//
//  HWGrowlNetworkMonitorTests.m
//  HardwareGrowlerTests
//

#import <XCTest/XCTest.h>
#import "HWGWifiSignal.h"

@interface HWGrowlNetworkMonitorTests : XCTestCase
@end

@implementation HWGrowlNetworkMonitorTests

- (void)testUnavailableRSSIReturnsZeroBars {
	XCTAssertEqual(HWGWifiBarsForRSSI(0), 0);
}

- (void)testStrongSignalReturnsFourBars {
	XCTAssertEqual(HWGWifiBarsForRSSI(-40), 4);
	XCTAssertEqual(HWGWifiBarsForRSSI(-55), 4);   // boundary, inclusive
}

- (void)testMidSignalReturnsThreeBars {
	XCTAssertEqual(HWGWifiBarsForRSSI(-56), 3);
	XCTAssertEqual(HWGWifiBarsForRSSI(-65), 3);   // boundary, inclusive
}

- (void)testWeakerSignalReturnsTwoBars {
	XCTAssertEqual(HWGWifiBarsForRSSI(-66), 2);
	XCTAssertEqual(HWGWifiBarsForRSSI(-73), 2);   // boundary, inclusive
}

- (void)testWeakestUsableSignalReturnsOneBar {
	XCTAssertEqual(HWGWifiBarsForRSSI(-74), 1);
	XCTAssertEqual(HWGWifiBarsForRSSI(-80), 1);   // boundary, inclusive
}

- (void)testUnusableSignalReturnsZeroBars {
	XCTAssertEqual(HWGWifiBarsForRSSI(-81), 0);
	XCTAssertEqual(HWGWifiBarsForRSSI(-95), 0);
}

@end
