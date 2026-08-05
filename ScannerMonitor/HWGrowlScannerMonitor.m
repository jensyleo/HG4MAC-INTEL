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
// Independent from HWG_SCANNER_NOTIFY_KEY above (which also controls whether browsing runs at
// all) — this only silences the notification itself while detection/state-tracking continues.
#define HWG_SCANNER_NOTIFY_FOUNDLOST_KEY @"HWGScannerNotifyFoundLost"

// #6 (05-ago-2026): scan job start/finish, via eSCL/AirScan's GET /eSCL/ScannerStatus — the
// same protocol _uscan._tcp already advertises (Mopria eSCL Technical Specification, publicly
// downloadable, free click-through license). Polls each resolved device's ScannerStatus
// endpoint for its <pwg:State> (Idle/Processing/Testing/Stopped) and diffs against the last
// known state to fire Started/Finished — same architecture as WiFi Monitor's signal poll.
// OFF by default: unlike Printer Job Status (CUPS, verified working end-to-end against a real
// test queue this session), this has NEVER been tested against a real network scanner —
// firmware compliance with ScannerStatus is known to vary significantly by vendor (per
// sane-airscan's own reason for existing), and some devices may only surface job completion
// via the per-job resource (GET /eSCL/ScanJobs/{id}) rather than the top-level status this
// polls. Ship it opt-in so it can be verified live once real hardware is available, same
// pattern as every other unverified-but-plausible feature in this app.
#define HWG_SCANNER_NOTIFY_SCANSTATUS_KEY @"HWGScannerNotifyScanStatus"
#define HWG_SCANNER_SCANSTATUS_POLL_KEY   @"HWGScannerScanStatusPollInterval"
#define HWG_SCANNER_SCANSTATUS_POLL_DEFAULT 10.0
#define HWG_SCANNER_SCANSTATUS_POLL_MIN     5.0
#define HWG_SCANNER_SCANSTATUS_POLL_MAX     60.0

static BOOL HWGScannerBoolForKey(NSString *key, BOOL def) {
	id stored = [[NSUserDefaults standardUserDefaults] objectForKey:key];
	return stored ? [stored boolValue] : def;
}

// Minimal eSCL ScannerStatus XML parser — pulls just the device-level <pwg:State> text
// (Idle/Processing/Testing/Stopped per the spec). Namespace processing deliberately left OFF
// (default), so elementName arrives as the raw qualified name ("pwg:State") — simpler than
// resolving the scan:/pwg: namespace URIs for a single field, and every real-world eSCL
// response uses these exact prefixes per the spec's own examples.
@interface HWGESCLStatusParser : NSObject <NSXMLParserDelegate>
@property (nonatomic, copy) NSString *deviceState;
@end
@implementation HWGESCLStatusParser {
	BOOL _inPwgState;
	NSMutableString *_buffer;
}
- (void)parser:(NSXMLParser *)parser didStartElement:(NSString *)elementName namespaceURI:(NSString *)namespaceURI qualifiedName:(NSString *)qName attributes:(NSDictionary<NSString *,NSString *> *)attributeDict {
	if ([elementName isEqualToString:@"pwg:State"]) {
		_inPwgState = YES;
		_buffer = [NSMutableString string];
	}
}
- (void)parser:(NSXMLParser *)parser foundCharacters:(NSString *)string {
	if (_inPwgState) [_buffer appendString:string];
}
- (void)parser:(NSXMLParser *)parser didEndElement:(NSString *)elementName namespaceURI:(NSString *)namespaceURI qualifiedName:(NSString *)qName {
	if ([elementName isEqualToString:@"pwg:State"] && _inPwgState) {
		self.deviceState = [_buffer stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
		_inPwgState = NO;
	}
}
@end

@interface HWGrowlScannerMonitor () <NSNetServiceBrowserDelegate, NSNetServiceDelegate>

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

// #6: scan job status. Resolved "host:port" per known service key (only devices that have
// actually resolved get polled — an unresolved service has nowhere to send a GET to).
@property (nonatomic, strong) NSMutableDictionary<NSString*, NSString*> *resolvedHostPortByKey;
// Last device-level <pwg:State> actually seen per key, so a poll only fires a notification on
// a real Idle<->Processing transition, not every tick. No entry yet = not seen/baselined.
@property (nonatomic, strong) NSMutableDictionary<NSString*, NSString*> *lastKnownScanStateByKey;
@property (nonatomic, strong) NSTimer *scanStatusPollTimer;

@end

@implementation HWGrowlScannerMonitor

@synthesize delegate;
@synthesize prefsView;

-(id)init {
	if ((self = [super init])) {
		self.knownServices = [NSMutableDictionary dictionary];
		self.resolvedHostPortByKey = [NSMutableDictionary dictionary];
		self.lastKnownScanStateByKey = [NSMutableDictionary dictionary];
		[self updateBrowsingState];
	}
	return self;
}

-(void)dealloc {
	[self stopBrowsing];
	[self stopScanStatusPolling];
}

-(void)updateBrowsingState {
	BOOL enabled = HWGScannerBoolForKey(HWG_SCANNER_NOTIFY_KEY, NO);
	if (enabled) {
		[self startBrowsing];
	} else {
		[self stopBrowsing];
	}
	[self updateScanStatusPollingState];
}

-(void)updateScanStatusPollingState {
	BOOL wantsPolling = HWGScannerBoolForKey(HWG_SCANNER_NOTIFY_KEY, NO) &&
	                    HWGScannerBoolForKey(HWG_SCANNER_NOTIFY_SCANSTATUS_KEY, NO);
	if (wantsPolling) {
		[self startScanStatusPolling];
	} else {
		[self stopScanStatusPolling];
	}
}

-(NSTimeInterval)scanStatusPollInterval {
	BOOL stored = [[NSUserDefaults standardUserDefaults] objectForKey:HWG_SCANNER_SCANSTATUS_POLL_KEY] != nil;
	NSTimeInterval v = stored ? [[NSUserDefaults standardUserDefaults] doubleForKey:HWG_SCANNER_SCANSTATUS_POLL_KEY] : HWG_SCANNER_SCANSTATUS_POLL_DEFAULT;
	if (v < HWG_SCANNER_SCANSTATUS_POLL_MIN) v = HWG_SCANNER_SCANSTATUS_POLL_MIN;
	if (v > HWG_SCANNER_SCANSTATUS_POLL_MAX) v = HWG_SCANNER_SCANSTATUS_POLL_MAX;
	return v;
}

-(void)startScanStatusPolling {
	if (self.scanStatusPollTimer) return;
	__weak typeof(self) weakSelf = self;
	self.scanStatusPollTimer = [NSTimer scheduledTimerWithTimeInterval:[self scanStatusPollInterval]
																repeats:YES
																  block:^(NSTimer * _Nonnull timer) {
		[weakSelf pollAllScanStatuses];
	}];
}

-(void)stopScanStatusPolling {
	[self.scanStatusPollTimer invalidate];
	self.scanStatusPollTimer = nil;
	[self.lastKnownScanStateByKey removeAllObjects];
}

-(void)pollAllScanStatuses {
	for (NSString *key in [self.resolvedHostPortByKey allKeys]) {
		NSString *hostPort = self.resolvedHostPortByKey[key];
		NSNetService *service = self.knownServices[key];
		if (!hostPort || !service) continue;
		[self pollScanStatusForKey:key hostPort:hostPort deviceName:service.name];
	}
}

-(void)pollScanStatusForKey:(NSString *)key hostPort:(NSString *)hostPort deviceName:(NSString *)deviceName {
	NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"http://%@/eSCL/ScannerStatus", hostPort]];
	if (!url) return;
	__weak typeof(self) weakSelf = self;
	NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
		if (!data || error) return;   // device offline/unreachable this tick — silently skip, try again next poll
		HWGESCLStatusParser *parser = [HWGESCLStatusParser new];
		NSXMLParser *xmlParser = [[NSXMLParser alloc] initWithData:data];
		xmlParser.delegate = parser;
		if (![xmlParser parse] || ![parser.deviceState length]) return;   // unparseable/unexpected shape — skip rather than guess
		dispatch_async(dispatch_get_main_queue(), ^{
			[weakSelf handleScanState:parser.deviceState forKey:key deviceName:deviceName];
		});
	}];
	[task resume];
}

// Diffs against the last known state and fires Started/Finished only on the real transition —
// same baseline-then-diff pattern every other monitor in this app uses. "Processing" is the
// only in-progress value the eSCL spec defines besides Idle/Testing/Stopped; treated as
// "scanning", everything else as "not scanning".
-(void)handleScanState:(NSString *)newState forKey:(NSString *)key deviceName:(NSString *)deviceName {
	NSString *previousState = self.lastKnownScanStateByKey[key];
	self.lastKnownScanStateByKey[key] = newState;
	if (!previousState) return;   // first sighting for this device — baseline only, no notification

	BOOL wasScanning = [previousState isEqualToString:@"Processing"];
	BOOL isScanning  = [newState isEqualToString:@"Processing"];
	if (wasScanning == isScanning) return;

	NSData *iconData = [[HWGrowlScannerMonitor scannerIcon] TIFFRepresentation];
	[delegate notifyWithName:@"ScannerScanStatus"
							 title:isScanning ? NSLocalizedString(@"Scan Started", @"") : NSLocalizedString(@"Scan Finished", @"")
					 description:deviceName
							  icon:iconData
			  identifierString:[NSString stringWithFormat:@"HWGrowlScannerScanStatus-%@-%@", key, isScanning ? @"started" : @"finished"]
				  contextString:nil
							plugin:self];
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
	service.delegate = self;
	[service resolveWithTimeout:5.0];

	if (!HWGScannerBoolForKey(HWG_SCANNER_NOTIFY_FOUNDLOST_KEY, YES)) return;
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
	[self.resolvedHostPortByKey removeObjectForKey:key];
	[self.lastKnownScanStateByKey removeObjectForKey:key];

	if (!HWGScannerBoolForKey(HWG_SCANNER_NOTIFY_FOUNDLOST_KEY, YES)) return;
	NSData *iconData = [[HWGrowlScannerMonitor scannerIcon] TIFFRepresentation];
	[delegate notifyWithName:@"ScannerLost"
							 title:NSLocalizedString(@"Network Scanner Lost", @"")
					 description:service.name
							  icon:iconData
			  identifierString:[NSString stringWithFormat:@"HWGrowlScanner-%@", key]
				  contextString:nil
							plugin:self];
}

#pragma mark NSNetServiceDelegate

// #6: captures host:port once Bonjour resolves the service, so scan-status polling has
// somewhere to send its GET. hostName sometimes arrives with a trailing "." (DNS root label) —
// harmless for URLWithString: but stripped here for a cleaner host string regardless.
-(void)netServiceDidResolveAddress:(NSNetService *)sender {
	NSString *key = [self keyForService:sender];
	if (![self.knownServices objectForKey:key]) return;   // already removed before resolution finished
	NSString *host = sender.hostName;
	if ([host hasSuffix:@"."]) host = [host substringToIndex:host.length - 1];
	if (![host length] || sender.port <= 0) return;
	self.resolvedHostPortByKey[key] = [NSString stringWithFormat:@"%@:%ld", host, (long)sender.port];
}

-(void)netService:(NSNetService *)sender didNotResolve:(NSDictionary<NSString *, NSNumber *> *)errorDict {
	// Leave it unresolved — this device just doesn't get polled for scan status until (if
	// ever) a future resolve attempt succeeds; ScannerFound/Lost detection is unaffected.
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

	// #6: scan start/finish — OFF by default (see the feature's own doc comment above for why:
	// never verified against a real network scanner yet, unlike Printer Job Status).
	NSButton *scanStatusRow = [self checkboxWithKey:HWG_SCANNER_NOTIFY_SCANSTATUS_KEY title:NSLocalizedString(@"Notify when a scan starts/finishes (experimental)", @"") defaultOn:NO];
	[v addSubview:scanStatusRow];
	[NSLayoutConstraint activateConstraints:@[
		[scanStatusRow.topAnchor     constraintEqualToAnchor:caption.bottomAnchor constant:14],
		[scanStatusRow.leadingAnchor  constraintEqualToAnchor:v.leadingAnchor constant:16],
		[scanStatusRow.heightAnchor   constraintEqualToConstant:24],
	]];

	NSTextField *scanStatusCaption = [NSTextField wrappingLabelWithString:
		NSLocalizedString(@"Polls each scanner's eSCL status over the network to detect scan start/finish. Not yet verified against a real network scanner — firmware support for this varies by manufacturer.", @"")];
	scanStatusCaption.textColor = [NSColor secondaryLabelColor];
	scanStatusCaption.font = [NSFont systemFontOfSize:11];
	scanStatusCaption.translatesAutoresizingMaskIntoConstraints = NO;
	scanStatusCaption.preferredMaxLayoutWidth = 380;
	[v addSubview:scanStatusCaption];
	[NSLayoutConstraint activateConstraints:@[
		[scanStatusCaption.topAnchor     constraintEqualToAnchor:scanStatusRow.bottomAnchor constant:8],
		[scanStatusCaption.leadingAnchor  constraintEqualToAnchor:v.leadingAnchor constant:16],
		[scanStatusCaption.trailingAnchor constraintLessThanOrEqualToAnchor:v.trailingAnchor constant:-16],
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
		@[@"Scanner Found/Lost", @"USB-TypeScanner", HWG_SCANNER_NOTIFY_FOUNDLOST_KEY],
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
	return [NSArray arrayWithObjects:@"ScannerFound", @"ScannerLost", @"ScannerScanStatus", nil];
}
-(NSDictionary*)localizedNames {
	return [NSDictionary dictionaryWithObjectsAndKeys:NSLocalizedString(@"Network Scanner Found", @""), @"ScannerFound",
			  NSLocalizedString(@"Network Scanner Lost", @""), @"ScannerLost",
			  NSLocalizedString(@"Scan Started/Finished", @""), @"ScannerScanStatus", nil];
}
-(NSDictionary*)noteDescriptions {
	return [NSDictionary dictionaryWithObjectsAndKeys:NSLocalizedString(@"Sent when a network scanner (Bonjour _scanner._tcp/_uscan._tcp) appears on the LAN", @""), @"ScannerFound",
			  NSLocalizedString(@"Sent when a previously-seen network scanner disappears from the LAN", @""), @"ScannerLost",
			  NSLocalizedString(@"Sent when a scan job starts or finishes (experimental, via eSCL ScannerStatus polling)", @""), @"ScannerScanStatus", nil];
}
-(NSArray*)defaultNotifications {
	return [NSArray array];
}

@end
