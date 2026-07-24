//
//  HWGrowlVolumeMonitor.m
//  HardwareGrowler
//
//  Created by Daniel Siemer on 5/3/12.
//  Copyright (c) 2012 The Growl Project, LLC. All rights reserved.
//

// compile with ARC: -fobjc-arc
#import "HWGrowlVolumeMonitor.h"
#import <sys/param.h>
#import <sys/mount.h>

#define VolumeNotifierUnmountWaitSeconds	600.0
#define VolumeEjectCacheInfoIndex			0
#define VolumeEjectCacheTimerIndex			1

// A plain (non-flipped) NSScrollView document view, when shorter than the visible clip
// area, gets anchored to the BOTTOM of the clip by default — leaving the slack as a gap
// ABOVE the content instead of below it. A flipped content view (y=0 at the TOP, growing
// downward) is anchored to the top instead, which is what a top-down settings pane wants.
// Same pattern already used by NetworkMonitor's `HWGFlippedContentView`.
@interface HWGVolumeFlippedContentView : NSView
@end
@implementation HWGVolumeFlippedContentView
- (BOOL)isFlipped { return YES; }
@end

// F33: individually configurable extra fields in the "Volume Mounted" notification body —
// same pattern as the other monitors' per-field settings. Mount-only (an unmounted path has
// no live filesystem left to stat), all default YES.
#define HWG_VOLUME_SHOW_PATH_KEY    @"HWGVolumeShowMountPath"
#define HWG_VOLUME_SHOW_FSTYPE_KEY  @"HWGVolumeShowFileSystemType"
#define HWG_VOLUME_SHOW_SIZE_KEY    @"HWGVolumeShowVolumeSize"

// F34 #3: differentiate an integrated SD/CF card reader from a generic USB volume, via
// Disk Arbitration's kDADiskDescriptionDeviceProtocolKey (e.g. "Secure Digital", "USB",
// "PCI-Express"). OFF by default per user request (22-jul-2026) — unlike the other F33
// fields, this one is a heuristic guess that can be flatly wrong for some readers (see the
// "Known limitations" README entry), so it doesn't get the same on-by-default trust.
#define HWG_VOLUME_SHOW_INTERFACE_KEY @"HWGVolumeShowInterfaceType"

static BOOL HWGVolumeBoolForKey(NSString *key, BOOL def) {
	id stored = [[NSUserDefaults standardUserDefaults] objectForKey:key];
	return stored ? [stored boolValue] : def;
}

// F30/F29 (23-jul-2026): best-effort device-type classifier for the 3 icon categories
// (SDCard/USBDrive/ExternalDisk) added this session. CONFIRMED LIMITATION (see
// -interfaceDescriptionForMountedPath: below): there is no public API that reliably says
// "this is specifically a pendrive" vs "this is specifically an external disk enclosure" —
// both show up as plain USB Mass Storage with no distinguishing field on many real devices.
// This is a HEURISTIC that can and will guess wrong for some hardware; when no reasonably
// confident signal exists at all, it returns nil and the caller falls back to the existing
// generic icon — a wrong specific icon is worse than an honest generic one, so this never
// forces a guess between USBDrive/ExternalDisk without at least a size or name/model signal.
// True automatic-detection accuracy is bounded by what device firmware chooses to report;
// the only fully reliable path remains the separately-tracked manual per-device override
// ("Identificación/parametrización de dispositivos DESCONOCIDOS" in TODO.md).
#define HWG_EXTERNAL_DISK_SIZE_THRESHOLD_BYTES (400ULL * 1024 * 1024 * 1024)   // 400 GB

static NSString *HWGDeviceCategoryFromInfo(NSString *protocol, NSString *mediaName, NSString *deviceModel, unsigned long long mediaSizeBytes, BOOL (^looksLikeCardReader)(NSString *)) {
	if ([protocol caseInsensitiveCompare:@"Secure Digital"] == NSOrderedSame) return @"SDCard";
	if (looksLikeCardReader(mediaName) || looksLikeCardReader(deviceModel)) return @"SDCard";

	NSString *combined = [[NSString stringWithFormat:@"%@ %@", mediaName ?: @"", deviceModel ?: @""] lowercaseString];
	static NSArray<NSString*> *diskTokens = nil;
	static NSArray<NSString*> *driveTokens = nil;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		diskTokens  = @[@"hdd", @"ssd", @"hard disk", @"hard drive", @"external"];
		driveTokens = @[@"flash", @"thumb", @"pen drive", @"usb drive", @"mass storage"];
	});
	for (NSString *token in diskTokens)  { if ([combined rangeOfString:token].location != NSNotFound) return @"ExternalDisk"; }
	if (mediaSizeBytes >= HWG_EXTERNAL_DISK_SIZE_THRESHOLD_BYTES) return @"ExternalDisk";
	for (NSString *token in driveTokens) { if ([combined rangeOfString:token].location != NSNotFound) return @"USBDrive"; }

	// REVERTED (23-jul-2026): a fallback was added here ("plain USB storage under the
	// ExternalDisk threshold that isn't a card reader is essentially always a pendrive")
	// after a live test with a Kingston "DT 100 G2" pendrive that had no identifying
	// token. It seemed safe, but broke immediately on the VERY NEXT live test: a real SD
	// card in a USB adapter/reader that reports itself as media name "STORAGE DEVICE",
	// protocol "USB", 63.9GB — no "Secure Digital"/card-reader token anywhere (the exact,
	// already-documented SD/CF reader limitation) — got wrongly guessed as "USBDrive"
	// instead of falling back to the honest generic icon. Protocol=="USB" alone cannot
	// distinguish a pendrive from an unidentifiable SD/CF reader; forcing a guess here
	// makes the SD-reader case wrong to "fix" the pendrive case, a straight regression of
	// this function's own stated design rule (see doc comment above `HWGDeviceCategoryFromInfo`:
	// "a wrong specific icon is worse than an honest generic one"). Genuinely
	// unidentifiable USB Mass Storage (no card-reader token, no disk/drive token, under
	// the ExternalDisk size threshold) now correctly falls through to nil/generic again —
	// this is a known, permanent limitation (see README "Known limitations"), not a bug to
	// keep patching with ever-more-specific guesses.

	return nil;   // no confident signal — caller falls back to the generic icon
}

// Returns "Device-<Category>" (or "Device-<Category>-<variant>" when variant is non-nil,
// e.g. "Critical" or "Unmounted") if that asset exists in the catalog, else nil so the
// caller can fall back to its own existing default.
static NSString *HWGDeviceIconNameForCategoryVariant(NSString *category, NSString *variant) {
	if (![category length]) return nil;
	NSString *name = [variant length] ? [NSString stringWithFormat:@"Device-%@-%@", category, variant] : [NSString stringWithFormat:@"Device-%@", category];
	return [NSImage imageNamed:name] ? name : nil;
}
static NSString *HWGDeviceIconNameForCategory(NSString *category, BOOL critical) {
	return HWGDeviceIconNameForCategoryVariant(category, critical ? @"Critical" : nil);
}

// Plain statfs() syscall — same mechanism already used by noteReadableSiblingForMountedPath:
// below, not NSFileManager/NSWorkspace, so this never touches TCC-gated file access.
static BOOL HWGCopyVolumeFileSystemInfo(NSString *path, NSString **outFSType, unsigned long long *outTotalBytes) {
	if (![path length]) return NO;
	struct statfs sfs;
	if (statfs([path fileSystemRepresentation], &sfs) != 0) return NO;
	if (outFSType) *outFSType = [NSString stringWithUTF8String:sfs.f_fstypename];
	if (outTotalBytes) *outTotalBytes = (unsigned long long)sfs.f_blocks * (unsigned long long)sfs.f_bsize;
	return YES;
}

@implementation VolumeInfo

@synthesize iconData;
@synthesize path;
@synthesize name;
@synthesize deviceCategory;

+ (NSImage*)ejectIconImage {
	static NSImage *_ejectIconImage = nil;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		_ejectIconImage = [NSImage imageNamed:@"DisksVolumes-Eject"];
	});
	return _ejectIconImage;
}

+ (NSData*)mountIconData {
	static NSData *_mountIconData = nil;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		// Custom colored mount icon from the asset catalog (replaces the old
		// generic SF Symbol "externaldrive").
		_mountIconData = [[NSImage imageNamed:@"DisksVolumes-Mounted"] TIFFRepresentation];
	});
	return _mountIconData;
}

+ (VolumeInfo *) volumeInfoForMountWithPath:(NSString *)aPath {
	return [[VolumeInfo alloc] initForMountWithPath:aPath];
}

+ (VolumeInfo *) volumeInfoForUnmountWithPath:(NSString *)aPath {
	return [[VolumeInfo alloc] initForUnmountWithPath:aPath];
}

- (id) initForMountWithPath:(NSString *)aPath {
	if ((self = [self initWithPath:aPath])) {
		// Always use the generic mount icon. Reading the volume's actual
		// icon (via iconForFile: or NSURLEffectiveIconKey) traverses to the
		// source file (e.g. the .dmg in ~/Downloads) and triggers TCC
		// permission prompts. We never touch the filesystem here.
		self.iconData = [VolumeInfo mountIconData];
	}
	return self;
}

- (id) initForUnmountWithPath:(NSString *)aPath {
	if ((self = [self initWithPath:aPath])) {
		// Always use the eject icon alone for unmounts. No filesystem access,
		// no TCC prompts. The volume name in the title is enough to identify
		// which volume was ejected.
		NSImage *ejectIcon = [VolumeInfo ejectIconImage];
		NSData *tiff = [ejectIcon TIFFRepresentation];
		NSBitmapImageRep *bitmapRep = [NSBitmapImageRep imageRepWithData:tiff];
		self.iconData = [bitmapRep representationUsingType:NSBitmapImageFileTypePNG
												properties:@{}];
	}

	return self;
}

- (id) initWithPath:(NSString *)aPath {
	if ((self = [super init])) {
		if (aPath) {
			path = aPath;
			// Use the last path component as the volume name. This is purely
			// string manipulation — no filesystem access, no TCC prompts.
			// For /Volumes/MyDrive this yields "MyDrive", which matches the
			// display name macOS shows in Finder for nearly all volumes.
			name = [aPath lastPathComponent];
		}
	}

	return self;
}

// No -dealloc needed under ARC (the ivars were only released here).

- (NSString *) description {
	NSMutableDictionary *desc = [NSMutableDictionary dictionary];
	
	if (name)
		[desc setObject:name forKey:@"name"];
	if (path)
		[desc setObject:path forKey:@"path"];
	if (iconData)
		[desc setObject:@"<yes>" forKey:@"iconData"];
	
	return [desc description];
}

@end

@interface HWGrowlVolumeMonitor ()

@property (nonatomic, weak) id<HWGrowlPluginControllerProtocol> delegate;
@property (nonatomic, strong) NSMutableDictionary *ejectCache;
@property (nonatomic, strong) NSString *ignoredVolumeColumnTitle;

// Disk Arbitration — detects media at the disk/physical level, independent of whether
// it ever mounts. NSWorkspace (above) only tells us about volumes that mount successfully,
// so media that's inserted but unreadable (unformatted/corrupt/unsupported filesystem)
// was previously invisible to this monitor entirely.
@property (nonatomic, assign) DASessionRef daSession;
// Media-name keys (kDADiskDescriptionMediaNameKey) for whole-disk objects that just
// appeared and might still get a child slice shortly; used to avoid double-reporting a
// disk that DOES turn out to have a recognized partition/filesystem.
@property (nonatomic, strong) NSMutableSet<NSString*> *pendingWholeDisks;
// Media-name keys currently flagged "not readable", so we don't repeat the notice for the
// same still-attached disk, and so removing it re-arms the check for next time.
@property (nonatomic, strong) NSMutableSet<NSString*> *reportedUnreadableDisks;
// BSD device-node name (e.g. "disk4s1") -> its group key, recorded at APPEARED time (when
// the disk's description is reliably populated). Disappeared events only give us
// DADiskGetBSDName reliably — kDADiskDescriptionMediaWholeKey isn't guaranteed accurate by
// then — so this reverse lookup is how we know which physical-card group a vanishing BSD
// node belonged to, without re-deriving it from a possibly-stale description.
@property (nonatomic, strong) NSMutableDictionary<NSString*, NSString*> *bsdNameToGroupKey;
// Group key -> set of BSD names currently believed attached under that physical card. Once
// this becomes empty (every slice/whole-disk node for that card has disappeared), the card
// is genuinely gone and its "already reported" state is cleared, re-arming it.
@property (nonatomic, strong) NSMutableDictionary<NSString*, NSMutableSet<NSString*>*> *groupMembers;
// Group key -> unreadable partition names seen so far for that physical card, collected
// during a short settle window before the notice actually fires (see
// scheduleUnreadableSettleForGroup:) so we can tell "nothing on this card is readable" apart
// from "SOME partitions on this card mounted fine, this one specifically didn't".
@property (nonatomic, strong) NSMutableDictionary<NSString*, NSMutableSet<NSString*>*> *groupUnreadablePartitions;
// Group keys for which at least one sibling partition mounted successfully (cross-referenced
// from volumeDidMount: via the mounted volume's BSD device node -> bsdNameToGroupKey).
@property (nonatomic, strong) NSMutableSet<NSString*> *groupsWithReadableSibling;
// Group keys with a pending settle timer already scheduled, so a second unreadable partition
// arriving during the window doesn't schedule a duplicate timer.
@property (nonatomic, strong) NSMutableSet<NSString*> *groupSettleScheduled;
// F30/F29 (23-jul-2026): best-effort device-type guess (@"SDCard"/@"USBDrive"/@"ExternalDisk",
// or absent = unknown) per physical-card group, captured at APPEARED time (see
// HWGDeviceCategoryFromInfo) so -finalizeUnreadableForGroup: can pick a device-specific
// "-Critical" icon even though by then there's no mounted path left to re-query.
@property (nonatomic, strong) NSMutableDictionary<NSString*, NSString*> *groupDeviceCategory;
// Human-readable name for a group (see -wholeDiskDisplayNameForDisk:), used ONLY for
// notification text — groupKey itself is now the whole disk's BSD name, not this.
@property (nonatomic, strong) NSMutableDictionary<NSString*, NSString*> *groupDisplayName;

// BUG FIX (23-jul-2026, found live): the device category used to be captured only in
// -volumeWillUnmount:, right before the eject — but that notification only fires for a
// GRACEFUL software-initiated unmount. A "surprise removal" (physically yanking the device
// with no prior Finder eject) skips straight to -volumeDidUnmount: with no chance to still
// query the (already-gone) path, so the "Unmounted" notice silently fell back to the plain
// generic icon in that case. Cache the category once at MOUNT time instead (when the query
// is always reliable) — this works for both graceful and surprise removal, since there's no
// re-query needed at unmount time at all.
@property (nonatomic, strong) NSMutableDictionary<NSString*, NSString*> *pathDeviceCategory;

// strong (not assign): these come from the prefs nib. NSArrayController is a
// top-level nib object — under ARC it needs a strong outlet to survive past
// nib load (otherwise it deallocs and the prefs pane crashes).
@property (nonatomic, strong) IBOutlet NSArrayController *arrayController;
@property (nonatomic, strong) IBOutlet NSTableView *tableView;

- (NSString *)wholeDiskGroupKeyForDisk:(DADiskRef)disk;
- (void)handleDiskAppeared:(DADiskRef)disk;
- (void)handleDiskDisappeared:(DADiskRef)disk;
- (void)scheduleUnreadableSettleForGroup:(NSString *)groupKey partitionName:(NSString *)partitionName;
- (void)finalizeUnreadableForGroup:(NSString *)groupKey;
- (void)noteReadableSiblingForMountedPath:(NSString *)path;

@end

static void hwgDiskAppearedCallback(DADiskRef disk, void *context) {
	HWGrowlVolumeMonitor *monitor = (__bridge HWGrowlVolumeMonitor *)context;
	[monitor handleDiskAppeared:disk];
}

static void hwgDiskDisappearedCallback(DADiskRef disk, void *context) {
	HWGrowlVolumeMonitor *monitor = (__bridge HWGrowlVolumeMonitor *)context;
	[monitor handleDiskDisappeared:disk];
}

@implementation HWGrowlVolumeMonitor

@synthesize delegate;
@synthesize ejectCache;
@synthesize daSession;

@synthesize prefsView;
@synthesize arrayController;
@synthesize tableView;

-(id)init {
	if((self = [super init])){
		self.ejectCache = [NSMutableDictionary dictionary];
		self.pendingWholeDisks = [NSMutableSet set];
		self.reportedUnreadableDisks = [NSMutableSet set];
		self.bsdNameToGroupKey = [NSMutableDictionary dictionary];
		self.groupMembers = [NSMutableDictionary dictionary];
		self.groupUnreadablePartitions = [NSMutableDictionary dictionary];
		self.groupsWithReadableSibling = [NSMutableSet set];
		self.groupSettleScheduled = [NSMutableSet set];
		self.groupDeviceCategory = [NSMutableDictionary dictionary];
		self.groupDisplayName = [NSMutableDictionary dictionary];
		self.pathDeviceCategory = [NSMutableDictionary dictionary];

		NSNotificationCenter *center = [[NSWorkspace sharedWorkspace] notificationCenter];

		[center addObserver:self selector:@selector(volumeDidMount:) name:NSWorkspaceDidMountNotification object:nil];
		//Note that we must use both WILL and DID unmount, so we can only get the volume's icon before the volume has finished unmounting.
		//The icon and data is stored during WILL unmount, and then displayed during DID unmount.
		[center addObserver:self selector:@selector(volumeDidUnmount:) name:NSWorkspaceDidUnmountNotification object:nil];
		[center addObserver:self selector:@selector(volumeWillUnmount:) name:NSWorkspaceWillUnmountNotification object:nil];

		self.ignoredVolumeColumnTitle = NSLocalizedString(@"Ignored Drives:", @"Title for colum in table of ignored volumes");

		// Disk Arbitration session — see property comments above for why this exists
		// alongside the NSWorkspace mount notifications.
		daSession = DASessionCreate(kCFAllocatorDefault);
		if (daSession) {
			DASessionSetDispatchQueue(daSession, dispatch_get_main_queue());
			DARegisterDiskAppearedCallback(daSession, NULL, hwgDiskAppearedCallback, (__bridge void *)self);
			DARegisterDiskDisappearedCallback(daSession, NULL, hwgDiskDisappearedCallback, (__bridge void *)self);
		}
	}
	return self;
}

- (void)dealloc {
	// Keep the non-memory teardown (observer + timers); ARC frees the rest.
	[[[NSWorkspace sharedWorkspace] notificationCenter] removeObserver:self];

	[ejectCache enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
		[[obj objectAtIndex:VolumeEjectCacheTimerIndex] invalidate];
	}];

	if (daSession) {
		DASessionSetDispatchQueue(daSession, NULL);
		CFRelease(daSession);
	}
}

// Returns a stable, UNIQUE label for the PHYSICAL disk that `disk` (whole disk, or one of
// its partitions/slices) belongs to: the whole disk's own BSD name (e.g. "disk4"). Every
// partition of the same physical card resolves to the SAME group key via DADiskCopyWholeDisk,
// regardless of each partition's own label (e.g. a card with "android_meta" and
// "android_expand" partitions both group under the card's own BSD name) — this is what lets
// multiple unreadable partitions on one card collapse into a single notice instead of one
// per partition.
//
// BUG FIX (23-jul-2026, found live with a pendrive + an external HDD connected at once): this
// used to return the whole disk's MEDIA NAME instead of its BSD name. Many external
// enclosures and pendrives report a generic media name for the whole-disk object (e.g.
// "Generic") — TWO DIFFERENT physical drives sharing that same generic name collided under
// the same dictionary key, mixing up their tracked state: one device's false "not readable"
// timer could fire and get reported using the OTHER device's identity, and one device's
// "already reported"/"has a readable sibling" bookkeeping could suppress or misdirect the
// other's real notification. A BSD name is guaranteed unique per physical device within a
// session, so it can never collide this way — the (possibly non-unique) media name is now
// tracked separately, purely for what the notification TEXT displays.
- (NSString *)wholeDiskGroupKeyForDisk:(DADiskRef)disk {
	DADiskRef whole = DADiskCopyWholeDisk(disk);
	if (!whole) return nil;
	const char *bsd = DADiskGetBSDName(whole);
	NSString *key = bsd ? [NSString stringWithUTF8String:bsd] : nil;
	CFRelease(whole);
	return key;
}

// Human-readable name for a group, for notification text only — never used as a dictionary
// key (see -wholeDiskGroupKeyForDisk: above for why). Falls back to the group key itself
// (the BSD name) if the whole disk never reported a media name.
- (NSString *)wholeDiskDisplayNameForDisk:(DADiskRef)disk {
	DADiskRef whole = DADiskCopyWholeDisk(disk);
	if (!whole) return nil;
	NSString *name = nil;
	CFDictionaryRef descRef = DADiskCopyDescription(whole);
	if (descRef) {
		NSDictionary *desc = (__bridge_transfer NSDictionary *)descRef;
		name = desc[(__bridge NSString *)kDADiskDescriptionMediaNameKey];
	}
	CFRelease(whole);
	return name;
}

// Disk Arbitration: a disk (whole disk or a slice/partition of one) has appeared. This
// fires for EVERY disk, mountable or not — unlike NSWorkspaceDidMountNotification, which
// only fires once a filesystem is actually mounted. We use it to catch media that's
// present but can't be mounted (unformatted, corrupt, or an unsupported filesystem).
- (void)handleDiskAppeared:(DADiskRef)disk {
	CFDictionaryRef descRef = DADiskCopyDescription(disk);
	if (!descRef) return;
	NSDictionary *desc = (__bridge_transfer NSDictionary *)descRef;

	// Never flag the Mac's own internal storage.
	if ([desc[(__bridge NSString *)kDADiskDescriptionDeviceInternalKey] boolValue]) return;

	NSString *partitionName = desc[(__bridge NSString *)kDADiskDescriptionMediaNameKey]
		?: NSLocalizedString(@"Disk", @"");
	BOOL isWhole = [desc[(__bridge NSString *)kDADiskDescriptionMediaWholeKey] boolValue];
	BOOL hasFilesystem = (desc[(__bridge NSString *)kDADiskDescriptionVolumeKindKey] != nil);
	// Group by the PHYSICAL card, not the individual partition: a card with several
	// unrecognized partitions (e.g. an Android card's "android_meta"/"android_expand") only
	// gets ONE "Disk Not Readable" notice, not one per partition. groupKey is the whole
	// disk's BSD name (unique) — see -wholeDiskGroupKeyForDisk:'s doc comment for why this
	// is no longer the (possibly non-unique) media name.
	NSString *groupKey = [self wholeDiskGroupKeyForDisk:disk] ?: partitionName;
	NSString *displayName = [self wholeDiskDisplayNameForDisk:disk] ?: partitionName;
	if (displayName) self.groupDisplayName[groupKey] = displayName;

	// F30/F29: best-effort device-type guess for this group, captured now (while the
	// description is reliable) so a later "Disk Not Readable" notice can pick a
	// device-specific icon — see HWGDeviceCategoryFromInfo's doc comment for why this is a
	// heuristic, not a guarantee. Only set/overwrite when we get an actual guess, so a
	// stray unreliable read (e.g. from a partition-level appearance) doesn't erase an
	// earlier, possibly-better whole-disk guess for the same group.
	{
		NSString *protocol = desc[(__bridge NSString *)kDADiskDescriptionDeviceProtocolKey];
		NSString *mediaName = desc[(__bridge NSString *)kDADiskDescriptionMediaNameKey];
		NSString *deviceModel = desc[(__bridge NSString *)kDADiskDescriptionDeviceModelKey];
		NSNumber *mediaSize = desc[(__bridge NSString *)kDADiskDescriptionMediaSizeKey];
		NSString *category = HWGDeviceCategoryFromInfo(protocol, mediaName, deviceModel,
			[mediaSize unsignedLongLongValue], ^BOOL(NSString *s) { return [self stringContainsCardReaderToken:s]; });
		if (category) self.groupDeviceCategory[groupKey] = category;
	}

	// Remember which physical-card group this BSD node belongs to, and that the card is
	// still (at least partly) present — this is what lets handleDiskDisappeared: know when
	// the group is FULLY gone without having to re-read a (possibly stale-by-then)
	// description at disappear time.
	const char *bsdName = DADiskGetBSDName(disk);
	if (bsdName) {
		NSString *bsd = [NSString stringWithUTF8String:bsdName];
		self.bsdNameToGroupKey[bsd] = groupKey;
		NSMutableSet *members = self.groupMembers[groupKey];
		if (!members) { members = [NSMutableSet set]; self.groupMembers[groupKey] = members; }
		[members addObject:bsd];
	}

	if (!isWhole) {
		// A slice/partition appeared under this media's whole disk — it has SOME
		// structure, so the "maybe totally blank" fallback check below no longer applies.
		[self.pendingWholeDisks removeObject:groupKey];
		if (hasFilesystem) return;   // recognized filesystem — the normal mount flow handles it
		[self scheduleUnreadableSettleForGroup:groupKey partitionName:partitionName];
		return;
	}

	// Whole-disk object. A normal, readable card gets a child slice with a recognized
	// filesystem moments later (handled above); a totally blank/unpartitioned card never
	// gets a child slice at all, so give it a couple seconds before treating it as
	// unreadable — long enough for Disk Arbitration to finish probing.
	//
	// BUG FIX (23-jul-2026, found live with a real external HDD): a large external HDD can
	// take noticeably longer than a small pendrive to spin up / get auto-mounted by macOS,
	// especially with several disks being enumerated at app launch at once. 1.5s wasn't
	// always enough — confirmed via `diskutil info` that the reported-unreadable partition
	// had a perfectly valid recognized filesystem (ExFAT) and mounted instantly by hand with
	// `diskutil mount`, it just hadn't been auto-mounted yet when our timer fired. Bumped to
	// 3.0s, and added a live re-check (below) that doesn't depend on a fixed delay at all.
	if (hasFilesystem) return;
	[self.pendingWholeDisks addObject:groupKey];
	NSString *wholeBSDName = bsdName ? [NSString stringWithUTF8String:bsdName] : nil;
	__weak HWGrowlVolumeMonitor *weakSelf = self;
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
		HWGrowlVolumeMonitor *strongSelf = weakSelf;
		if (!strongSelf) return;
		if ([strongSelf.pendingWholeDisks containsObject:groupKey]) {
			[strongSelf.pendingWholeDisks removeObject:groupKey];
			// Bug found live (23-jul-2026): at app LAUNCH, when a disk was already mounted
			// before HG4MAC started, Disk Arbitration's bulk "existing disks" enumeration can
			// deliver the whole-disk object noticeably before the already-mounted partition's
			// own appeared callback (with its filesystem key populated) — the window above
			// isn't always enough in that specific bulk-scan case, producing a false "Disk Not
			// Readable" moments before the correct "Mounted" notice for the SAME device. Cross-
			// check the actual mount table (getmntinfo) before declaring it unreadable: if any
			// currently-mounted filesystem's device node belongs to this whole disk, it's
			// readable — just slow to report through the DA callback we were waiting on.
			if (wholeBSDName && [strongSelf wholeDiskBSDNameHasMountedVolume:wholeBSDName]) return;
			// Second bug fix (23-jul-2026, external HDD case): the partition can be
			// perfectly readable and recognized by Disk Arbitration WITHOUT being mounted
			// yet at all (auto-mount just hasn't caught up) — getmntinfo() alone can't see
			// that. Re-query DA directly for every BSD node already seen for this group;
			// if any of them reports a recognized filesystem kind, it's readable.
			if (groupKey && [strongSelf groupHasRecognizedFilesystem:groupKey]) return;
			[strongSelf scheduleUnreadableSettleForGroup:groupKey partitionName:partitionName];
		}
	});
}

// Returns YES if any currently mounted filesystem's device node (e.g. "/dev/disk4s1")
// belongs to the given whole-disk BSD name (e.g. "disk4") — i.e. some partition of this
// physical disk is, in fact, already mounted and readable, regardless of what Disk
// Arbitration's own appeared-callback timing has told us so far.
- (BOOL)wholeDiskBSDNameHasMountedVolume:(NSString *)wholeBSDName {
	if (![wholeBSDName length]) return NO;
	NSString *prefix = [NSString stringWithFormat:@"/dev/%@", wholeBSDName];
	struct statfs *mounts = NULL;
	int count = getmntinfo(&mounts, MNT_NOWAIT);
	for (int i = 0; i < count; i++) {
		NSString *fromName = [NSString stringWithUTF8String:mounts[i].f_mntfromname];
		// Match "/dev/disk4" itself or any partition of it ("/dev/disk4s1", ...), but not a
		// different disk that merely shares the prefix (e.g. "disk4" vs "disk40").
		if ([fromName isEqualToString:prefix] || [fromName hasPrefix:[prefix stringByAppendingString:@"s"]]) {
			return YES;
		}
	}
	return NO;
}

// Returns YES if ANY BSD node already tracked for this group (see -handleDiskAppeared:'s
// self.groupMembers bookkeeping) currently reports a recognized filesystem kind via Disk
// Arbitration — even if that partition isn't mounted yet. Catches the case an external HDD
// hits: DA already knows the partition is a valid, recognized filesystem (e.g. exFAT/NTFS)
// well before macOS gets around to auto-mounting it, so waiting for a mount is unnecessary.
- (BOOL)groupHasRecognizedFilesystem:(NSString *)groupKey {
	if (!daSession || ![groupKey length]) return NO;
	NSSet<NSString*> *members = self.groupMembers[groupKey];
	for (NSString *bsd in members) {
		DADiskRef disk = DADiskCreateFromBSDName(kCFAllocatorDefault, daSession, [bsd UTF8String]);
		if (!disk) continue;
		BOOL hasFS = NO;
		CFDictionaryRef descRef = DADiskCopyDescription(disk);
		if (descRef) {
			NSDictionary *desc = (__bridge_transfer NSDictionary *)descRef;
			hasFS = (desc[(__bridge NSString *)kDADiskDescriptionVolumeKindKey] != nil);
		}
		CFRelease(disk);
		if (hasFS) return YES;
	}
	return NO;
}

// Disk Arbitration: a disk (whole or slice) has gone away. We deliberately do NOT re-read
// its description here — kDADiskDescriptionMediaWholeKey isn't guaranteed reliable by the
// time a disk is disappearing (especially on a surprise/physical removal), which would
// silently leave a card's "already reported" state stuck forever, so a later reinsertion
// of the SAME card would never notify again. Instead, DADiskGetBSDName (a lightweight
// accessor, not a description copy) reliably still works, and we use OUR OWN bookkeeping
// (populated at appeared time, when the description WAS reliable) to find which physical
// card group this BSD node belonged to.
- (void)handleDiskDisappeared:(DADiskRef)disk {
	const char *bsdName = DADiskGetBSDName(disk);
	if (!bsdName) return;
	NSString *bsd = [NSString stringWithUTF8String:bsdName];

	NSString *groupKey = self.bsdNameToGroupKey[bsd];
	[self.bsdNameToGroupKey removeObjectForKey:bsd];
	if (!groupKey) return;

	NSMutableSet *members = self.groupMembers[groupKey];
	[members removeObject:bsd];
	if (members.count > 0) return;   // other slices of this same card are still present

	// The whole card is gone now (no BSD nodes of this group remain) — re-arm it so a
	// future reinsertion is reported again.
	[self.groupMembers removeObjectForKey:groupKey];
	[self.pendingWholeDisks removeObject:groupKey];
	[self.reportedUnreadableDisks removeObject:groupKey];
	[self.groupUnreadablePartitions removeObjectForKey:groupKey];
	[self.groupsWithReadableSibling removeObject:groupKey];
	[self.groupSettleScheduled removeObject:groupKey];
	[self.groupDeviceCategory removeObjectForKey:groupKey];
	[self.groupDisplayName removeObjectForKey:groupKey];
}

// Records an unreadable partition for this physical card and, if a settle window isn't
// already running for it, starts one. We deliberately delay the actual notice (instead of
// firing immediately, as a first version of this feature did) because a multi-partition card
// can have SOME partitions that mount fine and others that don't (e.g. an Android card whose
// "android_meta"/"android_expand" partitions are never meant to mount, alongside a normal
// user-data partition that does) — reporting the very first unreadable partition immediately
// made the notice read like the partition's internal name WAS the device ("android_meta could
// not be read"), which is misleading. Waiting lets us classify the situation instead:
//   - nothing on the card is readable at all -> name the DEVICE, not a partition
//   - some partitions mounted fine, this one specifically didn't -> name that PARTITION,
//     phrased as "part of the device", not as if it were the whole device
- (void)scheduleUnreadableSettleForGroup:(NSString *)groupKey partitionName:(NSString *)partitionName {
	if ([self.reportedUnreadableDisks containsObject:groupKey]) return;

	NSMutableSet *pending = self.groupUnreadablePartitions[groupKey];
	if (!pending) { pending = [NSMutableSet set]; self.groupUnreadablePartitions[groupKey] = pending; }
	[pending addObject:partitionName];

	if ([self.groupSettleScheduled containsObject:groupKey]) return;   // timer already running
	[self.groupSettleScheduled addObject:groupKey];

	// TEMP (15-jul-2026, pedido del usuario): 1.0s mientras se decide el valor final — ver
	// project_pending_tests.md (el usuario percibió 2s/3s como demasiado largo).
	__weak HWGrowlVolumeMonitor *weakSelf = self;
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
		HWGrowlVolumeMonitor *strongSelf = weakSelf;
		if (!strongSelf) return;
		[strongSelf.groupSettleScheduled removeObject:groupKey];
		[strongSelf finalizeUnreadableForGroup:groupKey];
	});
}

- (void)finalizeUnreadableForGroup:(NSString *)groupKey {
	// Already reported for this physical card since it was inserted — collapse any further
	// unreadable partitions on the SAME card into that one notice instead of repeating it.
	if ([self.reportedUnreadableDisks containsObject:groupKey]) return;
	NSSet *partitions = self.groupUnreadablePartitions[groupKey];
	if (![partitions count]) return;   // nothing actually pending (shouldn't normally happen)
	[self.reportedUnreadableDisks addObject:groupKey];

	BOOL hasReadableSibling = [self.groupsWithReadableSibling containsObject:groupKey];
	NSString *description;
	if (hasReadableSibling) {
		// Case 2: some part of this device DID mount fine — name the partition(s) that
		// didn't, phrased as a PART of the device rather than as the device itself.
		NSString *partsJoined = [[partitions allObjects] componentsJoinedByString:@", "];
		description = [NSString stringWithFormat:
			NSLocalizedString(@"Part of this device (%@) could not be read. It may be unformatted or use an unsupported file system.", @""),
			partsJoined];
	} else {
		// Case 1: nothing on this device could be read at all — name the DEVICE by its
		// display name (media name), not whichever partition happened first, and not
		// groupKey itself (that's the BSD name now, not fit for user-facing text).
		description = [NSString stringWithFormat:
			NSLocalizedString(@"%@ could not be read. It may be unformatted or use an unsupported file system.", @""),
			self.groupDisplayName[groupKey] ?: groupKey];
	}

	// F29: prefer a device-specific "-Critical" icon (SDCard/USBDrive/ExternalDisk) over the
	// generic radioactive-symbol one, when the best-effort classifier had enough to go on.
	NSString *category = self.groupDeviceCategory[groupKey];
	NSString *iconName = HWGDeviceIconNameForCategory(category, YES) ?: @"Device-Critical";
	NSData *icon = [[NSImage imageNamed:iconName] TIFFRepresentation];
	[delegate notifyWithName:@"VolumeNotReadable"
							 title:NSLocalizedString(@"Disk Not Readable", @"")
					 description:description
							  icon:icon
			  identifierString:groupKey
				  contextString:nil
							plugin:self];
	[self.groupUnreadablePartitions removeObjectForKey:groupKey];
}

// Cross-references a just-mounted volume's BSD device node against bsdNameToGroupKey (built
// up by handleDiskAppeared: for every disk node Disk Arbitration has ever seen, mountable or
// not) so we know "this physical card has at least one readable partition" even though the
// mount notification and the DiskArbitration unreadable-partition tracking are two entirely
// separate mechanisms.
- (void)noteReadableSiblingForMountedPath:(NSString *)path {
	if (![path length]) return;
	struct statfs sfs;
	if (statfs([path fileSystemRepresentation], &sfs) != 0) return;
	NSString *devPath = [NSString stringWithUTF8String:sfs.f_mntfromname];   // e.g. "/dev/disk4s1"
	NSString *bsd = [devPath lastPathComponent];                             // "disk4s1"
	if (![bsd length]) return;
	NSString *groupKey = self.bsdNameToGroupKey[bsd];
	if (!groupKey) return;
	[self.groupsWithReadableSibling addObject:groupKey];
}

// F34 #3: resolves the bus/reader interface for a mounted path via Disk Arbitration.
//
// CONFIRMED LIMITATION (22-jul-2026, live test with a real USB SD/CF card reader behind a
// hub): the reader/hub exposed the card purely as a generic USB Mass Storage Class device —
// kDADiskDescriptionDeviceProtocolKey="USB", kDADiskDescriptionMediaNameKey="Untitled 1",
// kDADiskDescriptionDeviceModelKey="MassStorageClass" — with NO substring anywhere ("SD",
// "Secure Digital", "MMC", "CompactFlash", etc.) that could identify it as a card reader.
// This is a real hardware/driver limitation, not a code bug: the reader's own USB Mass
// Storage firmware simply never reports card-specific identity to the OS, so Disk Arbitration
// has nothing to expose — there is no public API workaround. This only works for a native
// internal SD controller (protocol reports "Secure Digital" directly) or a USB adapter whose
// specific chipset/firmware DOES surface an SD-related string in its model/media name — not
// guaranteed for any given reader. Documented in README "Known limitations".
- (NSString *)interfaceDescriptionForMountedPath:(NSString *)path {
	if (!daSession || ![path length]) return nil;
	struct statfs sfs;
	if (statfs([path fileSystemRepresentation], &sfs) != 0) return nil;
	NSString *devPath = [NSString stringWithUTF8String:sfs.f_mntfromname];   // e.g. "/dev/disk4s1"
	NSString *bsd = [devPath lastPathComponent];
	if (![bsd length]) return nil;

	DADiskRef disk = DADiskCreateFromBSDName(kCFAllocatorDefault, daSession, [bsd UTF8String]);
	if (!disk) return nil;
	NSString *result = nil;
	CFDictionaryRef descRef = DADiskCopyDescription(disk);
	if (descRef) {
		NSDictionary *desc = (__bridge_transfer NSDictionary *)descRef;
		NSString *protocol = desc[(__bridge NSString *)kDADiskDescriptionDeviceProtocolKey];
		NSString *mediaName = desc[(__bridge NSString *)kDADiskDescriptionMediaNameKey];
		NSString *deviceModel = desc[(__bridge NSString *)kDADiskDescriptionDeviceModelKey];
		BOOL isInternal = [desc[(__bridge NSString *)kDADiskDescriptionDeviceInternalKey] boolValue];

		BOOL looksLikeCardReader =
			[protocol caseInsensitiveCompare:@"Secure Digital"] == NSOrderedSame ||
			[self stringContainsCardReaderToken:mediaName] ||
			[self stringContainsCardReaderToken:deviceModel];

		if (looksLikeCardReader) {
			result = isInternal
				? NSLocalizedString(@"SD/CF card (integrated reader)", @"")
				: NSLocalizedString(@"SD/CF card (external reader)", @"");
		} else if ([protocol length]) {
			result = protocol;
		}
	}
	CFRelease(disk);
	return result;
}

// F30: best-effort device-type guess for an already-mounted path — same DA lookup as
// -interfaceDescriptionForMountedPath: above, reused via HWGDeviceCategoryFromInfo (see its
// doc comment for the accuracy caveats: this is a heuristic, not a guarantee).
- (NSString *)deviceCategoryForMountedPath:(NSString *)path {
	if (!daSession || ![path length]) return nil;
	struct statfs sfs;
	if (statfs([path fileSystemRepresentation], &sfs) != 0) return nil;
	NSString *devPath = [NSString stringWithUTF8String:sfs.f_mntfromname];
	NSString *bsd = [devPath lastPathComponent];
	if (![bsd length]) return nil;

	DADiskRef disk = DADiskCreateFromBSDName(kCFAllocatorDefault, daSession, [bsd UTF8String]);
	if (!disk) return nil;
	NSString *category = nil;
	CFDictionaryRef descRef = DADiskCopyDescription(disk);
	if (descRef) {
		NSDictionary *desc = (__bridge_transfer NSDictionary *)descRef;
		// BUG FIX (23-jul-2026): internal APFS system volumes (home, Preboot, VM, Update,
		// iSCPreboot, xarts, /, …) all report the SAME ~large size as the internal SSD
		// container, which was tripping the size-based "ExternalDisk" heuristic below and
		// mislabeling every internal system volume mount with the external-disk icon.
		// Never classify internal storage — it's never any of these 3 removable-device
		// categories, matching the same exclusion -handleDiskAppeared: already applies for
		// the "Disk Not Readable" path.
		if ([desc[(__bridge NSString *)kDADiskDescriptionDeviceInternalKey] boolValue]) {
			CFRelease(disk);
			return nil;
		}
		NSString *protocol = desc[(__bridge NSString *)kDADiskDescriptionDeviceProtocolKey];
		NSString *mediaName = desc[(__bridge NSString *)kDADiskDescriptionMediaNameKey];
		NSString *deviceModel = desc[(__bridge NSString *)kDADiskDescriptionDeviceModelKey];
		NSNumber *mediaSize = desc[(__bridge NSString *)kDADiskDescriptionMediaSizeKey];
		category = HWGDeviceCategoryFromInfo(protocol, mediaName, deviceModel,
			[mediaSize unsignedLongLongValue], ^BOOL(NSString *s) { return [self stringContainsCardReaderToken:s]; });
	}
	CFRelease(disk);
	return category;
}

- (BOOL)stringContainsCardReaderToken:(NSString *)s {
	if (![s length]) return NO;
	NSString *lower = [s lowercaseString];
	static NSArray<NSString*> *tokens = nil;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		tokens = @[@"secure digital", @" sd/", @"sd card", @"sdxc", @"sdhc", @"mmc", @"compactflash", @" cf ", @"cardreader", @"card reader"];
	});
	for (NSString *token in tokens) {
		if ([lower rangeOfString:token].location != NSNotFound) return YES;
	}
	return NO;
}

- (void) sendMountNotificationForVolume:(VolumeInfo*)volume mounted:(BOOL)mounted {
	NSArray *exceptions = [[NSUserDefaults standardUserDefaults] objectForKey:@"HWGVolumeMonitorExceptions"];
	__block BOOL found = NO;
	[exceptions enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
		NSString *justAString = [obj valueForKey:@"justastring"];
		NSString *path = [volume path];
		NSString *name = [volume name];
		BOOL hasWildCard = [justAString hasSuffix:@"*"];
		if(!hasWildCard){
			if([path caseInsensitiveCompare:justAString] == NSOrderedSame ||
				[name caseInsensitiveCompare:justAString] == NSOrderedSame)
			{
				found = YES;
				*stop = YES;
			}
		}else{
			justAString = [justAString substringToIndex:[justAString length] - 1];
			if([path rangeOfString:justAString options:(NSAnchoredSearch | NSCaseInsensitivePredicateOption)].location != NSNotFound ||
				[name rangeOfString:justAString options:(NSAnchoredSearch | NSCaseInsensitivePredicateOption)].location != NSNotFound)
			{
				found = YES;
				*stop = YES;
			}
		}
	}];
	if(found)
		return;
	
	NSString *context = mounted ? [volume path] : nil;
	NSString *type = mounted ? @"VolumeMounted" : @"VolumeUnmounted";
	NSString *title = [NSString stringWithFormat:@"%@ %@", [volume name], mounted ? NSLocalizedString(@"Mounted", @"") : NSLocalizedString(@"Unmounted", @"")];

	// F30: best-effort device-specific icon (SDCard/USBDrive/ExternalDisk) in place of the
	// generic mount/eject icon, when the classifier had enough to go on.
	NSData *iconData = [volume iconData];
	if (mounted) {
		NSString *category = [self deviceCategoryForMountedPath:[volume path]];
		// Cache now, at mount time — the only point this query is always reliable — so
		// -volumeDidUnmount: can use it later even for a surprise removal (no prior
		// Finder eject, no -volumeWillUnmount: firing, path already gone by then).
		if (category && [volume path]) self.pathDeviceCategory[[volume path]] = category;
		NSString *iconName = HWGDeviceIconNameForCategory(category, NO);
		if (iconName) iconData = [[NSImage imageNamed:iconName] TIFFRepresentation];
	} else {
		// Bug found live (23-jul-2026): unmount always showed the plain generic eject
		// icon, even for a device the mount notice had just identified specifically
		// (e.g. a pendrive). Bug fix #1 (captured the category in -volumeWillUnmount:)
		// only covered a GRACEFUL eject — a surprise removal (unplugging without
		// ejecting first) skips that notification entirely, so it still fell back to
		// generic in that case. Now reads the category cached at MOUNT time instead,
		// which covers both. Same red-X-over-the-icon treatment as the existing generic
		// eject icon (per explicit user request — not a new badge design).
		NSString *category = self.pathDeviceCategory[[volume path]] ?: [volume deviceCategory];
		NSString *iconName = HWGDeviceIconNameForCategoryVariant(category, @"Unmounted");
		if (iconName) iconData = [[NSImage imageNamed:iconName] TIFFRepresentation];
		if ([volume path]) [self.pathDeviceCategory removeObjectForKey:[volume path]];
	}

	// F33: extra fields, mount-only — an unmounted path has no live filesystem left to stat.
	NSString *description = mounted ? NSLocalizedString(@"Click to open", @"Message body on a volume mount notification, clicking it opens the drive in finder") : nil;
	if (mounted) {
		BOOL showPath      = HWGVolumeBoolForKey(HWG_VOLUME_SHOW_PATH_KEY, YES);
		BOOL showFSType    = HWGVolumeBoolForKey(HWG_VOLUME_SHOW_FSTYPE_KEY, YES);
		BOOL showSize      = HWGVolumeBoolForKey(HWG_VOLUME_SHOW_SIZE_KEY, YES);
		BOOL showInterface = HWGVolumeBoolForKey(HWG_VOLUME_SHOW_INTERFACE_KEY, NO);

		NSMutableArray<NSString*> *extraLines = [NSMutableArray array];
		if (showPath && [volume path]) [extraLines addObject:[volume path]];

		if (showInterface) {
			NSString *interface = [self interfaceDescriptionForMountedPath:[volume path]];
			if ([interface length]) {
				[extraLines addObject:[NSString stringWithFormat:NSLocalizedString(@"Interface: %@", @""), interface]];
			}
		}

		if (showFSType || showSize) {
			NSString *fsType = nil;
			unsigned long long totalBytes = 0;
			if (HWGCopyVolumeFileSystemInfo([volume path], &fsType, &totalBytes)) {
				if (showFSType && [fsType length]) {
					[extraLines addObject:[NSString stringWithFormat:NSLocalizedString(@"File system: %@", @""), fsType]];
				}
				if (showSize && totalBytes > 0) {
					NSString *sizeStr = [NSByteCountFormatter stringFromByteCount:(long long)totalBytes
																	   countStyle:NSByteCountFormatterCountStyleFile];
					[extraLines addObject:[NSString stringWithFormat:NSLocalizedString(@"Size: %@", @""), sizeStr]];
				}
			}
		}

		if ([extraLines count]) {
			NSString *extra = [extraLines componentsJoinedByString:@"\n"];
			description = description ? [description stringByAppendingFormat:@"\n%@", extra] : extra;
		}
	}

	[delegate notifyWithName:type
							 title:title
					 description:description
							  icon:iconData
			  identifierString:[volume path]
				  contextString:context 
							plugin:self];
}

- (void) staleEjectItemTimerFired:(NSTimer *)theTimer {
	VolumeInfo *info = [theTimer userInfo];
	
	[ejectCache removeObjectForKey:[info path]];
}

- (void) volumeDidMount:(NSNotification *)aNotification {
	NSString *devicePath = [[aNotification userInfo] objectForKey:@"NSDevicePath"];
	// Let the "Disk Not Readable" grouping know this physical card has (at least) one
	// partition that mounted fine — see noteReadableSiblingForMountedPath:.
	[self noteReadableSiblingForMountedPath:devicePath];
	//send notification
	VolumeInfo *volume = [VolumeInfo volumeInfoForMountWithPath:devicePath];
	[self sendMountNotificationForVolume:volume mounted:YES];
}

- (void) volumeWillUnmount:(NSNotification *)aNotification {
	NSString *path = [[aNotification userInfo] objectForKey:@"NSDevicePath"];
	
	if (path) {
		VolumeInfo *info = [VolumeInfo volumeInfoForUnmountWithPath:path];
		// Capture the device-type category NOW, while the volume is still mounted and
		// statfs()/Disk Arbitration can still resolve it — by -volumeDidUnmount: time the
		// path is already gone. Lets the eventual "Unmounted" notice use the same
		// device-specific icon the "Mounted" one used, instead of always falling back to
		// the plain eject icon.
		info.deviceCategory = [self deviceCategoryForMountedPath:path];
		NSTimer *timer = [NSTimer scheduledTimerWithTimeInterval:VolumeNotifierUnmountWaitSeconds
																		  target:self
																		selector:@selector(staleEjectItemTimerFired:)
																		userInfo:info
																		 repeats:NO];
		
		// need to invalidate the timer for a previous item if it exists
		NSArray *cacheItem = [ejectCache objectForKey:path];
		if (cacheItem)
			[[cacheItem objectAtIndex:VolumeEjectCacheTimerIndex] invalidate];
		
		[ejectCache setObject:[NSArray arrayWithObjects:info, timer, nil] forKey:path];
	}
}

- (void) volumeDidUnmount:(NSNotification *)aNotification {
	VolumeInfo *info = nil;
	NSString *path = [[aNotification userInfo] objectForKey:@"NSDevicePath"];
	NSArray *cacheItem = path ? [ejectCache objectForKey:path] : nil;
	
	if (cacheItem)
		info = [cacheItem objectAtIndex:VolumeEjectCacheInfoIndex];
	else
		info = [VolumeInfo volumeInfoForUnmountWithPath:path];
	
	//Send notification
	[self sendMountNotificationForVolume:info mounted:NO];
	
	if (cacheItem) {
		[[cacheItem objectAtIndex:VolumeEjectCacheTimerIndex] invalidate];
		// we need to remove the item from the cache AFTER calling volumeDidUnmount so that "info" stays
		// retained long enough to be useful. After this next call, "info" is no longer valid.
		[ejectCache removeObjectForKey:path];
		info = nil;
	}
}

#pragma mark UI

-(void)tableViewSelectionDidChange:(NSNotification *)notification {
   NSArray *arranged = [arrayController arrangedObjects];
   NSUInteger selection = [arrayController selectionIndex];
   if(selection < [arranged count] && [arranged count]){
      NSString *justastring = [[arranged objectAtIndex:selection] valueForKey:@"justastring"];
      if(!justastring || [justastring isEqualToString:@""])
         [self.tableView editColumn:0 row:selection withEvent:nil select:YES];
   }
}

-(IBAction)addVolumeEntry:(id)sender {
   // F15: open a native Finder-style picker rooted at /Volumes instead of adding
   // an empty editable row. The picked volume name(s) go into the exceptions list
   // (key "justastring"), which sendMountNotificationForVolume: matches against
   // both the volume name and path.
   NSOpenPanel *panel = [NSOpenPanel openPanel];
   panel.canChooseDirectories    = YES;
   panel.canChooseFiles          = NO;
   panel.allowsMultipleSelection = YES;
   panel.directoryURL = [NSURL fileURLWithPath:@"/Volumes" isDirectory:YES];
   panel.prompt  = NSLocalizedString(@"Ignore", @"OpenPanel confirm button for choosing drives to ignore");
   panel.message = NSLocalizedString(@"Choose the drive(s) to ignore", @"OpenPanel message for choosing drives to ignore");

   __weak HWGrowlVolumeMonitor *weakSelf = self;
   void (^addPicked)(void) = ^{
      HWGrowlVolumeMonitor *strongSelf = weakSelf;
      if (!strongSelf) return;
      NSMutableArray *added = [NSMutableArray array];
      for (NSURL *url in panel.URLs) {
         // Prefer the volume's localized name (e.g. "Macintosh HD") — the user
         // picked the URL via the open-panel powerbox, so reading this resource
         // value doesn't trigger a TCC prompt. Fall back to the path component.
         NSString *name = nil;
         [url getResourceValue:&name forKey:NSURLVolumeLocalizedNameKey error:NULL];
         if (![name length]) name = [url lastPathComponent];
         // Skip the resolved boot-volume root ("/") and any empty name.
         if (![name length] || [name isEqualToString:@"/"]) continue;
         NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithObject:name forKey:@"justastring"];
         [strongSelf.arrayController addObject:dict];
         [added addObject:dict];
      }
      if ([added count])
         [strongSelf.arrayController setSelectedObjects:added];
   };

   NSWindow *window = [self.tableView window];
   if (window) {
      [panel beginSheetModalForWindow:window completionHandler:^(NSModalResponse result){
         if (result == NSModalResponseOK) addPicked();
      }];
   } else {
      if ([panel runModal] == NSModalResponseOK) addPicked();
   }
}
#pragma mark HWGrowlPluginProtocol

// -delegate / -setDelegate: auto-generated from @property (weak) + @synthesize.
-(NSString*)pluginDisplayName{
	return NSLocalizedString(@"Volume Monitor", @"");
}
-(NSImage*)preferenceIcon {
	static NSImage *_icon = nil;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		_icon = [NSImage imageNamed:@"HWGPrefsDrivesVolumes"];
	});
	return _icon;
}
// F33: single generic handler for every per-field visibility checkbox — mirrors the other
// monitors' `fieldToggleChanged:`. Each checkbox's `identifier` carries the NSUserDefaults
// key it controls.
-(IBAction)fieldToggleChanged:(NSButton*)sender {
	NSString *key = sender.identifier;
	if (!key) return;
	[[NSUserDefaults standardUserDefaults] setBool:(sender.state == NSControlStateValueOn) forKey:key];
}

-(NSButton *)checkboxWithKey:(NSString *)key title:(NSString *)title defaultOn:(BOOL)defaultOn {
	NSButton *box = [NSButton checkboxWithTitle:title target:self action:@selector(fieldToggleChanged:)];
	box.identifier = key;
	box.state = HWGVolumeBoolForKey(key, defaultOn) ? NSControlStateValueOn : NSControlStateValueOff;
	box.translatesAutoresizingMaskIntoConstraints = YES;   // frame-based layout, see preferencePane
	return box;
}

-(NSView*)preferencePane {
	if (prefsView) return prefsView;

	// The nib lives in THIS plugin's bundle, not the main app bundle. Its top-level view
	// (the ignore-list picker: a table + add/remove buttons) is assigned to `prefsView` via
	// the IBOutlet, which this method then wraps with the appended section below.
	[[NSBundle bundleForClass:[self class]] loadNibNamed:@"VolumeMonitorPrefs" owner:self topLevelObjects:nil];
	NSView *xibView = prefsView;

	// Unlike PowerMonitorPrefs.xib, this xib's declared frame (202x195) has NO baked-in
	// blank space — its scrollView + add/remove buttons genuinely occupy the full height
	// (confirmed in VolumeMonitorPrefs.xib: scrollView spans y=18..195, buttons at y=-1..20)
	// — so no "recover slack" trick is needed here; xibH can be reserved directly.
	CGFloat width = 380;
	CGFloat pad = 16;
	CGFloat xibW = 202, xibH = 195;
	CGFloat headerH = 18;
	CGFloat rowH = 24;
	NSArray<NSButton*> *rows = @[
		[self checkboxWithKey:HWG_VOLUME_SHOW_PATH_KEY   title:NSLocalizedString(@"Mount path", @"") defaultOn:YES],
		[self checkboxWithKey:HWG_VOLUME_SHOW_FSTYPE_KEY title:NSLocalizedString(@"File system type", @"") defaultOn:YES],
		[self checkboxWithKey:HWG_VOLUME_SHOW_SIZE_KEY   title:NSLocalizedString(@"Volume size", @"") defaultOn:YES],
		// F34 #3: SD/CF card reader vs generic USB, via Disk Arbitration's protocol key.
		[self checkboxWithKey:HWG_VOLUME_SHOW_INTERFACE_KEY title:NSLocalizedString(@"Interface / card reader type", @"") defaultOn:YES],
	];
	// Build top-down (cursor starts at 0, grows downward) in a FLIPPED content view — see
	// HWGVolumeFlippedContentView above. This fixes two related problems at once:
	// (1) a plain non-flipped document view, when shorter than the visible clip area
	// (AppDelegate stretches the outer scroll view to match the container — see
	// `containerViewFrameDidChange:`), gets anchored to the BOTTOM of the clip by default,
	// leaving the slack as a gap ABOVE the content instead of below it (reported by the
	// user: "Notification fields" appeared floating with a gap above it, not flush at the
	// top like every other monitor's pane). A flipped view anchors to the TOP instead.
	// (2) it also sidesteps the historical "pre-computed totalHeight drifts from the real
	// content extent" class of bug (already hit once in Power Monitor's pane) — height is
	// simply wherever the cursor ends up, never a separately hand-computed guess.
	NSView *combined = [[HWGVolumeFlippedContentView alloc] initWithFrame:NSMakeRect(0, 0, width, 1)];
	CGFloat cursor = 0;

	// Notification fields first, "Ignored Drives" list last (user's requested order).
	NSTextField *header = [NSTextField labelWithString:NSLocalizedString(@"Notification fields", @"")];
	header.font = [NSFont boldSystemFontOfSize:12];
	header.textColor = [NSColor secondaryLabelColor];
	header.translatesAutoresizingMaskIntoConstraints = YES;
	header.frame = NSMakeRect(pad, cursor, width - 2 * pad, headerH);
	[combined addSubview:header];
	cursor += headerH + 10;

	for (NSButton *row in rows) {
		row.frame = NSMakeRect(pad, cursor, width - 2 * pad, rowH);
		[combined addSubview:row];
		cursor += rowH + 10;
	}
	cursor += 6;

	// The xib's internal Auto Layout (scrollView/tableView pinned to xibView's edges) can
	// grow xibView taller than its declared 195pt — a fixed-size, hard-clipping wrapper
	// decouples the checkbox layout math from whatever xibView's internal content wants to
	// do (found when "Ignored Drives" was moved below the checkboxes: without this, the
	// list's overflow grew upward and silently covered them).
	NSView *xibWrapper = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, xibW, xibH)];
	xibWrapper.wantsLayer = YES;
	xibWrapper.layer.masksToBounds = YES;
	xibView.translatesAutoresizingMaskIntoConstraints = YES;
	xibView.frame = NSMakeRect(0, 0, xibW, xibH);
	[xibWrapper addSubview:xibView];

	xibWrapper.frame = NSMakeRect(0, cursor, xibW, xibH);
	[combined addSubview:xibWrapper];
	cursor += xibH + pad;

	combined.frame = NSMakeRect(0, 0, width, cursor);

	// AppDelegate force-resizes whatever `preferencePane` returns to match the container's
	// real frame — wrap `combined` in a scroll view whose OUTER frame is free to stretch,
	// while `combined` itself keeps its own fixed (flipped, top-anchored) content.
	NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, width, cursor)];
	scroll.hasVerticalScroller = YES;
	scroll.autohidesScrollers = YES;
	scroll.drawsBackground = NO;
	scroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
	scroll.documentView = combined;

	prefsView = scroll;
	return prefsView;
}

#pragma mark HWGrowlPluginNotifierProtocol

-(NSArray*)noteNames {
	return [NSArray arrayWithObjects:@"VolumeMounted", @"VolumeUnmounted", @"VolumeNotReadable", nil];
}
-(NSDictionary*)localizedNames {
	return [NSDictionary dictionaryWithObjectsAndKeys:NSLocalizedString(@"Volume Mounted", @""), @"VolumeMounted",
			  NSLocalizedString(@"Volume Unmounted", @""), @"VolumeUnmounted",
			  NSLocalizedString(@"Disk Not Readable", @""), @"VolumeNotReadable", nil];
}
-(NSDictionary*)noteDescriptions {
	return [NSDictionary dictionaryWithObjectsAndKeys:NSLocalizedString(@"Sent when a volume is mounted", @""), @"VolumeMounted",
			  NSLocalizedString(@"Sent when a volume is unmounted", @""), @"VolumeUnmounted",
			  NSLocalizedString(@"Sent when inserted media can't be read/mounted", @""), @"VolumeNotReadable", nil];
}
-(NSArray*)defaultNotifications {
	return [NSArray arrayWithObjects:@"VolumeMounted", @"VolumeUnmounted", @"VolumeNotReadable", nil];
}

-(void)fireOnLaunchNotes{
	// mountedLocalVolumePaths was deprecated in 10.11; use the NSFileManager URL API.
	// options:0 (no SkipHiddenVolumes) to match the old behavior of listing ALL
	// mounted volumes at launch, including system (APFS volume-group) volumes — real-world
	// macOS mounts SEVEN OR MORE of these internal-only siblings alongside the boot volume
	// ("/", "/System/Volumes/VM", "Preboot", "Update", "xarts", "iSCPreboot", "Hardware",
	// "Data/home"). This is intentional: the app is meant to report them too, not just
	// user-visible external media. The real bug this used to trigger — enough of these
	// firing at once silently pushed OTHER monitors' launch notices (Power's battery/AC
	// status, USB) off the bottom of the screen — is fixed at the source in
	// GrowlApplicationBridge.m's banner stack (see `_pendingBannerReveals`), not here.
	NSArray<NSURL*> *urls = [[NSFileManager defaultManager]
		mountedVolumeURLsIncludingResourceValuesForKeys:nil
												options:0];
	__block HWGrowlVolumeMonitor *blockSelf = self;
	[urls enumerateObjectsUsingBlock:^(NSURL *url, NSUInteger idx, BOOL *stop) {
		[blockSelf sendMountNotificationForVolume:[VolumeInfo volumeInfoForMountWithPath:url.path] mounted:YES];
	}];
}
-(void)noteClosed:(NSString*)contextString byClick:(BOOL)clicked {
	// openFile: was deprecated in 11.0; use openURL: with a file URL.
	if(clicked && contextString)
		[[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:contextString]];
}

@end
