//
//  TMSliderControl.m
//  HardwareGrowler-NC
//
//  A small on/off toggle control (superclass of GrowlOnSwitch). This
//  implementation was rewritten from scratch for this fork: it draws the
//  toggle programmatically with NSBezierPath and does not use any bundled
//  artwork. The class is named after the original "TMSliderControl" concept
//  used by Growl, but contains no third-party code.
//
//  Copyright (c) 2026 Jensy Leonardo Martínez Cruz.
//  Licensed under the GNU General Public License v3.0 (GPLv3) — see LICENSE.
//

#import "TMSliderControl.h"

@implementation TMSliderControl {
    NSInteger _state;
}

@synthesize actionBlock = _actionBlock;

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        _state = 0;
    }
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    self = [super initWithCoder:coder];
    if (self) {
        _state = 0;
    }
    return self;
}

- (void)dealloc {
    [_actionBlock release];   // copied block — release it (MRC)
    [super dealloc];
}

- (NSInteger)state { return _state; }

- (void)setState:(NSInteger)state {
    if (_state != state) {
        _state = state;
        [self setNeedsDisplay:YES];
        if (_actionBlock) _actionBlock(state);
    }
}

- (void)setState:(NSInteger)state animated:(BOOL)animated {
    [self setState:state];
}

- (void)drawRect:(NSRect)dirtyRect {
    NSRect bounds = self.bounds;

    // Dimensiones del toggle
    CGFloat w = 51.0, h = 31.0;
    CGFloat x = NSMidX(bounds) - w / 2.0;
    CGFloat y = NSMidY(bounds) - h / 2.0;
    NSRect trackRect = NSMakeRect(x, y, w, h);
    CGFloat radius = h / 2.0;

    NSBezierPath *track = [NSBezierPath bezierPathWithRoundedRect:trackRect xRadius:radius yRadius:radius];

    // Color del track: verde si ON, gris si OFF
    if (_state) {
        [[NSColor colorWithRed:0.20 green:0.78 blue:0.35 alpha:1.0] setFill];
    } else {
        [[NSColor colorWithWhite:0.35 alpha:1.0] setFill];
    }
    [track fill];

    // Círculo blanco del thumb
    CGFloat thumbD = h - 4.0;
    CGFloat thumbX = _state ? (x + w - thumbD - 2.0) : (x + 2.0);
    CGFloat thumbY = y + 2.0;
    NSRect thumbRect = NSMakeRect(thumbX, thumbY, thumbD, thumbD);

    NSBezierPath *thumb = [NSBezierPath bezierPathWithOvalInRect:thumbRect];
    [[NSColor whiteColor] setFill];
    [thumb fill];

    // Sombra sutil del thumb. Guardar/restaurar el estado del contexto para que la
    // sombra no se filtre a dibujos posteriores en el mismo contexto gráfico.
    [NSGraphicsContext saveGraphicsState];
    NSShadow *shadow = [[NSShadow alloc] init];
    [shadow setShadowColor:[NSColor colorWithWhite:0.0 alpha:0.3]];
    [shadow setShadowOffset:NSMakeSize(0, -1)];
    [shadow setShadowBlurRadius:2.0];
    [shadow set];
    [thumb fill];
    [shadow release];
    [NSGraphicsContext restoreGraphicsState];
}

- (void)mouseUp:(NSEvent *)event {
    NSPoint p = [self convertPoint:[event locationInWindow] fromView:nil];
    if (NSPointInRect(p, self.bounds)) {
        [self setState:(_state == 0) ? 1 : 0];
        [NSApp sendAction:self.action to:self.target from:self];
    }
}

- (BOOL)isFlipped { return NO; }

@end
