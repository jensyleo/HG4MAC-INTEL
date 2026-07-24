//
//  HWGrowlThunderboltMonitor.m
//  HardwareGrowler
//
//  Created by Daniel Siemer on 5/5/12.
//  Copyright (c) 2012 The Growl Project, LLC. All rights reserved.
//

#import "HWGrowlThunderboltMonitor.h"
#include <IOKit/IOKitLib.h>

// kIOMainPortDefault is available since macOS 12 (deployment target is 13).
// (Note: it's a const, not a macro, so a #ifndef fallback would wrongly
// redefine it to the deprecated kIOMasterPortDefault — don't do that.)

// F33: individually configurable fields in the Thunderbolt connect notification's extra
// info — same pattern as Network/Power/USB/Bluetooth Monitor. All default to YES.
#define HWG_TB_SHOW_VIDPID_KEY @"HWGThunderboltShowVIDPID"
#define HWG_TB_SHOW_TYPE_KEY   @"HWGThunderboltShowType"

// F34 candidate #2: eGPU-specific notification, separate from the generic
// ThunderboltConnected/Disconnected pair above. OFF by default per user request — this is a
// NEW behavior (an extra notification on top of the existing generic one), not a visibility
// toggle on an already-firing notice.
#define HWG_TB_NOTIFY_EGPU_KEY @"HWGThunderboltNotifyEGPU"

static BOOL HWGTBBoolForKey(NSString *key, BOOL def) {
	id stored = [[NSUserDefaults standardUserDefaults] objectForKey:key];
	return stored ? [stored boolValue] : def;
}

@interface HWGrowlThunderboltMonitor ()

@property (nonatomic, weak) id<HWGrowlPluginControllerProtocol> delegate;
@property (nonatomic, assign) BOOL notificationsArePrimed;
@property (nonatomic, strong) NSView *prefsView;

// C / Core Foundation pointers — ARC does NOT manage these; keep assign.
@property (nonatomic, assign) IONotificationPortRef ioKitNotificationPort;
@property (nonatomic, assign)	CFRunLoopSourceRef notificationRunLoopSource;
// Persistent IOKit notification iterators — must be IOObjectRelease'd in dealloc.
@property (nonatomic, assign) io_iterator_t addedIterator;
@property (nonatomic, assign) io_iterator_t removedIterator;

@end

@implementation HWGrowlThunderboltMonitor

@synthesize delegate;
@synthesize notificationsArePrimed;
@synthesize ioKitNotificationPort;
@synthesize notificationRunLoopSource;
@synthesize addedIterator;
@synthesize removedIterator;
@synthesize prefsView;

-(id)init {
	if((self = [super init])){
		self.notificationsArePrimed = NO;
		self.ioKitNotificationPort = IONotificationPortCreate(kIOMainPortDefault);
		self.notificationRunLoopSource = IONotificationPortGetRunLoopSource(ioKitNotificationPort);

		// IOKit callbacks should be delivered on the main run loop.
		CFRunLoopAddSource(CFRunLoopGetMain(),
								 notificationRunLoopSource,
								 kCFRunLoopDefaultMode);
	}
	return self;
}

-(void)dealloc {
	// Keep the CF/IOKit teardown; ARC handles ObjC memory. No [super dealloc].
	if (addedIterator)   { IOObjectRelease(addedIterator);   addedIterator = 0; }
	if (removedIterator) { IOObjectRelease(removedIterator); removedIterator = 0; }
	if (ioKitNotificationPort) {
		CFRunLoopRemoveSource(CFRunLoopGetMain(), notificationRunLoopSource, kCFRunLoopDefaultMode);
		IONotificationPortDestroy(ioKitNotificationPort);
	}
}

-(void)postRegistrationInit {
	[self registerForThunderboltNotifications];
}

-(NSString*)nameForThunderboltObject:(io_object_t)thisObject {
	kern_return_t	nameResult;
	io_name_t		deviceNameChars;

	// IORegistryEntryGetName fills an io_name_t (fixed buffer) — the correct API for
	// the registry entry's name, like USBMonitor. (The old code used
	// IORegistryEntryGetProperty for "IOName" with an UNINITIALIZED size in/out param
	// → undefined behavior, and "IOName" rarely exists on IOPCIDevice.)
	nameResult = IORegistryEntryGetName(thisObject, deviceNameChars);
	if (nameResult != KERN_SUCCESS) {
		NSLog(@"Could not get name for Thunderbolt object: IORegistryEntryGetName returned 0x%x", nameResult);
		return NULL;
	}

	NSString* tempDeviceName = [NSString stringWithCString:deviceNameChars encoding:NSUTF8StringEncoding];
	if (tempDeviceName) {
		return tempDeviceName;
	}
		
	return NSLocalizedString(@"Unnamed Thunderbolt Device", @"");
}

#pragma mark Callbacks

-(void)tbDeviceName:(NSString*)deviceName added:(BOOL)added extraInfo:(NSString *)extraInfo {
	NSString *title = added ? NSLocalizedString(@"Thunderbolt Connection", @"") : NSLocalizedString(@"Thunderbolt Disconnection", @"");

	NSString *imageName = added ? @"Thunderbolt-On" : @"Thunderbolt-Off";
	NSData *iconData = [[NSImage imageNamed:imageName] TIFFRepresentation];
	NSString *description = extraInfo ? [NSString stringWithFormat:@"%@\n%@", deviceName, extraInfo] : deviceName;

	[delegate notifyWithName:added ? @"ThunderboltConnected" : @"ThunderboltDisconnected"
							 title:title
					 description:description
							  icon:iconData
			  identifierString:deviceName
				  contextString:nil
							plugin:self];
}

// PCI-SIG published base class codes (top byte of the "class-code" registry property) —
// public, standard PCI Local Bus spec values, read the same way as the device name via
// IORegistryEntryCreateCFProperty. 0x06 (Bridge) is what a Thunderbolt dock/hub's own PCI
// function typically enumerates as, mirroring the bDeviceClass==9 hub check in USBMonitor.
-(NSString *)tbClassNameForBaseClass:(uint8_t)baseClass {
	switch (baseClass) {
		case 0x01: return NSLocalizedString(@"Storage Controller", @"");
		case 0x02: return NSLocalizedString(@"Network Controller", @"");
		case 0x03: return NSLocalizedString(@"Display Controller", @"");
		case 0x04: return NSLocalizedString(@"Multimedia Controller", @"");
		case 0x06: return NSLocalizedString(@"Bridge / Dock", @"");
		case 0x07: return NSLocalizedString(@"Communication Controller", @"");
		case 0x09: return NSLocalizedString(@"Input Device", @"");
		case 0x0C: return NSLocalizedString(@"Serial Bus Controller", @"");
		case 0x0D: return NSLocalizedString(@"Wireless Controller", @"");
		default:   return nil;
	}
}

-(NSString *)tbExtraInfoForDevice:(io_object_t)device {
	NSMutableArray<NSString*> *lines = [NSMutableArray array];

	if (HWGTBBoolForKey(HWG_TB_SHOW_VIDPID_KEY, YES)) {
		int vendorID = -1, deviceID = -1;
		CFTypeRef vidRef = IORegistryEntryCreateCFProperty(device, CFSTR("vendor-id"), kCFAllocatorDefault, 0);
		if (vidRef) {
			if (CFGetTypeID(vidRef) == CFDataGetTypeID() && CFDataGetLength((CFDataRef)vidRef) >= 2) {
				const UInt8 *bytes = CFDataGetBytePtr((CFDataRef)vidRef);
				vendorID = bytes[0] | (bytes[1] << 8);
			} else if (CFGetTypeID(vidRef) == CFNumberGetTypeID()) {
				CFNumberGetValue((CFNumberRef)vidRef, kCFNumberIntType, &vendorID);
			}
			CFRelease(vidRef);
		}
		CFTypeRef didRef = IORegistryEntryCreateCFProperty(device, CFSTR("device-id"), kCFAllocatorDefault, 0);
		if (didRef) {
			if (CFGetTypeID(didRef) == CFDataGetTypeID() && CFDataGetLength((CFDataRef)didRef) >= 2) {
				const UInt8 *bytes = CFDataGetBytePtr((CFDataRef)didRef);
				deviceID = bytes[0] | (bytes[1] << 8);
			} else if (CFGetTypeID(didRef) == CFNumberGetTypeID()) {
				CFNumberGetValue((CFNumberRef)didRef, kCFNumberIntType, &deviceID);
			}
			CFRelease(didRef);
		}
		if (vendorID >= 0 && deviceID >= 0) {
			[lines addObject:[NSString stringWithFormat:NSLocalizedString(@"VID:PID:\t%04X:%04X", @""), vendorID, deviceID]];
		}
	}

	if (HWGTBBoolForKey(HWG_TB_SHOW_TYPE_KEY, YES)) {
		CFTypeRef classRef = IORegistryEntryCreateCFProperty(device, CFSTR("class-code"), kCFAllocatorDefault, 0);
		if (classRef) {
			uint32_t classCode = 0;
			BOOL got = NO;
			if (CFGetTypeID(classRef) == CFDataGetTypeID() && CFDataGetLength((CFDataRef)classRef) >= 3) {
				const UInt8 *bytes = CFDataGetBytePtr((CFDataRef)classRef);
				classCode = bytes[0] | (bytes[1] << 8) | (bytes[2] << 16);
				got = YES;
			} else if (CFGetTypeID(classRef) == CFNumberGetTypeID()) {
				CFNumberGetValue((CFNumberRef)classRef, kCFNumberSInt32Type, (int32_t *)&classCode);
				got = YES;
			}
			if (got) {
				uint8_t baseClass = (classCode >> 16) & 0xFF;
				NSString *className = [self tbClassNameForBaseClass:baseClass];
				if (className) [lines addObject:[NSString stringWithFormat:NSLocalizedString(@"Type:\t%@", @""), className]];
			}
			CFRelease(classRef);
		}
	}

	return [lines count] ? [lines componentsJoinedByString:@"\n"] : nil;
}

// F34 #2: reads the PCI base-class code the same way -tbExtraInfoForDevice: does, to
// decide if a device is an eGPU candidate — kept separate from that method since this
// check must run regardless of the "Type" F33 checkbox (HWG_TB_SHOW_TYPE_KEY), which only
// controls whether the class name is INCLUDED in the generic notification's text.
-(BOOL)isDisplayControllerDevice:(io_object_t)device {
	CFTypeRef classRef = IORegistryEntryCreateCFProperty(device, CFSTR("class-code"), kCFAllocatorDefault, 0);
	if (!classRef) return NO;
	uint32_t classCode = 0;
	BOOL got = NO;
	if (CFGetTypeID(classRef) == CFDataGetTypeID() && CFDataGetLength((CFDataRef)classRef) >= 3) {
		const UInt8 *bytes = CFDataGetBytePtr((CFDataRef)classRef);
		classCode = bytes[0] | (bytes[1] << 8) | (bytes[2] << 16);
		got = YES;
	} else if (CFGetTypeID(classRef) == CFNumberGetTypeID()) {
		CFNumberGetValue((CFNumberRef)classRef, kCFNumberSInt32Type, (int32_t *)&classCode);
		got = YES;
	}
	CFRelease(classRef);
	if (!got) return NO;
	uint8_t baseClass = (classCode >> 16) & 0xFF;
	return baseClass == 0x03;   // PCI-SIG "Display Controller"
}

// F34 #2: eGPU-specific notification — a Display Controller PCI function hot-plugged after
// launch is, in practice, an external GPU attached via Thunderbolt (internal GPUs on Apple
// Silicon don't enumerate as a post-launch IOPCIDevice add/remove). OFF by default.
-(void)tbNotifyEGPUIfNeeded:(io_object_t)device deviceName:(NSString *)deviceName added:(BOOL)added {
	if (!HWGTBBoolForKey(HWG_TB_NOTIFY_EGPU_KEY, NO)) return;
	if (![self isDisplayControllerDevice:device]) return;

	NSString *title = added ? NSLocalizedString(@"eGPU Connected", @"") : NSLocalizedString(@"eGPU Disconnected", @"");
	NSString *imageName = added ? @"Thunderbolt-On" : @"Thunderbolt-Off";
	NSData *iconData = [[NSImage imageNamed:imageName] TIFFRepresentation];

	[delegate notifyWithName:added ? @"ThunderboltEGPUConnected" : @"ThunderboltEGPUDisconnected"
							 title:title
					 description:deviceName ?: @""
							  icon:iconData
			  identifierString:[NSString stringWithFormat:@"eGPU-%@", deviceName]
				  contextString:nil
							plugin:self];
}

-(void)tbDeviceAdded:(io_iterator_t)iterator {
	io_object_t	thisObject;
	while ((thisObject = IOIteratorNext(iterator))) {
		// Only notify for real hot-plug events (after priming). Notifying for
		// every pre-existing IOPCIDevice at launch would spam dozens of
		// internal devices, so we deliberately ignore the launch enumeration.
		if (notificationsArePrimed) {
			NSString *deviceName = [self nameForThunderboltObject:thisObject];
			if (deviceName) {
				[self tbDeviceName:deviceName added:YES extraInfo:[self tbExtraInfoForDevice:thisObject]];
				[self tbNotifyEGPUIfNeeded:thisObject deviceName:deviceName added:YES];
			}
		}
		IOObjectRelease(thisObject);
	}
}

static void tbDeviceAdded(void *refCon, io_iterator_t iterator) {
	HWGrowlThunderboltMonitor *monitor = (__bridge HWGrowlThunderboltMonitor*)refCon;
	[monitor tbDeviceAdded:iterator];
}

-(void)tbDeviceRemoved:(io_iterator_t)iterator {
	io_object_t thisObject;
	while ((thisObject = IOIteratorNext(iterator))) {
		if (notificationsArePrimed) {
			NSString *deviceName = [self nameForThunderboltObject:thisObject];
			// No extraInfo on removal: registry properties are frequently unreadable
			// from a terminating entry by the time this callback fires. Same limitation
			// applies to the eGPU class-code check below — it will often silently miss
			// eGPU DISCONNECT (but not connect), documented in README.
			if (deviceName) {
				[self tbDeviceName:deviceName added:NO extraInfo:nil];
				[self tbNotifyEGPUIfNeeded:thisObject deviceName:deviceName added:NO];
			}
		}
		IOObjectRelease(thisObject);
	}
}

static void tbDeviceRemoved(void *refCon, io_iterator_t iterator) {
	HWGrowlThunderboltMonitor *monitor = (__bridge HWGrowlThunderboltMonitor*)refCon;
	[monitor tbDeviceRemoved:iterator];
}

#pragma mark -

-(void)registerForThunderboltNotifications {
	//http://developer.apple.com/documentation/DeviceDrivers/Conceptual/AccessingHardware/AH_Finding_Devices/chapter_4_section_2.html#//apple_ref/doc/uid/TP30000379/BABEACCJ
	kern_return_t   matchingResult;
	kern_return_t   removeNoteResult;
	CFDictionaryRef myThunderboltMatchDictionary;
	// addedIterator / removedIterator are now ivars (released in dealloc).
	
	//	NSLog(@"registerForThunderboltNotifications");
	
	//	Setup a matching dictionary.
	myThunderboltMatchDictionary = IOServiceMatching("IOPCIDevice");
	
	//	Register our notification
	matchingResult = IOServiceAddMatchingNotification(ioKitNotificationPort,
																	  kIOPublishNotification,
																	  myThunderboltMatchDictionary,
																	  tbDeviceAdded,
																	  (__bridge void *)self,
																	  &addedIterator);
	
	if (matchingResult)
		NSLog(@"matching notification registration failed: %d)", matchingResult);
	
	//	Prime the notifications (And deal with the existing devices)...
	[self tbDeviceAdded:addedIterator];
	
	//	Register for removal notifications.
	
	//	It seems we have to make a new dictionary...  reusing the old one didn't work.
	myThunderboltMatchDictionary = IOServiceMatching("IOPCIDevice");
	removeNoteResult = IOServiceAddMatchingNotification(ioKitNotificationPort,
																		 kIOTerminatedNotification,
																		 myThunderboltMatchDictionary,
																		 tbDeviceRemoved,
																		 (__bridge void *)self,
																		 &removedIterator);
	
	// Matching notification must be "primed" by iterating over the
	// iterator returned from IOServiceAddMatchingNotification(), so
	// we call our device removed method here...
	//
	if (kIOReturnSuccess != removeNoteResult)
		NSLog(@"Couldn't add device removal notification");
	else
		[self tbDeviceRemoved:removedIterator];
	
	self.notificationsArePrimed = YES;
}

#pragma mark HWGrowlPluginProtocol

// -delegate / -setDelegate: auto-generated from @property (weak) + @synthesize.
-(NSString*)pluginDisplayName {
	return NSLocalizedString(@"Thunderbolt Monitor", @"");
}
-(NSImage*)preferenceIcon {
	static NSImage *_icon = nil;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		_icon = [NSImage imageNamed:@"HWGPrefsThunderbolt"];
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
	box.state = HWGTBBoolForKey(key, defaultOn) ? NSControlStateValueOn : NSControlStateValueOff;
	box.translatesAutoresizingMaskIntoConstraints = NO;
	return box;
}

-(NSView*)preferencePane {
	if (prefsView) return prefsView;

	NSView *v = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 380, 174)];

	NSTextField *header = [NSTextField labelWithString:NSLocalizedString(@"Notification fields", @"")];
	header.font = [NSFont boldSystemFontOfSize:12];
	header.textColor = [NSColor secondaryLabelColor];
	header.translatesAutoresizingMaskIntoConstraints = NO;

	NSArray<NSButton*> *rows = @[
		[self checkboxWithKey:HWG_TB_SHOW_VIDPID_KEY title:NSLocalizedString(@"Vendor/device ID (VID:PID)", @"") defaultOn:YES],
		[self checkboxWithKey:HWG_TB_SHOW_TYPE_KEY    title:NSLocalizedString(@"Device type (Storage, Display, Bridge/Dock…)", @"") defaultOn:YES],
		// F34 #2: OFF by default — new behavior, extra notification on top of the generic one.
		[self checkboxWithKey:HWG_TB_NOTIFY_EGPU_KEY  title:NSLocalizedString(@"Notify separately when an eGPU is connected", @"") defaultOn:NO],
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
	return [NSArray arrayWithObjects:@"ThunderboltConnected", @"ThunderboltDisconnected", nil];
}
-(NSDictionary*)localizedNames {
	return [NSDictionary dictionaryWithObjectsAndKeys:NSLocalizedString(@"Thunderbolt Connected", @""), @"ThunderboltConnected",
			  NSLocalizedString(@"Thunderbolt Disconnected", @""), @"ThunderboltDisconnected", nil];
}
-(NSDictionary*)noteDescriptions {
	return [NSDictionary dictionaryWithObjectsAndKeys:NSLocalizedString(@"Sent when a Thunderbolt Device is connected", @""), @"ThunderboltConnected",
			  NSLocalizedString(@"Sent when a Thunderbolt Device is disconnected", @""), @"ThunderboltDisconnected", nil];
}
-(NSArray*)defaultNotifications {
	return [NSArray arrayWithObjects:@"ThunderboltConnected", @"ThunderboltDisconnected", nil];
}

@end
