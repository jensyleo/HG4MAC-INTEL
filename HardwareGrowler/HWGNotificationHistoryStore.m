//
//  HWGNotificationHistoryStore.m
//  HardwareGrowler
//

// compile with ARC: -fobjc-arc
#import "HWGNotificationHistoryStore.h"

NSNotificationName const HWGNotificationHistoryDidChangeNotification = @"HWGNotificationHistoryDidChangeNotification";

// BUG FIX (05-ago-2026): the only existing cap was time-based (1-30 days, user-configurable
// retention), with no ceiling on ENTRY COUNT. Camera/Audio Monitor's in-use notifications
// (added this session) can legitimately fire dozens of times a day per device — over even a
// modest retention window that's thousands of JSON-serialized entries, all held in memory
// AND rewritten in full on every single -addEntryWithModuleBundleID:... call (see -persist),
// since disk writes were never batched (entry volume was assumed low when this was written —
// true for connect/disconnect events, no longer true for in-use toggling). Capping the buffer
// independently of the day-based prune keeps both memory and per-write cost bounded regardless
// of how chatty a module gets.
static const NSUInteger kHWGNotificationHistoryMaxEntries = 500;

@implementation HWGNotificationHistoryEntry

- (NSDictionary *)dictionaryRepresentation {
	return @{
		@"date": @([self.date timeIntervalSince1970]),
		@"moduleBundleID": self.moduleBundleID ?: @"",
		@"moduleDisplayName": self.moduleDisplayName ?: @"",
		@"title": self.title ?: @"",
		@"body": self.body ?: @"",
	};
}

+ (instancetype)entryFromDictionary:(NSDictionary *)dict {
	HWGNotificationHistoryEntry *entry = [HWGNotificationHistoryEntry new];
	NSNumber *epoch = dict[@"date"];
	entry.date = epoch ? [NSDate dateWithTimeIntervalSince1970:[epoch doubleValue]] : [NSDate date];
	entry.moduleBundleID = dict[@"moduleBundleID"] ?: @"";
	entry.moduleDisplayName = dict[@"moduleDisplayName"] ?: @"";
	entry.title = dict[@"title"] ?: @"";
	entry.body = dict[@"body"];
	return entry;
}

@end

@interface HWGNotificationHistoryStore ()
@property (nonatomic, strong) NSMutableArray<HWGNotificationHistoryEntry *> *entries;   // newest first
@property (nonatomic, strong) dispatch_queue_t queue;
@end

@implementation HWGNotificationHistoryStore

+ (instancetype)sharedStore {
	static HWGNotificationHistoryStore *shared = nil;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{ shared = [[self alloc] init]; });
	return shared;
}

- (instancetype)init {
	self = [super init];
	if (self) {
		self.queue = dispatch_queue_create("com.jensyleo.hg4mac.notificationhistory", DISPATCH_QUEUE_SERIAL);
		self.entries = [[self loadFromDisk] mutableCopy] ?: [NSMutableArray array];
		// A file written before this cap existed may still be oversized — trim once at
		// launch (entries are newest-first, so this keeps the most recent ones).
		if (self.entries.count > kHWGNotificationHistoryMaxEntries) {
			NSRange overflow = NSMakeRange(kHWGNotificationHistoryMaxEntries, self.entries.count - kHWGNotificationHistoryMaxEntries);
			[self.entries removeObjectsInRange:overflow];
		}
	}
	return self;
}

- (NSURL *)storeDirectory {
	NSURL *appSupport = [[NSFileManager defaultManager] URLForDirectory:NSApplicationSupportDirectory
																 inDomain:NSUserDomainMask
														  appropriateForURL:nil
																	create:YES
																	 error:nil];
	NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier] ?: @"com.jensyleo.hg4mac";
	NSURL *dir = [appSupport URLByAppendingPathComponent:bundleID];
	[[NSFileManager defaultManager] createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:nil];
	return dir;
}

- (NSURL *)storeFileURL {
	return [[self storeDirectory] URLByAppendingPathComponent:@"NotificationHistory.json"];
}

- (NSArray<HWGNotificationHistoryEntry *> *)loadFromDisk {
	NSData *data = [NSData dataWithContentsOfURL:[self storeFileURL]];
	if (!data) return @[];
	NSArray *raw = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
	if (![raw isKindOfClass:[NSArray class]]) return @[];
	NSMutableArray<HWGNotificationHistoryEntry *> *result = [NSMutableArray arrayWithCapacity:raw.count];
	for (NSDictionary *dict in raw) {
		if ([dict isKindOfClass:[NSDictionary class]]) {
			[result addObject:[HWGNotificationHistoryEntry entryFromDictionary:dict]];
		}
	}
	return result;
}

// Must be called on self.queue.
- (void)persist {
	NSMutableArray *raw = [NSMutableArray arrayWithCapacity:self.entries.count];
	for (HWGNotificationHistoryEntry *entry in self.entries) {
		[raw addObject:[entry dictionaryRepresentation]];
	}
	NSData *data = [NSJSONSerialization dataWithJSONObject:raw options:0 error:nil];
	if (data) [data writeToURL:[self storeFileURL] atomically:YES];
}

- (void)addEntryWithModuleBundleID:(NSString *)bundleID
                 moduleDisplayName:(NSString *)displayName
                             title:(NSString *)title
                              body:(NSString *)body {
	HWGNotificationHistoryEntry *entry = [HWGNotificationHistoryEntry new];
	entry.date = [NSDate date];
	entry.moduleBundleID = bundleID;
	entry.moduleDisplayName = displayName;
	entry.title = title;
	entry.body = body;

	dispatch_async(self.queue, ^{
		[self.entries insertObject:entry atIndex:0];
		if (self.entries.count > kHWGNotificationHistoryMaxEntries) {
			NSRange overflow = NSMakeRange(kHWGNotificationHistoryMaxEntries, self.entries.count - kHWGNotificationHistoryMaxEntries);
			[self.entries removeObjectsInRange:overflow];
		}
		[self persist];
		dispatch_async(dispatch_get_main_queue(), ^{
			[[NSNotificationCenter defaultCenter] postNotificationName:HWGNotificationHistoryDidChangeNotification object:self];
		});
	});
}

- (NSArray<HWGNotificationHistoryEntry *> *)allEntries {
	__block NSArray *result = nil;
	dispatch_sync(self.queue, ^{
		result = [self.entries copy];
	});
	return result;
}

- (void)pruneOlderThanDays:(NSInteger)days {
	dispatch_async(self.queue, ^{
		NSDate *cutoff = [NSDate dateWithTimeIntervalSinceNow:-(days * 24 * 60 * 60)];
		NSIndexSet *toRemove = [self.entries indexesOfObjectsPassingTest:^BOOL(HWGNotificationHistoryEntry *entry, NSUInteger idx, BOOL *stop) {
			return [entry.date compare:cutoff] == NSOrderedAscending;
		}];
		if (toRemove.count > 0) {
			[self.entries removeObjectsAtIndexes:toRemove];
			[self persist];
		}
	});
}

- (void)clearAll {
	dispatch_async(self.queue, ^{
		[self.entries removeAllObjects];
		[self persist];
	});
}

@end
