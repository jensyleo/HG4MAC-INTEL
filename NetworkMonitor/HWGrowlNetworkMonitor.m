//
//  HWGrowlNetworkMonitor.m
//  HardwareGrowler
//
//  Created by Daniel Siemer on 5/2/12.
//  Copyright (c) 2012 The Growl Project, LLC. All rights reserved.
//

// compile with ARC: -fobjc-arc
#import "HWGrowlNetworkMonitor.h"
#import "GrowlNetworkUtilities.h"
#import <SystemConfiguration/SystemConfiguration.h>
#import <CoreWLAN/CoreWLAN.h>
#import <CoreLocation/CoreLocation.h>

#include <sys/socket.h>
#include <sys/sockio.h>
#include <sys/ioctl.h>
#include <net/if.h>
#include <net/if_media.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <ifaddrs.h>

/* @"Link Status" == 1 seems to mean disconnected */
#define AIRPORT_DISCONNECTED 1

// F20: user-configurable WiFi signal poll interval (seconds). Default 12, clamped 5–60.
#define HWG_WIFI_POLL_KEY     @"HWGWifiSignalPollInterval"
#define HWG_WIFI_POLL_DEFAULT 12.0
#define HWG_WIFI_POLL_MIN     5.0
#define HWG_WIFI_POLL_MAX     60.0

// F20: user-configurable rate-limit between two "Wi-Fi Signal Changed" notifications, so a
// value hovering at a bar threshold doesn't spam. Default 10s, clamped 0–60 (0 = disabled).
#define HWG_WIFI_COOLDOWN_KEY     @"HWGWifiSignalCooldown"
#define HWG_WIFI_COOLDOWN_DEFAULT 10.0
#define HWG_WIFI_COOLDOWN_MIN     0.0
#define HWG_WIFI_COOLDOWN_MAX     60.0

// F33: individually configurable fields shown in Network Monitor notifications, grouped
// into 3 sections (Wi-Fi / Ethernet / Other-IP) in Preferences → Modules → Network Monitor.
// All default to YES (matching prior always-on behavior) except HWG_ETH_SHOW_ALL_KEY,
// which defaults to NO (matches the F35 hardcoded "real Ethernet only" filter).
#define HWG_WIFI_SHOW_SSID_KEY       @"HWGWifiShowSSID"
#define HWG_WIFI_SHOW_BSSID_KEY      @"HWGWifiShowBSSID"
#define HWG_WIFI_SHOW_BAND_KEY       @"HWGWifiShowBand"
#define HWG_WIFI_SHOW_GENERATION_KEY @"HWGWifiShowGeneration"
#define HWG_WIFI_SHOW_SECURITY_KEY   @"HWGWifiShowSecurity"

#define HWG_ETH_SHOW_INTERFACE_KEY   @"HWGEthernetShowInterface"
#define HWG_ETH_SHOW_SPEED_KEY       @"HWGEthernetShowSpeed"
#define HWG_ETH_SHOW_MODE_KEY        @"HWGEthernetShowMode"
#define HWG_ETH_SHOW_ALL_KEY         @"HWGEthernetShowAllInterfaces"

#define HWG_IP_SHOW_IPV4_KEY         @"HWGIPShowIPv4"
#define HWG_IP_SHOW_IPV6_KEY         @"HWGIPShowIPv6"
#define HWG_IP_SHOW_GATEWAY_KEY      @"HWGIPShowGateway"
#define HWG_IP_SHOW_NONROUTABLE_KEY  @"HWGIPShowNonRoutableTag"
#define HWG_IP_USE_FRIENDLY_KEY      @"HWGIPUseFriendlyNames"

// F34 #4: VPN connected/disconnected. OFF by default per user request — this is a NEW
// notification, not a visibility toggle on an existing one. Detection is a HEURISTIC (see
// -vpnLikeInterfaceNamesFromIPInfo:ipv6: below and the README "Known limitations" entry) —
// there is no public API that says "this interface IS a VPN"; we infer it from the BSD
// interface-name prefix macOS gives virtual tunnel interfaces.
#define HWG_VPN_NOTIFY_KEY @"HWGNetworkNotifyVPN"

// A plain NSView is NOT flipped by default, so inside an NSScrollView whose clip area
// ends up TALLER than the document (e.g. after the Preferences-window resize fix let the
// box grow), the document sits at the BOTTOM of the visible area — leaving an empty gap
// above content that's pinned via top-anchor constraints, instead of at the top where the
// constraints visually intend it. Flipped views don't have this ambiguity.
@interface HWGFlippedContentView : NSView
@end
@implementation HWGFlippedContentView
- (BOOL)isFlipped { return YES; }
@end

static struct ifmedia_description ifm_subtype_ethernet_descriptions[] = IFM_SUBTYPE_ETHERNET_DESCRIPTIONS;
static struct ifmedia_description ifm_shared_option_descriptions[] = IFM_SHARED_OPTION_DESCRIPTIONS;

typedef enum {
	HWGAirPortInterface,
	HWGEthernetInterface,
} NetworkInterfaceType;

@interface HWGrowlNetworkInterfaceStatus : NSObject;

@property (nonatomic, strong) NSString *interface;
@property (nonatomic, strong) NSDictionary *status;
@property (nonatomic, assign) NetworkInterfaceType type;

-(id)initForInterface:(NSString*)anInterface ofType:(NetworkInterfaceType)aType withStatus:(NSDictionary*)theStatus;

@end

@implementation HWGrowlNetworkInterfaceStatus

@synthesize interface;
@synthesize status;
@synthesize type;

-(id)initForInterface:(NSString *)anInterface 
					ofType:(NetworkInterfaceType)aType 
			  withStatus:(NSDictionary *)theStatus 
{
	if((self = [super init])){
		self.interface = anInterface;
		self.type = aType;
		self.status = theStatus;
	}
	return self;
}

// ARC: no manual dealloc needed (interface/status are strong, auto-released).

@end

@interface HWGrowlNetworkMonitor () <CWEventDelegate, CLLocationManagerDelegate>

@property (nonatomic, weak) id<HWGrowlPluginControllerProtocol> delegate;

// Core Foundation pointers — ARC does NOT manage these; keep assign.
@property (nonatomic, assign) SCDynamicStoreRef dynStore;
@property (nonatomic, assign) CFRunLoopSourceRef rlSrc;

@property (nonatomic, strong) NSMutableDictionary *networkInterfaceStates;
@property (nonatomic, strong) NSString *previousIPCombined;
// F33: whether any IPv4/IPv6 address was present on the last check — tracked separately
// from previousIPCombined (the DISPLAYED text) because F33's per-field toggles can make
// the displayed text empty even while addresses are genuinely still present.
@property (nonatomic, assign) BOOL previousHasIPAddresses;

// P10 (reverted 16-jul-2026): Ethernet (wired) link up/down was briefly detected via
// NWPathMonitor, but that only reports an interface once it has a USABLE network path
// (an IP + working route) — an interface with link but no DHCP-assigned IP (or one with a
// slow-to-settle static IP) never appeared at all, or appeared very late. Back to watching
// the RAW physical-link SCDynamicStore key (".../Link"), which reflects carrier/link state
// alone, independent of DHCP/IP — the same signal System Settings uses, and the same one
// already confirmed firing correctly on this exact machine (see iPhone USB test, 30-jun-2026,
// before this ever became NWPathMonitor). SCDynamicStore is also still used for IP/gateway.

// Remembers, per interface, whether it had recognized Ethernet media when it came up,
// so the Link-Down notification uses the same icon family as the Link-Up (the media is
// often unreadable once the interface is gone).
@property (nonatomic, strong) NSMutableDictionary *interfaceIsEthernet;

// CoreWLAN: replaces the deprecated SCDynamicStore AirPort keys for WiFi events.
// weak: the framework owns the +sharedWiFiClient singleton; we don't.
@property (nonatomic, weak) CWWiFiClient *wifiClient;
@property (nonatomic, strong) NSString *lastReportedSSID;

// F20: track the last reported WiFi signal bar level (0–4; -1 = not connected / unknown)
// so we notify only when the LEVEL changes, plus a cooldown to avoid threshold flapping.
@property (nonatomic, assign) NSInteger lastReportedWifiBars;
@property (nonatomic, strong) NSDate *lastSignalNoteTime;
@property (nonatomic, strong) NSTimer *signalPollTimer;

// Preferences pane (built programmatically — no nib) for the WiFi signal poll interval.
@property (nonatomic, strong) NSView *prefsView;
@property (nonatomic, weak) NSTextField *intervalValueLabel;
@property (nonatomic, weak) NSTextField *cooldownValueLabel;

// CoreLocation: required since macOS 10.14 to read the Wi-Fi SSID
@property (nonatomic, strong) CLLocationManager *locationManager;

// F34 #4: BSD names of VPN-like interfaces (utunN/pppN/ipsecN with a real address) currently
// believed active, so we notify only on the connect/disconnect TRANSITION.
@property (nonatomic, strong) NSMutableSet<NSString*> *activeVPNInterfaceNames;

@end

@implementation HWGrowlNetworkMonitor

@synthesize delegate;
@synthesize rlSrc;
@synthesize dynStore;
@synthesize networkInterfaceStates;
@synthesize previousIPCombined;
@synthesize previousHasIPAddresses;
@synthesize interfaceIsEthernet;
@synthesize wifiClient;
@synthesize lastReportedSSID;
@synthesize lastReportedWifiBars;
@synthesize lastSignalNoteTime;
@synthesize signalPollTimer;
@synthesize prefsView;
@synthesize intervalValueLabel;
@synthesize cooldownValueLabel;
@synthesize locationManager;

-(id)init {
	if((self = [super init])){
		self.previousIPCombined = nil;
		self.networkInterfaceStates = [NSMutableDictionary dictionary];
		self.interfaceIsEthernet = [NSMutableDictionary dictionary];
		self.lastReportedWifiBars = -1;
		self.activeVPNInterfaceNames = [NSMutableSet set];

		[self startObserving];
		[self startWiFiMonitoring];
		[self requestLocationForSSID];
	}
	return self;
}

// Reading the Wi-Fi SSID requires Location authorization since macOS 10.14.
// We ask once; if granted, [CWInterface ssid] starts returning the real name.
-(void)requestLocationForSSID {
	self.locationManager = [[CLLocationManager alloc] init];
	self.locationManager.delegate = self;
	[self.locationManager requestWhenInUseAuthorization];
}

-(void)locationManagerDidChangeAuthorization:(CLLocationManager *)manager {
	// When the user grants access, refresh the WiFi state so the SSID we now
	// can read gets reflected (and update the IP notification's interface info).
	CLAuthorizationStatus status = manager.authorizationStatus;
	if (status == kCLAuthorizationStatusAuthorizedAlways ||
	    status == kCLAuthorizationStatusAuthorized) {
		CWInterface *iface = [self.wifiClient interface];
		if (iface && [iface ssid]) {
			// Update our cached name so a re-read shows the real SSID next time.
			self.lastReportedSSID = [iface ssid];
		}
	}
}

-(void)dealloc {
	// ARC handles the ObjC ivars; keep the non-memory teardown (cancel timers,
	// CF teardown, stop CoreWLAN monitoring, drop delegates).
	[NSObject cancelPreviousPerformRequestsWithTarget:self];
	[signalPollTimer invalidate];

	if (rlSrc)
		CFRunLoopRemoveSource(CFRunLoopGetMain(), rlSrc, kCFRunLoopDefaultMode);
   if (dynStore)
		CFRelease(dynStore);

	if (wifiClient) {
		[wifiClient stopMonitoringAllEventsAndReturnError:NULL];
		wifiClient.delegate = nil;
	}

	locationManager.delegate = nil;
}

#pragma mark CoreWLAN — WiFi event monitoring (replaces deprecated SCDynamicStore AirPort keys)

-(void)startWiFiMonitoring {
	self.wifiClient = [CWWiFiClient sharedWiFiClient];
	self.wifiClient.delegate = self;

	NSError *err = nil;
	[self.wifiClient startMonitoringEventWithType:CWEventTypeLinkDidChange error:&err];
	if (err) NSLog(@"HWG WiFi linkDidChange monitor error: %@", err);
	err = nil;
	[self.wifiClient startMonitoringEventWithType:CWEventTypeSSIDDidChange error:&err];
	if (err) NSLog(@"HWG WiFi ssidDidChange monitor error: %@", err);
	err = nil;
	[self.wifiClient startMonitoringEventWithType:CWEventTypePowerDidChange error:&err];
	if (err) NSLog(@"HWG WiFi powerDidChange monitor error: %@", err);
	err = nil;
	[self.wifiClient startMonitoringEventWithType:CWEventTypeBSSIDDidChange error:&err];
	if (err) NSLog(@"HWG WiFi bssidDidChange monitor error: %@", err);
	err = nil;
	[self.wifiClient startMonitoringEventWithType:CWEventTypeModeDidChange error:&err];
	if (err) NSLog(@"HWG WiFi modeDidChange monitor error: %@", err);

	// F20 (Plan B): CWEventTypeLinkQualityDidChange does NOT fire on macOS Tahoe, so poll
	// the RSSI on a timer to detect signal-level changes. Interval is user-configurable.
	[self restartSignalPollTimer];

	// Initialize lastReportedSSID from the CURRENT state. If WiFi is already
	// connected when the app launches, no change event will fire — without
	// this, the first disconnect would be ignored (lastReportedSSID == nil).
	CWInterface *iface = [self.wifiClient interface];
	if (iface && [iface powerOn] && [iface interfaceMode] == kCWInterfaceModeStation) {
		self.lastReportedSSID = [iface ssid] ?: NSLocalizedString(@"Wi-Fi", @"");
	}
}

-(void)powerStateDidChangeForWiFiInterfaceWithName:(NSString *)interfaceName {
	[self handleWiFiStateChangeForInterface:interfaceName];
}

-(void)bssidDidChangeForWiFiInterfaceWithName:(NSString *)interfaceName {
	[self handleWiFiStateChangeForInterface:interfaceName];
}

-(void)modeDidChangeForWiFiInterfaceWithName:(NSString *)interfaceName {
	[self handleWiFiStateChangeForInterface:interfaceName];
}

-(void)handleWiFiStateChangeForInterface:(NSString *)interfaceName {
	// CoreWLAN delivers CWEventDelegate callbacks on its own internal queue, not the
	// main thread. This method mutates lastReportedSSID and posts notifications that
	// build NSImages / touch UI, so marshal the whole thing to main to avoid races.
	if (![NSThread isMainThread]) {
		dispatch_async(dispatch_get_main_queue(), ^{ [self handleWiFiStateChangeForInterface:interfaceName]; });
		return;
	}

	CWInterface *iface = [self.wifiClient interfaceWithName:interfaceName];
	if (!iface) return;

	// interfaceMode is the OS's operational state of the radio and does NOT
	// require Location permission (unlike ssid/bssid which return nil without
	// it). kCWInterfaceModeStation = associated to an access point.
	BOOL              poweredOn = [iface powerOn];
	CWInterfaceMode   mode      = [iface interfaceMode];
	BOOL              connected = poweredOn && (mode == kCWInterfaceModeStation);

	NSString *ssid     = [iface ssid];      // nil if Location permission denied
	NSString *bssidStr = [iface bssid];     // nil if Location permission denied

	if (connected) {
		NSString *displayName = ssid ?: NSLocalizedString(@"Wi-Fi", @"");
		if (lastReportedSSID && [lastReportedSSID isEqualToString:displayName])
			return; // already reported this state
		self.lastReportedSSID = displayName;
		// F20: baseline the signal bar level right away instead of waiting for
		// pollWifiSignal:'s first scheduled tick to do it — otherwise detecting any
		// real change takes two full poll intervals (one just to baseline, one to
		// compare) instead of one.
		NSInteger rssiNow = [iface rssiValue];
		self.lastReportedWifiBars = (rssiNow != 0) ? [self wifiBarsForRSSI:rssiNow] : -1;
		NSData *bssidData = nil;
		if (bssidStr) {
			unsigned int b[6] = {0};
			sscanf([bssidStr UTF8String], "%x:%x:%x:%x:%x:%x",
			       &b[0], &b[1], &b[2], &b[3], &b[4], &b[5]);
			unsigned char bytes[6] = {(unsigned char)b[0], (unsigned char)b[1],
			                          (unsigned char)b[2], (unsigned char)b[3],
			                          (unsigned char)b[4], (unsigned char)b[5]};
			bssidData = [NSData dataWithBytes:bytes length:6];
		}
		[self airportConnected:displayName bssid:bssidData];
		// IPv4 often arrives after the WiFi link comes up (DHCP completes
		// later than IPv6 SLAAC). The SCDynamicStore IPv4 key change does
		// not always fire reliably on macOS Tahoe, so we manually re-check
		// IPs a couple of times to pick up the late IPv4 address. Use
		// dispatch_after on the main queue (not performSelector:afterDelay:)
		// because this method may run off the main thread.
		__weak HWGrowlNetworkMonitor *blockSelf = self;
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
		               dispatch_get_main_queue(), ^{ [blockSelf updateIP]; });
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)),
		               dispatch_get_main_queue(), ^{ [blockSelf updateIP]; });
	} else {
		if (lastReportedSSID == nil)
			return; // already disconnected
		NSString *previousName = ([lastReportedSSID length] > 0)
		    ? lastReportedSSID
		    : NSLocalizedString(@"Wi-Fi", @"");
		self.lastReportedSSID = nil;
		self.lastReportedWifiBars = -1;   // re-baseline signal level on next connect (F20)
		[self airportDisconnected:previousName];
	}
}

-(void)linkDidChangeForWiFiInterfaceWithName:(NSString *)interfaceName {
	[self handleWiFiStateChangeForInterface:interfaceName];
}

-(void)ssidDidChangeForWiFiInterfaceWithName:(NSString *)interfaceName {
	[self handleWiFiStateChangeForInterface:interfaceName];
}

// F20: CoreWLAN link-quality events carry the live RSSI. Report only when the signal
// BAR LEVEL changes (RSSI fluctuates constantly), with direction, plus a cooldown so a
// value hovering at a threshold doesn't spam.
// F20 (Plan B): macOS Tahoe does NOT deliver CWEventTypeLinkQualityDidChange, so we poll
// the RSSI on a timer instead. Fires every ~12s (App Nap is disabled, so it's reliable),
// reads the live RSSI, and reports only when the signal BAR LEVEL changes.
// Configured WiFi signal poll interval (seconds), clamped to [MIN, MAX], default if unset.
-(NSTimeInterval)signalPollInterval {
	id stored = [[NSUserDefaults standardUserDefaults] objectForKey:HWG_WIFI_POLL_KEY];
	NSTimeInterval v = stored ? [[NSUserDefaults standardUserDefaults] doubleForKey:HWG_WIFI_POLL_KEY] : HWG_WIFI_POLL_DEFAULT;
	if (v < HWG_WIFI_POLL_MIN) v = HWG_WIFI_POLL_MIN;
	if (v > HWG_WIFI_POLL_MAX) v = HWG_WIFI_POLL_MAX;
	return v;
}

// Configured rate-limit between two signal-change notifications, clamped to [MIN, MAX].
-(NSTimeInterval)signalCooldownInterval {
	id stored = [[NSUserDefaults standardUserDefaults] objectForKey:HWG_WIFI_COOLDOWN_KEY];
	NSTimeInterval v = stored ? [[NSUserDefaults standardUserDefaults] doubleForKey:HWG_WIFI_COOLDOWN_KEY] : HWG_WIFI_COOLDOWN_DEFAULT;
	if (v < HWG_WIFI_COOLDOWN_MIN) v = HWG_WIFI_COOLDOWN_MIN;
	if (v > HWG_WIFI_COOLDOWN_MAX) v = HWG_WIFI_COOLDOWN_MAX;
	return v;
}

-(void)restartSignalPollTimer {
	[signalPollTimer invalidate];
	self.signalPollTimer = [NSTimer scheduledTimerWithTimeInterval:[self signalPollInterval]
	                                                        target:self
	                                                      selector:@selector(pollWifiSignal:)
	                                                      userInfo:nil
	                                                       repeats:YES];
}

-(void)pollWifiSignal:(NSTimer *)timer {
	CWInterface *iface = [self.wifiClient interface];
	if (!(iface && [iface powerOn] && [iface interfaceMode] == kCWInterfaceModeStation)) {
		self.lastReportedWifiBars = -1;   // not associated → re-baseline on reconnect
		return;
	}
	NSInteger rssi = [iface rssiValue];
	if (rssi == 0) return;

	NSInteger bars = [self wifiBarsForRSSI:rssi];

	if (lastReportedWifiBars < 0) {   // first sample after connect → baseline, don't notify
		self.lastReportedWifiBars = bars;
		return;
	}
	if (bars == lastReportedWifiBars) return;   // no level change

	// Rate-limit so a value hovering at a threshold doesn't spam. Don't update the baseline
	// while in cooldown, so a later poll still catches the net change (and flapping back to
	// the old level self-cancels since then bars == lastReportedWifiBars).
	NSTimeInterval cooldown = [self signalCooldownInterval];
	if (cooldown > 0 && lastSignalNoteTime && [[NSDate date] timeIntervalSinceDate:lastSignalNoteTime] < cooldown)
		return;

	BOOL improved = (bars > lastReportedWifiBars);
	NSString *ssid = [iface ssid] ?: (lastReportedSSID ?: NSLocalizedString(@"Wi-Fi", @""));
	NSString *arrow = improved ? @"↑" : @"↓";
	NSString *dir = improved ? NSLocalizedString(@"improved", @"WiFi signal got stronger")
	                         : NSLocalizedString(@"degraded", @"WiFi signal got weaker");
	NSString *desc = [NSString stringWithFormat:
		NSLocalizedString(@"%@\nSignal %@ %@ (%ld/4)", @"network name, arrow, improved/degraded, bars"),
		ssid, arrow, dir, (long)bars];
	NSData *iconData = [[NSImage imageNamed:[NSString stringWithFormat:@"Network-Wifi-%ld", (long)bars]] TIFFRepresentation];

	[delegate notifyWithName:@"AirportSignalChange"
						 title:NSLocalizedString(@"Wi-Fi Signal Changed", @"")
				 description:desc
						  icon:iconData
		  identifierString:@"HWGrowlAirPortSignal"
			  contextString:nil
						plugin:self];

	self.lastReportedWifiBars = bars;
	self.lastSignalNoteTime = [NSDate date];
}

-(void)fireOnLaunchNotes {
	[self interateInterfaces];
	[self fireCurrentWiFiState];
}

// At launch (only called when "Show existing" is enabled), announce the WiFi we're
// ALREADY connected to. CoreWLAN only delivers CHANGE events, so an already-up
// connection would otherwise never be reported — unlike volumes / IP, which do
// report at launch. startWiFiMonitoring only records lastReportedSSID silently.
-(void)fireCurrentWiFiState {
	CWInterface *iface = [self.wifiClient interface];
	if (!(iface && [iface powerOn] && [iface interfaceMode] == kCWInterfaceModeStation))
		return;

	NSString *ssid        = [iface ssid];   // nil if Location permission denied
	NSString *displayName = ssid ?: NSLocalizedString(@"Wi-Fi", @"");
	NSString *bssidStr    = [iface bssid];
	NSData   *bssidData   = nil;
	if (bssidStr) {
		unsigned int b[6] = {0};
		sscanf([bssidStr UTF8String], "%x:%x:%x:%x:%x:%x",
		       &b[0], &b[1], &b[2], &b[3], &b[4], &b[5]);
		unsigned char bytes[6] = {(unsigned char)b[0], (unsigned char)b[1],
		                          (unsigned char)b[2], (unsigned char)b[3],
		                          (unsigned char)b[4], (unsigned char)b[5]};
		bssidData = [NSData dataWithBytes:bytes length:6];
	}
	self.lastReportedSSID = displayName;
	[self airportConnected:displayName bssid:bssidData];
}

-(void)setupDynamicStore
{
   if(dynStore != NULL)
      return;
   
   SCDynamicStoreContext context = {0, (__bridge void *)self, NULL, NULL, NULL};
   
	dynStore = SCDynamicStoreCreate(kCFAllocatorDefault,
                                   CFBundleGetIdentifier(CFBundleGetMainBundle()),
                                   scCallback,
                                   &context);
	if (!dynStore) {
		NSLog(@"SCDynamicStoreCreate() failed: %s", SCErrorString(SCError()));
	}
   
   rlSrc = SCDynamicStoreCreateRunLoopSource(kCFAllocatorDefault, dynStore, 0);
	CFRunLoopAddSource(CFRunLoopGetMain(), rlSrc, kCFRunLoopDefaultMode);
   CFRelease(rlSrc);
}

-(void)startObserving
{
   [self setupDynamicStore];

    // AirPort key removed — WiFi events are now handled by CoreWLAN
    // (CWWiFiClient). Keeping it would fire duplicate disconnect notifications.
    // Wired/Ethernet link up/down: watch EVERY interface's own ".../Link" key via a
    // pattern (not a literal key, since we don't know interface names up front) — this is
    // the raw physical-link/carrier state, independent of DHCP/IP (see property comment
    // above for why NWPathMonitor was reverted).
    NSArray *watchedKeys = [NSArray arrayWithObjects:@"State:/Network/Global/IPv4", @"State:/Network/Global/IPv6", nil];
    NSArray *watchedPatterns = [NSArray arrayWithObject:@"State:/Network/Interface/[^/]+/Link"];
	if (!SCDynamicStoreSetNotificationKeys(dynStore,
                                          (__bridge CFArrayRef)watchedKeys,
                                          (__bridge CFArrayRef)watchedPatterns))
   {
		NSLog(@"SCDynamicStoreSetNotificationKeys() failed: %s", SCErrorString(SCError()));
		CFRelease(dynStore);
		dynStore = NULL;
	}

	[self primeWiredLinkState];
}

// Extracts the BSD interface name (e.g. "en0") from a "State:/Network/Interface/<bsd>/Link" key.
-(NSString *)bsdNameFromLinkKey:(NSString *)key {
	NSArray *parts = [key componentsSeparatedByString:@"/"];
	if ([parts count] < 2) return nil;
	return parts[[parts count] - 2];
}

// Reads the raw link-active bit for one interface's ".../Link" key. This reflects
// carrier/link presence alone — no IP, no DHCP, no route involved.
-(BOOL)readLinkActiveForKey:(NSString *)key {
	CFDictionaryRef d = SCDynamicStoreCopyValue(dynStore, (__bridge CFStringRef)key);
	if (!d) return NO;
	NSDictionary *dict = (__bridge_transfer NSDictionary *)d;
	return [dict[(__bridge NSString *)kSCPropNetLinkActive] boolValue];
}

// Watching EVERY interface's ".../Link" key (needed to fix the DHCP/static-IP bugs above)
// picks up more than physical Ethernet: en0 is WiFi on Apple Silicon Macs (already reported
// separately via CoreWLAN/"AirPort Connected") and awdl0 is AWDL (Apple Wireless Direct
// Link — AirDrop/Handoff/Continuity), which flaps constantly in the background and isn't a
// cable a user connected. Filter to interfaces SCNetworkInterface itself classifies as
// Ethernet — this is the same registry System Settings' Network pane reads, so it correctly
// includes USB/Thunderbolt-Ethernet adapters (which register as Ethernet-type) without
// hardcoding interface-name prefixes.
// F33: configurable from Preferences → Modules → Network Monitor ("Also report Wi-Fi's own
// link and AWDL/AirDrop events") — off by default, matching the original hardcoded filter.
-(BOOL)isWiredEthernetInterface:(NSString *)bsdName {
	if ([self boolForKey:HWG_ETH_SHOW_ALL_KEY default:NO]) return YES;
	BOOL isEthernet = NO;
	CFArrayRef ifaces = SCNetworkInterfaceCopyAll();
	if (ifaces) {
		for (CFIndex i = 0; i < CFArrayGetCount(ifaces); i++) {
			SCNetworkInterfaceRef iface = (SCNetworkInterfaceRef)CFArrayGetValueAtIndex(ifaces, i);
			NSString *bsd = (__bridge NSString *)SCNetworkInterfaceGetBSDName(iface);
			if (bsd && [bsd isEqualToString:bsdName]) {
				NSString *type = (__bridge NSString *)SCNetworkInterfaceGetInterfaceType(iface);
				isEthernet = [type isEqualToString:(__bridge NSString *)kSCNetworkInterfaceTypeEthernet];
				break;
			}
		}
		CFRelease(ifaces);
	}
	return isEthernet;
}

// At launch: read the CURRENT raw link state of every WIRED ETHERNET interface (by listing
// all existing ".../Link" keys and filtering out WiFi/AWDL/other virtual ones), and report
// the ones already up — mirrors what fireOnLaunchNotes does for IP/WiFi. Gated by
// onLaunchEnabled, same as before.
-(void)primeWiredLinkState {
	CFArrayRef keys = SCDynamicStoreCopyKeyList(dynStore, CFSTR("State:/Network/Interface/[^/]+/Link"));
	if (!keys) return;
	BOOL announce = [delegate onLaunchEnabled];
	CFIndex count = CFArrayGetCount(keys);
	for (CFIndex i = 0; i < count; i++) {
		NSString *key = (__bridge NSString *)CFArrayGetValueAtIndex(keys, i);
		NSString *ifname = [self bsdNameFromLinkKey:key];
		if (!ifname || ![self isWiredEthernetInterface:ifname] || ![self readLinkActiveForKey:key]) continue;
		if (announce) {
			[self updateInterface:ifname forType:HWGEthernetInterface withStatus:@{@"Active": @1}];
		} else {
			HWGrowlNetworkInterfaceStatus *st = [[HWGrowlNetworkInterfaceStatus alloc]
				initForInterface:ifname ofType:HWGEthernetInterface withStatus:@{@"Active": @1}];
			[networkInterfaceStates setObject:st forKey:ifname];
		}
	}
	CFRelease(keys);
}

// Fired by scCallback for a changed ".../Link" key: ignore anything that isn't a real wired
// Ethernet interface (see isWiredEthernetInterface: above), then feed the existing
// updateInterface: flow (dedup against the previous state happens there).
-(void)handleLinkKeyChanged:(NSString *)key {
	NSString *ifname = [self bsdNameFromLinkKey:key];
	if (!ifname || ![self isWiredEthernetInterface:ifname]) return;
	BOOL active = [self readLinkActiveForKey:key];
	[self updateInterface:ifname forType:HWGEthernetInterface withStatus:@{@"Active": @(active)}];
}

-(void)updateInterface:(NSString*)interface forType:(NetworkInterfaceType)type withStatus:(NSDictionary*)status {
	HWGrowlNetworkInterfaceStatus *new = [[HWGrowlNetworkInterfaceStatus alloc] initForInterface:interface
																														ofType:type
																												  withStatus:status];
	if(type == HWGAirPortInterface)
		[self updateAirportWithInterface:new];
	else if(type == HWGEthernetInterface)
		[self updateLinkWithInterface:new];
	
	[networkInterfaceStates setObject:new forKey:interface];
}

-(void)updateAirportWithInterface:(HWGrowlNetworkInterfaceStatus*)interface {
	NSString *interfaceString = [interface interface];
	NSDictionary *newValue = [interface status];
	NSDictionary *existing = [(HWGrowlNetworkInterfaceStatus*)[networkInterfaceStates objectForKey:interfaceString] status];
	//	NSLog(CFSTR("AirPort event"));
	
	NSData *newBSSID = nil;
	if (newValue)
		newBSSID = [newValue objectForKey:@"BSSID"];
	
	NSData *oldBSSID = nil;
	if (existing)
		oldBSSID = [existing objectForKey:@"BSSID"];
		
	if (newValue && ![oldBSSID isEqualToData:newBSSID] && !(newBSSID && oldBSSID && CFEqual((__bridge CFTypeRef)oldBSSID, (__bridge CFTypeRef)newBSSID))) {
		NSNumber *linkStatus = [newValue objectForKey:@"Link Status"];
		NSNumber *powerStatus = [newValue objectForKey:@"Power Status"];
		if (linkStatus || powerStatus) {
			int status = 0;
			if (linkStatus) {
				status = [linkStatus intValue];
			} else if (powerStatus) {
				status = [powerStatus intValue];
				status = !status;
			}
			NSString *networkName = nil;
			if (status == AIRPORT_DISCONNECTED) {
				networkName = [existing objectForKey:@"SSID_STR"];
				if (!networkName)
					networkName = [existing objectForKey:@"SSID"];
				if(networkName)
                    [self airportDisconnected:networkName];
			} else {
				networkName = [newValue objectForKey:@"SSID_STR"];
				if (!networkName)
					networkName = [newValue objectForKey:@"SSID"];
				if(networkName && newBSSID){
					[self airportConnected:networkName bssid:newBSSID];
				}
			}
		}
	}
}

-(void)airportDisconnected:(NSString*)networkName {
	NSData *iconData = [[NSImage imageNamed:@"Network-Wifi-Off"] TIFFRepresentation];
    [delegate notifyWithName:@"AirportDisconnected"
							 title:NSLocalizedString(@"AirPort Disconnected", @"")
					 description:[NSString stringWithFormat:NSLocalizedString(@"Left network %@.", @""), networkName]
							  icon:iconData
			  identifierString:@"HWGrowlAirPort"
				  contextString:nil 
							plugin:self];
}

// Map a Wi-Fi RSSI (dBm — negative, closer to 0 is stronger) to a bar level 0–4.
// rssi == 0 means "unavailable" → level 0 (the all-gray "no signal" icon).
-(NSInteger)wifiBarsForRSSI:(NSInteger)rssi {
	if (rssi == 0)        return 0;   // unavailable → gray "no signal" (Network-Wifi-0)
	else if (rssi >= -55) return 4;
	else if (rssi >= -65) return 3;
	else if (rssi >= -73) return 2;
	else if (rssi >= -80) return 1;
	else                  return 0;
}

// Icon name for the current signal. rssiValue does NOT require Location permission.
-(NSString*)wifiIconNameForCurrentSignal {
	CWInterface *iface = [self.wifiClient interface];
	NSInteger rssi = iface ? [iface rssiValue] : 0;
	return [NSString stringWithFormat:@"Network-Wifi-%ld", (long)[self wifiBarsForRSSI:rssi]];
}

// F33: generic reader for a per-field visibility toggle, defaulting to `def` when unset.
-(BOOL)boolForKey:(NSString *)key default:(BOOL)def {
	id stored = [[NSUserDefaults standardUserDefaults] objectForKey:key];
	return stored ? [stored boolValue] : def;
}

// "2.4 GHz" / "5 GHz" / "6 GHz". None of channelBand/activePHYMode/security require
// Location permission (unlike ssid/bssid) — they describe the RADIO/PROTOCOL, not the
// network's identity.
-(NSString*)wifiBandStringForChannel:(CWChannel*)channel {
	switch ([channel channelBand]) {
		case kCWChannelBand2GHz: return NSLocalizedString(@"2.4 GHz", @"");
		case kCWChannelBand5GHz: return NSLocalizedString(@"5 GHz", @"");
		case kCWChannelBand6GHz: return NSLocalizedString(@"6 GHz", @"");
		default:                 return NSLocalizedString(@"Unknown", @"");
	}
}

// Maps the 802.11 PHY mode to the consumer "Wi-Fi N" generation name most people
// recognize. 6GHz-band 802.11ax is marketed as "Wi-Fi 6E" rather than plain "Wi-Fi 6".
-(NSString*)wifiGenerationStringForPHYMode:(CWPHYMode)mode band:(CWChannelBand)band {
	switch (mode) {
		case kCWPHYMode11be: return NSLocalizedString(@"Wi-Fi 7", @"");
		case kCWPHYMode11ax: return (band == kCWChannelBand6GHz)
			? NSLocalizedString(@"Wi-Fi 6E", @"")
			: NSLocalizedString(@"Wi-Fi 6", @"");
		case kCWPHYMode11ac: return NSLocalizedString(@"Wi-Fi 5", @"");
		case kCWPHYMode11n:  return NSLocalizedString(@"Wi-Fi 4", @"");
		case kCWPHYMode11a:
		case kCWPHYMode11b:
		case kCWPHYMode11g:  return NSLocalizedString(@"Legacy 802.11", @"");
		default:             return NSLocalizedString(@"Unknown", @"");
	}
}

-(NSString*)wifiSecurityStringForSecurity:(CWSecurity)security {
	switch (security) {
		case kCWSecurityNone:               return NSLocalizedString(@"Open (no security)", @"");
		case kCWSecurityWEP:
		case kCWSecurityDynamicWEP:          return @"WEP";
		case kCWSecurityWPAPersonal:
		case kCWSecurityWPAPersonalMixed:    return @"WPA Personal";
		case kCWSecurityWPA2Personal:
		case kCWSecurityPersonal:            return @"WPA2 Personal";
		case kCWSecurityWPA3Personal:        return @"WPA3 Personal";
		case kCWSecurityWPA3Transition:      return @"WPA2/WPA3 Personal";
		case kCWSecurityWPAEnterprise:
		case kCWSecurityWPAEnterpriseMixed:  return @"WPA Enterprise";
		case kCWSecurityWPA2Enterprise:
		case kCWSecurityEnterprise:          return @"WPA2 Enterprise";
		case kCWSecurityWPA3Enterprise:      return @"WPA3 Enterprise";
		case kCWSecurityOWE:
		case kCWSecurityOWETransition:       return NSLocalizedString(@"Enhanced Open (OWE)", @"");
		default:                             return NSLocalizedString(@"Unknown", @"");
	}
}

// F33: builds the "Band:"/"Wi-Fi:"/"Security:" lines for the current connection —
// EACH individually toggleable from Preferences → Modules → Network Monitor. Band and
// generation combine onto one line ("Band: 5 GHz (Wi-Fi 6)") when both are enabled;
// otherwise each gets its own line. Returns nil if nothing is enabled or the interface
// isn't associated.
-(NSString*)wifiExtraInfoLines {
	BOOL showBand = [self boolForKey:HWG_WIFI_SHOW_BAND_KEY default:YES];
	BOOL showGen  = [self boolForKey:HWG_WIFI_SHOW_GENERATION_KEY default:YES];
	BOOL showSec  = [self boolForKey:HWG_WIFI_SHOW_SECURITY_KEY default:YES];
	if (!showBand && !showGen && !showSec) return nil;

	CWInterface *iface = [self.wifiClient interface];
	if (!iface) return nil;
	CWChannel *channel = [iface wlanChannel];
	if (!channel) return nil;

	NSString *band = [self wifiBandStringForChannel:channel];
	NSString *gen  = [self wifiGenerationStringForPHYMode:[iface activePHYMode] band:[channel channelBand]];
	NSString *sec  = [self wifiSecurityStringForSecurity:[iface security]];

	NSMutableArray *lines = [NSMutableArray array];
	if (showBand && showGen) {
		[lines addObject:[NSString stringWithFormat:
			NSLocalizedString(@"Band:\t%@ (%@)", "First %@ = band e.g. '5 GHz', second %@ = generation e.g. 'Wi-Fi 6'"), band, gen]];
	} else if (showBand) {
		[lines addObject:[NSString stringWithFormat:NSLocalizedString(@"Band:\t%@", ""), band]];
	} else if (showGen) {
		[lines addObject:[NSString stringWithFormat:NSLocalizedString(@"Wi-Fi Generation:\t%@", ""), gen]];
	}
	if (showSec) {
		[lines addObject:[NSString stringWithFormat:NSLocalizedString(@"Security:\t%@", ""), sec]];
	}
	return [lines count] ? [lines componentsJoinedByString:@"\n"] : nil;
}

-(void)airportConnected:(NSString*)name bssid:(NSData*)data {
	BOOL showSSID  = [self boolForKey:HWG_WIFI_SHOW_SSID_KEY default:YES];
	BOOL showBSSID = [self boolForKey:HWG_WIFI_SHOW_BSSID_KEY default:YES];

	// BSSID is nil when Location permission is denied (macOS 10.14+). Build a
	// description with whatever info we have, never deref a NULL buffer.
	NSMutableArray *lines = [NSMutableArray arrayWithObject:NSLocalizedString(@"Joined network.", @"")];
	if (showSSID) {
		[lines addObject:[NSString stringWithFormat:NSLocalizedString(@"SSID:\t%@", ""), name]];
	}
	if (showBSSID && data && [data length] >= 6) {
		const unsigned char *bssidBytes = [data bytes];
		NSString *bssid = [NSString stringWithFormat:@"%02X:%02X:%02X:%02X:%02X:%02X",
								 bssidBytes[0], bssidBytes[1], bssidBytes[2],
								 bssidBytes[3], bssidBytes[4], bssidBytes[5]];
		[lines addObject:[NSString stringWithFormat:NSLocalizedString(@"BSSID:\t%@", ""), bssid]];
	}
	NSString *description = [lines componentsJoinedByString:@"\n"];

	NSString *extra = [self wifiExtraInfoLines];
	if (extra) description = [description stringByAppendingFormat:@"\n%@", extra];

	NSData *iconData = [[NSImage imageNamed:[self wifiIconNameForCurrentSignal]] TIFFRepresentation];

	[delegate notifyWithName:@"AirportConnected"
							 title:NSLocalizedString(@"AirPort Connected", @"")
					 description:description
							  icon:iconData
			  identifierString:@"HWGrowlAirPort"
				  contextString:nil
							plugin:self];
}

-(void)updateLinkWithInterface:(HWGrowlNetworkInterfaceStatus*)interface {
	NSString *interfaceString = [interface interface];
	NSDictionary *newValue = [interface status];
	NSDictionary *existing = [(HWGrowlNetworkInterfaceStatus*)[networkInterfaceStates objectForKey:interfaceString] status];
	int newActive = [[newValue objectForKey:@"Active"] intValue];
	int oldActive = [[existing objectForKey:@"Active"] intValue];
	
	NSString *noteName = nil;
	NSString *noteTitle = nil;
	NSString *noteDescription = nil;
	NSString *imageName = nil;
	BOOL showInterface = [self boolForKey:HWG_ETH_SHOW_INTERFACE_KEY default:YES];
	BOOL showSpeed     = [self boolForKey:HWG_ETH_SHOW_SPEED_KEY default:YES];
	BOOL showMode      = [self boolForKey:HWG_ETH_SHOW_MODE_KEY default:YES];

	if (newActive && !oldActive) {
		// Use the Ethernet connector icon only for interfaces with a recognized Ethernet
		// media (e.g. "1000baseT/full-duplex"); unidentified interfaces (media "Unknown"
		// or unreadable — e.g. an iPhone/USB net interface) get a generic interface icon.
		NSString *mode = nil;
		NSString *speed = [self getMediaTypeForInterface:interfaceString mode:&mode];
		BOOL isEthernet = (speed != nil && ![speed hasPrefix:@"Unknown"]);
		[interfaceIsEthernet setObject:@(isEthernet) forKey:interfaceString];
		noteName = @"NetworkLinkUp";
		noteTitle = NSLocalizedString(@"Network Link Up", @"");

		NSMutableArray *lines = [NSMutableArray array];
		if (showInterface) [lines addObject:[NSString stringWithFormat:NSLocalizedString(@"Interface:\t%@", ""), interfaceString]];
		if (showSpeed)     [lines addObject:[NSString stringWithFormat:NSLocalizedString(@"Speed:\t%@", ""), speed ?: NSLocalizedString(@"Unknown", @"")]];
		if (showMode && mode) [lines addObject:[NSString stringWithFormat:NSLocalizedString(@"Mode:\t%@", ""), mode]];
		noteDescription = [lines count] ? [lines componentsJoinedByString:@"\n"] : nil;
		imageName = isEthernet ? @"Network-Ethernet-On" : @"Network-Interface-On";
	} else if (!newActive && oldActive) {
		// Match the icon family chosen when the interface came up (media is often
		// unreadable once it's down). Default to the generic interface icon.
		BOOL isEthernet = [[interfaceIsEthernet objectForKey:interfaceString] boolValue];
		[interfaceIsEthernet removeObjectForKey:interfaceString];
		noteName = @"NetworkLinkDown";
		noteTitle = NSLocalizedString(@"Network Link Down", @"");
		noteDescription = showInterface
			? [NSString stringWithFormat:NSLocalizedString(@"Interface:\t%@", nil), interfaceString]
			: nil;
		imageName = isEthernet ? @"Network-Ethernet-Off" : @"Network-Interface-Off";
	}
	
	NSData *iconData = [[NSImage imageNamed:imageName] TIFFRepresentation];
   
	if(noteName){
		[delegate notifyWithName:noteName
								 title:noteTitle
						 description:noteDescription
								  icon:iconData
				  identifierString:@"HWGrowlNetworkLink"
					  contextString:nil
								plugin:self];
	}
}

/* TO DO: REWRITE ME WITH BETTER METHODS OF GETTING INFO */
// Returns the media speed (e.g. "1000baseT"), and — via `outMode` — the duplex/other
// shared options (e.g. "full-duplex"), kept as SEPARATE pieces so the caller can label
// them individually ("Speed:" / "Mode:") instead of one combined "100baseT <full-duplex>"
// string. `outMode` is set to nil when there are no shared options to report.
- (NSString *)getMediaTypeForInterface:(NSString*)interfaceString mode:(NSString **)outMode {
	// This is all made by looking through Darwin's src/network_cmds/ifconfig.tproj.
	// There's no pretty way to get media stuff; I've stripped it down to the essentials
	// for what I'm doing.

	if (outMode) *outMode = nil;

	const char *interface = [interfaceString UTF8String];
	size_t length = strlen(interface);
	if (length >= IFNAMSIZ)
		NSLog(@"Interface name too long");

	int s = socket(AF_INET, SOCK_DGRAM, 0);
	if (s < 0) {
		NSLog(@"Can't open datagram socket");
		return NULL;
	}
	struct ifmediareq ifmr;
	memset(&ifmr, 0, sizeof(ifmr));
	strncpy(ifmr.ifm_name, interface, sizeof(ifmr.ifm_name));

	if (ioctl(s, SIOCGIFMEDIA, (caddr_t)&ifmr) < 0) {
		// Media not supported.
		close(s);
		return NULL;
	}

	close(s);

	// Now ifmr.ifm_current holds the selected type (probably auto-select)
	// ifmr.ifm_active holds details (100baseT <full-duplex> or similar)
	// We only want the ifm_active bit.

	const char *type = "Unknown";

	// We'll only look in the Ethernet list. I don't care about anything else.
	struct ifmedia_description *desc;
	for (desc = ifm_subtype_ethernet_descriptions; desc->ifmt_string; ++desc) {
		if (IFM_SUBTYPE(ifmr.ifm_active) == desc->ifmt_word) {
			type = desc->ifmt_string;
			break;
		}
	}

	NSMutableString *options = nil;

	// And fill in the duplex settings.
	for (desc = ifm_shared_option_descriptions; desc->ifmt_string; desc++) {
		if (ifmr.ifm_active & desc->ifmt_word) {
			if (options) {
				[options appendFormat:@",%s", desc->ifmt_string];
			} else {
				options = [NSMutableString stringWithUTF8String:desc->ifmt_string];
			}
		}
	}

	if (outMode) *outMode = options;

	return [NSString stringWithUTF8String:type];
}

// Counts the number of leading 1-bits in a 32-bit IPv4 netmask.
static int cidrBitsFromNetmaskV4(uint32_t netmask) {
	uint32_t hostOrder = ntohl(netmask);
	int bits = 0;
	while (hostOrder & 0x80000000) {
		bits++;
		hostOrder <<= 1;
	}
	return bits;
}

// Reads the IPv4 address + CIDR mask of every active interface (skips lo0,
// link-local 169.254.x). Returns array of dicts {@"ip": "x", @"cidr": "n"}.
- (NSArray *)collectIPv4InfoFromKernel {
	NSMutableArray *out = [NSMutableArray array];
	struct ifaddrs *interfaces = NULL;
	if (getifaddrs(&interfaces) != 0) return out;
	for (struct ifaddrs *cur = interfaces; cur != NULL; cur = cur->ifa_next) {
		if (!cur->ifa_addr || cur->ifa_addr->sa_family != AF_INET) continue;
		NSString *ifname = [NSString stringWithUTF8String:cur->ifa_name];
		if ([ifname isEqualToString:@"lo0"]) continue;
		struct sockaddr_in *sin = (struct sockaddr_in *)cur->ifa_addr;
		char buf[INET_ADDRSTRLEN] = {0};
		if (!inet_ntop(AF_INET, &sin->sin_addr, buf, sizeof(buf))) continue;
		NSString *ip = [NSString stringWithUTF8String:buf];
		if ([ip isEqualToString:@"127.0.0.1"]) continue;
		// 169.254.0.0/16 is APIPA / self-assigned: non-routable. We still show
		// it (the interface did acquire an address) but flag it as such.
		BOOL routable = ![ip hasPrefix:@"169.254."];
		int cidr = 0;
		if (cur->ifa_netmask) {
			struct sockaddr_in *mask = (struct sockaddr_in *)cur->ifa_netmask;
			cidr = cidrBitsFromNetmaskV4(mask->sin_addr.s_addr);
		}
		[out addObject:@{@"ip": ip, @"cidr": @(cidr), @"if": ifname, @"routable": @(routable)}];
	}
	freeifaddrs(interfaces);
	return out;
}

// Reads IPv6 addresses (skips ::1 loopback). fe80:: link-local are included
// but flagged non-routable so they can be labeled in the notification.
- (NSArray *)collectIPv6InfoFromKernel {
	NSMutableArray *out = [NSMutableArray array];
	struct ifaddrs *interfaces = NULL;
	if (getifaddrs(&interfaces) != 0) return out;
	for (struct ifaddrs *cur = interfaces; cur != NULL; cur = cur->ifa_next) {
		if (!cur->ifa_addr || cur->ifa_addr->sa_family != AF_INET6) continue;
		NSString *ifname = [NSString stringWithUTF8String:cur->ifa_name];
		if ([ifname isEqualToString:@"lo0"]) continue;
		struct sockaddr_in6 *sin = (struct sockaddr_in6 *)cur->ifa_addr;
		char buf[INET6_ADDRSTRLEN] = {0};
		if (!inet_ntop(AF_INET6, &sin->sin6_addr, buf, sizeof(buf))) continue;
		NSString *ip = [NSString stringWithUTF8String:buf];
		// strip the "%en0" scope suffix that link-local addresses carry
		NSRange pct = [ip rangeOfString:@"%"];
		if (pct.location != NSNotFound) ip = [ip substringToIndex:pct.location];
		if ([ip isEqualToString:@"::1"]) continue;    // loopback
		// fe80:: link-local is auto-generated on EVERY interface (utun, awdl,
		// llw, en…) and never carries useful signal — skip it entirely.
		if ([[ip lowercaseString] hasPrefix:@"fe80:"]) continue;
		[out addObject:@{@"ip": ip, @"routable": @(YES), @"if": ifname}];
	}
	freeifaddrs(interfaces);
	return out;
}

// Reads the gateway (Router) PER INTERFACE from SCDynamicStore, keyed by BSD interface
// name (e.g. "en0" -> "10.4.200.2"), by enumerating every network service's live State
// dictionary — "State:/Network/Service/<uuid>/IPv4" or ".../IPv6" — which each carry their
// own "InterfaceName" and "Router". This replaces reading only the single Global/IPv4(6)
// dictionary, which reflects just the system's ONE primary/default route: with multiple
// active interfaces on DIFFERENT subnets (e.g. Wi-Fi + a USB-Ethernet dock), the Global
// dictionary silently drops every gateway except the primary one. Per-service lookup
// reports every interface's own gateway, matching what's actually shown for each interface.
- (NSDictionary *)gatewaysByInterfaceForProtocol:(NSString *)proto {
	NSMutableDictionary *result = [NSMutableDictionary dictionary];
	NSString *pattern = [NSString stringWithFormat:@"State:/Network/Service/[^/]+/%@", proto];
	CFArrayRef keys = SCDynamicStoreCopyKeyList(dynStore, (__bridge CFStringRef)pattern);
	if (!keys) return result;
	CFIndex count = CFArrayGetCount(keys);
	for (CFIndex i = 0; i < count; i++) {
		CFStringRef key = CFArrayGetValueAtIndex(keys, i);
		CFDictionaryRef d = SCDynamicStoreCopyValue(dynStore, key);
		if (!d) continue;
		NSDictionary *dict = (__bridge NSDictionary *)d;
		NSString *ifname = dict[@"InterfaceName"];
		NSString *router = dict[@"Router"];
		if (ifname && router) result[ifname] = router;
		CFRelease(d);
	}
	CFRelease(keys);
	return result;
}

// Maps BSD interface names (en0, en1…) to friendly names (Wi-Fi, Ethernet…).
- (NSDictionary *)bsdToFriendlyNameMap {
	NSMutableDictionary *map = [NSMutableDictionary dictionary];
	CFArrayRef ifaces = SCNetworkInterfaceCopyAll();
	if (ifaces) {
		for (CFIndex i = 0; i < CFArrayGetCount(ifaces); i++) {
			SCNetworkInterfaceRef iface =
			    (SCNetworkInterfaceRef)CFArrayGetValueAtIndex(ifaces, i);
			NSString *bsd  = (__bridge NSString *)SCNetworkInterfaceGetBSDName(iface);
			NSString *name = (__bridge NSString *)SCNetworkInterfaceGetLocalizedDisplayName(iface);
			if (bsd && name) [map setObject:name forKey:bsd];
		}
		CFRelease(ifaces);
	}
	return map;
}

// F34 #4: BSD interface-name prefixes macOS uses for VPN/tunnel interfaces — "utun" covers
// IKEv2/IPSec, WireGuard, and most modern VPN clients (incl. the built-in VPN pane and
// third-party apps like Tunnelblick/NordVPN/etc.); "ppp" covers legacy PPTP/L2TP. This is a
// HEURISTIC, not a definitive check: macOS also uses utun for some non-VPN system services
// (e.g. Content Filter / Network Extension–based features), so a false positive is possible
// in principle — documented in README. A utun/ppp interface with NO address assigned yet
// (or one that lost its address) is not counted as "connected".
-(NSArray<NSString*> *)vpnLikeInterfaceNamesFromIPInfo:(NSArray *)ipv4Info ipv6:(NSArray *)ipv6Info {
	NSMutableSet<NSString*> *names = [NSMutableSet set];
	for (NSDictionary *info in ipv4Info) {
		NSString *ifname = info[@"if"];
		if ([ifname hasPrefix:@"utun"] || [ifname hasPrefix:@"ppp"] || [ifname hasPrefix:@"ipsec"]) {
			[names addObject:ifname];
		}
	}
	for (NSDictionary *info in ipv6Info) {
		NSString *ifname = info[@"if"];
		if ([ifname hasPrefix:@"utun"] || [ifname hasPrefix:@"ppp"] || [ifname hasPrefix:@"ipsec"]) {
			[names addObject:ifname];
		}
	}
	return [names allObjects];
}

// F34 #4: compares the current set of VPN-like interfaces against activeVPNInterfaceNames
// and fires a connect/disconnect notice for each TRANSITION. OFF by default.
-(void)checkVPNTransitionsWithIPv4Info:(NSArray *)ipv4Info ipv6Info:(NSArray *)ipv6Info {
	if (![self boolForKey:HWG_VPN_NOTIFY_KEY default:NO]) return;

	NSSet<NSString*> *currentNames = [NSSet setWithArray:[self vpnLikeInterfaceNamesFromIPInfo:ipv4Info ipv6:ipv6Info]];

	NSMutableSet<NSString*> *newlyConnected = [currentNames mutableCopy];
	[newlyConnected minusSet:self.activeVPNInterfaceNames];
	NSMutableSet<NSString*> *newlyDisconnected = [self.activeVPNInterfaceNames mutableCopy];
	[newlyDisconnected minusSet:currentNames];

	NSData *onIcon  = [[NSImage imageNamed:@"Network-Generic-On"] TIFFRepresentation];
	NSData *offIcon = [[NSImage imageNamed:@"Network-Generic-Off"] TIFFRepresentation];

	for (NSString *ifname in newlyConnected) {
		[delegate notifyWithName:@"VPNConnected"
								 title:NSLocalizedString(@"VPN Connected", @"")
						 description:[NSString stringWithFormat:NSLocalizedString(@"Interface:\t%@", @""), ifname]
								  icon:onIcon
				  identifierString:[NSString stringWithFormat:@"HWGrowlVPN-%@", ifname]
					  contextString:nil
								plugin:self];
	}
	for (NSString *ifname in newlyDisconnected) {
		[delegate notifyWithName:@"VPNDisconnected"
								 title:NSLocalizedString(@"VPN Disconnected", @"")
						 description:[NSString stringWithFormat:NSLocalizedString(@"Interface:\t%@", @""), ifname]
								  icon:offIcon
				  identifierString:[NSString stringWithFormat:@"HWGrowlVPN-%@", ifname]
					  contextString:nil
								plugin:self];
	}

	self.activeVPNInterfaceNames = [currentNames mutableCopy];
}

-(void)updateIP {
	NSDictionary *friendly     = [self bsdToFriendlyNameMap];
	NSArray  *ipv4Info         = [self collectIPv4InfoFromKernel];
	NSArray  *ipv6Info         = [self collectIPv6InfoFromKernel];
	[self checkVPNTransitionsWithIPv4Info:ipv4Info ipv6Info:ipv6Info];
	NSDictionary *ipv4Gateways = [self gatewaysByInterfaceForProtocol:@"IPv4"];
	NSDictionary *ipv6Gateways = [self gatewaysByInterfaceForProtocol:@"IPv6"];

	// F33: each field individually toggleable from Preferences → Modules → Network Monitor.
	// Routability still drives icon choice below regardless of what's actually displayed.
	BOOL showIPv4        = [self boolForKey:HWG_IP_SHOW_IPV4_KEY default:YES];
	BOOL showIPv6        = [self boolForKey:HWG_IP_SHOW_IPV6_KEY default:YES];
	BOOL showGateway     = [self boolForKey:HWG_IP_SHOW_GATEWAY_KEY default:YES];
	BOOL showNonRoutable = [self boolForKey:HWG_IP_SHOW_NONROUTABLE_KEY default:YES];
	BOOL useFriendly     = [self boolForKey:HWG_IP_USE_FRIENDLY_KEY default:YES];

	NSString *nonRoutableTag = NSLocalizedString(@"(non-routable)", @"");
	BOOL anyRoutable = NO;

	NSMutableArray *lines = [NSMutableArray array];
	for (NSDictionary *info in ipv4Info) {
		BOOL r = [info[@"routable"] boolValue];
		if (r) anyRoutable = YES;
		if (!showIPv4) continue;
		NSString *bsdName = info[@"if"];
		NSString *ifname = useFriendly ? (friendly[bsdName] ?: bsdName) : bsdName;
		[lines addObject:[NSString stringWithFormat:@"%@ — IPv4:\t%@/%@",
		                  ifname, info[@"ip"], info[@"cidr"]]];
		if (!r && showNonRoutable) [lines addObject:nonRoutableTag];   // tag on its own line
		// Each interface's own gateway (not just the system's single primary route) —
		// so a secondary interface (e.g. a USB-Ethernet dock on a different subnet)
		// still gets its gateway reported.
		NSString *gw = ipv4Gateways[bsdName];
		if (gw && showGateway) [lines addObject:[NSString stringWithFormat:NSLocalizedString(@"Gateway:\t%@", @""), gw]];
	}
	for (NSDictionary *info in ipv6Info) {
		BOOL r = [info[@"routable"] boolValue];
		if (r) anyRoutable = YES;
		if (!showIPv6) continue;
		NSString *bsdName = info[@"if"];
		NSString *ifname = useFriendly ? (friendly[bsdName] ?: bsdName) : bsdName;
		[lines addObject:[NSString stringWithFormat:@"%@ — IPv6:\t%@", ifname, info[@"ip"]]];
		if (!r && showNonRoutable) [lines addObject:nonRoutableTag];   // tag on its own line
		NSString *gw = ipv6Gateways[bsdName];
		if (gw && showGateway) [lines addObject:[NSString stringWithFormat:NSLocalizedString(@"Gateway:\t%@", @""), gw]];
	}

	NSString *combined = [lines componentsJoinedByString:@"\n"];
	BOOL hasAddressesNow = ([ipv4Info count] + [ipv6Info count]) > 0;

	// The "released" transition is decided from actual address PRESENCE (independent of
	// the F33 display toggles, which can make `combined` empty even with real addresses
	// still up); the displayed-text dedup below is separate and only skips a re-fire when
	// what would actually be SHOWN hasn't changed.
	if (!hasAddressesNow && !previousHasIPAddresses)
		return;   // fresh launch with no connection, or already reported "released"
	if (hasAddressesNow && [combined isEqualTo:previousIPCombined])
		return;   // addresses present but nothing in the visible text changed

	self.previousHasIPAddresses = hasAddressesNow;
	self.previousIPCombined = combined;

	NSString *description = nil;
	NSString *imageName   = nil;

	if (!hasAddressesNow) {
		description = NSLocalizedString(@"IP address released", @"");
		imageName   = @"Network-Generic-Off";
	} else {
		description = [combined length] ? combined : NSLocalizedString(@"IP address updated", @"");
		// Icon reflects whether we have real connectivity (a routable address)
		// or only self-assigned addresses.
		imageName   = anyRoutable ? @"Network-Generic-On" : @"Network-Generic-Off";
	}

	NSData *iconData = [[NSImage imageNamed:imageName] TIFFRepresentation];
	[delegate notifyWithName:@"IPAddressChange"
							 title:NSLocalizedString(@"IP Addresses Updated", @"")
					 description:description
							  icon:iconData
			  identifierString:@"HWGrowlIPAddressChange"
				  contextString:nil
							plugin:self];
}

- (void) interateInterfaces
{
    // Wired/Ethernet link priming at launch is handled by primeWiredLinkState (called from
    // startObserving before this runs). Here we just fire the current IP state (gated by
    // onLaunchEnabled via fireOnLaunchNotes).
    [self updateIP];
}

static void scCallback(SCDynamicStoreRef store, CFArrayRef changedKeys, void *info) {
	@autoreleasepool {
        HWGrowlNetworkMonitor *observer = (__bridge HWGrowlNetworkMonitor *)info;
        // Global IPv4/IPv6 keys (exact) + every interface's own ".../Link" key (pattern).
        [(__bridge NSArray*)changedKeys enumerateObjectsUsingBlock:^(NSString *key, NSUInteger idx, BOOL *stop) {
            if([key hasPrefix:@"State:/Network/Global"])
                [observer updateIP];
            else if ([key hasSuffix:@"/Link"])
                [observer handleLinkKeyChanged:key];
        }];
    }
}

#pragma mark HWGrowlPluginProtocol

// delegate accessors are auto-synthesized from the @property (weak).
-(NSString*)pluginDisplayName {
	return NSLocalizedString(@"Network Monitor", @"");
}
-(NSImage*)preferenceIcon {
	static NSImage *_icon = nil;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		_icon = [NSImage imageNamed:@"HWGPrefsNetwork"];
	});
	return _icon;
}
-(IBAction)signalIntervalChanged:(NSSlider*)sender {
	NSInteger secs = lround([sender doubleValue]);
	[[NSUserDefaults standardUserDefaults] setInteger:secs forKey:HWG_WIFI_POLL_KEY];
	self.intervalValueLabel.stringValue = [NSString stringWithFormat:@"%ld s", (long)secs];
	[self restartSignalPollTimer];   // apply the new interval immediately
}

-(IBAction)signalCooldownChanged:(NSSlider*)sender {
	NSInteger secs = lround([sender doubleValue]);
	[[NSUserDefaults standardUserDefaults] setInteger:secs forKey:HWG_WIFI_COOLDOWN_KEY];
	self.cooldownValueLabel.stringValue = (secs == 0)
		? NSLocalizedString(@"off", @"cooldown disabled")
		: [NSString stringWithFormat:@"%ld s", (long)secs];
}

// F33: single generic handler for every per-field visibility checkbox. Each checkbox's
// `identifier` carries the NSUserDefaults key it controls (set when the checkbox is built).
-(IBAction)fieldToggleChanged:(NSButton*)sender {
	NSString *key = sender.identifier;
	if (!key) return;
	[[NSUserDefaults standardUserDefaults] setBool:(sender.state == NSControlStateValueOn) forKey:key];
}

-(NSButton *)checkboxWithKey:(NSString *)key title:(NSString *)title defaultOn:(BOOL)defaultOn {
	NSButton *box = [NSButton checkboxWithTitle:title target:self action:@selector(fieldToggleChanged:)];
	box.identifier = key;
	box.state = [self boolForKey:key default:defaultOn] ? NSControlStateValueOn : NSControlStateValueOff;
	box.translatesAutoresizingMaskIntoConstraints = NO;
	return box;
}

// Wraps a fixed-height content view in a scroll view sized to fill whatever the tab
// control actually gives it — the container forces the top-level preferencePane to a
// fixed size that's shorter than 3 sections' worth of checkboxes, so content that doesn't
// fit scrolls instead of overflowing the tab's visible box.
-(NSScrollView *)scrollWrapping:(NSView *)content height:(CGFloat)height {
	NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:content.frame];
	scroll.hasVerticalScroller = YES;
	scroll.autohidesScrollers = YES;
	scroll.drawsBackground = NO;
	scroll.documentView = content;
	content.translatesAutoresizingMaskIntoConstraints = NO;
	[NSLayoutConstraint activateConstraints:@[
		[content.topAnchor      constraintEqualToAnchor:scroll.contentView.topAnchor],
		[content.leadingAnchor  constraintEqualToAnchor:scroll.contentView.leadingAnchor],
		[content.widthAnchor    constraintEqualToAnchor:scroll.contentView.widthAnchor],
		[content.heightAnchor   constraintEqualToConstant:height],
	]];
	return scroll;
}

-(NSTextField *)sectionHeaderWithTitle:(NSString *)title {
	NSTextField *h = [NSTextField labelWithString:title];
	h.font = [NSFont boldSystemFontOfSize:12];
	h.textColor = [NSColor secondaryLabelColor];
	h.translatesAutoresizingMaskIntoConstraints = NO;
	return h;
}

// Lays out a vertical stack of checkboxes (optionally preceded by other rows already
// pinned by the caller) inside `tab`, top-anchored to `topView`/`topAnchor`.
-(void)layoutRows:(NSArray<NSView*> *)rows inView:(NSView *)tab belowView:(NSView *)topView gap:(CGFloat)firstGap {
	NSView *previous = topView;
	CGFloat gap = firstGap;
	for (NSView *row in rows) {
		[tab addSubview:row];
		[NSLayoutConstraint activateConstraints:@[
			[row.topAnchor     constraintEqualToAnchor:previous == tab ? tab.topAnchor : previous.bottomAnchor constant:gap],
			[row.leadingAnchor  constraintEqualToAnchor:tab.leadingAnchor constant:16],
			[row.heightAnchor   constraintEqualToConstant:24],
		]];
		previous = row;
		gap = 8;
	}
}

-(NSView*)preferencePane {
	if (prefsView) return prefsView;

	NSTabView *tabs = [[NSTabView alloc] initWithFrame:NSMakeRect(0, 0, 420, 260)];
	// AppDelegate sizes this view once via -setFrameSize: to match the prefs window's
	// container, then never again — without an autoresizing mask this view (and its
	// visible tab box) stays whatever size it was created at even if the user later
	// resizes the Preferences window. Track the container's size going forward.
	tabs.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

	// --- Tab: Wi-Fi (also hosts the pre-existing signal-poll-interval slider) ---
	NSView *wifiTab = [[HWGFlippedContentView alloc] initWithFrame:NSMakeRect(0, 0, tabs.bounds.size.width, 420)];
	NSTimeInterval cur = [self signalPollInterval];

	NSTextField *title = [NSTextField labelWithString:NSLocalizedString(@"Wi-Fi signal check interval", @"")];
	title.font = [NSFont boldSystemFontOfSize:12];
	title.translatesAutoresizingMaskIntoConstraints = NO;

	NSSlider *slider = [NSSlider sliderWithValue:cur minValue:HWG_WIFI_POLL_MIN maxValue:HWG_WIFI_POLL_MAX
										  target:self action:@selector(signalIntervalChanged:)];
	slider.translatesAutoresizingMaskIntoConstraints = NO;

	NSTextField *value = [NSTextField labelWithString:[NSString stringWithFormat:@"%.0f s", cur]];
	self.intervalValueLabel = value;
	value.translatesAutoresizingMaskIntoConstraints = NO;

	NSTextField *caption = [NSTextField labelWithString:
		NSLocalizedString(@"How often the Wi-Fi signal strength is checked (5–60 s).", @"")];
	caption.textColor = [NSColor secondaryLabelColor];
	caption.font = [NSFont systemFontOfSize:11];
	caption.translatesAutoresizingMaskIntoConstraints = NO;

	// F20: rate-limit between two signal-change notifications, so a value hovering at a bar
	// threshold doesn't spam. Configurable — a 20s cooldown fixed regardless of poll interval
	// otherwise blocks a legitimate second signal change that follows shortly after the first.
	NSTimeInterval curCooldown = [self signalCooldownInterval];
	NSTextField *cooldownTitle = [NSTextField labelWithString:NSLocalizedString(@"Minimum time between signal-change notices", @"")];
	cooldownTitle.font = [NSFont boldSystemFontOfSize:12];
	cooldownTitle.translatesAutoresizingMaskIntoConstraints = NO;

	NSSlider *cooldownSlider = [NSSlider sliderWithValue:curCooldown minValue:HWG_WIFI_COOLDOWN_MIN maxValue:HWG_WIFI_COOLDOWN_MAX
												   target:self action:@selector(signalCooldownChanged:)];
	cooldownSlider.translatesAutoresizingMaskIntoConstraints = NO;

	NSTextField *cooldownValue = [NSTextField labelWithString:(curCooldown < 0.5)
		? NSLocalizedString(@"off", @"cooldown disabled")
		: [NSString stringWithFormat:@"%.0f s", curCooldown]];
	self.cooldownValueLabel = cooldownValue;
	cooldownValue.translatesAutoresizingMaskIntoConstraints = NO;

	NSTextField *cooldownCaption = [NSTextField labelWithString:
		NSLocalizedString(@"Prevents repeat notices if the signal hovers at a threshold (0–60 s, 0 = off).", @"")];
	cooldownCaption.textColor = [NSColor secondaryLabelColor];
	cooldownCaption.font = [NSFont systemFontOfSize:11];
	cooldownCaption.translatesAutoresizingMaskIntoConstraints = NO;

	NSTextField *wifiFieldsHeader = [self sectionHeaderWithTitle:NSLocalizedString(@"Notification fields", @"")];

	[wifiTab addSubview:title]; [wifiTab addSubview:slider]; [wifiTab addSubview:value]; [wifiTab addSubview:caption];
	[wifiTab addSubview:cooldownTitle]; [wifiTab addSubview:cooldownSlider]; [wifiTab addSubview:cooldownValue]; [wifiTab addSubview:cooldownCaption];
	[NSLayoutConstraint activateConstraints:@[
		[title.topAnchor      constraintEqualToAnchor:wifiTab.topAnchor constant:16],
		[title.leadingAnchor  constraintEqualToAnchor:wifiTab.leadingAnchor constant:16],
		[slider.topAnchor     constraintEqualToAnchor:title.bottomAnchor constant:12],
		[slider.leadingAnchor constraintEqualToAnchor:wifiTab.leadingAnchor constant:16],
		[slider.widthAnchor   constraintEqualToConstant:220],
		[value.centerYAnchor  constraintEqualToAnchor:slider.centerYAnchor],
		[value.leadingAnchor  constraintEqualToAnchor:slider.trailingAnchor constant:10],
		[caption.topAnchor     constraintEqualToAnchor:slider.bottomAnchor constant:6],
		[caption.leadingAnchor constraintEqualToAnchor:wifiTab.leadingAnchor constant:16],

		[cooldownTitle.topAnchor      constraintEqualToAnchor:caption.bottomAnchor constant:18],
		[cooldownTitle.leadingAnchor  constraintEqualToAnchor:wifiTab.leadingAnchor constant:16],
		[cooldownSlider.topAnchor     constraintEqualToAnchor:cooldownTitle.bottomAnchor constant:12],
		[cooldownSlider.leadingAnchor constraintEqualToAnchor:wifiTab.leadingAnchor constant:16],
		[cooldownSlider.widthAnchor   constraintEqualToConstant:220],
		[cooldownValue.centerYAnchor  constraintEqualToAnchor:cooldownSlider.centerYAnchor],
		[cooldownValue.leadingAnchor  constraintEqualToAnchor:cooldownSlider.trailingAnchor constant:10],
		[cooldownCaption.topAnchor     constraintEqualToAnchor:cooldownSlider.bottomAnchor constant:6],
		[cooldownCaption.leadingAnchor constraintEqualToAnchor:wifiTab.leadingAnchor constant:16],
	]];
	[wifiTab addSubview:wifiFieldsHeader];
	[NSLayoutConstraint activateConstraints:@[
		[wifiFieldsHeader.topAnchor     constraintEqualToAnchor:cooldownCaption.bottomAnchor constant:18],
		[wifiFieldsHeader.leadingAnchor  constraintEqualToAnchor:wifiTab.leadingAnchor constant:16],
	]];
	[self layoutRows:@[
		[self checkboxWithKey:HWG_WIFI_SHOW_SSID_KEY        title:NSLocalizedString(@"SSID (network name)", @"") defaultOn:YES],
		[self checkboxWithKey:HWG_WIFI_SHOW_BSSID_KEY       title:NSLocalizedString(@"BSSID (access point address)", @"") defaultOn:YES],
		[self checkboxWithKey:HWG_WIFI_SHOW_BAND_KEY        title:NSLocalizedString(@"Band (2.4/5/6 GHz)", @"") defaultOn:YES],
		[self checkboxWithKey:HWG_WIFI_SHOW_GENERATION_KEY  title:NSLocalizedString(@"Generation (Wi-Fi 4–7)", @"") defaultOn:YES],
		[self checkboxWithKey:HWG_WIFI_SHOW_SECURITY_KEY    title:NSLocalizedString(@"Security type", @"") defaultOn:YES],
	] inView:wifiTab belowView:wifiFieldsHeader gap:10];

	NSTabViewItem *wifiItem = [[NSTabViewItem alloc] initWithIdentifier:@"wifi"];
	wifiItem.label = NSLocalizedString(@"Wi-Fi", @"");
	wifiItem.view = [self scrollWrapping:wifiTab height:420];
	[tabs addTabViewItem:wifiItem];

	// --- Tab: Ethernet ---
	NSView *ethTab = [[HWGFlippedContentView alloc] initWithFrame:NSMakeRect(0, 0, tabs.bounds.size.width, 200)];
	NSTextField *ethHeader = [self sectionHeaderWithTitle:NSLocalizedString(@"Notification fields", @"")];
	[ethTab addSubview:ethHeader];
	[NSLayoutConstraint activateConstraints:@[
		[ethHeader.topAnchor     constraintEqualToAnchor:ethTab.topAnchor constant:16],
		[ethHeader.leadingAnchor  constraintEqualToAnchor:ethTab.leadingAnchor constant:16],
	]];
	[self layoutRows:@[
		[self checkboxWithKey:HWG_ETH_SHOW_INTERFACE_KEY title:NSLocalizedString(@"Interface name (en0, en5…)", @"") defaultOn:YES],
		[self checkboxWithKey:HWG_ETH_SHOW_SPEED_KEY     title:NSLocalizedString(@"Speed", @"") defaultOn:YES],
		[self checkboxWithKey:HWG_ETH_SHOW_MODE_KEY      title:NSLocalizedString(@"Mode / duplex", @"") defaultOn:YES],
		[self checkboxWithKey:HWG_ETH_SHOW_ALL_KEY       title:NSLocalizedString(@"Also report Wi-Fi's own link and AWDL/AirDrop events", @"") defaultOn:NO],
	] inView:ethTab belowView:ethHeader gap:10];

	NSTabViewItem *ethItem = [[NSTabViewItem alloc] initWithIdentifier:@"ethernet"];
	ethItem.label = NSLocalizedString(@"Ethernet", @"");
	ethItem.view = [self scrollWrapping:ethTab height:200];
	[tabs addTabViewItem:ethItem];

	// --- Tab: IP ---
	NSView *ipTab = [[HWGFlippedContentView alloc] initWithFrame:NSMakeRect(0, 0, tabs.bounds.size.width, 230)];
	NSTextField *ipHeader = [self sectionHeaderWithTitle:NSLocalizedString(@"Notification fields", @"")];
	[ipTab addSubview:ipHeader];
	[NSLayoutConstraint activateConstraints:@[
		[ipHeader.topAnchor     constraintEqualToAnchor:ipTab.topAnchor constant:16],
		[ipHeader.leadingAnchor  constraintEqualToAnchor:ipTab.leadingAnchor constant:16],
	]];
	[self layoutRows:@[
		[self checkboxWithKey:HWG_IP_SHOW_IPV4_KEY        title:NSLocalizedString(@"IPv4 address", @"") defaultOn:YES],
		[self checkboxWithKey:HWG_IP_SHOW_IPV6_KEY        title:NSLocalizedString(@"IPv6 address", @"") defaultOn:YES],
		[self checkboxWithKey:HWG_IP_SHOW_GATEWAY_KEY     title:NSLocalizedString(@"Gateway (per interface)", @"") defaultOn:YES],
		[self checkboxWithKey:HWG_IP_SHOW_NONROUTABLE_KEY title:NSLocalizedString(@"\"(non-routable)\" tag on self-assigned addresses", @"") defaultOn:YES],
		[self checkboxWithKey:HWG_IP_USE_FRIENDLY_KEY     title:NSLocalizedString(@"Use friendly interface names (vs. en0/en5…)", @"") defaultOn:YES],
	] inView:ipTab belowView:ipHeader gap:10];

	NSTabViewItem *ipItem = [[NSTabViewItem alloc] initWithIdentifier:@"ip"];
	ipItem.label = NSLocalizedString(@"IP", @"");
	ipItem.view = [self scrollWrapping:ipTab height:230];
	[tabs addTabViewItem:ipItem];

	// --- Tab: VPN (F34 #4 — split out of "Other" 22-jul-2026, own dedicated tab) ---
	NSView *vpnTab = [[HWGFlippedContentView alloc] initWithFrame:NSMakeRect(0, 0, tabs.bounds.size.width, 120)];
	NSTextField *vpnHeader = [self sectionHeaderWithTitle:NSLocalizedString(@"VPN detection (F34)", @"")];
	[vpnTab addSubview:vpnHeader];
	[NSLayoutConstraint activateConstraints:@[
		[vpnHeader.topAnchor     constraintEqualToAnchor:vpnTab.topAnchor constant:16],
		[vpnHeader.leadingAnchor  constraintEqualToAnchor:vpnTab.leadingAnchor constant:16],
	]];
	// F34 #4: OFF by default — new notification, and detection is a heuristic (utun/ppp/ipsec
	// interface name prefix), not a guaranteed "this is definitely a VPN" signal.
	NSButton *vpnRow = [self checkboxWithKey:HWG_VPN_NOTIFY_KEY title:NSLocalizedString(@"Notify when a VPN connects/disconnects", @"") defaultOn:NO];
	[self layoutRows:@[vpnRow] inView:vpnTab belowView:vpnHeader gap:10];

	NSTextField *vpnCaption = [NSTextField wrappingLabelWithString:
		NSLocalizedString(@"Detected via utun/ppp/ipsec virtual interfaces (used by most VPN clients, incl. macOS's built-in VPN and third-party apps). This is a heuristic — some non-VPN system features can also use a utun interface. See README for details.", @"")];
	vpnCaption.textColor = [NSColor secondaryLabelColor];
	vpnCaption.font = [NSFont systemFontOfSize:11];
	vpnCaption.translatesAutoresizingMaskIntoConstraints = NO;
	vpnCaption.preferredMaxLayoutWidth = 360;
	[vpnTab addSubview:vpnCaption];
	[NSLayoutConstraint activateConstraints:@[
		[vpnCaption.topAnchor     constraintEqualToAnchor:vpnRow.bottomAnchor constant:6],
		[vpnCaption.leadingAnchor  constraintEqualToAnchor:vpnTab.leadingAnchor constant:16],
		[vpnCaption.trailingAnchor constraintLessThanOrEqualToAnchor:vpnTab.trailingAnchor constant:-16],
	]];

	NSTabViewItem *vpnItem = [[NSTabViewItem alloc] initWithIdentifier:@"vpn"];
	vpnItem.label = NSLocalizedString(@"VPN", @"");
	vpnItem.view = [self scrollWrapping:vpnTab height:120];
	[tabs addTabViewItem:vpnItem];

	// --- Tab: Other (catch-all reserved for FUTURE fields that don't fit Wi-Fi/Ethernet/IP/VPN) ---
	NSView *otherTab = [[HWGFlippedContentView alloc] initWithFrame:NSMakeRect(0, 0, tabs.bounds.size.width, 120)];
	NSTextField *otherPlaceholder = [NSTextField labelWithString:
		NSLocalizedString(@"No additional fields yet.", @"")];
	otherPlaceholder.textColor = [NSColor secondaryLabelColor];
	otherPlaceholder.font = [NSFont systemFontOfSize:12];
	otherPlaceholder.translatesAutoresizingMaskIntoConstraints = NO;
	[otherTab addSubview:otherPlaceholder];
	[NSLayoutConstraint activateConstraints:@[
		[otherPlaceholder.topAnchor     constraintEqualToAnchor:otherTab.topAnchor constant:16],
		[otherPlaceholder.leadingAnchor  constraintEqualToAnchor:otherTab.leadingAnchor constant:16],
	]];

	NSTabViewItem *otherItem = [[NSTabViewItem alloc] initWithIdentifier:@"other"];
	otherItem.label = NSLocalizedString(@"Other", @"");
	otherItem.view = [self scrollWrapping:otherTab height:120];
	[tabs addTabViewItem:otherItem];

	prefsView = tabs;
	return prefsView;
}

#pragma mark HWGrowlPluginNotifierProtocol

-(NSArray*)noteNames {
	return [NSArray arrayWithObjects:@"IPAddressChange", @"NetworkLinkUp", @"NetworkLinkDown", @"AirportConnected", @"AirportDisconnected", @"AirportSignalChange", @"VPNConnected", @"VPNDisconnected", nil];
}
-(NSDictionary*)localizedNames {
	return [NSDictionary dictionaryWithObjectsAndKeys:NSLocalizedString(@"IP Address Changed", @""), @"IPAddressChange",
			  NSLocalizedString(@"Network Link Up", @""), @"NetworkLinkUp",
			  NSLocalizedString(@"Network Link Down", @""), @"NetworkLinkDown",
			  NSLocalizedString(@"AirPort Connected", @""), @"AirportConnected",
			  NSLocalizedString(@"AirPort Disconnected", @""), @"AirportDisconnected",
			  NSLocalizedString(@"Wi-Fi Signal Changed", @""), @"AirportSignalChange",
			  NSLocalizedString(@"VPN Connected", @""), @"VPNConnected",
			  NSLocalizedString(@"VPN Disconnected", @""), @"VPNDisconnected", nil];
}
-(NSDictionary*)noteDescriptions {
	return [NSDictionary dictionaryWithObjectsAndKeys:NSLocalizedString(@"Sent when the systems IP address changes", @""), @"IPAddressChange",
			  NSLocalizedString(@"Sent when an Ethernet link starts", @""), @"NetworkLinkUp",
			  NSLocalizedString(@"Sent when an Ethernet link goes down", @""), @"NetworkLinkDown",
			  NSLocalizedString(@"Sent when AirPort connects to a network", @""), @"AirportConnected",
			  NSLocalizedString(@"Sent when AirPort disconnects from a network", @""), @"AirportDisconnected",
			  NSLocalizedString(@"Sent when the Wi-Fi signal strength level changes", @""), @"AirportSignalChange",
			  NSLocalizedString(@"Sent when a VPN tunnel interface connects (F34, heuristic detection)", @""), @"VPNConnected",
			  NSLocalizedString(@"Sent when a VPN tunnel interface disconnects (F34, heuristic detection)", @""), @"VPNDisconnected", nil];
}
-(NSArray*)defaultNotifications {
	return [NSArray arrayWithObjects:@"IPAddressChange", @"NetworkLinkUp", @"NetworkLinkDown", @"AirportConnected", @"AirportDisconnected", @"AirportSignalChange", nil];
}

@end
