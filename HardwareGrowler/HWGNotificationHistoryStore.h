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

// BUG FIX (04-ago-2026): the History panel's table previously only reloaded when the user
// switched TO the History tab (-selectTabIndex: in AppDelegate.m) — there was no signal at
// all connecting a newly-persisted entry to the UI, so notifications that fired while the
// History tab wasn't the active one (or Preferences was closed) could sit persisted-but-
// unshown for an arbitrary number of further events, exactly matching the reported "lag."
// Posted on the main queue after each entry is persisted; AppDelegate observes this and
// reloads the table only when the History tab is actually visible (avoids busywork when it
// isn't). Not the same as `pruneOlderThanDays:`/`clearAll`, which the UI already refreshes
// after synchronously via direct calls, not this notification.
FOUNDATION_EXPORT NSNotificationName const HWGNotificationHistoryDidChangeNotification;

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
