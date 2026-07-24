//
//  AppDelegate.m
//  HG4MAC
//
//  Created by Daniel Siemer on 5/2/12.
//  Copyright (c) 2012 The Growl Project, LLC. All rights reserved.
//

// compile with ARC: -fobjc-arc
#import "AppDelegate.h"
#import "GrowlOnSwitch.h"
#import "HWGrowlPluginController.h"
#import "HWGImageTextCell.h"
#import <ServiceManagement/ServiceManagement.h>
#import <UserNotifications/UserNotifications.h>
#import <CoreBluetooth/CoreBluetooth.h>
#include <unistd.h>

#define ShowDevicesTitle     NSLocalizedString(@"Show Connected Devices at Launch", nil)
#define QuitTitle	           NSLocalizedString(@"Quit HG4MAC", nil)
#define PreferencesTitle     NSLocalizedString(@"Preferences", nil)
#define OpenPreferencesTitle NSLocalizedString(@"Open HG4MAC Preferences...", nil)
#define IconTitle            NSLocalizedString(@"Icon:", nil)
#define StartAtLoginTitle    NSLocalizedString(@"Start HG4MAC at Login:", nil)
#define NoPluginPrefsTitle   NSLocalizedString(@"There are no preferences available for this monitor.", @"")
#define ModuleLabel          NSLocalizedString(@"Modules", @"")

// Performance preset (added 22-jul-2026 per user request — with 12 monitors now, some
// polling/observing continuously, the user wants an easy way to cap resource usage without
// hand-picking each monitor in the Modules tab every time).
#define HWG_PERFORMANCE_MODE_KEY @"HWGPerformanceMode"
typedef NS_ENUM(NSInteger, HWGPerformanceMode) {
	HWGPerformanceModeMinimal = 0,
	HWGPerformanceModeAll     = 1,
	HWGPerformanceModeCustom  = 2,
};
// Default is "All" (not "Minimal") so this new control never silently disables monitors an
// existing user already had running before this feature existed.
#define HWG_PERFORMANCE_MODE_DEFAULT HWGPerformanceModeAll

// Remembers the monitor enable/disable arrangement the user had set up under "Custom" —
// captured the moment they LEAVE Custom for Minimal/All, so switching back to Custom later
// restores it instead of showing whatever Minimal/All left behind (bug found 22-jul-2026:
// without this, Custom → Minimal/All → Custom silently lost the custom arrangement, since
// applying Minimal/All overwrites "DisabledPlugins" directly with no memory of what came before).
#define HWG_PERFORMANCE_CUSTOM_SNAPSHOT_KEY @"HWGPerformanceCustomSnapshot"

// "Minimal elements": only the monitors the original (pre-fork) HardwareGrowler app shipped
// with — Volume, USB, Thunderbolt (was FireWire), Bluetooth, Power, Network. Everything added
// since (Thermal, Display, Audio, Camera, Gamepad, Printer) is what "All elements" adds back.
static NSSet<NSString*> *HWGMinimalPluginBundleIdentifiers(void) {
	static NSSet<NSString*> *ids = nil;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		NSString *prefix = @"com.jensyleo.hg4mac.";
		ids = [NSSet setWithArray:@[
			[prefix stringByAppendingString:@"VolumeMonitor"],
			[prefix stringByAppendingString:@"USBMonitor"],
			[prefix stringByAppendingString:@"ThunderboltMonitor"],
			[prefix stringByAppendingString:@"BluetoothMonitor"],
			[prefix stringByAppendingString:@"PowerMonitor"],
			[prefix stringByAppendingString:@"NetworkMonitor"],
		]];
	});
	return ids;
}

// The modules table uses NSTableViewStyleSourceList (see -awakeFromNib below), which by
// default paints a system BLUE selection highlight — indistinguishable from Bluetooth
// Monitor's own blue-indigo icon when that row is selected (the icon and the highlight
// behind it become the same color family, so the glyph loses contrast). Overriding
// -drawSelectionInRect: substitutes a neutral gray fill instead, which keeps every module's
// icon color (including Bluetooth's blue) legible against the selection background
// regardless of which row is selected.
@interface HWGGraySelectionRowView : NSTableRowView
@end

@implementation HWGGraySelectionRowView
-(void)drawSelectionInRect:(NSRect)dirtyRect {
	if (self.selectionHighlightStyle == NSTableViewSelectionHighlightStyleNone) return;
	NSRect selectionRect = NSInsetRect(self.bounds, 4, 1);
	NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:selectionRect xRadius:6 yRadius:6];
	[[NSColor colorWithWhite:0.5 alpha:0.35] setFill];
	[path fill];
}
@end

@interface AppDelegate ()

@end

@implementation AppDelegate

@synthesize window = _window;
@synthesize iconPopUp;
@synthesize pluginController;

@synthesize showDevices;
@synthesize quitTitle;
@synthesize preferencesTitle;
@synthesize openPreferencesTitle;
@synthesize iconTitle;
@synthesize startAtLoginTitle;
@synthesize noPluginPrefsTitle;
@synthesize moduleLabel;

@synthesize iconInMenu;
@synthesize iconInDock;
@synthesize iconInBoth;
@synthesize noIcon;

@synthesize toolbar;
@synthesize generalItem;
@synthesize modulesItem;
@synthesize tabView;
@synthesize tableView;
@synthesize moduleColumn;
@synthesize containerView;
@synthesize noPrefsLabel;
@synthesize placeholderView;
@synthesize currentView;

+(void)initialize
{
	[[NSUserDefaults standardUserDefaults] registerDefaults:[NSDictionary dictionaryWithObjectsAndKeys:
																				[NSNumber numberWithBool:NO], @"OnLogin",
																				[NSNumber numberWithBool:YES], @"ShowExisting",
																				[NSNumber numberWithBool:NO], @"GroupNetwork",
																				[NSNumber numberWithInteger:0], @"Visibility", nil]];
	[[NSUserDefaults standardUserDefaults] synchronize];
	[super initialize];
}

// ARC: no manual dealloc needed (all ObjC ivars are strong/weak, auto-managed).
// (AppDelegate lives for the whole app lifetime anyway.)

- (void) awakeFromNib {
	self.iconInMenu = NSLocalizedString(@"Show icon in the menubar", @"default option for where the icon should be seen");
	self.iconInDock = NSLocalizedString(@"Show icon in the dock", @"display the icon only in the dock");
	self.iconInBoth = NSLocalizedString(@"Show icon in both", @"display the icon in both the menubar and the dock");
	self.noIcon = NSLocalizedString(@"No icon visible", @"display no icon at all");
	
	[generalItem setLabel:NSLocalizedString(@"General", @"")];
	[modulesItem setLabel:NSLocalizedString(@"Modules", @"")];
	
	NSNumber *visibility = [[NSUserDefaults standardUserDefaults] objectForKey:@"Visibility"];
	if(visibility == nil || [visibility integerValue] == kShowIconInDock || [visibility integerValue] == kShowIconInBoth){
		[NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
	}
	
	if(visibility == nil || [visibility integerValue] == kShowIconInMenu || [visibility integerValue] == kShowIconInBoth){
		[self initMenu];
	}
	
	BOOL _isOn = [self isRegisteredAtLogin];
	[[NSUserDefaults standardUserDefaults] setBool:_isOn forKey:@"OnLogin"];
	[[NSUserDefaultsController sharedUserDefaultsController].defaults setBool:_isOn forKey:@"OnLogin"];
	[onLoginSwitch setState:_isOn];
	oldOnLoginValue = _isOn;

	// weak capture: onLoginSwitch retains the action block, so a strong self
	// capture would create a retain cycle (self → onLoginSwitch → block → self).
	__weak AppDelegate *weakSelf = self;
	[onLoginSwitch setActionBlock:^(NSInteger state) {
		AppDelegate *blockSelf = weakSelf;
		if (!blockSelf) return;
		BOOL enabled = (state != 0);
		[blockSelf setStartAtLogin:enabled];
		blockSelf->oldOnLoginValue = enabled;
		[[NSUserDefaults standardUserDefaults] setBool:enabled forKey:@"OnLogin"];
	}];

	self.pluginController = [[HWGrowlPluginController alloc] init];
	[self buildPerformanceSection];
	[self startObservingDefaultsForCustomModeDetection];

	// The currently-selected monitor's prefs pane is sized to match containerView's frame
	// at the moment it's inserted (see -tableViewSelectionDidChange:). But containerView
	// itself is resized AFTER that — confirmed via Accessibility inspection: right after
	// the window is first shown, containerView.frame is a small nib-authored placeholder
	// size, and only grows to its real on-screen size once the split between the sidebar
	// and detail area is actually resolved. That happens exactly once, for whichever
	// monitor is selected first (every other monitor is only ever built after the
	// container already has its real size, from the user clicking its row). Rather than
	// guessing when that resize completes, react to it directly.
	[containerView setPostsFrameChangedNotifications:YES];
	[[NSNotificationCenter defaultCenter] addObserver:self
											  selector:@selector(containerViewFrameDidChange:)
												  name:NSViewFrameDidChangeNotification
												object:containerView];

	
	NSDictionary *attrDict = [NSDictionary dictionaryWithObjectsAndKeys:
		[NSFont systemFontOfSize:13.0f], NSFontAttributeName,
		[NSColor secondaryLabelColor], NSForegroundColorAttributeName, nil];
	NSMutableAttributedString *noPrefsAttributed = [[NSMutableAttributedString alloc] initWithString:NoPluginPrefsTitle
		attributes:attrDict];
	[noPrefsAttributed setAlignment:NSTextAlignmentCenter range:NSMakeRange(0, [noPrefsAttributed length])];
	[noPrefsLabel setAttributedStringValue:noPrefsAttributed];

	HWGImageTextCell *imageTextCell = [[HWGImageTextCell alloc] init];
   [moduleColumn setDataCell:imageTextCell];

	// Fixed row height so the icon (sized below) never overflows into the next row.
	[tableView setRowHeight:40.0];

	// Fondo transparente para que se vea el fondo oscuro de la ventana
	[tableView setBackgroundColor:[NSColor clearColor]];
	[tableView setUsesAlternatingRowBackgroundColors:NO];
	tableView.style = NSTableViewStyleSourceList;
	[[tableView enclosingScrollView] setDrawsBackground:NO];
	[[tableView enclosingScrollView] setBorderType:NSNoBorder];
}

- (IBAction)showPreferences:(id)sender
{
   if(![self.window isVisible]){
      [self.window center];
      [self.window setFrameAutosaveName:@"HWGrowlerPrefsWindowFrame"];
      [self.window setFrameUsingName:@"HWGrowlerPrefsWindowFrame" force:YES];
   }
	// Become a regular (Dock-visible, focusable) app so the window can take
	// focus, then activate. Modern replacement for the deprecated Carbon
	// TransformProcessType(kProcessTransformToForegroundApplication).
	//
	// BUG FIX ATTEMPT #1 (23-jul-2026, DID NOT WORK): bare dispatch_async (single run-loop
	// tick) between the policy change and activation — no observed change.
	//
	// BUG FIX ATTEMPT #2 (23-jul-2026, PARTIAL): -activateWithOptions: + a real 0.15s delay
	// before activating — user confirmed this helped ("mejoro un poco") but the app still
	// goes to the end of the switcher in some circumstances.
	//
	// BUG FIX ATTEMPT #3 (23-jul-2026): instrumented with NSLog + os_log stream and
	// reproduced the user's exact repro (quit app, launch, launch again while running to
	// trigger -applicationShouldHandleReopen:, which is the only way to reach this method
	// when Visibility=kDontShowIcon since there's no status item to click). Confirmed via
	// log that AppKit itself already sends the process an "ApplicationDidBecomeActive"
	// activation BEFORE our delegate method even runs, while activationPolicy is still
	// Accessory — i.e. the switcher's first activation record for this reopen happens under
	// the wrong policy no matter what we do afterwards. Fix: activate immediately (matching
	// the classic, pre-deprecation TransformProcessType+SetFrontProcess pattern) in addition
	// to the delayed retry, so whichever timing the switcher actually keys off gets a
	// same-policy activation request from us.
	[NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
	[NSApp unhide:nil];
	[[NSRunningApplication currentApplication] activateWithOptions:NSApplicationActivateAllWindows | NSApplicationActivateIgnoringOtherApps];
	[self.window makeKeyAndOrderFront:sender];
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
		[[NSRunningApplication currentApplication] activateWithOptions:NSApplicationActivateAllWindows | NSApplicationActivateIgnoringOtherApps];
		[self.window makeKeyAndOrderFront:sender];
	});
}

- (void)windowWillClose:(NSNotification *)notification {
	NSNumber *value = [[[NSUserDefaultsController sharedUserDefaultsController] defaults] valueForKey:@"Visibility"];
	HWGrowlIconState visibility = [value integerValue];
	if(visibility == kDontShowIcon || visibility == kShowIconInMenu){
		dispatch_async(dispatch_get_main_queue(), ^{
			// Go back to a background (menu-bar-only) app. Modern replacement
			// for TransformProcessType(kProcessTransformToUIElementApplication).
			[NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
			// Relinquish focus — macOS automatically brings the previously
			// active app forward. More reliable than tracking the prior app,
			// because clicking our status item already made us frontmost.
			[NSApp hide:nil];
		});
	}
}

- (void) initMenu{
	statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
	[statusItem setMenu:statusMenu];
	
	// Menu-bar icon: a COLOR image (NOT a template) so the blue dot — our distinctive
	// mark — keeps its color. Because it isn't a template, macOS won't auto-tint it, so
	// we ship two variants and pick by the menu bar's appearance: "Normal" has dark claws
	// (for a light menu bar), "Selected" has light claws (for a dark menu bar); both keep
	// the blue dot. A drawing-handler image re-renders on appearance change, so it swaps
	// automatically when the user toggles light/dark.
	NSString *lightPath = [[NSBundle mainBundle] pathForResource:@"menubarIcon_Normal"   ofType:@"png"];
	NSString *darkPath  = [[NSBundle mainBundle] pathForResource:@"menubarIcon_Selected" ofType:@"png"];
	NSImage *clawsLight = [[NSImage alloc] initWithContentsOfFile:lightPath];  // dark claws + blue dot
	NSImage *clawsDark  = [[NSImage alloc] initWithContentsOfFile:darkPath];   // light claws + blue dot
	NSImage *icon = [NSImage imageWithSize:NSMakeSize(18.0, 18.0) flipped:NO drawingHandler:^BOOL(NSRect rect) {
		NSAppearanceName match = [[NSAppearance currentDrawingAppearance]
			bestMatchFromAppearancesWithNames:@[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]];
		NSImage *use = [match isEqualToString:NSAppearanceNameDarkAqua] ? clawsDark : clawsLight;
		[use drawInRect:rect fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1.0];
		return YES;
	}];
	icon.template = NO;   // color icon — do not tint (keeps the blue dot)
	statusItem.button.image = icon;

	// Add "About…" and "Uninstall…" items at the bottom of the status menu.
	[statusMenu addItem:[NSMenuItem separatorItem]];
	NSMenuItem *aboutItem = [[NSMenuItem alloc]
		initWithTitle:NSLocalizedString(@"About HG4MAC…", @"")
			   action:@selector(showAbout:)
		keyEquivalent:@""];
	aboutItem.target = self;
	[statusMenu addItem:aboutItem];

	NSMenuItem *uninstallItem = [[NSMenuItem alloc]
		initWithTitle:NSLocalizedString(@"Uninstall HG4MAC…", @"")
			   action:@selector(uninstall:)
		keyEquivalent:@""];
	uninstallItem.target = self;
	[statusMenu addItem:uninstallItem];
}

// Standard macOS About panel. Name / version / copyright come from the Info.plist
// (CFBundleName, CFBundleShortVersionString, NSHumanReadableCopyright); the credits
// carry the GPLv3 + no-warranty notice and a link to the license.
- (IBAction)showAbout:(id)sender {
	if (@available(macOS 14.0, *)) { [NSApp activate]; }
	else { [NSApp activateIgnoringOtherApps:YES]; }

	NSMutableAttributedString *credits = [[NSMutableAttributedString alloc]
		initWithString:NSLocalizedString(@"A macOS menu-bar app that shows native-style notifications when hardware changes.\n\nModernized fork of HardwareGrowler / Growl. Free software under the GNU General Public License v3.0 — with NO WARRANTY.\n", @"")
		attributes:@{ NSFontAttributeName: [NSFont systemFontOfSize:11],
		              NSForegroundColorAttributeName: [NSColor secondaryLabelColor] }];
	[credits appendAttributedString:[[NSAttributedString alloc]
		initWithString:@"gnu.org/licenses/gpl-3.0"
		attributes:@{ NSFontAttributeName: [NSFont systemFontOfSize:11],
		              NSLinkAttributeName: [NSURL URLWithString:@"https://www.gnu.org/licenses/gpl-3.0.html"] }]];

	[NSApp orderFrontStandardAboutPanel:@{ NSAboutPanelOptionCredits: credits }];
}

- (IBAction)uninstall:(id)sender {
	[NSApp activateIgnoringOtherApps:YES];
	NSAlert *alert = [[NSAlert alloc] init];
	alert.alertStyle = NSAlertStyleCritical;
	alert.messageText = NSLocalizedString(@"Uninstall HG4MAC?", @"");
	alert.informativeText = NSLocalizedString(@"This will quit HG4MAC, remove it from login items, delete all of its settings, and move the app to the Trash.\n\nThis cannot be undone.", @"");
	[alert addButtonWithTitle:NSLocalizedString(@"Uninstall", @"")];  // NSAlertFirstButtonReturn
	[alert addButtonWithTitle:NSLocalizedString(@"Cancel", @"")];     // NSAlertSecondButtonReturn
	if ([alert runModal] != NSAlertFirstButtonReturn)
		return;
	[self performUninstall];
}

- (void)performUninstall {
	NSString *bundleID = @"com.jensyleo.hg4mac";
	NSString *home = NSHomeDirectory();
	NSString *appPath = [[NSBundle mainBundle] bundlePath];

	// Unregister the login item in-process (needs our SMAppService).
	if (@available(macOS 13.0, *)) {
		[[SMAppService mainAppService] unregisterAndReturnError:NULL];
	}

	// Everything else is done by a DETACHED shell script that runs AFTER we
	// quit. This is essential for the preferences: while the app is alive,
	// cfprefsd owns the domain and rewrites the plist on exit, so deleting it
	// in-process leaves an orphan. Running `defaults delete` + rm after the app
	// has terminated avoids that. The script also clears every other standard
	// Library location and moves the app bundle to the Trash — no orphans left.
	NSString *trash = [home stringByAppendingPathComponent:@".Trash"];
	NSArray *dirs = @[@"Library/Preferences", @"Library/Preferences/ByHost",
	                  @"Library/Caches", @"Library/Saved Application State",
	                  @"Library/HTTPStorages", @"Library/WebKit",
	                  @"Library/Application Support", @"Library/LaunchAgents",
	                  @"Library/Logs/DiagnosticReports",
	                  @"Library/Application Support/CrashReporter"];

	NSMutableString *cmd = [NSMutableString string];
	[cmd appendString:@"sleep 1; "];
	[cmd appendFormat:@"/usr/bin/defaults delete %@ >/dev/null 2>&1; ", bundleID];
	// Also drop the legacy Growl-named prefs domain from installs before the rename.
	[cmd appendString:@"/usr/bin/defaults delete com.growl.hardwaregrowler >/dev/null 2>&1; "];
	for (NSString *rel in dirs) {
		NSString *dir = [home stringByAppendingPathComponent:rel];
		[cmd appendFormat:@"/bin/rm -rf \"%@\"/*%@* >/dev/null 2>&1; ", dir, bundleID];
		[cmd appendFormat:@"/bin/rm -rf \"%@\"/*HG4MAC* >/dev/null 2>&1; ", dir];
		// Legacy pre-rename artifacts (old app name / bundle id).
		[cmd appendFormat:@"/bin/rm -rf \"%@\"/*HardwareGrowler* >/dev/null 2>&1; ", dir];
		[cmd appendFormat:@"/bin/rm -rf \"%@\"/*com.growl.hardwaregrowler* >/dev/null 2>&1; ", dir];
	}
	[cmd appendFormat:@"/bin/mv \"%@\" \"%@/\" >/dev/null 2>&1; ", appPath, trash];

	NSTask *task = [[NSTask alloc] init];
	task.launchPath = @"/bin/sh";
	task.arguments = @[@"-c", cmd];
	[task launch];

	[NSApp terminate:nil];
}

- (void) initTitles{
	self.showDevices = ShowDevicesTitle;
	self.quitTitle = QuitTitle;
	self.preferencesTitle = PreferencesTitle;
	self.openPreferencesTitle = OpenPreferencesTitle;
	self.iconTitle = IconTitle;
	self.startAtLoginTitle = StartAtLoginTitle;
	self.noPluginPrefsTitle = NoPluginPrefsTitle;
	self.moduleLabel = ModuleLabel;
}

- (void)requestAllPermissions {
	// 1. Notificaciones — el delegate se necesita para el caso en que sí se otorgue permiso
	[[UNUserNotificationCenter currentNotificationCenter] setDelegate:self];
	[[UNUserNotificationCenter currentNotificationCenter]
		requestAuthorizationWithOptions:(UNAuthorizationOptionAlert | UNAuthorizationOptionSound)
		completionHandler:^(BOOL granted, NSError *error) {
			(void)granted; (void)error;
		}];

	// 2. Bluetooth — iniciarlo provoca el diálogo de permiso del sistema
	dispatch_async(dispatch_get_main_queue(), ^{
		CBCentralManager *cbManager = [[CBCentralManager alloc]
			initWithDelegate:nil queue:nil
			options:@{CBCentralManagerOptionShowPowerAlertKey: @NO}];
		// Retener brevemente para que el sistema procese el permiso
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
			(void)cbManager; // liberar
		});
	});
}

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification
{
	// Single-instance guard: if another copy with our bundle id is already running,
	// this launch is a duplicate — quit immediately and let the existing one keep
	// running. Belt-and-suspenders alongside LSMultipleInstancesProhibited in the
	// Info.plist (this also covers launches Launch Services doesn't police, e.g.
	// executing the binary directly or via launchd).
	NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
	for (NSRunningApplication *other in [NSRunningApplication runningApplicationsWithBundleIdentifier:bundleID]) {
		if (![other isEqual:[NSRunningApplication currentApplication]]) {
			[NSApp terminate:nil];
			return;
		}
	}

	[self requestAllPermissions];

	[[self toolbar] setVisible:YES];
	if([[[self toolbar] items] count] == 0){
		[[self toolbar] insertItemWithItemIdentifier:@"General" atIndex:0];
		[[self toolbar] insertItemWithItemIdentifier:@"Modules" atIndex:1];
	}
	[self selectTabIndex:0];
	[self initTitles];
		
	[[NSUserDefaultsController sharedUserDefaultsController] addObserver:self
																				 forKeyPath:@"values.Visibility"
																					 options:NSKeyValueObservingOptionNew
																					 context:nil];
	oldIconValue = [[[NSUserDefaultsController sharedUserDefaultsController] defaults] integerForKey:@"Visibility"];

	BOOL isRegistered = [self isRegisteredAtLogin];
	[[NSUserDefaultsController sharedUserDefaultsController].defaults setBool:isRegistered forKey:@"OnLogin"];
	oldOnLoginValue = isRegistered;
}

- (BOOL) applicationShouldHandleReopen:(NSApplication *)theApplication hasVisibleWindows:(BOOL)flag {
	[self showPreferences:self];
	return YES;
}

- (void)observeValueForKeyPath:(NSString*)keyPath 
							 ofObject:(id)object 
								change:(NSDictionary*)change 
							  context:(void*)context
{
	NSUserDefaultsController *defaultController = [NSUserDefaultsController sharedUserDefaultsController];
	if([keyPath isEqualToString:@"values.Visibility"])
	{
		NSNumber *value = [[defaultController defaults] valueForKey:@"Visibility"];
		HWGrowlIconState index   = [value integerValue];
		switch (index) {
			case kDontShowIcon:
				if(![[defaultController defaults] boolForKey:@"SuppressNoIconWarn"])
				{
					[NSApp activateIgnoringOtherApps:YES];
					// Modern NSAlert (the alertWithMessageText:defaultButton:... constructor
					// was deprecated in 10.10). First button added = NSAlertFirstButtonReturn.
					NSAlert *alert = [[NSAlert alloc] init];
					alert.messageText = NSLocalizedString(@"Warning! Enabling this option will cause HG4MAC to run in the background", nil);
					alert.informativeText = NSLocalizedString(@"Enabling this option will cause HG4MAC to run without showing a dock icon or a menu item.\n\nTo access preferences, tap HG4MAC in Launchpad, or open HG4MAC in Finder.", nil);
					[alert addButtonWithTitle:NSLocalizedString(@"Ok", nil)];      // NSAlertFirstButtonReturn
					[alert addButtonWithTitle:NSLocalizedString(@"Cancel", nil)];  // NSAlertSecondButtonReturn
					alert.showsSuppressionButton = YES;
					NSInteger allow = [alert runModal];
					if(allow == NSAlertFirstButtonReturn)
					{
						if([[alert suppressionButton] state] == NSControlStateValueOn){
							[[defaultController defaults] setBool:YES forKey:@"SuppressNoIconWarn"];
						}
						[self warnUserAboutIcons];
						[[NSStatusBar systemStatusBar] removeStatusItem:statusItem];
						statusItem = nil;
					}
					else
					{
						[[defaultController defaults] setInteger:oldIconValue forKey:@"Visibility"];
						[[defaultController defaults] synchronize];
						[iconPopUp selectItemAtIndex:oldIconValue];
					}
				}else{
					[self warnUserAboutIcons];
					[[NSStatusBar systemStatusBar] removeStatusItem:statusItem];
					statusItem = nil;
				}
				break;
			case kShowIconInBoth:
				[NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
				if(!statusItem)
					[self initMenu];
				break;
			case kShowIconInDock:
				[NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
				[[NSStatusBar systemStatusBar] removeStatusItem:statusItem];
				statusItem = nil;
				break;
			case kShowIconInMenu:
			default:
				if(!statusItem)
					[self initMenu];
				if(oldIconValue == kShowIconInBoth || oldIconValue == kShowIconInDock)
					[self warnUserAboutIcons];
				break;
		}
		oldIconValue = index;
	}
}

- (void)warnUserAboutIcons
{
	// Legacy no-op: this warning only applied to macOS < 10.7, which the app no
	// longer supports (deployment target 13.0). Icon changes apply immediately.
}

- (void)userNotificationCenter:(UNUserNotificationCenter *)center
       willPresentNotification:(UNNotification *)notification
         withCompletionHandler:(void (^)(UNNotificationPresentationOptions))completionHandler {
	completionHandler(UNNotificationPresentationOptionBanner | UNNotificationPresentationOptionSound);
}

- (void) setStartAtLogin:(BOOL)enabled {
    NSLog(@"HWG setStartAtLogin: %@", enabled ? @"YES" : @"NO");

    // macOS 13+: use SMAppService so the item appears in System Settings >
    // General > Login Items (and "App background activity") and is user-managed.
    if (@available(macOS 13.0, *)) {
        SMAppService *svc = [SMAppService mainAppService];
        NSError *err = nil;
        BOOL ok = enabled ? [svc registerAndReturnError:&err]
                          : [svc unregisterAndReturnError:&err];
        if (!ok) NSLog(@"HWG SMAppService %@ error: %@",
                       enabled ? @"register" : @"unregister", err);
        // Clean up any legacy LaunchAgent left by older versions.
        if (enabled) {
            NSString *legacy = [NSHomeDirectory() stringByAppendingPathComponent:
                @"Library/LaunchAgents/com.growl.hardwaregrowler.plist"];
            [[NSFileManager defaultManager] removeItemAtPath:legacy error:nil];
        }
        return;
    }

    // Fallback for < macOS 13: manual LaunchAgent plist.
    NSString *label = @"com.growl.hardwaregrowler";
    NSString *launchAgentsDir = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/LaunchAgents"];
    NSString *plistPath = [launchAgentsDir stringByAppendingPathComponent:[label stringByAppendingString:@".plist"]];
    if (enabled) {
        [[NSFileManager defaultManager] createDirectoryAtPath:launchAgentsDir
                                  withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *bundlePath = [[NSBundle mainBundle] bundlePath];
        NSDictionary *plist = @{
            @"Label": label,
            @"ProgramArguments": @[@"/usr/bin/open", @"-a", bundlePath],
            @"RunAtLoad": @YES,
            @"KeepAlive": @NO
        };
        BOOL ok = [plist writeToFile:plistPath atomically:YES];
        NSLog(@"HWG plist written=%d path=%@", ok, plistPath);
    } else {
        [[NSFileManager defaultManager] removeItemAtPath:plistPath error:nil];
        NSLog(@"HWG plist removed");
    }
}

- (BOOL) isRegisteredAtLogin {
    if (@available(macOS 13.0, *)) {
        return [SMAppService mainAppService].status == SMAppServiceStatusEnabled;
    }
    NSString *plistPath = [NSHomeDirectory() stringByAppendingPathComponent:
        @"Library/LaunchAgents/com.growl.hardwaregrowler.plist"];
    return [[NSFileManager defaultManager] fileExistsAtPath:plistPath];
}

#pragma mark Performance preset

// Builds the "Performance" radio row (Minimal/All/Custom) at the TOP of the Modules tab —
// moved here from General (22-jul-2026, user's request: "por sentido común, lleva esas 3
// opciones a Modules", since this setting is entirely about which modules run).
//
// REWRITTEN (22-jul-2026) to use Auto Layout throughout instead of manual frame math: an
// earlier version tried to preserve the two existing nib-authored subviews' legacy
// springs-and-struts autoresizing (shrinking their frame height once, relying on
// NSView's margin-preservation to keep things aligned as the window resizes) — that
// requires knowing the EXACT view height at the moment the shrink is applied, which this
// code has no reliable way to determine (the Modules tab may or may not already be at its
// final stretched size by the time -awakeFromNib runs, unlike the General tab where it
// happened to still be at the nib's authored size) — got the controls "mal ubicados" (badly
// placed) as a result. Auto Layout constraints, anchored directly between the views
// themselves rather than computed from an assumed total height, are correct regardless of
// when/whether any resize has already happened — matches how NetworkMonitor's own
// programmatically-built prefs sections in this codebase are already done.
- (void)buildPerformanceSection {
	NSTabViewItem *modulesTabItem = [tabView tabViewItemAtIndex:1];
	NSView *modulesView = [modulesTabItem view];
	if (!modulesView) return;

	NSScrollView *moduleScrollView = nil;
	NSBox *detailBox = nil;
	for (NSView *sub in modulesView.subviews) {
		if ([sub isKindOfClass:[NSScrollView class]]) moduleScrollView = (NSScrollView *)sub;
		else if ([sub isKindOfClass:[NSBox class]]) detailBox = (NSBox *)sub;
	}
	if (!moduleScrollView || !detailBox) return;

	// Capture the two existing views' current horizontal geometry (left inset, width/right
	// inset, and the gap between them) BEFORE opting them into Auto Layout, so their
	// horizontal arrangement is preserved exactly — only their VERTICAL behavior changes
	// (top edge now depends on the new Performance row instead of a fixed nib y-coordinate).
	CGFloat scrollLeftInset = NSMinX(moduleScrollView.frame) - NSMinX(modulesView.bounds);
	CGFloat scrollWidth = NSWidth(moduleScrollView.frame);
	CGFloat bottomInset = NSMinY(moduleScrollView.frame) - NSMinY(modulesView.bounds);
	CGFloat gapBetween = NSMinX(detailBox.frame) - NSMaxX(moduleScrollView.frame);
	CGFloat boxRightInset = NSMaxX(modulesView.bounds) - NSMaxX(detailBox.frame);
	CGFloat boxBottomInset = NSMinY(detailBox.frame) - NSMinY(modulesView.bounds);

	moduleScrollView.translatesAutoresizingMaskIntoConstraints = NO;
	detailBox.translatesAutoresizingMaskIntoConstraints = NO;

	NSTextField *header = [NSTextField labelWithString:NSLocalizedString(@"Performance", @"")];
	header.font = [NSFont boldSystemFontOfSize:12];
	header.textColor = [NSColor secondaryLabelColor];
	header.translatesAutoresizingMaskIntoConstraints = NO;
	[modulesView addSubview:header];

	NSInteger storedMode = [[NSUserDefaults standardUserDefaults] objectForKey:HWG_PERFORMANCE_MODE_KEY]
		? [[NSUserDefaults standardUserDefaults] integerForKey:HWG_PERFORMANCE_MODE_KEY]
		: HWG_PERFORMANCE_MODE_DEFAULT;

	NSButton *minimalRadio = [self performanceRadioWithTitle:NSLocalizedString(@"Minimal elements", @"")
													  tooltip:NSLocalizedString(@"Only the original monitors: Volume, USB, Thunderbolt, Bluetooth, Power, Network. Lightest on resources.", @"")
														  tag:HWGPerformanceModeMinimal];
	NSButton *allRadio = [self performanceRadioWithTitle:NSLocalizedString(@"All elements", @"")
												  tooltip:NSLocalizedString(@"Every monitor, including Audio/Camera/Gamepad/Printer/Thermal/Display. Default.", @"")
													  tag:HWGPerformanceModeAll];
	NSButton *customRadio = [self performanceRadioWithTitle:NSLocalizedString(@"Custom", @"")
													 tooltip:NSLocalizedString(@"Choose exactly which monitors run below.", @"")
														 tag:HWGPerformanceModeCustom];

	minimalRadio.state = (storedMode == HWGPerformanceModeMinimal) ? NSControlStateValueOn : NSControlStateValueOff;
	allRadio.state     = (storedMode == HWGPerformanceModeAll)     ? NSControlStateValueOn : NSControlStateValueOff;
	customRadio.state  = (storedMode == HWGPerformanceModeCustom)  ? NSControlStateValueOn : NSControlStateValueOff;

	[modulesView addSubview:minimalRadio];
	[modulesView addSubview:allRadio];
	[modulesView addSubview:customRadio];

	[NSLayoutConstraint activateConstraints:@[
		// Header: top-left corner of the Modules tab.
		[header.topAnchor      constraintEqualToAnchor:modulesView.topAnchor constant:12],
		[header.leadingAnchor  constraintEqualToAnchor:modulesView.leadingAnchor constant:scrollLeftInset],

		// Radio row: directly below the header, left-aligned with it.
		[minimalRadio.topAnchor     constraintEqualToAnchor:header.bottomAnchor constant:8],
		[minimalRadio.leadingAnchor constraintEqualToAnchor:header.leadingAnchor],

		[allRadio.topAnchor      constraintEqualToAnchor:minimalRadio.topAnchor],
		[allRadio.leadingAnchor  constraintEqualToAnchor:minimalRadio.trailingAnchor constant:16],

		[customRadio.topAnchor     constraintEqualToAnchor:minimalRadio.topAnchor],
		[customRadio.leadingAnchor constraintEqualToAnchor:allRadio.trailingAnchor constant:16],

		// Module list (scroll view): same left inset/width as before, now starts below the
		// radio row instead of at a fixed y, and still ends at the same bottom inset.
		[moduleScrollView.leadingAnchor  constraintEqualToAnchor:modulesView.leadingAnchor constant:scrollLeftInset],
		[moduleScrollView.widthAnchor    constraintEqualToConstant:scrollWidth],
		[moduleScrollView.topAnchor      constraintEqualToAnchor:minimalRadio.bottomAnchor constant:12],
		[moduleScrollView.bottomAnchor   constraintEqualToAnchor:modulesView.bottomAnchor constant:-bottomInset],

		// Detail box: same gap from the scroll view and right/bottom insets as before, top
		// aligned with the scroll view (both start right below the radio row together).
		[detailBox.leadingAnchor  constraintEqualToAnchor:moduleScrollView.trailingAnchor constant:gapBetween],
		[detailBox.trailingAnchor constraintEqualToAnchor:modulesView.trailingAnchor constant:-boxRightInset],
		[detailBox.topAnchor      constraintEqualToAnchor:moduleScrollView.topAnchor],
		[detailBox.bottomAnchor   constraintEqualToAnchor:modulesView.bottomAnchor constant:-boxBottomInset],
	]];

	performanceMinimalRadio = minimalRadio;
	performanceAllRadio = allRadio;
	performanceCustomRadio = customRadio;
}

// Whenever the user manually flips a single monitor's enabled state in the Modules tab (an
// action the Minimal/All presets don't do — those only ever touch EVERY monitor at once),
// the current state no longer matches either preset exactly. Reflect that honestly by
// switching the Performance selector to "Custom" instead of leaving a stale/misleading
// Minimal or All selection checked.
- (void)markPerformanceModeAsCustom {
	[[NSUserDefaults standardUserDefaults] setInteger:HWGPerformanceModeCustom forKey:HWG_PERFORMANCE_MODE_KEY];
	performanceMinimalRadio.state = NSControlStateValueOff;
	performanceAllRadio.state = NSControlStateValueOff;
	performanceCustomRadio.state = NSControlStateValueOn;
}

- (NSButton *)performanceRadioWithTitle:(NSString *)title tooltip:(NSString *)tooltip tag:(NSInteger)tag {
	NSButton *radio = [NSButton radioButtonWithTitle:title target:self action:@selector(performanceModeChanged:)];
	radio.tag = tag;
	radio.toolTip = tooltip;
	radio.translatesAutoresizingMaskIntoConstraints = NO;
	return radio;
}

-(IBAction)performanceModeChanged:(NSButton*)sender {
	NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
	HWGPerformanceMode mode = (HWGPerformanceMode)sender.tag;
	HWGPerformanceMode oldMode = [defaults objectForKey:HWG_PERFORMANCE_MODE_KEY]
		? [defaults integerForKey:HWG_PERFORMANCE_MODE_KEY]
		: HWG_PERFORMANCE_MODE_DEFAULT;

	// Leaving Custom for Minimal/All: save the current arrangement first, or it's gone the
	// moment Minimal/All overwrites "DisabledPlugins" (bug found 22-jul-2026).
	if (oldMode == HWGPerformanceModeCustom && mode != HWGPerformanceModeCustom) {
		[self captureCustomSnapshot];
	}

	[defaults setInteger:mode forKey:HWG_PERFORMANCE_MODE_KEY];

	if (mode == HWGPerformanceModeCustom) {
		[self restoreCustomSnapshotIfAny];
		return;
	}
	[self applyPerformancePresetMode:mode];
}

// Shared enable/disable engine for BOTH the Minimal/All presets and restoring a saved Custom
// snapshot — `resolver` decides, per bundle ID, whether that plugin should end up disabled.
// Mirrors -moduleCheckbox:'s own start/stopObserving + "DisabledPlugins" persistence, applied
// to every plugin at once. Skips plugins whose state doesn't actually change (no pointless
// start/stop calls), then refreshes the Modules table so its checkboxes reflect the new state.
- (void)applyDisabledStateWithResolver:(BOOL (^)(NSString *bundleID))resolver {
	// Guard: this method's own writes to "DisabledPlugins" must NOT be mistaken by
	// -userDefaultsDidChange: for a manual per-monitor-pane change (which would immediately
	// flip the just-chosen preset back to Custom).
	applyingPerformancePreset = YES;

	NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
	NSMutableDictionary *disabledDict = [[defaults objectForKey:@"DisabledPlugins"] mutableCopy] ?: [NSMutableDictionary dictionary];

	for (NSMutableDictionary *pluginDict in [pluginController plugins]) {
		id<HWGrowlPluginProtocol> plugin = [pluginDict objectForKey:@"plugin"];
		NSString *bundleID = [[NSBundle bundleForClass:[plugin class]] bundleIdentifier];
		BOOL wasDisabled = [[pluginDict objectForKey:@"disabled"] boolValue];
		BOOL shouldBeDisabled = resolver(bundleID);

		if (shouldBeDisabled != wasDisabled) {
			[pluginDict setObject:@(shouldBeDisabled) forKey:@"disabled"];
			if (shouldBeDisabled) {
				if ([plugin respondsToSelector:@selector(stopObserving)]) [plugin stopObserving];
			} else {
				if ([plugin respondsToSelector:@selector(startObserving)]) [plugin startObserving];
			}
		}
		if (bundleID) [disabledDict setObject:@(shouldBeDisabled) forKey:bundleID];
	}

	[defaults setObject:disabledDict forKey:@"DisabledPlugins"];
	[defaults synchronize];
	[tableView reloadData];

	applyingPerformancePreset = NO;
	lastKnownDefaultsSnapshot = [defaults dictionaryRepresentation];
}

- (void)applyPerformancePresetMode:(HWGPerformanceMode)mode {
	NSSet<NSString*> *minimalSet = HWGMinimalPluginBundleIdentifiers();
	[self applyDisabledStateWithResolver:^BOOL(NSString *bundleID) {
		return (mode == HWGPerformanceModeMinimal) ? ![minimalSet containsObject:bundleID] : NO;
	}];
}

// Saves the CURRENT monitor enable/disable arrangement as "the Custom arrangement" — called
// right before switching AWAY from Custom to Minimal/All, so it survives Minimal/All
// overwriting "DisabledPlugins" and can be brought back later (see -restoreCustomSnapshotIfAny).
- (void)captureCustomSnapshot {
	NSDictionary *disabledDict = [[NSUserDefaults standardUserDefaults] objectForKey:@"DisabledPlugins"];
	if (disabledDict) {
		[[NSUserDefaults standardUserDefaults] setObject:disabledDict forKey:HWG_PERFORMANCE_CUSTOM_SNAPSHOT_KEY];
	}
}

// Restores the arrangement captured by -captureCustomSnapshot. If the user has never left
// Custom before (no snapshot yet — e.g. right after this feature shipped, or a fresh install
// that's never touched Minimal/All), there's nothing to restore — leave the current
// arrangement untouched, matching Custom's original "don't force anything" behavior.
- (void)restoreCustomSnapshotIfAny {
	NSDictionary *snapshot = [[NSUserDefaults standardUserDefaults] objectForKey:HWG_PERFORMANCE_CUSTOM_SNAPSHOT_KEY];
	if (!snapshot) return;
	[self applyDisabledStateWithResolver:^BOOL(NSString *bundleID) {
		return bundleID ? [[snapshot objectForKey:bundleID] boolValue] : NO;
	}];
}

#pragma mark Detecting changes inside a monitor's own prefs pane

// Keys that are NOT a monitor's own setting — changing these must never flip Performance to
// "Custom". Every other NSUserDefaults key is assumed to belong to some monitor's F33/F34
// preferences pane (Power/Thermal/Display/Audio/Camera/Gamepad/Network/Volume/Thunderbolt/
// Printer all persist their own checkboxes straight to NSUserDefaults with no shared callback
// into AppDelegate, so there is no cheaper way to notice "the user changed a monitor setting"
// than diffing defaults directly).
+ (NSSet<NSString*> *)nonMonitorDefaultsKeys {
	static NSSet<NSString*> *keys = nil;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		keys = [NSSet setWithArray:@[
			@"Visibility", @"OnLogin", @"ShowExisting", @"GroupNetwork",
			HWG_PERFORMANCE_MODE_KEY, @"DisabledPlugins",
			// AppKit/window-state autosave keys some AppKit versions persist under
			// NSUserDefaults for this app's window — not user-facing "settings" at all.
			@"NSWindow Frame Preferences",
		]];
	});
	return keys;
}

- (void)startObservingDefaultsForCustomModeDetection {
	lastKnownDefaultsSnapshot = [[NSUserDefaults standardUserDefaults] dictionaryRepresentation];
	[[NSNotificationCenter defaultCenter] addObserver:self
											  selector:@selector(userDefaultsDidChange:)
												  name:NSUserDefaultsDidChangeNotification
												object:nil];
}

- (void)userDefaultsDidChange:(NSNotification *)note {
	NSDictionary *current = [[NSUserDefaults standardUserDefaults] dictionaryRepresentation];
	NSDictionary *previous = lastKnownDefaultsSnapshot;
	lastKnownDefaultsSnapshot = current;
	if (applyingPerformancePreset) return;   // our own preset-apply write — not a manual change

	NSSet<NSString*> *ignoredKeys = [AppDelegate nonMonitorDefaultsKeys];
	__block BOOL monitorSettingChanged = NO;
	[current enumerateKeysAndObjectsUsingBlock:^(NSString *key, id value, BOOL *stop) {
		if ([ignoredKeys containsObject:key]) return;
		if (![previous[key] isEqual:value]) { monitorSettingChanged = YES; *stop = YES; }
	}];
	if (!monitorSettingChanged) return;

	NSInteger currentMode = [[NSUserDefaults standardUserDefaults] integerForKey:HWG_PERFORMANCE_MODE_KEY];
	if (currentMode == HWGPerformanceModeCustom) return;   // already Custom, nothing to flip
	[self markPerformanceModeAsCustom];
}

#pragma mark Module Table

-(IBAction)moduleCheckbox:(id)sender {
	NSInteger selection = [tableView clickedRow];
	if(selection >= 0 && (NSUInteger)selection < [[pluginController plugins] count]){
		NSMutableDictionary *pluginDict = [[pluginController plugins] objectAtIndex:selection];
		id<HWGrowlPluginProtocol> plugin = [pluginDict objectForKey:@"plugin"];
		NSString *identifier = [[NSBundle bundleForClass:[plugin class]] bundleIdentifier];
		NSNumber *disabled = [pluginDict objectForKey:@"disabled"];
		
		if([disabled boolValue]){
			if([plugin respondsToSelector:@selector(stopObserving)])
				[plugin stopObserving];
		}else{
			if([plugin respondsToSelector:@selector(startObserving)])
				[plugin startObserving];
		}
		
		NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
		NSMutableDictionary *disabledDict = [[defaults objectForKey:@"DisabledPlugins"] mutableCopy];
		if(!disabledDict)
			disabledDict = [NSMutableDictionary dictionary];
		[disabledDict setObject:disabled forKey:identifier];
		[defaults setObject:disabledDict forKey:@"DisabledPlugins"];
		[defaults synchronize];

		// A manual per-monitor change no longer matches whichever preset was selected
		// (Minimal/All only ever change EVERY monitor together) — reflect that honestly.
		[self markPerformanceModeAsCustom];
	}
}

-(void)tableViewSelectionDidChange:(NSNotification *)notification {
	NSInteger selection = [tableView selectedRow];
	NSView *newView = nil;
	if(selection >= 0 && (NSUInteger)selection < [[pluginController plugins] count]){
		id<HWGrowlPluginProtocol> plugin = [[[pluginController plugins] objectAtIndex:selection] objectForKey:@"plugin"];
		if([plugin preferencePane]){
			newView = [plugin preferencePane];
		}else{
			newView = placeholderView;
		}
	}else
		newView = placeholderView;
	[newView setFrameSize:[containerView frame].size];
	if([currentView superview])
		[currentView removeFromSuperview];
	[containerView addSubview:newView];
	self.currentView = newView;
	[containerView layoutSubtreeIfNeeded];
	[_window recalculateKeyViewLoop];
}

// containerView can still resize AFTER a pane has been sized/inserted above (see the
// -awakeFromNib comment where this is observed) — keep the currently-displayed pane's
// frame in sync whenever that happens, instead of assuming containerView's frame at
// insertion time is final.
-(void)containerViewFrameDidChange:(NSNotification *)notification {
	if (!currentView) return;
	[currentView setFrameSize:[containerView frame].size];
	[containerView layoutSubtreeIfNeeded];
}

- (NSTableRowView *)tableView:(NSTableView *)aTableView rowViewForRow:(NSInteger)row {
	return [[HWGGraySelectionRowView alloc] init];
}

- (id) tableView:(NSTableView *)aTableView objectValueForTableColumn:(NSTableColumn *)aTableColumn row:(NSInteger)rowIndex {
	if (aTableColumn == moduleColumn) {
		id<HWGrowlPluginProtocol> plugin = [[[pluginController plugins] objectAtIndex:rowIndex] objectForKey:@"plugin"];
		return [plugin pluginDisplayName];
	}
	return nil;
}

- (void)tableView:(NSTableView *)aTableView willDisplayCell:(id)aCell forTableColumn:(NSTableColumn *)aTableColumn row:(NSInteger)rowIndex {
	if (aTableColumn == moduleColumn && [aCell isKindOfClass:[HWGImageTextCell class]]) {
		id<HWGrowlPluginProtocol> plugin = [[[pluginController plugins] objectAtIndex:rowIndex] objectForKey:@"plugin"];
		NSImage *icon = [plugin preferenceIcon];
		if (!icon) {
			static NSImage *placeholder = nil;
			static dispatch_once_t onceToken;
			dispatch_once(&onceToken, ^{
				placeholder = [NSImage imageNamed:@"HWGPrefsDefault"];
			});
			icon = placeholder;
		}
		// Asset-catalog icons are 512×512; the cell draws at the image's natural
		// size, so pin to 32×32 to fit the 40px list row without overlapping.
		icon.size = NSMakeSize(32, 32);
		[(HWGImageTextCell *)aCell setImage:icon];
	}
}

#pragma mark Toolbar

-(void)selectTabIndex:(NSInteger)tab {
	if(tab < 0 || tab > 1)
		tab = 0;
	[toolbar setSelectedItemIdentifier:[NSString stringWithFormat:@"%ld", tab]];
	[tabView selectTabViewItemAtIndex:tab];
}

-(IBAction)selectTab:(id)sender {
	[self selectTabIndex:[sender tag]];
}

-(BOOL)validateToolbarItem:(NSToolbarItem *)theItem {
	return YES;
}

-(NSArray*)toolbarSelectableItemIdentifiers:(NSToolbar*)aToolbar
{
	return [NSArray arrayWithObjects:@"0", @"1", nil];
}

- (NSArray *)toolbarAllowedItemIdentifiers:(NSToolbar *)toolbar
{
   return [NSArray arrayWithObjects:@"0", @"1", nil];
}

- (NSArray *)toolbarDefaultItemIdentifiers:(NSToolbar*)aToolbar 
{
   return [NSArray arrayWithObjects:@"0", @"1", nil];
}

@end
