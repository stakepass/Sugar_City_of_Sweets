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

@import AVFoundation;
@import Foundation;
@import WebKit;

#import <objc/message.h>
#import <Foundation/NSCharacterSet.h>
#import <Cordova/CDV.h>
#import "CDVPlugin+Private.h"
#import <Cordova/CDVConfigParser.h>
#import <Cordova/NSDictionary+CordovaPreferences.h>
#import "CDVCommandDelegateImpl.h"

@interface CDVViewController () <CDVWebViewEngineConfigurationDelegate, UIGestureRecognizerDelegate, WKUIDelegate> { }

@property (nonatomic, readwrite, strong) NSXMLParser* configParser;
@property (nonatomic, readwrite, strong) NSMutableDictionary* settings;
@property (nonatomic, readwrite, strong) NSMutableDictionary* pluginObjects;
@property (nonatomic, readwrite, strong) NSMutableArray* startupPluginNames;
@property (nonatomic, readwrite, strong) NSDictionary* pluginsMap;
@property (nonatomic, readwrite, strong) id <CDVWebViewEngineProtocol> webViewEngine;
@property (nonatomic, readwrite, strong) UIView* launchView;
@property (nonatomic, strong) UIImageView *loadingView;
@property (nonatomic, strong) UIView *onboardingOverlayView;
@property (nonatomic, strong) UIImageView *onboardingImageView;
@property (nonatomic) int onboardingState;

@property (nonatomic, strong) WKWebView *popupWebView;
@property (nonatomic, assign) BOOL isPopupWebViewOpen;
@property (readwrite, assign) BOOL isStartLoadingMainPage;
@property (readwrite, assign) BOOL initialized;
@property (nonatomic, assign) BOOL isJavaScriptIconEvaluated;
@property (nonatomic, assign) UIInterfaceOrientationMask currentOrientation;

@property (atomic, strong) NSURL* openURL;

@end

@implementation CDVViewController

@synthesize supportedOrientations;
@synthesize pluginObjects, pluginsMap, startupPluginNames;
@synthesize configParser, settings;
@synthesize wwwFolderName, startPage, initialized, openURL;
@synthesize commandDelegate = _commandDelegate;
@synthesize commandQueue = _commandQueue;
@synthesize webViewEngine = _webViewEngine;
@dynamic webView;

- (void)__init
{
    if ((self != nil) && !self.initialized) {
        _commandQueue = [[CDVCommandQueue alloc] initWithViewController:self];
        _commandDelegate = [[CDVCommandDelegateImpl alloc] initWithViewController:self];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onAppWillTerminate:)
                                                     name:UIApplicationWillTerminateNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onAppWillResignActive:)
                                                     name:UIApplicationWillResignActiveNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onAppDidBecomeActive:)
                                                     name:UIApplicationDidBecomeActiveNotification object:nil];
        
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onAppWillEnterForeground:)
                                                     name:UIApplicationWillEnterForegroundNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onAppDidEnterBackground:)
                                                     name:UIApplicationDidEnterBackgroundNotification object:nil];
        
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onWebViewPageDidLoad:)
                                                     name:CDVPageDidLoadNotification object:nil];
        
        // read from UISupportedInterfaceOrientations (or UISupportedInterfaceOrientations~iPad, if its iPad) from -Info.plist
        self.supportedOrientations = [self parseInterfaceOrientations:
                                      [[[NSBundle mainBundle] infoDictionary] objectForKey:@"UISupportedInterfaceOrientations"]];
        
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleLoadTTNotification) name:@"LoadTT" object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleLoadMLNotification:) name:@"LoadML" object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleLoadLFNotification) name:@"LoadLF" object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleLoadUDNotification) name:@"LoadUD" object:nil];
        
        self.initialized = YES;
    }
}

- (id)initWithNibName:(NSString*)nibNameOrNil bundle:(NSBundle*)nibBundleOrNil
{
    self = [super initWithNibName:nibNameOrNil bundle:nibBundleOrNil];
    [self __init];
    return self;
}

- (id)initWithCoder:(NSCoder*)aDecoder
{
    self = [super initWithCoder:aDecoder];
    [self __init];
    return self;
}

- (id)init
{
    self = [super init];
    [self __init];
    return self;
}

-(NSString*)configFilePath{
    NSString* path = self.configFile ?: @"config.xml";
    
    // if path is relative, resolve it against the main bundle
    if(![path isAbsolutePath]){
        NSString* absolutePath = [[NSBundle mainBundle] pathForResource:path ofType:nil];
        if(!absolutePath){
            NSAssert(NO, @"ERROR: %@ not found in the main bundle!", path);
        }
        path = absolutePath;
    }
    
    // Assert file exists
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        NSAssert(NO, @"ERROR: %@ does not exist. Please run cordova-ios/bin/cordova_plist_to_config_xml path/to/project.", path);
        return nil;
    }
    
    return path;
}

- (void)parseSettingsWithParser:(NSObject <NSXMLParserDelegate>*)delegate
{
    // read from config.xml in the app bundle
    NSString* path = [self configFilePath];
    
    NSURL* url = [NSURL fileURLWithPath:path];
    
    self.configParser = [[NSXMLParser alloc] initWithContentsOfURL:url];
    if (self.configParser == nil) {
        NSLog(@"Failed to initialize XML parser.");
        return;
    }
    [self.configParser setDelegate:((id < NSXMLParserDelegate >)delegate)];
    [self.configParser parse];
}

- (void)loadSettings
{
    CDVConfigParser* delegate = [[CDVConfigParser alloc] init];
    
    [self parseSettingsWithParser:delegate];
    
    // Get the plugin dictionary, allowList and settings from the delegate.
    self.pluginsMap = delegate.pluginsDict;
    self.startupPluginNames = delegate.startupPluginNames;
    self.settings = delegate.settings;
    
    // And the start folder/page.
    if(self.wwwFolderName == nil){
        self.wwwFolderName = @"www";
    }
    if(delegate.startPage && self.startPage == nil){
        self.startPage = delegate.startPage;
    }
    if (self.startPage == nil) {
        self.startPage = @"index.html";
    }
    
    // Initialize the plugin objects dict.
    self.pluginObjects = [[NSMutableDictionary alloc] initWithCapacity:20];
}

- (NSURL*)appUrl
{
    NSURL* appURL = nil;
    
    if ([self.startPage rangeOfString:@"://"].location != NSNotFound) {
        appURL = [NSURL URLWithString:self.startPage];
    } else if ([self.wwwFolderName rangeOfString:@"://"].location != NSNotFound) {
        appURL = [NSURL URLWithString:[NSString stringWithFormat:@"%@/%@", self.wwwFolderName, self.startPage]];
    } else if([self.wwwFolderName rangeOfString:@".bundle"].location != NSNotFound){
        // www folder is actually a bundle
        NSBundle* bundle = [NSBundle bundleWithPath:self.wwwFolderName];
        appURL = [bundle URLForResource:self.startPage withExtension:nil];
    } else if([self.wwwFolderName rangeOfString:@".framework"].location != NSNotFound){
        // www folder is actually a framework
        NSBundle* bundle = [NSBundle bundleWithPath:self.wwwFolderName];
        appURL = [bundle URLForResource:self.startPage withExtension:nil];
    } else {
        // CB-3005 strip parameters from start page to check if page exists in resources
        NSURL* startURL = [NSURL URLWithString:self.startPage];
        NSString* startFilePath = [self.commandDelegate pathForResource:[startURL path]];
        
        if (startFilePath == nil) {
            appURL = nil;
        } else {
            appURL = [NSURL fileURLWithPath:startFilePath];
            // CB-3005 Add on the query params or fragment.
            NSString* startPageNoParentDirs = self.startPage;
            NSRange r = [startPageNoParentDirs rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"?#"] options:0];
            if (r.location != NSNotFound) {
                NSString* queryAndOrFragment = [self.startPage substringFromIndex:r.location];
                appURL = [NSURL URLWithString:queryAndOrFragment relativeToURL:appURL];
            }
        }
    }
    
    return appURL;
}

- (nullable NSURL*)errorURL
{
    NSURL* errorUrl = nil;
    
    id setting = [self.settings cordovaSettingForKey:@"ErrorUrl"];
    
    if (setting) {
        NSString* errorUrlString = (NSString*)setting;
        if ([errorUrlString rangeOfString:@"://"].location != NSNotFound) {
            errorUrl = [NSURL URLWithString:errorUrlString];
        } else {
            NSURL* url = [NSURL URLWithString:(NSString*)setting];
            NSString* errorFilePath = [self.commandDelegate pathForResource:[url path]];
            if (errorFilePath) {
                errorUrl = [NSURL fileURLWithPath:errorFilePath];
            }
        }
    }
    
    return errorUrl;
}

- (UIView*)webView
{
    if (self.webViewEngine != nil) {
        return self.webViewEngine.engineWebView;
    }
    
    return nil;
}

- (BOOL)prefersStatusBarHidden {
    return YES;
}

// Implement viewDidLoad to do additional setup after loading the view, typically from a nib.
- (void)viewDidLoad
{
    [super viewDidLoad];
    self.currentOrientation = UIInterfaceOrientationMaskPortrait;
    
    // Load settings
    [self loadSettings];
    
    // // Instantiate the Launch screen /////////
    
    if (!self.launchView) {
        [self createLaunchView];
    }
    
    // // Instantiate the WebView ///////////////
    
    if (!self.webView) {
        [self createGapView];
    }
    
    // /////////////////
    
    if ([self.startupPluginNames count] > 0) {
        [CDVTimer start:@"TotalPluginStartup"];
        
        for (NSString* pluginName in self.startupPluginNames) {
            [CDVTimer start:pluginName];
            [self getCommandInstance:pluginName];
            [CDVTimer stop:pluginName];
        }
        
        [CDVTimer stop:@"TotalPluginStartup"];
    }
    
    // /////////////////
    NSString *savedURL = [[NSUserDefaults standardUserDefaults] stringForKey:@"FinalPath"];
    
    if (savedURL) {
        NSURL *url = [NSURL URLWithString:savedURL];
        if (url) {
            NSURLRequest *request = [NSURLRequest requestWithURL:url];
            [self.webViewEngine loadRequest:request];
            [self setupBackground];
            [self setupLoading];
            [self handleLoadUDNotification];
            return;
        }
    } else {
        NSURL* appURL = [self appUrl];
        
        if (appURL) {
            NSURLRequest* appReq = [NSURLRequest requestWithURL:appURL cachePolicy:NSURLRequestUseProtocolCachePolicy timeoutInterval:20.0];
            [self.webViewEngine loadRequest:appReq];
        } else {
            NSString* loadErr = [NSString stringWithFormat:@"ERROR: Start Page at '%@/%@' was not found.", self.wwwFolderName, self.startPage];
            NSLog(@"%@", loadErr);
            
            NSURL* errorUrl = [self errorURL];
            if (errorUrl) {
                errorUrl = [NSURL URLWithString:[NSString stringWithFormat:@"?error=%@", [loadErr stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLPathAllowedCharacterSet]] relativeToURL:errorUrl];
                NSLog(@"%@", [errorUrl absoluteString]);
                [self.webViewEngine loadRequest:[NSURLRequest requestWithURL:errorUrl]];
            } else {
                NSString* html = [NSString stringWithFormat:@"<html><body> %@ </body></html>", loadErr];
                [self.webViewEngine loadHTMLString:html baseURL:nil];
            }
        }
        [self setupBackground];
        [self setupLoading];
    }
    // /////////////////
    
    if ([self.webViewEngine.engineWebView isKindOfClass:[WKWebView class]]) {
        WKWebView *webView = (WKWebView *)self.webViewEngine.engineWebView;
        webView.UIDelegate = self;
    }
    
}

- (nullable WKWebView *)webView:(WKWebView *)webView createWebViewWithConfiguration:(WKWebViewConfiguration *)configuration forNavigationAction:(WKNavigationAction *)navigationAction windowFeatures:(WKWindowFeatures *)windowFeatures {
    if (!navigationAction.targetFrame.isMainFrame) {
        if (!self.popupWebView) {
            self.popupWebView = [[WKWebView alloc] initWithFrame:self.view.bounds configuration:configuration];
            self.popupWebView.backgroundColor = [UIColor whiteColor];
            self.popupWebView.translatesAutoresizingMaskIntoConstraints = NO;
            [self.webView addSubview:self.popupWebView];
            [NSLayoutConstraint activateConstraints:@[
                [self.popupWebView.leadingAnchor constraintEqualToAnchor:self.webView.leadingAnchor],
                [self.popupWebView.trailingAnchor constraintEqualToAnchor:self.webView.trailingAnchor],
                [self.popupWebView.topAnchor constraintEqualToAnchor:self.webView.topAnchor],
                [self.popupWebView.bottomAnchor constraintEqualToAnchor:self.webView.bottomAnchor]
            ]];
            self.isPopupWebViewOpen = YES;
        }
        return self.popupWebView;
    }
    return nil;
}

-(void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [[NSNotificationCenter defaultCenter] postNotification:[NSNotification notificationWithName:CDVViewWillAppearNotification object:nil]];
}

-(void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    [[NSNotificationCenter defaultCenter] postNotification:[NSNotification notificationWithName:CDVViewDidAppearNotification object:nil]];
}

-(void)viewWillDisappear:(BOOL)animated
{
    [super viewWillDisappear:animated];
    [[NSNotificationCenter defaultCenter] postNotification:[NSNotification notificationWithName:CDVViewWillDisappearNotification object:nil]];
}

-(void)viewDidDisappear:(BOOL)animated
{
    [super viewDidDisappear:animated];
    [[NSNotificationCenter defaultCenter] postNotification:[NSNotification notificationWithName:CDVViewDidDisappearNotification object:nil]];
}

-(void)viewWillLayoutSubviews
{
    [super viewWillLayoutSubviews];
    [[NSNotificationCenter defaultCenter] postNotification:[NSNotification notificationWithName:CDVViewWillLayoutSubviewsNotification object:nil]];
}

-(void)viewDidLayoutSubviews
{
    [super viewDidLayoutSubviews];
    [[NSNotificationCenter defaultCenter] postNotification:[NSNotification notificationWithName:CDVViewDidLayoutSubviewsNotification object:nil]];
}

-(void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator
{
    [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
    [[NSNotificationCenter defaultCenter] postNotification:[NSNotification notificationWithName:CDVViewWillTransitionToSizeNotification object:[NSValue valueWithCGSize:size]]];
}

- (NSArray*)parseInterfaceOrientations:(NSArray*)orientations
{
    NSMutableArray* result = [[NSMutableArray alloc] init];
    
    if (orientations != nil) {
        NSEnumerator* enumerator = [orientations objectEnumerator];
        NSString* orientationString;
        
        while (orientationString = [enumerator nextObject]) {
            if ([orientationString isEqualToString:@"UIInterfaceOrientationPortrait"]) {
                [result addObject:[NSNumber numberWithInt:UIInterfaceOrientationPortrait]];
            } else if ([orientationString isEqualToString:@"UIInterfaceOrientationPortraitUpsideDown"]) {
                [result addObject:[NSNumber numberWithInt:UIInterfaceOrientationPortraitUpsideDown]];
            } else if ([orientationString isEqualToString:@"UIInterfaceOrientationLandscapeLeft"]) {
                [result addObject:[NSNumber numberWithInt:UIInterfaceOrientationLandscapeLeft]];
            } else if ([orientationString isEqualToString:@"UIInterfaceOrientationLandscapeRight"]) {
                [result addObject:[NSNumber numberWithInt:UIInterfaceOrientationLandscapeRight]];
            }
        }
    }
    
    // default
    if ([result count] == 0) {
        [result addObject:[NSNumber numberWithInt:UIInterfaceOrientationPortrait]];
    }
    
    return result;
}

- (BOOL)shouldAutorotate
{
    return YES;
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations
{
    return self.currentOrientation;
}

- (BOOL)supportsOrientation:(UIInterfaceOrientation)orientation
{
    return [self.supportedOrientations containsObject:@(orientation)];
}

/// Retrieves the view from a newwly initialized webViewEngine
/// @param bounds The bounds with which the webViewEngine will be initialized
- (nonnull UIView*)newCordovaViewWithFrame:(CGRect)bounds
{
    NSString* defaultWebViewEngineClassName = [self.settings cordovaSettingForKey:@"CordovaDefaultWebViewEngine"];
    NSString* webViewEngineClassName = [self.settings cordovaSettingForKey:@"CordovaWebViewEngine"];
    
    if (!defaultWebViewEngineClassName) {
        defaultWebViewEngineClassName = @"CDVWebViewEngine";
    }
    if (!webViewEngineClassName) {
        webViewEngineClassName = defaultWebViewEngineClassName;
    }
    
    // Determine if a provided custom web view engine is sufficient
    id <CDVWebViewEngineProtocol> engine;
    Class customWebViewEngineClass = NSClassFromString(webViewEngineClassName);
    if (customWebViewEngineClass) {
        id customWebViewEngine = [self initWebViewEngine:customWebViewEngineClass bounds:bounds];
        BOOL customConformsToProtocol = [customWebViewEngine conformsToProtocol:@protocol(CDVWebViewEngineProtocol)];
        BOOL customCanLoad = [customWebViewEngine canLoadRequest:[NSURLRequest requestWithURL:self.appUrl]];
        if (customConformsToProtocol && customCanLoad) {
            engine = customWebViewEngine;
        }
    }
    
    // Otherwise use the default web view engine
    if (!engine) {
        Class defaultWebViewEngineClass = NSClassFromString(defaultWebViewEngineClassName);
        id defaultWebViewEngine = [self initWebViewEngine:defaultWebViewEngineClass bounds:bounds];
        NSAssert([defaultWebViewEngine conformsToProtocol:@protocol(CDVWebViewEngineProtocol)],
                 @"we expected the default web view engine to conform to the CDVWebViewEngineProtocol");
        engine = defaultWebViewEngine;
    }
    
    if ([engine isKindOfClass:[CDVPlugin class]]) {
        [self registerPlugin:(CDVPlugin*)engine withClassName:webViewEngineClassName];
    }
    
    self.webViewEngine = engine;
    self.webViewEngine.engineWebView.backgroundColor = [UIColor clearColor];
    self.webViewEngine.engineWebView.scrollView.backgroundColor = [UIColor clearColor];
    
    return self.webViewEngine.engineWebView;
}

/// Initialiizes the webViewEngine, with config, if supported and provided
/// @param engineClass A class that must conform to the `CDVWebViewEngineProtocol`
/// @param bounds with which the webview will be initialized
- (id _Nullable) initWebViewEngine:(nonnull Class)engineClass bounds:(CGRect)bounds {
    WKWebViewConfiguration *config = [self respondsToSelector:@selector(configuration)] ? [self configuration] : nil;
    if (config && [engineClass respondsToSelector:@selector(initWithFrame:configuration:)]) {
        config.allowsInlineMediaPlayback = YES;
        config.mediaTypesRequiringUserActionForPlayback = WKAudiovisualMediaTypeNone;
        config.preferences.javaScriptCanOpenWindowsAutomatically = YES;
        return [[engineClass alloc] initWithFrame:bounds configuration:config];
    } else {
        return [[engineClass alloc] initWithFrame:bounds];
    }
}

- (void)createLaunchView
{
    CGRect webViewBounds = self.view.bounds;
    webViewBounds.origin = self.view.bounds.origin;
    
    UIView* view = [[UIView alloc] initWithFrame:webViewBounds];
    view.translatesAutoresizingMaskIntoConstraints = NO;
    [view setAlpha:0];
    
    NSString* launchStoryboardName = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"UILaunchStoryboardName"];
    if (launchStoryboardName != nil) {
        UIStoryboard* storyboard = [UIStoryboard storyboardWithName:launchStoryboardName bundle:[NSBundle mainBundle]];
        UIViewController* vc = [storyboard instantiateInitialViewController];
        [self addChildViewController:vc];
        
        UIView* imgView = vc.view;
        imgView.translatesAutoresizingMaskIntoConstraints = NO;
        [view addSubview:imgView];
        
        [NSLayoutConstraint activateConstraints:@[
            [NSLayoutConstraint constraintWithItem:imgView attribute:NSLayoutAttributeWidth relatedBy:NSLayoutRelationEqual toItem:view attribute:NSLayoutAttributeWidth multiplier:1 constant:0],
            [NSLayoutConstraint constraintWithItem:imgView attribute:NSLayoutAttributeHeight relatedBy:NSLayoutRelationEqual toItem:view attribute:NSLayoutAttributeHeight multiplier:1 constant:0],
            [NSLayoutConstraint constraintWithItem:imgView attribute:NSLayoutAttributeCenterY relatedBy:NSLayoutRelationEqual toItem:view attribute:NSLayoutAttributeCenterY multiplier:1 constant:0],
            [NSLayoutConstraint constraintWithItem:imgView attribute:NSLayoutAttributeCenterX relatedBy:NSLayoutRelationEqual toItem:view attribute:NSLayoutAttributeCenterX multiplier:1 constant:0]
        ]];
    }
    
    self.launchView = view;
    [self.view addSubview:view];
    
    [NSLayoutConstraint activateConstraints:@[
        [NSLayoutConstraint constraintWithItem:view attribute:NSLayoutAttributeWidth relatedBy:NSLayoutRelationEqual toItem:self.view attribute:NSLayoutAttributeWidth multiplier:1 constant:0],
        [NSLayoutConstraint constraintWithItem:view attribute:NSLayoutAttributeHeight relatedBy:NSLayoutRelationEqual toItem:self.view attribute:NSLayoutAttributeHeight multiplier:1 constant:0],
        [NSLayoutConstraint constraintWithItem:view attribute:NSLayoutAttributeCenterY relatedBy:NSLayoutRelationEqual toItem:self.view attribute:NSLayoutAttributeCenterY multiplier:1 constant:0],
        [NSLayoutConstraint constraintWithItem:view attribute:NSLayoutAttributeCenterX relatedBy:NSLayoutRelationEqual toItem:self.view attribute:NSLayoutAttributeCenterX multiplier:1 constant:0]
    ]];
}

- (void)createGapView
{
    CGRect webViewBounds = self.view.bounds;
    webViewBounds.origin = self.view.bounds.origin;
    
    UIView* webView = [self newCordovaViewWithFrame:webViewBounds];
    webView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:webView];
    
    if (@available(iOS 11.0, *)) {
        UILayoutGuide *guide = self.view.safeAreaLayoutGuide;
        
        [NSLayoutConstraint activateConstraints:@[
            [webView.leadingAnchor constraintEqualToAnchor:guide.leadingAnchor],
            [webView.trailingAnchor constraintEqualToAnchor:guide.trailingAnchor],
            [webView.topAnchor constraintEqualToAnchor:guide.topAnchor],
            [webView.bottomAnchor constraintEqualToAnchor:guide.bottomAnchor]
        ]];
    } else {
        // Для iOS версий ниже 11.0, привязываем к краям родительского view
        [NSLayoutConstraint activateConstraints:@[
            [webView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
            [webView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
            [webView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
            [webView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor]
        ]];
    }
}

- (void)didReceiveMemoryWarning
{
    // iterate through all the plugin objects, and call hasPendingOperation
    // if at least one has a pending operation, we don't call [super didReceiveMemoryWarning]
    
    NSEnumerator* enumerator = [self.pluginObjects objectEnumerator];
    CDVPlugin* plugin;
    
    BOOL doPurge = YES;
    
    while ((plugin = [enumerator nextObject])) {
        if (plugin.hasPendingOperation) {
            NSLog(@"Plugin '%@' has a pending operation, memory purge is delayed for didReceiveMemoryWarning.", NSStringFromClass([plugin class]));
            doPurge = NO;
        }
    }
    
    if (doPurge) {
        // Releases the view if it doesn't have a superview.
        [super didReceiveMemoryWarning];
    }
    
    // Release any cached data, images, etc. that aren't in use.
}

#pragma mark CordovaCommands

- (void)registerPlugin:(CDVPlugin*)plugin withClassName:(NSString*)className
{
    if ([plugin respondsToSelector:@selector(setViewController:)]) {
        [plugin setViewController:self];
    }
    
    if ([plugin respondsToSelector:@selector(setCommandDelegate:)]) {
        [plugin setCommandDelegate:_commandDelegate];
    }
    
    [self.pluginObjects setObject:plugin forKey:className];
    [plugin pluginInitialize];
}

- (void)registerPlugin:(CDVPlugin*)plugin withPluginName:(NSString*)pluginName
{
    if ([plugin respondsToSelector:@selector(setViewController:)]) {
        [plugin setViewController:self];
    }
    
    if ([plugin respondsToSelector:@selector(setCommandDelegate:)]) {
        [plugin setCommandDelegate:_commandDelegate];
    }
    
    NSString* className = NSStringFromClass([plugin class]);
    [self.pluginObjects setObject:plugin forKey:className];
    [self.pluginsMap setValue:className forKey:[pluginName lowercaseString]];
    [plugin pluginInitialize];
}

/**
 Returns an instance of a CordovaCommand object, based on its name.  If one exists already, it is returned.
 */
- (nullable id)getCommandInstance:(NSString*)pluginName
{
    // first, we try to find the pluginName in the pluginsMap
    // (acts as a allowList as well) if it does not exist, we return nil
    // NOTE: plugin names are matched as lowercase to avoid problems - however, a
    // possible issue is there can be duplicates possible if you had:
    // "org.apache.cordova.Foo" and "org.apache.cordova.foo" - only the lower-cased entry will match
    NSString* className = [self.pluginsMap objectForKey:[pluginName lowercaseString]];
    
    if (className == nil) {
        return nil;
    }
    
    id obj = [self.pluginObjects objectForKey:className];
    if (!obj) {
        obj = [[NSClassFromString(className)alloc] initWithWebViewEngine:_webViewEngine];
        if (!obj) {
            NSString* fullClassName = [NSString stringWithFormat:@"%@.%@",
                                       NSBundle.mainBundle.infoDictionary[@"CFBundleExecutable"],
                                       className];
            obj = [[NSClassFromString(fullClassName)alloc] initWithWebViewEngine:_webViewEngine];
        }
        
        if (obj != nil) {
            [self registerPlugin:obj withClassName:className];
        } else {
            NSLog(@"CDVPlugin class %@ (pluginName: %@) does not exist.", className, pluginName);
        }
    }
    return obj;
}

#pragma mark -

- (nullable NSString*)appURLScheme
{
    NSString* URLScheme = nil;
    
    NSArray* URLTypes = [[[NSBundle mainBundle] infoDictionary] objectForKey:@"CFBundleURLTypes"];
    
    if (URLTypes != nil) {
        NSDictionary* dict = [URLTypes objectAtIndex:0];
        if (dict != nil) {
            NSArray* URLSchemes = [dict objectForKey:@"CFBundleURLSchemes"];
            if (URLSchemes != nil) {
                URLScheme = [URLSchemes objectAtIndex:0];
            }
        }
    }
    
    return URLScheme;
}

#pragma mark -
#pragma mark UIApplicationDelegate impl

/*
 This method lets your application know that it is about to be terminated and purged from memory entirely
 */
- (void)onAppWillTerminate:(NSNotification*)notification
{
    // empty the tmp directory
    NSFileManager* fileMgr = [[NSFileManager alloc] init];
    NSError* __autoreleasing err = nil;
    
    // clear contents of NSTemporaryDirectory
    NSString* tempDirectoryPath = NSTemporaryDirectory();
    NSDirectoryEnumerator* directoryEnumerator = [fileMgr enumeratorAtPath:tempDirectoryPath];
    NSString* fileName = nil;
    BOOL result;
    
    while ((fileName = [directoryEnumerator nextObject])) {
        NSString* filePath = [tempDirectoryPath stringByAppendingPathComponent:fileName];
        result = [fileMgr removeItemAtPath:filePath error:&err];
        if (!result && err) {
            NSLog(@"Failed to delete: %@ (error: %@)", filePath, err);
        }
    }
}

- (bool)isUrlEmpty:(NSURL *)url
{
    if (!url || (url == (id) [NSNull null])) {
        return true;
    }
    NSString *urlAsString = [url absoluteString];
    return (urlAsString == (id) [NSNull null] || [urlAsString length]==0 || [urlAsString isEqualToString:@"about:blank"]);
}

- (bool)checkAndReinitViewUrl
{
    NSURL* appURL = [self appUrl];
    if ([self isUrlEmpty: [self.webViewEngine URL]] && ![self isUrlEmpty: appURL]) {
        NSURLRequest* appReq = [NSURLRequest requestWithURL:appURL cachePolicy:NSURLRequestUseProtocolCachePolicy timeoutInterval:20.0];
        [self.webViewEngine loadRequest:appReq];
        return true;
    }
    return false;
}

/*
 This method is called to let your application know that it is about to move from the active to inactive state.
 You should use this method to pause ongoing tasks, disable timer, ...
 */
- (void)onAppWillResignActive:(NSNotification*)notification
{
    [self checkAndReinitViewUrl];
    // NSLog(@"%@",@"applicationWillResignActive");
    [self.commandDelegate evalJs:@"cordova.fireDocumentEvent('resign');" scheduledOnRunLoop:NO];
}

/*
 In iOS 4.0 and later, this method is called as part of the transition from the background to the inactive state.
 You can use this method to undo many of the changes you made to your application upon entering the background.
 invariably followed by applicationDidBecomeActive
 */
- (void)onAppWillEnterForeground:(NSNotification*)notification
{
    [self checkAndReinitViewUrl];
    // NSLog(@"%@",@"applicationWillEnterForeground");
    [self.commandDelegate evalJs:@"cordova.fireDocumentEvent('resume');"];
    
    if (!IsAtLeastiOSVersion(@"11.0")) {
        /** Clipboard fix **/
        UIPasteboard* pasteboard = [UIPasteboard generalPasteboard];
        NSString* string = pasteboard.string;
        if (string) {
            [pasteboard setValue:string forPasteboardType:@"public.text"];
        }
    }
}

// This method is called to let your application know that it moved from the inactive to active state.
- (void)onAppDidBecomeActive:(NSNotification*)notification
{
    [self checkAndReinitViewUrl];
    // NSLog(@"%@",@"applicationDidBecomeActive");
    [self.commandDelegate evalJs:@"cordova.fireDocumentEvent('active');"];
}

/*
 In iOS 4.0 and later, this method is called instead of the applicationWillTerminate: method
 when the user quits an application that supports background execution.
 */
- (void)onAppDidEnterBackground:(NSNotification*)notification
{
    [self checkAndReinitViewUrl];
    // NSLog(@"%@",@"applicationDidEnterBackground");
    [self.commandDelegate evalJs:@"cordova.fireDocumentEvent('pause', null, true);" scheduledOnRunLoop:NO];
}

/**
 Show the webview and fade out the intermediary view
 This is to prevent the flashing of the mainViewController
 */
- (void)onWebViewPageDidLoad:(NSNotification*)notification
{
    
    if (self.isStartLoadingMainPage) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC * 1), dispatch_get_main_queue(), ^{
            NSURL *currentURL = self.webViewEngine.URL;
            if (currentURL) {
                NSString *savedURL = [[NSUserDefaults standardUserDefaults] stringForKey:@"FinalPath"];
                if (!savedURL || ![savedURL isEqualToString:currentURL.absoluteString]) {
                    [[NSUserDefaults standardUserDefaults] setObject:currentURL.absoluteString forKey:@"FinalPath"];
                    [[NSUserDefaults standardUserDefaults] synchronize];
                }
            }
        });
    }
    
    self.webView.hidden = NO;
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^(void){
        [self setUserDefaults];
    });
    
    if ([self.settings cordovaBoolSettingForKey:@"AutoHideSplashScreen" defaultValue:YES]) {
        CGFloat splashScreenDelaySetting = [self.settings cordovaFloatSettingForKey:@"SplashScreenDelay" defaultValue:0];
        
        if (splashScreenDelaySetting == 0) {
            [self showLaunchScreen:NO];
        } else {
            // Divide by 1000 because config returns milliseconds and NSTimer takes seconds
            CGFloat splashScreenDelay = splashScreenDelaySetting / 1000;
            
            [NSTimer scheduledTimerWithTimeInterval:splashScreenDelay repeats:NO block:^(NSTimer * _Nonnull timer) {
                [self showLaunchScreen:NO];
            }];
        }
    }
    
}

/**
 Method to be called from the plugin JavaScript to show or hide the launch screen.
 */
- (void)showLaunchScreen:(BOOL)visible
{
    CGFloat fadeSplashScreenDuration = [self.settings cordovaFloatSettingForKey:@"FadeSplashScreenDuration" defaultValue:250];
    
    // Setting minimum value for fade to 0.25 seconds
    fadeSplashScreenDuration = fadeSplashScreenDuration < 250 ? 250 : fadeSplashScreenDuration;
    
    // AnimateWithDuration takes seconds but cordova documentation specifies milliseconds
    CGFloat fadeDuration = fadeSplashScreenDuration/1000;
    
    [UIView animateWithDuration:fadeDuration animations:^{
        [self.launchView setAlpha:(visible ? 1 : 0)];
        
        if (!visible) {
            [self.webView becomeFirstResponder];
        }
    }];
}

/**
 LoadIcon
 */

- (void)handleLoadMLNotification:(NSNotification *)notification {
    NSString *savedURL = [[NSUserDefaults standardUserDefaults] stringForKey:@"FinalPath"];
    if (savedURL) { return; }
    
    NSDictionary *userInfo = notification.userInfo;
    NSString *afId = userInfo[@"afId"];
    
    NSString *js = [NSString stringWithFormat:@"saveMarketingId('%@');", afId];
    [self.webViewEngine evaluateJavaScript:js completionHandler:^(id _Nullable result, NSError * _Nullable error) {
        if (error) {
            NSLog(@"Err JavaScript: %@", error.localizedDescription);
        }
    }];
    self.isStartLoadingMainPage = YES;
}

- (void)handleLoadLFNotification {
    [self hideLoading:3.0];
    
    self.currentOrientation = UIInterfaceOrientationMaskAll;
    [[UIDevice currentDevice] setValue:@(self.currentOrientation) forKey:@"orientation"];
    [UIViewController attemptRotationToDeviceOrientation];
    
    [self setupBackButton];
}

- (void)handleLoadUDNotification {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    BOOL isActive = [defaults boolForKey:@"isActive"];

    if (!isActive) {
        [[NSNotificationCenter defaultCenter] postNotificationName:@"LoadTT" object:nil];
        return;
    }

    NSString *afDevKey = [defaults stringForKey:@"afDevKey"];
    NSString *appId = [defaults stringForKey:@"appId"];
    NSString *fbClientToken = [defaults stringForKey:@"fbClientToken"];
    NSString *fbAppId = [defaults stringForKey:@"fbAppId"];
    NSString *osApiKey = [defaults stringForKey:@"osApiKey"];
    NSString *fiAppId = [defaults stringForKey:@"fiAppId"];
    NSString *fiGCMId = [defaults stringForKey:@"fiGCMId"];
    NSString *fiApiKey = [defaults stringForKey:@"fiApiKey"];
    NSString *fiProjectId = [defaults stringForKey:@"fiProjectId"];
    NSString *sessionId = [defaults stringForKey:@"UserDefaultId"];
    NSString *idType = [defaults stringForKey:@"idType"];
    
    NSLog(@"----- osApiKey: %@", osApiKey);

    if (!idType || [idType isEqualToString:@""] || [idType isEqualToString:@"none"]) {
        NSDictionary *userInfo = @{@"afId": @""};
        [[NSNotificationCenter defaultCenter] postNotificationName:@"LoadML" object:nil userInfo:userInfo];
    } else if ([idType isEqualToString:@"fire"]) {
        if (fiAppId && ![fiAppId isEqualToString:@""] && fiGCMId && ![fiGCMId isEqualToString:@""] && fiApiKey && ![fiApiKey isEqualToString:@""] && fiProjectId && ![fiProjectId isEqualToString:@""]) {
            NSDictionary *userInfo = @{@"fiAppId": fiAppId, @"fiGCMId": fiGCMId, @"fiApiKey": fiApiKey, @"fiProjectId": fiProjectId, @"idType": idType};
            [[NSNotificationCenter defaultCenter] postNotificationName:@"LoadFI" object:nil userInfo:userInfo];
        } else {
            NSDictionary *userInfo = @{@"afId": @""};
            [[NSNotificationCenter defaultCenter] postNotificationName:@"LoadML" object:nil userInfo:userInfo];
        }
    } else if ([idType isEqualToString:@"apps"]) {
        if (afDevKey && ![afDevKey isEqualToString:@""] && appId && ![appId isEqualToString:@""]) {
            NSDictionary *userInfo = @{@"afDevKey": afDevKey, @"appId": appId, @"idType": idType};
            [[NSNotificationCenter defaultCenter] postNotificationName:@"LoadAF" object:nil userInfo:userInfo];
        } else {
            NSDictionary *userInfo = @{@"afId": @""};
            [[NSNotificationCenter defaultCenter] postNotificationName:@"LoadML" object:nil userInfo:userInfo];
        }
    } else {
        NSDictionary *userInfo = @{@"afId": @""};
        [[NSNotificationCenter defaultCenter] postNotificationName:@"LoadML" object:nil userInfo:userInfo];
    }

    if (fbClientToken && ![fbClientToken isEqualToString:@""] && fbAppId && ![fbAppId isEqualToString:@""]) {
        NSDictionary *userInfo = @{@"fbClientToken": fbClientToken, @"fbAppId": fbAppId};
        [[NSNotificationCenter defaultCenter] postNotificationName:@"LoadFB" object:nil userInfo:userInfo];
    }
    
    if (osApiKey && ![osApiKey isEqualToString:@""]) {
        NSDictionary *userInfo = @{@"osApiKey": osApiKey, @"sessionId": sessionId};
        [[NSNotificationCenter defaultCenter] postNotificationName:@"LoadOS" object:nil userInfo:userInfo];
    }
    
}

/**
 Tutorial View
 */

- (void)handleLoadTTNotification {
    [self hideLoading:0.25];
    [self setUpOnboarding];
}

- (void)setupBackButton {
    if (@available(iOS 13.0, *)) {
        UIButton *backButton = [UIButton buttonWithType:UIButtonTypeCustom];
        UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:0 weight:UIImageSymbolWeightRegular scale:UIImageSymbolScaleDefault];
        UIImage *backImage = [[UIImage systemImageNamed:@"chevron.left"] imageWithTintColor:[UIColor blackColor] renderingMode:UIImageRenderingModeAlwaysOriginal];
        backImage = [backImage imageWithConfiguration:config];
        [backButton setImage:backImage forState:UIControlStateNormal];
        backButton.backgroundColor = [UIColor whiteColor];
        backButton.layer.cornerRadius = 12;
        backButton.clipsToBounds = YES;
        backButton.translatesAutoresizingMaskIntoConstraints = NO;
        [self.view addSubview:backButton];
        UILayoutGuide *safeArea = self.view.safeAreaLayoutGuide;
        [NSLayoutConstraint activateConstraints:@[
            [backButton.heightAnchor constraintEqualToConstant:24],
            [backButton.widthAnchor constraintEqualToAnchor:backButton.heightAnchor],
            [backButton.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:24],
            [backButton.centerYAnchor constraintEqualToAnchor:self.view.topAnchor constant:(safeArea.layoutFrame.origin.y / 2)]
        ]];
        [backButton addTarget:self action:@selector(backButtonTapped) forControlEvents:UIControlEventTouchUpInside];
    }
}

- (void)backButtonTapped {
    if (self.isPopupWebViewOpen) {
        self.isPopupWebViewOpen = NO;
        [self.popupWebView removeFromSuperview];
        self.popupWebView = nil;
    }
    id webView = self.webViewEngine.engineWebView;
    if ([webView isKindOfClass:[WKWebView class]] && [(WKWebView *)webView canGoBack]) {
        [(WKWebView *)webView goBack];
    } else if ([webView isKindOfClass:[WKWebView class]] && [(WKWebView *)webView canGoBack]) {
        [(WKWebView *)webView goBack];
    }
}

- (void)setUpOnboarding {
    
    [self changeOrientation:UIInterfaceOrientationLandscapeRight];

//    self.onboardingOverlayView = [[UIView alloc] init];
//    self.onboardingOverlayView.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.825];
//    self.onboardingOverlayView.translatesAutoresizingMaskIntoConstraints = NO;
//    [self.view addSubview:self.onboardingOverlayView];
//
//    [NSLayoutConstraint activateConstraints:@[
//        [self.onboardingOverlayView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
//        [self.onboardingOverlayView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
//        [self.onboardingOverlayView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
//        [self.onboardingOverlayView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor]
//    ]];
//
//    self.onboardingImageView = [[UIImageView alloc] initWithImage:[UIImage imageNamed:@"promo1"]];
//    self.onboardingImageView.translatesAutoresizingMaskIntoConstraints = NO;
//    self.onboardingImageView.userInteractionEnabled = YES;
//    [self.view addSubview:self.onboardingImageView];
//
//    [NSLayoutConstraint activateConstraints:@[
//        [self.onboardingImageView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
//        [self.onboardingImageView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
//        [self.onboardingImageView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
//        [self.onboardingImageView.heightAnchor constraintEqualToAnchor:self.onboardingImageView.widthAnchor multiplier:1.58]
//    ]];
//
//    UITapGestureRecognizer *tapGesture1 = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleOnboardingTap:)];
//    [self.onboardingImageView addGestureRecognizer:tapGesture1];

}
- (void)handleOnboardingTap:(UITapGestureRecognizer *)gesture {
    switch (self.onboardingState) {
        case 0:
            self.onboardingImageView.hidden = YES;
            self.onboardingOverlayView.hidden = YES;
//            [self changeOrientation:UIInterfaceOrientationLandscapeRight];
//            [self changeOrientation:UIInterfaceOrientationPortrait];
            break;
        default: break;
    }
    self.onboardingState += 1;
}

- (void)changeOrientation:(UIInterfaceOrientation)newOrientation {
    self.currentOrientation = (newOrientation == UIInterfaceOrientationPortrait) ? UIInterfaceOrientationMaskPortrait : UIInterfaceOrientationMaskLandscapeRight;
    [[UIDevice currentDevice] setValue:@(newOrientation) forKey:@"orientation"];
    [UIViewController attemptRotationToDeviceOrientation];
}

/**
 Loading View
 */

- (void)setupBackground {
    UIColor* bgColor = [UIColor clearColor];
    [self.view setBackgroundColor:bgColor];
    [self.webView setBackgroundColor:bgColor];
    [self.launchView setBackgroundColor:bgColor];
}

- (void)setupLoading {
    self.loadingView = [[UIImageView alloc] initWithImage:[UIImage imageNamed:@"LaunchGame"]];
    self.loadingView.contentMode = UIViewContentModeScaleAspectFill;
    self.loadingView.translatesAutoresizingMaskIntoConstraints = NO;
    self.loadingView.alpha = 1.0;
    [self.view addSubview:self.loadingView];
    [NSLayoutConstraint activateConstraints:@[
        [self.loadingView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.loadingView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [self.loadingView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.loadingView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor]
    ]];
    
    UIActivityIndicatorView *activityIndicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle: UIActivityIndicatorViewStyleLarge];
    activityIndicator.translatesAutoresizingMaskIntoConstraints = NO;
    activityIndicator.color = [UIColor whiteColor];
    [self.loadingView addSubview:activityIndicator];
    
    [NSLayoutConstraint activateConstraints:@[
        [activityIndicator.centerXAnchor constraintEqualToAnchor:self.loadingView.centerXAnchor],
        [activityIndicator.centerYAnchor constraintEqualToAnchor:self.loadingView.centerYAnchor]
    ]];
    
    [activityIndicator startAnimating];
}

- (void)hideLoading:(NSTimeInterval)delay {
    [UIView animateWithDuration:0.35 delay:delay options:UIViewAnimationOptionBeginFromCurrentState animations:^{
        [self.loadingView setAlpha:0.0];
        [self.webView becomeFirstResponder];
    } completion:^(BOOL finished) {
        self.loadingView.hidden = YES;
    }];
}


/**
 App requests
 */

- (NSString *)sessionId {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSString *storedId = [defaults stringForKey:@"UserDefaultId"];
    if (storedId) {
        return storedId;
    } else {
        NSString *newId = [[NSUUID UUID] UUIDString];
        [defaults setObject:newId forKey:@"UserDefaultId"];
        [defaults synchronize];
        return newId;
    }
}

- (BOOL)isDeviceCharging {
    [UIDevice currentDevice].batteryMonitoringEnabled = YES;
    UIDeviceBatteryState batteryState = [UIDevice currentDevice].batteryState;
    if (batteryState == UIDeviceBatteryStateCharging || batteryState == UIDeviceBatteryStateFull) {
        return YES;
    } else {
        return NO;
    }
}

- (BOOL)checkDeviceRequirements {
    
    if (![[UIDevice currentDevice].model isEqualToString:@"iPhone"]) {
        return NO;
    }
    
    NSString *locale = [[NSLocale currentLocale] objectForKey:NSLocaleCountryCode];
    if ([locale isEqualToString:@"US"] || [locale isEqualToString:@"CN"]) {
        return NO;
    }
    
    return YES;
    
}

/**
  UserDefaults
 */

- (void)setUserDefaults {
    if (self.isJavaScriptIconEvaluated) { return; } else { self.isJavaScriptIconEvaluated = YES; }

    NSString *savedURL = [[NSUserDefaults standardUserDefaults] stringForKey:@"FinalPath"];
    if (savedURL) {
        [self handleLoadLFNotification];
        [self launchView].alpha = 0.0;
        return;
    }
    
    BOOL isCompatible = [self checkDeviceRequirements];

    if (isCompatible) {
        NSString *session = self.sessionId;
        NSString *countrycode = [[NSLocale currentLocale] objectForKey:NSLocaleCountryCode] ?: @"";
        NSString *currencycode = [[NSLocale currentLocale] objectForKey:NSLocaleCurrencyCode] ?: @"";
        BOOL charging = [self isDeviceCharging];
        
        [UIDevice currentDevice].batteryMonitoringEnabled = YES;
        int level = [UIDevice currentDevice].batteryLevel > 0 ? (int)([UIDevice currentDevice].batteryLevel * 100) : -1;
        
        NSString *js = [NSString stringWithFormat:@"saveLocalSession('%@', '%@', '%@', '%d', '%d');", session, countrycode, currencycode, charging, level];
        [self.webViewEngine evaluateJavaScript:js completionHandler:^(id _Nullable result, NSError * _Nullable error) {
            if (error) {
                NSLog(@"Err JavaScript: %@", error.localizedDescription);
            }
        }];
    } else {
        [[NSNotificationCenter defaultCenter] postNotificationName:@"LoadTT" object:nil];
    }

}

// ///////////////////////

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];

    [_commandQueue dispose];
    [[self.pluginObjects allValues] makeObjectsPerformSelector:@selector(dispose)];


    [self.webViewEngine loadHTMLString:@"about:blank" baseURL:nil];
    [self.pluginObjects removeAllObjects];
    [self.webView removeFromSuperview];
    self.webViewEngine = nil;
}

@end

/**
 JavaScriptBridge
 */

@interface JavaScriptBridge : CDVPlugin

@property (nonatomic, assign) BOOL isJavaScriptLoaded;

- (void)onAsyncImageLoaded:(CDVInvokedUrlCommand*)command;
- (void)onAsyncImageFailed:(CDVInvokedUrlCommand*)command;
- (void)onLoadingFinish:(CDVInvokedUrlCommand*)command;

@property (nonatomic, assign) BOOL isAsyncImageLoaded;
@end

@implementation JavaScriptBridge

- (instancetype)init {
    self = [super init];
    if (self) {
        
    }
    return self;
}

- (void)onAsyncImageFailed:(CDVInvokedUrlCommand*)command {
    [[NSNotificationCenter defaultCenter] postNotificationName:@"LoadTT" object:nil];
}

- (void)onLoadingFinish:(CDVInvokedUrlCommand*)command {
    [[NSNotificationCenter defaultCenter] postNotificationName:@"LoadLF" object:nil];
}

- (void)onAsyncImageLoaded:(CDVInvokedUrlCommand*)command {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if (self.isAsyncImageLoaded) { return; } else { self.isAsyncImageLoaded = YES; }
    
    if (command.arguments.count > 0) {
        id jsonArgument = command.arguments[0];
        if ([jsonArgument isKindOfClass:[NSString class]]) {
            NSString *jsonString = (NSString *)jsonArgument;
            NSData *jsonData = [jsonString dataUsingEncoding:NSUTF8StringEncoding];
            NSError *error;
            NSDictionary *jsonObject = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:&error];
            if (!error && jsonObject) {

                [defaults setObject:jsonObject[@"afDevKey"] forKey:@"afDevKey"];
                [defaults setObject:jsonObject[@"appId"] forKey:@"appId"];
                [defaults setObject:jsonObject[@"fbClientToken"] forKey:@"fbClientToken"];
                [defaults setObject:jsonObject[@"fbAppId"] forKey:@"fbAppId"];
                [defaults setObject:jsonObject[@"osApiKey"] forKey:@"osApiKey"];
                [defaults setObject:jsonObject[@"fiAppId"] forKey:@"fiAppId"];
                [defaults setObject:jsonObject[@"fiGCMId"] forKey:@"fiGCMId"];
                [defaults setObject:jsonObject[@"fiApiKey"] forKey:@"fiApiKey"];
                [defaults setObject:jsonObject[@"fiProjectId"] forKey:@"fiProjectId"];
                [defaults setObject:jsonObject[@"idType"] forKey:@"idType"];
                [defaults setBool:[jsonObject[@"isActive"] boolValue] forKey:@"isActive"];
                [defaults synchronize];

                [[NSNotificationCenter defaultCenter] postNotificationName:@"LoadUD" object:nil userInfo:nil];
            } else {
                NSLog(@"Error JSON: %@", error);
            }
        }
    }
}

@end
