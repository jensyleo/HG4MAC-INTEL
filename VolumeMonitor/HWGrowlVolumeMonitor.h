//
//  HWGrowlVolumeMonitor.h
//  HardwareGrowler
//
//  Created by Daniel Siemer on 5/3/12.
//  Copyright (c) 2012 The Growl Project, LLC. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <DiskArbitration/DiskArbitration.h>
#import "HardwareGrowlPlugin.h"

@interface VolumeInfo : NSObject {
	NSData *iconData;
	NSString *name;
	NSString *path;
}

@property (nonatomic, retain) NSData *iconData;
@property (nonatomic, retain) NSString *name;
@property (nonatomic, retain) NSString *path;
// F30 follow-up (23-jul-2026): device-type category (e.g. "USBDrive"/"SDCard"/
// "ExternalDisk"), captured at -volumeWillUnmount: time (while the path is still live)
// so the eventual unmount notification can use the same specific icon the mount
// notification used, instead of always falling back to the plain eject icon.
@property (nonatomic, retain) NSString *deviceCategory;

+ (VolumeInfo *) volumeInfoForMountWithPath:(NSString *)aPath;
+ (VolumeInfo *) volumeInfoForUnmountWithPath:(NSString *)aPath;

- (id) initForMountWithPath:(NSString *)aPath;
- (id) initForUnmountWithPath:(NSString *)aPath;
- (id) initWithPath:(NSString *)aPath;

@end

@interface HWGrowlVolumeMonitor : NSObject <HWGrowlPluginProtocol, HWGrowlPluginNotifierProtocol, NSTableViewDelegate>

@property (nonatomic, retain) IBOutlet NSView *prefsView;

@end
