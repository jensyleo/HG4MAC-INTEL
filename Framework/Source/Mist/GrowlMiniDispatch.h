//
//  GrowlMiniDispatch.h
//
//  Created by Rachel Blackman on 7/13/11.
//

#import <Cocoa/Cocoa.h>
#import <UserNotifications/UserNotifications.h>
#import "GrowlDefines.h"

@class GrowlNote;

@protocol GrowlMiniDispatchDelegate
@optional
- (void)growlNotificationWasClicked:(id)context;
- (void)growlNotificationTimedOut:(id)context;
@end

@class GrowlPositionController;

@interface GrowlMiniDispatch : NSObject <NSAnimationDelegate, UNUserNotificationCenterDelegate> {
	GrowlPositionController *positionController;
   NSMutableDictionary *windowDictionary;
	NSMutableArray *queuedWindows;
}

@property (nonatomic,retain) GrowlPositionController *positionController;
@property (nonatomic, retain) NSMutableDictionary *windowDictionary;

+ (GrowlMiniDispatch*)sharedDispatch;
+ (BOOL)copyNotificationCenter;
- (BOOL)displayNotification:(GrowlNote*)note force:(BOOL)force;
- (void)cancelNotification:(GrowlNote*)note;

@end
