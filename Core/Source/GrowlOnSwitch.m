//
//  GrowlOnSwitch.m
//  GrowlSlider
//
//  Created by Daniel Siemer on 1/10/12.
//  Copyright (c) 2012 The Growl Project, LLC. All rights reserved.
//

#import "GrowlOnSwitch.h"

@implementation GrowlOnSwitch

@synthesize onLabel = _onLabel;
@synthesize offLabel = _offLabel;

- (id)initWithFrame:(NSRect)frameRect
{
   if((self = [super initWithFrame:frameRect])){
      [self addObserver:self
             forKeyPath:@"state"
                options:NSKeyValueObservingOptionNew|NSKeyValueObservingOptionOld
                context:nil];
   }
   return self;
}

// Loaded from a NIB (as onLoginSwitch is), AppKit calls initWithCoder:, NOT
// initWithFrame: — so the observer must be registered here too, otherwise the
// "state" KVO never fires (ON label color never updates) AND dealloc's
// removeObserver: is unbalanced → exception if this view is ever deallocated.
- (id)initWithCoder:(NSCoder *)coder
{
   if((self = [super initWithCoder:coder])){
      [self addObserver:self
             forKeyPath:@"state"
                options:NSKeyValueObservingOptionNew|NSKeyValueObservingOptionOld
                context:nil];
   }
   return self;
}

- (void)awakeFromNib {
   NSString *offString = NSLocalizedString(@"OFF", @"If the string is too long, use O");
   [self.offLabel setStringValue:offString];
   
   NSString *onString = NSLocalizedString(@"ON", @"If the string is too long, use I");
   [self.onLabel setStringValue:onString];
   [super awakeFromNib];
}

- (void)dealloc
{
    [self removeObserver:self forKeyPath:@"state"];
    [_onLabel release];
    [_offLabel release];
    [super dealloc];
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
    if([keyPath isEqualToString:@"state"])
    {
        // labelColor (not blackColor) so the OFF label stays legible in dark mode;
        // controlAccentColor follows the system accent for the ON state.
        self.onLabel.textColor = (self.state ? [NSColor controlAccentColor] : [NSColor labelColor]);
    }
    else
    {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
    }
}

- (void)setNilValueForKey:(NSString *)key
{
	if ([key isEqualToString:@"state"])
		[self setState:NO];
	else
		return [super setNilValueForKey:key];
}

- (BOOL)canBecomeKeyView
{
   return YES;
}

- (BOOL)acceptsFirstResponder
{
   return YES;
}

- (void)setHidden:(BOOL)flag {
	[super setHidden:flag];
	[self.onLabel setHidden:flag];
	[self.offLabel setHidden:flag];
}

- (void)setEnabled:(BOOL)flag {
	[super setEnabled:flag];
	[self.onLabel setEnabled:flag];
	[self.offLabel setEnabled:flag];
}

@end
