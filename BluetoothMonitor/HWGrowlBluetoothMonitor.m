//
//  HWGrowlBluetoothMonitor.m
//  HardwareGrowler
//
//  Created by Daniel Siemer on 5/5/12.
//  Copyright (c) 2012 The Growl Project, LLC. All rights reserved.
//

// compile with ARC: -fobjc-arc
#import "HWGrowlBluetoothMonitor.h"
#import <stdlib.h>
#import <IOBluetooth/IOBluetooth.h>

// F33: individually configurable fields in the Bluetooth connect notification's extra
// info — same pattern as Network/Power/USB Monitor. All default to YES.
#define HWG_BT_SHOW_TYPE_KEY    @"HWGBluetoothShowType"
#define HWG_BT_SHOW_PAIRED_KEY  @"HWGBluetoothShowPaired"
#define HWG_BT_SHOW_ADDRESS_KEY @"HWGBluetoothShowAddress"

static BOOL HWGBTBoolForKey(NSString *key, BOOL def) {
	id stored = [[NSUserDefaults standardUserDefaults] objectForKey:key];
	return stored ? [stored boolValue] : def;
}

@interface HWGrowlBluetoothMonitor ()

@property (nonatomic, weak) id<HWGrowlPluginControllerProtocol> delegate;
@property (nonatomic, assign) BOOL starting;
@property (nonatomic, strong) NSView *prefsView;

// strong: we keep this object to call -unregister on it later, so the monitor
// must own it.
@property (nonatomic, strong) IOBluetoothUserNotification *connectionNotification;

@end

@implementation HWGrowlBluetoothMonitor

@synthesize delegate;
@synthesize starting;
@synthesize connectionNotification;
@synthesize prefsView;

-(void)dealloc {
	[connectionNotification unregister];
	// ARC handles the release; no [super dealloc].
}

-(id)init {
	// Legacy 10.7-10.7.2 incompatibility check removed: the app's deployment
	// target is 13.0, so that range is unreachable.
	self = [super init];
	return self;
}

-(void)postRegistrationInit {
	self.starting = YES;
	self.connectionNotification = [IOBluetoothDevice registerForConnectNotifications:self 
																									selector:@selector(bluetoothConnection:device:)];
	self.starting = NO;
}

-(void)bluetoothName:(NSString*)name connected:(BOOL)connected extraInfo:(NSString *)extraInfo {
	NSString *title = connected ? NSLocalizedString(@"Bluetooth Connection", @"") : NSLocalizedString(@"Bluetooth Disconnection", @"");

    NSString *imageName = (connected ? @"Bluetooth-On" : @"Bluetooth-Off");
	NSData *iconData = [[NSImage imageNamed:imageName] TIFFRepresentation];
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

	return [lines count] ? [lines componentsJoinedByString:@"\n"] : nil;
}

-(void)bluetoothDisconnection:(IOBluetoothUserNotification*)note
							  device:(IOBluetoothDevice*)device
{
	// No extraInfo on disconnect: class/paired-state read the same way as connect, but a
	// disconnecting device's properties are less reliably available by the time this fires.
	[self bluetoothName:[device name] connected:NO extraInfo:nil];
	[note unregister];

}

-(void)bluetoothConnection:(IOBluetoothUserNotification*)note
						  device:(IOBluetoothDevice*)device
{
	if (!starting || [delegate onLaunchEnabled])
		[self bluetoothName:[device name] connected:YES extraInfo:[self bluetoothExtraInfoForDevice:device]];

	[device registerForDisconnectNotification:self selector:@selector(bluetoothDisconnection:device:)];
}

#pragma mark HWGrowlPluginProtocol

// -delegate / -setDelegate: are auto-generated from the @property (weak) +
// @synthesize above (satisfies HWGrowlPluginProtocol). No manual accessors —
// hand-written ones could silently mask the property's weak qualifier.
-(NSString*)pluginDisplayName {
	return NSLocalizedString(@"Bluetooth Monitor", @"");
}
-(NSImage*)preferenceIcon {
	static NSImage *_icon = nil;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		_icon = [NSImage imageNamed:@"HWGPrefsBluetooth"];
	});
	return _icon;
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

	NSView *v = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 380, 160)];

	NSTextField *header = [NSTextField labelWithString:NSLocalizedString(@"Notification fields", @"")];
	header.font = [NSFont boldSystemFontOfSize:12];
	header.textColor = [NSColor secondaryLabelColor];
	header.translatesAutoresizingMaskIntoConstraints = NO;

	NSArray<NSButton*> *rows = @[
		[self checkboxWithKey:HWG_BT_SHOW_TYPE_KEY    title:NSLocalizedString(@"Device type (Keyboard, Mouse, Headphones…)", @"") defaultOn:YES],
		[self checkboxWithKey:HWG_BT_SHOW_PAIRED_KEY  title:NSLocalizedString(@"Paired state", @"") defaultOn:YES],
		[self checkboxWithKey:HWG_BT_SHOW_ADDRESS_KEY title:NSLocalizedString(@"MAC address", @"") defaultOn:YES],
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

	prefsView = v;
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
