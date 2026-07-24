//
//  HWGrowlCameraMonitor.m
//  HardwareGrowler
//

// compile with ARC: -fobjc-arc
#import "HWGrowlCameraMonitor.h"
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

		AVCaptureDevice *device = [AVCaptureDevice deviceWithUniqueID:uid];
		NSString *name = device.localizedName ?: NSLocalizedString(@"Camera", @"");
		[delegate notifyWithName:@"CameraInUseChanged"
							 title:nowRunning ? NSLocalizedString(@"Camera Started Being Used", @"") : NSLocalizedString(@"Camera Stopped Being Used", @"")
						   description:name
							  icon:[self iconDataInUse:nowRunning]
					  identifierString:[NSString stringWithFormat:@"HWGrowlCameraInUse-%@", uid]
						 contextString:nil
								plugin:self];
	}
}

#pragma mark Icon (hand-drawn outline, transparent background, no colored badge — matches
#pragma mark Thermal Monitor's convention, same style decision as Audio Monitor)

+(NSColor *)accentColor {
	// Explicit choice (19-jul-2026): the same blue Bluetooth Monitor uses, confirmed with
	// the user despite the two monitors then sharing a color — unlike the earlier
	// Audio-vs-Bluetooth/Network clash (which was an accidental default nobody asked for),
	// this one is intentional.
	return [NSColor colorWithRed:35.0/255.0 green:71.0/255.0 blue:232.0/255.0 alpha:1.0];
}

-(NSImage *)cameraIconInUse:(BOOL)inUse {
	NSSize size = NSMakeSize(128, 128);
	NSImage *image = [NSImage imageWithSize:size flipped:NO drawingHandler:^BOOL(NSRect rect) {
		NSColor *color = [HWGrowlCameraMonitor accentColor];
		[color setStroke];
		CGFloat lineWidth = rect.size.width * 0.05;

		// Camera body: rounded rect, slightly wider than tall.
		CGFloat bodyW = rect.size.width * 0.76;
		CGFloat bodyH = rect.size.height * 0.54;
		NSRect bodyRect = NSMakeRect(NSMidX(rect) - bodyW / 2.0, NSMidY(rect) - bodyH / 2.0 - rect.size.height * 0.04, bodyW, bodyH);
		NSBezierPath *body = [NSBezierPath bezierPathWithRoundedRect:bodyRect xRadius:bodyH * 0.22 yRadius:bodyH * 0.22];
		body.lineWidth = lineWidth;
		[body stroke];

		// Lens: concentric circles, centered in the body.
		CGFloat lensD = bodyH * 0.82;
		NSPoint lensCenter = NSMakePoint(NSMidX(bodyRect), NSMidY(bodyRect));
		NSRect lensOuter = NSMakeRect(lensCenter.x - lensD / 2.0, lensCenter.y - lensD / 2.0, lensD, lensD);
		NSBezierPath *outerRing = [NSBezierPath bezierPathWithOvalInRect:lensOuter];
		outerRing.lineWidth = lineWidth * 0.85;
		[outerRing stroke];

		CGFloat innerD = lensD * 0.48;
		NSRect lensInner = NSMakeRect(lensCenter.x - innerD / 2.0, lensCenter.y - innerD / 2.0, innerD, innerD);
		if (inUse) {
			[color setFill];
			[[NSBezierPath bezierPathWithOvalInRect:lensInner] fill];
		} else {
			NSBezierPath *innerRing = [NSBezierPath bezierPathWithOvalInRect:lensInner];
			innerRing.lineWidth = lineWidth * 0.7;
			[innerRing stroke];
		}

		// Small viewfinder "bump" on top-right, like a compact camera's flash/viewfinder —
		// purely decorative, keeps the glyph reading as "camera" rather than a plain circle.
		CGFloat bumpW = bodyW * 0.22;
		CGFloat bumpH = bodyH * 0.28;
		NSRect bumpRect = NSMakeRect(NSMaxX(bodyRect) - bumpW * 1.6, NSMaxY(bodyRect) - 1, bumpW, bumpH);
		NSBezierPath *bump = [NSBezierPath bezierPathWithRoundedRect:bumpRect xRadius:bumpH * 0.25 yRadius:bumpH * 0.25];
		bump.lineWidth = lineWidth * 0.85;
		[bump stroke];

		return YES;
	}];
	return image;
}

-(NSData *)iconDataInUse:(BOOL)inUse {
	return [[self cameraIconInUse:inUse] TIFFRepresentation];
}

#pragma mark HWGrowlPluginProtocol

-(NSString*)pluginDisplayName {
	return NSLocalizedString(@"Camera Monitor", @"");
}
-(NSImage*)preferenceIcon {
	static NSImage *_icon = nil;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		_icon = [self cameraIconInUse:NO];
	});
	return _icon;
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

	NSView *v = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 460, 190)];

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

	prefsView = v;
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
