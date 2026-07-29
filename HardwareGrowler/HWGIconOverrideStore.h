//
//  HWGIconOverrideStore.h
//  HardwareGrowler
//
//  User-configurable icon overrides — Fase A of the icon-customization feature. Any
//  default icon (referenced app-wide by its Assets.xcassets name, e.g. "USB-TypeHub")
//  can be replaced by a user-supplied image. Normalized copies (512x512, transparent
//  background where the source has none) are stored as PNG files on disk; a small JSON
//  index tracks which default names have an override. Same shape as
//  HWGNotificationHistoryStore: Application Support/<bundle id> subfolder, private
//  serial queue, plain JSON — no Core Data/SQLite.

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@interface HWGIconOverrideStore : NSObject

+ (instancetype)sharedStore;

// Normalizes `image` to 512x512 (uniform bounding-box rescale, transparent padding) and
// stores it as the override for `defaultName`. Persists immediately.
- (void)setOverrideImage:(NSImage *)image forDefaultName:(NSString *)defaultName;

// Removes the override for `defaultName`, if any. Persists immediately.
- (void)removeOverrideForDefaultName:(NSString *)defaultName;

- (BOOL)hasOverrideForDefaultName:(NSString *)defaultName;

// The override image for `defaultName`, or nil if none is set.
- (nullable NSImage *)overrideImageForDefaultName:(NSString *)defaultName;

// Icon customization got broad enough (12 monitors, 3 ways to set an icon each) that the
// user asked for a way to back up/restore the whole set at once. Bundles the entire
// overrides directory (index + every normalized PNG) into a single zip archive via
// `/usr/bin/ditto` (no extra dependency — same tool `github-publish` workflows in this
// project already shell out to for zipping release builds).
- (BOOL)exportProfileToURL:(NSURL *)destinationURL error:(NSError * _Nullable * _Nullable)error;

// Replaces the current overrides directory with the contents of a previously-exported
// zip archive, then reloads the in-memory index/cache from disk. Existing overrides not
// present in the imported profile are removed (a full restore, not a merge).
- (BOOL)importProfileFromURL:(NSURL *)sourceURL error:(NSError * _Nullable * _Nullable)error;

// The on-disk folder overrides live in (Application Support/<bundle id>/IconOverrides) —
// exposed so AppDelegate's combined "Settings Profile" export/import (icons + defaults.
// together) can fold this same folder into a bigger archive without duplicating the
// zip/unzip logic above.
- (NSURL *)overridesDirectoryURL;

// Re-reads the index and clears the decoded-image cache from whatever is currently on
// disk — call after replacing the overrides folder out from under the store (e.g. the
// combined settings-profile import copies files in directly, bypassing
// -importProfileFromURL:error:, then calls this instead of duplicating that method's
// reload step).
- (void)reloadFromDisk;

@end

// Resolves `defaultName` through the override store first, falling back to
// [NSImage imageNamed:defaultName] when no override exists. Every call site that used to
// call [NSImage imageNamed:...] directly for a user-facing monitor/status icon should call
// this instead so overrides apply everywhere automatically. Returns nil only if defaultName
// itself doesn't resolve to any bundled asset either (mirrors imageNamed: semantics).
FOUNDATION_EXPORT NSImage * _Nullable HWGResolveIconNamed(NSString *defaultName);

NS_ASSUME_NONNULL_END
