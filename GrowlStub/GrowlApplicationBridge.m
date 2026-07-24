//
//  GrowlApplicationBridge.m
//  HardwareGrowler-NC
//
//  Originally part of Growl (© The Growl Project, LLC, BSD License — see
//  License.txt). Substantially rewritten for this fork to implement a custom
//  native-style notification banner (NSPanel + NSVisualEffectView) instead of
//  the legacy Growl delivery path.
//
//  This fork's modifications are © 2026 Jensy Leonardo Martínez Cruz, licensed
//  under the GNU General Public License v3.0 (GPLv3) — see LICENSE. The
//  original Growl portions remain under their BSD License (GPL-compatible).
//
// compile with ARC: -fobjc-arc -fobjc-exceptions
#import "Growl/Growl.h"
#import <UserNotifications/UserNotifications.h>
#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>

static id<GrowlApplicationBridgeDelegate> _delegate = nil;
static BOOL _useCustomBanner = NO;

// Active banners stack — newest at index 0 (top of screen), older below.
// All access happens on the main queue, so no locking needed.
static NSMutableArray *_activeBanners = nil;

// Vertical gap between stacked banners (in screen pixels)
static const CGFloat kBannerGap = 8.0;

// ── Helper: content view that tracks mouse hover and click ───────────────────
@interface HWGBannerContentView : NSView
@property (nonatomic, copy) void (^onHoverChange)(BOOL hovering);
@property (nonatomic, copy) void (^onClick)(void);
@end

@implementation HWGBannerContentView
- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    for (NSTrackingArea *ta in [self.trackingAreas copy]) {
        [self removeTrackingArea:ta];
    }
    NSTrackingArea *ta = [[NSTrackingArea alloc]
        initWithRect:self.bounds
             options:NSTrackingMouseEnteredAndExited
                   | NSTrackingActiveAlways
                   | NSTrackingInVisibleRect
               owner:self
            userInfo:nil];
    [self addTrackingArea:ta];
}
- (void)mouseEntered:(NSEvent *)e { if (_onHoverChange) _onHoverChange(YES); }
- (void)mouseExited:(NSEvent *)e  { if (_onHoverChange) _onHoverChange(NO); }
// Clicks anywhere on the banner (except the close button, which is an NSButton
// that consumes its own clicks) trigger the open action.
- (void)mouseDown:(NSEvent *)e { if (_onClick) _onClick(); }
@end

// ── Helper: NSButton with a block-based click handler ────────────────────────
@interface HWGCloseButton : NSButton
@property (nonatomic, copy) void (^onClick)(void);
@end

@implementation HWGCloseButton
- (instancetype)initWithFrame:(NSRect)f {
    if ((self = [super initWithFrame:f])) {
        self.target = self;
        self.action = @selector(handleClick);
    }
    return self;
}
- (void)handleClick { if (_onClick) _onClick(); }
@end

// Layout constants shared between banner creation and repositioning.
static const CGFloat kCardW = 300;
static const CGFloat kPadL  = 9;    // left padding (room for close-button overhang)
static const CGFloat kPadT  = 9;    // top padding (room for close-button overhang)
static const CGFloat kPanelW = kCardW + kPadL;
static const CGFloat kScreenMargin = 10;

// Repositions every banner in _activeBanners according to its own height,
// stacking newest (index 0) at the top. Heights never animate (only origin
// does), so reading panel.frame.size.height mid-animation is safe.
static void repositionBanners(NSRect sf, BOOL animated) {
    CGFloat x       = NSMaxX(sf) - kScreenMargin - kPanelW;
    CGFloat cardTop = NSMaxY(sf) - kScreenMargin;   // top edge of the next card
    for (NSPanel *p in _activeBanners) {
        CGFloat panelH = p.frame.size.height;
        CGFloat cardH  = panelH - kPadT;
        CGFloat originY = cardTop - cardH;
        NSRect f = NSMakeRect(x, originY, kPanelW, panelH);
        if (animated) {
            [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) {
                ctx.duration       = 0.25;
                ctx.timingFunction = [CAMediaTimingFunction
                    functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
                [p.animator setFrame:f display:YES];
            } completionHandler:nil];
        } else {
            [p setFrame:f display:YES];
        }
        cardTop = originY - kBannerGap;   // next card sits below this one
    }
}

// ── Highlights the changed value in "before → after" description lines ──────
// Several plugins (Display Monitor's DisplayModeChanged/DisplayRoleChanged, etc.)
// build multi-line descriptions where one or more lines read "Label:\told → new".
// Coloring just the "new" part in an accent color lets the reader's eye land on
// what actually changed instead of re-reading the whole line. Lines without "→"
// (most notifications — plain "Connected"/"Disconnected" style text) are left
// exactly as before, just carrying the base font/color.
static NSAttributedString *HWGAttributedBodyHighlightingChangedValues(NSString *body, NSFont *font, NSColor *baseColor, BOOL dark) {
    NSDictionary *baseAttrs = @{NSFontAttributeName: font, NSForegroundColorAttributeName: baseColor};
    NSMutableAttributedString *result = [[NSMutableAttributedString alloc] init];

    NSColor *highlightColor = dark ? [NSColor systemTealColor] : [NSColor systemBlueColor];
    NSDictionary *highlightAttrs = @{NSFontAttributeName: [NSFont boldSystemFontOfSize:font.pointSize],
                                      NSForegroundColorAttributeName: highlightColor};

    NSArray<NSString *> *lines = [body componentsSeparatedByString:@"\n"];
    for (NSUInteger i = 0; i < [lines count]; i++) {
        NSString *line = lines[i];
        NSRange arrowRange = [line rangeOfString:@" → "];
        if (arrowRange.location == NSNotFound) {
            [result appendAttributedString:[[NSAttributedString alloc] initWithString:line attributes:baseAttrs]];
        } else {
            NSUInteger newValueStart = arrowRange.location + arrowRange.length;
            NSString *beforeArrow = [line substringToIndex:newValueStart];   // includes " → "
            NSString *newValue = [line substringFromIndex:newValueStart];
            [result appendAttributedString:[[NSAttributedString alloc] initWithString:beforeArrow attributes:baseAttrs]];
            [result appendAttributedString:[[NSAttributedString alloc] initWithString:newValue attributes:highlightAttrs]];
        }
        if (i + 1 < [lines count]) {
            [result appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n" attributes:baseAttrs]];
        }
    }
    return result;
}

// ── Floating banner styled like a native macOS notification ──────────────────
// Slides in from the right, slides out on auto-dismiss OR when user clicks "×".
// clickContext (if non-nil) is sent to the Growl delegate when the banner body
// is clicked, so plugins can act on it (e.g. VolumeMonitor opens the volume).
static void showBannerWindow(NSString *title, NSString *body, id clickContext, NSData *iconData) {
    dispatch_async(dispatch_get_main_queue(), ^{
        const CGFloat CARD_W = kCardW;
        const CGFloat PAD_L  = kPadL, PAD_T = kPadT;
        const CGFloat W      = kPanelW;
        const CGFloat M      = kScreenMargin;

        NSScreen *screen = [NSScreen mainScreen];
        if (!screen) return;
        NSRect sf = screen.visibleFrame;

        if (!_activeBanners) _activeBanners = [[NSMutableArray alloc] init];

        // Appearance-adaptive colors — computed early (moved up from its original spot
        // below) because the body's attributed-string highlight needs `dark` to pick an
        // accent color before the body height can even be measured.
        NSAppearance *appearance = [NSApp effectiveAppearance];
        NSAppearanceName best = [appearance bestMatchFromAppearancesWithNames:
            @[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]];
        BOOL dark = [best isEqualToString:NSAppearanceNameDarkAqua];

        NSColor *titleColor = dark ? [NSColor whiteColor]
                                   : [NSColor colorWithWhite:0.08 alpha:1.0];
        NSColor *bodyColor  = dark ? [NSColor colorWithWhite:0.72 alpha:1.0]
                                   : [NSColor colorWithWhite:0.35 alpha:1.0];

        // ── Measure title + body heights so the card grows to fit the content ──
        const CGFloat bodyX = 54, bodyRightPad = 8;
        const CGFloat bodyW = CARD_W - bodyX - bodyRightPad;

        // Title: wraps to as many lines as needed; the card grows to fit the
        // full title (no truncation). Prevents long volume names from
        // overflowing the card (P46).
        NSFont *titleFont = [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
        NSString *titleStr = title ?: @"HG4MAC";
        NSRect titleBR = [titleStr boundingRectWithSize:NSMakeSize(bodyW, 10000)
                                                options:NSStringDrawingUsesLineFragmentOrigin
                                             attributes:@{NSFontAttributeName: titleFont}];
        CGFloat titleH = ceil(titleBR.size.height);
        if (titleH < 16) titleH = 16;     // 1 line minimum

        NSFont *bodyFont = [NSFont systemFontOfSize:11];
        NSString *bodyStr = body ?: @"";
        // Per-line, highlights the part after "→" (the NEW value in a "before → after"
        // change line, e.g. "Role:\tExtended → Mirrored") in an accent color, so the reader's
        // eye lands on what actually changed instead of re-reading the whole line.
        NSAttributedString *attrBody = HWGAttributedBodyHighlightingChangedValues(bodyStr, bodyFont, bodyColor, dark);
        NSRect bodyBR = [attrBody boundingRectWithSize:NSMakeSize(bodyW, 10000)
                                              options:NSStringDrawingUsesLineFragmentOrigin];
        CGFloat bodyH = ceil(bodyBR.size.height);
        if (bodyH < 22) bodyH = 22;   // minimum keeps short notifications looking normal

        // Card layout: 10 top pad + titleH + 2 gap + bodyH + 10 bottom pad
        const CGFloat CARD_H = 10 + titleH + 2 + bodyH + 10;
        const CGFloat H      = CARD_H + PAD_T;

        // New banner starts off-screen to the right at the top slot's Y.
        NSRect startFrame = NSMakeRect(NSMaxX(sf) + 4,
                                       NSMaxY(sf) - M - CARD_H, W, H);

        NSPanel *panel = [[NSPanel alloc]
            initWithContentRect:startFrame
                      styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
                        backing:NSBackingStoreBuffered
                          defer:NO];
        panel.floatingPanel      = YES;
        panel.level              = NSStatusWindowLevel;
        panel.opaque             = NO;
        panel.backgroundColor    = [NSColor clearColor];
        panel.hidesOnDeactivate  = NO;
        panel.hasShadow          = YES;
        panel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces
                                 | NSWindowCollectionBehaviorStationary;
        panel.acceptsMouseMovedEvents = YES;

        // Outer content view — NOT clipped, so the close button can overhang
        // the rounded card. This is where hover tracking lives.
        HWGBannerContentView *cv = [[HWGBannerContentView alloc]
            initWithFrame:NSMakeRect(0, 0, W, H)];
        cv.wantsLayer = YES;
        panel.contentView = cv;

        // Background card — uses NSVisualEffectView for the "frosted glass"
        // translucent blur effect, just like native macOS notifications.
        NSVisualEffectView *cardView = [[NSVisualEffectView alloc]
            initWithFrame:NSMakeRect(PAD_L, 0, CARD_W, CARD_H)];
        cardView.material     = NSVisualEffectMaterialPopover;   // adapts to dark/light
        cardView.blendingMode = NSVisualEffectBlendingModeBehindWindow;
        cardView.state        = NSVisualEffectStateActive;
        cardView.wantsLayer   = YES;
        cardView.layer.cornerRadius  = 12;
        cardView.layer.masksToBounds = YES;
        [cv addSubview:cardView];

        // App icon — 36×36 (standard macOS notification icon size).
        // Top-aligned with the title so tall cards don't float it in the middle.
        NSImageView *iconView = [[NSImageView alloc]
            initWithFrame:NSMakeRect(10, CARD_H - 10 - 36, 36, 36)];
        // Use the notification's own icon when provided, else the app icon.
        // initWithData: returns a non-nil but INVALID image for non-image bytes,
        // so check -isValid (not just nil) before using it.
        NSImage *notifIcon = nil;
        if (iconData) notifIcon = [[NSImage alloc] initWithData:iconData];
        if (!notifIcon.isValid) notifIcon = nil;
        iconView.image        = notifIcon ?: [NSApp applicationIconImage];
        iconView.imageScaling = NSImageScaleProportionallyUpOrDown;
        [cardView addSubview:iconView];

        // Title — pinned near the top; wraps fully (no line cap), card grows.
        NSTextField *titleLabel    = [[NSTextField alloc]
            initWithFrame:NSMakeRect(bodyX, CARD_H - 10 - titleH, bodyW, titleH)];
        titleLabel.stringValue        = titleStr;
        titleLabel.font               = titleFont;
        titleLabel.textColor          = titleColor;
        titleLabel.drawsBackground    = NO;
        titleLabel.bordered           = NO;
        titleLabel.editable           = NO;
        titleLabel.selectable         = NO;
        titleLabel.maximumNumberOfLines = 0;
        titleLabel.lineBreakMode      = NSLineBreakByWordWrapping;
        [cardView addSubview:titleLabel];

        // Body — grows downward; height measured above, no line cap
        NSTextField *bodyLabel         = [[NSTextField alloc]
            initWithFrame:NSMakeRect(bodyX, 10, bodyW, bodyH)];
        bodyLabel.attributedStringValue = attrBody;   // font/color are embedded in attrBody
        bodyLabel.drawsBackground      = NO;
        bodyLabel.bordered             = NO;
        bodyLabel.editable             = NO;
        bodyLabel.selectable           = NO;
        bodyLabel.maximumNumberOfLines = 0;
        bodyLabel.lineBreakMode        = NSLineBreakByWordWrapping;
        [cardView addSubview:bodyLabel];

        // Close "×" button — sits centered on the card's top-left corner so it
        // overhangs the rounded edge, like native macOS notifications. Lives on
        // the unclipped outer view (cv), not on the masked card.
        const CGFloat BTN = 18;
        HWGCloseButton *closeBtn = [[HWGCloseButton alloc]
            initWithFrame:NSMakeRect(PAD_L - BTN / 2.0,
                                     CARD_H - BTN / 2.0,
                                     BTN, BTN)];
        closeBtn.bordered      = NO;
        closeBtn.bezelStyle    = NSBezelStyleCircular;
        closeBtn.imagePosition = NSImageOnly;
        closeBtn.title         = @"";

        NSImage *xImg = nil;
        if (@available(macOS 11.0, *)) {
            xImg = [NSImage imageWithSystemSymbolName:@"xmark.circle.fill"
                             accessibilityDescription:@"Close"];
            NSImageSymbolConfiguration *cfg =
                [NSImageSymbolConfiguration configurationWithPointSize:16
                                                                weight:NSFontWeightRegular];
            if (cfg) xImg = [xImg imageWithSymbolConfiguration:cfg];
        }

        closeBtn.wantsLayer = YES;
        closeBtn.alphaValue = 0.0;       // hidden until hover

        if (xImg) {
            closeBtn.image            = xImg;
            closeBtn.contentTintColor = dark ? [NSColor colorWithWhite:0.85 alpha:1.0]
                                             : [NSColor colorWithWhite:0.25 alpha:1.0];
        } else {
            // Fallback for older systems: plain "×" character
            closeBtn.imagePosition = NSNoImage;
            closeBtn.title         = @"×";
            closeBtn.font          = [NSFont systemFontOfSize:14 weight:NSFontWeightBold];
            NSMutableAttributedString *as = [[NSMutableAttributedString alloc]
                initWithString:@"×"];
            [as addAttribute:NSForegroundColorAttributeName
                       value:(dark ? [NSColor whiteColor] : [NSColor blackColor])
                       range:NSMakeRange(0, 1)];
            closeBtn.attributedTitle = as;
        }
        [cv addSubview:closeBtn];

        // Single dismiss block — fires either on click or after 5 s, runs once.
        // When the banner closes, banners below it slide up to fill the gap.
        // IMPORTANT: capture `panel` WEAKLY here. `dismiss` is stored on closeBtn.onClick
        // and cv.onClick — both of which are subviews retained BY panel. A strong capture
        // of `panel` inside `dismiss` would create panel → subview → onClick block → panel,
        // a retain cycle that leaks every banner ever shown for the app's whole lifetime
        // (only visually hidden via orderOut, never deallocated) — a real, cumulative leak
        // given how often notifications fire (periodic refires, Wi-Fi signal changes, etc).
        __block BOOL dismissed = NO;
        __weak NSPanel *weakPanel = panel;
        void (^dismiss)(void) = ^{
            if (dismissed) return;
            dismissed = YES;

            NSPanel *strongPanel = weakPanel;
            if (!strongPanel) return;

            // Remove this banner from the stack, then re-flow the rest so the
            // ones below slide up to fill the gap.
            NSInteger idx = [_activeBanners indexOfObjectIdenticalTo:strongPanel];
            if (idx != NSNotFound) {
                [_activeBanners removeObjectAtIndex:idx];
                repositionBanners(sf, YES);
            }

            [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) {
                ctx.duration       = 0.3;
                ctx.timingFunction = [CAMediaTimingFunction
                    functionWithName:kCAMediaTimingFunctionEaseIn];
                NSRect outFrame = strongPanel.frame;
                outFrame.origin.x = NSMaxX(sf) + 4;
                [strongPanel.animator setFrame:outFrame display:YES];
            } completionHandler:^{
                [strongPanel orderOut:nil];
            }];
        };

        closeBtn.onClick = dismiss;

        // Click on the banner body: notify the Growl delegate (so the plugin
        // can act, e.g. open the mounted volume) then dismiss the banner.
        cv.onClick = ^{
            if (clickContext &&
                [_delegate respondsToSelector:@selector(growlNotificationWasClicked:)]) {
                [(id)_delegate growlNotificationWasClicked:clickContext];
            }
            dismiss();
        };

        // Hover behavior: fade the close button in/out smoothly
        cv.onHoverChange = ^(BOOL hovering) {
            [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) {
                ctx.duration = 0.15;
                closeBtn.animator.alphaValue = hovering ? 1.0 : 0.0;
            } completionHandler:nil];
        };

        // Register at index 0 — this banner is now the newest (top slot)
        [_activeBanners insertObject:panel atIndex:0];

        // Show off-screen, then animate everyone to their correct positions.
        // The new banner (index 0) slides in from the right; existing banners
        // shift down to make room — all driven by repositionBanners.
        [panel orderFront:nil];
        repositionBanners(sf, YES);

        // Re-register tracking areas once the panel reaches its on-screen spot
        // (they were created while the view was off-screen with an empty rect).
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [cv updateTrackingAreas];
        });

        // Auto-dismiss after 5 s (skipped if user already clicked "×")
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC),
                       dispatch_get_main_queue(), ^{
            dismiss();
        });
    });
}

// ── Routing logic (unchanged) ────────────────────────────────────────────────

@implementation GrowlApplicationBridge

+ (void)setGrowlDelegate:(id<GrowlApplicationBridgeDelegate>)delegate {
    _delegate = delegate;
    [[UNUserNotificationCenter currentNotificationCenter]
        requestAuthorizationWithOptions:(UNAuthorizationOptionAlert | UNAuthorizationOptionSound)
        completionHandler:^(BOOL granted, NSError *error) {
            _useCustomBanner = !granted;
        }];
}

+ (void)setShouldUseBuiltInNotifications:(BOOL)use {}

+ (void)notifyWithTitle:(NSString *)title
            description:(NSString *)description
       notificationName:(NSString *)notifName
               iconData:(NSData *)iconData
               priority:(signed int)priority
               isSticky:(BOOL)isSticky
           clickContext:(id)clickContext
             identifier:(NSString *)identifier
{
    if (!_useCustomBanner) {
        UNMutableNotificationContent *content = [UNMutableNotificationContent new];
        content.title = title ?: @"HG4MAC";
        content.body  = description ?: @"";
        NSString *reqID = identifier ?: [[NSUUID UUID] UUIDString];
        UNNotificationRequest *req = [UNNotificationRequest
            requestWithIdentifier:reqID content:content trigger:nil];
        [[UNUserNotificationCenter currentNotificationCenter]
            addNotificationRequest:req
             withCompletionHandler:^(NSError *err) {
                if (err) showBannerWindow(title, description, clickContext, iconData);
            }];
    } else {
        showBannerWindow(title, description, clickContext, iconData);
    }
}

@end
