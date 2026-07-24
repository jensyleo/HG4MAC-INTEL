//
//  GrowlMiniDispatch.m
//
//  Created by Rachel Blackman on 7/13/11.
//

#import "GrowlMiniDispatch.h"
#import "GrowlMistWindowController.h"
#import "GrowlPositionController.h"
#import "GrowlPositioningDefines.h"

#import "GrowlDefines.h"
#import "GrowlDefinesInternal.h"
#import "GrowlApplicationBridge.h"
#import "GrowlApplicationBridge_Private.h"
#import "GrowlNote.h"
#import "GrowlNote_Private.h"

@implementation GrowlMiniDispatch

@synthesize windowDictionary;
@synthesize positionController;

+ (GrowlMiniDispatch*)sharedDispatch {
   static GrowlMiniDispatch *_sharedDispatch = nil;
   static dispatch_once_t onceToken;
   dispatch_once(&onceToken, ^{
      _sharedDispatch = [[GrowlMiniDispatch alloc] init];
   });
   return _sharedDispatch;
}

- (id)init {
	self = [super init];
	if (self) {
      self.windowDictionary = [NSMutableDictionary dictionary];
      
      [[UNUserNotificationCenter currentNotificationCenter] setDelegate:self];
	
		__block GrowlMiniDispatch *blockSelf = self;
		void (^screenChangeBlock)(NSNotification*) = ^(NSNotification *note){
			CGRect newRect = [[NSScreen mainScreen] visibleFrame];
			CGRect currentRect = [blockSelf.positionController screenFrame];
			if(!CGRectEqualToRect(newRect, currentRect))
			{
				if([blockSelf.positionController isFrameFree:[blockSelf.positionController screenFrame]])
					[blockSelf.positionController setScreenFrame:newRect];
				else{
					[blockSelf.positionController setUpdateFrame:YES];
					[blockSelf.positionController setNewFrame:newRect];
				}
			}
		};
		
		[[NSNotificationCenter defaultCenter] addObserverForName:NSApplicationDidChangeScreenParametersNotification
																		  object:nil
																			queue:[NSOperationQueue mainQueue]
																	 usingBlock:screenChangeBlock];
	}
	return self;
}

- (void)dealloc {
   [windowDictionary release]; windowDictionary = nil;
	[positionController release]; positionController = nil;
	[queuedWindows release]; queuedWindows = nil;
	[super dealloc];
}

- (void)queueWindow:(GrowlMistWindowController*)newWindow
{
	if(!queuedWindows)
		queuedWindows = [[NSMutableArray alloc] init];
	[queuedWindows addObject:newWindow];
}

- (BOOL)insertWindow:(GrowlMistWindowController*)newWindow
{	
	CGSize displaySize = [newWindow window].frame.size;
	displaySize.width += 10.0f;
	displaySize.height += 10.0f;
	CGRect found = [positionController canFindSpotForSize:displaySize
												  startingInPosition:GrowlTopRightCorner];
	if(!CGRectEqualToRect(found, CGRectZero)){
		[positionController occupyRect:found];
		[[newWindow window] setFrameOrigin:found.origin];
		[windowDictionary setObject:newWindow forKey:[newWindow uuid]];
		[newWindow fadeIn];
		return YES;
	}else{
		return NO;
	}
}

- (void)dequeueWindows
{
	if(!queuedWindows)
		return;
	
	NSMutableArray *toRemove = [NSMutableArray array];
	
	//We display them in order of receipt, if there is a note it can't display right now, we break and will catch it when there is space
	[queuedWindows enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
		if([self insertWindow:obj]){
			[toRemove addObject:obj];
		}else
			*stop = YES;
	}];
	
	//Mutable arrays don't like being mutated while being enumerated
	if([toRemove count] > 0)
		[queuedWindows removeObjectsInArray:toRemove];
	
	if([queuedWindows count] == 0){
		[queuedWindows release];
		queuedWindows = nil;
	}
}

+ (BOOL)copyNotificationCenter {
   BOOL useNotificationCenter = YES;
   BOOL alwaysCopyNC = NO;
   
   // Do we have notification center disabled?  (Only valid if it hasn't been turned on directly in Growl.)
   if (![[GrowlApplicationBridge sharedBridge] useNotificationCenterAlways]) {
      if (useNotificationCenter && [[NSUserDefaults standardUserDefaults] valueForKey:GROWL_FRAMEWORK_NOTIFICATIONCENTER_ENABLE])
         useNotificationCenter = [[NSUserDefaults standardUserDefaults] boolForKey:GROWL_FRAMEWORK_NOTIFICATIONCENTER_ENABLE];
   }
   
   // If we have notification center set to always-on, we must send.
   if (useNotificationCenter && ([[GrowlApplicationBridge sharedBridge] useNotificationCenterAlways]
                                 || [[NSUserDefaults standardUserDefaults] valueForKey:GROWL_FRAMEWORK_NOTIFICATIONCENTER_ALWAYS])) {
      alwaysCopyNC = ([[GrowlApplicationBridge sharedBridge] useNotificationCenterAlways] ||
                      ![[NSUserDefaults standardUserDefaults] boolForKey:GROWL_FRAMEWORK_NOTIFICATIONCENTER_ALWAYS]);
   }
   return alwaysCopyNC;
}
- (BOOL)displayNotification:(GrowlNote *)note force:(BOOL)force {
   BOOL result = [windowDictionary objectForKey:note.noteUUID] != nil;
   if(!result){
      result = [self sendNoteToApple:note force:force];
   }
   if(!result){
      result = [self sendNoteToMist:note force:force];
   }
   return result;
}

- (BOOL)sendNoteToMist:(GrowlNote*)note force:(BOOL)force {
   NSDictionary *noteDict = [note noteDictionary];
   
   if(!force){
      BOOL defaultOnly = YES;
      if([[NSUserDefaults standardUserDefaults] valueForKey:GROWL_FRAMEWORK_MIST_DEFAULT_ONLY])
         defaultOnly = [[[NSUserDefaults standardUserDefaults] valueForKey:GROWL_FRAMEWORK_MIST_DEFAULT_ONLY] boolValue];
      
      if (![[GrowlApplicationBridge sharedBridge] isNotificationDefaultEnabled:noteDict] && defaultOnly)
         return NO;
   }
   
   dispatch_async(dispatch_get_main_queue(), ^{
      NSString *title = [noteDict objectForKey:GROWL_NOTIFICATION_TITLE];
      NSString *text = [noteDict objectForKey:GROWL_NOTIFICATION_DESCRIPTION];
      BOOL sticky = [[noteDict objectForKey:GROWL_NOTIFICATION_STICKY] boolValue];
      NSImage *image = nil;
      
      NSData	*iconData = [noteDict objectForKey:GROWL_NOTIFICATION_ICON_DATA];
      if (!iconData)
         iconData = [noteDict objectForKey:GROWL_NOTIFICATION_APP_ICON_DATA];
      
      if (!iconData) {
         image = [NSApp applicationIconImage];
      }
      else if ([iconData isKindOfClass:[NSImage class]]) {
         image = (NSImage *)iconData;
      }
      else {
         image = [[[NSImage alloc] initWithData:iconData] autorelease];
      }
   
      GrowlMistWindowController *mistWindow = [[GrowlMistWindowController alloc] initWithNotificationTitle:title
                                                                                                      text:text
                                                                                                     image:image
                                                                                                    sticky:sticky
                                                                                                      uuid:[note noteUUID]
                                                                                                  delegate:self];
      
      if(![self insertWindow:mistWindow])
         [self queueWindow:mistWindow];
      [mistWindow release];
   });
   return YES;
}

- (BOOL)sendNoteToApple:(GrowlNote*)note force:(BOOL)force {
   NSDictionary *dict = note.noteDictionary;

   if (!force) {
      BOOL defaultOnly = YES;
      if ([[NSUserDefaults standardUserDefaults] valueForKey:GROWL_FRAMEWORK_NOTIFICATIONCENTER_DEFAULT_ONLY])
         defaultOnly = [[[NSUserDefaults standardUserDefaults] valueForKey:GROWL_FRAMEWORK_NOTIFICATIONCENTER_DEFAULT_ONLY] boolValue];
      if (![[GrowlApplicationBridge sharedBridge] isNotificationDefaultEnabled:dict] && defaultOnly)
         return NO;
   }

   NSString *uuid = note.noteUUID;
   dispatch_async(dispatch_get_main_queue(), ^{
      UNMutableNotificationContent *content = [[UNMutableNotificationContent alloc] init];
      content.title = [dict objectForKey:GROWL_NOTIFICATION_TITLE] ?: @"";
      content.body = [dict objectForKey:GROWL_NOTIFICATION_DESCRIPTION] ?: @"";
      NSMutableDictionary *userInfo = [NSMutableDictionary dictionaryWithObject:uuid forKey:GROWL_NOTIFICATION_INTERNAL_ID];
      if ([dict objectForKey:GROWL_NOTIFICATION_CLICK_CONTEXT])
         [userInfo setObject:[dict objectForKey:GROWL_NOTIFICATION_CLICK_CONTEXT] forKey:GROWL_NOTIFICATION_CLICK_CONTEXT];
      content.userInfo = userInfo;

      UNNotificationRequest *request = [UNNotificationRequest requestWithIdentifier:uuid
                                                                            content:content
                                                                            trigger:nil];
      [[UNUserNotificationCenter currentNotificationCenter] addNotificationRequest:request
                                                               withCompletionHandler:^(NSError *error) {
         if (error) NSLog(@"HWG MiniDispatch notification error: %@", error);
      }];
      [windowDictionary setObject:request forKey:uuid];
      [content release];

      if (![[dict objectForKey:GROWL_NOTIFICATION_STICKY] boolValue]) {
         NSInteger lifetime = 120;
         if ([[NSUserDefaults standardUserDefaults] valueForKey:GROWL_FRAMEWORK_NOTIFICATIONCENTER_DURATION])
            lifetime = [[NSUserDefaults standardUserDefaults] integerForKey:GROWL_FRAMEWORK_NOTIFICATIONCENTER_DURATION];
         if (lifetime) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(lifetime * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
               if ([windowDictionary objectForKey:uuid]) {
                  [[UNUserNotificationCenter currentNotificationCenter]
                     removeDeliveredNotificationsWithIdentifiers:@[uuid]];
                  [windowDictionary removeObjectForKey:uuid];
                  GrowlNote *n = [[GrowlApplicationBridge sharedBridge] noteForUUID:uuid];
                  [n handleStatusUpdate:GrowlNoteTimedOut];
               }
            });
         }
      }
   });
   return YES;
}

- (void)cancelNotification:(GrowlNote*)note {
   dispatch_async(dispatch_get_main_queue(), ^{
      id toCancel = [windowDictionary objectForKey:note.noteUUID];
      if([toCancel isKindOfClass:[UNNotificationRequest class]]){
         NSString *identifier = ((UNNotificationRequest*)toCancel).identifier;
         [[UNUserNotificationCenter currentNotificationCenter] removeDeliveredNotificationsWithIdentifiers:@[identifier]];
      }else if([toCancel isKindOfClass:[GrowlMistWindowController class]]){
         if([toCancel respondsToSelector:@selector(mistViewDismissed:)])
            [toCancel mistViewDismissed:YES];
      }
      [windowDictionary removeObjectForKey:note.noteUUID];
   });
}

- (void)clearWindowFrame:(GrowlMistWindowController*)window {
	CGRect padded = [window window].frame;
	padded.size.width += 10.0f;
	padded.size.height += 10.0f;
	[positionController vacateRect:padded];
	
	if([positionController updateFrame] && [positionController isFrameFree:[positionController screenFrame]]){
		[positionController setUpdateFrame:NO];
		[positionController setScreenFrame:[positionController newFrame]];
	}
}

- (void)mistWindow:(GrowlMistWindowController*)window statusUpdate:(GrowlNoteStatus)status {
   [window retain];
	[windowDictionary removeObjectForKey:[window uuid]];
	[self clearWindowFrame:window];
	
	[self dequeueWindows];
	
   GrowlNote *note = [[GrowlApplicationBridge sharedBridge] noteForUUID:[window uuid]];
   [note handleStatusUpdate:status];
	[window release];
}
- (void)mistNotificationDismissed:(GrowlMistWindowController *)window
{
   [self mistWindow:window statusUpdate:GrowlNoteTimedOut];
}

- (void)mistNotificationClicked:(GrowlMistWindowController *)window
{
   [self mistWindow:window statusUpdate:GrowlNoteClicked];
}

- (void)closeAllNotifications:(GrowlMistWindowController *)window
{
   [windowDictionary enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
      //For now this should only be called by GrowlMistWindowController
      if([obj isKindOfClass:[GrowlMistWindowController class]]){
         if([obj respondsToSelector:@selector(mistViewDismissed:)])
            [obj mistViewDismissed:YES];
      }
   }];
}

#pragma mark UNUserNotificationCenter delegate methods

- (void)userNotificationCenter:(UNUserNotificationCenter *)center
       willPresentNotification:(UNNotification *)notification
         withCompletionHandler:(void (^)(UNNotificationPresentationOptions))completionHandler {
   completionHandler(UNNotificationPresentationOptionBanner | UNNotificationPresentationOptionSound);
}

- (void)userNotificationCenter:(UNUserNotificationCenter *)center
didReceiveNotificationResponse:(UNNotificationResponse *)response
         withCompletionHandler:(void (^)(void))completionHandler {
   GrowlNoteStatus status;
   if ([response.actionIdentifier isEqualToString:UNNotificationDefaultActionIdentifier]) {
      status = GrowlNoteClicked;
   } else if ([response.actionIdentifier isEqualToString:UNNotificationDismissActionIdentifier]) {
      status = GrowlNoteTimedOut;
   } else {
      status = GrowlNoteClicked;
   }

   NSString *uuid = [response.notification.request.content.userInfo objectForKey:GROWL_NOTIFICATION_INTERNAL_ID];
   GrowlNote *note = [[[GrowlApplicationBridge sharedBridge] noteForUUID:uuid] retain];
   [windowDictionary removeObjectForKey:uuid];
   if (note) {
      [note handleStatusUpdate:status];
   } else {
      id context = [response.notification.request.content.userInfo objectForKey:GROWL_NOTIFICATION_CLICK_CONTEXT];
      [[GrowlApplicationBridge sharedBridge] context:context statusUpdate:status];
   }
   [[UNUserNotificationCenter currentNotificationCenter]
      removeDeliveredNotificationsWithIdentifiers:@[response.notification.request.identifier]];
   [note release];
   completionHandler();
}

@end
