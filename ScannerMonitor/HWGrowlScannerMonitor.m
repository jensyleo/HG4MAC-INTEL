//
//  HWGrowlScannerMonitor.m
//  HardwareGrowler
//
//  Detects NETWORK scanners (not USB — USB scanner detection already exists in USBMonitor) via
//  Bonjour/mDNS service discovery for `_scanner._tcp` (generic network scanner / WSD) and
//  `_uscan._tcp` (eSCL/AirScan). Uses NSNetServiceBrowser rather than any lower-level DNS-SD API
//  since it's already available via Foundation with no new framework/link dependency.
//
//  This is the FIRST feature in this app to request macOS's Local Network permission (via
//  NSBonjourServices + NSLocalNetworkUsageDescription in the main app's Info.plist) — a prompt
//  the app has never triggered before. To keep that blast radius as small as possible: OFF by
//  default (browsing never starts until the user opts in from Preferences), and starting/
//  stopping the two NSNetServiceBrowsers is the ONLY thing the enable checkbox controls.

// compile with ARC: -fobjc-arc
#import "HWGrowlScannerMonitor.h"
#import "HWGIconOverrideStore.h"
#import "HWGIconPickerView.h"

#define HWG_SCANNER_NOTIFY_KEY @"HWGScannerNotifyEnabled"

static BOOL HWGScannerBoolForKey(NSString *key, BOOL def) {
	id stored = [[NSUserDefaults standardUserDefaults] objectForKey:key];
	return stored ? [stored boolValue] : def;
}

@interface HWGrowlScannerMonitor () <NSNetServiceBrowserDelegate>

@property (nonatomic, weak) id<HWGrowlPluginControllerProtocol> delegate;
@property (nonatomic, strong) NSView *prefsView;

// One browser per service type — `_scanner._tcp` (generic network scanner / WSD) and
// `_uscan._tcp` (eSCL/AirScan), both domain "local." per the task's Bonjour usage description.
@property (nonatomic, strong) NSNetServiceBrowser *scannerTCPBrowser;
@property (nonatomic, strong) NSNetServiceBrowser *uscanBrowser;

// Keeps a strong reference to every currently-known NSNetService so it isn't deallocated while
// still resolving/being tracked (NSNetServiceBrowser does not retain them for you), keyed by a
// browser-qualified name so `_scanner._tcp` and `_uscan._tcp` never collide if the same device
// advertises both.
@property (nonatomic, strong) NSMutableDictionary<NSString*, NSNetService*> *knownServices;

@end

@implementation HWGrowlScannerMonitor

@synthesize delegate;
@synthesize prefsView;

-(id)init {
	if ((self = [super init])) {
		self.knownServices = [NSMutableDictionary dictionary];
		[self updateBrowsingState];
	}
	return self;
}

-(void)dealloc {
	[self stopBrowsing];
}

-(void)updateBrowsingState {
	BOOL enabled = HWGScannerBoolForKey(HWG_SCANNER_NOTIFY_KEY, NO);
	if (enabled) {
		[self startBrowsing];
	} else {
		[self stopBrowsing];
	}
}

-(void)startBrowsing {
	if (!_scannerTCPBrowser) {
		self.scannerTCPBrowser = [[NSNetServiceBrowser alloc] init];
		_scannerTCPBrowser.delegate = self;
		[_scannerTCPBrowser searchForServicesOfType:@"_scanner._tcp." inDomain:@"local."];
	}
	if (!_uscanBrowser) {
		self.uscanBrowser = [[NSNetServiceBrowser alloc] init];
		_uscanBrowser.delegate = self;
		[_uscanBrowser searchForServicesOfType:@"_uscan._tcp." inDomain:@"local."];
	}
}

-(void)stopBrowsing {
	[_scannerTCPBrowser stop];
	[_uscanBrowser stop];
	self.scannerTCPBrowser = nil;
	self.uscanBrowser = nil;
	[self.knownServices removeAllObjects];
}

// Distinguishes the same device name advertised over both service types.
-(NSString *)keyForService:(NSNetService*)service {
	return [NSString stringWithFormat:@"%@|%@", service.type, service.name];
}

#pragma mark NSNetServiceBrowserDelegate

-(void)netServiceBrowser:(NSNetServiceBrowser *)browser didFindService:(NSNetService *)service moreComing:(BOOL)moreComing {
	NSString *key = [self keyForService:service];
	self.knownServices[key] = service;

	NSData *iconData = [[HWGrowlScannerMonitor scannerIcon] TIFFRepresentation];
	[delegate notifyWithName:@"ScannerFound"
							 title:NSLocalizedString(@"Network Scanner Found", @"")
					 description:service.name
							  icon:iconData
			  identifierString:[NSString stringWithFormat:@"HWGrowlScanner-%@", key]
				  contextString:nil
							plugin:self];
}

-(void)netServiceBrowser:(NSNetServiceBrowser *)browser didRemoveService:(NSNetService *)service moreComing:(BOOL)moreComing {
	NSString *key = [self keyForService:service];
	[self.knownServices removeObjectForKey:key];

	NSData *iconData = [[HWGrowlScannerMonitor scannerIcon] TIFFRepresentation];
	[delegate notifyWithName:@"ScannerLost"
							 title:NSLocalizedString(@"Network Scanner Lost", @"")
					 description:service.name
							  icon:iconData
			  identifierString:[NSString stringWithFormat:@"HWGrowlScanner-%@", key]
				  contextString:nil
							plugin:self];
}

#pragma mark Icon

// Reuses the existing "USB-TypeScanner" asset (Assets.xcassets) rather than drawing new
// artwork — this monitor detects the same kind of device (a scanner), just discovered over
// the network instead of USB, so the same glyph reads correctly for both the notification icon
// and the module/sidebar icon. A dedicated network-specific icon can be a follow-up.
+(NSImage *)scannerIcon {
	NSImage *override = [[HWGIconOverrideStore sharedStore] overrideImageForDefaultName:@"USB-TypeScanner"];
	return override ?: [NSImage imageNamed:@"USB-TypeScanner"];
}

#pragma mark HWGrowlPluginProtocol

-(NSString*)pluginDisplayName {
	return NSLocalizedString(@"Scanner Monitor", @"");
}
-(NSImage*)preferenceIcon {
	NSImage *override = [[HWGIconOverrideStore sharedStore] overrideImageForDefaultName:@"USB-TypeScanner"];
	return override ?: [NSImage imageNamed:@"USB-TypeScanner"];
}

-(IBAction)fieldToggleChanged:(NSButton*)sender {
	NSString *key = sender.identifier;
	if (!key) return;
	[[NSUserDefaults standardUserDefaults] setBool:(sender.state == NSControlStateValueOn) forKey:key];
	[self updateBrowsingState];
}

-(NSButton *)checkboxWithKey:(NSString *)key title:(NSString *)title defaultOn:(BOOL)defaultOn {
	NSButton *box = [NSButton checkboxWithTitle:title target:self action:@selector(fieldToggleChanged:)];
	box.identifier = key;
	box.state = HWGScannerBoolForKey(key, defaultOn) ? NSControlStateValueOn : NSControlStateValueOff;
	box.translatesAutoresizingMaskIntoConstraints = NO;
	return box;
}

-(NSView*)preferencePane {
	if (prefsView) return prefsView;

	NSTabView *tabs = [[NSTabView alloc] initWithFrame:NSMakeRect(0, 0, 560, 340)];
	tabs.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

	NSView *v = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 560, 340)];

	NSTextField *header = [NSTextField labelWithString:NSLocalizedString(@"Notification fields", @"")];
	header.font = [NSFont boldSystemFontOfSize:12];
	header.textColor = [NSColor secondaryLabelColor];
	header.translatesAutoresizingMaskIntoConstraints = NO;
	[v addSubview:header];
	[NSLayoutConstraint activateConstraints:@[
		[header.topAnchor     constraintEqualToAnchor:v.topAnchor constant:16],
		[header.leadingAnchor  constraintEqualToAnchor:v.leadingAnchor constant:16],
	]];

	// Brand-new capability requesting a brand-new macOS permission (Local Network) — OFF by
	// default, same as every other new monitor added to this app, but doubly important here
	// since this is the first feature that will ever trigger that specific system prompt.
	NSButton *row = [self checkboxWithKey:HWG_SCANNER_NOTIFY_KEY title:NSLocalizedString(@"Enable network scanner detection", @"") defaultOn:NO];
	[v addSubview:row];
	[NSLayoutConstraint activateConstraints:@[
		[row.topAnchor     constraintEqualToAnchor:header.bottomAnchor constant:10],
		[row.leadingAnchor  constraintEqualToAnchor:v.leadingAnchor constant:16],
		[row.heightAnchor   constraintEqualToConstant:24],
	]];

	NSTextField *caption = [NSTextField wrappingLabelWithString:
		NSLocalizedString(@"Detects scanners on your local network via Bonjour (_scanner._tcp and _uscan._tcp/eSCL-AirScan). Enabling this asks macOS for Local Network permission — a prompt this app has never shown before.", @"")];
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

	NSTabViewItem *generalItem = [[NSTabViewItem alloc] initWithIdentifier:@"general"];
	generalItem.label = NSLocalizedString(@"General", @"");
	generalItem.view = v;
	[tabs addTabViewItem:generalItem];

	// --- Tab: Icons ---
	CGFloat iconsPad = 16;
	CGFloat iconsWidth = 560 - 2 * iconsPad;
	HWGIconPickerView *iconPicker = [[HWGIconPickerView alloc] initWithIconSpecs:@[
		@[@"Module Icon (Sidebar)", @"USB-TypeScanner"],
		@[@"Scanner Found/Lost", @"USB-TypeScanner"],
	]];
	iconPicker.translatesAutoresizingMaskIntoConstraints = YES;
	iconPicker.frame = NSMakeRect(0, 0, iconsWidth, 0);
	CGFloat iconPickerH = iconPicker.fittingSize.height;

	NSTextField *iconsHeader = [NSTextField labelWithString:NSLocalizedString(@"Notification icons", @"")];
	iconsHeader.font = [NSFont boldSystemFontOfSize:12];
	iconsHeader.textColor = [NSColor secondaryLabelColor];
	iconsHeader.translatesAutoresizingMaskIntoConstraints = YES;
	CGFloat iconsHeaderH = iconsHeader.fittingSize.height;
	CGFloat iconsGap = 12;

	NSView *iconsContent = [[HWGFlippedContentView alloc] initWithFrame:NSMakeRect(0, 0, 560, iconsHeaderH + iconsGap + iconPickerH + 2 * iconsPad)];
	iconsHeader.frame = NSMakeRect(iconsPad, iconsPad, iconsWidth, iconsHeaderH);
	[iconsContent addSubview:iconsHeader];
	iconPicker.frame = NSMakeRect(iconsPad, iconsPad + iconsHeaderH + iconsGap, iconsWidth, iconPickerH);
	[iconsContent addSubview:iconPicker];

	NSScrollView *iconsScroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 560, 120)];
	iconsScroll.hasVerticalScroller = YES;
	iconsScroll.autohidesScrollers = YES;
	iconsScroll.drawsBackground = NO;
	iconsScroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
	iconsScroll.documentView = iconsContent;

	NSTabViewItem *iconsItem = [[NSTabViewItem alloc] initWithIdentifier:@"icons"];
	iconsItem.label = NSLocalizedString(@"Icons", @"");
	iconsItem.view = iconsScroll;
	[tabs addTabViewItem:iconsItem];

	prefsView = tabs;
	return prefsView;
}

#pragma mark HWGrowlPluginNotifierProtocol

-(NSArray*)noteNames {
	return [NSArray arrayWithObjects:@"ScannerFound", @"ScannerLost", nil];
}
-(NSDictionary*)localizedNames {
	return [NSDictionary dictionaryWithObjectsAndKeys:NSLocalizedString(@"Network Scanner Found", @""), @"ScannerFound",
			  NSLocalizedString(@"Network Scanner Lost", @""), @"ScannerLost", nil];
}
-(NSDictionary*)noteDescriptions {
	return [NSDictionary dictionaryWithObjectsAndKeys:NSLocalizedString(@"Sent when a network scanner (Bonjour _scanner._tcp/_uscan._tcp) appears on the LAN", @""), @"ScannerFound",
			  NSLocalizedString(@"Sent when a previously-seen network scanner disappears from the LAN", @""), @"ScannerLost", nil];
}
-(NSArray*)defaultNotifications {
	return [NSArray array];
}

@end
