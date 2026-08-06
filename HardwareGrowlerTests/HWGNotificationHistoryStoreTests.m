//
//  HWGNotificationHistoryStoreTests.m
//  HardwareGrowlerTests
//
//  Deliberately read-only: -addEntryWithModuleBundleID:... has no matching per-entry
//  removal API (only -pruneOlderThanDays: and -clearAll, both of which operate on the
//  user's REAL notification history — pruneOlderThanDays:0 would wipe every existing
//  entry, not just a test fixture). Until the store grows a way to remove a single entry,
//  this only exercises the non-mutating read path so a test run can never leave stray
//  data behind or destroy real history the user is keeping.
//

#import <XCTest/XCTest.h>
#import "HWGNotificationHistoryStore.h"

@interface HWGNotificationHistoryStoreTests : XCTestCase
@end

@implementation HWGNotificationHistoryStoreTests

- (void)testAllEntriesReturnsAnArrayWithoutThrowing {
	NSArray<HWGNotificationHistoryEntry *> *entries = [[HWGNotificationHistoryStore sharedStore] allEntries];
	XCTAssertNotNil(entries);
}

- (void)testEntriesAreOrderedNewestFirst {
	NSArray<HWGNotificationHistoryEntry *> *entries = [[HWGNotificationHistoryStore sharedStore] allEntries];
	for (NSUInteger i = 1; i < entries.count; i++) {
		NSDate *previous = entries[i - 1].date;
		NSDate *current  = entries[i].date;
		XCTAssertTrue([previous compare:current] != NSOrderedAscending,
		              @"allEntries must be newest first (see header)");
	}
}

@end
