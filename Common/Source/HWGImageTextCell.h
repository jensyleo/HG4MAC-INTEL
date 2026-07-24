//
//  HWGImageTextCell.h
//  HardwareGrowler-NC
//
//  An NSTextFieldCell that draws a small image to the left of its text, used
//  for the module list in the preferences window.
//
//  This is a clean-room, original implementation written for this fork to
//  replace the Apple sample-code cell it previously relied on. No third-party
//  code is used; the image+text cell is a common Cocoa idiom implemented here
//  from scratch.
//
//  Copyright (c) 2026 Jensy Leonardo Martínez Cruz.
//  Licensed under the GNU General Public License v3.0 (GPLv3) — see LICENSE.
//

#import <Cocoa/Cocoa.h>

@interface HWGImageTextCell : NSTextFieldCell

/// Image drawn to the left of the text. nil draws text only.
@property (atomic, strong) NSImage *image;

@end
