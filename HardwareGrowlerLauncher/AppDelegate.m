//
//  AppDelegate.m
//  HardwareGrowlerLauncher
//
//  Created by Daniel Siemer on 5/2/12.
//  Copyright (c) 2012 The Growl Project, LLC. All rights reserved.
//

#import "AppDelegate.h"

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification
{
   NSArray *growlInstances = [NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.jensyleo.hg4mac"];
   if(!growlInstances.count)
   {
      NSURL* appURL = [[[[NSBundle mainBundle] bundleURL] URLByAppendingPathComponent:@"../../../../Contents/MacOS/HG4MAC" isDirectory:NO] URLByResolvingSymlinksInPath];
      NSLog(@"Launching HG4MAC at URL: %@", appURL);
      // Modern replacement for the deprecated launchApplicationAtURL:options:
      // configuration:error:. Terminate only after the launch attempt returns.
      NSWorkspaceOpenConfiguration *conf = [NSWorkspaceOpenConfiguration configuration];
      [[NSWorkspace sharedWorkspace] openApplicationAtURL:appURL
                                            configuration:conf
                                        completionHandler:^(NSRunningApplication *app, NSError *error) {
         if (error) NSLog(@"%@", error);
         dispatch_async(dispatch_get_main_queue(), ^{ [NSApp terminate:nil]; });
      }];
      return;
   }
	[NSApp terminate:nil];
}

@end
