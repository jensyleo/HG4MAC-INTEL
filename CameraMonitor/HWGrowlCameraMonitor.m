//
//  HWGrowlCameraMonitor.m
//  HardwareGrowler
//

// compile with ARC: -fobjc-arc
#import "HWGrowlCameraMonitor.h"
#import "HWGIconOverrideStore.h"
#import "HWGIconPickerView.h"
#import <AVFoundation/AVFoundation.h>
#import <CoreAudio/CoreAudio.h>       // shares its transport-type FourCharCode space with AVCaptureDevice.transportType
#import <CoreMediaIO/CoreMediaIO.h>

// F19: same philosophy as Audio Monitor —
//   1. Connect/disconnect — only for transports NOT already covered by USB/Bluetooth Monitor
//      (AVCaptureDevice.transportType reuses the exact same FourCharCode constants as
//      CoreAudio's kAudioDeviceTransportType*, so the same comparison works verbatim).
//   2. An extra axis no other monitor has: whether the camera is ACTIVELY IN USE by any app
//      right now (kCMIODevicePropertyDeviceIsRunningSomewhere via CoreMediaIO) — a genuine
//      privacy-relevant signal, the same fact macOS's own green/orange camera-in-use
//      indicator dot reflects. Reading this property does NOT require camera/TCC
//      permission — it's hardware-state observation, not frame capture (the same technique
//      used by camera-privacy-watchdog utilities).

#define HWG_CAMERA_SHOW_TRANSPORT_KEY   @"HWGCameraShowTransport"
#define HWG_CAMERA_NOTIFY_CONNECT_KEY   @"HWGCameraNotifyConnect"
#define HWG_CAMERA_NOTIFY_IN_USE_KEY    @"HWGCameraNotifyInUse"
// Per-row refinement on top of HWG_CAMERA_NOTIFY_IN_USE_KEY above (the master "In Use" toggle):
// lets the user silence just one direction (e.g. keep "started" but not "stopped").
#define HWG_CAMERA_NOTIFY_INUSE_ROW_KEY @"HWGCameraNotifyInUseRow"
#define HWG_CAMERA_NOTIFY_IDLE_ROW_KEY  @"HWGCameraNotifyIdleRow"

static BOOL HWGCameraBoolForKey(NSString *key, BOOL def) {
	id stored = [[NSUserDefaults standardUserDefaults] objectForKey:key];
	return stored ? [stored boolValue] : def;
}

@interface HWGrowlCameraMonitor ()

@property (nonatomic, weak) id<HWGrowlPluginControllerProtocol> delegate;
@property (nonatomic, strong) NSView *prefsView;
@property (nonatomic, strong) NSMutableSet<NSString *> *runningCameraUIDs;   // cameras currently "in use" (any app)
// MUST be `copy`, not `assign` — `assign` doesn't trigger ARC's copy-to-heap for block
// literals, so the block stays STACK-allocated and becomes a dangling pointer the moment
// -init's stack frame returns. Every later use (any subsequent CMIOObjectAddPropertyListenerBlock/
// RemovePropertyListenerBlock call passing this property) then reads freed/garbage memory —
// this was the real cause of the SIGSEGV inside CMIO's internal `_Block_copy` (confirmed via
// crash log, 22-jul-2026: crashed on a plain CONNECT event, not just disconnect, ruling out
// the earlier reentrancy theory as the sole cause — a dangling block pointer explains
// crashing unpredictably on ANY subsequent listener add/remove, regardless of connect vs
// disconnect).
@property (nonatomic, copy) CMIOObjectPropertyListenerBlock inUseListenerBlock;
@property (nonatomic, copy) CMIOObjectPropertyListenerBlock deviceListChangedBlock;
// CMIODeviceIDs that currently have an -inUseListenerBlock attached — tracked explicitly so
// -unregisterInUseListeners removes listeners from the exact IDs they were added to, not
// whatever -allCMIODeviceIDs happens to return NOW (which, when called from the device-list-
// changed callback itself, may already reflect devices that just appeared/disappeared).
@property (nonatomic, strong) NSMutableSet<NSNumber *> *deviceIDsWithInUseListener;

@end

@implementation HWGrowlCameraMonitor

@synthesize delegate;
@synthesize prefsView;
@synthesize runningCameraUIDs;
@synthesize inUseListenerBlock;
@synthesize deviceListChangedBlock;
@synthesize deviceIDsWithInUseListener;

-(id)init {
	self = [super init];
	if (self) {
		runningCameraUIDs = [NSMutableSet set];
		deviceIDsWithInUseListener = [NSMutableSet set];

		[[NSNotificationCenter defaultCenter] addObserver:self
												  selector:@selector(deviceConnected:)
													  name:AVCaptureDeviceWasConnectedNotification
													object:nil];
		[[NSNotificationCenter defaultCenter] addObserver:self
												  selector:@selector(deviceDisconnected:)
													  name:AVCaptureDeviceWasDisconnectedNotification
													object:nil];

		// Baseline the "in use" state silently at launch, then start listening for changes —
		// same "no notification for the pre-existing state" convention every other monitor
		// follows.
		[self refreshRunningStateForAllDevicesNotifying:NO];
		[self registerInUseListeners];

		// -registerInUseListeners only attaches to CMIODeviceIDs that exist AT THIS MOMENT.
		// A camera plugged in AFTER launch gets a CMIODeviceID that was never in that list, so
		// it would silently never fire "in use" changes — confirmed live (19-jul-2026): a USB
		// webcam connected mid-session correctly reported Connected/Disconnected (that's
		// AVCaptureDevice's own notification, always current) but never "Started/Stopped
		// Being Used" (the CMIO listener, which had nothing attached to its ID). Listening for
		// the CMIO device LIST to change and re-registering closes that gap.
		__weak typeof(self) weakSelf = self;
		deviceListChangedBlock = ^(UInt32 n, const CMIOObjectPropertyAddress *addrs) {
			(void)n; (void)addrs;
			// CRASH FIX (confirmed via crash log, 22-jul-2026): calling
			// CMIOObjectRemovePropertyListenerBlock synchronously from INSIDE the CMIO device-
			// list-changed callback itself is an unsafe reentrant call into CoreMediaIO's
			// internal DAL (crashed in CMIO::DAL::PropertyListener::PropertyListener via
			// _Block_copy, SIGSEGV) — happened specifically when a camera was disconnected,
			// i.e. exactly the moment its CMIODeviceID becomes stale. Deferring to the next
			// run-loop turn via dispatch_async lets CMIO finish its own internal teardown
			// first, so we're no longer inside its call stack when we touch listeners.
			dispatch_async(dispatch_get_main_queue(), ^{
				[weakSelf unregisterInUseListeners];
				[weakSelf registerInUseListeners];
				[weakSelf refreshRunningStateForAllDevicesNotifying:YES];
			});
		};
		CMIOObjectPropertyAddress devicesAddress = { kCMIOHardwarePropertyDevices, kCMIOObjectPropertyScopeGlobal, kCMIOObjectPropertyElementMain };
		CMIOObjectAddPropertyListenerBlock(kCMIOObjectSystemObject, &devicesAddress, dispatch_get_main_queue(), deviceListChangedBlock);
	}
	return self;
}

-(void)dealloc {
	[[NSNotificationCenter defaultCenter] removeObserver:self];
	[self unregisterInUseListeners];
	if (deviceListChangedBlock) {
		CMIOObjectPropertyAddress devicesAddress = { kCMIOHardwarePropertyDevices, kCMIOObjectPropertyScopeGlobal, kCMIOObjectPropertyElementMain };
		CMIOObjectRemovePropertyListenerBlock(kCMIOObjectSystemObject, &devicesAddress, dispatch_get_main_queue(), deviceListChangedBlock);
	}
}

#pragma mark Transport filtering (shared logic/constants with Audio Monitor)

-(BOOL)transportAlreadyCoveredByAnotherMonitor:(int32_t)transport {
	return transport == kAudioDeviceTransportTypeUSB
		|| transport == kAudioDeviceTransportTypeBluetooth
		|| transport == kAudioDeviceTransportTypeBluetoothLE;
}

-(NSString *)labelForTransportType:(int32_t)transport {
	switch (transport) {
		case kAudioDeviceTransportTypeBuiltIn:      return NSLocalizedString(@"Built-in", @"");
		case kAudioDeviceTransportTypeUSB:           return NSLocalizedString(@"USB", @"");
		case kAudioDeviceTransportTypeBluetooth:     return NSLocalizedString(@"Bluetooth", @"");
		case kAudioDeviceTransportTypeBluetoothLE:   return NSLocalizedString(@"Bluetooth LE", @"");
		case kAudioDeviceTransportTypeThunderbolt:   return NSLocalizedString(@"Thunderbolt", @"");
		case kAudioDeviceTransportTypeAirPlay:       return NSLocalizedString(@"AirPlay/Continuity", @"");
		case kAudioDeviceTransportTypeVirtual:       return NSLocalizedString(@"Virtual", @"");
		default:                                      return NSLocalizedString(@"Unknown", @"");
	}
}

#pragma mark Connect/disconnect

-(void)deviceConnected:(NSNotification *)note {
	AVCaptureDevice *device = note.object;
	if (![device hasMediaType:AVMediaTypeVideo]) return;   // this notification also fires for audio-only devices
	if (!HWGCameraBoolForKey(HWG_CAMERA_NOTIFY_CONNECT_KEY, YES)) return;

	int32_t transport = device.transportType;
	if ([self transportAlreadyCoveredByAnotherMonitor:transport]) return;

	NSMutableArray<NSString *> *lines = [NSMutableArray array];
	if (HWGCameraBoolForKey(HWG_CAMERA_SHOW_TRANSPORT_KEY, YES)) {
		[lines addObject:[NSString stringWithFormat:NSLocalizedString(@"Transport:\t%@", @""), [self labelForTransportType:transport]]];
	}
	NSString *description = [lines count] ? [NSString stringWithFormat:@"%@\n%@", device.localizedName, [lines componentsJoinedByString:@"\n"]] : device.localizedName;

	[delegate notifyWithName:@"CameraConnected"
						 title:NSLocalizedString(@"Camera Connected", @"")
					   description:description
						  icon:[self iconDataInUse:NO]
			  identifierString:[NSString stringWithFormat:@"HWGrowlCamera-%@", device.uniqueID]
				 contextString:nil
						plugin:self];
}

-(void)deviceDisconnected:(NSNotification *)note {
	AVCaptureDevice *device = note.object;
	if (![device hasMediaType:AVMediaTypeVideo]) return;
	if (!HWGCameraBoolForKey(HWG_CAMERA_NOTIFY_CONNECT_KEY, YES)) return;
	if ([self transportAlreadyCoveredByAnotherMonitor:device.transportType]) return;

	[runningCameraUIDs removeObject:device.uniqueID];
	[delegate notifyWithName:@"CameraDisconnected"
						 title:NSLocalizedString(@"Camera Disconnected", @"")
					   description:device.localizedName
						  icon:[self iconDataInUse:NO]
			  identifierString:[NSString stringWithFormat:@"HWGrowlCamera-%@", device.uniqueID]
				 contextString:nil
						plugin:self];
}

#pragma mark "In use" (CoreMediaIO)

// Maps an AVCaptureDevice.uniqueID to its CMIODeviceID by matching kCMIODevicePropertyDeviceUID
// across every currently-enumerated CMIO device — CoreMediaIO and AVFoundation identify the
// same physical camera by the same UID string, but use separate object-ID spaces.
-(NSArray<NSNumber *> *)allCMIODeviceIDs {
	CMIOObjectPropertyAddress address = { kCMIOHardwarePropertyDevices, kCMIOObjectPropertyScopeGlobal, kCMIOObjectPropertyElementMain };
	UInt32 size = 0;
	if (CMIOObjectGetPropertyDataSize(kCMIOObjectSystemObject, &address, 0, NULL, &size) != kCMIOHardwareNoError || size == 0) return @[];
	UInt32 count = size / (UInt32)sizeof(CMIODeviceID);
	CMIODeviceID *deviceIDs = malloc(size);
	if (!deviceIDs) return @[];
	NSMutableArray<NSNumber *> *result = [NSMutableArray array];
	if (CMIOObjectGetPropertyData(kCMIOObjectSystemObject, &address, 0, NULL, size, &size, deviceIDs) == kCMIOHardwareNoError) {
		for (UInt32 i = 0; i < count; i++) [result addObject:@(deviceIDs[i])];
	}
	free(deviceIDs);
	return result;
}

-(NSString *)uidForCMIODevice:(CMIODeviceID)deviceID {
	CMIOObjectPropertyAddress address = { kCMIODevicePropertyDeviceUID, kCMIOObjectPropertyScopeGlobal, kCMIOObjectPropertyElementMain };
	CFStringRef uid = NULL;
	UInt32 size = sizeof(uid);
	if (CMIOObjectGetPropertyData(deviceID, &address, 0, NULL, size, &size, &uid) != kCMIOHardwareNoError || !uid) return nil;
	return CFBridgingRelease(uid);
}

-(BOOL)isCMIODeviceRunningSomewhere:(CMIODeviceID)deviceID {
	CMIOObjectPropertyAddress address = { kCMIODevicePropertyDeviceIsRunningSomewhere, kCMIOObjectPropertyScopeGlobal, kCMIOObjectPropertyElementMain };
	UInt32 isRunning = 0;
	UInt32 size = sizeof(isRunning);
	if (!CMIOObjectHasProperty(deviceID, &address)) return NO;
	CMIOObjectGetPropertyData(deviceID, &address, 0, NULL, size, &size, &isRunning);
	return isRunning != 0;
}

-(void)registerInUseListeners {
	if (!inUseListenerBlock) {
		__weak typeof(self) weakSelf = self;
		inUseListenerBlock = ^(UInt32 n, const CMIOObjectPropertyAddress *addrs) {
			(void)n; (void)addrs;
			[weakSelf refreshRunningStateForAllDevicesNotifying:YES];
		};
	}
	CMIOObjectPropertyAddress address = { kCMIODevicePropertyDeviceIsRunningSomewhere, kCMIOObjectPropertyScopeGlobal, kCMIOObjectPropertyElementMain };
	for (NSNumber *deviceID in [self allCMIODeviceIDs]) {
		if ([deviceIDsWithInUseListener containsObject:deviceID]) continue;   // already listening
		if (CMIOObjectHasProperty([deviceID unsignedIntValue], &address)) {
			CMIOObjectAddPropertyListenerBlock([deviceID unsignedIntValue], &address, dispatch_get_main_queue(), inUseListenerBlock);
			[deviceIDsWithInUseListener addObject:deviceID];
		}
	}
}

-(void)unregisterInUseListeners {
	if (!inUseListenerBlock) return;
	CMIOObjectPropertyAddress address = { kCMIODevicePropertyDeviceIsRunningSomewhere, kCMIOObjectPropertyScopeGlobal, kCMIOObjectPropertyElementMain };
	// Only call CMIOObjectRemovePropertyListenerBlock for IDs that are STILL in the current
	// device list — a device that just disconnected (the common reason this runs at all) has
	// an already-torn-down CMIODeviceID, and removing a listener from a stale/dead ID is what
	// crashed (confirmed via crash log, 22-jul-2026: SIGSEGV inside CoreMediaIO's internal
	// PropertyListener teardown). For an ID that's gone, there's nothing left to remove a
	// listener FROM — CMIO already discarded it along with the device — so we just drop our
	// own bookkeeping for it instead of calling into the framework at all.
	NSSet<NSNumber *> *currentIDs = [NSSet setWithArray:[self allCMIODeviceIDs]];
	for (NSNumber *deviceID in deviceIDsWithInUseListener) {
		if ([currentIDs containsObject:deviceID]) {
			CMIOObjectRemovePropertyListenerBlock([deviceID unsignedIntValue], &address, dispatch_get_main_queue(), inUseListenerBlock);
		}
	}
	[deviceIDsWithInUseListener removeAllObjects];
}

-(void)refreshRunningStateForAllDevicesNotifying:(BOOL)shouldNotify {
	BOOL wantsInUse = HWGCameraBoolForKey(HWG_CAMERA_NOTIFY_IN_USE_KEY, YES);
	for (NSNumber *deviceIDNumber in [self allCMIODeviceIDs]) {
		CMIODeviceID deviceID = [deviceIDNumber unsignedIntValue];
		NSString *uid = [self uidForCMIODevice:deviceID];
		if (!uid) continue;
		BOOL nowRunning = [self isCMIODeviceRunningSomewhere:deviceID];
		BOOL wasRunning = [runningCameraUIDs containsObject:uid];
		if (nowRunning == wasRunning) continue;

		if (nowRunning) [runningCameraUIDs addObject:uid]; else [runningCameraUIDs removeObject:uid];
		if (!shouldNotify || !wantsInUse) continue;
		NSString *rowKey = nowRunning ? HWG_CAMERA_NOTIFY_INUSE_ROW_KEY : HWG_CAMERA_NOTIFY_IDLE_ROW_KEY;
		if (!HWGCameraBoolForKey(rowKey, YES)) continue;

		AVCaptureDevice *device = [AVCaptureDevice deviceWithUniqueID:uid];
		NSString *name = device.localizedName ?: NSLocalizedString(@"Camera", @"");
		// BUG FIX (05-ago-2026): Started/Stopped used to share ONE identifierString per
		// device — confirmed live (user testing rapid on/off toggling) that this made
		// UNUserNotificationCenter treat the second notification as an update to the still-
		// displayed first one (same request identifier = same notification slot) instead of
		// a fresh banner, so "Stopped" silently didn't appear until "Started" had already
		// cleared. Appending the state makes each transition its own request identifier —
		// connect/disconnect notifications elsewhere intentionally keep a stable per-device
		// identifier for bounce-detection continuity, this is deliberately different from that.
		[delegate notifyWithName:@"CameraInUseChanged"
							 title:nowRunning ? NSLocalizedString(@"Camera Started Being Used", @"") : NSLocalizedString(@"Camera Stopped Being Used", @"")
						   description:name
							  icon:[self iconDataInUse:nowRunning]
					  identifierString:[NSString stringWithFormat:@"HWGrowlCameraInUse-%@-%@", uid, nowRunning ? @"started" : @"stopped"]
						 contextString:nil
								plugin:self];
	}
}

#pragma mark Icon

// Designed PNGs (Assets.xcassets) — replaces the hand-drawn single-blue outline glyph this
// used to render at runtime. Redesigned with more color variety per the user's feedback
// (coral body + blue lens ring + yellow highlight) instead of the single blue tone shared
// with Bluetooth Monitor. The in-use/not-in-use distinction that the old glyph conveyed via
// a filled-vs-outlined lens center is preserved as two separate PNGs (a filled red "REC"
// dot + matching indicator light for in-use, a plain yellow highlight otherwise).
-(NSImage *)cameraIconInUse:(BOOL)inUse {
	return HWGResolveIconNamed(inUse ? @"CameraMonitor-Icon-InUse" : @"CameraMonitor-Icon");
}

-(NSData *)iconDataInUse:(BOOL)inUse {
	return HWGResolveIconDataNamed(inUse ? @"CameraMonitor-Icon-InUse" : @"CameraMonitor-Icon");
}

#pragma mark HWGrowlPluginProtocol

-(NSString*)pluginDisplayName {
	return NSLocalizedString(@"Camera Monitor", @"");
}
-(NSImage*)preferenceIcon {
	// Resolved fresh every call (not cached) since this is user-customizable — see the same
	// note on AudioMonitor's -preferenceIcon. Own dedicated default name ("-Module"),
	// separate from -cameraIconInUse:'s "CameraMonitor-Icon" — customizing one must never
	// silently change the other.
	return HWGResolveIconNamed(@"CameraMonitor-Icon-Module");
}

-(IBAction)fieldToggleChanged:(NSButton*)sender {
	NSString *key = sender.identifier;
	if (!key) return;
	[[NSUserDefaults standardUserDefaults] setBool:(sender.state == NSControlStateValueOn) forKey:key];
}

-(NSButton *)checkboxWithKey:(NSString *)key title:(NSString *)title defaultOn:(BOOL)defaultOn {
	NSButton *box = [NSButton checkboxWithTitle:title target:self action:@selector(fieldToggleChanged:)];
	box.identifier = key;
	box.state = HWGCameraBoolForKey(key, defaultOn) ? NSControlStateValueOn : NSControlStateValueOff;
	box.translatesAutoresizingMaskIntoConstraints = NO;
	return box;
}

-(NSView*)preferencePane {
	if (prefsView) return prefsView;

	NSTabView *tabs = [[NSTabView alloc] initWithFrame:NSMakeRect(0, 0, 560, 190)];
	tabs.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

	NSView *v = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 560, 190)];

	NSTextField *header = [NSTextField labelWithString:NSLocalizedString(@"Notification fields", @"")];
	header.font = [NSFont boldSystemFontOfSize:12];
	header.textColor = [NSColor secondaryLabelColor];
	header.translatesAutoresizingMaskIntoConstraints = NO;

	NSArray<NSButton*> *rows = @[
		[self checkboxWithKey:HWG_CAMERA_SHOW_TRANSPORT_KEY title:NSLocalizedString(@"Transport type", @"") defaultOn:YES],
		[self checkboxWithKey:HWG_CAMERA_NOTIFY_CONNECT_KEY title:NSLocalizedString(@"Notify on connect/disconnect (Built-in/Thunderbolt/AirPlay — USB and Bluetooth already covered by their own monitors)", @"") defaultOn:YES],
		[self checkboxWithKey:HWG_CAMERA_NOTIFY_IN_USE_KEY  title:NSLocalizedString(@"Notify when camera starts/stops being used (privacy indicator)", @"") defaultOn:YES],
	];

	[v addSubview:header];
	[NSLayoutConstraint activateConstraints:@[
		[header.topAnchor     constraintEqualToAnchor:v.topAnchor constant:16],
		[header.leadingAnchor  constraintEqualToAnchor:v.leadingAnchor constant:16],
	]];
	NSView *previous = header;
	for (NSButton *row in rows) {
		[v addSubview:row];
		[NSLayoutConstraint activateConstraints:@[
			[row.topAnchor     constraintEqualToAnchor:previous.bottomAnchor constant:10],
			[row.leadingAnchor  constraintEqualToAnchor:v.leadingAnchor constant:16],
			[row.trailingAnchor constraintLessThanOrEqualToAnchor:v.trailingAnchor constant:-16],
		]];
		previous = row;
	}

	NSTabViewItem *generalItem = [[NSTabViewItem alloc] initWithIdentifier:@"general"];
	generalItem.label = NSLocalizedString(@"General", @"");
	generalItem.view = v;
	[tabs addTabViewItem:generalItem];

	CGFloat iconsPad = 16;
	CGFloat iconsWidth = 560 - 2 * iconsPad;
	HWGIconPickerView *iconPicker = [[HWGIconPickerView alloc] initWithIconSpecs:@[
		@[@"Module Icon (Sidebar)", @"CameraMonitor-Icon-Module"],
		@[@"In Use", @"CameraMonitor-Icon-InUse", HWG_CAMERA_NOTIFY_INUSE_ROW_KEY],
		@[@"Idle", @"CameraMonitor-Icon", HWG_CAMERA_NOTIFY_IDLE_ROW_KEY],
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

	NSScrollView *iconsScroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 560, 160)];
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
	return @[@"CameraConnected", @"CameraDisconnected", @"CameraInUseChanged"];
}
-(NSDictionary*)localizedNames {
	return @{
		@"CameraConnected": NSLocalizedString(@"Camera Connected", @""),
		@"CameraDisconnected": NSLocalizedString(@"Camera Disconnected", @""),
		@"CameraInUseChanged": NSLocalizedString(@"Camera In Use Changed", @""),
	};
}
-(NSDictionary*)noteDescriptions {
	return @{
		@"CameraConnected": NSLocalizedString(@"Sent when a camera not already covered by USB/Bluetooth Monitor is connected", @""),
		@"CameraDisconnected": NSLocalizedString(@"Sent when such a camera is disconnected", @""),
		@"CameraInUseChanged": NSLocalizedString(@"Sent when a camera starts or stops being used by any app — a privacy-relevant signal, same fact macOS's own camera-in-use indicator reflects", @""),
	};
}
-(NSArray*)defaultNotifications {
	return [self noteNames];
}

@end
