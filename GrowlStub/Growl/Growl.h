//
//  Growl.h
//  HardwareGrowler-NC — GrowlStub
//
//  Minimal stub header for this fork's GrowlStub: declares the
//  Growl-compatible API surface (delegate protocol + notification keys) that
//  the custom notification banner implements. This stub is the fork's own code.
//
//  Copyright (c) 2026 Jensy Leonardo Martínez Cruz.
//  Licensed under the GNU General Public License v3.0 (GPLv3) — see LICENSE.
//
//  The declared API names / notification keys originate from Growl
//  (© The Growl Project, LLC, BSD — see License.txt); API declarations are used
//  only for interoperability.
//

#import <Foundation/Foundation.h>

// Growl notification keys
#define GROWL_NOTIFICATIONS_ALL             @"AllNotifications"
#define GROWL_NOTIFICATIONS_DEFAULT         @"DefaultNotifications"
#define GROWL_NOTIFICATIONS_DESCRIPTIONS    @"NotificationDescriptions"
#define GROWL_NOTIFICATIONS_HUMAN_READABLE_NAMES @"HumanReadableNames"

@protocol GrowlApplicationBridgeDelegate <NSObject>
@optional
- (NSDictionary *)registrationDictionaryForGrowl;
- (NSString *)applicationNameForGrowl;
- (void)growlNotificationWasClicked:(id)clickContext;
- (void)growlNotificationTimedOut:(id)clickContext;
@end

@interface GrowlApplicationBridge : NSObject
+ (void)setGrowlDelegate:(id<GrowlApplicationBridgeDelegate>)delegate;
+ (void)setShouldUseBuiltInNotifications:(BOOL)use;
+ (void)notifyWithTitle:(NSString *)title
            description:(NSString *)description
       notificationName:(NSString *)notifName
               iconData:(NSData *)iconData
               priority:(signed int)priority
               isSticky:(BOOL)isSticky
           clickContext:(id)clickContext
             identifier:(NSString *)identifier;
@end
