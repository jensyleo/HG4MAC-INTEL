//
//  HWGNotificationHistoryStore.h
//  HardwareGrowler
//
//  Lightweight persistence for the optional "Notification History" tab (F37) — every
//  notification the app fires can optionally be recorded here, per-module, with a
//  user-configurable retention window (1-30 days). Off by default.
//
//  No Core Data / SQLite: entry volume is low (individual hardware-change notifications,
//  not high-frequency events) and a plain JSON array on disk is simpler and consistent
//  with the rest of this app's preference/state storage (NSUserDefaults + plain files),
//  which has no other database dependency.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface HWGNotificationHistoryEntry : NSObject

@property (nonatomic, strong) NSDate *date;
@property (nonatomic, copy) NSString *moduleBundleID;
@property (nonatomic, copy) NSString *moduleDisplayName;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy, nullable) NSString *body;

@end

@interface HWGNotificationHistoryStore : NSObject

+ (instancetype)sharedStore;

// Appends one entry and persists immediately (low volume — no batching needed).
- (void)addEntryWithModuleBundleID:(NSString *)bundleID
                 moduleDisplayName:(NSString *)displayName
                             title:(NSString *)title
                              body:(nullable NSString *)body;

// Newest first.
- (NSArray<HWGNotificationHistoryEntry *> *)allEntries;

// Removes entries older than `days` (relative to now) and persists the result.
- (void)pruneOlderThanDays:(NSInteger)days;

- (void)clearAll;

@end

NS_ASSUME_NONNULL_END
