//
//  HWGrowlDisplayMonitor.m
//  HardwareGrowler
//

// compile with ARC: -fobjc-arc
#import "HWGrowlDisplayMonitor.h"
#import <CoreGraphics/CoreGraphics.h>
#import <OSLog/OSLog.h>

// Detection is driven by CGDisplayRegisterReconfigurationCallback + CGGetOnlineDisplayList,
// NOT NSScreen/NSApplicationDidChangeScreenParametersNotification. NSScreen only exposes
// displays AppKit can address a window to — a display connected while macOS puts it in
// Mirror mode does NOT get its own NSScreen entry (confirmed empirically: the notification
// fired, but [NSScreen screens] never changed size). CGGetOnlineDisplayList is a Quartz-level
// "is this display physically connected" list that includes mirrored displays, so it's the
// only reliable way to satisfy the F19 requirement of detecting a display "via any connection
// method" regardless of Mirror vs Extended arrangement.

// F33: individually configurable fields in the Display connect notification's extra info —
// same pattern as USB/Network/Power Monitor. All default to YES.
#define HWG_DISPLAY_SHOW_RESOLUTION_KEY @"HWGDisplayShowResolution"
#define HWG_DISPLAY_SHOW_REFRESH_KEY    @"HWGDisplayShowRefreshRate"
#define HWG_DISPLAY_SHOW_ROLE_KEY       @"HWGDisplayShowRole"
#define HWG_DISPLAY_SHOW_ROTATION_KEY   @"HWGDisplayShowRotation"

// F34: notify when an already-connected display changes resolution or refresh rate (e.g.
// user picks a different resolution in System Settings, or a TV renegotiates a different
// refresh rate). Off the connect/disconnect path entirely — driven by comparing mode
// signatures across reconfiguration callbacks for displays neither added nor removed.
#define HWG_DISPLAY_NOTIFY_MODE_CHANGE_KEY @"HWGDisplayNotifyModeChange"

// F34: notify when an already-connected display's role changes (becomes/stops being Main,
// or Mirroring starts/stops between two displays that were both already online) — same
// comparison approach as the mode-change detection above, applied to CGDisplayIsMain/
// CGDisplayIsInMirrorSet instead of CGDisplayCopyDisplayMode.
#define HWG_DISPLAY_NOTIFY_ROLE_CHANGE_KEY @"HWGDisplayNotifyRoleChange"

// EXPERIMENTAL, off by default — see the long comment on -pollForPhysicalVideoLink and the
// README "Known limitations" entry before touching this. Not a supported feature; a
// best-effort heuristic that scrapes free-form kernel log text with no stability contract.
#define HWG_DISPLAY_EARLY_DETECTION_KEY          @"HWGDisplayEarlyDetectionEnabled"
#define HWG_DISPLAY_EARLY_DETECTION_INTERVAL_KEY @"HWGDisplayEarlyDetectionIntervalSeconds"

static BOOL HWGDisplayBoolForKey(NSString *key, BOOL def) {
	id stored = [[NSUserDefaults standardUserDefaults] objectForKey:key];
	return stored ? [stored boolValue] : def;
}

static NSInteger HWGDisplayIntForKey(NSString *key, NSInteger def) {
	id stored = [[NSUserDefaults standardUserDefaults] objectForKey:key];
	return stored ? [stored integerValue] : def;
}

@interface HWGrowlDisplayMonitor ()

@property (nonatomic, weak) id<HWGrowlPluginControllerProtocol> delegate;
@property (nonatomic, strong) NSView *prefsView;

// Snapshot of currently-online display IDs (NSNumber-wrapped CGDirectDisplayID), as of the
// last time we processed a reconfiguration callback. Diffed against the new snapshot every
// time to figure out what connected/disconnected.
@property (nonatomic, strong) NSMutableSet<NSNumber *> *knownDisplayIDs;
// id -> last-known human readable name, so a disconnect can still be reported with a
// sensible label even after the display is gone.
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSString *> *displayNames;
// id -> last-known "WxH@Hz" string for a display that's still online, so a later
// reconfiguration callback can tell a genuine resolution/refresh-rate change (same
// CGDirectDisplayID, different mode) apart from a no-op callback (e.g. Dock
// resize/wallpaper change also triggers this same callback).
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSString *> *displayModeSignatures;
// id -> last-known role string (Main/Extended/Mirrored) for a display that's still online,
// so a role change (e.g. dragging the menu bar to a different display in System Settings, or
// starting/stopping Mirroring between two already-connected displays) can be detected without
// a connect/disconnect having happened.
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSString *> *displayRoleSignatures;

// Experimental early-detection polling state (see -pollForPhysicalVideoLink).
@property (nonatomic, strong) NSTimer *earlyDetectionTimer;
@property (nonatomic, strong) NSDate *earlyDetectionLastPollDate;
@property (nonatomic, strong) NSTextField *earlyDetectionIntervalLabel;

-(void)displayConfigurationChanged;

@end

static void HWGDisplayReconfigurationCallback(CGDirectDisplayID display, CGDisplayChangeSummaryFlags flags, void *userInfo) {
	(void)display; (void)flags; // unused — every callback triggers a full re-diff regardless of which display/flag fired
	HWGrowlDisplayMonitor *monitor = (__bridge HWGrowlDisplayMonitor *)userInfo;
	[monitor displayConfigurationChanged];
}

@implementation HWGrowlDisplayMonitor

@synthesize delegate;
@synthesize prefsView;
@synthesize knownDisplayIDs;
@synthesize displayNames;
@synthesize displayModeSignatures;
@synthesize displayRoleSignatures;
@synthesize earlyDetectionTimer;
@synthesize earlyDetectionLastPollDate;
@synthesize earlyDetectionIntervalLabel;

-(id)init {
	self = [super init];
	if (self) {
		knownDisplayIDs = [NSMutableSet set];
		displayNames = [NSMutableDictionary dictionary];
		displayModeSignatures = [NSMutableDictionary dictionary];
		displayRoleSignatures = [NSMutableDictionary dictionary];

		// Baseline silently at launch — like Thermal/USB/WiFi — so the first real
		// connect/disconnect after this point is the first thing ever notified.
		[self snapshotOnlineDisplaysUpdatingKnownState:YES];

		CGDisplayRegisterReconfigurationCallback(HWGDisplayReconfigurationCallback, (__bridge void *)self);

		[self updateEarlyDetectionTimerState];
	}
	return self;
}

-(void)dealloc {
	CGDisplayRemoveReconfigurationCallback(HWGDisplayReconfigurationCallback, (__bridge void *)self);
	[earlyDetectionTimer invalidate];
}

#pragma mark Experimental early physical-link detection (off by default)

// EXPERIMENTAL / off by default. Background: CGGetOnlineDisplayList/CGDisplayRegisterReconfigurationCallback
// only see a display once macOS has assigned it an arrangement (Extended or Mirror) — if the
// user dismisses macOS's own "how do you want to use this display" prompt without choosing,
// there is no CGDirectDisplayID yet and nothing is detectable through CoreGraphics. Investigated
// (2026-07-18) whether the earlier, physical-link-level event is reachable at all: the kernel
// itself logs it, under the DCPAVFamilyProxy/IOAVFamily subsystems (Apple Silicon's Display
// Co-Processor driver) — a real HDMI/DisplayPort hotplug produces an
// AppleDCPDPTXRemoteHDCPAuthSessionProxy message sequence whose "ReceiverConnected" entry marks
// the moment the physical link/HDCP handshake completes, well before any CoreGraphics display
// object exists. Reading it is possible via the PUBLIC unified-logging API (OSLogStore, macOS
// 10.15+) with no special entitlement — confirmed by a standalone unprivileged test binary.
//
// This is deliberately NOT wired into the normal detection path, because:
//   1. It scrapes FREE-FORM kernel debug log text ("ReceiverConnected", "IOAVFamily",
//      "DCPAVFamilyProxy") with no documented, versioned API contract — Apple can change the
//      wording, the subsystem, or remove the logging entirely in any macOS update, silently.
//   2. OSLogStore has no public push/streaming callback — only a historical enumerator — so
//      catching this requires POLLING on a timer, each poll scanning every kernel log line
//      since the last poll (tens of thousands of lines over a half-hour in normal use) just to
//      find the rare handful that match. That's real, continuous CPU/battery cost for a
//      cosmetic few-seconds-earlier heads-up.
//   3. Apple Silicon only (DCPAVFamilyProxy is the M-series Display Co-Processor proxy) — an
//      Intel Mac would see nothing from this path.
// See the matching "Known limitations" entry in README.md for the user-facing version of this.

-(void)updateEarlyDetectionTimerState {
	[earlyDetectionTimer invalidate];
	earlyDetectionTimer = nil;

	if (!HWGDisplayBoolForKey(HWG_DISPLAY_EARLY_DETECTION_KEY, NO)) return;

	// Only entries logged AFTER we start polling matter — no interest in replaying old hotplugs.
	earlyDetectionLastPollDate = [NSDate date];

	NSInteger seconds = HWGDisplayIntForKey(HWG_DISPLAY_EARLY_DETECTION_INTERVAL_KEY, 3);
	if (seconds < 1) seconds = 1;
	if (seconds > 10) seconds = 10;

	// Block-based timer with a weak capture — a target-based NSTimer (target:self) would
	// retain self strongly for as long as the timer exists, and since the timer itself is
	// also held strongly by earlyDetectionTimer, that's a self-retain cycle: -dealloc (and
	// the CGDisplayRemoveReconfigurationCallback cleanup within it) would never run for as
	// long as this experimental feature stays enabled.
	__weak typeof(self) weakSelf = self;
	earlyDetectionTimer = [NSTimer scheduledTimerWithTimeInterval:seconds repeats:YES block:^(NSTimer *timer) {
		[weakSelf pollForPhysicalVideoLink];
	}];
}

-(void)pollForPhysicalVideoLink {
	NSDate *pollStart = [NSDate date];
	NSDate *since = earlyDetectionLastPollDate ?: pollStart;
	earlyDetectionLastPollDate = pollStart;

	NSError *error = nil;
	OSLogStore *store = [OSLogStore localStoreAndReturnError:&error];
	if (!store) return; // best-effort: silently skip this poll rather than surface a broken feature

	OSLogPosition *position = [store positionWithDate:since];
	NSPredicate *predicate = [NSPredicate predicateWithFormat:@"process == %@", @"kernel"];
	OSLogEnumerator *enumerator = [store entriesEnumeratorWithOptions:0
															   position:position
															  predicate:predicate
																  error:&error];
	if (!enumerator) return;

	for (OSLogEntryLog *entry in enumerator) {
		if ([entry.composedMessage containsString:@"ReceiverConnected"]) {
			[delegate notifyWithName:@"DisplayLinkDetected"
								 title:NSLocalizedString(@"Video Link Detected (Experimental)", @"")
						   description:NSLocalizedString(@"A physical video link was detected before macOS assigned the display a role. Best-effort signal from internal kernel log text — may be inaccurate or stop working after a macOS update.", @"")
								  icon:[self iconDataForConnected:YES]
					  identifierString:@"HWGrowlDisplayEarlyLink"
						 contextString:nil
								plugin:self];
			break; // one heads-up per poll is enough — the real DisplayConnected note follows shortly
		}
	}
}

// CGDirectDisplayID -> best-effort human-readable name, via a matching NSScreen if one
// exists (e.g. the display is Extended/addressable); nil if none matches (e.g. a mirrored
// secondary display, which has no NSScreen of its own).
-(NSString *)nameForOnlineDisplayID:(CGDirectDisplayID)displayID {
	for (NSScreen *screen in [NSScreen screens]) {
		NSNumber *screenNumber = [[screen deviceDescription] objectForKey:@"NSScreenNumber"];
		if ([screenNumber unsignedIntValue] == displayID) {
			if ([screen respondsToSelector:@selector(localizedName)]) {
				NSString *name = [screen localizedName];
				if (name.length) return name;
			}
			break;
		}
	}
	return nil;
}

// Builds the extra info lines (resolution/refresh rate/role) for a just-connected display,
// all via public CoreGraphics/AppKit APIs — nil if nothing usable was found. Only called on
// connect: by the time a display is removed, CGDisplayCopyDisplayMode and friends no longer
// return anything useful for that (now offline) CGDirectDisplayID.
-(NSString *)extraInfoForDisplayID:(CGDirectDisplayID)displayID {
	NSMutableArray<NSString *> *lines = [NSMutableArray array];

	NSScreen *matchingScreen = nil;
	for (NSScreen *screen in [NSScreen screens]) {
		NSNumber *screenNumber = [[screen deviceDescription] objectForKey:@"NSScreenNumber"];
		if ([screenNumber unsignedIntValue] == displayID) { matchingScreen = screen; break; }
	}

	BOOL wantsResolution = HWGDisplayBoolForKey(HWG_DISPLAY_SHOW_RESOLUTION_KEY, YES);
	BOOL wantsRefresh    = HWGDisplayBoolForKey(HWG_DISPLAY_SHOW_REFRESH_KEY, YES);

	// Fetch the mode at most once — both the no-NSScreen resolution fallback and the refresh
	// rate need it, and CGDisplayCopyDisplayMode is not free to call twice per notification.
	CGDisplayModeRef mode = NULL;
	if ((wantsResolution && !matchingScreen) || wantsRefresh) {
		mode = CGDisplayCopyDisplayMode(displayID);
	}

	if (wantsResolution) {
		NSString *resolution = nil;
		if (matchingScreen) {
			NSSize points = matchingScreen.frame.size;
			CGFloat scale = matchingScreen.backingScaleFactor;
			if (scale > 1) {
				resolution = [NSString stringWithFormat:@"%d×%d (Retina %dx)", (int)points.width, (int)points.height, (int)scale];
			} else {
				resolution = [NSString stringWithFormat:@"%d×%d", (int)points.width, (int)points.height];
			}
		} else if (mode) {
			// No addressable NSScreen (e.g. a mirrored secondary display) — fall back to the
			// raw pixel dimensions of the display's current mode.
			resolution = [NSString stringWithFormat:@"%zu×%zu", CGDisplayModeGetPixelWidth(mode), CGDisplayModeGetPixelHeight(mode)];
		}
		if (resolution) [lines addObject:[NSString stringWithFormat:NSLocalizedString(@"Resolution:\t%@", @""), resolution]];
	}

	if (wantsRefresh && mode) {
		double refreshRate = CGDisplayModeGetRefreshRate(mode);
		if (refreshRate > 0) {
			[lines addObject:[NSString stringWithFormat:NSLocalizedString(@"Refresh rate:\t%.0f Hz", @""), refreshRate]];
		}
	}

	if (mode) CGDisplayModeRelease(mode);

	if (HWGDisplayBoolForKey(HWG_DISPLAY_SHOW_ROTATION_KEY, YES)) {
		double rotation = CGDisplayRotation(displayID);   // 0.0 if the display/GPU doesn't support rotation
		if (rotation != 0.0) {
			[lines addObject:[NSString stringWithFormat:NSLocalizedString(@"Rotation:\t%.0f°", @""), rotation]];
		}
	}

	if (HWGDisplayBoolForKey(HWG_DISPLAY_SHOW_ROLE_KEY, YES)) {
		[lines addObject:[NSString stringWithFormat:NSLocalizedString(@"Role:\t%@", @""), [self roleForDisplayID:displayID]]];
	}

	return [lines count] ? [lines componentsJoinedByString:@"\n"] : nil;
}

-(NSString *)roleForDisplayID:(CGDirectDisplayID)displayID {
	if (CGDisplayIsMain(displayID)) return NSLocalizedString(@"Main display", @"");
	if (CGDisplayIsInMirrorSet(displayID)) return NSLocalizedString(@"Mirrored", @"");
	return NSLocalizedString(@"Extended", @"");
}

// "WxH@Hz" for the display's current mode — used only to detect a genuine mode change
// across two reconfiguration callbacks for a display that stays online throughout (added
// and removed sets both exclude it). nil if the mode can't be read (display just went
// offline, etc.) so callers can treat "unknown" as "don't compare".
-(NSString *)modeSignatureForDisplayID:(CGDirectDisplayID)displayID {
	CGDisplayModeRef mode = CGDisplayCopyDisplayMode(displayID);
	if (!mode) return nil;
	// Rotation is folded into the same signature/diff as resolution+refresh rate (rather than
	// a third independent tracked signature like role) because on a physical rotation,
	// CGDisplayCopyDisplayMode's pixel W/H already swap to match (portrait vs landscape) —
	// it's really one mode-reconfiguration event, same as this class already treats
	// resolution+Hz as one event instead of two.
	NSString *signature = [NSString stringWithFormat:@"%zux%zu@%.2f@r%.0f",
		CGDisplayModeGetPixelWidth(mode), CGDisplayModeGetPixelHeight(mode), CGDisplayModeGetRefreshRate(mode), CGDisplayRotation(displayID)];
	CGDisplayModeRelease(mode);
	return signature;
}

// Parses a "WxH@Hz" signature (see -modeSignatureForDisplayID:) back into its pieces, so
// -describeModeChangeFromSignature:toSignature: can build "old → new" lines per field
// instead of just showing the new mode. Returns NO if the string doesn't match the format
// this class itself always produces (defensive only — should not happen in practice).
+(BOOL)parseModeSignature:(NSString *)signature width:(size_t *)width height:(size_t *)height hz:(double *)hz rotation:(double *)rotation {
	if (!signature) return NO;
	unsigned long w = 0, h = 0;
	double r = 0, rot = 0;
	if (sscanf([signature UTF8String], "%lux%lu@%lf@r%lf", &w, &h, &r, &rot) != 4) return NO;
	if (width) *width = w;
	if (height) *height = h;
	if (hz) *hz = r;
	if (rotation) *rotation = rot;
	return YES;
}

// Builds "Resolution:\told → new" / "Refresh rate:\told → new" / "Rotation:\told → new" lines
// (only the fields whose F33 checkbox is on and that actually changed), for the
// DisplayModeChanged notification — mirrors what DisplayRoleChanged already does for role,
// instead of only showing the new mode via -extraInfoForDisplayID: with no reference point
// for what it used to be.
-(NSString *)describeModeChangeFromSignature:(NSString *)oldSignature toSignature:(NSString *)newSignature {
	size_t oldW, oldH, newW, newH; double oldHz, newHz, oldRot, newRot;
	BOOL haveOld = [HWGrowlDisplayMonitor parseModeSignature:oldSignature width:&oldW height:&oldH hz:&oldHz rotation:&oldRot];
	BOOL haveNew = [HWGrowlDisplayMonitor parseModeSignature:newSignature width:&newW height:&newH hz:&newHz rotation:&newRot];
	if (!haveOld || !haveNew) return nil;

	NSMutableArray<NSString *> *lines = [NSMutableArray array];
	BOOL wantsResolution = HWGDisplayBoolForKey(HWG_DISPLAY_SHOW_RESOLUTION_KEY, YES);
	BOOL wantsRefresh    = HWGDisplayBoolForKey(HWG_DISPLAY_SHOW_REFRESH_KEY, YES);
	BOOL wantsRotation   = HWGDisplayBoolForKey(HWG_DISPLAY_SHOW_ROTATION_KEY, YES);

	if (wantsResolution && (oldW != newW || oldH != newH)) {
		[lines addObject:[NSString stringWithFormat:NSLocalizedString(@"Resolution:\t%zu×%zu → %zu×%zu", @""), oldW, oldH, newW, newH]];
	}
	if (wantsRefresh && oldHz != newHz) {
		[lines addObject:[NSString stringWithFormat:NSLocalizedString(@"Refresh rate:\t%.0f Hz → %.0f Hz", @""), oldHz, newHz]];
	}
	if (wantsRotation && oldRot != newRot) {
		[lines addObject:[NSString stringWithFormat:NSLocalizedString(@"Rotation:\t%.0f° → %.0f°", @""), oldRot, newRot]];
	}
	return [lines count] ? [lines componentsJoinedByString:@"\n"] : nil;
}

// Reads CGGetOnlineDisplayList, diffs it against knownDisplayIDs, fires connect/disconnect
// notifications for the difference, then updates the stored snapshot. When updatingKnownState
// is called from init (no prior snapshot to diff against), no notifications are fired — it
// only establishes the baseline.
-(void)snapshotOnlineDisplaysUpdatingKnownState:(BOOL)isBaselineOnly {
	uint32_t displayCount = 0;
	CGGetOnlineDisplayList(0, NULL, &displayCount);
	if (displayCount == 0) return;

	CGDirectDisplayID *onlineDisplays = calloc(displayCount, sizeof(CGDirectDisplayID));
	if (!onlineDisplays) return;
	CGGetOnlineDisplayList(displayCount, onlineDisplays, &displayCount);

	NSMutableSet<NSNumber *> *newIDs = [NSMutableSet set];
	for (uint32_t i = 0; i < displayCount; i++) {
		[newIDs addObject:@(onlineDisplays[i])];
	}
	free(onlineDisplays);

	if (isBaselineOnly) {
		knownDisplayIDs = newIDs;
		for (NSNumber *displayID in newIDs) {
			CGDirectDisplayID cgID = [displayID unsignedIntValue];
			NSString *name = [self nameForOnlineDisplayID:cgID];
			displayNames[displayID] = name ?: NSLocalizedString(@"External Display", @"");
			NSString *signature = [self modeSignatureForDisplayID:cgID];
			if (signature) displayModeSignatures[displayID] = signature;
			displayRoleSignatures[displayID] = [self roleForDisplayID:cgID];
		}
		return;
	}

	NSMutableSet<NSNumber *> *added = [newIDs mutableCopy];
	[added minusSet:knownDisplayIDs];

	NSMutableSet<NSNumber *> *removed = [knownDisplayIDs mutableCopy];
	[removed minusSet:newIDs];

	for (NSNumber *displayID in added) {
		CGDirectDisplayID cgID = [displayID unsignedIntValue];
		NSString *name = [self nameForOnlineDisplayID:cgID] ?: NSLocalizedString(@"External Display", @"");
		displayNames[displayID] = name;
		NSString *signature = [self modeSignatureForDisplayID:cgID];
		if (signature) displayModeSignatures[displayID] = signature;
		displayRoleSignatures[displayID] = [self roleForDisplayID:cgID];
		NSString *extraInfo = [self extraInfoForDisplayID:cgID];
		NSString *description = extraInfo ? [NSString stringWithFormat:@"%@\n%@", name, extraInfo] : name;
		[self notifyConnected:YES displayID:displayID description:description];
	}
	for (NSNumber *displayID in removed) {
		NSString *lastKnownName = displayNames[displayID] ?: NSLocalizedString(@"External Display", @"");
		[self notifyConnected:NO displayID:displayID description:lastKnownName];
		[displayNames removeObjectForKey:displayID];
		[displayModeSignatures removeObjectForKey:displayID];
		[displayRoleSignatures removeObjectForKey:displayID];
	}

	// Neither added nor removed: still online, but its mode may have changed (user picked a
	// different resolution/refresh rate in System Settings, a TV renegotiated a lower Hz,
	// etc.). Compare against the last known signature; only fire if we had one to compare
	// against (a nil old signature means we never captured it, e.g. a screen that just came
	// out of a state where CGDisplayCopyDisplayMode returned NULL — don't report a "change"
	// from unknown, only from a known prior mode). Deliberately a SEPARATE notification from
	// the role-change one below, even though both can fire from the same user action
	// (switching Extended→Mirror renegotiates a shared resolution AND changes role at once,
	// confirmed live) — they're two distinct facts (what resolution/Hz vs. what role), each
	// independently toggleable via its own F33 checkbox, and merging them would mean a user
	// who wants one but not the other can no longer get just one.
	if (HWGDisplayBoolForKey(HWG_DISPLAY_NOTIFY_MODE_CHANGE_KEY, YES)) {
		NSMutableSet<NSNumber *> *unchanged = [newIDs mutableCopy];
		[unchanged minusSet:added];
		[unchanged minusSet:removed];
		for (NSNumber *displayID in unchanged) {
			CGDirectDisplayID cgID = [displayID unsignedIntValue];
			NSString *newSignature = [self modeSignatureForDisplayID:cgID];
			if (!newSignature) continue;
			NSString *oldSignature = displayModeSignatures[displayID];
			if (oldSignature && ![oldSignature isEqualToString:newSignature]) {
				NSString *name = displayNames[displayID] ?: NSLocalizedString(@"External Display", @"");
				// "old → new" per field (falls back to the old flat "just show the new mode"
				// text if the signatures can't be parsed, which shouldn't happen in practice —
				// see -parseModeSignature:).
				NSString *extraInfo = [self describeModeChangeFromSignature:oldSignature toSignature:newSignature] ?: [self extraInfoForDisplayID:cgID];
				NSString *description = extraInfo ? [NSString stringWithFormat:@"%@\n%@", name, extraInfo] : name;
				[delegate notifyWithName:@"DisplayModeChanged"
									 title:NSLocalizedString(@"Display Mode Changed", @"")
							   description:description
									  icon:[self iconDataForConnected:YES]
						  identifierString:[NSString stringWithFormat:@"HWGrowlDisplayMode-%@", displayID]
							 contextString:nil
									plugin:self];
			}
			displayModeSignatures[displayID] = newSignature;
		}
	}

	// Same idea, for role instead of mode: catches the menu bar/Main display moving to a
	// different online display, or Mirroring starting/stopping between two displays that
	// were both already connected — none of which is a connect/disconnect event, but both
	// are visible via CGDisplayIsMain/CGDisplayIsInMirrorSet without needing the display to
	// have gone offline first.
	if (HWGDisplayBoolForKey(HWG_DISPLAY_NOTIFY_ROLE_CHANGE_KEY, YES)) {
		NSMutableSet<NSNumber *> *unchanged = [newIDs mutableCopy];
		[unchanged minusSet:added];
		[unchanged minusSet:removed];
		for (NSNumber *displayID in unchanged) {
			CGDirectDisplayID cgID = [displayID unsignedIntValue];
			NSString *newRole = [self roleForDisplayID:cgID];
			NSString *oldRole = displayRoleSignatures[displayID];
			if (oldRole && ![oldRole isEqualToString:newRole]) {
				NSString *name = displayNames[displayID] ?: NSLocalizedString(@"External Display", @"");
				NSString *description = [NSString stringWithFormat:@"%@\n%@",
					name, [NSString stringWithFormat:NSLocalizedString(@"Role:\t%@ → %@", @""), oldRole, newRole]];
				[delegate notifyWithName:@"DisplayRoleChanged"
									 title:NSLocalizedString(@"Display Role Changed", @"")
							   description:description
									  icon:[self iconDataForConnected:YES]
						  identifierString:[NSString stringWithFormat:@"HWGrowlDisplayRole-%@", displayID]
							 contextString:nil
									plugin:self];
			}
			displayRoleSignatures[displayID] = newRole;
		}
	}

	knownDisplayIDs = newIDs;
}

-(void)displayConfigurationChanged {
	// CGDisplayRegisterReconfigurationCallback fires on an arbitrary thread (not guaranteed
	// to be main) per Apple's docs. knownDisplayIDs/displayNames are also touched from the
	// main thread (prefs pane, the early-detection timer) with no synchronization, so hop to
	// main before mutating them to avoid a data race between the two.
	dispatch_async(dispatch_get_main_queue(), ^{
		// The callback fires once per display per reconfiguration event (and multiple times
		// for a single hotplug — begin/end phases). Re-diffing the full online list each time
		// is idempotent: once the sets match, added/removed come back empty and nothing fires
		// twice.
		[self snapshotOnlineDisplaysUpdatingKnownState:NO];
	});
}

-(NSData *)iconDataForConnected:(BOOL)connected {
	NSString *name = connected ? @"Display-On" : @"Display-Off";
	return [[NSImage imageNamed:name] TIFFRepresentation];
}

-(void)notifyConnected:(BOOL)connected displayID:(NSNumber *)displayID description:(NSString *)description {
	NSString *title = connected ? NSLocalizedString(@"Display Connected", @"") : NSLocalizedString(@"Display Disconnected", @"");
	NSString *identifierString = [NSString stringWithFormat:@"HWGrowlDisplay-%@", displayID];

	[delegate notifyWithName:connected ? @"DisplayConnected" : @"DisplayDisconnected"
						 title:title
				   description:description
						  icon:[self iconDataForConnected:connected]
			  identifierString:identifierString
				 contextString:nil
						plugin:self];
}

#pragma mark HWGrowlPluginProtocol

-(NSString*)pluginDisplayName {
	return NSLocalizedString(@"Display Monitor", @"");
}
-(NSImage*)preferenceIcon {
	static NSImage *_icon = nil;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		_icon = [NSImage imageNamed:@"HWGPrefsDisplay"];
	});
	return _icon;
}

// F33: single generic handler for every per-field visibility checkbox. Each checkbox's
// `identifier` carries the NSUserDefaults key it controls.
-(IBAction)fieldToggleChanged:(NSButton*)sender {
	NSString *key = sender.identifier;
	if (!key) return;
	[[NSUserDefaults standardUserDefaults] setBool:(sender.state == NSControlStateValueOn) forKey:key];
}

-(NSButton *)checkboxWithKey:(NSString *)key title:(NSString *)title defaultOn:(BOOL)defaultOn {
	NSButton *box = [NSButton checkboxWithTitle:title target:self action:@selector(fieldToggleChanged:)];
	box.identifier = key;
	box.state = HWGDisplayBoolForKey(key, defaultOn) ? NSControlStateValueOn : NSControlStateValueOff;
	box.translatesAutoresizingMaskIntoConstraints = NO;
	return box;
}

-(IBAction)earlyDetectionToggleChanged:(NSButton*)sender {
	[[NSUserDefaults standardUserDefaults] setBool:(sender.state == NSControlStateValueOn) forKey:HWG_DISPLAY_EARLY_DETECTION_KEY];
	[self updateEarlyDetectionTimerState];
}

-(IBAction)earlyDetectionIntervalChanged:(NSSlider*)sender {
	NSInteger seconds = sender.integerValue;
	[[NSUserDefaults standardUserDefaults] setInteger:seconds forKey:HWG_DISPLAY_EARLY_DETECTION_INTERVAL_KEY];
	self.earlyDetectionIntervalLabel.stringValue = [NSString stringWithFormat:NSLocalizedString(@"Poll every %ld s", @""), (long)seconds];
	[self updateEarlyDetectionTimerState];
}

-(NSView*)preferencePane {
	if (prefsView) return prefsView;

	NSView *v = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 460, 485)];

	NSTextField *header = [NSTextField labelWithString:NSLocalizedString(@"Notification fields", @"")];
	header.font = [NSFont boldSystemFontOfSize:12];
	header.textColor = [NSColor secondaryLabelColor];
	header.translatesAutoresizingMaskIntoConstraints = NO;

	NSArray<NSButton*> *rows = @[
		[self checkboxWithKey:HWG_DISPLAY_SHOW_RESOLUTION_KEY title:NSLocalizedString(@"Resolution", @"") defaultOn:YES],
		[self checkboxWithKey:HWG_DISPLAY_SHOW_REFRESH_KEY    title:NSLocalizedString(@"Refresh rate", @"") defaultOn:YES],
		[self checkboxWithKey:HWG_DISPLAY_SHOW_ROLE_KEY       title:NSLocalizedString(@"Role (Main/Extended/Mirrored)", @"") defaultOn:YES],
		[self checkboxWithKey:HWG_DISPLAY_SHOW_ROTATION_KEY   title:NSLocalizedString(@"Rotation", @"") defaultOn:YES],
		[self checkboxWithKey:HWG_DISPLAY_NOTIFY_MODE_CHANGE_KEY title:NSLocalizedString(@"Notify on resolution/refresh rate change", @"") defaultOn:YES],
		[self checkboxWithKey:HWG_DISPLAY_NOTIFY_ROLE_CHANGE_KEY title:NSLocalizedString(@"Notify on role change (Main/Extended/Mirrored)", @"") defaultOn:YES],
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

	// --- Experimental early-detection section, visually separated ---
	NSBox *separator = [[NSBox alloc] init];
	separator.boxType = NSBoxSeparator;
	separator.translatesAutoresizingMaskIntoConstraints = NO;
	[v addSubview:separator];
	[NSLayoutConstraint activateConstraints:@[
		[separator.topAnchor      constraintEqualToAnchor:previous.bottomAnchor constant:18],
		[separator.leadingAnchor  constraintEqualToAnchor:v.leadingAnchor constant:16],
		[separator.trailingAnchor constraintEqualToAnchor:v.trailingAnchor constant:-16],
	]];
	previous = separator;

	NSTextField *expHeader = [NSTextField labelWithString:NSLocalizedString(@"⚠️ Early physical-link detection (Experimental)", @"")];
	expHeader.font = [NSFont boldSystemFontOfSize:12];
	expHeader.textColor = [NSColor systemOrangeColor];
	expHeader.translatesAutoresizingMaskIntoConstraints = NO;
	[v addSubview:expHeader];
	[NSLayoutConstraint activateConstraints:@[
		[expHeader.topAnchor     constraintEqualToAnchor:previous.bottomAnchor constant:14],
		[expHeader.leadingAnchor  constraintEqualToAnchor:v.leadingAnchor constant:16],
	]];
	previous = expHeader;

	NSButton *earlyDetectionCheckbox = [NSButton checkboxWithTitle:NSLocalizedString(@"Try to detect the video link before macOS assigns a role", @"")
															 target:self
															 action:@selector(earlyDetectionToggleChanged:)];
	earlyDetectionCheckbox.state = HWGDisplayBoolForKey(HWG_DISPLAY_EARLY_DETECTION_KEY, NO) ? NSControlStateValueOn : NSControlStateValueOff;
	earlyDetectionCheckbox.translatesAutoresizingMaskIntoConstraints = NO;
	[v addSubview:earlyDetectionCheckbox];
	[NSLayoutConstraint activateConstraints:@[
		[earlyDetectionCheckbox.topAnchor     constraintEqualToAnchor:previous.bottomAnchor constant:10],
		[earlyDetectionCheckbox.leadingAnchor  constraintEqualToAnchor:v.leadingAnchor constant:16],
		[earlyDetectionCheckbox.heightAnchor   constraintEqualToConstant:24],
	]];
	previous = earlyDetectionCheckbox;

	NSInteger currentInterval = HWGDisplayIntForKey(HWG_DISPLAY_EARLY_DETECTION_INTERVAL_KEY, 3);
	if (currentInterval < 1) currentInterval = 1;
	if (currentInterval > 10) currentInterval = 10;

	NSTextField *intervalLabel = [NSTextField labelWithString:[NSString stringWithFormat:NSLocalizedString(@"Poll every %ld s", @""), (long)currentInterval]];
	intervalLabel.translatesAutoresizingMaskIntoConstraints = NO;
	self.earlyDetectionIntervalLabel = intervalLabel;
	[v addSubview:intervalLabel];
	[NSLayoutConstraint activateConstraints:@[
		[intervalLabel.topAnchor     constraintEqualToAnchor:previous.bottomAnchor constant:10],
		[intervalLabel.leadingAnchor  constraintEqualToAnchor:v.leadingAnchor constant:36],
	]];

	NSSlider *intervalSlider = [NSSlider sliderWithValue:currentInterval minValue:1 maxValue:10 target:self action:@selector(earlyDetectionIntervalChanged:)];
	intervalSlider.numberOfTickMarks = 10;
	intervalSlider.allowsTickMarkValuesOnly = YES;
	intervalSlider.translatesAutoresizingMaskIntoConstraints = NO;
	[v addSubview:intervalSlider];
	[NSLayoutConstraint activateConstraints:@[
		[intervalSlider.topAnchor      constraintEqualToAnchor:intervalLabel.bottomAnchor constant:6],
		[intervalSlider.leadingAnchor  constraintEqualToAnchor:v.leadingAnchor constant:36],
		[intervalSlider.trailingAnchor constraintEqualToAnchor:v.trailingAnchor constant:-36],
	]];
	previous = intervalSlider;

	NSTextField *warning = [NSTextField wrappingLabelWithString:NSLocalizedString(@"Reads the macOS unified log for internal kernel messages (\"ReceiverConnected\") that mark a physical HDMI/DisplayPort link, before the display has an assigned role (Extended/Mirror). This is NOT a documented API: the exact log text can change or disappear in any macOS update with no warning, and Apple Silicon only. While enabled, this polls the system log on a timer — a continuous, ongoing CPU/battery cost for the whole time it stays on. Off by default; recommended only for testing.", @"")];
	warning.font = [NSFont systemFontOfSize:11];
	warning.textColor = [NSColor secondaryLabelColor];
	warning.translatesAutoresizingMaskIntoConstraints = NO;
	warning.preferredMaxLayoutWidth = 420;
	[v addSubview:warning];
	[NSLayoutConstraint activateConstraints:@[
		[warning.topAnchor      constraintEqualToAnchor:previous.bottomAnchor constant:12],
		[warning.leadingAnchor  constraintEqualToAnchor:v.leadingAnchor constant:16],
		[warning.trailingAnchor constraintEqualToAnchor:v.trailingAnchor constant:-16],
	]];

	prefsView = v;
	return prefsView;
}

#pragma mark HWGrowlPluginNotifierProtocol

-(NSArray*)noteNames {
	return [NSArray arrayWithObjects:@"DisplayConnected", @"DisplayDisconnected", @"DisplayModeChanged", @"DisplayRoleChanged", @"DisplayLinkDetected", nil];
}
-(NSDictionary*)localizedNames {
	return [NSDictionary dictionaryWithObjectsAndKeys:NSLocalizedString(@"Display Connected", @""), @"DisplayConnected",
			  NSLocalizedString(@"Display Disconnected", @""), @"DisplayDisconnected",
			  NSLocalizedString(@"Display Mode Changed", @""), @"DisplayModeChanged",
			  NSLocalizedString(@"Display Role Changed", @""), @"DisplayRoleChanged",
			  NSLocalizedString(@"Video Link Detected (Experimental)", @""), @"DisplayLinkDetected", nil];
}
-(NSDictionary*)noteDescriptions {
	return [NSDictionary dictionaryWithObjectsAndKeys:NSLocalizedString(@"Sent when an external display is connected", @""), @"DisplayConnected",
			  NSLocalizedString(@"Sent when an external display is disconnected", @""), @"DisplayDisconnected",
			  NSLocalizedString(@"Sent when an already-connected display's resolution or refresh rate changes", @""), @"DisplayModeChanged",
			  NSLocalizedString(@"Sent when an already-connected display's role changes (becomes/stops being Main, or Mirroring starts/stops)", @""), @"DisplayRoleChanged",
			  NSLocalizedString(@"Experimental: sent when a physical video link is detected before macOS assigns the display a role. Off by default — see Preferences.", @""), @"DisplayLinkDetected", nil];
}
-(NSArray*)defaultNotifications {
	return [NSArray arrayWithObjects:@"DisplayConnected", @"DisplayDisconnected", nil];
}

@end
