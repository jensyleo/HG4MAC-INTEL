//
//  HWGrowlGamepadMonitor.m
//  HardwareGrowler
//

// compile with ARC: -fobjc-arc
#import "HWGrowlGamepadMonitor.h"
#import <GameController/GameController.h>

// F19: unlike Audio/Camera Monitor, GameController framework exposes no transport type for a
// GCController, so there's no reliable way to suppress the (very common) case where the same
// physical connect is ALSO reported by USB/Bluetooth Monitor. Deliberately NOT suppressed —
// confirmed with the user (19-jul-2026) as the right call, same reasoning already accepted
// for Audio Monitor's default-device-change axis: the generic "USB/Bluetooth Device
// Connected: <name>" notification doesn't know it's specifically a recognized GAME
// CONTROLLER, its vendor/product category (DualSense/Xbox/MFi/etc.), player index, or
// battery — genuinely new information even when the underlying connect event is the same one
// another monitor already announced.

#define HWG_GAMEPAD_SHOW_CATEGORY_KEY    @"HWGGamepadShowCategory"
#define HWG_GAMEPAD_SHOW_PLAYER_INDEX_KEY @"HWGGamepadShowPlayerIndex"
#define HWG_GAMEPAD_SHOW_BATTERY_KEY     @"HWGGamepadShowBattery"

static BOOL HWGGamepadBoolForKey(NSString *key, BOOL def) {
	id stored = [[NSUserDefaults standardUserDefaults] objectForKey:key];
	return stored ? [stored boolValue] : def;
}

@interface HWGrowlGamepadMonitor ()

@property (nonatomic, weak) id<HWGrowlPluginControllerProtocol> delegate;
@property (nonatomic, strong) NSView *prefsView;

@end

@implementation HWGrowlGamepadMonitor

@synthesize delegate;
@synthesize prefsView;

-(id)init {
	self = [super init];
	if (self) {
		[[NSNotificationCenter defaultCenter] addObserver:self
												  selector:@selector(controllerConnected:)
													  name:GCControllerDidConnectNotification
													object:nil];
		[[NSNotificationCenter defaultCenter] addObserver:self
												  selector:@selector(controllerDisconnected:)
													  name:GCControllerDidDisconnectNotification
													object:nil];

		// Without this, GCControllerDidConnectNotification never fires for a controller that
		// connects AFTER launch — confirmed live (22-jul-2026): connecting a controller only
		// produced USB/Bluetooth Monitor's generic notification, never "Game Controller
		// Connected". GCController requires the app to actively ask the system to search for
		// wireless controllers; without ever calling this, GameController framework doesn't
		// route connect events to a background/menu-bar-only app like this one at all (not
		// just for Bluetooth — this turned out to matter even for the wired controller
		// tested). nil completion handler: this runs for the plugin's whole lifetime, there's
		// no single "discovery finished" moment to act on.
		[GCController startWirelessControllerDiscoveryWithCompletionHandler:nil];
	}
	return self;
}

-(void)dealloc {
	[[NSNotificationCenter defaultCenter] removeObserver:self];
	[GCController stopWirelessControllerDiscovery];
}

#pragma mark Connect/disconnect

-(NSString *)playerIndexLabel:(GCControllerPlayerIndex)index {
	switch (index) {
		case GCControllerPlayerIndex1: return @"1";
		case GCControllerPlayerIndex2: return @"2";
		case GCControllerPlayerIndex3: return @"3";
		case GCControllerPlayerIndex4: return @"4";
		default: return nil;
	}
}

-(NSString *)extraInfoForController:(GCController *)controller {
	NSMutableArray<NSString *> *lines = [NSMutableArray array];

	if (HWGGamepadBoolForKey(HWG_GAMEPAD_SHOW_CATEGORY_KEY, YES) && controller.productCategory.length) {
		[lines addObject:[NSString stringWithFormat:NSLocalizedString(@"Type:\t%@", @""), controller.productCategory]];
	}
	if (HWGGamepadBoolForKey(HWG_GAMEPAD_SHOW_PLAYER_INDEX_KEY, YES)) {
		NSString *playerLabel = [self playerIndexLabel:controller.playerIndex];
		if (playerLabel) [lines addObject:[NSString stringWithFormat:NSLocalizedString(@"Player:\t%@", @""), playerLabel]];
	}
	if (HWGGamepadBoolForKey(HWG_GAMEPAD_SHOW_BATTERY_KEY, YES) && controller.battery) {
		float level = controller.battery.batteryLevel;
		if (level >= 0) {
			[lines addObject:[NSString stringWithFormat:NSLocalizedString(@"Battery:\t%.0f%%", @""), level * 100.0]];
		}
	}

	return [lines count] ? [lines componentsJoinedByString:@"\n"] : nil;
}

-(void)controllerConnected:(NSNotification *)note {
	GCController *controller = note.object;
	NSString *name = controller.vendorName ?: NSLocalizedString(@"Game Controller", @"");
	NSString *extraInfo = [self extraInfoForController:controller];
	NSString *description = extraInfo ? [NSString stringWithFormat:@"%@\n%@", name, extraInfo] : name;

	[delegate notifyWithName:@"GamepadConnected"
						 title:NSLocalizedString(@"Game Controller Connected", @"")
					   description:description
						  icon:[self iconData]
			  identifierString:[NSString stringWithFormat:@"HWGrowlGamepad-%p", controller]
				 contextString:nil
						plugin:self];
}

-(void)controllerDisconnected:(NSNotification *)note {
	GCController *controller = note.object;
	NSString *name = controller.vendorName ?: NSLocalizedString(@"Game Controller", @"");

	[delegate notifyWithName:@"GamepadDisconnected"
						 title:NSLocalizedString(@"Game Controller Disconnected", @"")
					   description:name
						  icon:[self iconData]
			  identifierString:[NSString stringWithFormat:@"HWGrowlGamepad-%p", controller]
				 contextString:nil
						plugin:self];
}

#pragma mark Icon (hand-drawn outline, transparent background — same convention as Audio/Camera Monitor)

+(NSColor *)accentColor {
	// Remaining unclaimed colors after Bluetooth=blue-indigo, Network=cyan, Thunderbolt=yellow,
	// Thermal=red, Power=green, Audio=orange, Camera=purple — pink is distinct from all of them.
	return [NSColor systemPinkColor];
}

// Uses SF Symbol's own "gamecontroller" glyph (Apple's actual modern controller icon —
// wing-shaped body, D-pad, twin thumbsticks, face buttons) instead of a hand-drawn path —
// the hand-drawn rounded-rect-plus-circles version read as noticeably more dated/generic
// than Apple's design once compared side by side.
-(NSImage *)gamepadIcon {
	NSImage *base = [NSImage imageWithSystemSymbolName:@"gamecontroller" accessibilityDescription:nil];
	NSImageSymbolConfiguration *sizeConfig = [NSImageSymbolConfiguration configurationWithPointSize:96 weight:NSFontWeightMedium];
	NSImageSymbolConfiguration *colorConfig = [NSImageSymbolConfiguration configurationWithHierarchicalColor:[HWGrowlGamepadMonitor accentColor]];
	// Configs must be MERGED before applying — calling -imageWithSymbolConfiguration: twice
	// in sequence does NOT compose them; the second call resets to the original symbol's
	// default (tiny, ~22×14pt) size, discarding the first call's size config entirely. That
	// was the bug behind the icon rendering almost invisibly small in the sidebar.
	NSImageSymbolConfiguration *combined = [sizeConfig configurationByApplyingConfiguration:colorConfig];
	base = [base imageWithSymbolConfiguration:combined];

	NSSize canvasSize = NSMakeSize(128, 128);
	NSImage *image = [NSImage imageWithSize:canvasSize flipped:NO drawingHandler:^BOOL(NSRect rect) {
		NSSize glyphSize = base.size;
		// Fit within the canvas with a small margin, preserving aspect ratio — the raw
		// glyph size from a 96pt point-size config isn't guaranteed to match the 128×128
		// canvas proportions on its own.
		CGFloat scale = MIN(rect.size.width / glyphSize.width, rect.size.height / glyphSize.height) * 1.15;
		NSSize drawSize = NSMakeSize(glyphSize.width * scale, glyphSize.height * scale);
		NSRect glyphRect = NSMakeRect(NSMidX(rect) - drawSize.width / 2.0, NSMidY(rect) - drawSize.height / 2.0, drawSize.width, drawSize.height);
		[base drawInRect:glyphRect fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1.0];
		return YES;
	}];
	return image;
}

-(NSData *)iconData {
	return [[self gamepadIcon] TIFFRepresentation];
}

#pragma mark HWGrowlPluginProtocol

-(NSString*)pluginDisplayName {
	return NSLocalizedString(@"Gamepad Monitor", @"");
}
-(NSImage*)preferenceIcon {
	static NSImage *_icon = nil;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		_icon = [self gamepadIcon];
	});
	return _icon;
}

-(IBAction)fieldToggleChanged:(NSButton*)sender {
	NSString *key = sender.identifier;
	if (!key) return;
	[[NSUserDefaults standardUserDefaults] setBool:(sender.state == NSControlStateValueOn) forKey:key];
}

-(NSButton *)checkboxWithKey:(NSString *)key title:(NSString *)title defaultOn:(BOOL)defaultOn {
	NSButton *box = [NSButton checkboxWithTitle:title target:self action:@selector(fieldToggleChanged:)];
	box.identifier = key;
	box.state = HWGGamepadBoolForKey(key, defaultOn) ? NSControlStateValueOn : NSControlStateValueOff;
	box.translatesAutoresizingMaskIntoConstraints = NO;
	return box;
}

-(NSView*)preferencePane {
	if (prefsView) return prefsView;

	NSView *v = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 460, 160)];

	NSTextField *header = [NSTextField labelWithString:NSLocalizedString(@"Notification fields", @"")];
	header.font = [NSFont boldSystemFontOfSize:12];
	header.textColor = [NSColor secondaryLabelColor];
	header.translatesAutoresizingMaskIntoConstraints = NO;

	NSArray<NSButton*> *rows = @[
		[self checkboxWithKey:HWG_GAMEPAD_SHOW_CATEGORY_KEY     title:NSLocalizedString(@"Controller type (DualSense/Xbox/MFi/etc.)", @"") defaultOn:YES],
		[self checkboxWithKey:HWG_GAMEPAD_SHOW_PLAYER_INDEX_KEY title:NSLocalizedString(@"Player index", @"") defaultOn:YES],
		[self checkboxWithKey:HWG_GAMEPAD_SHOW_BATTERY_KEY      title:NSLocalizedString(@"Battery level", @"") defaultOn:YES],
	];

	[v addSubview:header];
	[NSLayoutConstraint activateConstraints:@[
		[header.topAnchor     constraintEqualToAnchor:v.topAnchor constant:16],
		[header.leadingAnchor  constraintEqualToAnchor:v.leadingAnchor constant:16],
	]];
	NSView *previous = header;
	for (NSButton *row in rows) {
		[v addSubview:row];
		[NSLayoutConstraint activateConstraints:@[
			[row.topAnchor     constraintEqualToAnchor:previous.bottomAnchor constant:10],
			[row.leadingAnchor  constraintEqualToAnchor:v.leadingAnchor constant:16],
			[row.trailingAnchor constraintLessThanOrEqualToAnchor:v.trailingAnchor constant:-16],
		]];
		previous = row;
	}

	prefsView = v;
	return prefsView;
}

#pragma mark HWGrowlPluginNotifierProtocol

-(NSArray*)noteNames {
	return @[@"GamepadConnected", @"GamepadDisconnected"];
}
-(NSDictionary*)localizedNames {
	return @{
		@"GamepadConnected": NSLocalizedString(@"Game Controller Connected", @""),
		@"GamepadDisconnected": NSLocalizedString(@"Game Controller Disconnected", @""),
	};
}
-(NSDictionary*)noteDescriptions {
	return @{
		@"GamepadConnected": NSLocalizedString(@"Sent when a game controller is connected, with type/player/battery detail — even if USB/Bluetooth Monitor also reported the same connect event generically", @""),
		@"GamepadDisconnected": NSLocalizedString(@"Sent when a game controller is disconnected", @""),
	};
}
-(NSArray*)defaultNotifications {
	return [self noteNames];
}

@end
