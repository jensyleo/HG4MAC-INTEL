//
//  AppDelegate.h
//  HardwareGrowler
//
//  Created by Daniel Siemer on 5/2/12.
//  Copyright (c) 2012 The Growl Project, LLC. All rights reserved.
//

#import <Cocoa/Cocoa.h>
#import <UserNotifications/UserNotifications.h>
#import <CoreBluetooth/CoreBluetooth.h>

@class GrowlOnSwitch, HWGrowlPluginController;

typedef enum : NSInteger {
	kShowIconInMenu = 0,
	kShowIconInDock = 1,
	kShowIconInBoth = 2,
	kDontShowIcon = 3
} HWGrowlIconState;

@interface AppDelegate : NSObject <NSApplicationDelegate, NSToolbarDelegate, NSTableViewDelegate, NSTableViewDataSource, NSWindowDelegate, UNUserNotificationCenterDelegate, CBCentralManagerDelegate> {
	// Only ivars WITHOUT a @property live here; the rest are synthesized with the
	// correct ARC ownership from the @property declarations below.
	NSStatusItem *statusItem;          // strong (we create/own it); set to nil to release
	IBOutlet NSMenu *statusMenu;       // top-level nib object
	IBOutlet GrowlOnSwitch *onLoginSwitch;

	HWGrowlIconState oldIconValue;
	BOOL oldOnLoginValue;

	// Performance preset radios (Modules tab, built in code — see -buildPerformanceSection).
	// Weak: owned by the Modules tab's view; kept here only to flip the selection to
	// "Custom" when the user manually changes a monitor's enabled state or any setting
	// INSIDE a monitor's own preferences pane.
	__weak NSButton *performanceMinimalRadio;
	__weak NSButton *performanceAllRadio;
	__weak NSButton *performanceCustomRadio;

	// Detects changes made INSIDE any individual monitor's own prefs pane (e.g. Power
	// Monitor's "Notify when Low Power Mode..." checkbox) — those plugins have no shared
	// "a setting changed" callback into AppDelegate, so this diffs NSUserDefaults itself
	// via NSUserDefaultsDidChangeNotification. See -userDefaultsDidChange:.
	NSDictionary *lastKnownDefaultsSnapshot;
	BOOL applyingPerformancePreset;   // guards against our OWN preset-apply writes re-triggering Custom

	// History tab (F37, built in code — see -buildHistoryTab). All weak: owned by the
	// History tab's view hierarchy, kept here only so refresh methods can update them.
	__weak NSButton *historyEnableCheckbox;
	__weak NSSlider *historyRetentionSlider;
	__weak NSTextField *historyRetentionLabel;
	__weak NSStackView *historyModulesStack;
	__weak NSTableView *historyTableView;

	// Snapshot of history entries currently backing historyTableView (rebuilt by
	// -refreshHistoryTable each time the History tab is shown or history changes).
	NSArray *historyEntriesCache;
}

@property (nonatomic, strong) IBOutlet NSString *showDevices;
@property (nonatomic, strong) IBOutlet NSString *quitTitle;
@property (nonatomic, strong) IBOutlet NSString *preferencesTitle;
@property (nonatomic, strong) IBOutlet NSString *openPreferencesTitle;
@property (nonatomic, strong) IBOutlet NSString *iconTitle;
@property (nonatomic, strong) IBOutlet NSString *startAtLoginTitle;
@property (nonatomic, strong) IBOutlet NSString *noPluginPrefsTitle;
@property (nonatomic, strong) IBOutlet NSString *moduleLabel;

@property (nonatomic, strong) NSString *iconInMenu;
@property (nonatomic, strong) NSString *iconInDock;
@property (nonatomic, strong) NSString *iconInBoth;
@property (nonatomic, strong) NSString *noIcon;

// Views/controls owned by the nib/view hierarchy → weak (was assign).
// EXCEPTION: window is strong. It's a top-level nib object with visibleAtLaunch=NO,
// so nothing else reliably keeps it alive before the user opens Preferences. Owning
// it here guarantees it survives (no cycle: window.delegate is weak; AppDelegate is
// app-lifetime). This mirrors the placeholderView/prefs-pane top-level-object lesson.
@property (strong) IBOutlet NSWindow *window;
@property (nonatomic, weak) IBOutlet NSPopUpButton *iconPopUp;
@property (nonatomic, strong) HWGrowlPluginController *pluginController;

@property (nonatomic, weak) IBOutlet NSToolbar *toolbar;
@property (nonatomic, weak) IBOutlet NSToolbarItem *generalItem;
@property (nonatomic, weak) IBOutlet NSToolbarItem *modulesItem;
// Not from the nib (History tab is built entirely in code, see -buildHistoryTab) — strong,
// since nothing else would keep it alive between toolbar layout passes otherwise.
@property (nonatomic, strong) NSToolbarItem *historyItem;
@property (nonatomic, weak) IBOutlet NSTabView *tabView;
@property (nonatomic, weak) IBOutlet NSTableColumn *moduleColumn;
@property (nonatomic, weak) IBOutlet NSTableView *tableView;
@property (nonatomic, weak) IBOutlet NSView *containerView;
@property (nonatomic, weak) IBOutlet NSTextField *noPrefsLabel;
// strong: placeholderView is removed from its superview when another pane shows,
// so we must own it or it would dealloc (we add it back later).
@property (nonatomic, strong) IBOutlet NSView *placeholderView;
@property (nonatomic, weak) IBOutlet NSView *currentView;

// Kept strong for the brief permission-request window in -requestAllPermissions. A
// CBCentralManager with delegate:nil never reliably calls
// -centralManagerDidUpdateState: internally, so its power-alert/permission prompt isn't
// guaranteed to fire — this app IS its own delegate instead.
@property (nonatomic, strong) CBCentralManager *permissionRequestBluetoothManager;

- (void)setStartAtLogin:(BOOL)enabled;
- (BOOL)isRegisteredAtLogin;

@end
