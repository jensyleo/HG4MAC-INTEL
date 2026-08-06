//
//  HWGWifiSignal.h
//  HardwareGrowler
//
//  Pure, dependency-free WiFi signal math extracted out of HWGrowlNetworkMonitor so it can
//  be unit tested without pulling in CoreWLAN/CoreLocation/the rest of the monitor's
//  dependency graph — see HardwareGrowlerTests/HWGrowlNetworkMonitorTests.m.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Maps a Wi-Fi RSSI (dBm — negative, closer to 0 is stronger) to a bar level 0-4.
// rssi == 0 means "unavailable" -> level 0 (the all-gray "no signal" icon).
FOUNDATION_EXPORT NSInteger HWGWifiBarsForRSSI(NSInteger rssi);

NS_ASSUME_NONNULL_END
