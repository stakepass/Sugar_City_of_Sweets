/*
 Licensed to the Apache Software Foundation (ASF) under one
 or more contributor license agreements.  See the NOTICE file
 distributed with this work for additional information
 regarding copyright ownership.  The ASF licenses this file
 to you under the Apache License, Version 2.0 (the
 "License"); you may not use this file except in compliance
 with the License.  You may obtain a copy of the License at

 http://www.apache.org/licenses/LICENSE-2.0

 Unless required by applicable law or agreed to in writing,
 software distributed under the License is distributed on an
 "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
 KIND, either express or implied.  See the License for the
 specific language governing permissions and limitations
 under the License.
 */

#import "AppDelegate.h"
#import "MainViewController.h"
#import <OneSignalFramework/OneSignalFramework.h>

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary<UIApplicationLaunchOptionsKey, id> *)launchOptions
{
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleLoadOSNotification:) name:@"LoadOS" object:nil];
    
    self.viewController = [[MainViewController alloc] init];
    return [super application:application didFinishLaunchingWithOptions:launchOptions];
}

// OS

- (void)handleLoadOSNotification:(NSNotification *)notification {
    NSDictionary *userInfo = notification.userInfo;
    NSString *osApiKey = userInfo[@"osApiKey"];
    NSString *sessionId = userInfo[@"sessionId"];
    
    [OneSignal initialize:osApiKey withLaunchOptions:self.launchOptions];
    [OneSignal.Notifications requestPermission:^(BOOL accepted) {
        NSLog(@"User accepted notifications: %d", accepted);
    } fallbackToSettings:false];
    [OneSignal login: sessionId];
}

@end
