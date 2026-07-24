//
//  TMSliderControl.h
//  HardwareGrowler-NC
//
//  Rewritten from scratch for this fork (see TMSliderControl.m).
//  Copyright (c) 2026 Jensy Leonardo Martínez Cruz.
//  Licensed under the GNU General Public License v3.0 (GPLv3) — see LICENSE.
//

#import <Cocoa/Cocoa.h>

@interface TMSliderControl : NSControl

@property (nonatomic, assign) NSInteger state;
@property (nonatomic, copy) void (^actionBlock)(NSInteger state);

- (void)setState:(NSInteger)state animated:(BOOL)animated;

@end
