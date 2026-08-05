//
//  HWGrowlBluetoothMonitor.m
//  HardwareGrowler
//
//  Created by Daniel Siemer on 5/5/12.
//  Copyright (c) 2012 The Growl Project, LLC. All rights reserved.
//

// compile with ARC: -fobjc-arc
#import "HWGrowlBluetoothMonitor.h"
#import "HWGIconOverrideStore.h"
#import "HWGIconPickerView.h"
#import <stdlib.h>
#import <IOBluetooth/IOBluetooth.h>
#include <IOKit/IOKitLib.h>

// F33: individually configurable fields in the Bluetooth connect notification's extra
// info — same pattern as Network/Power/USB Monitor. All default to YES.
#define HWG_BT_SHOW_TYPE_KEY    @"HWGBluetoothShowType"
#define HWG_BT_SHOW_PAIRED_KEY  @"HWGBluetoothShowPaired"
#define HWG_BT_SHOW_ADDRESS_KEY @"HWGBluetoothShowAddress"
// F36 (a): battery level for Apple accessories (AirPods/Magic Mouse/Keyboard/Trackpad) via
// IOBluetoothDevice's unofficial, undocumented battery selectors — not in the public header,
// so every read is respondsToSelector:-guarded and wrapped in performSelector. On by default
// since this is the well-established, widely-used mechanism (same one iStat Menus/Barttery/etc.
// rely on) for Apple's own accessories specifically. Non-Apple (CoreBluetooth GATT Battery
// Service) is a separate, not-yet-implemented rope — see TODO.md, blocked on hardware to test.
#define HWG_BT_SHOW_BATTERY_KEY @"HWGBluetoothShowBattery"

static BOOL HWGBTBoolForKey(NSString *key, BOOL def) {
	id stored = [[NSUserDefaults standardUserDefaults] objectForKey:key];
	return stored ? [stored boolValue] : def;
}

// Per-device-type "Notify" toggle (Icons tab) — same mechanism as USB/Thunderbolt Monitor's.
// Gates only the CONNECT notification (disconnect has no reliable class info, per the
// existing note on `-bluetoothDisconnection:device:`).
#define HWG_BT_NOTIFY_KEY_PREFIX @"HWGBluetoothNotifyType_"
#define HWG_BT_NOTIFY_DISCONNECT_KEY @"HWGBluetoothNotifyDisconnect"

@interface HWGrowlBluetoothMonitor ()

@property (nonatomic, weak) id<HWGrowlPluginControllerProtocol> delegate;
@property (nonatomic, assign) BOOL starting;
@property (nonatomic, strong) NSView *prefsView;

// strong: we keep this object to call -unregister on it later, so the monitor
// must own it.
@property (nonatomic, strong) IOBluetoothUserNotification *connectionNotification;

// Per-device disconnect notifications, keyed by address string. Nothing else holds a
// strong reference to the object `registerForDisconnectNotification:selector:` returns —
// without retaining it here, ARC is free to deallocate it before the disconnect ever
// fires, silently dropping that device's disconnect notification. Cleared (with
// -unregister) both when the disconnect actually fires and in -dealloc, for any device
// still connected when the monitor itself goes away.
@property (nonatomic, strong) NSMutableDictionary<NSString *, IOBluetoothUserNotification *> *disconnectNotifications;

@end

@implementation HWGrowlBluetoothMonitor

@synthesize delegate;
@synthesize starting;
@synthesize connectionNotification;
@synthesize prefsView;
@synthesize disconnectNotifications;

-(void)dealloc {
	[connectionNotification unregister];
	for (IOBluetoothUserNotification *note in disconnectNotifications.allValues) {
		[note unregister];
	}
	// ARC handles the release; no [super dealloc].
}

-(id)init {
	// Legacy 10.7-10.7.2 incompatibility check removed: the app's deployment
	// target is 13.0, so that range is unreachable.
	self = [super init];
	if (self) {
		disconnectNotifications = [NSMutableDictionary dictionary];
	}
	return self;
}

-(void)postRegistrationInit {
	self.starting = YES;
	// `registerForConnectNotifications:` fires `bluetoothConnection:device:` synchronously,
	// during this call, for every device already connected at registration time (in addition
	// to real future connect events) — it does enumerate pre-existing state, unlike
	// IOKit's plain "future events only" notification style. So detection of an
	// already-connected keyboard/mouse at launch already works; see `bluetoothConnection:`
	// for why the notification itself still needs special handling at this exact moment.
	self.connectionNotification = [IOBluetoothDevice registerForConnectNotifications:self
																									selector:@selector(bluetoothConnection:device:)];
	self.starting = NO;
}

-(void)bluetoothName:(NSString*)name connected:(BOOL)connected iconName:(NSString *)iconNameOverride extraInfo:(NSString *)extraInfo {
	NSString *title = connected ? NSLocalizedString(@"Bluetooth Connection", @"") : NSLocalizedString(@"Bluetooth Disconnection", @"");

	// Device-type icon only applies on connect — same reasoning as the extra-info fields:
	// `deviceClassMajor`/`deviceClassMinor` are read from the live `IOBluetoothDevice` at
	// connect time; on disconnect this app never even has a device-type icon to offer (see
	// call sites below), so this always falls back to the plain generic icon there.
    NSString *imageName = connected ? (iconNameOverride ?: @"Bluetooth-On") : @"Bluetooth-Off";
	NSData *iconData = [HWGResolveIconNamed(imageName) TIFFRepresentation];
	NSString *description = extraInfo ? [NSString stringWithFormat:@"%@\n%@", name, extraInfo] : name;

	[delegate notifyWithName:connected ? @"BluetoothConnected" : @"BluetoothDisconnected"
							 title:title
					 description:description
							  icon:iconData
			  identifierString:name
				  contextString:nil
							plugin:self];
}

// Human-readable label for a device's major class, and (for the two categories that carry
// useful sub-detail) its minor class — via the Bluetooth SIG's published Class of Device
// major/minor tables, read through IOBluetoothDevice's own public `deviceClassMajor`/
// `deviceClassMinor` accessors (developer.apple.com/documentation/iobluetooth).
-(NSString *)bluetoothTypeLabelForDevice:(IOBluetoothDevice *)device {
	BluetoothDeviceClassMajor major = [device deviceClassMajor];
	BluetoothDeviceClassMinor minor = [device deviceClassMinor];

	switch (major) {
		case kBluetoothDeviceClassMajorComputer:       return NSLocalizedString(@"Computer", @"");
		case kBluetoothDeviceClassMajorPhone:           return NSLocalizedString(@"Phone", @"");
		case kBluetoothDeviceClassMajorLANAccessPoint:  return NSLocalizedString(@"Network Access Point", @"");
		case kBluetoothDeviceClassMajorImaging:         return NSLocalizedString(@"Imaging", @"");
		case kBluetoothDeviceClassMajorWearable:        return NSLocalizedString(@"Wearable", @"");
		case kBluetoothDeviceClassMajorToy:             return NSLocalizedString(@"Toy", @"");
		case kBluetoothDeviceClassMajorHealth:           return NSLocalizedString(@"Health Device", @"");
		case kBluetoothDeviceClassMajorPeripheral: {
			// Peripheral minor class packs Keyboard/Pointing/Combo into the top 2 bits.
			uint8_t peripheralType = minor & 0x30;
			if (peripheralType == 0x10) return NSLocalizedString(@"Keyboard", @"");
			if (peripheralType == 0x20) return NSLocalizedString(@"Mouse/Trackpad", @"");
			if (peripheralType == 0x30) return NSLocalizedString(@"Keyboard & Mouse", @"");
			return NSLocalizedString(@"Peripheral", @"");
		}
		case kBluetoothDeviceClassMajorAudio: {
			switch (minor) {
				case kBluetoothDeviceClassMinorAudioHeadset:    return NSLocalizedString(@"Headset", @"");
				case kBluetoothDeviceClassMinorAudioHandsFree:  return NSLocalizedString(@"Hands-Free", @"");
				case kBluetoothDeviceClassMinorAudioMicrophone: return NSLocalizedString(@"Microphone", @"");
				case kBluetoothDeviceClassMinorAudioLoudspeaker: return NSLocalizedString(@"Speaker", @"");
				case kBluetoothDeviceClassMinorAudioHeadphones: return NSLocalizedString(@"Headphones", @"");
				case kBluetoothDeviceClassMinorAudioPortable:   return NSLocalizedString(@"Portable Audio", @"");
				case kBluetoothDeviceClassMinorAudioCar:        return NSLocalizedString(@"Car Audio", @"");
				case kBluetoothDeviceClassMinorAudioHiFi:       return NSLocalizedString(@"Hi-Fi Audio", @"");
				default: return NSLocalizedString(@"Audio/Video", @"");
			}
		}
		default: return nil;   // Miscellaneous/Unclassified — nothing useful to say
	}
}

// Maps the same major/minor Class of Device values used by `bluetoothTypeLabelForDevice:`
// to one of the device-type icons (Assets.xcassets) added for the "maximum icon coverage"
// pass — nil whenever there's no dedicated icon for that specific sub-case (e.g. Imaging,
// Toy, or an Audio minor class without one of the 4 icons made for Headphones/Speaker/
// Headset/Microphone), which falls back to the plain generic Bluetooth-On icon.
-(NSString *)bluetoothIconNameForDevice:(IOBluetoothDevice *)device {
	BluetoothDeviceClassMajor major = [device deviceClassMajor];
	BluetoothDeviceClassMinor minor = [device deviceClassMinor];

	switch (major) {
		case kBluetoothDeviceClassMajorComputer:       return @"BT-TypeComputer";
		case kBluetoothDeviceClassMajorPhone:           return @"BT-TypePhone";
		case kBluetoothDeviceClassMajorLANAccessPoint:  return @"BT-TypeAccessPoint";
		case kBluetoothDeviceClassMajorWearable:        return @"BT-TypeWearable";
		case kBluetoothDeviceClassMajorHealth:           return @"BT-TypeHealth";
		case kBluetoothDeviceClassMajorPeripheral: {
			uint8_t peripheralType = minor & 0x30;
			if (peripheralType == 0x10) return @"BT-TypeKeyboard";
			if (peripheralType == 0x20) return @"BT-TypeMouse";
			if (peripheralType == 0x30) return @"BT-TypeCombo";
			return nil;   // plain "Peripheral" — nothing more specific to show
		}
		case kBluetoothDeviceClassMajorAudio: {
			switch (minor) {
				case kBluetoothDeviceClassMinorAudioHeadset:
				case kBluetoothDeviceClassMinorAudioHandsFree: return @"BT-TypeHeadset";
				case kBluetoothDeviceClassMinorAudioMicrophone: return @"BT-TypeMicrophone";
				case kBluetoothDeviceClassMinorAudioLoudspeaker: return @"BT-TypeSpeaker";
				case kBluetoothDeviceClassMinorAudioHeadphones: return @"BT-TypeHeadphones";
				default: return nil;   // Portable/Car/Hi-Fi/etc. — no dedicated icon made
			}
		}
		default: return nil;   // Imaging, Toy, Miscellaneous/Unclassified
	}
}

// Stable identifier per type, used to build the "Notify" defaults key — kept separate
// from the icon-name lookup so notify-toggle identifiers survive an icon asset rename.
// Every sub-case that falls back to a shared/no icon above also shares one "Other" key.
-(NSString *)bluetoothTypeIdentifierForDevice:(IOBluetoothDevice *)device {
	BluetoothDeviceClassMajor major = [device deviceClassMajor];
	BluetoothDeviceClassMinor minor = [device deviceClassMinor];

	switch (major) {
		case kBluetoothDeviceClassMajorComputer:       return @"Computer";
		case kBluetoothDeviceClassMajorPhone:           return @"Phone";
		case kBluetoothDeviceClassMajorLANAccessPoint:  return @"AccessPoint";
		case kBluetoothDeviceClassMajorWearable:        return @"Wearable";
		case kBluetoothDeviceClassMajorHealth:           return @"Health";
		case kBluetoothDeviceClassMajorPeripheral: {
			uint8_t peripheralType = minor & 0x30;
			if (peripheralType == 0x10) return @"Keyboard";
			if (peripheralType == 0x20) return @"Mouse";
			if (peripheralType == 0x30) return @"Combo";
			return @"Other";
		}
		case kBluetoothDeviceClassMajorAudio: {
			switch (minor) {
				case kBluetoothDeviceClassMinorAudioHeadset:
				case kBluetoothDeviceClassMinorAudioHandsFree: return @"Headset";
				case kBluetoothDeviceClassMinorAudioMicrophone: return @"Microphone";
				case kBluetoothDeviceClassMinorAudioLoudspeaker: return @"Speaker";
				case kBluetoothDeviceClassMinorAudioHeadphones: return @"Headphones";
				default: return @"Other";
			}
		}
		default: return @"Other";
	}
}

// Calls one of IOBluetoothDevice's unofficial battery selectors (batteryPercentSingle /
// batteryPercentLeft / batteryPercentRight / batteryPercentCase) and returns the percentage,
// or -1 if the device doesn't respond to that selector or reports no reading. Not in the
// public IOBluetoothDevice header — every call is respondsToSelector:-guarded first, and the
// invocation is built via NSInvocation (not a plain performSelector:) because the return
// type is a small integer, not an object; a plain performSelector: would misinterpret it.
-(NSInteger)bluetoothBatteryValueForSelectorName:(NSString *)selectorName device:(IOBluetoothDevice *)device {
	SEL selector = NSSelectorFromString(selectorName);
	if (![device respondsToSelector:selector]) return -1;

	NSMethodSignature *signature = [device methodSignatureForSelector:selector];
	if (!signature) return -1;

	NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
	invocation.selector = selector;
	invocation.target = device;
	[invocation invoke];

	// All four known selectors return a signed 8-bit percentage (-1 = "no reading").
	int8_t result = -1;
	[invocation getReturnValue:&result];
	return result;
}

// Strips everything except hex digits and lowercases — Bluetooth addresses show up in
// different separator styles across IOKit properties (confirmed on this Mac: IOBluetoothDevice's
// own -addressString vs. the registry's "DeviceAddress"/"SerialNumber" don't necessarily agree
// on "-" vs ":"), so comparing the bare hex digits is the only format-proof way to match them.
static NSString *HWGBTNormalizedAddress(NSString *address) {
	if (!address.length) return @"";
	NSMutableString *hexOnly = [NSMutableString stringWithCapacity:address.length];
	NSCharacterSet *hexSet = [NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdefABCDEF"];
	for (NSUInteger i = 0; i < address.length; i++) {
		unichar c = [address characterAtIndex:i];
		if ([hexSet characterIsMember:c]) [hexOnly appendFormat:@"%C", c];
	}
	return [hexOnly lowercaseString];
}

// Second battery path, for Apple HID peripherals (Magic Mouse/Keyboard/Trackpad) — confirmed
// via `ioreg` that these do NOT answer the IOBluetoothDevice private selectors above (those
// are mainly for AirPods/Beats headphones per Hammerspoon's reverse-engineering notes); their
// battery instead lives in the IOKit registry, on an `AppleDeviceManagementHIDEventService`
// node with a "DeviceAddress" property matching the Bluetooth device's address (hex digits
// only — see HWGBTNormalizedAddress above), and a "BatteryPercent" integer property (confirmed
// present and correct — read 53 on a real Magic Keyboard while writing this).
-(NSInteger)bluetoothHIDBatteryPercentForDevice:(IOBluetoothDevice *)device {
	NSString *targetAddress = HWGBTNormalizedAddress([device addressString]);
	if (!targetAddress.length) return -1;

	CFMutableDictionaryRef matchDict = IOServiceMatching("AppleDeviceManagementHIDEventService");
	if (!matchDict) return -1;

	io_iterator_t iterator = IO_OBJECT_NULL;
	if (IOServiceGetMatchingServices(kIOMainPortDefault, matchDict, &iterator) != kIOReturnSuccess) return -1;

	NSInteger result = -1;
	io_object_t service;
	while ((service = IOIteratorNext(iterator))) {
		// Try "DeviceAddress" first, then "SerialNumber" as a fallback — both were observed
		// carrying the device's Bluetooth address (in different separator styles) on this Mac's
		// registry nodes, but not every node necessarily has both keys populated.
		BOOL matched = NO;
		for (NSString *addressKey in @[@"DeviceAddress", @"SerialNumber"]) {
			CFTypeRef addressRef = IORegistryEntryCreateCFProperty(service, (__bridge CFStringRef)addressKey, kCFAllocatorDefault, 0);
			if (!addressRef) continue;
			if (CFGetTypeID(addressRef) == CFStringGetTypeID()) {
				NSString *entryAddress = HWGBTNormalizedAddress((__bridge NSString *)addressRef);
				if (entryAddress.length && [entryAddress isEqualToString:targetAddress]) matched = YES;
			}
			CFRelease(addressRef);
			if (matched) break;
		}

		if (matched) {
			CFTypeRef percentRef = IORegistryEntryCreateCFProperty(service, CFSTR("BatteryPercent"), kCFAllocatorDefault, 0);
			if (percentRef) {
				if (CFGetTypeID(percentRef) == CFNumberGetTypeID()) {
					int percent = -1;
					CFNumberGetValue((CFNumberRef)percentRef, kCFNumberIntType, &percent);
					result = percent;
				}
				CFRelease(percentRef);
			}
		}
		IOObjectRelease(service);
		if (result >= 0) break;
	}
	IOObjectRelease(iterator);
	return result;
}

// AirPods-style devices report Left/Right/Case independently via the private IOBluetoothDevice
// selectors; Apple HID peripherals (Magic Mouse/Keyboard/Trackpad) report only a single overall
// value via the IOKit registry path above. Builds one "Battery:" line covering whichever
// reading is actually available, or nil if neither path has anything (e.g. non-Apple devices).
-(NSString *)bluetoothBatteryInfoForDevice:(IOBluetoothDevice *)device {
	NSInteger single = [self bluetoothBatteryValueForSelectorName:@"batteryPercentSingle" device:device];
	if (single < 0) single = [self bluetoothHIDBatteryPercentForDevice:device];
	if (single >= 0) {
		return [NSString stringWithFormat:NSLocalizedString(@"Battery:\t%ld%%", @""), (long)single];
	}

	NSInteger left  = [self bluetoothBatteryValueForSelectorName:@"batteryPercentLeft"  device:device];
	NSInteger right = [self bluetoothBatteryValueForSelectorName:@"batteryPercentRight" device:device];
	NSInteger box   = [self bluetoothBatteryValueForSelectorName:@"batteryPercentCase"  device:device];
	if (left < 0 && right < 0 && box < 0) return nil;

	NSMutableArray<NSString*> *parts = [NSMutableArray array];
	if (left  >= 0) [parts addObject:[NSString stringWithFormat:NSLocalizedString(@"L %ld%%", @""), (long)left]];
	if (right >= 0) [parts addObject:[NSString stringWithFormat:NSLocalizedString(@"R %ld%%", @""), (long)right]];
	if (box   >= 0) [parts addObject:[NSString stringWithFormat:NSLocalizedString(@"Case %ld%%", @""), (long)box]];
	return [NSString stringWithFormat:NSLocalizedString(@"Battery:\t%@", @""), [parts componentsJoinedByString:@" / "]];
}

-(NSString *)bluetoothExtraInfoForDevice:(IOBluetoothDevice *)device {
	NSMutableArray<NSString*> *lines = [NSMutableArray array];

	if (HWGBTBoolForKey(HWG_BT_SHOW_TYPE_KEY, YES)) {
		NSString *typeLabel = [self bluetoothTypeLabelForDevice:device];
		if (typeLabel) [lines addObject:[NSString stringWithFormat:NSLocalizedString(@"Type:\t%@", @""), typeLabel]];
	}

	if (HWGBTBoolForKey(HWG_BT_SHOW_PAIRED_KEY, YES)) {
		[lines addObject:[NSString stringWithFormat:NSLocalizedString(@"Paired:\t%@", @""),
			[device isPaired] ? NSLocalizedString(@"Yes", @"") : NSLocalizedString(@"No", @"")]];
	}

	if (HWGBTBoolForKey(HWG_BT_SHOW_ADDRESS_KEY, YES)) {
		NSString *address = [device addressString];
		if (address) [lines addObject:[NSString stringWithFormat:NSLocalizedString(@"Address:\t%@", @""), address]];
	}

	if (HWGBTBoolForKey(HWG_BT_SHOW_BATTERY_KEY, YES)) {
		NSString *batteryInfo = [self bluetoothBatteryInfoForDevice:device];
		if (batteryInfo) [lines addObject:batteryInfo];
	}

	return [lines count] ? [lines componentsJoinedByString:@"\n"] : nil;
}

-(void)bluetoothDisconnection:(IOBluetoothUserNotification*)note
							  device:(IOBluetoothDevice*)device
{
	// No extraInfo on disconnect: class/paired-state read the same way as connect, but a
	// disconnecting device's properties are less reliably available by the time this fires.
	if (HWGBTBoolForKey(HWG_BT_NOTIFY_DISCONNECT_KEY, YES)) {
		[self bluetoothName:[device name] connected:NO iconName:nil extraInfo:nil];
	}
	[note unregister];
	NSString *address = [device addressString];
	if (address) [disconnectNotifications removeObjectForKey:address];
}

-(void)bluetoothConnection:(IOBluetoothUserNotification*)note
						  device:(IOBluetoothDevice*)device
{
	IOBluetoothUserNotification *disconnectNote = [device registerForDisconnectNotification:self
																				  selector:@selector(bluetoothDisconnection:device:)];
	NSString *address = [device addressString];
	if (disconnectNote && address) disconnectNotifications[address] = disconnectNote;

	if (!starting || [delegate onLaunchEnabled]) {
		if (starting) {
			// A device already connected at launch is reported here synchronously, from
			// `-postRegistrationInit` (itself called from `-awakeFromNib` on the Preferences
			// window controller) — well before `-applicationDidFinishLaunching:` and before
			// the notification banner plumbing (`GrowlApplicationBridge`) has finished its
			// own async setup. Confirmed via logging that this path was reached correctly
			// (device detected, `onLaunchEnabled` true, `notifyWithName:` called) but no
			// banner ever appeared. Deferring a couple of seconds gives that infrastructure
			// time to finish initializing before the notification is actually posted — a
			// real, currently-connecting device (the non-`starting` path below) doesn't need
			// this, since by then the app has been running for a while.
			NSString *name = [device name];
			NSString *iconName = [self bluetoothIconNameForDevice:device];
			NSString *extraInfo = [self bluetoothExtraInfoForDevice:device];
			NSString *notifyKey = [HWG_BT_NOTIFY_KEY_PREFIX stringByAppendingString:[self bluetoothTypeIdentifierForDevice:device]];
			if (HWGBTBoolForKey(notifyKey, YES)) {
				__weak typeof(self) weakSelf = self;
				dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
					[weakSelf bluetoothName:name connected:YES iconName:iconName extraInfo:extraInfo];
				});
			}
		} else {
			NSString *notifyKey = [HWG_BT_NOTIFY_KEY_PREFIX stringByAppendingString:[self bluetoothTypeIdentifierForDevice:device]];
			if (HWGBTBoolForKey(notifyKey, YES)) {
				[self bluetoothName:[device name] connected:YES iconName:[self bluetoothIconNameForDevice:device] extraInfo:[self bluetoothExtraInfoForDevice:device]];
			}
		}
	}
}

#pragma mark HWGrowlPluginProtocol

// -delegate / -setDelegate: are auto-generated from the @property (weak) +
// @synthesize above (satisfies HWGrowlPluginProtocol). No manual accessors —
// hand-written ones could silently mask the property's weak qualifier.
-(NSString*)pluginDisplayName {
	return NSLocalizedString(@"Bluetooth Monitor", @"");
}
-(NSImage*)preferenceIcon {
	// Resolved fresh every call (not cached) since this is user-customizable via the Icons
	// tab's "Module Icon (Sidebar)" row — see the same note on AudioMonitor's -preferenceIcon.
	return HWGResolveIconNamed(@"HWGPrefsBluetooth-Module");
}
// F33: single generic handler for every per-field visibility checkbox. Each checkbox's
// `identifier` carries the NSUserDefaults key it controls.
-(IBAction)fieldToggleChanged:(NSButton*)sender {
	NSString *key = sender.identifier;
	if (!key) return;
	[[NSUserDefaults standardUserDefaults] setBool:(sender.state == NSControlStateValueOn) forKey:key];
}

-(NSButton *)checkboxWithKey:(NSString *)key title:(NSString *)title defaultOn:(BOOL)defaultOn {
	NSButton *box = [NSButton checkboxWithTitle:title target:self action:@selector(fieldToggleChanged:)];
	box.identifier = key;
	box.state = HWGBTBoolForKey(key, defaultOn) ? NSControlStateValueOn : NSControlStateValueOff;
	box.translatesAutoresizingMaskIntoConstraints = NO;
	return box;
}

-(NSView*)preferencePane {
	if (prefsView) return prefsView;

	NSTabView *tabs = [[NSTabView alloc] initWithFrame:NSMakeRect(0, 0, 560, 260)];
	// AppDelegate sizes this view once via -setFrameSize: to match the prefs window's
	// container, then never again — without an autoresizing mask this view (and its
	// visible tab box) stays whatever size it was created at even if the user later
	// resizes the Preferences window. Track the container's size going forward.
	tabs.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

	// --- Tab: General (pre-existing "Notification fields" content) ---
	NSView *v = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, tabs.bounds.size.width, 190)];

	NSTextField *header = [NSTextField labelWithString:NSLocalizedString(@"Notification fields", @"")];
	header.font = [NSFont boldSystemFontOfSize:12];
	header.textColor = [NSColor secondaryLabelColor];
	header.translatesAutoresizingMaskIntoConstraints = NO;

	NSArray<NSButton*> *rows = @[
		[self checkboxWithKey:HWG_BT_SHOW_TYPE_KEY    title:NSLocalizedString(@"Device type (Keyboard, Mouse, Headphones…)", @"") defaultOn:YES],
		[self checkboxWithKey:HWG_BT_SHOW_PAIRED_KEY  title:NSLocalizedString(@"Paired state", @"") defaultOn:YES],
		[self checkboxWithKey:HWG_BT_SHOW_ADDRESS_KEY title:NSLocalizedString(@"MAC address", @"") defaultOn:YES],
		[self checkboxWithKey:HWG_BT_SHOW_BATTERY_KEY title:NSLocalizedString(@"Battery level (Apple accessories: AirPods, Magic Mouse/Keyboard/Trackpad)", @"") defaultOn:YES],
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
			[row.heightAnchor   constraintEqualToConstant:24],
		]];
		previous = row;
	}

	NSTabViewItem *generalItem = [[NSTabViewItem alloc] initWithIdentifier:@"general"];
	generalItem.label = NSLocalizedString(@"General", @"");
	generalItem.view = v;
	[tabs addTabViewItem:generalItem];

	// --- Tab: Icons (per-event icon overrides) ---
	CGFloat iconsPad = 16;
	CGFloat iconsWidth = tabs.bounds.size.width - 2 * iconsPad;

	HWGIconPickerView *iconPicker = [[HWGIconPickerView alloc] initWithIconSpecs:@[
		@[@"Module Icon (Sidebar)", @"HWGPrefsBluetooth-Module"],
		@[@"Computer", @"BT-TypeComputer", [HWG_BT_NOTIFY_KEY_PREFIX stringByAppendingString:@"Computer"]],
		@[@"Phone", @"BT-TypePhone", [HWG_BT_NOTIFY_KEY_PREFIX stringByAppendingString:@"Phone"]],
		@[@"Access Point", @"BT-TypeAccessPoint", [HWG_BT_NOTIFY_KEY_PREFIX stringByAppendingString:@"AccessPoint"]],
		@[@"Wearable", @"BT-TypeWearable", [HWG_BT_NOTIFY_KEY_PREFIX stringByAppendingString:@"Wearable"]],
		@[@"Health", @"BT-TypeHealth", [HWG_BT_NOTIFY_KEY_PREFIX stringByAppendingString:@"Health"]],
		@[@"Keyboard", @"BT-TypeKeyboard", [HWG_BT_NOTIFY_KEY_PREFIX stringByAppendingString:@"Keyboard"]],
		@[@"Mouse", @"BT-TypeMouse", [HWG_BT_NOTIFY_KEY_PREFIX stringByAppendingString:@"Mouse"]],
		@[@"Combo", @"BT-TypeCombo", [HWG_BT_NOTIFY_KEY_PREFIX stringByAppendingString:@"Combo"]],
		@[@"Headset", @"BT-TypeHeadset", [HWG_BT_NOTIFY_KEY_PREFIX stringByAppendingString:@"Headset"]],
		@[@"Microphone", @"BT-TypeMicrophone", [HWG_BT_NOTIFY_KEY_PREFIX stringByAppendingString:@"Microphone"]],
		@[@"Speaker", @"BT-TypeSpeaker", [HWG_BT_NOTIFY_KEY_PREFIX stringByAppendingString:@"Speaker"]],
		@[@"Headphones", @"BT-TypeHeadphones", [HWG_BT_NOTIFY_KEY_PREFIX stringByAppendingString:@"Headphones"]],
		@[@"Connected (generic)", @"Bluetooth-On", [HWG_BT_NOTIFY_KEY_PREFIX stringByAppendingString:@"Other"]],
		@[@"Disconnected", @"Bluetooth-Off", HWG_BT_NOTIFY_DISCONNECT_KEY],
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

	NSView *iconsContent = [[HWGFlippedContentView alloc] initWithFrame:NSMakeRect(0, 0, tabs.bounds.size.width, iconsHeaderH + iconsGap + iconPickerH + 2 * iconsPad)];
	iconsHeader.frame = NSMakeRect(iconsPad, iconsPad, iconsWidth, iconsHeaderH);
	[iconsContent addSubview:iconsHeader];
	iconPicker.frame = NSMakeRect(iconsPad, iconsPad + iconsHeaderH + iconsGap, iconsWidth, iconPickerH);
	[iconsContent addSubview:iconPicker];

	NSScrollView *iconsScroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, tabs.bounds.size.width, 320)];
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
	return [NSArray arrayWithObjects:@"BluetoothConnected", @"BluetoothDisconnected", nil];
}
-(NSDictionary*)localizedNames {
	return [NSDictionary dictionaryWithObjectsAndKeys:NSLocalizedString(@"Bluetooth Connected", @""), @"BluetoothConnected",
			  NSLocalizedString(@"Bluetooth Disconnected", @""), @"BluetoothDisconnected", nil];
}
-(NSDictionary*)noteDescriptions {
	return [NSDictionary dictionaryWithObjectsAndKeys:NSLocalizedString(@"Sent when a Bluetooth Device is connected", @""), @"BluetoothConnected",
			  NSLocalizedString(@"Sent when a Bluetooth Device is disconnected", @""), @"BluetoothDisconnected", nil];
}
-(NSArray*)defaultNotifications {
	return [NSArray arrayWithObjects:@"BluetoothConnected", @"BluetoothDisconnected", nil];
}

@end
