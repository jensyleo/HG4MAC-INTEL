//
//  HWGrowlPluginController.m
//  HardwareGrowler
//
//  Created by Daniel Siemer on 5/2/12.
//  Copyright (c) 2012 The Growl Project, LLC. All rights reserved.
//

// compile with ARC: -fobjc-arc
#import "HWGrowlPluginController.h"

//DO NOT TOUCH, FOR KEEPING LOCALIZATION SCRIPT SIMPLER
#define GrowlOffSwitchFake NSLocalizedString(@"OFF", @"If the string is too long, use O");
#define GrowlOnSwitchFake NSLocalizedString(@"ON", @"If the string is too long, use I");

@interface HWGrowlPluginController ()

@property (nonatomic, strong) NSMutableArray *notifiers;
@property (nonatomic, strong) NSMutableArray *monitors;

@end

@implementation HWGrowlPluginController

@synthesize plugins;
@synthesize notifiers;
@synthesize monitors;

// ARC: no manual dealloc needed (plugins/notifiers/monitors are strong).

-(id)init {
	if((self = [super init])){
		self.plugins = [NSMutableArray array];
		self.notifiers = [NSMutableArray array];
		self.monitors = [NSMutableArray array];
		[self loadPlugins];
		
		[GrowlApplicationBridge setGrowlDelegate:self];
		[GrowlApplicationBridge setShouldUseBuiltInNotifications:YES];
		
		[self postRegistrationInit];
		
		if([self onLaunchEnabled])
			[self fireOnLaunchNotes];
	}
	return self;
}

-(void)loadPlugins {
	NSString *pluginsPath = [[NSBundle mainBundle] builtInPlugInsPath];
	NSArray *pluginBundles = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:pluginsPath
																										  error:nil];
	if(pluginBundles) {
		NSDictionary *disabledPlugins = [[NSUserDefaults standardUserDefaults] objectForKey:@"DisabledPlugins"];
		
		__block HWGrowlPluginController *blockSelf = self;
		[pluginBundles enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
			NSString *bundlePath = [pluginsPath stringByAppendingPathComponent:obj];
			NSBundle *pluginBundle = [NSBundle bundleWithPath:bundlePath];
			
			if(pluginBundle && [pluginBundle load])
			{
				NSString *bundleID = [pluginBundle bundleIdentifier];
				id plugin = [[[pluginBundle principalClass] alloc] init];
				if(plugin)
				{ 
					if([plugin conformsToProtocol:@protocol(HWGrowlPluginProtocol)])
					{
						[plugin setDelegate:self];
						BOOL disabled = NO;
						if(disabledPlugins && [disabledPlugins objectForKey:bundleID])
							disabled = [[disabledPlugins objectForKey:bundleID] boolValue];
						else if([plugin respondsToSelector:@selector(enabledByDefault)])
							disabled = ![plugin enabledByDefault];
						
						NSMutableDictionary *pluginDict = [NSMutableDictionary dictionaryWithObjectsAndKeys:plugin, @"plugin", 
																	  [NSNumber numberWithBool:disabled], @"disabled", nil];
						[blockSelf.plugins addObject:pluginDict];
						
						if([plugin conformsToProtocol:@protocol(HWGrowlPluginNotifierProtocol)])
							[blockSelf.notifiers addObject:plugin];
						if([plugin conformsToProtocol:@protocol(HWGrowlPluginMonitorProtocol)])
							[blockSelf.monitors addObject:plugin];
					}else{
						NSLog(@"%@ does not conform to HWGrowlPluginProtocol", NSStringFromClass([pluginBundle principalClass]));
					}
					// ARC balances the +1 from alloc/init; arrays hold their own strong refs.
				}else{
					NSLog(@"We couldn't instantiate %@ for plugin %@", NSStringFromClass([pluginBundle principalClass]), bundleID);
				}
			}else{
				NSLog(@"%@ is not a bundle or could not be loaded", bundlePath);
			}
		}];
	}
	[plugins sortUsingComparator:^NSComparisonResult(id obj1, id obj2) {
		return [[[obj1 objectForKey:@"plugin"] pluginDisplayName] compare:[[obj2 objectForKey:@"plugin"] pluginDisplayName]];
	}];
}
			
-(void)postRegistrationInit {
	[plugins enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
		if([[obj objectForKey:@"plugin"] respondsToSelector:@selector(postRegistrationInit)])
			[[obj objectForKey:@"plugin"] postRegistrationInit];
	}];
}

-(void)fireOnLaunchNotes {
	[notifiers enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
		if([obj respondsToSelector:@selector(fireOnLaunchNotes)])
			[obj fireOnLaunchNotes];
	}];
}

-(void)notifyWithName:(NSString*)name 
					 title:(NSString*)title
			 description:(NSString*)description
					  icon:(NSData*)iconData
	  identifierString:(NSString*)identifier
		  contextString:(NSString*)context
					plugin:(id)plugin
{
	__block BOOL disabled = NO;
	[plugins enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
		if([obj objectForKey:@"plugin"] == plugin)
		{
			disabled = [[obj objectForKey:@"disabled"] boolValue];
			*stop = YES;
		}
	}];
	if(disabled)
		return;

	// Duplicate suppression (also covers the cold-boot double, where
	// fireOnLaunchNotes and a real connect event report the same thing).
	// Skip if an identical notification (same name + identifier + description)
	// was already shown within the cooldown window.
	{
		static NSMutableDictionary *recentNotes = nil;
		static dispatch_once_t onceToken;
		dispatch_once(&onceToken, ^{ recentNotes = [[NSMutableDictionary alloc] init]; });
		const NSTimeInterval cooldown = 3.0;
		@synchronized(recentNotes) {
			NSString *key = [NSString stringWithFormat:@"%@|%@|%@",
			                 name ?: @"", identifier ?: @"", description ?: @""];
			NSDate *now  = [NSDate date];
			// Purge expired entries so this dict can't grow unbounded over a long
			// uptime (entries older than the cooldown are dead weight anyway).
			NSMutableArray *stale = [NSMutableArray array];
			[recentNotes enumerateKeysAndObjectsUsingBlock:^(id k, NSDate *v, BOOL *stop){
				if ([now timeIntervalSinceDate:v] >= cooldown) [stale addObject:k];
			}];
			[recentNotes removeObjectsForKeys:stale];
			NSDate *last = [recentNotes objectForKey:key];
			if (last && [now timeIntervalSinceDate:last] < cooldown) {
				return; // duplicate within window — skip
			}
			[recentNotes setObject:now forKey:key];
		}
	}

	// Bounce detection: if the same device (identifier) produces many events in
	// a short window, surface ONE extra "unstable device" alert. The individual
	// connect/disconnect notifications are still shown — this only adds a heads-up.
	if (identifier && [identifier length]) {
		static NSMutableDictionary *bounceTimes = nil;    // identifier -> NSMutableArray<NSDate>
		static NSMutableDictionary *bounceAlerted = nil;  // identifier -> NSDate (last alert)
		static dispatch_once_t bounceOnce;
		dispatch_once(&bounceOnce, ^{
			bounceTimes   = [[NSMutableDictionary alloc] init];
			bounceAlerted = [[NSMutableDictionary alloc] init];
		});
		const NSTimeInterval bounceWindow = 20.0;
		const NSUInteger     bounceThreshold = 4;

		BOOL shouldAlert = NO;
		NSUInteger eventCount = 0;
		@synchronized(bounceTimes) {
			NSDate *now = [NSDate date];
			// Purge identifiers with no activity within the window so bounceTimes /
			// bounceAlerted can't grow unbounded across many unique devices.
			NSMutableArray *staleIds = [NSMutableArray array];
			[bounceTimes enumerateKeysAndObjectsUsingBlock:^(id k, NSArray *times, BOOL *stop){
				NSDate *newest = [times lastObject];
				if (!newest || [now timeIntervalSinceDate:newest] >= bounceWindow) [staleIds addObject:k];
			}];
			[bounceTimes removeObjectsForKeys:staleIds];
			[bounceAlerted removeObjectsForKeys:staleIds];
			NSMutableArray *kept = [NSMutableArray array];
			for (NSDate *t in (NSArray *)[bounceTimes objectForKey:identifier]) {
				if ([now timeIntervalSinceDate:t] < bounceWindow) [kept addObject:t];
			}
			[kept addObject:now];
			[bounceTimes setObject:kept forKey:identifier];
			eventCount = [kept count];

			if (eventCount >= bounceThreshold) {
				NSDate *lastAlert = [bounceAlerted objectForKey:identifier];
				if (!lastAlert || [now timeIntervalSinceDate:lastAlert] >= bounceWindow) {
					shouldAlert = YES;
					[bounceAlerted setObject:now forKey:identifier];
				}
			}
		}

		if (shouldAlert) {
			// Friendly device label. Internal identifiers carry the "HWGrowl"
			// prefix (e.g. "HWGrowlAirPort" -> "AirPort"); real device names
			// (USB/Volume/Bluetooth) are used as-is. A few internal ones get a
			// nicer mapping so they don't read like code.
			NSDictionary *labelMap = @{
				@"HWGrowlNetworkLink":     @"Ethernet",
				@"HWGrowlIPAddressChange": @"Network",
				@"HWGrowlAirPort":         @"Wi-Fi",
				@"HWGrowlAirPortSignal":   @"Wi-Fi Signal",
				@"PowerChange":            @"Power",
				@"PowerWarning":           @"Power",
			};
			NSString *deviceLabel = identifier;
			if ([labelMap objectForKey:identifier]) {
				deviceLabel = [labelMap objectForKey:identifier];
			} else if ([identifier hasPrefix:@"HWGrowl"]) {
				deviceLabel = [identifier substringFromIndex:[@"HWGrowl" length]];
			}
			NSString *desc = [NSString stringWithFormat:
				NSLocalizedString(@"%@ is unstable\nPlease check the device", @""),
				deviceLabel];
			NSData *unstableIcon = [[NSImage imageNamed:@"Device-Unstable"] TIFFRepresentation];
			[GrowlApplicationBridge notifyWithTitle:NSLocalizedString(@"Unstable device", @"")
										description:desc
								   notificationName:@"DeviceUnstable"
										   iconData:unstableIcon
										   priority:1
										   isSticky:NO
									   clickContext:nil
										 identifier:[@"HWGBounce-" stringByAppendingString:identifier]];
		}
	}

	NSString *contextCombined = nil;
	if(context && [context rangeOfString:@" : "].location != NSNotFound) {
		NSLog(@"found \" : \" in context string %@", context);
	}
	if(context && plugin && [context rangeOfString:@" : "].location == NSNotFound) {
		contextCombined = [NSString stringWithFormat:@"%@ : %@", NSStringFromClass([plugin class]), context];
	}
	
    [GrowlApplicationBridge	notifyWithTitle:title
										 description:description
								  notificationName:name 
											 iconData:iconData
											 priority:0
											 isSticky:NO
										clickContext:contextCombined
										  identifier:identifier];
}

-(BOOL)onLaunchEnabled {
	return [[NSUserDefaults standardUserDefaults] boolForKey:@"ShowExisting"];
}

-(BOOL)pluginDisabled:(id)plugin {
	__block BOOL disabled = NO;
	[plugins enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
		if([obj objectForKey:@"plugin"] == plugin) 
		{
			disabled = [[obj objectForKey:@"disabled"] boolValue];
			*stop = YES;
		}
	}];
	return disabled;
}

-(void)growlNotificationClosed:(id)clickContext viaClick:(BOOL)click {
	NSArray *components = [clickContext componentsSeparatedByString:@" : "];
	if([components count] < 2)
		return;
	NSString *classString = [components objectAtIndex:0];
	NSString *context = [components objectAtIndex:1];
	
	[notifiers enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
		if([obj isKindOfClass:NSClassFromString(classString)]){
			if([obj respondsToSelector:@selector(noteClosed:byClick:)])
				[obj noteClosed:context byClick:click];
			*stop = YES;
		}
	}];
}

#pragma mark GrowlApplicationBridgeDelegate methods

- (NSDictionary*)registrationDictionaryForGrowl {
	NSMutableArray *allNotes = [NSMutableArray array];
	NSMutableArray *defaultNotes = [NSMutableArray array];
	NSMutableDictionary *descriptions = [NSMutableDictionary dictionary];
	NSMutableDictionary *localizedNames = [NSMutableDictionary dictionary];
	
	[notifiers enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
		id<HWGrowlPluginNotifierProtocol> notifier = obj;
		[allNotes addObjectsFromArray:[notifier noteNames]];
		if([notifier defaultNotifications])
			[defaultNotes addObjectsFromArray:[notifier defaultNotifications]];
		[descriptions addEntriesFromDictionary:[notifier noteDescriptions]];
		[localizedNames addEntriesFromDictionary:[notifier localizedNames]];
	}];
	
	NSDictionary *regDict = [NSDictionary dictionaryWithObjectsAndKeys:allNotes, GROWL_NOTIFICATIONS_ALL,
									 defaultNotes, GROWL_NOTIFICATIONS_DEFAULT,
									 descriptions, GROWL_NOTIFICATIONS_DESCRIPTIONS,
									 localizedNames, GROWL_NOTIFICATIONS_HUMAN_READABLE_NAMES, nil];
	return regDict;
}

- (NSString *) applicationNameForGrowl {
	return @"HG4MAC";
}

-(void)growlNotificationTimedOut:(id)clickContext {
	[self growlNotificationClosed:clickContext viaClick:NO];
}

-(void)growlNotificationWasClicked:(id)clickContext {
	[self growlNotificationClosed:clickContext viaClick:YES];
}

@end
