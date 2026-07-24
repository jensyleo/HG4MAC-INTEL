//
//  HWGrowlPowerMonitor.m
//  HardwareGrowler
//
//  Created by Daniel Siemer on 5/6/12.
//  Copyright (c) 2012 The Growl Project, LLC. All rights reserved.
//

// compile with ARC: -fobjc-arc
#import "HWGrowlPowerMonitor.h"
#include <IOKit/IOKitLib.h>
#include <IOKit/ps/IOPSKeys.h>
#include <IOKit/ps/IOPowerSources.h>

// F33: individually configurable fields in the power/battery notification body — same
// pattern as NetworkMonitor's per-field settings. All default to YES (matches prior
// always-on behavior).
#define HWG_POWER_SHOW_TYPE_KEY       @"HWGPowerShowSourceType"
#define HWG_POWER_SHOW_STATE_KEY      @"HWGPowerShowChargeState"
#define HWG_POWER_SHOW_PERCENTAGE_KEY @"HWGPowerShowPercentage"
#define HWG_POWER_SHOW_TIME_KEY       @"HWGPowerShowTimeRemaining"

// #8 (F34 candidate): battery health/cycle count, reported as a SEPARATE periodic
// notification (not tied to the minutes-based status refire above) since it changes on
// a days/weeks/months timescale, not a minutes one. Each metric is independently
// toggleable; if both are off there's nothing to say, so the check is skipped entirely.
#define HWG_POWER_SHOW_CYCLES_KEY        @"HWGPowerShowCycleCount"
#define HWG_POWER_SHOW_HEALTH_KEY        @"HWGPowerShowBatteryHealth"
#define HWG_POWER_HEALTH_VALUE_KEY       @"HWGPowerHealthCheckIntervalValue"
#define HWG_POWER_HEALTH_UNIT_KEY        @"HWGPowerHealthCheckIntervalUnit"   // 0=days, 1=weeks, 2=months
#define HWG_POWER_LAST_HEALTH_CHECK_KEY  @"HWGPowerLastHealthCheckDate"
#define HWG_POWER_HEALTH_VALUE_DEFAULT   1
#define HWG_POWER_HEALTH_UNIT_DEFAULT    2

// Child of "Check every" above: an optional, more frequent REMINDER of the same (cached)
// health/cycle numbers, in hours — e.g. "remind me 3x/day" while waiting for the next full
// days/weeks/months check. Off by default; the main check above already covers the feature.
#define HWG_POWER_HEALTH_NOTIFY_ENABLED_KEY @"HWGPowerHealthNotifyEnabled"
#define HWG_POWER_HEALTH_NOTIFY_HOURS_KEY   @"HWGPowerHealthNotifyHours"
#define HWG_POWER_HEALTH_NOTIFY_UNIT_KEY    @"HWGPowerHealthNotifyUnit"   // 0=hours, 1=minutes
#define HWG_POWER_LAST_HEALTH_NOTIFY_KEY    @"HWGPowerLastHealthNotifyDate"
#define HWG_POWER_HEALTH_NOTIFY_HOURS_DEFAULT 8
#define HWG_POWER_HEALTH_NOTIFY_UNIT_DEFAULT  0

// F34 candidate #1: Low Power Mode toggle. Public, stable API (NSProcessInfo), off by
// default per user request — this is a NEW behavior change (existing users never saw this
// notification before), unlike the F33 fields above which only toggle visibility of parts
// of an ALREADY-firing notification.
#define HWG_POWER_LOWPOWER_NOTIFY_KEY @"HWGPowerNotifyLowPowerMode"

static BOOL HWGPowerBoolForKey(NSString *key, BOOL def) {
	id stored = [[NSUserDefaults standardUserDefaults] objectForKey:key];
	return stored ? [stored boolValue] : def;
}

// Reads CycleCount / battery health (AppleRawMaxCapacity ÷ DesignCapacity) straight from
// the IOKit registry — IOPowerSources (used elsewhere in this file) does not expose either.
// Verified against real `ioreg -c AppleSmartBattery -r` output: top-level "MaxCapacity" is a
// self-calibrating 0–100 value that resets near 100 after recalibration events (not useful
// for long-term health), so health% is computed from the raw mAh figures instead.
// "DesignCycleCount9C" (the manufacturer-rated cycle budget for this specific battery) is
// included when present, purely as extra context in the description.
static BOOL HWGCopyBatteryHealth(NSInteger *outCycleCount, NSInteger *outHealthPercent, NSInteger *outRatedCycles) {
	io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"));
	if (!service) return NO;

	CFTypeRef cycleRef  = IORegistryEntryCreateCFProperty(service, CFSTR("CycleCount"), kCFAllocatorDefault, 0);
	CFTypeRef maxRef    = IORegistryEntryCreateCFProperty(service, CFSTR("AppleRawMaxCapacity"), kCFAllocatorDefault, 0);
	CFTypeRef designRef = IORegistryEntryCreateCFProperty(service, CFSTR("DesignCapacity"), kCFAllocatorDefault, 0);
	CFTypeRef ratedRef  = IORegistryEntryCreateCFProperty(service, CFSTR("DesignCycleCount9C"), kCFAllocatorDefault, 0);
	IOObjectRelease(service);

	BOOL gotAny = NO;

	if (cycleRef && CFGetTypeID(cycleRef) == CFNumberGetTypeID()) {
		NSInteger v = 0;
		if (CFNumberGetValue((CFNumberRef)cycleRef, kCFNumberNSIntegerType, &v)) {
			if (outCycleCount) *outCycleCount = v;
			gotAny = YES;
		}
	}
	if (maxRef && designRef &&
		CFGetTypeID(maxRef) == CFNumberGetTypeID() && CFGetTypeID(designRef) == CFNumberGetTypeID()) {
		NSInteger maxCap = 0, designCap = 0;
		if (CFNumberGetValue((CFNumberRef)maxRef, kCFNumberNSIntegerType, &maxCap) &&
			CFNumberGetValue((CFNumberRef)designRef, kCFNumberNSIntegerType, &designCap) &&
			designCap > 0) {
			float healthPct = roundf((maxCap / (float)designCap) * 100.0f);
			if (outHealthPercent) *outHealthPercent = (NSInteger)healthPct;
			gotAny = YES;
		}
	}
	if (ratedRef && CFGetTypeID(ratedRef) == CFNumberGetTypeID()) {
		NSInteger v = 0;
		if (CFNumberGetValue((CFNumberRef)ratedRef, kCFNumberNSIntegerType, &v) && outRatedCycles)
			*outRatedCycles = v;
	}

	if (cycleRef) CFRelease(cycleRef);
	if (maxRef) CFRelease(maxRef);
	if (designRef) CFRelease(designRef);
	if (ratedRef) CFRelease(ratedRef);
	return gotAny;
}

@interface HWGrowlPowerMonitor ()

+(NSInteger)batteryPercentageForPowerSourceDescription:(CFDictionaryRef)description;

@end

@interface GrowlPowerSourceDescription : NSObject

@property (nonatomic, assign) BOOL charging;
@property (nonatomic, assign) BOOL charged;
@property (nonatomic, assign) BOOL finishingCharge;
@property (nonatomic, assign) NSInteger percentage;
@property (nonatomic, assign) HGPowerSource powerType;
@property (nonatomic, assign) NSInteger remainingTime;

@property (nonatomic, strong) NSString *typeString;

-(id)initWithPowerSourceDescription:(CFDictionaryRef)description;

@end

@implementation GrowlPowerSourceDescription

+(GrowlPowerSourceDescription*)descriptionWithDescription:(CFDictionaryRef)description {
	return [[GrowlPowerSourceDescription alloc] initWithPowerSourceDescription:description];
}

-(id)initWithPowerSourceDescription:(CFDictionaryRef)description {
	if((self = [super init])){
		CFStringRef powerType = CFDictionaryGetValue(description, CFSTR(kIOPSTransportTypeKey));
		if (CFStringCompare(powerType, CFSTR(kIOPSInternalType), 0) == kCFCompareEqualTo)
		{
			_powerType = HGBatteryPower;
			self.typeString = NSLocalizedString(@"Battery", @"Internal battery");
		}
		else if (CFStringCompare(powerType, CFSTR(kIOPSSerialTransportType), 0) == kCFCompareEqualTo ||
					CFStringCompare(powerType, CFSTR(kIOPSUSBTransportType), 0) == kCFCompareEqualTo ||
					CFStringCompare(powerType, CFSTR(kIOPSNetworkTransportType), 0) == kCFCompareEqualTo )
		{
			_powerType = HGUPSPower;
			self.typeString = NSLocalizedString(@"UPS", @"Uninteruptable Power supply");
		}
		else
		{
			_powerType = HGUnknownPower;
			self.typeString = NSLocalizedString(@"Unknown", @"Unknown power supply type");
		}
		
		if (CFDictionaryGetValue(description, CFSTR(kIOPSIsChargingKey)) == kCFBooleanTrue)
			_charging = YES;
		else
			_charging = NO;
		
		if (CFDictionaryGetValue(description, CFSTR(kIOPSIsChargedKey)) == kCFBooleanTrue)
			_charged = YES;
		else
			_charged = NO;
		
		CFTypeRef finishingValue = CFDictionaryGetValue(description, CFSTR(kIOPSIsFinishingChargeKey));
		if(finishingValue && finishingValue == kCFBooleanTrue)
			_finishingCharge = YES;
		else
			_finishingCharge = NO;
		
		_percentage = [HWGrowlPowerMonitor batteryPercentageForPowerSourceDescription:description];

		CFNumberRef timeToFullOrEmpty = NULL;
		if(_charging){
			timeToFullOrEmpty = CFDictionaryGetValue(description, CFSTR(kIOPSTimeToFullChargeKey));
		}else if(!_charging){ 
			timeToFullOrEmpty = CFDictionaryGetValue(description, CFSTR(kIOPSTimeToEmptyKey));
		}
		
		if(timeToFullOrEmpty){
			int64_t timeToChargeOrDrain;
			int64_t batteryTime = -1;
						
			if(CFNumberGetType(timeToFullOrEmpty) != kCFNumberSInt64Type)
				NSLog(@"GAH");
			
			if (CFNumberGetValue(timeToFullOrEmpty, kCFNumberSInt64Type, &timeToChargeOrDrain))
				batteryTime = timeToChargeOrDrain;
			
			if(batteryTime >= 0.0)
				_remainingTime = (NSInteger)batteryTime;
			else
				_remainingTime = kIOPSTimeRemainingUnknown;
		}else{
			_remainingTime = kIOPSTimeRemainingUnknown;
		}
	}
	return self;
}

// ARC: no manual dealloc needed (typeString is strong, auto-released).

-(NSString*)notificationDescriptionForCurrentSource:(HGPowerSource)currentSource {
	NSMutableString *description = nil;

	// F33: each field independently toggleable from Preferences → Modules → Power Monitor.
	BOOL showType       = HWGPowerBoolForKey(HWG_POWER_SHOW_TYPE_KEY, YES);
	BOOL showState      = HWGPowerBoolForKey(HWG_POWER_SHOW_STATE_KEY, YES);
	BOOL showPercentage = HWGPowerBoolForKey(HWG_POWER_SHOW_PERCENTAGE_KEY, YES);
	BOOL showTime       = HWGPowerBoolForKey(HWG_POWER_SHOW_TIME_KEY, YES);

	NSString *state = nil;
	NSString *time = nil;
	NSString *percentage = nil;

	// At 100% the battery is full even if IOKit still reports isCharging/finishing
	// (macOS keeps "finishing charge" briefly at 100%). Never say "Charging at 100%".
	if(_percentage >= 100)
		state = NSLocalizedString(@"Charged", @"");
	else if(_charging)
		state = NSLocalizedString(@"Charging", @"");
	else if(_finishingCharge)
		state = NSLocalizedString(@"Finishing", @"");
	else if (_charged)
		state = NSLocalizedString(@"Charged", @"");
	if (!showState) state = nil;

	if(_percentage >= 0.0)
		percentage = [NSString stringWithFormat:@"%ld%%", _percentage];
	if (!showPercentage) percentage = nil;

	if(_remainingTime > 0.0){
		NSString *format = (currentSource == HGACPower) ? NSLocalizedString(@"Time to charge: %ld minutes", @"") : NSLocalizedString(@"Time remaining: %ld minutes", @"");
		time = [NSString stringWithFormat:format, _remainingTime];
	}
	if (!showTime) time = nil;

	if(state || time || percentage){
		NSMutableArray *line1Parts = [NSMutableArray array];
		if (state) [line1Parts addObject:state];
		if (percentage) {
			[line1Parts addObject:[NSString stringWithFormat:
				NSLocalizedString(@"at %@", @"at battery percentage"), percentage]];
		}
		NSString *line1Body = [line1Parts componentsJoinedByString:@" "];

		description = [NSMutableString string];
		if (showType && [line1Body length]) {
			[description appendFormat:@"%@: %@", [self typeString], line1Body];
		} else if (showType) {
			[description appendString:[self typeString]];
		} else if ([line1Body length]) {
			[description appendString:line1Body];
		}
		if (time) {
			if ([description length]) [description appendString:@"\n"];
			[description appendString:time];
		}
	}
	return description;
}

@end

@interface HWGrowlPowerMonitor ()

@property (nonatomic, weak) id<HWGrowlPluginControllerProtocol> delegate;
// Core Foundation pointer — ARC does NOT manage this; keep assign.
@property (nonatomic, assign)	CFRunLoopSourceRef notificationRunLoopSource;

@property (nonatomic, assign) HGPowerSource lastPowerSource;
@property (nonatomic, assign) NSTimeInterval lastKnownTime;

@property (nonatomic, strong) NSTimer *refireTimer;
@property (nonatomic, assign) BOOL lastWarnState;
@property (nonatomic, assign) BOOL announcedFullyCharged;

@property (nonatomic, strong) NSString *refireBatteryStatusLabel;
@property (nonatomic, strong) NSString *refireEveryLabel;
@property (nonatomic, strong) NSString *minutesLabel;
@property (nonatomic, strong) NSString *refireOnlyOnBatteryLabel;

// #8: battery health/cycle count periodic check — independent of refireTimer above
// (that one only runs on battery, in minutes; this one runs always, in days/weeks/months).
@property (nonatomic, strong) NSTimer *healthCheckTimer;
@property (nonatomic, strong) NSTextField *healthIntervalValueLabel;
@property (nonatomic, strong) NSSlider *healthNotifySlider;
@property (nonatomic, strong) NSTextField *healthNotifyHoursLabel;

// F34 #1: last known Low Power Mode state, to dedupe spurious re-fires of
// NSProcessInfoPowerStateDidChangeNotification.
@property (nonatomic, assign) BOOL lastLowPowerModeEnabled;

@end

@implementation HWGrowlPowerMonitor

@synthesize prefsView;
@synthesize delegate;
@synthesize notificationRunLoopSource;
@synthesize lastPowerSource;
@synthesize lastKnownTime;
@synthesize refireTimer;
@synthesize lastWarnState;
@synthesize announcedFullyCharged;

-(id)init {
	if((self = [super init])){
		self.notificationRunLoopSource = IOPSNotificationCreateRunLoopSource(powerSourceChanged, (__bridge void *)self);

		if (notificationRunLoopSource)
			CFRunLoopAddSource(CFRunLoopGetMain(), notificationRunLoopSource, kCFRunLoopDefaultMode);
		lastPowerSource = HGUnknownPower;
		lastKnownTime = kIOPSTimeRemainingUnknown;
		lastWarnState = NO;

		self.refireBatteryStatusLabel = NSLocalizedString(@"Refire battery status", @"Label for checkbox that sets battery status to redisplay every so often");
		self.refireEveryLabel = NSLocalizedString(@"Refire every:", @"Label for box for putting in the amount of time between refire");
		self.minutesLabel = NSLocalizedString(@"minutes", @"Unit label for how often to refire the battery status");
		self.refireOnlyOnBatteryLabel = NSLocalizedString(@"Refire only on battery", @"Label for checkbox that sets whether to only show battery status every x minutes when on battery pwoer");

		// Runs regardless of AC/battery state (health doesn't change based on that) — unlike
		// refireTimer, which checkTimer starts/stops depending on power source.
		[self startHealthCheckTimer];

		// F34 #1: Low Power Mode. NSProcessInfoPowerStateDidChangeNotification fires on
		// BOTH low-power-mode toggles AND thermal-state changes sharing the same underlying
		// KVO-ish mechanism on some OS versions — re-read isLowPowerModeEnabled and compare
		// against the last known value rather than trusting the notification alone.
		[[NSNotificationCenter defaultCenter] addObserver:self
												  selector:@selector(lowPowerModeChanged:)
													  name:NSProcessInfoPowerStateDidChangeNotification
													object:nil];
		_lastLowPowerModeEnabled = [NSProcessInfo processInfo].isLowPowerModeEnabled;
	}
	return self;
}

-(void)dealloc {
	// ARC handles the ObjC ivars; keep the CF teardown + timer invalidation.
	if (notificationRunLoopSource) {
		CFRunLoopRemoveSource(CFRunLoopGetMain(), notificationRunLoopSource, kCFRunLoopDefaultMode);
		CFRelease(notificationRunLoopSource);
	}
	[refireTimer invalidate];
	[_healthCheckTimer invalidate];
	[[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark Low Power Mode (F34 #1)

-(void)lowPowerModeChanged:(NSNotification *)note {
	BOOL enabled = [NSProcessInfo processInfo].isLowPowerModeEnabled;
	if (enabled == _lastLowPowerModeEnabled) return;   // dedupe: notification can share the thermal-state path
	_lastLowPowerModeEnabled = enabled;

	if (!HWGPowerBoolForKey(HWG_POWER_LOWPOWER_NOTIFY_KEY, NO)) return;   // off by default (F34 #1)

	@autoreleasepool {
		NSData *iconData = [self currentPowerStatusIconData];
		[delegate notifyWithName:@"PowerLowPowerMode"
							title:enabled ? NSLocalizedString(@"Low Power Mode Enabled", @"") : NSLocalizedString(@"Low Power Mode Disabled", @"")
					  description:@""
							 icon:iconData
				 identifierString:@"PowerLowPowerMode"
					contextString:nil
						   plugin:self];
	}
}

-(void)fireOnLaunchNotes {
	[self powerSourceChanged:YES];
	[self checkTimer];
	// Covers the case where the configured interval already elapsed while the app was quit.
	[self checkBatteryHealthDue];
}

-(BOOL)refireOnBattery {
	BOOL result = YES;
	if([[NSUserDefaults standardUserDefaults] objectForKey:@"RefireOnBattery"])
		result = [[NSUserDefaults standardUserDefaults] boolForKey:@"RefireOnBattery"];
	return result;
}
-(void)setRefireOnBattery:(BOOL)refire {
	[[NSUserDefaults standardUserDefaults] setBool:refire forKey:@"RefireOnBattery"];
	[[NSUserDefaults standardUserDefaults] synchronize];
	[self checkTimer];
}

-(CGFloat)refireTime {
	CGFloat result = 10.0f;
	if([[NSUserDefaults standardUserDefaults] objectForKey:@"PowerRefireTime"])
		result = [[NSUserDefaults standardUserDefaults] floatForKey:@"PowerRefireTime"];
	return result;
}
-(void)setRefireTime:(CGFloat)time {
	[[NSUserDefaults standardUserDefaults] setFloat:time forKey:@"PowerRefireTime"];
	[[NSUserDefaults standardUserDefaults] synchronize];
	[self stopTimer];
	[self checkTimer];
}

-(BOOL)enableRefire {
	BOOL result = YES;
	if([[NSUserDefaults standardUserDefaults] objectForKey:@"EnablePowerRefire"])
		result = [[NSUserDefaults standardUserDefaults] boolForKey:@"EnablePowerRefire"];
	return result;
}
-(void)setEnableRefire:(BOOL)enable {
	[[NSUserDefaults standardUserDefaults] setBool:enable forKey:@"EnablePowerRefire"];
	[[NSUserDefaults standardUserDefaults] synchronize];
	[self checkTimer];
}

-(void)checkTimer {
	if(refireTimer) {
		/* Conditions under which we stop:
		 * refire is disabled, or we are on AC and we only want to fire on battery
		 */
		if(![self enableRefire] || (lastPowerSource == HGACPower && [self refireOnBattery]))
			[self stopTimer];
	} else {
		/* Conditions under which we start:
		 * refire is enabled, and we are not on AC or we only want to fire on battery
		 */
		if([self enableRefire] && (lastPowerSource != HGACPower || ![self refireOnBattery]))
			[self startTimer];
	}
}

-(void)startTimer {	
	if(refireTimer)
		return;
	
//	NSLog(@"start timer");
	self.refireTimer = [NSTimer timerWithTimeInterval:[self refireTime] * 60.0f
															 target:self 
														  selector:@selector(timerFire:)
														  userInfo:nil
															repeats:YES];
	[[NSRunLoop mainRunLoop] addTimer:refireTimer forMode:NSDefaultRunLoopMode];
    [[NSRunLoop mainRunLoop] addTimer:refireTimer forMode:NSEventTrackingRunLoopMode];
    [[NSRunLoop mainRunLoop] addTimer:refireTimer forMode:NSModalPanelRunLoopMode];
}

-(void)stopTimer {
	if(!refireTimer)
		return;
	
//	NSLog(@"stop timer");
	[refireTimer invalidate];
	self.refireTimer = nil;
}

-(void)timerFire:(NSTimer*)timer {
	[self powerSourceChanged:YES];
}

-(void)powerSourceChanged:(BOOL)force {
	BOOL changedType = NO;
	BOOL hasBattery = NO;
	BOOL chargingOrFinishing = NO;
	NSInteger percentage = -1;
	
	CFTypeRef sourcesBlob = IOPSCopyPowerSourcesInfo();
	if(sourcesBlob)
	{
		NSString *source = (__bridge NSString*)IOPSGetProvidingPowerSourceType(sourcesBlob);
		
		HGPowerSource currentSource;
		if([source compare:@"AC Power"] == NSOrderedSame) {
			currentSource = HGACPower;
		} else if ([source compare:@"Battery Power"] == NSOrderedSame) {
			currentSource = HGBatteryPower;
		} else if ([source compare:@"UPS Power"] == NSOrderedSame) {
			currentSource = HGUPSPower;
		} else {
			currentSource = HGUnknownPower;
		}
		
		if(currentSource != lastPowerSource)
			changedType = YES;
		
		NSMutableArray *powerSourceDescriptions = [NSMutableArray array];
		CFArrayRef	powerSourcesList = IOPSCopyPowerSourcesList(sourcesBlob);
		if(powerSourcesList)
		{
			CFIndex	count = CFArrayGetCount(powerSourcesList);
			for (CFIndex i = 0; i < count; ++i) {
				CFTypeRef		powerSource;
				CFDictionaryRef description;
				
				powerSource = CFArrayGetValueAtIndex(powerSourcesList, i);
				description = IOPSGetPowerSourceDescription(sourcesBlob, powerSource);
				
				if(!description)
					continue;
				
				hasBattery = YES;
				GrowlPowerSourceDescription *growlDescription = [GrowlPowerSourceDescription descriptionWithDescription:description];
				[powerSourceDescriptions addObject:growlDescription];
				
				if([growlDescription charging] || [growlDescription finishingCharge])
					chargingOrFinishing = YES;
				
				if([growlDescription percentage] > percentage)
					percentage = [growlDescription percentage];
			}
			CFRelease(powerSourcesList);
		}
		
		__block CFTimeInterval remaining = kIOPSTimeRemainingUnknown;
		if(currentSource == HGACPower){
			//enumerate them and find greatest
			[powerSourceDescriptions enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
				if([obj remainingTime] > remaining)
					remaining = [obj remainingTime];
			}];
		}else if(currentSource == HGUPSPower || currentSource == HGBatteryPower){
			remaining = IOPSGetTimeRemainingEstimate();
			if(remaining >= 0.0f)
				remaining /= 60.0f;
		}
		

		BOOL sendTime = NO;
		if(remaining != kIOPSTimeRemainingUnknown && (changedType || (remaining == kIOPSTimeRemainingUnknown) != (lastKnownTime == kIOPSTimeRemainingUnknown)))
			sendTime = YES;
				
		BOOL warnBattery = NO;
		IOPSLowBatteryWarningLevel warnLevel = IOPSGetBatteryWarningLevel();
		if(warnLevel != kIOPSLowBatteryWarningNone)
			warnBattery = YES;
		
		if(lastWarnState && warnBattery)
			warnBattery = NO;
		else if(!lastWarnState && warnBattery)
			lastWarnState = YES;
		else if(lastWarnState && !warnBattery)
			lastWarnState = NO;
		
		// The periodic refire (force) re-announces status every X min — useful for
		// charge/discharge PROGRESS, but pointless once the battery is fully charged on
		// AC (nothing changes at 100%). Suppress a refire-ONLY fire when fully charged;
		// the one-time "charged" transition still fires via changedType/sendTime (so 100%
		// is announced exactly once), and the refire keeps working while charging/on battery.
		BOOL fullyCharged = (currentSource == HGACPower && !chargingOrFinishing);
		BOOL refireOnly   = force && !changedType && !sendTime && !warnBattery;

		// One-time "fully charged" notice. Reaching 100% doesn't change the power-source
		// type and (empirically) doesn't flip the time-known state, so the normal
		// changedType/sendTime/refire path never announces it. Announce it explicitly,
		// exactly once, when the battery TRANSITIONS to full; re-arm when it drops below
		// 100% or is unplugged. Don't announce at launch if it's already full — only on a
		// real transition (on the first check lastPowerSource is still Unknown).
		BOOL isFull = (currentSource == HGACPower && hasBattery && percentage >= 100);
		if(isFull && !announcedFullyCharged){
			BOOL firstCheck = (lastPowerSource == HGUnknownPower);
			announcedFullyCharged = YES;
			if(!firstCheck){
				@autoreleasepool {
					NSString *desc = [self chargingDescriptionForPowerSources:powerSourceDescriptions
															 currentSource:currentSource];
					NSData *fullIcon = [[NSImage imageNamed:@"Power-Plugged"] TIFFRepresentation];
					// Distinct identifier so the dedup key (name+identifier+description) doesn't
					// collide with the generic "On AC Power" notice (same description).
					[delegate notifyWithName:@"PowerChange"
									   title:NSLocalizedString(@"Battery Fully Charged", @"")
								 description:desc ?: @""
										icon:fullIcon
							identifierString:@"PowerFullyCharged"
							   contextString:nil
									  plugin:self];
				}
			}
		} else if(!isFull){
			announcedFullyCharged = NO;
		}

		if((changedType || sendTime || warnBattery || force) && !(refireOnly && fullyCharged)){
			NSString *title = nil;
			NSString *name = nil;
			NSString *localizedSource = [self localizedNameForSource:currentSource];
			NSString *description = nil;
			NSString *powerDescription = [self chargingDescriptionForPowerSources:powerSourceDescriptions
																					  currentSource:currentSource];
			if(!warnBattery){
				name = @"PowerChange";
				title = [NSString stringWithFormat:NSLocalizedString(@"On %@", @"Format string for On <power type>"), localizedSource];
				description = hasBattery ? powerDescription : @"";

				// "old → new" on an actual source-type change (Battery→AC etc.) — skip on the
				// very first check (lastPowerSource is still Unknown then, so there's no real
				// "old" to show) and on refires where the type didn't change (changedType
				// false), which would otherwise repeat "AC Power → AC Power" every refire.
				if (changedType && lastPowerSource != HGUnknownPower) {
					NSString *sourceLine = [NSString stringWithFormat:NSLocalizedString(@"Source:\t%@ → %@", @""),
						[self localizedNameForSource:lastPowerSource], localizedSource];
					description = [description length] ? [NSString stringWithFormat:@"%@\n%@", sourceLine, description] : sourceLine;
				}
			} else {
				name = @"PowerWarning";
				title	= NSLocalizedString(@"Battery Low!", @"");
				description = NSLocalizedString(@"Battery Low, Please plug the computer in now", @"");
				if(powerDescription)
					description = [description stringByAppendingFormat:@"\n%@", powerDescription];
			}
			
			if(!description)
				description = [NSMutableString string];
						
			NSString *imageName = [self powerIconNameForSource:currentSource percentage:percentage];

			@autoreleasepool
			{
	NSData *iconData = [[NSImage imageNamed:imageName] TIFFRepresentation];
            
            [delegate notifyWithName:name
                               title:title
								 description:description
                                icon:iconData
                    identifierString:name
                       contextString:nil
                              plugin:self];
			}
			lastPowerSource = currentSource;
			lastKnownTime = remaining;
		}
		
		CFRelease(sourcesBlob);
	}
}

// Icon-name selection extracted out of -powerSourceChanged: so it can also be reused by
// the Battery Health Check notification (which has no notion of "the notification that
// triggered this", just "what's the current status right now").
-(NSString *)powerIconNameForSource:(HGPowerSource)source percentage:(NSInteger)percentage {
	switch (source) {
		case HGACPower:
			// Plugged but NOT full → charging ramp by level (Power-Charging-0…100),
			// even if IOKit momentarily reports isCharging=NO right after connecting.
			// Only a full (or unknown) battery shows the plain "plugged" icon — this
			// avoids showing a full-battery icon when you plug in at e.g. 10%.
			if (percentage >= 0 && percentage < 100) {
				CGFloat adjusted = roundf((CGFloat)percentage / 10.0f);
				return (adjusted == 0) ? @"Power-Charging-0" : [NSString stringWithFormat:@"Power-Charging-%ld0", (NSInteger)adjusted];
			}
			return @"Power-Plugged";   // full (100%) or unknown %
		case HGBatteryPower:
		case HGUPSPower:
			if (percentage >= 0) {
				CGFloat adjusted = roundf((CGFloat)percentage / 10.0f);
				return (adjusted == 0) ? @"Power-0" : [NSString stringWithFormat:@"Power-%ld0", (NSInteger)adjusted];
			}
			return @"Power-NoBattery";
		case HGUnknownPower:
		default:
			return @"Power-BatteryFailure";
	}
}

// Reads the CURRENT power source/percentage fresh from IOKit — used by Battery Health
// Check, which fires on its own schedule (not from within -powerSourceChanged:) and so has
// no already-computed currentSource/percentage lying around to reuse.
-(NSData *)currentPowerStatusIconData {
	NSString *imageName = @"Power-BatteryFailure";
	CFTypeRef sourcesBlob = IOPSCopyPowerSourcesInfo();
	if (sourcesBlob) {
		NSString *source = (__bridge NSString*)IOPSGetProvidingPowerSourceType(sourcesBlob);
		HGPowerSource currentSource;
		if ([source compare:@"AC Power"] == NSOrderedSame) {
			currentSource = HGACPower;
		} else if ([source compare:@"Battery Power"] == NSOrderedSame) {
			currentSource = HGBatteryPower;
		} else if ([source compare:@"UPS Power"] == NSOrderedSame) {
			currentSource = HGUPSPower;
		} else {
			currentSource = HGUnknownPower;
		}

		NSInteger percentage = -1;
		CFArrayRef powerSourcesList = IOPSCopyPowerSourcesList(sourcesBlob);
		if (powerSourcesList) {
			CFIndex count = CFArrayGetCount(powerSourcesList);
			for (CFIndex i = 0; i < count; ++i) {
				CFTypeRef powerSource = CFArrayGetValueAtIndex(powerSourcesList, i);
				CFDictionaryRef description = IOPSGetPowerSourceDescription(sourcesBlob, powerSource);
				if (!description) continue;
				NSInteger p = [HWGrowlPowerMonitor batteryPercentageForPowerSourceDescription:description];
				if (p > percentage) percentage = p;
			}
			CFRelease(powerSourcesList);
		}

		imageName = [self powerIconNameForSource:currentSource percentage:percentage];
		CFRelease(sourcesBlob);
	}
	return [[NSImage imageNamed:imageName] TIFFRepresentation];
}

-(NSMutableString*)chargingDescriptionForPowerSources:(NSArray*)sources currentSource:(HGPowerSource)currentSource {
	// P20 (MRC): the old code did [[NSMutableString string] retain] + autorelease
	// to survive a nested @autoreleasepool in the caller (powerSourceChanged:).
	// Under ARC this resolves itself: the __block var is strong (keeps it alive in
	// the block) and the returned value is retained by the caller before the pool drains.
	__block NSMutableString *description = nil;
	[sources enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
		NSString *sourceString = [obj notificationDescriptionForCurrentSource:currentSource];
		if(sourceString){
			if(!description)
				description = [NSMutableString string];
			else
				[description appendString:@"\n"];
			[description appendString:sourceString];
		}
	}];
	return description;
}

+(NSInteger)batteryPercentageForPowerSourceDescription:(CFDictionaryRef)description {
	NSInteger percentageCapacity = -1;
	
	if(description && CFDictionaryGetValue(description, CFSTR(kIOPSIsPresentKey)) == kCFBooleanTrue){		
		CFNumberRef currentCapacityNum = CFDictionaryGetValue(description, CFSTR(kIOPSCurrentCapacityKey));
		CFNumberRef maxCapacityNum = CFDictionaryGetValue(description, CFSTR(kIOPSMaxCapacityKey));
		
		CFIndex currentCapacity, maxCapacity, sourceCapacity = -1;

		// Guard: the capacity keys can be absent (NULL) on some third-party UPS, and
		// maxCapacity could be 0 → CFNumberGetValue(NULL) is UB and /0 yields NaN.
		if (currentCapacityNum && maxCapacityNum &&
			 CFNumberGetValue(currentCapacityNum, kCFNumberCFIndexType, &currentCapacity) &&
			 CFNumberGetValue(maxCapacityNum, kCFNumberCFIndexType, &maxCapacity) &&
			 maxCapacity > 0)
			sourceCapacity = roundf((currentCapacity / (float)maxCapacity) * 100.0f);
		
		if(sourceCapacity > percentageCapacity)
			percentageCapacity = sourceCapacity;
	}
	
	return percentageCapacity;
}

-(NSString*)localizedNameForSource:(HGPowerSource)source {
	NSString *result = nil;
	switch (source) {
		case HGACPower:
			result = NSLocalizedString(@"AC Power", @"");
			break;
		case HGBatteryPower:
			result = NSLocalizedString(@"Battery Power", @"");
			break;
		case HGUPSPower:
			result = NSLocalizedString(@"UPS Power", @"");
			break;
		case HGUnknownPower:
		default:
			result = NSLocalizedString(@"Unknown Power Source", @"");
			break;
	}
	return result;
}

static void powerSourceChanged(void *context) {
	HWGrowlPowerMonitor *monitor = (__bridge HWGrowlPowerMonitor*)context;
	[monitor powerSourceChanged:NO];
	[monitor checkTimer];
}

#pragma mark Battery health check (#8)

-(NSInteger)healthIntervalValue {
	id stored = [[NSUserDefaults standardUserDefaults] objectForKey:HWG_POWER_HEALTH_VALUE_KEY];
	NSInteger v = stored ? [stored integerValue] : HWG_POWER_HEALTH_VALUE_DEFAULT;
	return (v < 1) ? 1 : v;
}
-(void)setHealthIntervalValue:(NSInteger)value {
	[[NSUserDefaults standardUserDefaults] setInteger:(value < 1 ? 1 : value) forKey:HWG_POWER_HEALTH_VALUE_KEY];
}

-(NSInteger)healthIntervalUnit {
	id stored = [[NSUserDefaults standardUserDefaults] objectForKey:HWG_POWER_HEALTH_UNIT_KEY];
	return stored ? [stored integerValue] : HWG_POWER_HEALTH_UNIT_DEFAULT;
}
-(void)setHealthIntervalUnit:(NSInteger)unit {
	[[NSUserDefaults standardUserDefaults] setInteger:unit forKey:HWG_POWER_HEALTH_UNIT_KEY];
}

-(NSString *)healthIntervalUnitLabel:(NSInteger)unit {
	switch (unit) {
		case 0:  return NSLocalizedString(@"day(s)", @"");
		case 1:  return NSLocalizedString(@"week(s)", @"");
		default: return NSLocalizedString(@"month(s)", @"");
	}
}

-(NSTimeInterval)healthCheckIntervalSeconds {
	NSTimeInterval unitSeconds;
	switch ([self healthIntervalUnit]) {
		case 0:  unitSeconds = 86400.0; break;              // days
		case 1:  unitSeconds = 7 * 86400.0; break;          // weeks
		default: unitSeconds = 30 * 86400.0; break;         // months (approx, matches "refire every N minutes" style — not calendar-exact)
	}
	return [self healthIntervalValue] * unitSeconds;
}

-(BOOL)healthNotifyEnabled {
	return HWGPowerBoolForKey(HWG_POWER_HEALTH_NOTIFY_ENABLED_KEY, NO);
}
-(void)setHealthNotifyEnabled:(BOOL)enabled {
	[[NSUserDefaults standardUserDefaults] setBool:enabled forKey:HWG_POWER_HEALTH_NOTIFY_ENABLED_KEY];
}

-(NSInteger)healthNotifyHours {
	id stored = [[NSUserDefaults standardUserDefaults] objectForKey:HWG_POWER_HEALTH_NOTIFY_HOURS_KEY];
	NSInteger v = stored ? [stored integerValue] : HWG_POWER_HEALTH_NOTIFY_HOURS_DEFAULT;
	return (v < 1) ? 1 : v;
}
-(void)setHealthNotifyHours:(NSInteger)hours {
	[[NSUserDefaults standardUserDefaults] setInteger:(hours < 1 ? 1 : hours) forKey:HWG_POWER_HEALTH_NOTIFY_HOURS_KEY];
}

// 0 = hours, 1 = minutes. Minutes exists mainly so this reminder can be tested end-to-end
// in a few minutes instead of waiting up to a full day at the 1-24 hour range.
-(NSInteger)healthNotifyUnit {
	id stored = [[NSUserDefaults standardUserDefaults] objectForKey:HWG_POWER_HEALTH_NOTIFY_UNIT_KEY];
	return stored ? [stored integerValue] : HWG_POWER_HEALTH_NOTIFY_UNIT_DEFAULT;
}
-(void)setHealthNotifyUnit:(NSInteger)unit {
	[[NSUserDefaults standardUserDefaults] setInteger:unit forKey:HWG_POWER_HEALTH_NOTIFY_UNIT_KEY];
}
-(NSString *)healthNotifyUnitLabel:(NSInteger)unit {
	return (unit == 1) ? NSLocalizedString(@"minute(s)", @"") : NSLocalizedString(@"hour(s)", @"");
}
-(NSTimeInterval)healthNotifyIntervalSeconds {
	NSTimeInterval unitSeconds = ([self healthNotifyUnit] == 1) ? 60.0 : 3600.0;
	return [self healthNotifyHours] * unitSeconds;
}

-(void)startHealthCheckTimer {
	if (_healthCheckTimer) return;
	// A 1-minute tick is cheap (just compares elapsed-vs-configured-interval, no IOKit call
	// unless something is actually due) and is what makes the minutes option on "Notify
	// every" meaningful — an hourly tick would silently round every reminder up to the next
	// full hour regardless of what the user configured.
	self.healthCheckTimer = [NSTimer scheduledTimerWithTimeInterval:60.0
															   target:self
															 selector:@selector(checkBatteryHealthDue)
															 userInfo:nil
															  repeats:YES];
}

-(void)checkBatteryHealthDue {
	BOOL showCycles = HWGPowerBoolForKey(HWG_POWER_SHOW_CYCLES_KEY, YES);
	BOOL showHealth = HWGPowerBoolForKey(HWG_POWER_SHOW_HEALTH_KEY, YES);
	if (!showCycles && !showHealth) return;   // both fields off — nothing to report, skip entirely

	NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
	NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];

	NSTimeInterval lastCheck = [defaults doubleForKey:HWG_POWER_LAST_HEALTH_CHECK_KEY];
	BOOL checkDue = (lastCheck == 0) || (now - lastCheck) >= [self healthCheckIntervalSeconds];

	// "Notify every" (child of "Check every"): an optional, more frequent reminder of the
	// SAME health/cycle numbers, in hours — independent cadence from the main check above.
	BOOL notifyEnabled = [self healthNotifyEnabled];
	NSTimeInterval lastNotify = [defaults doubleForKey:HWG_POWER_LAST_HEALTH_NOTIFY_KEY];
	BOOL notifyDue = notifyEnabled && ((lastNotify == 0) || (now - lastNotify) >= [self healthNotifyIntervalSeconds]);

	[self performBatteryHealthCheckForcingCheckDue:checkDue notifyDue:notifyDue];
}

// Split out of -checkBatteryHealthDue so "Check Now" can force a report immediately
// (forcingCheckDue:YES) without waiting for either interval to actually elapse, while the
// normal timer-driven path still only reports when one of them is genuinely due.
-(void)performBatteryHealthCheckForcingCheckDue:(BOOL)checkDue notifyDue:(BOOL)notifyDue {
	if (!checkDue && !notifyDue) return;

	NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
	NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];

	// Mark as checked/notified regardless of outcome — a Mac with no battery (desktop)
	// would otherwise retry every hour forever with nothing to report. A full check also
	// resets the reminder clock (we just showed the same info either way).
	if (checkDue) [defaults setDouble:now forKey:HWG_POWER_LAST_HEALTH_CHECK_KEY];
	[defaults setDouble:now forKey:HWG_POWER_LAST_HEALTH_NOTIFY_KEY];

	BOOL showCycles = HWGPowerBoolForKey(HWG_POWER_SHOW_CYCLES_KEY, YES);
	BOOL showHealth = HWGPowerBoolForKey(HWG_POWER_SHOW_HEALTH_KEY, YES);

	NSInteger cycleCount = -1, healthPercent = -1, ratedCycles = -1;
	if (!HWGCopyBatteryHealth(&cycleCount, &healthPercent, &ratedCycles))
		return;   // no AppleSmartBattery service (desktop Mac) — nothing to report

	NSMutableArray<NSString*> *parts = [NSMutableArray array];
	if (showCycles && cycleCount >= 0) {
		[parts addObject:(ratedCycles > 0)
			? [NSString stringWithFormat:NSLocalizedString(@"Cycle count: %ld (rated for ~%ld)", @""), (long)cycleCount, (long)ratedCycles]
			: [NSString stringWithFormat:NSLocalizedString(@"Cycle count: %ld", @""), (long)cycleCount]];
	}
	if (showHealth && healthPercent >= 0) {
		[parts addObject:[NSString stringWithFormat:NSLocalizedString(@"Battery health: %ld%%", @""), (long)healthPercent]];
	}
	if (![parts count]) return;

	@autoreleasepool {
		NSData *iconData = [self currentPowerStatusIconData];
		[delegate notifyWithName:@"PowerBatteryHealth"
							title:NSLocalizedString(@"Battery Health Check", @"")
					  description:[parts componentsJoinedByString:@"\n"]
							 icon:iconData
				 identifierString:@"PowerBatteryHealthCheck"
					contextString:nil
						   plugin:self];
	}
}

#pragma mark HWGrowlPluginProtocol

// delegate accessors are auto-synthesized from the @property (weak).
-(NSString*)pluginDisplayName {
	return NSLocalizedString(@"Power Monitor", @"");
}
-(NSImage*)preferenceIcon {
	static NSImage *_icon = nil;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		_icon = [NSImage imageNamed:@"HWGPrefsPower"];
	});
	return _icon;
}
// F33: single generic handler for every per-field visibility checkbox — mirrors
// NetworkMonitor's `fieldToggleChanged:`. Each checkbox's `identifier` carries the
// NSUserDefaults key it controls.
-(IBAction)fieldToggleChanged:(NSButton*)sender {
	NSString *key = sender.identifier;
	if (!key) return;
	[[NSUserDefaults standardUserDefaults] setBool:(sender.state == NSControlStateValueOn) forKey:key];
}

-(NSButton *)checkboxWithKey:(NSString *)key title:(NSString *)title defaultOn:(BOOL)defaultOn {
	NSButton *box = [NSButton checkboxWithTitle:title target:self action:@selector(fieldToggleChanged:)];
	box.identifier = key;
	box.state = HWGPowerBoolForKey(key, defaultOn) ? NSControlStateValueOn : NSControlStateValueOff;
	box.translatesAutoresizingMaskIntoConstraints = YES;   // frame-based layout, see preferencePane
	return box;
}

-(IBAction)healthIntervalSliderChanged:(NSSlider*)sender {
	[self setHealthIntervalValue:[sender integerValue]];
	[self updateHealthIntervalLabel];
}
-(IBAction)healthUnitChanged:(NSPopUpButton*)sender {
	[self setHealthIntervalUnit:[sender indexOfSelectedItem]];
	[self updateHealthIntervalLabel];
}
-(void)updateHealthIntervalLabel {
	NSInteger value = [self healthIntervalValue];
	self.healthIntervalValueLabel.stringValue = [NSString stringWithFormat:@"%ld %@", (long)value, [self healthIntervalUnitLabel:[self healthIntervalUnit]]];
}

// Manual override for "Check every" — forces an immediate report regardless of how much
// time is left on either interval, so the user isn't stuck waiting up to a month (the
// default "Check every" interval) to see a report, or to re-verify the feature after
// changing settings.
-(IBAction)healthCheckNowPressed:(NSButton*)sender {
	[self performBatteryHealthCheckForcingCheckDue:YES notifyDue:NO];
}

-(IBAction)healthNotifyToggled:(NSButton*)sender {
	BOOL on = (sender.state == NSControlStateValueOn);
	[self setHealthNotifyEnabled:on];
	self.healthNotifySlider.enabled = on;
}
-(IBAction)healthNotifyHoursChanged:(NSSlider*)sender {
	[self setHealthNotifyHours:[sender integerValue]];
	[self updateHealthNotifyHoursLabel];
}
-(IBAction)healthNotifyUnitChanged:(NSPopUpButton*)sender {
	[self setHealthNotifyUnit:[sender indexOfSelectedItem]];
	[self updateHealthNotifyHoursLabel];
}
-(void)updateHealthNotifyHoursLabel {
	NSInteger value = [self healthNotifyHours];
	self.healthNotifyHoursLabel.stringValue = [NSString stringWithFormat:@"%ld %@", (long)value, [self healthNotifyUnitLabel:[self healthNotifyUnit]]];
}

-(NSView*)preferencePane {
	if (prefsView) return prefsView;

	// The nib lives in THIS plugin's bundle, not the main app bundle.
	[[NSBundle bundleForClass:[self class]] loadNibNamed:@"PowerMonitorPrefs" owner:self topLevelObjects:nil];
	NSView *xibView = prefsView;   // the refire-settings view the nib wired up

	// F33: append a "Notification fields" section below the existing XIB content, rather
	// than editing the XIB itself (its fixed-size layout is fragile to hand-edit). Positions
	// everything with plain old-style FRAME math (matching xibView's own legacy
	// springs-and-struts layout) instead of Auto Layout — two different Auto Layout-based
	// attempts (manual anchor chains, then NSStackView) both left a large, unexplained gap
	// between xibView and this section, likely from mixing Auto Layout with xibView's
	// non-Auto-Layout internal subviews. Deterministic frame arithmetic sidesteps that
	// entirely: every view's exact position is computed by hand, top to bottom.
	// Widened from the original 380 to fit the "Check every"/"Notify every" controls
	// (slider + label + unit popup) without any subview extending past combined's own
	// bounds — a subview whose frame exceeds its superview's bounds is only clickable in
	// the portion that still falls within the superview's bounds, which is exactly what
	// caused the unit popup's arrow/chevron (at its far right edge) to not respond to
	// clicks while its text (further left, still in-bounds) did.
	CGFloat width = 460;
	CGFloat pad = 16;
	CGFloat xibW = 225, xibH = 204;
	CGFloat headerH = 18;
	CGFloat rowH = 24;
	NSArray<NSButton*> *rows = @[
		[self checkboxWithKey:HWG_POWER_SHOW_TYPE_KEY       title:NSLocalizedString(@"Power source type (Battery/UPS/Unknown)", @"") defaultOn:YES],
		[self checkboxWithKey:HWG_POWER_SHOW_STATE_KEY      title:NSLocalizedString(@"Charge state (Charging/Finishing/Charged)", @"") defaultOn:YES],
		[self checkboxWithKey:HWG_POWER_SHOW_PERCENTAGE_KEY title:NSLocalizedString(@"Battery percentage", @"") defaultOn:YES],
		[self checkboxWithKey:HWG_POWER_SHOW_TIME_KEY       title:NSLocalizedString(@"Time remaining / time to charge", @"") defaultOn:YES],
		// F34 #1: OFF by default — new behavior, not a visibility toggle on an existing notice.
		[self checkboxWithKey:HWG_POWER_LOWPOWER_NOTIFY_KEY title:NSLocalizedString(@"Notify when Low Power Mode is turned on/off", @"") defaultOn:NO],
	];
	// #8: battery health/cycle count — own header/section since it's a SEPARATE periodic
	// notification (see checkBatteryHealthDue), not part of the regular status notice above.
	NSArray<NSButton*> *healthRows = @[
		[self checkboxWithKey:HWG_POWER_SHOW_CYCLES_KEY title:NSLocalizedString(@"Cycle count", @"") defaultOn:YES],
		[self checkboxWithKey:HWG_POWER_SHOW_HEALTH_KEY title:NSLocalizedString(@"Battery health %", @"") defaultOn:YES],
	];
	CGFloat healthControlRowH = 30;
	CGFloat healthSectionHeight = 10 + headerH + 10
		+ ([healthRows count] * rowH) + (([healthRows count] - 1) * 10)
		+ 10 + healthControlRowH      // "Check every" row
		+ 6 + rowH                    // "Check Now" button row
		+ 6 + healthControlRowH;      // "Notify every" row (child, tighter gap)
	// PowerMonitorPrefs.xib's own content occupies only its TOP ~half — its lowest control
	// ("Refire only on battery") has its own bottom edge at local y=107 (of the xib's
	// declared 204pt-tall frame), and the cursor logic below jumps straight to that real
	// content bottom (skipping the ~97pt of blank space baked into the xib) instead of the
	// xib's full declared height. `totalHeight` MUST reserve space to match — reserving the
	// full `xibH` here (as an earlier version of this method did) left that same ~97pt as
	// unused dead space at the very BOTTOM of the pane instead (content is anchored top-down,
	// so any over-reservation at the top surfaces as slack at the bottom) — which in turn
	// made the scroll view show a scrollbar with nothing under it. Keep this constant in sync
	// with the identical one used for the cursor jump right after xibView is placed.
	CGFloat xibContentBottomLocal = 107;
	CGFloat totalHeight = (xibContentBottomLocal + 16) + headerH + 10 + ([rows count] * rowH) + (([rows count] - 1) * 10)
		+ healthSectionHeight + pad;

	NSView *combined = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, width, totalHeight)];
	CGFloat cursorTop = totalHeight;   // distance from the TOP where the next view's top edge goes

	xibView.translatesAutoresizingMaskIntoConstraints = YES;   // keep its own old-style layout untouched
	CGFloat xibY = cursorTop - xibH;
	xibView.frame = NSMakeRect(0, xibY, xibW, xibH);
	[combined addSubview:xibView];
	// PowerMonitorPrefs.xib's own content (the refire checkboxes/labels) is authored inside
	// the TOP ~half of its declared 204pt-tall frame — the lowest control ("Refire only on
	// battery") has its own bottom edge at local y=107, leaving ~97pt of blank space already
	// baked into the xib below it. Advancing the cursor from xibView's FULL frame bottom
	// (as a naive stack would) left that blank space PLUS our own 16pt gap between the
	// visible refire controls and "Notification fields" — this is what actually caused the
	// large gap (confirmed by reading real on-screen element positions via Accessibility).
	// Resume from the xib's real content bottom instead (xibContentBottomLocal declared
	// above, alongside totalHeight, which must reserve the matching amount of space).
	cursorTop = xibY + xibContentBottomLocal - 16;

	NSTextField *header = [NSTextField labelWithString:NSLocalizedString(@"Notification fields", @"")];
	header.font = [NSFont boldSystemFontOfSize:12];
	header.textColor = [NSColor secondaryLabelColor];
	header.translatesAutoresizingMaskIntoConstraints = YES;
	CGFloat headerY = cursorTop - headerH;
	header.frame = NSMakeRect(pad, headerY, width - 2 * pad, headerH);
	[combined addSubview:header];
	cursorTop = headerY - 10;

	for (NSButton *row in rows) {
		CGFloat rowY = cursorTop - rowH;
		row.frame = NSMakeRect(pad, rowY, width - 2 * pad, rowH);
		[combined addSubview:row];
		cursorTop = rowY - 10;
	}

	// #8: "Battery health check" section — own header, own checkboxes, own interval control.
	cursorTop -= 10;
	NSTextField *healthHeader = [NSTextField labelWithString:NSLocalizedString(@"Battery health check", @"")];
	healthHeader.font = [NSFont boldSystemFontOfSize:12];
	healthHeader.textColor = [NSColor secondaryLabelColor];
	healthHeader.translatesAutoresizingMaskIntoConstraints = YES;
	CGFloat healthHeaderY = cursorTop - headerH;
	healthHeader.frame = NSMakeRect(pad, healthHeaderY, width - 2 * pad, headerH);
	[combined addSubview:healthHeader];
	cursorTop = healthHeaderY - 10;

	for (NSButton *row in healthRows) {
		CGFloat rowY = cursorTop - rowH;
		row.frame = NSMakeRect(pad, rowY, width - 2 * pad, rowH);
		[combined addSubview:row];
		cursorTop = rowY - 10;
	}

	// Interval control: "Check every: [==slider==] N unit(s) [Days/Weeks/Months ▾]"
	// Column x-positions all fit within `width` (see the comment on `width` above) so no
	// subview's clickable area gets clipped by combined's own bounds.
	CGFloat controlY = cursorTop - healthControlRowH;
	NSTextField *everyLabel = [NSTextField labelWithString:NSLocalizedString(@"Check every:", @"")];
	everyLabel.translatesAutoresizingMaskIntoConstraints = YES;
	everyLabel.frame = NSMakeRect(pad, controlY + 6, 88, 18);
	[combined addSubview:everyLabel];

	NSSlider *intervalSlider = [[NSSlider alloc] initWithFrame:NSMakeRect(pad + 92, controlY, 110, healthControlRowH)];
	intervalSlider.minValue = 1;
	intervalSlider.maxValue = 12;
	intervalSlider.integerValue = [self healthIntervalValue];
	intervalSlider.target = self;
	intervalSlider.action = @selector(healthIntervalSliderChanged:);
	intervalSlider.translatesAutoresizingMaskIntoConstraints = YES;
	[combined addSubview:intervalSlider];

	self.healthIntervalValueLabel = [NSTextField labelWithString:@""];
	self.healthIntervalValueLabel.translatesAutoresizingMaskIntoConstraints = YES;
	self.healthIntervalValueLabel.frame = NSMakeRect(pad + 92 + 118, controlY + 6, 84, 18);
	[combined addSubview:self.healthIntervalValueLabel];
	[self updateHealthIntervalLabel];

	NSPopUpButton *unitPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(pad + 92 + 118 + 88, controlY, 110, healthControlRowH) pullsDown:NO];
	[unitPopup addItemsWithTitles:@[NSLocalizedString(@"Days", @""), NSLocalizedString(@"Weeks", @""), NSLocalizedString(@"Months", @"")]];
	[unitPopup selectItemAtIndex:[self healthIntervalUnit]];
	unitPopup.target = self;
	unitPopup.action = @selector(healthUnitChanged:);
	unitPopup.translatesAutoresizingMaskIntoConstraints = YES;
	[combined addSubview:unitPopup];

	cursorTop = controlY - 6;

	// Manual override: forces an immediate report without waiting for "Check every"'s
	// interval (up to a month at default settings) to elapse — also the only way to
	// re-verify the feature after it has already fired once this interval.
	CGFloat checkNowY = cursorTop - rowH;
	NSButton *checkNowButton = [NSButton buttonWithTitle:NSLocalizedString(@"Check Now", @"") target:self action:@selector(healthCheckNowPressed:)];
	checkNowButton.translatesAutoresizingMaskIntoConstraints = YES;
	checkNowButton.frame = NSMakeRect(pad + 92, checkNowY, 100, rowH);
	[combined addSubview:checkNowButton];
	cursorTop = checkNowY - 6;

	// "Notify every" — CHILD of "Check every": an optional, more frequent reminder of the
	// same numbers, in hours. Indented (+20pt) to read as nested under the row above.
	CGFloat notifyY = cursorTop - healthControlRowH;
	CGFloat notifyIndent = pad + 20;
	NSButton *notifyCheckbox = [NSButton checkboxWithTitle:NSLocalizedString(@"Notify every:", @"") target:self action:@selector(healthNotifyToggled:)];
	notifyCheckbox.state = [self healthNotifyEnabled] ? NSControlStateValueOn : NSControlStateValueOff;
	notifyCheckbox.translatesAutoresizingMaskIntoConstraints = YES;
	notifyCheckbox.frame = NSMakeRect(notifyIndent, notifyY + 6, 130, 18);
	[combined addSubview:notifyCheckbox];

	self.healthNotifySlider = [[NSSlider alloc] initWithFrame:NSMakeRect(notifyIndent + 134, notifyY, 110, healthControlRowH)];
	self.healthNotifySlider.minValue = 1;
	self.healthNotifySlider.maxValue = 24;
	self.healthNotifySlider.integerValue = [self healthNotifyHours];
	self.healthNotifySlider.enabled = [self healthNotifyEnabled];
	self.healthNotifySlider.target = self;
	self.healthNotifySlider.action = @selector(healthNotifyHoursChanged:);
	self.healthNotifySlider.translatesAutoresizingMaskIntoConstraints = YES;
	[combined addSubview:self.healthNotifySlider];

	// Room for the label+unit-popup pair added below is tight: this row is indented (+20pt,
	// nested under "Check every") on top of already using a wider checkbox column (134 vs
	// "Check every"'s 92), so reusing that row's same label/popup widths would push the
	// popup's right edge past combined's own bounds — the exact "arrow doesn't respond to
	// clicks" bug documented above on `width`. Narrower label + narrower popup, laid out via
	// explicit end-of-previous-view + gap math (rather than copying fixed offsets), keeps the
	// popup's right edge safely inside combined's bounds.
	CGFloat notifySliderEndX = notifyIndent + 134 + 110;
	CGFloat notifyGap = 8;
	CGFloat notifyLabelW = 60;
	self.healthNotifyHoursLabel = [NSTextField labelWithString:@""];
	self.healthNotifyHoursLabel.translatesAutoresizingMaskIntoConstraints = YES;
	self.healthNotifyHoursLabel.frame = NSMakeRect(notifySliderEndX + notifyGap, notifyY + 6, notifyLabelW, 18);
	[combined addSubview:self.healthNotifyHoursLabel];

	NSPopUpButton *notifyUnitPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(notifySliderEndX + notifyGap + notifyLabelW + notifyGap, notifyY, 84, healthControlRowH) pullsDown:NO];
	[notifyUnitPopup addItemsWithTitles:@[NSLocalizedString(@"Hours", @""), NSLocalizedString(@"Minutes", @"")]];
	[notifyUnitPopup selectItemAtIndex:[self healthNotifyUnit]];
	notifyUnitPopup.target = self;
	notifyUnitPopup.action = @selector(healthNotifyUnitChanged:);
	notifyUnitPopup.translatesAutoresizingMaskIntoConstraints = YES;
	[combined addSubview:notifyUnitPopup];

	[self updateHealthNotifyHoursLabel];

	NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, width, 260)];
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
	return [NSArray arrayWithObjects:@"PowerChange", @"PowerWarning", nil];
}
-(NSDictionary*)localizedNames {
	return [NSDictionary dictionaryWithObjectsAndKeys:NSLocalizedString(@"Power Changed", @""), @"PowerChange",
			  NSLocalizedString(@"Power Warning", @""), @"PowerWarning", nil];
}
-(NSDictionary*)noteDescriptions {
	return [NSDictionary dictionaryWithObjectsAndKeys:NSLocalizedString(@"Sent when the type or status of power changed", @""), @"PowerChange",
			  NSLocalizedString(@"Sent when the battery is getting low", @""), @"PowerWarning", nil];
}
-(NSArray*)defaultNotifications {
	return [NSArray arrayWithObjects:@"PowerChange", @"PowerWarning", nil];
}

@end
