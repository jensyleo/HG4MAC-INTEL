//
//  HWGrowlPowerMonitor.h
//  HardwareGrowler
//
//  Created by Daniel Siemer on 5/6/12.
//  Copyright (c) 2012 The Growl Project, LLC. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "HardwareGrowlPlugin.h"

typedef enum {
	HGUnknownPower = -1,
	HGACPower = 0,
	HGBatteryPower,
	HGUPSPower
} HGPowerSource;

@interface HWGrowlPowerMonitor : NSObject <HWGrowlPluginProtocol, HWGrowlPluginNotifierProtocol>

// strong (not assign/weak): the prefs nib's top-level view must be owned by us, or
// it deallocs right after loadNibNamed:owner:topLevelObjects: (blank pane otherwise).
@property (nonatomic, strong) IBOutlet NSView *prefsView;

@end
