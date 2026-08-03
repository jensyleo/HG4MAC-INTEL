//
//  HWGIconPickerView.m
//  HardwareGrowler
//

// compile with ARC: -fobjc-arc
#import "HWGIconPickerView.h"
#import "HWGIconOverrideStore.h"
#import <CoreServices/CoreServices.h>

@implementation HWGFlippedContentView
- (BOOL)isFlipped { return YES; }
@end

@implementation HWGSystemIconCatalog

+ (NSArray<NSArray *> *)availableIcons {
	// Four-char OSTypes recognized by the legacy Icon Services generic-icon lookup —
	// see the header comment above for why this (rather than a UTType-based API) is the
	// only way to reach these particular system-drawn icons. kGenericWORMIcon/others
	// omitted here because they resolve to the same placeholder as a missing icon on
	// modern macOS, not a distinct picture — this list only includes ones confirmed
	// distinct.
	NSArray<NSArray *> *specs = @[
		@[NSLocalizedString(@"Hard Disk", @""), @(kGenericHardDiskIcon)],
		@[NSLocalizedString(@"Removable Media", @""), @(kGenericRemovableMediaIcon)],
		@[NSLocalizedString(@"CD/DVD", @""), @(kGenericCDROMIcon)],
		@[NSLocalizedString(@"Floppy Disk", @""), @(kGenericFloppyIcon)],
		@[NSLocalizedString(@"Network", @""), @(kGenericNetworkIcon)],
		@[NSLocalizedString(@"File Server", @""), @(kGenericFileServerIcon)],
		@[NSLocalizedString(@"PC Card", @""), @(kGenericPCCardIcon)],
		@[NSLocalizedString(@"RAM Disk", @""), @(kGenericRAMDiskIcon)],
	];

	NSMutableArray<NSArray *> *result = [NSMutableArray arrayWithCapacity:specs.count];
	for (NSArray *spec in specs) {
		NSString *label = spec[0];
		OSType code = (OSType)[spec[1] unsignedIntValue];
		NSString *fileType = NSFileTypeForHFSTypeCode(code);
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
		NSImage *image = [[NSWorkspace sharedWorkspace] iconForFileType:fileType];
#pragma clang diagnostic pop
		if (image) [result addObject:@[label, image]];
	}
	return result;
}

@end

// One tile in the "System Icon…" popover grid — carries the full-size system NSImage
// alongside the defaultName it should be applied to, so the click handler doesn't need
// a second lookup table.
@interface HWGSystemIconButton : NSButton
@property (nonatomic, copy) NSString *defaultName;
@property (nonatomic, strong) NSImage *catalogImage;
// Only used by the "From URL…" download button, to reach its sibling controls without
// a second lookup table.
@property (nonatomic, weak) NSTextField *urlField;
@property (nonatomic, weak) NSTextField *statusLabel;
@end
@implementation HWGSystemIconButton @end

@interface HWGIconPickerRow : NSObject
@property (nonatomic, copy) NSString *defaultName;
@property (nonatomic, weak) NSImageView *imageView;
@property (nonatomic, weak) NSButton *resetButton;
// Persistent anchor for the "Custom" sub-menu popover and its "From URL…" follow-up —
// unlike buttons living INSIDE a popover's own content view, this one never gets torn
// down when a popover closes, so it's always safe to re-anchor a new popover to it.
@property (nonatomic, weak) NSButton *changeButton;
@property (nonatomic, weak) NSButton *urlButton;
@end
@implementation HWGIconPickerRow @end

static BOOL HWGIconPickerNotifyBoolForKey(NSString *key, BOOL def) {
	id stored = [[NSUserDefaults standardUserDefaults] objectForKey:key];
	return stored ? [stored boolValue] : def;
}

@interface HWGIconPickerView ()
@property (nonatomic, strong) NSArray<HWGIconPickerRow *> *rows;
@property (nonatomic, strong) NSPopover *activeSystemIconPopover;
@end

@implementation HWGIconPickerView

- (instancetype)initWithIconSpecs:(NSArray<NSArray *> *)iconSpecs {
	self = [super initWithFrame:NSZeroRect];
	if (self) {
		self.translatesAutoresizingMaskIntoConstraints = NO;
		[self buildWithIconSpecs:iconSpecs];
	}
	return self;
}

// Handler for every row's "Notify?" checkbox — `identifier` carries the NSUserDefaults key
// (set per-row in `buildWithIconSpecs:` below), same pattern each monitor's own General-tab
// checkboxes already use.
- (void)notifyToggleChanged:(NSButton *)sender {
	NSString *key = sender.identifier;
	if (!key) return;
	[[NSUserDefaults standardUserDefaults] setBool:(sender.state == NSControlStateValueOn) forKey:key];
}

- (void)buildWithIconSpecs:(NSArray<NSArray *> *)iconSpecs {
	NSTextField *header = [NSTextField labelWithString:NSLocalizedString(@"Icons", @"")];
	header.font = [NSFont boldSystemFontOfSize:12];
	header.textColor = [NSColor secondaryLabelColor];
	header.translatesAutoresizingMaskIntoConstraints = NO;
	[self addSubview:header];

	NSMutableArray<HWGIconPickerRow *> *rows = [NSMutableArray array];
	NSView *previous = header;

	// Name column width: sized to the widest label actually in THIS picker's list, not a
	// single constant shared by every monitor — some monitors' labels are short single words
	// ("Mouse", "Speaker") while others (Volume's "External Disk (Unmounted)") are much
	// longer. A fixed 150pt fit the short lists but truncated the long ones; measuring here
	// keeps every row's button columns aligned (they all still share this one width) while
	// guaranteeing no label ever needs the "…"/tooltip fallback.
	CGFloat nameColumnWidth = 150;
	for (NSArray *spec in iconSpecs) {
		// Measure with an actual NSTextField (not NSString sizeWithAttributes:), then read its
		// real -intrinsicContentSize — the two didn't agree closely enough in practice ("Other
		// Interface Connected/Disconnected" in Network Monitor still got truncated with "…"
		// even after bumping the NSString-based safety margin from +4 to +16). Building the
		// same kind of label this row will actually use and asking IT for its size sidesteps
		// whatever gap causes the mismatch — plus a small +6 margin for a bit of breathing room.
		NSTextField *measuringField = [NSTextField labelWithString:spec[0]];
		// +24 margin — generous on purpose. A real Retina display can measure/render text
		// slightly wider than this headless-style measurement predicts; a few points of unused
		// trailing space in a name column is invisible, but truncating the longest label isn't.
		CGFloat needed = ceil(measuringField.intrinsicContentSize.width) + 24;
		if (needed > nameColumnWidth) nameColumnWidth = needed;
	}

	for (NSArray *spec in iconSpecs) {
		NSString *label = spec[0];
		NSString *defaultName = spec[1];

		NSImageView *imageView = [NSImageView new];
		imageView.translatesAutoresizingMaskIntoConstraints = NO;
		imageView.image = HWGResolveIconNamed(defaultName);
		imageView.imageScaling = NSImageScaleProportionallyUpOrDown;

		NSTextField *nameField = [NSTextField labelWithString:label];
		nameField.translatesAutoresizingMaskIntoConstraints = NO;
		nameField.lineBreakMode = NSLineBreakByTruncatingTail;
		nameField.toolTip = label; // safety net only — the column is now sized to fit every label in full

		NSButton *changeButton = [NSButton buttonWithTitle:NSLocalizedString(@"Custom", @"") target:self action:@selector(changeButtonClicked:)];
		changeButton.translatesAutoresizingMaskIntoConstraints = NO;
		changeButton.identifier = defaultName;
		changeButton.toolTip = NSLocalizedString(@"Choose an image file", @"");

		NSButton *systemIconButton = [NSButton buttonWithTitle:NSLocalizedString(@"System", @"") target:self action:@selector(systemIconButtonClicked:)];
		systemIconButton.translatesAutoresizingMaskIntoConstraints = NO;
		systemIconButton.identifier = defaultName;
		systemIconButton.toolTip = NSLocalizedString(@"Choose a macOS system icon", @"");

		NSButton *urlButton = [NSButton buttonWithTitle:NSLocalizedString(@"URL", @"") target:self action:@selector(fromURLClicked:)];
		urlButton.translatesAutoresizingMaskIntoConstraints = NO;
		urlButton.identifier = defaultName;
		urlButton.toolTip = NSLocalizedString(@"Download an icon from an image URL", @"");

		NSButton *resetButton = [NSButton buttonWithTitle:NSLocalizedString(@"Reset", @"") target:self action:@selector(resetButtonClicked:)];
		resetButton.translatesAutoresizingMaskIntoConstraints = NO;
		resetButton.identifier = defaultName;
		resetButton.enabled = [[HWGIconOverrideStore sharedStore] hasOverrideForDefaultName:defaultName];

		// "Notify?" column — always created so every row has the exact same subview/constraint
		// structure (no per-row branching that could make Auto Layout treat rows differently);
		// simply hidden for rows whose spec has no 3rd element (Module Icon/Connected/
		// Disconnected — not a distinct notification event).
		NSString *notifyKey = (spec.count > 2) ? spec[2] : nil;
		BOOL notifyDefaultOn = (spec.count > 3) ? [spec[3] boolValue] : YES;
		NSButton *notifyBox = [NSButton checkboxWithTitle:@"" target:self action:@selector(notifyToggleChanged:)];
		notifyBox.translatesAutoresizingMaskIntoConstraints = NO;
		if (notifyKey) {
			notifyBox.identifier = notifyKey;
			notifyBox.state = HWGIconPickerNotifyBoolForKey(notifyKey, notifyDefaultOn) ? NSControlStateValueOn : NSControlStateValueOff;
			notifyBox.toolTip = NSLocalizedString(@"Notify for this event", @"");
		} else {
			notifyBox.hidden = YES;
			notifyBox.enabled = NO;
		}
		[self addSubview:notifyBox];

		HWGIconPickerRow *row = [HWGIconPickerRow new];
		row.defaultName = defaultName;
		row.imageView = imageView;
		row.resetButton = resetButton;
		row.changeButton = changeButton;
		row.urlButton = urlButton;
		[rows addObject:row];

		[self addSubview:imageView];
		[self addSubview:nameField];
		[self addSubview:changeButton];
		[self addSubview:systemIconButton];
		[self addSubview:urlButton];
		[self addSubview:resetButton];

		[NSLayoutConstraint activateConstraints:@[
			[imageView.topAnchor constraintEqualToAnchor:previous.bottomAnchor constant:previous == header ? 10 : 12],
			[imageView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
			[imageView.widthAnchor constraintEqualToConstant:32],
			[imageView.heightAnchor constraintEqualToConstant:32],

			[nameField.centerYAnchor constraintEqualToAnchor:imageView.centerYAnchor],
			[nameField.leadingAnchor constraintEqualToAnchor:imageView.trailingAnchor constant:10],
			[nameField.widthAnchor constraintEqualToConstant:nameColumnWidth],

			// Fixed-width name column + fixed-width, equally-spaced buttons — every row's
			// button block now starts at the exact same x and each column lines up
			// vertically across every row (previously each button's leading edge depended
			// on that row's own label's natural width, which varied per row and made the
			// columns look staggered/disordered). Every monitor's tab width was widened
			// (28-jul-2026) specifically so these columns are wide enough to show every
			// label/button in full — no more mid-word truncation anywhere.
			[changeButton.centerYAnchor constraintEqualToAnchor:imageView.centerYAnchor],
			[changeButton.leadingAnchor constraintEqualToAnchor:nameField.trailingAnchor constant:10],
			[changeButton.widthAnchor constraintEqualToConstant:70],

			[systemIconButton.centerYAnchor constraintEqualToAnchor:imageView.centerYAnchor],
			[systemIconButton.leadingAnchor constraintEqualToAnchor:changeButton.trailingAnchor constant:8],
			[systemIconButton.widthAnchor constraintEqualToAnchor:changeButton.widthAnchor],

			[urlButton.centerYAnchor constraintEqualToAnchor:imageView.centerYAnchor],
			[urlButton.leadingAnchor constraintEqualToAnchor:systemIconButton.trailingAnchor constant:8],
			[urlButton.widthAnchor constraintEqualToAnchor:changeButton.widthAnchor],

			[resetButton.centerYAnchor constraintEqualToAnchor:imageView.centerYAnchor],
			[resetButton.leadingAnchor constraintEqualToAnchor:urlButton.trailingAnchor constant:8],
			[resetButton.widthAnchor constraintEqualToAnchor:changeButton.widthAnchor],
		]];

		[NSLayoutConstraint activateConstraints:@[
			[notifyBox.centerYAnchor constraintEqualToAnchor:imageView.centerYAnchor],
			[notifyBox.leadingAnchor constraintEqualToAnchor:resetButton.trailingAnchor constant:16],
			[notifyBox.trailingAnchor constraintLessThanOrEqualToAnchor:self.trailingAnchor],
		]];

		previous = imageView;
	}

	[NSLayoutConstraint activateConstraints:@[
		[header.topAnchor constraintEqualToAnchor:self.topAnchor],
		[header.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
		[previous.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
	]];

	self.rows = rows;
}

- (HWGIconPickerRow *)rowForDefaultName:(NSString *)defaultName {
	for (HWGIconPickerRow *row in self.rows) {
		if ([row.defaultName isEqualToString:defaultName]) return row;
	}
	return nil;
}

- (void)changeButtonClicked:(NSButton *)sender {
	NSString *defaultName = sender.identifier;
	if (![defaultName length]) return;

	NSOpenPanel *panel = [NSOpenPanel openPanel];
	panel.allowsMultipleSelection = NO;
	panel.canChooseDirectories = NO;
	panel.canChooseFiles = YES;
	panel.title = NSLocalizedString(@"Choose Icon Image", @"");

	[panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse result) {
		if (result != NSModalResponseOK) return;
		NSURL *url = panel.URLs.firstObject;
		if (!url) return;
		NSImage *image = [[NSImage alloc] initWithContentsOfURL:url];
		if (!image) return; // not a decodable image — silently ignore rather than guessing a UTType-based filter

		[[HWGIconOverrideStore sharedStore] setOverrideImage:image forDefaultName:defaultName];

		HWGIconPickerRow *row = [self rowForDefaultName:defaultName];
		row.imageView.image = HWGResolveIconNamed(defaultName);
		row.resetButton.enabled = YES;
	}];
}

// Fase C: paste a direct image URL instead of picking a local file — e.g. a product
// photo the user already found on a manufacturer's site. Downloads on demand only
// (no background/automatic lookups, no search — the user supplies the exact URL),
// decodes, and runs through the same normalization/override pipeline as every other
// source.
- (void)fromURLClicked:(NSButton *)sender {
	NSString *defaultName = sender.identifier;
	if (![defaultName length]) return;
	NSButton *anchor = sender; // "URL" is its own persistent row button now, safe to anchor to directly

	NSView *content = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 320, 92)];

	NSTextField *label = [NSTextField labelWithString:NSLocalizedString(@"Image URL:", @"")];
	label.translatesAutoresizingMaskIntoConstraints = NO;

	NSTextField *urlField = [NSTextField new];
	urlField.translatesAutoresizingMaskIntoConstraints = NO;
	urlField.placeholderString = @"https://example.com/icon.png";

	NSTextField *statusLabel = [NSTextField labelWithString:@""];
	statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
	statusLabel.font = [NSFont systemFontOfSize:11];
	statusLabel.textColor = [NSColor secondaryLabelColor];

	HWGSystemIconButton *downloadButton = [HWGSystemIconButton buttonWithTitle:NSLocalizedString(@"Download", @"") target:self action:@selector(urlDownloadClicked:)];
	downloadButton.defaultName = defaultName;
	downloadButton.translatesAutoresizingMaskIntoConstraints = NO;
	downloadButton.urlField = urlField;
	downloadButton.statusLabel = statusLabel;

	[content addSubview:label];
	[content addSubview:urlField];
	[content addSubview:statusLabel];
	[content addSubview:downloadButton];

	[NSLayoutConstraint activateConstraints:@[
		[label.topAnchor constraintEqualToAnchor:content.topAnchor constant:12],
		[label.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:12],

		[urlField.centerYAnchor constraintEqualToAnchor:label.centerYAnchor],
		[urlField.leadingAnchor constraintEqualToAnchor:label.trailingAnchor constant:8],
		[urlField.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-12],
		[urlField.widthAnchor constraintGreaterThanOrEqualToConstant:180],

		[downloadButton.topAnchor constraintEqualToAnchor:urlField.bottomAnchor constant:10],
		[downloadButton.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-12],

		[statusLabel.centerYAnchor constraintEqualToAnchor:downloadButton.centerYAnchor],
		[statusLabel.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:12],
		[statusLabel.trailingAnchor constraintLessThanOrEqualToAnchor:downloadButton.leadingAnchor constant:-8],
	]];

	NSPopover *popover = [NSPopover new];
	NSViewController *vc = [NSViewController new];
	vc.view = content;
	popover.contentViewController = vc;
	popover.behavior = NSPopoverBehaviorTransient;
	self.activeSystemIconPopover = popover;
	[popover showRelativeToRect:anchor.bounds ofView:anchor preferredEdge:NSMaxYEdge];
}

- (void)urlDownloadClicked:(HWGSystemIconButton *)sender {
	NSString *defaultName = sender.defaultName;
	NSString *urlString = [sender.urlField.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
	if (![defaultName length] || ![urlString length]) return;

	NSURL *url = [NSURL URLWithString:urlString];
	if (!url || !url.scheme || (![url.scheme.lowercaseString isEqualToString:@"https"] && ![url.scheme.lowercaseString isEqualToString:@"http"])) {
		sender.statusLabel.stringValue = NSLocalizedString(@"Enter a valid http(s) URL.", @"");
		return;
	}

	sender.enabled = NO;
	sender.statusLabel.stringValue = NSLocalizedString(@"Downloading…", @"");

	NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
		dispatch_async(dispatch_get_main_queue(), ^{
			NSImage *image = data ? [[NSImage alloc] initWithData:data] : nil;
			if (error || !image) {
				sender.statusLabel.stringValue = NSLocalizedString(@"Couldn't load an image from that URL.", @"");
				sender.enabled = YES;
				return;
			}

			[[HWGIconOverrideStore sharedStore] setOverrideImage:image forDefaultName:defaultName];

			HWGIconPickerRow *row = [self rowForDefaultName:defaultName];
			row.imageView.image = HWGResolveIconNamed(defaultName);
			row.resetButton.enabled = YES;

			[self.activeSystemIconPopover close];
			self.activeSystemIconPopover = nil;
		});
	}];
	[task resume];
}

- (void)systemIconButtonClicked:(NSButton *)sender {
	NSString *defaultName = sender.identifier;
	if (![defaultName length]) return;

	NSArray<NSArray *> *catalog = [HWGSystemIconCatalog availableIcons];
	if (![catalog count]) return;

	NSInteger columns = 4;
	CGFloat tileSize = 64, tilePad = 12;
	NSInteger rowCount = (catalog.count + columns - 1) / columns;
	CGFloat gridW = columns * tileSize + (columns + 1) * tilePad;
	CGFloat gridH = rowCount * (tileSize + 18) + (rowCount + 1) * tilePad;

	NSView *content = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, gridW, gridH)];
	for (NSUInteger i = 0; i < catalog.count; i++) {
		NSString *label = catalog[i][0];
		NSImage *image = catalog[i][1];
		NSInteger col = i % columns, row = i / columns;

		HWGSystemIconButton *tile = [HWGSystemIconButton buttonWithTitle:label target:self action:@selector(systemIconChosen:)];
		tile.defaultName = defaultName;
		tile.catalogImage = image;
		tile.image = image;
		tile.imagePosition = NSImageAbove;
		tile.bezelStyle = NSBezelStyleShadowlessSquare;
		tile.bordered = NO;
		tile.font = [NSFont systemFontOfSize:10];
		CGFloat x = tilePad + col * (tileSize + tilePad);
		CGFloat y = gridH - tilePad - (row + 1) * (tileSize + 18) - row * tilePad;
		tile.frame = NSMakeRect(x, y, tileSize, tileSize + 18);
		[content addSubview:tile];
	}

	NSPopover *popover = [NSPopover new];
	NSViewController *vc = [NSViewController new];
	vc.view = content;
	popover.contentViewController = vc;
	popover.behavior = NSPopoverBehaviorTransient;
	self.activeSystemIconPopover = popover;
	[popover showRelativeToRect:sender.bounds ofView:sender preferredEdge:NSMaxYEdge];
}

- (void)systemIconChosen:(HWGSystemIconButton *)sender {
	NSString *defaultName = sender.defaultName;
	if (![defaultName length] || !sender.catalogImage) return;

	[[HWGIconOverrideStore sharedStore] setOverrideImage:sender.catalogImage forDefaultName:defaultName];

	HWGIconPickerRow *row = [self rowForDefaultName:defaultName];
	row.imageView.image = HWGResolveIconNamed(defaultName);
	row.resetButton.enabled = YES;

	[self.activeSystemIconPopover close];
	self.activeSystemIconPopover = nil;
}

- (void)resetButtonClicked:(NSButton *)sender {
	NSString *defaultName = sender.identifier;
	if (![defaultName length]) return;

	[[HWGIconOverrideStore sharedStore] removeOverrideForDefaultName:defaultName];

	HWGIconPickerRow *row = [self rowForDefaultName:defaultName];
	row.imageView.image = HWGResolveIconNamed(defaultName);
	row.resetButton.enabled = NO;
}

@end
