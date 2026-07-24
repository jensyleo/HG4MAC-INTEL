//
//  HWGrowlAudioMonitor.m
//  HardwareGrowler
//

// compile with ARC: -fobjc-arc
#import "HWGrowlAudioMonitor.h"
#import <CoreAudio/CoreAudio.h>

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
#define HWG_AUDIO_NOTIFY_DEFAULT_OUTPUT_KEY  @"HWGAudioNotifyDefaultOutput"
#define HWG_AUDIO_NOTIFY_DEFAULT_INPUT_KEY   @"HWGAudioNotifyDefaultInput"
#define HWG_AUDIO_NOTIFY_DEVICE_CONNECT_KEY  @"HWGAudioNotifyDeviceConnect"

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

		// Baseline silently at launch — like every other monitor — so the first real
		// connect/disconnect/default-change after this point is the first thing notified.
		[self snapshotDevicesUpdatingKnownState:YES];
		lastDefaultOutputID = [self currentDefaultDeviceForAddress:&kDefaultOutputAddress];
		lastDefaultInputID = [self currentDefaultDeviceForAddress:&kDefaultInputAddress];

		__weak typeof(self) weakSelf = self;
		AudioObjectAddPropertyListenerBlock(kAudioObjectSystemObject, &kDevicesAddress, dispatch_get_main_queue(), ^(UInt32 n, const AudioObjectPropertyAddress *addrs) {
			(void)n; (void)addrs;
			[weakSelf snapshotDevicesUpdatingKnownState:NO];
		});
		AudioObjectAddPropertyListenerBlock(kAudioObjectSystemObject, &kDefaultOutputAddress, dispatch_get_main_queue(), ^(UInt32 n, const AudioObjectPropertyAddress *addrs) {
			(void)n; (void)addrs;
			[weakSelf defaultOutputChanged];
		});
		AudioObjectAddPropertyListenerBlock(kAudioObjectSystemObject, &kDefaultInputAddress, dispatch_get_main_queue(), ^(UInt32 n, const AudioObjectPropertyAddress *addrs) {
			(void)n; (void)addrs;
			[weakSelf defaultInputChanged];
		});
	}
	return self;
}

-(void)dealloc {
	AudioObjectRemovePropertyListenerBlock(kAudioObjectSystemObject, &kDevicesAddress, dispatch_get_main_queue(), nil);
	AudioObjectRemovePropertyListenerBlock(kAudioObjectSystemObject, &kDefaultOutputAddress, dispatch_get_main_queue(), nil);
	AudioObjectRemovePropertyListenerBlock(kAudioObjectSystemObject, &kDefaultInputAddress, dispatch_get_main_queue(), nil);
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

// Every other monitor's preference/notification icon is a colored PNG with its own settled
// color (Bluetooth = deep blue-indigo, Network = cyan/turquoise, Thunderbolt = yellow,
// Thermal = red, Power = green/multicolor). Purple and sky-blue were both tried and rejected
// (blue read too close to Bluetooth/Network's existing blue tones) — orange is the one warm
// tone still unclaimed, and reads clearly distinct from every other monitor's color at a glance.
+(NSColor *)accentColor {
	return [NSColor systemOrangeColor];
}

// Hand-drawn outline icon (transparent background, no colored badge) — matches Thermal
// Monitor's convention (HWGPrefsThermal.png: a plain colored glyph on transparent, no
// squircle container) rather than Bluetooth's solid-badge convention; the badge style was
// tried first and rejected. Shape follows a user-supplied reference: a rounded speaker
// cabinet with two concentric driver rings (tweeter + woofer) and symmetric sound-wave arcs
// fanning out on both sides — stroke-only, no fill, single accent color throughout.
-(NSImage *)speakerIconWithWaves:(BOOL)showWaves {
	NSSize size = NSMakeSize(128, 128);
	NSImage *image = [NSImage imageWithSize:size flipped:NO drawingHandler:^BOOL(NSRect rect) {
		NSColor *color = [HWGrowlAudioMonitor accentColor];
		[color setStroke];

		CGFloat lineWidth = rect.size.width * 0.045;
		CGFloat bodyW = rect.size.width * 0.40;
		CGFloat bodyH = rect.size.height * 0.74;
		NSRect bodyRect = NSMakeRect(NSMidX(rect) - bodyW / 2.0, NSMidY(rect) - bodyH / 2.0, bodyW, bodyH);

		NSBezierPath *body = [NSBezierPath bezierPathWithRoundedRect:bodyRect xRadius:bodyW * 0.28 yRadius:bodyW * 0.28];
		body.lineWidth = lineWidth;
		[body stroke];

		// Tweeter (small, upper) and woofer (larger, lower), each an outlined ring with a
		// small filled center dot — same layered-circle language as the reference image.
		CGFloat tweeterD = bodyW * 0.42;
		NSPoint tweeterCenter = NSMakePoint(NSMidX(bodyRect), NSMaxY(bodyRect) - bodyH * 0.24);
		[self strokeDriverRingAtCenter:tweeterCenter diameter:tweeterD lineWidth:lineWidth color:color];

		CGFloat wooferD = bodyW * 0.62;
		NSPoint wooferCenter = NSMakePoint(NSMidX(bodyRect), NSMinY(bodyRect) + bodyH * 0.30);
		[self strokeDriverRingAtCenter:wooferCenter diameter:wooferD lineWidth:lineWidth color:color];

		if (showWaves) {
			CGFloat waveLineWidth = lineWidth * 0.85;
			for (NSInteger i = 0; i < 3; i++) {
				CGFloat radius = rect.size.width * (0.16 + i * 0.085);
				CGFloat spanDegrees = 70.0;

				NSBezierPath *rightArc = [NSBezierPath bezierPath];
				[rightArc appendBezierPathWithArcWithCenter:NSMakePoint(NSMaxX(bodyRect), NSMidY(rect))
													  radius:radius
												  startAngle:-spanDegrees / 2.0
													endAngle:spanDegrees / 2.0];
				rightArc.lineWidth = waveLineWidth;
				[rightArc stroke];

				NSBezierPath *leftArc = [NSBezierPath bezierPath];
				[leftArc appendBezierPathWithArcWithCenter:NSMakePoint(NSMinX(bodyRect), NSMidY(rect))
													 radius:radius
												 startAngle:180.0 - spanDegrees / 2.0
												   endAngle:180.0 + spanDegrees / 2.0];
				leftArc.lineWidth = waveLineWidth;
				[leftArc stroke];
			}
		}
		return YES;
	}];
	return image;
}

-(void)strokeDriverRingAtCenter:(NSPoint)center diameter:(CGFloat)diameter lineWidth:(CGFloat)lineWidth color:(NSColor *)color {
	NSRect ringRect = NSMakeRect(center.x - diameter / 2.0, center.y - diameter / 2.0, diameter, diameter);
	NSBezierPath *ring = [NSBezierPath bezierPathWithOvalInRect:ringRect];
	ring.lineWidth = lineWidth * 0.8;
	[ring stroke];

	CGFloat dotDiameter = diameter * 0.22;
	NSRect dotRect = NSMakeRect(center.x - dotDiameter / 2.0, center.y - dotDiameter / 2.0, dotDiameter, dotDiameter);
	[color setFill];
	[[NSBezierPath bezierPathWithOvalInRect:dotRect] fill];
}

-(NSData *)iconDataForSymbol:(NSString *)symbolName {
	// symbolName no longer selects an SF Symbol — kept as the call sites' "connected vs
	// disconnected vs default-change" signal: waves show for an active/connected/current
	// state, omitted for a disconnected one (visually "silent"), matching how the reference
	// icon's waves imply sound actively playing.
	BOOL showWaves = ![symbolName isEqualToString:@"speaker.slash.fill"];
	return [[self speakerIconWithWaves:showWaves] TIFFRepresentation];
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
		[delegate notifyWithName:@"AudioDeviceDisconnected"
							 title:NSLocalizedString(@"Audio Device Disconnected", @"")
					   description:lastKnownName
							  icon:[self iconDataForSymbol:@"speaker.slash.fill"]
				  identifierString:[NSString stringWithFormat:@"HWGrowlAudioDevice-%@", deviceID]
					 contextString:nil
							plugin:self];
	}

	knownDeviceIDs = newIDs;
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

	NSString *oldName = [self nameForDeviceID:oldID] ?: NSLocalizedString(@"None", @"");
	NSString *newName = [self nameForDeviceID:newID] ?: NSLocalizedString(@"None", @"");
	NSString *arrowLine = [NSString stringWithFormat:@"%@:\t%@ → %@", label, oldName, newName];
	NSString *extraInfo = [self extraInfoForDeviceID:newID];
	NSString *description = extraInfo ? [NSString stringWithFormat:@"%@\n%@", arrowLine, extraInfo] : arrowLine;

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
	static NSImage *_icon = nil;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		_icon = [self speakerIconWithWaves:YES];
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
	box.state = HWGAudioBoolForKey(key, defaultOn) ? NSControlStateValueOn : NSControlStateValueOff;
	box.translatesAutoresizingMaskIntoConstraints = NO;
	return box;
}

-(NSView*)preferencePane {
	if (prefsView) return prefsView;

	NSView *v = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 460, 230)];

	NSTextField *header = [NSTextField labelWithString:NSLocalizedString(@"Notification fields", @"")];
	header.font = [NSFont boldSystemFontOfSize:12];
	header.textColor = [NSColor secondaryLabelColor];
	header.translatesAutoresizingMaskIntoConstraints = NO;

	NSArray<NSButton*> *rows = @[
		[self checkboxWithKey:HWG_AUDIO_SHOW_TRANSPORT_KEY        title:NSLocalizedString(@"Transport type (USB/Bluetooth/HDMI/etc.)", @"") defaultOn:YES],
		[self checkboxWithKey:HWG_AUDIO_SHOW_CHANNELS_KEY         title:NSLocalizedString(@"Channel count", @"") defaultOn:YES],
		[self checkboxWithKey:HWG_AUDIO_SHOW_SAMPLERATE_KEY       title:NSLocalizedString(@"Sample rate", @"") defaultOn:YES],
		[self checkboxWithKey:HWG_AUDIO_NOTIFY_DEFAULT_OUTPUT_KEY title:NSLocalizedString(@"Notify on default output change", @"") defaultOn:YES],
		[self checkboxWithKey:HWG_AUDIO_NOTIFY_DEFAULT_INPUT_KEY  title:NSLocalizedString(@"Notify on default input change", @"") defaultOn:YES],
		[self checkboxWithKey:HWG_AUDIO_NOTIFY_DEVICE_CONNECT_KEY title:NSLocalizedString(@"Notify on device connect/disconnect (HDMI/Thunderbolt/Built-in — USB and Bluetooth already covered by their own monitors)", @"") defaultOn:YES],
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

	prefsView = v;
	return prefsView;
}

#pragma mark HWGrowlPluginNotifierProtocol

-(NSArray*)noteNames {
	return @[@"AudioDeviceConnected", @"AudioDeviceDisconnected", @"AudioDefaultOutputChanged", @"AudioDefaultInputChanged"];
}
-(NSDictionary*)localizedNames {
	return @{
		@"AudioDeviceConnected": NSLocalizedString(@"Audio Device Connected", @""),
		@"AudioDeviceDisconnected": NSLocalizedString(@"Audio Device Disconnected", @""),
		@"AudioDefaultOutputChanged": NSLocalizedString(@"Default Audio Output Changed", @""),
		@"AudioDefaultInputChanged": NSLocalizedString(@"Default Audio Input Changed", @""),
	};
}
-(NSDictionary*)noteDescriptions {
	return @{
		@"AudioDeviceConnected": NSLocalizedString(@"Sent when an audio device not already covered by USB/Bluetooth Monitor is connected (HDMI, Thunderbolt, Built-in, Aggregate, AirPlay)", @""),
		@"AudioDeviceDisconnected": NSLocalizedString(@"Sent when such an audio device is disconnected", @""),
		@"AudioDefaultOutputChanged": NSLocalizedString(@"Sent when macOS switches the default audio output device", @""),
		@"AudioDefaultInputChanged": NSLocalizedString(@"Sent when macOS switches the default audio input device", @""),
	};
}
-(NSArray*)defaultNotifications {
	return [self noteNames];
}

@end
