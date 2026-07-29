//
//  HWGIconPickerView.h
//  HardwareGrowler
//
//  Reusable "icon customization" block for a monitor's preferencePane: one row per
//  default icon name, each with a live preview, a "Custom" button (NSOpenPanel ->
//  HWGIconOverrideStore), a "System" button (pick one of macOS's own generic icons
//  instead of a local file — see HWGSystemIconCatalog below), and a "Reset" button
//  (removes the override), enabled only when an override is currently active. Every
//  monitor embeds one instance of this view, passing the (label, default icon name)
//  pairs relevant to it — this is the single place the open-panel/system-icon-picker/
//  normalization/store wiring lives, so no monitor needs to duplicate that logic.

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

// A plain NSView is bottom-anchored (unflipped: y=0 is the bottom edge) — when it's used as
// an NSScrollView's documentView and gets stretched taller than its own content by the
// enclosing NSTabView (every monitor's Icons tab is resized to match however tall that
// monitor's General tab is), short content ends up glued to the bottom of the visible area
// with a large blank gap above it instead of sitting at the top. Every Icons-tab content
// container should use this instead of NSView so short icon lists still render top-anchored.
@interface HWGFlippedContentView : NSView
@end

// macOS's own generic hardware icons (external disk, removable media, CD/DVD, network,
// file server, PC card, RAM disk, iDisk) — resolved via the legacy Icon Services OSType
// API (`-[NSWorkspace iconForFileType:]` fed an HFS four-char-code), which is still the
// only way to reach these particular system-drawn icons; there is no modern UTType-based
// equivalent for this specific icon set. That API was soft-deprecated in macOS 12 in
// favor of `-iconForContentType:`, but keeps working today — see the "Known limitations"
// section of README.md for what to revisit if a future macOS removes it outright.
@interface HWGSystemIconCatalog : NSObject
// Each entry: @[label, NSImage]. Built once per catalog access (cheap — 8 small icons).
+ (NSArray<NSArray *> *)availableIcons;
@end

@interface HWGIconPickerView : NSView

// `iconSpecs` is an array of two-element arrays: @[label, defaultIconName].
// e.g. @[ @[@"Hub", @"USB-TypeHub"], @[@"Keyboard/Mouse", @"USB-TypeHID"] ]
- (instancetype)initWithIconSpecs:(NSArray<NSArray<NSString *> *> *)iconSpecs;

@end

NS_ASSUME_NONNULL_END
