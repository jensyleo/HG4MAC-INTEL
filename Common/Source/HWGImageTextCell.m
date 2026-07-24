//
//  HWGImageTextCell.m
//  HardwareGrowler-NC
//
//  Clean-room, original implementation — see HWGImageTextCell.h.
//  Copyright (c) 2026 Jensy Leonardo Martínez Cruz.
//  Licensed under the GNU General Public License v3.0 (GPLv3) — see LICENSE.
//

#import "HWGImageTextCell.h"

// Horizontal gap between the left edge and the image, and between image and text.
static const CGFloat kHWGImageGap = 7.0;

@implementation HWGImageTextCell

// NSCell already declares an `image` property; synthesize our own backing ivar
// so it holds an arbitrary NSImage rather than NSCell's image-cell semantics.
@synthesize image = _image;

// NSCell duplicates itself when a table draws it, so carry the image across.
- (id)copyWithZone:(NSZone *)zone {
	HWGImageTextCell *copy = [super copyWithZone:zone];
	copy->_image = _image;
	return copy;
}

// Width the image column consumes (0 when there is no image).
- (CGFloat)imageColumnWidth {
	return self.image ? kHWGImageGap + self.image.size.width : 0.0;
}

// Split a cell rect into (image area, text area). Text keeps a leading gap.
- (void)splitFrame:(NSRect)frame image:(NSRect *)imageRect text:(NSRect *)textRect {
	NSRect img = NSZeroRect, text = frame;
	if (self.image) {
		NSDivideRect(frame, &img, &text, [self imageColumnWidth], NSMinXEdge);
	}
	if (imageRect) *imageRect = img;
	if (textRect)  *textRect  = text;
}

- (void)drawWithFrame:(NSRect)cellFrame inView:(NSView *)controlView {
	// Let the table's selection highlight show through.
	self.drawsBackground = NO;

	NSRect imageRect, textRect;
	[self splitFrame:cellFrame image:&imageRect text:&textRect];

	[super drawWithFrame:textRect inView:controlView];

	if (self.image) {
		NSSize size = self.image.size;
		NSRect dest;
		dest.size = size;
		// Nudge in from the leading edge and vertically center within the row.
		dest.origin.x = imageRect.origin.x + kHWGImageGap - 4.0;
		dest.origin.y = imageRect.origin.y + floor((imageRect.size.height - size.height) * 0.5);
		[self.image drawInRect:dest
					   fromRect:NSZeroRect
					  operation:NSCompositingOperationSourceOver
					   fraction:1.0
				 respectFlipped:YES
						  hints:nil];
	}
}

// Keep text editing/selection confined to the text area, not under the image.
- (void)editWithFrame:(NSRect)aRect inView:(NSView *)controlView editor:(NSText *)textObj delegate:(id)anObject event:(NSEvent *)theEvent {
	NSRect imageRect, textRect;
	[self splitFrame:aRect image:&imageRect text:&textRect];
	[super editWithFrame:textRect inView:controlView editor:textObj delegate:anObject event:theEvent];
}

- (void)selectWithFrame:(NSRect)aRect inView:(NSView *)controlView editor:(NSText *)textObj delegate:(id)anObject start:(NSInteger)selStart length:(NSInteger)selLength {
	NSRect imageRect, textRect;
	[self splitFrame:aRect image:&imageRect text:&textRect];
	[super selectWithFrame:textRect inView:controlView editor:textObj delegate:anObject start:selStart length:selLength];
}

- (NSSize)cellSize {
	NSSize size = [super cellSize];
	size.width += [self imageColumnWidth];
	return size;
}

@end
