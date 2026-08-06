//
//  HWGWifiSignal.m
//  HardwareGrowler
//

#import "HWGWifiSignal.h"

NSInteger HWGWifiBarsForRSSI(NSInteger rssi) {
	if (rssi == 0)        return 0;   // unavailable → gray "no signal" (Network-Wifi-0)
	else if (rssi >= -55) return 4;
	else if (rssi >= -65) return 3;
	else if (rssi >= -73) return 2;
	else if (rssi >= -80) return 1;
	else                  return 0;
}
