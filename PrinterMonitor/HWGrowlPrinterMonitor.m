//
//  HWGrowlPrinterMonitor.m
//  HardwareGrowler
//
//  F34 #5: printer connected/disconnected. There is no public push notification for the
//  system's printer list changing — this monitor POLLS the current CUPS destination list on
//  a short timer and diffs against the previous snapshot. This works uniformly for USB,
//  Bluetooth, AND network (IPP/AirPrint/Bonjour) printers because all three end up as CUPS
//  destinations once macOS has added them (System Settings → Printers & Scanners) — but a
//  network printer only appears once it's actually been ADDED there, not merely
//  reachable/discoverable on the LAN. OFF by default per user request.
//
//  BUG FIX (23-jul-2026): originally used `[NSPrinter printerNames]` (classic AppKit printing
//  API) — confirmed via live testing (added/removed a real Bonjour/AirPrint printer) that this
//  API returns an EMPTY list in this app the entire time, even while `lpstat -p` / CUPS itself
//  correctly showed the printer as added. `NSPrinter` apparently doesn't reliably enumerate
//  CUPS destinations for this kind of background-only (LSUIElement) process. Switched to
//  `cupsGetDests()` — the actual public CUPS C API `lpstat` itself is built on — which reads
//  the destination list directly and does not depend on any AppKit printing-panel machinery.
//
//  ATTEMPTED (23-jul-2026, REVERTED): tried watching /etc/cups/printers.conf directly via a
//  kqueue-backed DispatchSource for instant, event-driven detection instead of polling.
//  Confirmed via live testing this silently detected nothing at all: that file is mode 0600,
//  owned by root:_lp — a normal user process cannot even open() it, so the watcher never
//  attached (open() failed, and the code silently gave up, exactly matching the report "no
//  notifica nada"). `cupsGetDests()` itself doesn't have this problem because it talks to
//  cupsd over IPP (a local socket any user can query), not by reading the config file
//  directly. Reverted to polling, but with a much shorter interval (3s vs the original 15s)
//  since cupsGetDests() itself is a cheap local IPP round-trip — this gets most of the
//  "feels instant" benefit without requiring privileges this app will never have.

// compile with ARC: -fobjc-arc
#import "HWGrowlPrinterMonitor.h"
#import <cups/cups.h>

#define HWG_PRINTER_NOTIFY_KEY @"HWGPrinterNotifyConnectDisconnect"
#define HWG_PRINTER_POLL_INTERVAL 3.0

// F34 follow-up (23-jul-2026, user request): 3 additions, all OFF by default —
// #1 printer error/warning state, #2 default-printer-changed, #3 extra info fields on Connected.
#define HWG_PRINTER_NOTIFY_ERROR_KEY   @"HWGPrinterNotifyErrorState"
#define HWG_PRINTER_NOTIFY_DEFAULT_KEY @"HWGPrinterNotifyDefaultChanged"
#define HWG_PRINTER_SHOW_LOCATION_KEY   @"HWGPrinterShowLocation"
#define HWG_PRINTER_SHOW_MAKEMODEL_KEY  @"HWGPrinterShowMakeModel"
#define HWG_PRINTER_SHOW_CONNECTION_KEY @"HWGPrinterShowConnectionType"

static BOOL HWGPrinterBoolForKey(NSString *key, BOOL def) {
	id stored = [[NSUserDefaults standardUserDefaults] objectForKey:key];
	return stored ? [stored boolValue] : def;
}

// One CUPS destination's info, read once per poll and reused for all 3 features below (name
// diffing, error-state tracking, default-printer tracking, and Connected's extra info lines) —
// avoids querying CUPS multiple times per tick for the same data.
@interface HWGPrinterInfo : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, assign) BOOL isDefault;
@property (nonatomic, copy) NSString *stateReasons;   // e.g. "none", or "media-empty-warning,toner-low-warning"
@property (nonatomic, copy) NSString *location;
@property (nonatomic, copy) NSString *makeModel;
@property (nonatomic, copy) NSString *connectionType;   // "USB" / "Network" / "Bluetooth" / raw scheme
@end
@implementation HWGPrinterInfo
@end

// Maps a device-uri scheme (e.g. "usb://…", "dnssd://…") to a human-readable connection type.
// Same 3-way split already documented in README for how this monitor detects printers.
static NSString *HWGConnectionTypeForDeviceURI(NSString *uri) {
	if (![uri length]) return nil;
	NSString *scheme = [[uri componentsSeparatedByString:@":"] firstObject].lowercaseString;
	if ([scheme isEqualToString:@"usb"]) return NSLocalizedString(@"USB", @"");
	if ([scheme isEqualToString:@"bluetooth"]) return NSLocalizedString(@"Bluetooth", @"");
	if ([scheme isEqualToString:@"dnssd"] || [scheme isEqualToString:@"ipp"] || [scheme isEqualToString:@"ipps"] ||
		[scheme isEqualToString:@"socket"] || [scheme isEqualToString:@"lpd"] || [scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"]) {
		return NSLocalizedString(@"Network", @"");
	}
	return [scheme length] ? [scheme uppercaseString] : nil;
}

// Reads every CUPS destination (what `lpstat -p` also reads — see BUG FIX note above for why
// this replaced `[NSPrinter printerNames]`) with the extra attributes #1/#2/#3 need.
static NSDictionary<NSString*, HWGPrinterInfo*> *HWGCollectPrinterInfo(void) {
	cups_dest_t *dests = NULL;
	int count = cupsGetDests(&dests);
	NSMutableDictionary<NSString*, HWGPrinterInfo*> *result = [NSMutableDictionary dictionaryWithCapacity:(NSUInteger)MAX(count, 0)];
	for (int i = 0; i < count; i++) {
		cups_dest_t *dest = &dests[i];
		if (!dest->name) continue;
		HWGPrinterInfo *info = [[HWGPrinterInfo alloc] init];
		info.name = [NSString stringWithUTF8String:dest->name];
		info.isDefault = dest->is_default ? YES : NO;

		const char *reasons = cupsGetOption("printer-state-reasons", dest->num_options, dest->options);
		info.stateReasons = reasons ? [NSString stringWithUTF8String:reasons] : @"none";

		const char *location = cupsGetOption("printer-location", dest->num_options, dest->options);
		info.location = (location && *location) ? [NSString stringWithUTF8String:location] : nil;

		const char *makeModel = cupsGetOption("printer-make-and-model", dest->num_options, dest->options);
		info.makeModel = (makeModel && *makeModel) ? [NSString stringWithUTF8String:makeModel] : nil;

		const char *deviceURI = cupsGetOption("device-uri", dest->num_options, dest->options);
		info.connectionType = deviceURI ? HWGConnectionTypeForDeviceURI([NSString stringWithUTF8String:deviceURI]) : nil;

		result[info.name] = info;
	}
	if (dests) cupsFreeDests(count, dests);
	return result;
}

// Whether a printer-state-reasons string indicates an actual problem — "none" (the IPP
// keyword for "nothing to report") is the only value that means everything's fine; anything
// else (…-error or …-warning keywords, comma-separated) is worth surfacing. This is a
// heuristic reading of a standard IPP value, not a CUPS-internal API.
static BOOL HWGStateReasonsIndicateProblem(NSString *reasons) {
	return [reasons length] && ![reasons isEqualToString:@"none"];
}

@interface HWGrowlPrinterMonitor ()

@property (nonatomic, weak) id<HWGrowlPluginControllerProtocol> delegate;
@property (nonatomic, strong) NSView *prefsView;
@property (nonatomic, strong) NSSet<NSString*> *knownPrinterNames;
@property (nonatomic, strong) NSTimer *pollTimer;

// #1: last known state-reasons per printer, to fire only on the OK↔problem transition, not
// on every poll tick while a problem persists.
@property (nonatomic, strong) NSMutableDictionary<NSString*, NSString*> *lastKnownStateReasons;
// #2: last known default-printer name, to fire only when it actually changes.
@property (nonatomic, copy) NSString *lastKnownDefaultPrinter;

@end

@implementation HWGrowlPrinterMonitor

@synthesize delegate;
@synthesize prefsView;

-(id)init {
	if ((self = [super init])) {
		self.lastKnownStateReasons = [NSMutableDictionary dictionary];
		// Baseline silently at launch — never announce printers/states/defaults that were
		// already present.
		NSDictionary<NSString*, HWGPrinterInfo*> *info = HWGCollectPrinterInfo();
		self.knownPrinterNames = [NSSet setWithArray:[info allKeys]];
		for (HWGPrinterInfo *p in [info allValues]) {
			self.lastKnownStateReasons[p.name] = p.stateReasons;
			if (p.isDefault) self.lastKnownDefaultPrinter = p.name;
		}
		[self updateWatcherState];
	}
	return self;
}

-(void)dealloc {
	[_pollTimer invalidate];
}

-(void)updateWatcherState {
	BOOL enabled = HWGPrinterBoolForKey(HWG_PRINTER_NOTIFY_KEY, NO);
	if (enabled && !_pollTimer) {
		self.pollTimer = [NSTimer scheduledTimerWithTimeInterval:HWG_PRINTER_POLL_INTERVAL
														   target:self
														 selector:@selector(checkPrinters)
														 userInfo:nil
														  repeats:YES];
	} else if (!enabled && _pollTimer) {
		[_pollTimer invalidate];
		self.pollTimer = nil;
	}
}

-(void)checkPrinters {
	NSDictionary<NSString*, HWGPrinterInfo*> *currentInfo = HWGCollectPrinterInfo();
	NSSet<NSString*> *currentNames = [NSSet setWithArray:[currentInfo allKeys]];

	BOOL namesChanged = ![currentNames isEqualToSet:self.knownPrinterNames];
	BOOL showLocation   = HWGPrinterBoolForKey(HWG_PRINTER_SHOW_LOCATION_KEY, NO);
	BOOL showMakeModel  = HWGPrinterBoolForKey(HWG_PRINTER_SHOW_MAKEMODEL_KEY, NO);
	BOOL showConnection = HWGPrinterBoolForKey(HWG_PRINTER_SHOW_CONNECTION_KEY, NO);

	if (namesChanged) {
		NSMutableSet<NSString*> *added = [currentNames mutableCopy];
		[added minusSet:self.knownPrinterNames];
		NSMutableSet<NSString*> *removed = [self.knownPrinterNames mutableCopy];
		[removed minusSet:currentNames];

		NSImage *icon = [HWGrowlPrinterMonitor printerIconConnected:YES];
		NSData *onIcon = [icon TIFFRepresentation];
		NSImage *offImage = [HWGrowlPrinterMonitor printerIconConnected:NO];
		NSData *offIcon = [offImage TIFFRepresentation];

		for (NSString *name in added) {
			// #3: extra info lines on Connected — each independently toggleable, OFF by
			// default (23-jul-2026). Absent entirely if all 3 are off, matching the plain
			// name-only description this notification always had before.
			HWGPrinterInfo *info = currentInfo[name];
			NSMutableArray<NSString*> *lines = [NSMutableArray arrayWithObject:name];
			if (showLocation && [info.location length]) {
				[lines addObject:[NSString stringWithFormat:NSLocalizedString(@"Location: %@", @""), info.location]];
			}
			if (showMakeModel && [info.makeModel length]) {
				[lines addObject:[NSString stringWithFormat:NSLocalizedString(@"Model: %@", @""), info.makeModel]];
			}
			if (showConnection && [info.connectionType length]) {
				[lines addObject:[NSString stringWithFormat:NSLocalizedString(@"Connection: %@", @""), info.connectionType]];
			}

			[delegate notifyWithName:@"PrinterConnected"
									 title:NSLocalizedString(@"Printer Connected", @"")
							 description:[lines componentsJoinedByString:@"\n"]
									  icon:onIcon
					  identifierString:[NSString stringWithFormat:@"HWGrowlPrinter-%@", name]
						  contextString:nil
									plugin:self];
		}
		for (NSString *name in removed) {
			[delegate notifyWithName:@"PrinterDisconnected"
									 title:NSLocalizedString(@"Printer Disconnected", @"")
							 description:name
									  icon:offIcon
					  identifierString:[NSString stringWithFormat:@"HWGrowlPrinter-%@", name]
						  contextString:nil
									plugin:self];
		}

		// Re-arm error-state tracking for removed printers (a later reinsertion should be
		// evaluated fresh, not compared against a stale reading from before it disappeared).
		for (NSString *name in removed) [self.lastKnownStateReasons removeObjectForKey:name];

		self.knownPrinterNames = currentNames;
	}

	// #1: error/warning state — OFF by default. Fires only on the OK↔problem transition.
	if (HWGPrinterBoolForKey(HWG_PRINTER_NOTIFY_ERROR_KEY, NO)) {
		for (HWGPrinterInfo *info in [currentInfo allValues]) {
			NSString *previousReasons = self.lastKnownStateReasons[info.name];
			BOOL wasProblem = HWGStateReasonsIndicateProblem(previousReasons);
			BOOL isProblem  = HWGStateReasonsIndicateProblem(info.stateReasons);
			if (isProblem && !wasProblem) {
				NSData *iconData = [[HWGrowlPrinterMonitor printerIconConnected:NO] TIFFRepresentation];
				[delegate notifyWithName:@"PrinterError"
										 title:NSLocalizedString(@"Printer Needs Attention", @"")
								 description:[NSString stringWithFormat:@"%@\n%@", info.name, info.stateReasons]
										  icon:iconData
						  identifierString:[NSString stringWithFormat:@"HWGrowlPrinterError-%@", info.name]
							  contextString:nil
										plugin:self];
			} else if (!isProblem && wasProblem) {
				NSData *iconData = [[HWGrowlPrinterMonitor printerIconConnected:YES] TIFFRepresentation];
				[delegate notifyWithName:@"PrinterError"
										 title:NSLocalizedString(@"Printer OK", @"")
								 description:info.name
										  icon:iconData
						  identifierString:[NSString stringWithFormat:@"HWGrowlPrinterError-%@", info.name]
							  contextString:nil
										plugin:self];
			}
			self.lastKnownStateReasons[info.name] = info.stateReasons;
		}
	}

	// #2: default printer changed — OFF by default. Fires only on an actual change, and
	// never on the very first read (nothing to compare "from" yet).
	if (HWGPrinterBoolForKey(HWG_PRINTER_NOTIFY_DEFAULT_KEY, NO)) {
		NSString *currentDefault = nil;
		for (HWGPrinterInfo *info in [currentInfo allValues]) {
			if (info.isDefault) { currentDefault = info.name; break; }
		}
		if (currentDefault && ![currentDefault isEqualToString:self.lastKnownDefaultPrinter]) {
			NSString *previous = self.lastKnownDefaultPrinter;
			self.lastKnownDefaultPrinter = currentDefault;
			if (previous) {   // skip the very first baseline read
				NSData *iconData = [[HWGrowlPrinterMonitor printerIconConnected:YES] TIFFRepresentation];
				[delegate notifyWithName:@"PrinterDefaultChanged"
										 title:NSLocalizedString(@"Default Printer Changed", @"")
								 description:[NSString stringWithFormat:NSLocalizedString(@"%@ → %@", @""), previous, currentDefault]
										  icon:iconData
						  identifierString:@"HWGrowlPrinterDefault"
							  contextString:nil
										plugin:self];
			}
		}
	}
}

#pragma mark Icon

+(NSColor *)accentColor {
	// Teal — not used by any other monitor (Bluetooth/Camera=blue, Network=cyan,
	// Thunderbolt=yellow, Thermal=red, Power=green, Audio=orange, Gamepad=pink).
	return [NSColor systemTealColor];
}

// Flat-color vector icon (23-jul-2026, adapted from a reference image the user provided) —
// unlike the other hand-drawn monitor icons in this codebase (stroke-only, single accent
// color), this one is a filled flat illustration: gray printer body with side "ears" and a
// paper tray sticking up (recolored to the accent teal, replacing the reference's blue), a
// dark control-panel bevel with button dots, and — when `connected` — a printed page
// emerging from the bottom slot with text lines and a small accent-colored swatch, matching
// the reference's composition. Black outlines throughout (as in the reference), which read
// fine on both light and dark sidebar backgrounds.
+(NSImage *)printerIconConnected:(BOOL)connected {
	NSSize canvasSize = NSMakeSize(128, 128);
	NSImage *image = [NSImage imageWithSize:canvasSize flipped:NO drawingHandler:^BOOL(NSRect rect) {
		// Enlarged 23-jul-2026 per user request — scale the whole drawing up around the
		// canvas center rather than re-deriving every proportion by hand.
		NSAffineTransform *enlarge = [NSAffineTransform transform];
		[enlarge translateXBy:NSMidX(rect) yBy:NSMidY(rect)];
		[enlarge scaleBy:1.22];
		[enlarge translateXBy:-NSMidX(rect) yBy:-NSMidY(rect)];
		[enlarge concat];

		NSColor *accent = [HWGrowlPrinterMonitor accentColor];
		NSColor *outline = [NSColor colorWithWhite:0.08 alpha:1.0];
		NSColor *bodyGray = [NSColor colorWithWhite:0.80 alpha:1.0];
		NSColor *earGray = [NSColor colorWithWhite:0.62 alpha:1.0];
		NSColor *bevelGray = [NSColor colorWithWhite:0.55 alpha:1.0];
		NSColor *slotGray = [NSColor colorWithWhite:0.45 alpha:1.0];
		CGFloat strokeW = rect.size.width * 0.028;

		CGFloat w = rect.size.width, h = rect.size.height;
		CGFloat bodyW = w * 0.66, bodyH = h * 0.34;
		NSRect bodyRect = NSMakeRect(NSMidX(rect) - bodyW / 2.0, h * 0.14, bodyW, bodyH);

		// Side "ears" (paper-tray posts) flanking the top paper slot.
		CGFloat earW = bodyW * 0.14, earH = h * 0.22;
		NSRect leftEar  = NSMakeRect(NSMinX(bodyRect) + bodyW * 0.10, NSMaxY(bodyRect) - h * 0.03, earW, earH);
		NSRect rightEar = NSMakeRect(NSMaxX(bodyRect) - bodyW * 0.10 - earW, NSMaxY(bodyRect) - h * 0.03, earW, earH);
		for (NSValue *v in @[[NSValue valueWithRect:leftEar], [NSValue valueWithRect:rightEar]]) {
			NSRect earRect = v.rectValue;
			NSBezierPath *ear = [NSBezierPath bezierPathWithRoundedRect:earRect xRadius:earW * 0.15 yRadius:earW * 0.15];
			[earGray setFill]; [ear fill];
			ear.lineWidth = strokeW; [outline setStroke]; [ear stroke];
		}

		// Paper tray sticking up between the ears, in the accent color.
		CGFloat trayPaperW = bodyW * 0.42;
		NSRect trayPaperRect = NSMakeRect(NSMidX(rect) - trayPaperW / 2.0, NSMinY(leftEar) + earH * 0.15, trayPaperW, earH * 1.15);
		NSBezierPath *trayPaper = [NSBezierPath bezierPathWithRoundedRect:trayPaperRect xRadius:trayPaperW * 0.06 yRadius:trayPaperW * 0.06];
		[[accent colorWithAlphaComponent:0.35] setFill]; [trayPaper fill];
		trayPaper.lineWidth = strokeW; [outline setStroke]; [trayPaper stroke];

		// Dark bevel strip (control panel) with 3 small button dots, just above the body.
		CGFloat bevelH = h * 0.06;
		NSRect bevelRect = NSMakeRect(NSMinX(bodyRect), NSMaxY(bodyRect) - bevelH * 0.4, bodyW, bevelH);
		NSBezierPath *bevel = [NSBezierPath bezierPathWithRoundedRect:bevelRect xRadius:bevelH * 0.2 yRadius:bevelH * 0.2];
		[bevelGray setFill]; [bevel fill];
		bevel.lineWidth = strokeW; [outline setStroke]; [bevel stroke];

		CGFloat dotD = bevelH * 0.42;
		for (int i = 0; i < 3; i++) {
			CGFloat dotX = NSMinX(bodyRect) + bodyW * (0.16 + i * 0.08);
			NSRect dotRect = NSMakeRect(dotX, NSMidY(bevelRect) - dotD / 2.0, dotD, dotD);
			NSBezierPath *dot = [NSBezierPath bezierPathWithRoundedRect:dotRect xRadius:dotD * 0.25 yRadius:dotD * 0.25];
			[outline setFill]; [dot fill];
		}

		// Printer body (main gray box).
		NSBezierPath *body = [NSBezierPath bezierPathWithRoundedRect:bodyRect xRadius:bodyW * 0.06 yRadius:bodyW * 0.06];
		[bodyGray setFill]; [body fill];
		body.lineWidth = strokeW * 1.3; [outline setStroke]; [body stroke];

		// Output slot: a dark horizontal bar low on the body, where the page emerges from.
		CGFloat slotW = bodyW * 0.62, slotH = h * 0.045;
		NSRect slotRect = NSMakeRect(NSMidX(rect) - slotW / 2.0, NSMinY(bodyRect) + bodyH * 0.16, slotW, slotH);
		NSBezierPath *slot = [NSBezierPath bezierPathWithRoundedRect:slotRect xRadius:slotH * 0.2 yRadius:slotH * 0.2];
		[slotGray setFill]; [slot fill];
		slot.lineWidth = strokeW; [outline setStroke]; [slot stroke];

		if (connected) {
			// Printed page emerging below the slot: white sheet with text lines + a small
			// accent-colored swatch (bottom-right), matching the reference's composition.
			CGFloat pageW = w * 0.46, pageH = h * 0.30;
			NSRect pageRect = NSMakeRect(NSMidX(rect) - pageW / 2.0, NSMinY(slotRect) - pageH * 0.82, pageW, pageH);
			NSBezierPath *page = [NSBezierPath bezierPathWithRoundedRect:pageRect xRadius:pageW * 0.04 yRadius:pageW * 0.04];
			[[NSColor whiteColor] setFill]; [page fill];
			page.lineWidth = strokeW * 1.2; [outline setStroke]; [page stroke];

			CGFloat lineH = pageH * 0.09;
			CGFloat lineInset = pageW * 0.10;
			for (int i = 0; i < 3; i++) {
				CGFloat lineY = NSMaxY(pageRect) - pageH * 0.22 - i * (lineH + pageH * 0.07);
				CGFloat lineW = (i == 2) ? pageW * 0.42 : pageW * 0.58;
				NSRect lineRect = NSMakeRect(NSMinX(pageRect) + lineInset, lineY, lineW, lineH);
				NSBezierPath *line = [NSBezierPath bezierPathWithRoundedRect:lineRect xRadius:lineH * 0.3 yRadius:lineH * 0.3];
				[outline setFill]; [line fill];
			}

			CGFloat swatchD = pageH * 0.34;
			NSRect swatchRect = NSMakeRect(NSMaxX(pageRect) - lineInset - swatchD, NSMinY(pageRect) + pageH * 0.14, swatchD, swatchD);
			NSBezierPath *swatch = [NSBezierPath bezierPathWithRoundedRect:swatchRect xRadius:swatchD * 0.15 yRadius:swatchD * 0.15];
			[accent setFill]; [swatch fill];
			swatch.lineWidth = strokeW; [outline setStroke]; [swatch stroke];
		}

		return YES;
	}];
	return image;
}

#pragma mark HWGrowlPluginProtocol

-(NSString*)pluginDisplayName {
	return NSLocalizedString(@"Printer Monitor", @"");
}
-(NSImage*)preferenceIcon {
	static NSImage *_icon = nil;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		_icon = [HWGrowlPrinterMonitor printerIconConnected:YES];
	});
	return _icon;
}

-(IBAction)fieldToggleChanged:(NSButton*)sender {
	NSString *key = sender.identifier;
	if (!key) return;
	[[NSUserDefaults standardUserDefaults] setBool:(sender.state == NSControlStateValueOn) forKey:key];
	[self updateWatcherState];
}

-(NSButton *)checkboxWithKey:(NSString *)key title:(NSString *)title defaultOn:(BOOL)defaultOn {
	NSButton *box = [NSButton checkboxWithTitle:title target:self action:@selector(fieldToggleChanged:)];
	box.identifier = key;
	box.state = HWGPrinterBoolForKey(key, defaultOn) ? NSControlStateValueOn : NSControlStateValueOff;
	box.translatesAutoresizingMaskIntoConstraints = NO;
	return box;
}

-(NSView*)preferencePane {
	if (prefsView) return prefsView;

	NSView *v = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 420, 340)];

	NSTextField *header = [NSTextField labelWithString:NSLocalizedString(@"Notification fields", @"")];
	header.font = [NSFont boldSystemFontOfSize:12];
	header.textColor = [NSColor secondaryLabelColor];
	header.translatesAutoresizingMaskIntoConstraints = NO;
	[v addSubview:header];
	[NSLayoutConstraint activateConstraints:@[
		[header.topAnchor     constraintEqualToAnchor:v.topAnchor constant:16],
		[header.leadingAnchor  constraintEqualToAnchor:v.leadingAnchor constant:16],
	]];

	// F34 #5: OFF by default — new monitor, off until the user opts in.
	NSButton *row = [self checkboxWithKey:HWG_PRINTER_NOTIFY_KEY title:NSLocalizedString(@"Notify when a printer is added/removed", @"") defaultOn:NO];
	[v addSubview:row];
	[NSLayoutConstraint activateConstraints:@[
		[row.topAnchor     constraintEqualToAnchor:header.bottomAnchor constant:10],
		[row.leadingAnchor  constraintEqualToAnchor:v.leadingAnchor constant:16],
		[row.heightAnchor   constraintEqualToConstant:24],
	]];

	NSTextField *caption = [NSTextField wrappingLabelWithString:
		NSLocalizedString(@"Detects USB, Bluetooth, and network (IPP/AirPrint/Bonjour) printers alike, by polling the system's printer list every 3s — there is no instant push notification for this (CUPS's own config file can't be watched directly without root). A network printer is only detected once it has actually been added in System Settings → Printers & Scanners, not merely discoverable on the LAN.", @"")];
	caption.textColor = [NSColor secondaryLabelColor];
	caption.font = [NSFont systemFontOfSize:11];
	caption.translatesAutoresizingMaskIntoConstraints = NO;
	caption.preferredMaxLayoutWidth = 380;
	[v addSubview:caption];
	[NSLayoutConstraint activateConstraints:@[
		[caption.topAnchor     constraintEqualToAnchor:row.bottomAnchor constant:8],
		[caption.leadingAnchor  constraintEqualToAnchor:v.leadingAnchor constant:16],
		[caption.trailingAnchor constraintLessThanOrEqualToAnchor:v.trailingAnchor constant:-16],
	]];

	// #3: extra info lines on "Printer Connected" — each OFF by default (23-jul-2026).
	NSTextField *infoHeader = [NSTextField labelWithString:NSLocalizedString(@"Extra info on connect", @"")];
	infoHeader.font = [NSFont boldSystemFontOfSize:12];
	infoHeader.textColor = [NSColor secondaryLabelColor];
	infoHeader.translatesAutoresizingMaskIntoConstraints = NO;
	[v addSubview:infoHeader];
	[NSLayoutConstraint activateConstraints:@[
		[infoHeader.topAnchor     constraintEqualToAnchor:caption.bottomAnchor constant:18],
		[infoHeader.leadingAnchor  constraintEqualToAnchor:v.leadingAnchor constant:16],
	]];

	NSButton *locationRow  = [self checkboxWithKey:HWG_PRINTER_SHOW_LOCATION_KEY   title:NSLocalizedString(@"Location", @"") defaultOn:NO];
	NSButton *makeModelRow = [self checkboxWithKey:HWG_PRINTER_SHOW_MAKEMODEL_KEY  title:NSLocalizedString(@"Make/model", @"") defaultOn:NO];
	NSButton *connRow      = [self checkboxWithKey:HWG_PRINTER_SHOW_CONNECTION_KEY title:NSLocalizedString(@"Connection type (USB/Network/Bluetooth)", @"") defaultOn:NO];
	NSView *previous = infoHeader;
	CGFloat gap = 10;
	for (NSButton *r in @[locationRow, makeModelRow, connRow]) {
		[v addSubview:r];
		[NSLayoutConstraint activateConstraints:@[
			[r.topAnchor     constraintEqualToAnchor:previous.bottomAnchor constant:gap],
			[r.leadingAnchor  constraintEqualToAnchor:v.leadingAnchor constant:16],
			[r.heightAnchor   constraintEqualToConstant:24],
		]];
		previous = r;
		gap = 6;
	}

	// #1 + #2: new notifications, both OFF by default (23-jul-2026).
	NSTextField *newNotesHeader = [NSTextField labelWithString:NSLocalizedString(@"Additional notifications", @"")];
	newNotesHeader.font = [NSFont boldSystemFontOfSize:12];
	newNotesHeader.textColor = [NSColor secondaryLabelColor];
	newNotesHeader.translatesAutoresizingMaskIntoConstraints = NO;
	[v addSubview:newNotesHeader];
	[NSLayoutConstraint activateConstraints:@[
		[newNotesHeader.topAnchor     constraintEqualToAnchor:previous.bottomAnchor constant:18],
		[newNotesHeader.leadingAnchor  constraintEqualToAnchor:v.leadingAnchor constant:16],
	]];

	NSButton *errorRow   = [self checkboxWithKey:HWG_PRINTER_NOTIFY_ERROR_KEY   title:NSLocalizedString(@"Notify when a printer needs attention (out of paper/toner, jammed, offline…)", @"") defaultOn:NO];
	NSButton *defaultRow = [self checkboxWithKey:HWG_PRINTER_NOTIFY_DEFAULT_KEY title:NSLocalizedString(@"Notify when the default printer changes", @"") defaultOn:NO];
	previous = newNotesHeader;
	gap = 10;
	for (NSButton *r in @[errorRow, defaultRow]) {
		[v addSubview:r];
		[NSLayoutConstraint activateConstraints:@[
			[r.topAnchor     constraintEqualToAnchor:previous.bottomAnchor constant:gap],
			[r.leadingAnchor  constraintEqualToAnchor:v.leadingAnchor constant:16],
			[r.heightAnchor   constraintEqualToConstant:24],
		]];
		previous = r;
		gap = 6;
	}

	NSTextField *errorCaption = [NSTextField wrappingLabelWithString:
		NSLocalizedString(@"\"Needs attention\" is read from the printer's standard IPP state-reasons — a heuristic (any reason other than \"none\"), not a CUPS-specific guarantee of what's wrong.", @"")];
	errorCaption.textColor = [NSColor secondaryLabelColor];
	errorCaption.font = [NSFont systemFontOfSize:11];
	errorCaption.translatesAutoresizingMaskIntoConstraints = NO;
	errorCaption.preferredMaxLayoutWidth = 380;
	[v addSubview:errorCaption];
	[NSLayoutConstraint activateConstraints:@[
		[errorCaption.topAnchor     constraintEqualToAnchor:previous.bottomAnchor constant:8],
		[errorCaption.leadingAnchor  constraintEqualToAnchor:v.leadingAnchor constant:16],
		[errorCaption.trailingAnchor constraintLessThanOrEqualToAnchor:v.trailingAnchor constant:-16],
		[errorCaption.bottomAnchor constraintLessThanOrEqualToAnchor:v.bottomAnchor constant:-16],
	]];

	prefsView = v;
	return prefsView;
}

#pragma mark HWGrowlPluginNotifierProtocol

-(NSArray*)noteNames {
	return [NSArray arrayWithObjects:@"PrinterConnected", @"PrinterDisconnected", @"PrinterError", @"PrinterDefaultChanged", nil];
}
-(NSDictionary*)localizedNames {
	return [NSDictionary dictionaryWithObjectsAndKeys:NSLocalizedString(@"Printer Connected", @""), @"PrinterConnected",
			  NSLocalizedString(@"Printer Disconnected", @""), @"PrinterDisconnected",
			  NSLocalizedString(@"Printer Needs Attention", @""), @"PrinterError",
			  NSLocalizedString(@"Default Printer Changed", @""), @"PrinterDefaultChanged", nil];
}
-(NSDictionary*)noteDescriptions {
	return [NSDictionary dictionaryWithObjectsAndKeys:NSLocalizedString(@"Sent when a printer is added to the system (F34)", @""), @"PrinterConnected",
			  NSLocalizedString(@"Sent when a printer is removed from the system (F34)", @""), @"PrinterDisconnected",
			  NSLocalizedString(@"Sent when a printer's state indicates a problem (out of paper/toner, jammed, offline…), and when it clears", @""), @"PrinterError",
			  NSLocalizedString(@"Sent when the system's default printer changes", @""), @"PrinterDefaultChanged", nil];
}
-(NSArray*)defaultNotifications {
	return [NSArray array];
}

@end
