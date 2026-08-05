//
//  HWGrowlAudioMonitor.m
//  HardwareGrowler
//

// compile with ARC: -fobjc-arc
#import "HWGrowlAudioMonitor.h"
#import <CoreAudio/CoreAudio.h>
#import <AVFoundation/AVFoundation.h>
#import "HWGIconOverrideStore.h"
#import "HWGIconPickerView.h"

// F19: Audio Monitor reports two kinds of facts, deliberately kept separate:
//
//   1. Default input/output device changes — information NO OTHER monitor has. Even when
//      Bluetooth Monitor already announced "AirPods connected", macOS choosing to actually
//      USE that device as the default output is a distinct, later decision (and can happen
//      independently of a connect at all — e.g. switching defaults between two devices that
//      were both already connected).
//   2. Device connected/disconnected — but ONLY for transports that USB Monitor and
//      Bluetooth Monitor do NOT already cover (HDMI, DisplayPort, Thunderbolt, Built-in,
//      Aggregate/Multi-Output, AirPlay, PCI, FireWire, Virtual). A USB or Bluetooth audio
//      device connecting already gets its own notification from that specialized monitor —
//      reporting it again here would be the same physical event announced twice for no new
//      information, the same "two notifications for one user action" tension already solved
//      for Display Monitor's mode+role split, but here there IS a real duplicate to avoid
//      (unlike Display's case, where both facts were genuinely distinct).
//
// Uses CoreAudio's AudioObjectPropertyListener (not AVFoundation) — this is system-wide
// device enumeration/defaults, which is squarely CoreAudio's domain; AVFoundation's device
// APIs are scoped to what the CURRENT app/session can use, not "what's on the system."

#define HWG_AUDIO_SHOW_TRANSPORT_KEY         @"HWGAudioShowTransport"
#define HWG_AUDIO_SHOW_CHANNELS_KEY          @"HWGAudioShowChannels"
#define HWG_AUDIO_SHOW_SAMPLERATE_KEY        @"HWGAudioShowSampleRate"
// #9-adjacent (05-ago-2026): "Label:\told → new" line for default output/input device
// changes, same optional-field pattern as Display Monitor's per-field toggles — ON by
// default. extraInfoForDeviceID (transport/channels/sample rate) stays unconditional.
#define HWG_AUDIO_SHOW_DEVICE_CHANGE_ARROW_KEY @"HWGAudioShowDeviceChangeArrow"
#define HWG_AUDIO_NOTIFY_DEFAULT_OUTPUT_KEY  @"HWGAudioNotifyDefaultOutput"
#define HWG_AUDIO_NOTIFY_DEFAULT_INPUT_KEY   @"HWGAudioNotifyDefaultInput"
#define HWG_AUDIO_NOTIFY_DEVICE_CONNECT_KEY  @"HWGAudioNotifyDeviceConnect"
#define HWG_AUDIO_NOTIFY_DEVICE_DISCONNECT_KEY @"HWGAudioNotifyDeviceDisconnect"

// #7 (Fase B, 04-ago-2026): microphone in-use, mirroring Camera Monitor's "In Use"/"Idle"
// feature (kCMIODevicePropertyDeviceIsRunningSomewhere) but for CoreAudio's equivalent
// property, kAudioDevicePropertyDeviceIsRunningSomewhere — distinct property/framework from
// Camera Monitor's, confirmed present in this Mac's CoreAudio.framework header. Per explicit
// user decision (04-ago-2026): ON by default (matching Camera Monitor's actual current
// default, not the OFF suggested in an earlier TODO draft), and applies to ALL connected
// microphones (input-capable audio devices), not just the current default input — mirrors
// Camera Monitor's "listen on every camera simultaneously" architecture rather than Audio
// Monitor's simpler single-default-device tracking, since the user wants to know about ANY
// mic being used, not just the default one.
#define HWG_AUDIO_NOTIFY_MIC_IN_USE_KEY @"HWGAudioNotifyMicInUse"

static BOOL HWGAudioBoolForKey(NSString *key, BOOL def) {
	id stored = [[NSUserDefaults standardUserDefaults] objectForKey:key];
	return stored ? [stored boolValue] : def;
}

@interface HWGrowlAudioMonitor ()

@property (nonatomic, weak) id<HWGrowlPluginControllerProtocol> delegate;
@property (nonatomic, strong) NSView *prefsView;

// Snapshot of currently-known device IDs, diffed on every kAudioHardwarePropertyDevices
// callback the same way Display Monitor diffs CGGetOnlineDisplayList — added/removed drive
// connect/disconnect (transport-filtered, see file header), no notification on the initial
// baseline snapshot at launch.
@property (nonatomic, strong) NSMutableSet<NSNumber *> *knownDeviceIDs;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSString *> *deviceNames;
// Device IDs that actually got a "connected" notification fired (i.e. NOT suppressed by the
// covered-transport filter). Symmetric bookkeeping so the matching disconnect is only
// reported for a device this monitor itself announced connecting — without this, a
// suppressed USB/Bluetooth device would still fire a confusing "Audio Device Disconnected"
// with no matching "Connected" ever having appeared.
@property (nonatomic, strong) NSMutableSet<NSNumber *> *reportedDeviceIDs;

@property (nonatomic, assign) AudioDeviceID lastDefaultOutputID;
@property (nonatomic, assign) AudioDeviceID lastDefaultInputID;

// AudioObjectRemovePropertyListenerBlock identifies which listener to remove by comparing
// the exact block pointer passed to AudioObjectAddPropertyListenerBlock — passing a
// different block (or nil) is a silent no-op, leaving the original listener registered
// forever. These must be the SAME block references used at registration time. `copy` (not
// `strong`) is the correct qualifier for a block property — it moves the block from the
// stack to the heap, which `strong` alone doesn't guarantee.
@property (nonatomic, copy) AudioObjectPropertyListenerBlock devicesListenerBlock;
@property (nonatomic, copy) AudioObjectPropertyListenerBlock defaultOutputListenerBlock;
@property (nonatomic, copy) AudioObjectPropertyListenerBlock defaultInputListenerBlock;

// #7: mic in-use tracking. One shared listener block (registered once PER input-capable
// device, same block reference on each — matches Camera Monitor's pattern) that just
// recomputes running state for every tracked device rather than needing per-device closures.
@property (nonatomic, strong) AudioObjectPropertyListenerBlock micInUseListenerBlock;
// Device IDs currently holding a live kAudioDevicePropertyDeviceIsRunningSomewhere listener —
// mirrors Camera Monitor's `deviceIDsWithInUseListener`, so teardown/re-diffing on device-list
// changes only touches IDs known to actually have one registered.
@property (nonatomic, strong) NSMutableSet<NSNumber *> *deviceIDsWithMicInUseListener;
// Device IDs currently observed as "running somewhere" (i.e. actively in use by some app) —
// updated on every raw callback, independent of the debounce below, so it always reflects
// the true current hardware state.
@property (nonatomic, strong) NSMutableSet<NSNumber *> *runningMicDeviceIDs;
// BUG FIX (05-ago-2026): confirmed live (user testing MS Teams call start/end, screenshots)
// that starting or ending a call fires 3 raw transitions in under half a second — e.g.
// Stopped -> Started -> Stopped when STARTING a call — because Teams' own audio session
// setup/teardown briefly cycles CoreAudio's input capture itself, not because the user
// touched the mic multiple times. Confirmed independently the same session with a standalone
// diagnostic tool (see conversation) showing the OS really does report these as 3 distinct,
// genuine kAudioDevicePropertyDeviceIsRunningSomewhere transitions, not a coalescing artifact
// on our end — so firing a notification for each one is technically accurate per-event but
// produces a misleading, self-contradicting sequence of banners (ending on "Stopped" right
// after the user just started a call). `lastNotifiedMicDeviceIDs` is the debounced baseline:
// diffed against the LATEST state once it's held stable for `kMicDebounceInterval`, collapsing
// a whole burst into one notification for whatever state actually stuck.
@property (nonatomic, strong) NSMutableSet<NSNumber *> *lastNotifiedMicDeviceIDs;
@property (nonatomic, strong) dispatch_block_t pendingMicNotifyBlock;

@end

// C callback trampolines — CoreAudio's AudioObjectPropertyListenerBlock already gives us a
// block-based API (no C function pointer + userInfo needed, unlike CGDisplayRegisterReconfigurationCallback),
// so these are implemented directly as blocks in -init below; no free functions required.

@implementation HWGrowlAudioMonitor

@synthesize delegate;
@synthesize prefsView;
@synthesize knownDeviceIDs;
@synthesize deviceNames;
@synthesize reportedDeviceIDs;
@synthesize lastDefaultOutputID;
@synthesize lastDefaultInputID;
@synthesize devicesListenerBlock;
@synthesize defaultOutputListenerBlock;
@synthesize defaultInputListenerBlock;
@synthesize micInUseListenerBlock;
@synthesize deviceIDsWithMicInUseListener;
@synthesize runningMicDeviceIDs;
@synthesize lastNotifiedMicDeviceIDs;
@synthesize pendingMicNotifyBlock;

static const NSTimeInterval kMicDebounceInterval = 1.0;

static AudioObjectPropertyAddress kRunningSomewhereAddress = {
	kAudioDevicePropertyDeviceIsRunningSomewhere, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain
};

static AudioObjectPropertyAddress kDevicesAddress = {
	kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain
};
static AudioObjectPropertyAddress kDefaultOutputAddress = {
	kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain
};
static AudioObjectPropertyAddress kDefaultInputAddress = {
	kAudioHardwarePropertyDefaultInputDevice, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain
};

-(id)init {
	self = [super init];
	if (self) {
		knownDeviceIDs = [NSMutableSet set];
		deviceNames = [NSMutableDictionary dictionary];
		reportedDeviceIDs = [NSMutableSet set];
		deviceIDsWithMicInUseListener = [NSMutableSet set];
		runningMicDeviceIDs = [NSMutableSet set];
		lastNotifiedMicDeviceIDs = [NSMutableSet set];

		// Baseline silently at launch — like every other monitor — so the first real
		// connect/disconnect/default-change after this point is the first thing notified.
		[self snapshotDevicesUpdatingKnownState:YES];
		lastDefaultOutputID = [self currentDefaultDeviceForAddress:&kDefaultOutputAddress];
		lastDefaultInputID = [self currentDefaultDeviceForAddress:&kDefaultInputAddress];

		__weak typeof(self) weakSelf = self;
		self.devicesListenerBlock = ^(UInt32 n, const AudioObjectPropertyAddress *addrs) {
			(void)n; (void)addrs;
			[weakSelf snapshotDevicesUpdatingKnownState:NO];
		};
		self.defaultOutputListenerBlock = ^(UInt32 n, const AudioObjectPropertyAddress *addrs) {
			(void)n; (void)addrs;
			[weakSelf defaultOutputChanged];
		};
		self.defaultInputListenerBlock = ^(UInt32 n, const AudioObjectPropertyAddress *addrs) {
			(void)n; (void)addrs;
			[weakSelf defaultInputChanged];
		};

		AudioObjectAddPropertyListenerBlock(kAudioObjectSystemObject, &kDevicesAddress, dispatch_get_main_queue(), self.devicesListenerBlock);
		AudioObjectAddPropertyListenerBlock(kAudioObjectSystemObject, &kDefaultOutputAddress, dispatch_get_main_queue(), self.defaultOutputListenerBlock);
		AudioObjectAddPropertyListenerBlock(kAudioObjectSystemObject, &kDefaultInputAddress, dispatch_get_main_queue(), self.defaultInputListenerBlock);

		self.micInUseListenerBlock = ^(UInt32 n, const AudioObjectPropertyAddress *addrs) {
			(void)n; (void)addrs;
			[weakSelf refreshMicInUseStateNotifying:YES];
		};

		if (HWGAudioBoolForKey(HWG_AUDIO_NOTIFY_MIC_IN_USE_KEY, YES)) {
			[self requestMicrophoneAccessIfNeeded];
			[self registerMicInUseListeners];
			[self refreshMicInUseStateNotifying:NO];   // baseline silently, like every other feature
		}
	}
	return self;
}

-(void)dealloc {
	if (pendingMicNotifyBlock) dispatch_block_cancel(pendingMicNotifyBlock);
	AudioObjectRemovePropertyListenerBlock(kAudioObjectSystemObject, &kDevicesAddress, dispatch_get_main_queue(), devicesListenerBlock);
	AudioObjectRemovePropertyListenerBlock(kAudioObjectSystemObject, &kDefaultOutputAddress, dispatch_get_main_queue(), defaultOutputListenerBlock);
	AudioObjectRemovePropertyListenerBlock(kAudioObjectSystemObject, &kDefaultInputAddress, dispatch_get_main_queue(), defaultInputListenerBlock);
	for (NSNumber *deviceID in deviceIDsWithMicInUseListener) {
		AudioObjectRemovePropertyListenerBlock([deviceID unsignedIntValue], &kRunningSomewhereAddress, dispatch_get_main_queue(), micInUseListenerBlock);
	}
}

#pragma mark CoreAudio helpers

-(AudioDeviceID)currentDefaultDeviceForAddress:(AudioObjectPropertyAddress *)address {
	AudioDeviceID deviceID = kAudioObjectUnknown;
	UInt32 size = sizeof(deviceID);
	AudioObjectGetPropertyData(kAudioObjectSystemObject, address, 0, NULL, &size, &deviceID);
	return deviceID;
}

-(NSString *)nameForDeviceID:(AudioDeviceID)deviceID {
	if (deviceID == kAudioObjectUnknown) return nil;
	AudioObjectPropertyAddress address = { kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
	CFStringRef name = NULL;
	UInt32 size = sizeof(name);
	OSStatus status = AudioObjectGetPropertyData(deviceID, &address, 0, NULL, &size, &name);
	if (status != noErr || !name) return nil;
	return CFBridgingRelease(name);
}

-(UInt32)transportTypeForDeviceID:(AudioDeviceID)deviceID {
	AudioObjectPropertyAddress address = { kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
	UInt32 transport = 0;
	UInt32 size = sizeof(transport);
	AudioObjectGetPropertyData(deviceID, &address, 0, NULL, &size, &transport);
	return transport;
}

// Already reported by USB Monitor / Bluetooth Monitor via their own connect/disconnect
// notifications — see file header for why Audio Monitor skips these transports for its own
// connect/disconnect event (default-device-change notifications are NOT filtered this way,
// since that's genuinely new information regardless of transport).
-(BOOL)transportAlreadyCoveredByAnotherMonitor:(UInt32)transport {
	return transport == kAudioDeviceTransportTypeUSB
		|| transport == kAudioDeviceTransportTypeBluetooth
		|| transport == kAudioDeviceTransportTypeBluetoothLE;
}

-(NSString *)labelForTransportType:(UInt32)transport {
	switch (transport) {
		case kAudioDeviceTransportTypeBuiltIn:        return NSLocalizedString(@"Built-in", @"");
		case kAudioDeviceTransportTypeUSB:             return NSLocalizedString(@"USB", @"");
		case kAudioDeviceTransportTypeBluetooth:       return NSLocalizedString(@"Bluetooth", @"");
		case kAudioDeviceTransportTypeBluetoothLE:     return NSLocalizedString(@"Bluetooth LE", @"");
		case kAudioDeviceTransportTypeHDMI:            return NSLocalizedString(@"HDMI", @"");
		case kAudioDeviceTransportTypeDisplayPort:     return NSLocalizedString(@"DisplayPort", @"");
		case kAudioDeviceTransportTypeThunderbolt:     return NSLocalizedString(@"Thunderbolt", @"");
		case kAudioDeviceTransportTypeAirPlay:         return NSLocalizedString(@"AirPlay", @"");
		case kAudioDeviceTransportTypeAggregate:       return NSLocalizedString(@"Aggregate", @"");
		case kAudioDeviceTransportTypeAutoAggregate:   return NSLocalizedString(@"Aggregate", @"");
		case kAudioDeviceTransportTypeVirtual:         return NSLocalizedString(@"Virtual", @"");
		case kAudioDeviceTransportTypePCI:             return NSLocalizedString(@"PCI", @"");
		case kAudioDeviceTransportTypeFireWire:        return NSLocalizedString(@"FireWire", @"");
		default:                                        return NSLocalizedString(@"Unknown", @"");
	}
}

// Sums channel counts across all buffers in the stream configuration for the given scope
// (Input or Output) — 0 if the device has no streams in that direction (e.g. an
// output-only speaker queried for its input channel count).
-(UInt32)channelCountForDeviceID:(AudioDeviceID)deviceID scope:(AudioObjectPropertyScope)scope {
	AudioObjectPropertyAddress address = { kAudioDevicePropertyStreamConfiguration, scope, kAudioObjectPropertyElementMain };
	UInt32 size = 0;
	if (AudioObjectGetPropertyDataSize(deviceID, &address, 0, NULL, &size) != noErr || size == 0) return 0;
	AudioBufferList *bufferList = malloc(size);
	if (!bufferList) return 0;
	UInt32 channels = 0;
	if (AudioObjectGetPropertyData(deviceID, &address, 0, NULL, &size, bufferList) == noErr) {
		for (UInt32 i = 0; i < bufferList->mNumberBuffers; i++) {
			channels += bufferList->mBuffers[i].mNumberChannels;
		}
	}
	free(bufferList);
	return channels;
}

-(double)sampleRateForDeviceID:(AudioDeviceID)deviceID {
	AudioObjectPropertyAddress address = { kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
	Float64 rate = 0;
	UInt32 size = sizeof(rate);
	AudioObjectGetPropertyData(deviceID, &address, 0, NULL, &size, &rate);
	return rate;
}

// Builds the F33 extra-info lines (transport/channels/sample rate) for a device, honoring
// each field's own toggle — same pattern as every other monitor's extraInfoFor...: method.
-(NSString *)extraInfoForDeviceID:(AudioDeviceID)deviceID {
	NSMutableArray<NSString *> *lines = [NSMutableArray array];

	if (HWGAudioBoolForKey(HWG_AUDIO_SHOW_TRANSPORT_KEY, YES)) {
		[lines addObject:[NSString stringWithFormat:NSLocalizedString(@"Transport:\t%@", @""), [self labelForTransportType:[self transportTypeForDeviceID:deviceID]]]];
	}
	if (HWGAudioBoolForKey(HWG_AUDIO_SHOW_CHANNELS_KEY, YES)) {
		UInt32 outChannels = [self channelCountForDeviceID:deviceID scope:kAudioDevicePropertyScopeOutput];
		UInt32 inChannels  = [self channelCountForDeviceID:deviceID scope:kAudioDevicePropertyScopeInput];
		if (outChannels > 0) [lines addObject:[NSString stringWithFormat:NSLocalizedString(@"Output channels:\t%u", @""), (unsigned)outChannels]];
		if (inChannels > 0)  [lines addObject:[NSString stringWithFormat:NSLocalizedString(@"Input channels:\t%u", @""), (unsigned)inChannels]];
	}
	if (HWGAudioBoolForKey(HWG_AUDIO_SHOW_SAMPLERATE_KEY, YES)) {
		double rate = [self sampleRateForDeviceID:deviceID];
		if (rate > 0) [lines addObject:[NSString stringWithFormat:NSLocalizedString(@"Sample rate:\t%.0f Hz", @""), rate]];
	}

	return [lines count] ? [lines componentsJoinedByString:@"\n"] : nil;
}


-(NSData *)iconDataForSymbol:(NSString *)symbolName {
	// symbolName no longer selects an SF Symbol — kept as the call sites' "connected vs
	// disconnected vs default-change" signal: the active-state PNG shows for an
	// active/connected/current state, the muted/"-Off" variant for a disconnected one,
	// matching how the hand-drawn icon's waves used to imply sound actively playing before
	// this was replaced with a proper designed PNG (Assets.xcassets) instead of a
	// stroke-drawn vector built at runtime.
	BOOL connected = ![symbolName isEqualToString:@"speaker.slash.fill"];
	NSString *imageName = connected ? @"AudioMonitor-Icon" : @"AudioMonitor-Icon-Off";
	return HWGResolveIconDataNamed(imageName);
}

#pragma mark Device connect/disconnect

-(void)snapshotDevicesUpdatingKnownState:(BOOL)isBaselineOnly {
	AudioObjectPropertyAddress address = kDevicesAddress;
	UInt32 size = 0;
	if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &address, 0, NULL, &size) != noErr) return;
	UInt32 count = size / (UInt32)sizeof(AudioDeviceID);
	if (count == 0) return;

	AudioDeviceID *deviceIDs = malloc(size);
	if (!deviceIDs) return;
	if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, 0, NULL, &size, deviceIDs) != noErr) {
		free(deviceIDs);
		return;
	}

	NSMutableSet<NSNumber *> *newIDs = [NSMutableSet set];
	for (UInt32 i = 0; i < count; i++) {
		[newIDs addObject:@(deviceIDs[i])];
	}
	free(deviceIDs);

	if (isBaselineOnly) {
		knownDeviceIDs = newIDs;
		for (NSNumber *deviceID in newIDs) {
			deviceNames[deviceID] = [self nameForDeviceID:[deviceID unsignedIntValue]] ?: NSLocalizedString(@"Unknown Device", @"");
		}
		return;
	}

	NSMutableSet<NSNumber *> *added = [newIDs mutableCopy];
	[added minusSet:knownDeviceIDs];
	NSMutableSet<NSNumber *> *removed = [knownDeviceIDs mutableCopy];
	[removed minusSet:newIDs];

	BOOL wantsConnect = HWGAudioBoolForKey(HWG_AUDIO_NOTIFY_DEVICE_CONNECT_KEY, YES);

	for (NSNumber *deviceID in added) {
		AudioDeviceID audioID = [deviceID unsignedIntValue];
		NSString *name = [self nameForDeviceID:audioID] ?: NSLocalizedString(@"Unknown Device", @"");
		deviceNames[deviceID] = name;
		if (!wantsConnect) continue;
		if ([self transportAlreadyCoveredByAnotherMonitor:[self transportTypeForDeviceID:audioID]]) continue;
		[reportedDeviceIDs addObject:deviceID];
		NSString *extraInfo = [self extraInfoForDeviceID:audioID];
		NSString *description = extraInfo ? [NSString stringWithFormat:@"%@\n%@", name, extraInfo] : name;
		[delegate notifyWithName:@"AudioDeviceConnected"
							 title:NSLocalizedString(@"Audio Device Connected", @"")
					   description:description
							  icon:[self iconDataForSymbol:@"speaker.wave.2.fill"]
				  identifierString:[NSString stringWithFormat:@"HWGrowlAudioDevice-%@", deviceID]
					 contextString:nil
							plugin:self];
	}
	for (NSNumber *deviceID in removed) {
		NSString *lastKnownName = deviceNames[deviceID] ?: NSLocalizedString(@"Unknown Device", @"");
		[deviceNames removeObjectForKey:deviceID];
		// Transport can't be queried anymore (device is gone), so the covered-transport
		// filter can't be re-checked here — instead, only fire "Disconnected" for a device
		// that actually got a "Connected" notification fired for it (tracked in
		// reportedDeviceIDs), keeping the two symmetric without needing the transport again.
		if (![reportedDeviceIDs containsObject:deviceID]) continue;
		[reportedDeviceIDs removeObject:deviceID];
		if (!HWGAudioBoolForKey(HWG_AUDIO_NOTIFY_DEVICE_DISCONNECT_KEY, YES)) continue;
		[delegate notifyWithName:@"AudioDeviceDisconnected"
							 title:NSLocalizedString(@"Audio Device Disconnected", @"")
					   description:lastKnownName
							  icon:[self iconDataForSymbol:@"speaker.slash.fill"]
				  identifierString:[NSString stringWithFormat:@"HWGrowlAudioDevice-%@", deviceID]
					 contextString:nil
							plugin:self];
	}

	knownDeviceIDs = newIDs;

	// #7: re-sync mic-in-use listeners against the fresh device list — drop stale ones for
	// devices that just disconnected, attach new ones for any newly-connected microphone.
	// (This point is only reached on the non-baseline path — the baseline branch above
	// returns early — so notifying here is always appropriate, never the initial silent seed.)
	if (HWGAudioBoolForKey(HWG_AUDIO_NOTIFY_MIC_IN_USE_KEY, YES)) {
		[self unregisterStaleMicInUseListeners];
		[self registerMicInUseListeners];
		[self refreshMicInUseStateNotifying:YES];
	}
}

#pragma mark Microphone in-use (#7)

// BUG FIX (04-ago-2026): confirmed live (user testing with QuickTime — the CoreAudio
// property itself DOES flip correctly, verified with a standalone diagnostic tool) that
// merely reading kAudioDevicePropertyDeviceIsRunningSomewhere never prompts for Microphone
// access and never even lists HardwareGrowler under System Settings → Privacy & Security →
// Microphone — it silently reports NO regardless of the true state for a process that has
// never been granted access, with no error and no prompt. Declaring
// NSMicrophoneUsageDescription in Info.plist alone doesn't trigger the prompt either — macOS
// only asks when the process actually calls a real audio-capture-adjacent API. Requesting via
// AVCaptureDevice here (even though nothing is actually captured/recorded) is what makes
// the permission prompt appear and the app show up in the Privacy list. Gated behind the
// checkbox — never requested unless the user has this feature enabled, same "don't trigger a
// system prompt for something the user hasn't opted into" caution already used for Scanner
// Monitor's Local Network permission.
-(void)requestMicrophoneAccessIfNeeded {
	if (![AVCaptureDevice respondsToSelector:@selector(authorizationStatusForMediaType:)]) return;
	AVAuthorizationStatus status = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio];
	if (status == AVAuthorizationStatusNotDetermined) {
		[AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio completionHandler:^(BOOL granted) {
			(void)granted;   // Nothing to do either way — listeners are already registered;
							  // a denial just means the running-state reads keep returning NO,
							  // same failure mode as today, not a crash or a new one.
		}];
	}
}

-(BOOL)deviceHasInputChannels:(AudioDeviceID)deviceID {
	return [self channelCountForDeviceID:deviceID scope:kAudioDevicePropertyScopeInput] > 0;
}

-(BOOL)isDeviceRunningSomewhere:(AudioDeviceID)deviceID {
	UInt32 running = 0;
	UInt32 size = sizeof(running);
	OSStatus status = AudioObjectGetPropertyData(deviceID, &kRunningSomewhereAddress, 0, NULL, &size, &running);
	return status == noErr && running != 0;
}

// Attaches the shared mic-in-use listener block to every currently-known input-capable
// device that doesn't already have one — safe to call repeatedly (e.g. after the device list
// changes, or when the checkbox is turned on).
-(void)registerMicInUseListeners {
	for (NSNumber *deviceID in self.knownDeviceIDs) {
		if ([self.deviceIDsWithMicInUseListener containsObject:deviceID]) continue;
		AudioDeviceID audioID = [deviceID unsignedIntValue];
		if (![self deviceHasInputChannels:audioID]) continue;
		AudioObjectAddPropertyListenerBlock(audioID, &kRunningSomewhereAddress, dispatch_get_main_queue(), self.micInUseListenerBlock);
		[self.deviceIDsWithMicInUseListener addObject:deviceID];
	}
}

// Removes the listener from every tracked device ID that's no longer in the current device
// list (disconnected) or no longer has input channels — mirrors Camera Monitor's caution
// about only removing from IDs known to still exist, since calling
// AudioObjectRemovePropertyListenerBlock on an already-disconnected device ID is unsafe.
-(void)unregisterStaleMicInUseListeners {
	NSMutableSet<NSNumber *> *stale = [NSMutableSet set];
	for (NSNumber *deviceID in self.deviceIDsWithMicInUseListener) {
		AudioDeviceID audioID = [deviceID unsignedIntValue];
		BOOL stillPresent = [self.knownDeviceIDs containsObject:deviceID];
		if (stillPresent && [self deviceHasInputChannels:audioID]) continue;
		if (stillPresent) {
			// Still connected (e.g. lost its input channels — shouldn't normally happen, but
			// safe either way) — fine to remove normally.
			AudioObjectRemovePropertyListenerBlock(audioID, &kRunningSomewhereAddress, dispatch_get_main_queue(), self.micInUseListenerBlock);
		}
		// If it's gone entirely, just drop the bookkeeping — no removal call, matching Camera
		// Monitor's crash postmortem (removing from a stale/disconnected ID is unsafe).
		[stale addObject:deviceID];
		[self.runningMicDeviceIDs removeObject:deviceID];
	}
	[self.deviceIDsWithMicInUseListener minusSet:stale];
}

// Recomputes which tracked input devices are currently "running somewhere" and fires
// Started/Stopped on the actual transition. `shouldNotify:NO` is used only for the initial
// silent baseline (at launch, or right after the checkbox is turned on) — same pattern as
// every other monitor's baseline-then-live-diff approach.
-(void)refreshMicInUseStateNotifying:(BOOL)shouldNotify {
	NSMutableSet<NSNumber *> *currentlyRunning = [NSMutableSet set];
	for (NSNumber *deviceID in self.deviceIDsWithMicInUseListener) {
		if ([self isDeviceRunningSomewhere:[deviceID unsignedIntValue]]) [currentlyRunning addObject:deviceID];
	}
	self.runningMicDeviceIDs = currentlyRunning;

	if (!shouldNotify) {
		// Silent baseline (launch, or checkbox just turned on) — nothing pending to debounce,
		// and this IS the notified baseline going forward.
		self.lastNotifiedMicDeviceIDs = currentlyRunning;
		return;
	}

	// Cancel any debounce still waiting from an earlier raw transition in this same burst —
	// only the LATEST scheduled check survives, so a burst of N raw callbacks only ever
	// results in one settle check, `kMicDebounceInterval` after the last one of them.
	if (self.pendingMicNotifyBlock) {
		dispatch_block_cancel(self.pendingMicNotifyBlock);
	}

	__weak typeof(self) weakSelf = self;
	dispatch_block_t block = dispatch_block_create(0, ^{
		typeof(self) strongSelf = weakSelf;
		if (!strongSelf) return;

		NSSet<NSNumber *> *settled = strongSelf.runningMicDeviceIDs;
		NSMutableSet<NSNumber *> *startedUsing = [settled mutableCopy];
		[startedUsing minusSet:strongSelf.lastNotifiedMicDeviceIDs];
		NSMutableSet<NSNumber *> *stoppedUsing = [strongSelf.lastNotifiedMicDeviceIDs mutableCopy];
		[stoppedUsing minusSet:settled];

		for (NSNumber *deviceID in startedUsing) {
			NSString *name = strongSelf.deviceNames[deviceID] ?: [strongSelf nameForDeviceID:[deviceID unsignedIntValue]] ?: NSLocalizedString(@"Unknown Device", @"");
			[strongSelf.delegate notifyWithName:@"AudioMicInUse"
										 title:NSLocalizedString(@"Microphone Started Being Used", @"")
								 description:name
										  icon:[strongSelf iconDataForMicInUse:YES]
							  identifierString:[NSString stringWithFormat:@"HWGrowlAudioMicInUse-%@-started", deviceID]
								  contextString:nil
											plugin:strongSelf];
		}
		for (NSNumber *deviceID in stoppedUsing) {
			NSString *name = strongSelf.deviceNames[deviceID] ?: [strongSelf nameForDeviceID:[deviceID unsignedIntValue]] ?: NSLocalizedString(@"Unknown Device", @"");
			[strongSelf.delegate notifyWithName:@"AudioMicInUse"
										 title:NSLocalizedString(@"Microphone Stopped Being Used", @"")
								 description:name
										  icon:[strongSelf iconDataForMicInUse:NO]
							  identifierString:[NSString stringWithFormat:@"HWGrowlAudioMicInUse-%@-stopped", deviceID]
								  contextString:nil
											plugin:strongSelf];
		}

		strongSelf.lastNotifiedMicDeviceIDs = [settled mutableCopy];
		strongSelf.pendingMicNotifyBlock = nil;
	});
	self.pendingMicNotifyBlock = block;
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kMicDebounceInterval * NSEC_PER_SEC)),
				   dispatch_get_main_queue(), block);
}

// BUG FIX (04-ago-2026): originally reused the speaker Connected/Disconnected artwork here —
// confirmed live (user testing) that this looked wrong (a speaker icon on a "Microphone
// Started/Stopped Being Used" notification). Replaced with 2 dedicated mic-shaped icons
// (orange capsule mic matching this monitor's accent color for "in use"; grayed-out mic with
// a red slash for "idle" — same visual language as the app's other muted/off states).
-(NSData *)iconDataForMicInUse:(BOOL)inUse {
	NSString *imageName = inUse ? @"AudioMonitor-Icon-MicInUse" : @"AudioMonitor-Icon-MicIdle";
	return HWGResolveIconDataNamed(imageName);
}

#pragma mark Default device changes

// Shared by -defaultOutputChanged/-defaultInputChanged below — takes the CURRENT/NEW ids
// directly (read fresh from CoreAudio by the caller) rather than a pointer into an ivar, to
// avoid taking the address of an ivar through a weak `self` in the property-listener block.
-(void)reportDefaultDeviceChangeFromID:(AudioDeviceID)oldID
									toID:(AudioDeviceID)newID
								noteName:(NSString *)noteName
								   title:(NSString *)title
								   label:(NSString *)label
							   notifyKey:(NSString *)notifyKey
									icon:(NSString *)symbolName {
	if (!HWGAudioBoolForKey(notifyKey, YES)) return;

	NSString *extraInfo = [self extraInfoForDeviceID:newID];
	NSString *description = extraInfo ?: @"";
	if (HWGAudioBoolForKey(HWG_AUDIO_SHOW_DEVICE_CHANGE_ARROW_KEY, YES)) {
		NSString *oldName = [self nameForDeviceID:oldID] ?: NSLocalizedString(@"None", @"");
		NSString *newName = [self nameForDeviceID:newID] ?: NSLocalizedString(@"None", @"");
		NSString *arrowLine = [NSString stringWithFormat:@"%@:\t%@ → %@", label, oldName, newName];
		description = [description length] ? [NSString stringWithFormat:@"%@\n%@", arrowLine, description] : arrowLine;
	}

	[delegate notifyWithName:noteName
						 title:title
					   description:description
						  icon:[self iconDataForSymbol:symbolName]
			  identifierString:noteName
				 contextString:nil
						plugin:self];
}

-(void)defaultOutputChanged {
	AudioDeviceID newID = [self currentDefaultDeviceForAddress:&kDefaultOutputAddress];
	if (newID == self.lastDefaultOutputID) return;
	AudioDeviceID oldID = self.lastDefaultOutputID;
	self.lastDefaultOutputID = newID;
	[self reportDefaultDeviceChangeFromID:oldID toID:newID
								   noteName:@"AudioDefaultOutputChanged"
									  title:NSLocalizedString(@"Default Audio Output Changed", @"")
									  label:NSLocalizedString(@"Default Output", @"")
								  notifyKey:HWG_AUDIO_NOTIFY_DEFAULT_OUTPUT_KEY
									   icon:@"hifispeaker.fill"];
}

-(void)defaultInputChanged {
	AudioDeviceID newID = [self currentDefaultDeviceForAddress:&kDefaultInputAddress];
	if (newID == self.lastDefaultInputID) return;
	AudioDeviceID oldID = self.lastDefaultInputID;
	self.lastDefaultInputID = newID;
	[self reportDefaultDeviceChangeFromID:oldID toID:newID
								   noteName:@"AudioDefaultInputChanged"
									  title:NSLocalizedString(@"Default Audio Input Changed", @"")
									  label:NSLocalizedString(@"Default Input", @"")
								  notifyKey:HWG_AUDIO_NOTIFY_DEFAULT_INPUT_KEY
									   icon:@"mic.fill"];
}

#pragma mark HWGrowlPluginProtocol

-(NSString*)pluginDisplayName {
	return NSLocalizedString(@"Audio Monitor", @"");
}
-(NSImage*)preferenceIcon {
	// Resolved fresh every call (not cached) since this is user-customizable — AppDelegate's
	// module list calls this each time it draws a row, so there's no need to cache it
	// ourselves, and caching it risked showing a stale icon until the app was restarted.
	// Own dedicated default name ("-Module"), separate from the "Connected" notification
	// icon's "AudioMonitor-Icon" — customizing one must never silently change the other.
	return HWGResolveIconNamed(@"AudioMonitor-Icon-Module");
}

-(IBAction)fieldToggleChanged:(NSButton*)sender {
	NSString *key = sender.identifier;
	if (!key) return;
	BOOL isOn = (sender.state == NSControlStateValueOn);
	[[NSUserDefaults standardUserDefaults] setBool:isOn forKey:key];

	// #7: (un)register mic-in-use listeners immediately on toggle, rather than waiting for the
	// next device-list change to notice the checkbox flipped.
	if ([key isEqualToString:HWG_AUDIO_NOTIFY_MIC_IN_USE_KEY]) {
		if (isOn) {
			[self requestMicrophoneAccessIfNeeded];
			[self registerMicInUseListeners];
			[self refreshMicInUseStateNotifying:NO];   // baseline silently, don't announce mics already in use
		} else {
			for (NSNumber *deviceID in self.deviceIDsWithMicInUseListener) {
				AudioObjectRemovePropertyListenerBlock([deviceID unsignedIntValue], &kRunningSomewhereAddress, dispatch_get_main_queue(), self.micInUseListenerBlock);
			}
			[self.deviceIDsWithMicInUseListener removeAllObjects];
			[self.runningMicDeviceIDs removeAllObjects];
		}
	}
}

-(NSButton *)checkboxWithKey:(NSString *)key title:(NSString *)title defaultOn:(BOOL)defaultOn {
	NSButton *box = [NSButton checkboxWithTitle:title target:self action:@selector(fieldToggleChanged:)];
	box.identifier = key;
	box.state = HWGAudioBoolForKey(key, defaultOn) ? NSControlStateValueOn : NSControlStateValueOff;
	box.translatesAutoresizingMaskIntoConstraints = NO;
	return box;
}

-(NSView*)preferencePane {
	if (prefsView) return prefsView;

	NSTabView *tabs = [[NSTabView alloc] initWithFrame:NSMakeRect(0, 0, 560, 264)];
	tabs.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

	NSView *v = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 560, 264)];

	NSTextField *header = [NSTextField labelWithString:NSLocalizedString(@"Notification fields", @"")];
	header.font = [NSFont boldSystemFontOfSize:12];
	header.textColor = [NSColor secondaryLabelColor];
	header.translatesAutoresizingMaskIntoConstraints = NO;

	NSArray<NSButton*> *rows = @[
		[self checkboxWithKey:HWG_AUDIO_SHOW_TRANSPORT_KEY        title:NSLocalizedString(@"Transport type (USB/Bluetooth/HDMI/etc.)", @"") defaultOn:YES],
		[self checkboxWithKey:HWG_AUDIO_SHOW_CHANNELS_KEY         title:NSLocalizedString(@"Channel count", @"") defaultOn:YES],
		[self checkboxWithKey:HWG_AUDIO_SHOW_SAMPLERATE_KEY       title:NSLocalizedString(@"Sample rate", @"") defaultOn:YES],
		[self checkboxWithKey:HWG_AUDIO_SHOW_DEVICE_CHANGE_ARROW_KEY title:NSLocalizedString(@"Show old → new device when the default changes", @"") defaultOn:YES],
		[self checkboxWithKey:HWG_AUDIO_NOTIFY_DEFAULT_OUTPUT_KEY title:NSLocalizedString(@"Notify on default output change", @"") defaultOn:YES],
		[self checkboxWithKey:HWG_AUDIO_NOTIFY_DEFAULT_INPUT_KEY  title:NSLocalizedString(@"Notify on default input change", @"") defaultOn:YES],
		[self checkboxWithKey:HWG_AUDIO_NOTIFY_DEVICE_CONNECT_KEY title:NSLocalizedString(@"Notify on device connect/disconnect (HDMI/Thunderbolt/Built-in — USB and Bluetooth already covered by their own monitors)", @"") defaultOn:YES],
		[self checkboxWithKey:HWG_AUDIO_NOTIFY_MIC_IN_USE_KEY     title:NSLocalizedString(@"Notify when a microphone starts/stops being used", @"") defaultOn:YES],
	];

	[v addSubview:header];
	[NSLayoutConstraint activateConstraints:@[
		[header.topAnchor     constraintEqualToAnchor:v.topAnchor constant:16],
		[header.leadingAnchor  constraintEqualToAnchor:v.leadingAnchor constant:16],
	]];
	NSView *previous = header;
	for (NSButton *row in rows) {
		row.translatesAutoresizingMaskIntoConstraints = NO;
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
		@[@"Module Icon (Sidebar)", @"AudioMonitor-Icon-Module"],
		@[@"Connected", @"AudioMonitor-Icon", HWG_AUDIO_NOTIFY_DEVICE_CONNECT_KEY],
		@[@"Disconnected/Muted", @"AudioMonitor-Icon-Off", HWG_AUDIO_NOTIFY_DEVICE_DISCONNECT_KEY],
		@[@"Microphone In Use", @"AudioMonitor-Icon-MicInUse", HWG_AUDIO_NOTIFY_MIC_IN_USE_KEY],
		@[@"Microphone Idle", @"AudioMonitor-Icon-MicIdle", HWG_AUDIO_NOTIFY_MIC_IN_USE_KEY],
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
	return @[@"AudioDeviceConnected", @"AudioDeviceDisconnected", @"AudioDefaultOutputChanged", @"AudioDefaultInputChanged", @"AudioMicInUse"];
}
-(NSDictionary*)localizedNames {
	return @{
		@"AudioDeviceConnected": NSLocalizedString(@"Audio Device Connected", @""),
		@"AudioDeviceDisconnected": NSLocalizedString(@"Audio Device Disconnected", @""),
		@"AudioDefaultOutputChanged": NSLocalizedString(@"Default Audio Output Changed", @""),
		@"AudioDefaultInputChanged": NSLocalizedString(@"Default Audio Input Changed", @""),
		@"AudioMicInUse": NSLocalizedString(@"Microphone In Use", @""),
	};
}
-(NSDictionary*)noteDescriptions {
	return @{
		@"AudioDeviceConnected": NSLocalizedString(@"Sent when an audio device not already covered by USB/Bluetooth Monitor is connected (HDMI, Thunderbolt, Built-in, Aggregate, AirPlay)", @""),
		@"AudioDeviceDisconnected": NSLocalizedString(@"Sent when such an audio device is disconnected", @""),
		@"AudioDefaultOutputChanged": NSLocalizedString(@"Sent when macOS switches the default audio output device", @""),
		@"AudioDefaultInputChanged": NSLocalizedString(@"Sent when macOS switches the default audio input device", @""),
		@"AudioMicInUse": NSLocalizedString(@"Sent when any connected microphone starts or stops actively being used by an app", @""),
	};
}
-(NSArray*)defaultNotifications {
	return [self noteNames];
}

@end
