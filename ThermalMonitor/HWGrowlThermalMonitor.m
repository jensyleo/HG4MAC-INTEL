//
//  HWGrowlThermalMonitor.m
//  HardwareGrowler
//

// compile with ARC: -fobjc-arc
#import "HWGrowlThermalMonitor.h"

// F34 candidate #3: per-level configurable thermal-state notifications. Each key gates
// whether ENTERING that level (in either direction) fires a notification. All levels are
// tracked internally regardless of these toggles, so turning one on later doesn't miss the
// next real transition. Serious/Critical default ON (actionable); Nominal/Fair default OFF
// (avoid noise on "back to normal").
#define HWG_THERMAL_NOTIFY_NOMINAL_KEY  @"HWGThermalNotifyNominal"
#define HWG_THERMAL_NOTIFY_FAIR_KEY     @"HWGThermalNotifyFair"
#define HWG_THERMAL_NOTIFY_SERIOUS_KEY  @"HWGThermalNotifySerious"
#define HWG_THERMAL_NOTIFY_CRITICAL_KEY @"HWGThermalNotifyCritical"

static BOOL HWGThermalBoolForKey(NSString *key, BOOL def) {
	id stored = [[NSUserDefaults standardUserDefaults] objectForKey:key];
	return stored ? [stored boolValue] : def;
}

@interface HWGrowlThermalMonitor ()

@property (nonatomic, weak) id<HWGrowlPluginControllerProtocol> delegate;
@property (nonatomic, assign) NSProcessInfoThermalState lastReportedThermalState;
@property (nonatomic, strong) NSView *prefsView;
// "Simulate Test Notification" popups — see -simulateThermalTransitionForTesting:.
@property (nonatomic, strong) NSPopUpButton *simulateFromPopup;
@property (nonatomic, strong) NSPopUpButton *simulateToPopup;

@end

@implementation HWGrowlThermalMonitor

@synthesize delegate;
@synthesize lastReportedThermalState;
@synthesize prefsView;

-(id)init {
	self = [super init];
	if (self) {
		// Baseline silently at launch — like WiFi/USB/Bluetooth — so the first real
		// transition after this point is the first thing ever notified.
		lastReportedThermalState = [NSProcessInfo processInfo].thermalState;
		[[NSNotificationCenter defaultCenter] addObserver:self
												  selector:@selector(thermalStateChanged:)
													  name:NSProcessInfoThermalStateDidChangeNotification
													object:nil];
	}
	return self;
}

-(void)dealloc {
	[[NSNotificationCenter defaultCenter] removeObserver:self];
}

// Description phrase ONLY (no level name prefix) — the level name is shown separately via
// -thermalStateShortLabel: in the "old → new" arrow, so this shouldn't repeat it (that used to
// read as "Critical → Nominal (Nominal — running normally)" — the duplicated "Nominal" was
// confusing noise).
-(NSString *)thermalStateLabel:(NSProcessInfoThermalState)state {
	switch (state) {
		case NSProcessInfoThermalStateNominal:  return NSLocalizedString(@"running normally", @"");
		case NSProcessInfoThermalStateFair:      return NSLocalizedString(@"slightly elevated", @"");
		case NSProcessInfoThermalStateSerious:   return NSLocalizedString(@"performance reduced", @"");
		case NSProcessInfoThermalStateCritical:  return NSLocalizedString(@"performance significantly reduced", @"");
		default: return NSLocalizedString(@"unknown", @"");
	}
}

// Short word only (Nominal/Fair/Serious/Critical), used for the "old → new" arrow line —
// the long descriptive phrase from -thermalStateLabel: (e.g. "performance significantly
// reduced") describes what that severity level MEANS, which only makes sense attached to the
// CURRENT/new state; showing it for the OLD state too reads as if the old explanation still
// applies after the transition (e.g. "Critical — performance significantly reduced →
// Nominal" makes it look like performance is STILL reduced, right before the arrow says
// otherwise).
-(NSString *)thermalStateShortLabel:(NSProcessInfoThermalState)state {
	switch (state) {
		case NSProcessInfoThermalStateNominal:  return NSLocalizedString(@"Nominal", @"");
		case NSProcessInfoThermalStateFair:      return NSLocalizedString(@"Fair", @"");
		case NSProcessInfoThermalStateSerious:   return NSLocalizedString(@"Serious", @"");
		case NSProcessInfoThermalStateCritical:  return NSLocalizedString(@"Critical", @"");
		default: return NSLocalizedString(@"Unknown", @"");
	}
}

-(NSString *)userDefaultsKeyForThermalState:(NSProcessInfoThermalState)state {
	switch (state) {
		case NSProcessInfoThermalStateNominal:  return HWG_THERMAL_NOTIFY_NOMINAL_KEY;
		case NSProcessInfoThermalStateFair:      return HWG_THERMAL_NOTIFY_FAIR_KEY;
		case NSProcessInfoThermalStateSerious:   return HWG_THERMAL_NOTIFY_SERIOUS_KEY;
		case NSProcessInfoThermalStateCritical:  return HWG_THERMAL_NOTIFY_CRITICAL_KEY;
		default: return nil;
	}
}

-(BOOL)defaultNotifyForThermalState:(NSProcessInfoThermalState)state {
	return (state == NSProcessInfoThermalStateSerious || state == NSProcessInfoThermalStateCritical);
}

// Dedicated icon per level: a thermometer with a fill level proportional to severity
// (Nominal ~18% .. Critical 100%, matching Power Monitor's charge-level ramp convention),
// plus a badge in the top-right corner that escalates in meaning: Nominal = green
// checkmark ("all good"), Fair = blue dash ("steady, still normal"), Serious = the same
// warning triangle used for "Unstable device" bounce alerts, Critical = the same
// radioactive icon used for "Disk Not Readable".
-(NSData *)iconDataForThermalState:(NSProcessInfoThermalState)state {
	NSString *name;
	switch (state) {
		case NSProcessInfoThermalStateNominal:  name = @"Thermal-Nominal";  break;
		case NSProcessInfoThermalStateFair:      name = @"Thermal-Fair";     break;
		case NSProcessInfoThermalStateSerious:   name = @"Thermal-Serious";  break;
		case NSProcessInfoThermalStateCritical:  name = @"Thermal-Critical"; break;
		default: return nil;
	}
	return [[NSImage imageNamed:name] TIFFRepresentation];
}

-(void)thermalStateChanged:(NSNotification *)note {
	NSProcessInfoThermalState state = [NSProcessInfo processInfo].thermalState;
	if (state == lastReportedThermalState) return;
	NSProcessInfoThermalState previousState = lastReportedThermalState;
	self.lastReportedThermalState = state;

	NSString *key = [self userDefaultsKeyForThermalState:state];
	BOOL shouldNotify = key ? HWGThermalBoolForKey(key, [self defaultNotifyForThermalState:state]) : NO;
	if (!shouldNotify) return;

	// "old → new" plus an explicit improving/worsening tag — see
	// -descriptionForThermalTransitionFrom:to:.
	NSString *description = [self descriptionForThermalTransitionFrom:previousState to:state];

	[delegate notifyWithName:@"ThermalStateChanged"
						 title:NSLocalizedString(@"Thermal State Changed", @"")
				   description:description
						  icon:[self iconDataForThermalState:state]
			  identifierString:@"HWGrowlThermalState"
				 contextString:nil
						plugin:self];
}

// Builds the "State:\told → new" line PLUS an explicit "(Cooling down)"/"(Warming up)" tag.
// Uses SHORT labels (just the word) for the "old → new" arrow, and appends the full
// descriptive phrase (from -thermalStateLabel:) only for the NEW state — that phrase explains
// what the severity level MEANS, which only makes sense for the state you're actually in now;
// attaching it to the OLD state too would make e.g. "Critical — performance significantly
// reduced → Nominal" read as if performance were STILL reduced, right before the arrow says
// otherwise. No improving/worsening tag for a same-level from==to (shouldn't happen via the
// real observer, but the simulate-testing path allows selecting equal states).
-(NSString *)descriptionForThermalTransitionFrom:(NSProcessInfoThermalState)fromState to:(NSProcessInfoThermalState)toState {
	NSString *line = [NSString stringWithFormat:NSLocalizedString(@"State:\t%@ → %@ — %@", @""),
		[self thermalStateShortLabel:fromState], [self thermalStateShortLabel:toState], [self thermalStateLabel:toState]];
	if (toState < fromState) {
		return [line stringByAppendingFormat:@"\n%@", NSLocalizedString(@"↓ Cooling down (improving)", @"")];
	} else if (toState > fromState) {
		return [line stringByAppendingFormat:@"\n%@", NSLocalizedString(@"↑ Warming up (worsening)", @"")];
	}
	return line;
}

// "Simulate Test Notification" (Preferences > Thermal Monitor): lets a user preview any
// from→to state combination on demand, without waiting for the Mac to actually throttle —
// genuinely useful on machines that rarely (or never, under light/moderate load — confirmed
// via `pmset -g therm` and NSProcessInfo.thermalState on an M4 under sustained CPU stress)
// reach Serious/Critical, so the notification/icon for those levels can still be seen and
// verified without forcing real thermal stress. Does NOT touch lastReportedThermalState, so
// it can't desync the real tracking from the actual OS-reported state, and does NOT check the
// per-level F33 checkbox (simulating is opt-in by definition — always fires so every
// combination, including ones disabled by default like Nominal/Fair, can still be previewed).
-(IBAction)simulateThermalTransitionForTesting:(NSButton*)sender {
	NSProcessInfoThermalState fromState = (NSProcessInfoThermalState)[self.simulateFromPopup indexOfSelectedItem];
	NSProcessInfoThermalState toState   = (NSProcessInfoThermalState)[self.simulateToPopup indexOfSelectedItem];
	NSString *description = [self descriptionForThermalTransitionFrom:fromState to:toState];
	[delegate notifyWithName:@"ThermalStateChanged"
						 title:NSLocalizedString(@"Thermal State Changed", @"")
					   description:description
						  icon:[self iconDataForThermalState:toState]
			  identifierString:@"HWGrowlThermalState"
				 contextString:nil
						plugin:self];
}

#pragma mark HWGrowlPluginProtocol

-(NSString*)pluginDisplayName {
	return NSLocalizedString(@"Thermal Monitor", @"");
}
-(NSImage*)preferenceIcon {
	return [NSImage imageNamed:@"HWGPrefsThermal"];
}

-(IBAction)fieldToggleChanged:(NSButton*)sender {
	NSString *key = sender.identifier;
	if (!key) return;
	[[NSUserDefaults standardUserDefaults] setBool:(sender.state == NSControlStateValueOn) forKey:key];
}

-(NSButton *)checkboxWithKey:(NSString *)key title:(NSString *)title defaultOn:(BOOL)defaultOn {
	NSButton *box = [NSButton checkboxWithTitle:title target:self action:@selector(fieldToggleChanged:)];
	box.identifier = key;
	box.state = HWGThermalBoolForKey(key, defaultOn) ? NSControlStateValueOn : NSControlStateValueOff;
	box.translatesAutoresizingMaskIntoConstraints = NO;
	return box;
}

-(NSView*)preferencePane {
	if (prefsView) return prefsView;

	NSView *v = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 420, 300)];

	NSTextField *header = [NSTextField labelWithString:NSLocalizedString(@"Notify when entering:", @"")];
	header.font = [NSFont boldSystemFontOfSize:12];
	header.textColor = [NSColor secondaryLabelColor];
	header.translatesAutoresizingMaskIntoConstraints = NO;

	NSArray<NSButton*> *rows = @[
		[self checkboxWithKey:HWG_THERMAL_NOTIFY_NOMINAL_KEY  title:NSLocalizedString(@"Nominal (back to normal)", @"") defaultOn:NO],
		[self checkboxWithKey:HWG_THERMAL_NOTIFY_FAIR_KEY     title:NSLocalizedString(@"Fair (slightly elevated)", @"") defaultOn:NO],
		[self checkboxWithKey:HWG_THERMAL_NOTIFY_SERIOUS_KEY  title:NSLocalizedString(@"Serious (throttling active)", @"") defaultOn:YES],
		[self checkboxWithKey:HWG_THERMAL_NOTIFY_CRITICAL_KEY title:NSLocalizedString(@"Critical (severe throttling)", @"") defaultOn:YES],
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
			[row.heightAnchor   constraintEqualToConstant:24],
		]];
		previous = row;
	}

	// "Simulate Test Notification" controls — see -simulateThermalTransitionForTesting:. Two
	// popups (From/To) instead of a single fixed button so EVERY 4×4 state combination can be
	// previewed (including same-level no-ops and "skip a level" jumps like Nominal→Critical),
	// not just one hardcoded transition — useful for any user who wants to see what a given
	// notification/icon looks like without waiting for (or being able to force) real thermal
	// throttling.
	NSArray<NSString *> *stateNames = @[
		NSLocalizedString(@"Nominal", @""), NSLocalizedString(@"Fair", @""),
		NSLocalizedString(@"Serious", @""), NSLocalizedString(@"Critical", @"")];

	NSTextField *simHeader = [NSTextField labelWithString:NSLocalizedString(@"Simulate Test Notification", @"")];
	simHeader.font = [NSFont boldSystemFontOfSize:12];
	simHeader.textColor = [NSColor secondaryLabelColor];
	simHeader.translatesAutoresizingMaskIntoConstraints = NO;
	[v addSubview:simHeader];
	[NSLayoutConstraint activateConstraints:@[
		[simHeader.topAnchor     constraintEqualToAnchor:previous.bottomAnchor constant:16],
		[simHeader.leadingAnchor  constraintEqualToAnchor:v.leadingAnchor constant:16],
	]];

	NSTextField *fromLabel = [NSTextField labelWithString:NSLocalizedString(@"From:", @"")];
	fromLabel.translatesAutoresizingMaskIntoConstraints = NO;
	[v addSubview:fromLabel];
	[NSLayoutConstraint activateConstraints:@[
		[fromLabel.topAnchor     constraintEqualToAnchor:simHeader.bottomAnchor constant:10],
		[fromLabel.leadingAnchor  constraintEqualToAnchor:v.leadingAnchor constant:16],
	]];

	self.simulateFromPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(16 + 44, 0, 100, 24) pullsDown:NO];
	self.simulateFromPopup.translatesAutoresizingMaskIntoConstraints = NO;
	[self.simulateFromPopup addItemsWithTitles:stateNames];
	[self.simulateFromPopup selectItemAtIndex:NSProcessInfoThermalStateNominal];
	[v addSubview:self.simulateFromPopup];
	[NSLayoutConstraint activateConstraints:@[
		[self.simulateFromPopup.centerYAnchor constraintEqualToAnchor:fromLabel.centerYAnchor],
		[self.simulateFromPopup.leadingAnchor  constraintEqualToAnchor:fromLabel.trailingAnchor constant:8],
	]];

	NSTextField *toLabel = [NSTextField labelWithString:NSLocalizedString(@"To:", @"")];
	toLabel.translatesAutoresizingMaskIntoConstraints = NO;
	[v addSubview:toLabel];
	[NSLayoutConstraint activateConstraints:@[
		[toLabel.centerYAnchor constraintEqualToAnchor:fromLabel.centerYAnchor],
		[toLabel.leadingAnchor  constraintEqualToAnchor:self.simulateFromPopup.trailingAnchor constant:16],
	]];

	self.simulateToPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 0, 100, 24) pullsDown:NO];
	self.simulateToPopup.translatesAutoresizingMaskIntoConstraints = NO;
	[self.simulateToPopup addItemsWithTitles:stateNames];
	[self.simulateToPopup selectItemAtIndex:NSProcessInfoThermalStateSerious];
	[v addSubview:self.simulateToPopup];
	[NSLayoutConstraint activateConstraints:@[
		[self.simulateToPopup.centerYAnchor constraintEqualToAnchor:fromLabel.centerYAnchor],
		[self.simulateToPopup.leadingAnchor  constraintEqualToAnchor:toLabel.trailingAnchor constant:8],
	]];

	NSButton *testButton = [NSButton buttonWithTitle:NSLocalizedString(@"Simulate", @"")
	                                            target:self action:@selector(simulateThermalTransitionForTesting:)];
	testButton.translatesAutoresizingMaskIntoConstraints = NO;
	[v addSubview:testButton];
	[NSLayoutConstraint activateConstraints:@[
		[testButton.topAnchor     constraintEqualToAnchor:fromLabel.bottomAnchor constant:12],
		[testButton.leadingAnchor  constraintEqualToAnchor:v.leadingAnchor constant:16],
	]];

	prefsView = v;
	return prefsView;
}

#pragma mark HWGrowlPluginNotifierProtocol

-(NSArray*)noteNames {
	return [NSArray arrayWithObject:@"ThermalStateChanged"];
}
-(NSDictionary*)localizedNames {
	return [NSDictionary dictionaryWithObject:NSLocalizedString(@"Thermal State Changed", @"") forKey:@"ThermalStateChanged"];
}
-(NSDictionary*)noteDescriptions {
	return [NSDictionary dictionaryWithObject:NSLocalizedString(@"Sent when the Mac's thermal state changes (throttling level)", @"") forKey:@"ThermalStateChanged"];
}
-(NSArray*)defaultNotifications {
	return [NSArray arrayWithObject:@"ThermalStateChanged"];
}

@end
