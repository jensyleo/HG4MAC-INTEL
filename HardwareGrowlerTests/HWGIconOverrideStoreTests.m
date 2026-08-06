//
//  HWGIconOverrideStoreTests.m
//  HardwareGrowlerTests
//

#import <XCTest/XCTest.h>
#import "HWGIconOverrideStore.h"

// Uses a name that doesn't correspond to any real icon in the app, so this test never
// touches an override a user could actually be relying on, and always cleans up after
// itself (both in tearDown and defensively at the start) so a crashed run can't leave a
// stray override behind in the user's real Application Support folder.
static NSString * const kFixtureName = @"XCTestFixture-HWGIconOverrideStoreTests-DoNotUse";

@interface HWGIconOverrideStoreTests : XCTestCase
@end

@implementation HWGIconOverrideStoreTests

- (void)setUp {
	[[HWGIconOverrideStore sharedStore] removeOverrideForDefaultName:kFixtureName];
}

- (void)tearDown {
	[[HWGIconOverrideStore sharedStore] removeOverrideForDefaultName:kFixtureName];
}

- (NSImage *)fixtureImage {
	NSImage *image = [[NSImage alloc] initWithSize:NSMakeSize(8, 8)];
	[image lockFocus];
	[[NSColor redColor] set];
	NSRectFill(NSMakeRect(0, 0, 8, 8));
	[image unlockFocus];
	return image;
}

- (void)testNoOverrideByDefault {
	XCTAssertFalse([[HWGIconOverrideStore sharedStore] hasOverrideForDefaultName:kFixtureName]);
	XCTAssertNil([[HWGIconOverrideStore sharedStore] overrideImageForDefaultName:kFixtureName]);
}

- (void)testSetOverrideRoundTrips {
	[[HWGIconOverrideStore sharedStore] setOverrideImage:[self fixtureImage] forDefaultName:kFixtureName];

	XCTAssertTrue([[HWGIconOverrideStore sharedStore] hasOverrideForDefaultName:kFixtureName]);
	NSImage *resolved = [[HWGIconOverrideStore sharedStore] overrideImageForDefaultName:kFixtureName];
	XCTAssertNotNil(resolved);
	// setOverrideImage: normalizes to 512x512 (see the store's header) — confirms the
	// round trip actually went through the store's persistence path, not just an in-memory echo.
	XCTAssertEqual(resolved.size.width, 512);
	XCTAssertEqual(resolved.size.height, 512);
}

- (void)testRemoveOverrideClearsIt {
	[[HWGIconOverrideStore sharedStore] setOverrideImage:[self fixtureImage] forDefaultName:kFixtureName];
	XCTAssertTrue([[HWGIconOverrideStore sharedStore] hasOverrideForDefaultName:kFixtureName]);

	[[HWGIconOverrideStore sharedStore] removeOverrideForDefaultName:kFixtureName];

	XCTAssertFalse([[HWGIconOverrideStore sharedStore] hasOverrideForDefaultName:kFixtureName]);
	XCTAssertNil([[HWGIconOverrideStore sharedStore] overrideImageForDefaultName:kFixtureName]);
}

- (void)testResolveIconNamedFallsBackWhenNoOverride {
	// A name with no override and no bundled asset resolves to nil, same as
	// [NSImage imageNamed:] semantics (documented on HWGResolveIconNamed).
	XCTAssertNil(HWGResolveIconNamed(kFixtureName));
}

@end
