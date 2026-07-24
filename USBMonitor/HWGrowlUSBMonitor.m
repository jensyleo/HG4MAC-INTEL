//
//  HWGrowlUSBMonitor.m
//  HardwareGrowler
//
//  Created by Daniel Siemer on 5/5/12.
//  Copyright (c) 2012 The Growl Project, LLC. All rights reserved.
//

// compile with ARC: -fobjc-arc
#import "HWGrowlUSBMonitor.h"
#include <IOKit/IOKitLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/usb/IOUSBLib.h>
#include <IOKit/usb/USB.h>

// kIOMainPortDefault is available since macOS 12 (deployment target is 13).
// (It's a const, not a macro — a #ifndef fallback would wrongly redefine it to
// the deprecated kIOMasterPortDefault.)

static void usbDeviceAdded(void *refCon, io_iterator_t iterator);
static void usbDeviceRemoved(void *refCon, io_iterator_t iterator);

// F33: individually configurable fields in the USB connect notification's extra info —
// same pattern as Network/Power Monitor. All default to YES.
#define HWG_USB_SHOW_MANUFACTURER_KEY @"HWGUSBShowManufacturer"
#define HWG_USB_SHOW_VIDPID_KEY       @"HWGUSBShowVIDPID"
#define HWG_USB_SHOW_SPEED_KEY        @"HWGUSBShowSpeed"
#define HWG_USB_SHOW_CLASS_KEY        @"HWGUSBShowDeviceClass"

static BOOL HWGUSBBoolForKey(NSString *key, BOOL def) {
	id stored = [[NSUserDefaults standardUserDefaults] objectForKey:key];
	return stored ? [stored boolValue] : def;
}

@interface HWGrowlUSBMonitor ()

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

@implementation HWGrowlUSBMonitor

@synthesize delegate;
@synthesize notificationsArePrimed;
@synthesize ioKitNotificationPort;
@synthesize notificationRunLoopSource;
@synthesize addedIterator;
@synthesize removedIterator;
@synthesize prefsView;

-(void)dealloc {
	// Keep the CF/IOKit teardown; ARC handles ObjC memory. No [super dealloc].
	if (addedIterator)   { IOObjectRelease(addedIterator);   addedIterator = 0; }
	if (removedIterator) { IOObjectRelease(removedIterator); removedIterator = 0; }
	if (self.ioKitNotificationPort) {
		CFRunLoopRemoveSource(CFRunLoopGetMain(), self.notificationRunLoopSource, kCFRunLoopDefaultMode);
		IONotificationPortDestroy(self.ioKitNotificationPort);
	}
}

-(id)init {
	if((self = [super init])){
		self.notificationsArePrimed = NO;

		self.ioKitNotificationPort = IONotificationPortCreate(kIOMainPortDefault);
		self.notificationRunLoopSource = IONotificationPortGetRunLoopSource(ioKitNotificationPort);

		CFRunLoopAddSource(CFRunLoopGetMain(),
								 notificationRunLoopSource,
								 kCFRunLoopDefaultMode);
	}
	return self;
}

-(void)postRegistrationInit {
	[self registerForUSBNotifications];
}

-(void)registerForUSBNotifications {
	//http://developer.apple.com/documentation/DeviceDrivers/Conceptual/AccessingHardware/AH_Finding_Devices/chapter_4_section_2.html#//apple_ref/doc/uid/TP30000379/BABEACCJ
	kern_return_t	matchingResult;
	kern_return_t	removeNoteResult;
	// addedIterator / removedIterator are now ivars (released in dealloc).

	//	NSLog(@"registerForUSBNotifications");
	
	//	Setup a matching Dictionary.
	CFDictionaryRef myMatchDictionary;
	myMatchDictionary = IOServiceMatching(kIOUSBDeviceClassName);
	
	//	Register our notification
	matchingResult = IOServiceAddMatchingNotification(ioKitNotificationPort,
																	  kIOFirstPublishNotification,
																	  myMatchDictionary,
																	  usbDeviceAdded,
																	  (__bridge void *)self,
																	  &addedIterator);
	
	if (matchingResult)
		NSLog(@"matching notification registration failed: %d", matchingResult);
	
	//	Prime the Notifications (And Deal with the existing devices)...
	[self usbDeviceAdded:addedIterator];
	
	//	Register for removal notifications.
	//	It seems we have to make a new dictionary...  reusing the old one didn't work.
	
	myMatchDictionary = IOServiceMatching(kIOUSBDeviceClassName);
	removeNoteResult = IOServiceAddMatchingNotification(ioKitNotificationPort,
																		 kIOTerminatedNotification,
																		 myMatchDictionary,
																		 usbDeviceRemoved,
																		 (__bridge void *)self,
																		 &removedIterator);
	
	// Matching notification must be "primed" by iterating over the
	// iterator returned from IOServiceAddMatchingNotification(), so
	// we call our device removed method here...
	//
	if (kIOReturnSuccess != removeNoteResult) {
		NSLog(@"Couldn't add device removal notification");
	} else {
		// Prime the removal iterator exactly once. (The old code drained it
		// twice — once here and again via usbDeviceRemoved(NULL, …) which ran
		// unconditionally due to a missing-braces bug — leaving the removal
		// notification mis-primed.)
		[self usbDeviceRemoved:removedIterator];
	}

	self.notificationsArePrimed = YES;
}

-(void)usbDeviceID:(uint64_t)deviceID name:(NSString*)deviceName added:(BOOL)added isHub:(BOOL)isHub extraInfo:(NSString *)extraInfo {
	(void)deviceID; // no longer used for identity — see identifierString below.
	NSString *title;
	if (isHub) {
		title = added ? NSLocalizedString(@"USB Hub/Dock Connection", @"")
						  : NSLocalizedString(@"USB Hub/Dock Disconnection", @"");
	} else {
		title = added ? NSLocalizedString(@"USB Connection", @"") : NSLocalizedString(@"USB Disconnection", @"");
	}

    NSString *imageName = added ? @"USB-On" : @"USB-Off";
    NSData *iconData = [[NSImage imageNamed:imageName] TIFFRepresentation];
	NSString *description = extraInfo ? [NSString stringWithFormat:@"%@\n%@", deviceName, extraInfo] : deviceName;
	// Use the device NAME as the bounce/dedup identifier (matches Bluetooth/Volume/
	// Thunderbolt), not the IOKit registry entry ID: that ID is a fresh, ephemeral
	// kernel object ID assigned on every single enumeration, so it's NEVER the same
	// across reconnects of the same physical device — bounce detection (which keys off
	// this identifier) could never see "the same device" flapping, so a rapidly
	// bouncing USB device/hub never triggered "Unstable device".
	[delegate notifyWithName:added ? @"USBConnected" : @"USBDisconnected"
							 title:title
					 description:description
							  icon:iconData
			  identifierString:deviceName
				  contextString:nil
							plugin:self];
}

// USB-IF standard device class code for hubs (0x09) — stable, permanent value
// from the USB spec, used to tell an actual hub/dock apart from an ordinary
// device (e.g. so a connected USB-C dock reads as "USB Hub/Dock" rather than
// showing only its individual sub-devices, none of which self-identify as
// the dock itself).
static const uint8_t kHWGUSBHubDeviceClass = 9;

-(BOOL)deviceIsHub:(io_object_t)device {
	CFTypeRef classNum = IORegistryEntryCreateCFProperty(device, CFSTR("bDeviceClass"), kCFAllocatorDefault, 0);
	if (!classNum) return NO;
	uint8_t deviceClass = 0;
	if (CFGetTypeID(classNum) == CFNumberGetTypeID()) {
		CFNumberGetValue((CFNumberRef)classNum, kCFNumberSInt8Type, &deviceClass);
	}
	CFRelease(classNum);
	return deviceClass == kHWGUSBHubDeviceClass;
}

// Human-readable label for the USB-IF's published base class codes
// (usb.org "Defined Class Codes"). Public, permanent spec values — same
// mechanism already used for hub detection above.
-(NSString *)usbClassNameForClassCode:(uint8_t)classCode {
	switch (classCode) {
		case 0x01: return NSLocalizedString(@"Audio", @"");
		case 0x02: return NSLocalizedString(@"Communications", @"");
		case 0x03: return NSLocalizedString(@"HID (Keyboard/Mouse)", @"");
		case 0x05: return NSLocalizedString(@"Physical", @"");
		case 0x06: return NSLocalizedString(@"Still Imaging", @"");
		case 0x07: return NSLocalizedString(@"Printer", @"");
		case 0x08: return NSLocalizedString(@"Mass Storage", @"");
		case 0x09: return NSLocalizedString(@"Hub", @"");
		case 0x0A: return NSLocalizedString(@"CDC Data", @"");
		case 0x0B: return NSLocalizedString(@"Smart Card", @"");
		case 0x0D: return NSLocalizedString(@"Content Security", @"");
		case 0x0E: return NSLocalizedString(@"Video", @"");
		case 0x0F: return NSLocalizedString(@"Personal Healthcare", @"");
		case 0x10: return NSLocalizedString(@"Audio/Video", @"");
		case 0x11: return NSLocalizedString(@"Billboard", @"");
		case 0x12: return NSLocalizedString(@"USB Type-C Bridge", @"");
		case 0xDC: return NSLocalizedString(@"Diagnostic", @"");
		case 0xE0: return NSLocalizedString(@"Wireless Controller", @"");
		case 0xEF: return NSLocalizedString(@"Miscellaneous", @"");
		case 0xFE: return NSLocalizedString(@"Application Specific", @"");
		case 0xFF: return NSLocalizedString(@"Vendor Specific", @"");
		default:   return nil;   // 0x00 = defined per-interface, not device — nothing useful to say
	}
}

// "Device Speed" registry values, per IOKit/usb/USB.h (kUSBDeviceSpeedLow..SuperPlus) —
// public, standard IOUSBHostFamily property already reachable the same way as bDeviceClass.
-(NSString *)usbSpeedNameForSpeedCode:(uint8_t)speedCode {
	switch (speedCode) {
		case 0: return NSLocalizedString(@"USB 1.0 (Low Speed)", @"");
		case 1: return NSLocalizedString(@"USB 1.1 (Full Speed)", @"");
		case 2: return NSLocalizedString(@"USB 2.0 (High Speed)", @"");
		case 3: return NSLocalizedString(@"USB 3.0/3.1 (SuperSpeed)", @"");
		case 4: return NSLocalizedString(@"USB 3.2 (SuperSpeed+)", @"");
		default: return nil;
	}
}

// Builds the extra info lines (manufacturer/product, vendor:product ID, speed, class) for
// a just-connected device, all via public/documented IORegistry properties (same mechanism
// as the existing bDeviceClass-based hub detection) — nil if nothing usable was found. Only
// called on connect: by the time a device is removed, these properties are frequently no
// longer readable from the terminating registry entry.
-(NSString *)usbExtraInfoForDevice:(io_object_t)device {
	NSMutableArray<NSString*> *lines = [NSMutableArray array];

	if (HWGUSBBoolForKey(HWG_USB_SHOW_MANUFACTURER_KEY, YES)) {
		NSString *vendorName = nil, *productName = nil;
		CFTypeRef vn = IORegistryEntryCreateCFProperty(device, CFSTR("USB Vendor Name"), kCFAllocatorDefault, 0);
		if (vn) {
			if (CFGetTypeID(vn) == CFStringGetTypeID()) vendorName = (__bridge_transfer NSString *)vn;
			else CFRelease(vn);
		}
		CFTypeRef pn = IORegistryEntryCreateCFProperty(device, CFSTR("USB Product Name"), kCFAllocatorDefault, 0);
		if (pn) {
			if (CFGetTypeID(pn) == CFStringGetTypeID()) productName = (__bridge_transfer NSString *)pn;
			else CFRelease(pn);
		}
		if (vendorName || productName) {
			NSString *combined = (vendorName && productName) ? [NSString stringWithFormat:@"%@ %@", vendorName, productName]
				: (vendorName ?: productName);
			[lines addObject:[NSString stringWithFormat:NSLocalizedString(@"Manufacturer:\t%@", @""), combined]];
		}
	}

	if (HWGUSBBoolForKey(HWG_USB_SHOW_VIDPID_KEY, YES)) {
		int vid = -1, pid = -1;
		CFTypeRef vidRef = IORegistryEntryCreateCFProperty(device, CFSTR("idVendor"), kCFAllocatorDefault, 0);
		if (vidRef) { if (CFGetTypeID(vidRef) == CFNumberGetTypeID()) CFNumberGetValue((CFNumberRef)vidRef, kCFNumberIntType, &vid); CFRelease(vidRef); }
		CFTypeRef pidRef = IORegistryEntryCreateCFProperty(device, CFSTR("idProduct"), kCFAllocatorDefault, 0);
		if (pidRef) { if (CFGetTypeID(pidRef) == CFNumberGetTypeID()) CFNumberGetValue((CFNumberRef)pidRef, kCFNumberIntType, &pid); CFRelease(pidRef); }
		if (vid >= 0 && pid >= 0) {
			[lines addObject:[NSString stringWithFormat:NSLocalizedString(@"VID:PID:\t%04X:%04X", @""), vid, pid]];
		}
	}

	if (HWGUSBBoolForKey(HWG_USB_SHOW_SPEED_KEY, YES)) {
		CFTypeRef speedRef = IORegistryEntryCreateCFProperty(device, CFSTR("Device Speed"), kCFAllocatorDefault, 0);
		if (speedRef) {
			if (CFGetTypeID(speedRef) == CFNumberGetTypeID()) {
				uint8_t speed = 0;
				CFNumberGetValue((CFNumberRef)speedRef, kCFNumberSInt8Type, &speed);
				NSString *speedName = [self usbSpeedNameForSpeedCode:speed];
				if (speedName) [lines addObject:[NSString stringWithFormat:NSLocalizedString(@"Speed:\t%@", @""), speedName]];
			}
			CFRelease(speedRef);
		}
	}

	if (HWGUSBBoolForKey(HWG_USB_SHOW_CLASS_KEY, YES)) {
		CFTypeRef classRef = IORegistryEntryCreateCFProperty(device, CFSTR("bDeviceClass"), kCFAllocatorDefault, 0);
		if (classRef) {
			if (CFGetTypeID(classRef) == CFNumberGetTypeID()) {
				uint8_t deviceClass = 0;
				CFNumberGetValue((CFNumberRef)classRef, kCFNumberSInt8Type, &deviceClass);
				NSString *className = [self usbClassNameForClassCode:deviceClass];
				if (className) [lines addObject:[NSString stringWithFormat:NSLocalizedString(@"Type:\t%@", @""), className]];
			}
			CFRelease(classRef);
		}
	}

	return [lines count] ? [lines componentsJoinedByString:@"\n"] : nil;
}

-(void)usbDeviceAdded:(io_iterator_t)iterator {
	//	NSLog(@"USB Device Added Notification.");
	io_object_t	thisObject;
	while ((thisObject = IOIteratorNext(iterator))) {
		if (self.notificationsArePrimed || [delegate onLaunchEnabled]) {
			kern_return_t	nameResult;
			io_name_t		deviceNameChars;
			kern_return_t	idResult;
			uint64_t			deviceID;

			//	This works with USB devices...
			//	but apparently not firewire
			nameResult = IORegistryEntryGetName(thisObject, deviceNameChars);
			if (nameResult != KERN_SUCCESS) {
				continue;
			}

			idResult = IORegistryEntryGetRegistryEntryID(thisObject, &deviceID);
			if(idResult != KERN_SUCCESS) {
				continue;
			}

			NSString *deviceName = [NSString stringWithCString:deviceNameChars encoding:NSASCIIStringEncoding];
			if (deviceName) {
				deviceName = [self deviceBusNameSwap:deviceName];
				BOOL isHub = [self deviceIsHub:thisObject];
				NSString *extraInfo = [self usbExtraInfoForDevice:thisObject];

				// NSLog(@"USB Device Attached: %@" , deviceName);
				[self usbDeviceID:deviceID name:deviceName added:YES isHub:isHub extraInfo:extraInfo];
			}
		}

		IOObjectRelease(thisObject);
	}
}

static void usbDeviceAdded(void *refCon, io_iterator_t iterator) {
	HWGrowlUSBMonitor *monitor = (__bridge HWGrowlUSBMonitor*)refCon;
	[monitor usbDeviceAdded:iterator];
}

-(void)usbDeviceRemoved:(io_iterator_t)iterator {
	//	NSLog(@"USB Device Removed Notification.");
	io_object_t thisObject;
	while ((thisObject = IOIteratorNext(iterator))) {
		kern_return_t	nameResult;
		io_name_t		deviceNameChars;
		kern_return_t	idResult;
		uint64_t			deviceID;

		//	This works with USB devices...
		//	but apparently not firewire
		nameResult = IORegistryEntryGetName(thisObject, deviceNameChars);
		if (nameResult != KERN_SUCCESS) {
			continue;
		}
		
		idResult = IORegistryEntryGetRegistryEntryID(thisObject, &deviceID);
		if(idResult != KERN_SUCCESS) {
			continue;
		}
		
		NSString *deviceName = [NSString stringWithCString:deviceNameChars encoding:NSASCIIStringEncoding];
		if (deviceName) {
			deviceName = [self deviceBusNameSwap:deviceName];
			BOOL isHub = [self deviceIsHub:thisObject];

			// NSLog(@"USB Device Detached: %@" , deviceName);
			// No extraInfo on removal: registry properties are frequently unreadable
			// from a terminating entry by the time this callback fires.
			[self usbDeviceID:deviceID name:deviceName added:NO isHub:isHub extraInfo:nil];
		}
		
		IOObjectRelease(thisObject);
	}
}

static void usbDeviceRemoved(void *refCon, io_iterator_t iterator) {
	HWGrowlUSBMonitor *monitor = (__bridge HWGrowlUSBMonitor*)refCon;
	[monitor usbDeviceRemoved:iterator];
}

-(NSString*)deviceBusNameSwap:(NSString*)deviceName {
	NSString *newName = deviceName;
	if (([deviceName compare:@"OHCI Root Hub Simulation"] == NSOrderedSame) ||
		 ([deviceName compare:@"UHCI Root Hub Simulation"] == NSOrderedSame)) {
		newName = NSLocalizedString(@"USB Bus", @"");
	} else if ([deviceName compare:@"EHCI Root Hub Simulation"] == NSOrderedSame ||
				  [deviceName compare:@"XHCI Root Hub USB 2.0 Simulation"] == NSOrderedSame) {
		newName = NSLocalizedString(@"USB 2.0 Bus", @"");
	} else if ([deviceName compare:@"XHCI Root Hub SS Simulation"] == NSOrderedSame) {
		newName = NSLocalizedString(@"USB 3.0 Bus", @"");
	}
	return newName;
}

#pragma mark HWGrowlPluginProtocol

// delegate accessors are auto-synthesized from the @property (weak).
-(NSString*)pluginDisplayName {
	return NSLocalizedString(@"USB Monitor", @"");
}
-(NSImage*)preferenceIcon {
	static NSImage *_icon = nil;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		_icon = [NSImage imageNamed:@"HWGPrefsUSB"];
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
	box.state = HWGUSBBoolForKey(key, defaultOn) ? NSControlStateValueOn : NSControlStateValueOff;
	box.translatesAutoresizingMaskIntoConstraints = NO;
	return box;
}

-(NSView*)preferencePane {
	if (prefsView) return prefsView;

	NSView *v = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 380, 200)];

	NSTextField *header = [NSTextField labelWithString:NSLocalizedString(@"Notification fields", @"")];
	header.font = [NSFont boldSystemFontOfSize:12];
	header.textColor = [NSColor secondaryLabelColor];
	header.translatesAutoresizingMaskIntoConstraints = NO;

	NSArray<NSButton*> *rows = @[
		[self checkboxWithKey:HWG_USB_SHOW_MANUFACTURER_KEY title:NSLocalizedString(@"Manufacturer / product name", @"") defaultOn:YES],
		[self checkboxWithKey:HWG_USB_SHOW_VIDPID_KEY       title:NSLocalizedString(@"Vendor/product ID (VID:PID)", @"") defaultOn:YES],
		[self checkboxWithKey:HWG_USB_SHOW_SPEED_KEY        title:NSLocalizedString(@"USB speed / generation", @"") defaultOn:YES],
		[self checkboxWithKey:HWG_USB_SHOW_CLASS_KEY        title:NSLocalizedString(@"Device class (Mass Storage, HID, Hub…)", @"") defaultOn:YES],
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
	return [NSArray arrayWithObjects:@"USBConnected", @"USBDisconnected", nil];
}
-(NSDictionary*)localizedNames {
	return [NSDictionary dictionaryWithObjectsAndKeys:NSLocalizedString(@"USB Connected", @""), @"USBConnected",
			  NSLocalizedString(@"USB Disconnected", @""), @"USBDisconnected", nil];
}
-(NSDictionary*)noteDescriptions {
	return [NSDictionary dictionaryWithObjectsAndKeys:NSLocalizedString(@"Sent when a USB Device is connected", @""), @"USBConnected",
			  NSLocalizedString(@"Sent when a USB Device is disconnected", @""), @"USBDisconnected", nil];
}
-(NSArray*)defaultNotifications {
	return [NSArray arrayWithObjects:@"USBConnected", @"USBDisconnected", nil];
}

@end
