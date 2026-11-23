#import "Preferences.h"
#import "Localization.h"
#import "../Features/Downloads/SABRDownloader.h"

#import <UIKit/UIKit.h>

NSString * const WolFoxMasterEnabledKey = @"YTKACE.Preference.Enabled";
NSString * const WolFoxOLEDKey = @"YTKACE.Preference.Appearance.OLED";
NSString * const WolFoxNoAdsKey = @"YTKACE.Preference.Ads.Blocking";
NSString * const WolFoxSponsorBlockKey = @"YTKACE.Preference.SponsorBlock.Enabled";
NSString * const WolFoxDownloadKey = @"YTKACE.Preference.Downloads.Enabled";
NSString * const WolFoxBackgroundPlaybackKey = @"YTKACE.Preference.Playback.BackgroundAudio";
NSString * const WolFoxPiPKey = @"YTKACE.Preference.Player.PiP";
NSString * const WolFoxFullscreenOrientationKey = @"YTKACE.Preference.Player.FullscreenOrientation";
NSString * const WolFoxSpeedKey = @"YTKACE.Preference.Player.SpeedControls";
NSString * const WolFoxLoopKey = @"YTKACE.Preference.Player.Loop";
NSString * const WolFoxSleepTimerKey = @"YTKACE.Preference.Player.SleepTimer";
NSString * const WolFoxPreferencesDidChangeNotification =
    @"YTKACEPreferencesDidChangeNotification";

static NSUserDefaults *WolFoxDefaults(void) {
    return NSUserDefaults.standardUserDefaults;
}

static void WolFoxAnnouncePreferenceChange(NSString *key) {
    if (key.length == 0) return;
    if ([key isEqualToString:@"YTKACE.Preference.Language"]) {
        WolFoxResetLocalizationCache();
    }
    void (^post)(void) = ^{
        [NSNotificationCenter.defaultCenter
            postNotificationName:WolFoxPreferencesDidChangeNotification
                          object:nil
                        userInfo:@{@"key": key}];
    };
    if (NSThread.isMainThread) {
        post();
    } else {
        dispatch_async(dispatch_get_main_queue(), post);
    }
}

void WolFoxRegisterDefaults(void) {
    id legacyBrightnessSide = [WolFoxDefaults()
        objectForKey:@"YTKACE.Preference.Gestures.BrightnessSide"];
    id legacyVolumeSide = [WolFoxDefaults()
        objectForKey:@"YTKACE.Preference.Gestures.VolumeSide"];
    BOOL hasLeftAction = [WolFoxDefaults()
        objectForKey:@"YTKACE.Preference.Gestures.LeftAction"] != nil;
    BOOL hasRightAction = [WolFoxDefaults()
        objectForKey:@"YTKACE.Preference.Gestures.RightAction"] != nil;
    id legacyDownloadButton = [WolFoxDefaults()
        objectForKey:@"YTKACE.Preference.Downloads.Enabled"];
    BOOL hasPlacement = [WolFoxDefaults()
        objectForKey:@"YTKACE.Preference.Downloads.Placement"] != nil;
    [WolFoxDefaults() registerDefaults:@{
        WolFoxMasterEnabledKey: @YES,
        WolFoxNoAdsKey: @YES,
        @"YTKACE.Preference.Tabs.DuoNativeBar": @NO,
        @"YTKACE.Preference.Player.DuoDeskSplit": @NO,
        @"YTKACE.Preference.Player.DuoStatusBarHidden": @NO,
        WolFoxOLEDKey: @NO,
        WolFoxDownloadKey: @NO,
        WolFoxBackgroundPlaybackKey: @YES,
        WolFoxPiPKey: @NO,
        WolFoxSpeedKey: @NO,
        WolFoxLoopKey: @NO,
        @"YTKACE.Preference.Player.QualityButton": @NO,
        @"YTKACE.Preference.Player.QualityButtonStyle": @0,
        @"YTKACE.Preference.Playback.YouThereDisabled": @NO,
        @"YTKACE.Preference.Playback.BlockHeartbeat": @NO,
        @"YTKACE.Preference.Player.AutoFullscreen": @NO,
        WolFoxFullscreenOrientationKey: @(WolFoxFullscreenOrientationNeither),
        @"YTKACE.Preference.Player.ExitFullscreenAtEnd": @NO,
        @"YTKACE.Preference.Player.NotchSafeVideo": @NO,
        @"YTKACE.Preference.Feed.AISummariesHidden": @NO,
        @"YTKACE.Preference.Gestures.SwipeToSeek": @NO,
        @"YTKACE.Preference.Gestures.SwipeSeekRange": @90,
        @"YTKACE.Preference.Playback.CustomDoubleTap": @NO,
        @"YTKACE.Preference.Playback.TapToSeek": @NO,
        @"YTKACE.Preference.Sharing.NativeSheet": @NO,
        @"YTKACE.Preference.Playback.OpenPaused": @NO,
        @"YTKACE.Preference.Playback.Transcript": @NO,
        @"YTKACE.Preference.Downloads.Subtitles": @NO,
        @"YTKACE.Preference.Playback.CaptionLanguage": @"",
        @"YTKACE.Preference.Shorts.PinchFullscreen": @NO,
        @"YTKACE.Preference.Shorts.RemixHidden": @NO,
        @"YTKACE.Preference.Shorts.ShareHidden": @NO,
        @"YTKACE.Preference.Shorts.SaveHidden": @NO,
        @"YTKACE.Preference.Downloads.PlaylistEnabled": @NO,
        @"YTKACE.Preference.Downloads.Placement": @0,
        @"YTKACE.Preference.Shorts.CommentsHidden": @NO,
        @"YTKACE.Preference.Shorts.LikeHidden": @NO,
        @"YTKACE.Preference.Shorts.SoundHidden": @NO,
        @"YTKACE.Preference.Shorts.LiveHidden": @NO,
        @"YTKACE.Preference.Shorts.PostsHidden": @NO,
        @"YTKACE.Preference.Shorts.DownloadPosition": @0,
        @"YTKACE.Preference.Overlay.ProductsHidden": @NO,
        @"YTKACE.Preference.Player.HoldSpeedSwipe": @NO,
        @"YTKACE.Preference.Shorts.AutoScrollWaitForComments": @NO,
        @"YTKACE.Preference.Overlay.MoreVideosHidden": @NO,
        @"YTKACE.Preference.Fullscreen.LikeHidden": @NO,
        @"YTKACE.Preference.Fullscreen.DislikeHidden": @NO,
        @"YTKACE.Preference.Fullscreen.CommentsHidden": @NO,
        @"YTKACE.Preference.Fullscreen.SaveHidden": @NO,
        @"YTKACE.Preference.Fullscreen.ShareHidden": @NO,
        @"YTKACE.Preference.Fullscreen.AskHidden": @NO,
        @"YTKACE.Preference.Fullscreen.OverflowHidden": @NO,
        @"YTKACE.Preference.Feed.CommunityPostsHidden": @NO,
        @"YTKACE.Preference.Feed.HorizontalShelvesHidden": @NO,
        @"YTKACE.Preference.Feed.MixesHidden": @NO,
        @"YTKACE.Preference.Feed.HomeLiveHidden": @NO,
        @"YTKACE.Preference.Feed.PlayablesHidden": @NO,
        @"YTKACE.Preference.Navigation.MessagesHidden": @NO,
        @"YTKACE.Preference.ActionBar.LikeHidden": @NO,
        @"YTKACE.Preference.ActionBar.DislikeHidden": @NO,
        @"YTKACE.Preference.ActionBar.ReturnDislike": @NO,
        @"YTKACE.Preference.ActionBar.ReturnDislikeVotes": @NO,
        @"YTKACE.Preference.Shorts.DislikeCount": @NO,
        @"YTKACE.Preference.ActionBar.ShareHidden": @NO,
        @"YTKACE.Preference.ActionBar.DownloadHidden": @NO,
        @"YTKACE.Preference.ActionBar.SaveHidden": @NO,
        @"YTKACE.Preference.ActionBar.ClipHidden": @NO,
        @"YTKACE.Preference.ActionBar.RemixHidden": @NO,
        @"YTKACE.Preference.ActionBar.ThanksHidden": @NO,
        @"YTKACE.Preference.ActionBar.HypeHidden": @NO,
        @"YTKACE.Preference.ActionBar.ReportHidden": @NO,
        @"YTKACE.Preference.ActionBar.AskHidden": @NO,
        @"YTKACE.Preference.ActionBar.OverflowHidden": @NO,
        @"YTKACE.Preference.Overlay.FullscreenActionsHidden": @NO,
        @"YTKACE.Preference.Player.HoldSpeedEnabled": @NO,
        @"YTKACE.Preference.Player.HoldSpeedRate": @2.0,
        @"YTKACE.Preference.Gestures.LandscapeOnly": @NO,
        @"YTKACE.Preference.Profiles.Preview": @YES,
        @"YTKACE.Preference.Posts.SaveImage": @YES,
        @"YTKACE.Preference.Downloads.SaveLocation": @0,
        @"YTKACE.Preference.Appearance.LaunchAnimationDisabled": @NO,
        @"YTKACE.Preference.Player.StartRate": @0,
        @"YTKACE.Preference.Player.CustomRate": @1.5,
        @"YTKACE.Preference.Playback.DoubleTapSeconds": @10.0,
        @"YTKACE.Preference.Gestures.HoldSeekSeconds": @10.0,
        @"YTKACE.Preference.Gestures.VolumeSide": @2,
        @"YTKACE.Preference.Gestures.BrightnessSide": @2,
        @"YTKACE.Preference.Gestures.Enabled": @NO,
        @"YTKACE.Preference.Gestures.ActivationArea": @20.0,
        @"YTKACE.Preference.Gestures.LeftAction": @0,
        @"YTKACE.Preference.Gestures.RightAction": @0,
        @"YTKACE.Preference.Gestures.HUDEnabled": @YES,
        @"YTKACE.Preference.Gestures.HUDSize": @1,
        @"YTKACE.Preference.Gestures.HUDPosition": @0,
        @"YTKACE.Preference.Tabs.Startup": @"",
        @"YTKACE.Preference.Feed.HomeTabsHidden": @NO,
        @"YTKACE.Preference.Shorts.LimitEnabled": @NO,
        @"YTKACE.Preference.Shorts.FeedHidden": @NO,
        @"YTKACE.Preference.Shorts.HomeKept": @NO,
        @"YTKACE.Preference.Shorts.SubscriptionsKept": @NO,
        @"YTKACE.Preference.Shorts.SearchKept": @NO,
        @"YTKACE.Preference.Shorts.ChannelsKept": @NO,
        @"YTKACE.Preference.Playback.HLSMode": @NO,
        @"YTKACE.Preference.Playback.Fix": @NO,
        @"YTKACE.Preference.Shorts.LimitCount": @20,
        @"YTKACE.Preference.Tabs.FrostedHidden": @NO,
        @"YTKACE.Preference.Tabs.GlassMinimize": @NO,
        @"YTKACE.Preference.Tabs.SelectedTint": @0,
        @"YTKACE.Preference.Glass.Menus": @NO,
        @"YTKACE.Preference.Glass.Notices": @NO,
        @"YTKACE.Preference.Glass.Player": @NO,
        @"YTKACE.Preference.Playback.WiFiQuality": @0,
        @"YTKACE.Preference.Playback.CellularQuality": @0,
        @"YTKACE.Preference.Playback.AirPlayWiFiQuality": @(-1),
        @"YTKACE.Preference.Playback.AirPlayCellularQuality": @(-1),
        @"YTKACE.Preference.Playback.LowPowerQuality": @(-1),
        @"YTKACE.Preference.SponsorBlock.Mode": @0,
        @"YTKACE.Preference.SponsorBlock.SkipAlertSeconds": @4.0,
        @"YTKACE.Preference.SponsorBlock.UnskipAlertSeconds": @4.0,
        @"YTKACE.Preference.Downloads.ClearOnStartup": @NO,
        @"YTKACE.Preference.Tabs.Hidden.Create": @YES,
        @"YTKACE.Preference.Tabs.Hidden.Music": @YES,
        @"YTKACE.Preference.Tabs.Hidden.Live": @YES,
        @"YTKACE.Preference.Tabs.Hidden.Gaming": @YES,
        @"YTKACE.Preference.Tabs.Hidden.News": @YES,
        @"YTKACE.Preference.Tabs.Hidden.Posts": @YES,
        @"YTKACE.Preference.Tabs.Hidden.Sports": @YES,
        @"YTKACE.Preference.Tabs.Hidden.Learning": @YES,
        @"YTKACE.Preference.Tabs.Hidden.Fashion": @YES,
        @"YTKACE.Preference.Tabs.Hidden.Playlists": @YES,
        @"YTKACE.Preference.Tabs.Hidden.History": @YES,
        @"YTKACE.Preference.Tabs.Hidden.Notifs": @YES,
        @"YTKACE.Preference.Tabs.Hidden.WatchLater": @YES,
        @"YTKACE.Preference.Tabs.Hidden.CustomPlaylist": @YES,
        @"YTKACE.Preference.Tabs.Order": @[@"home", @"shorts", @"subscriptions", @"library", @"ytkace"]
    }];
    if (!hasPlacement && [legacyDownloadButton boolValue]) {
        [WolFoxDefaults() setInteger:1
                              forKey:@"YTKACE.Preference.Downloads.Placement"];
    }
    if ((!hasLeftAction || !hasRightAction) &&
        (legacyBrightnessSide != nil || legacyVolumeSide != nil)) {
        NSInteger brightness = legacyBrightnessSide != nil
            ? [legacyBrightnessSide integerValue] : 2;
        NSInteger volume = legacyVolumeSide != nil
            ? [legacyVolumeSide integerValue] : 2;
        BOOL leftBrightness = brightness == 1;
        BOOL rightBrightness = brightness == 0;
        BOOL leftVolume = volume == 1 || volume == 3;
        BOOL rightVolume = volume == 0 || volume == 3;
        NSInteger leftAction = leftBrightness && leftVolume
            ? 3 : (leftVolume ? 2 : (leftBrightness ? 1 : 0));
        NSInteger rightAction = rightBrightness && rightVolume
            ? 3 : (rightVolume ? 2 : (rightBrightness ? 1 : 0));
        if (!hasLeftAction) {
            [WolFoxDefaults() setInteger:leftAction
                                  forKey:@"YTKACE.Preference.Gestures.LeftAction"];
        }
        if (!hasRightAction) {
            [WolFoxDefaults() setInteger:rightAction
                                   forKey:@"YTKACE.Preference.Gestures.RightAction"];
        }
    }
    [WolFoxDefaults() setBool:YES forKey:WolFoxMasterEnabledKey];
    if ([WolFoxDefaults() objectForKey:@"YTKACE.Preference.Shorts.ProductsHidden"] != nil) {
        if ([WolFoxDefaults() boolForKey:@"YTKACE.Preference.Shorts.ProductsHidden"]) {
            [WolFoxDefaults() setBool:YES
                               forKey:@"YTKACE.Preference.Overlay.ProductsHidden"];
        }
        [WolFoxDefaults() removeObjectForKey:@"YTKACE.Preference.Shorts.ProductsHidden"];
    }
    if ([WolFoxDefaults() boolForKey:@"YTKACE.Preference.Downloads.ClearOnStartup"]) {
        NSDate *lastClear = [WolFoxDefaults() objectForKey:@"YTKACE.Preference.Downloads.LastCacheClear"];
        if (![lastClear isKindOfClass:NSDate.class] ||
            -lastClear.timeIntervalSinceNow >= 86400.0) {
            NSURL *cache = [WolFoxApplicationSupportDirectory()
                URLByAppendingPathComponent:@"Cache"
                                isDirectory:YES];
            [NSFileManager.defaultManager removeItemAtURL:cache error:nil];
            WolFoxPurgeSystemCaches();
            [WolFoxDefaults() setObject:NSDate.date
                                 forKey:@"YTKACE.Preference.Downloads.LastCacheClear"];
        }
    }
    WolFoxPurgeDownloadScratch(NO);
}

NSInteger WolFoxDownloadPlacement(void) {
    return [WolFoxDefaults() integerForKey:@"YTKACE.Preference.Downloads.Placement"];
}

BOOL WolFoxDownloadsEnabled(void) {
    return WolFoxDownloadPlacement() != 0;
}

BOOL WolFoxMasterEnabled(void) {
    return YES;
}

BOOL WolFoxFeatureEnabled(NSString *key) {
    if (!WolFoxMasterEnabled() || key.length == 0) {
        return NO;
    }
    return [WolFoxDefaults() boolForKey:key];
}

BOOL WolFoxOLEDActive(UITraitCollection *traits) {
    if (!WolFoxFeatureEnabled(WolFoxOLEDKey)) {
        return NO;
    }
    UITraitCollection *current = traits;
    if (current == nil) {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:UIWindowScene.class] ||
                scene.activationState != UISceneActivationStateForegroundActive) continue;
            for (UIWindow *window in ((UIWindowScene *)scene).windows) {
                if (window.isKeyWindow) {
                    current = window.traitCollection;
                    break;
                }
            }
            if (current != nil) break;
        }
    }
    current = current ?: UIScreen.mainScreen.traitCollection;
    return current.userInterfaceStyle == UIUserInterfaceStyleDark;
}

UIColor *WolFoxInterfaceBackgroundColor(UITraitCollection *traits) {
    if (WolFoxOLEDActive(traits)) return UIColor.blackColor;
    UIUserInterfaceStyle style = traits.userInterfaceStyle;
    if (style == UIUserInterfaceStyleUnspecified) {
        style = UIScreen.mainScreen.traitCollection.userInterfaceStyle;
    }
    return style == UIUserInterfaceStyleDark
        ? [UIColor colorWithRed:0.035 green:0.045 blue:0.065 alpha:1.0]
        : [UIColor colorWithRed:0.955 green:0.962 blue:0.976 alpha:1.0];
}

UIColor *WolFoxInterfaceSurfaceColor(UITraitCollection *traits) {
    if (WolFoxOLEDActive(traits)) {
        return [UIColor colorWithWhite:0.055 alpha:1.0];
    }
    UIUserInterfaceStyle style = traits.userInterfaceStyle;
    if (style == UIUserInterfaceStyleUnspecified) {
        style = UIScreen.mainScreen.traitCollection.userInterfaceStyle;
    }
    return style == UIUserInterfaceStyleDark
        ? [UIColor colorWithRed:0.085 green:0.105 blue:0.145 alpha:1.0]
        : UIColor.whiteColor;
}

BOOL WolFoxSponsorBlockEnabled(void) {
    if (!WolFoxMasterEnabled()) {
        return NO;
    }

    return [WolFoxDefaults() boolForKey:WolFoxSponsorBlockKey];
}

void WolFoxSetPreference(NSString *key, BOOL enabled) {
    if (key.length == 0) {
        return;
    }

    if ([key isEqualToString:WolFoxMasterEnabledKey]) {
        [WolFoxDefaults() setBool:YES forKey:key];
        WolFoxAnnouncePreferenceChange(key);
        return;
    }
    [WolFoxDefaults() setBool:enabled forKey:key];
    WolFoxAnnouncePreferenceChange(key);
}

id WolFoxPreferenceObject(NSString *key) {
    if (key.length == 0) {
        return nil;
    }
    return [WolFoxDefaults() objectForKey:key];
}

void WolFoxSetPreferenceObject(NSString *key, id value) {
    if (key.length == 0) {
        return;
    }
    if (value == nil) {
        [WolFoxDefaults() removeObjectForKey:key];
    } else {
        [WolFoxDefaults() setObject:value forKey:key];
    }
    WolFoxAnnouncePreferenceChange(key);
}

static NSString *WolFoxRelativeStoragePath(NSURL *URL, NSURL *baseURL) {
    NSString *path = URL.URLByResolvingSymlinksInPath.path.stringByStandardizingPath;
    NSString *base = baseURL.URLByResolvingSymlinksInPath.path.stringByStandardizingPath;
    NSString *prefix = [base stringByAppendingString:@"/"];
    if (![path hasPrefix:prefix]) return nil;
    return [path substringFromIndex:prefix.length];
}

static void WolFoxRepairDownloads(NSURL *root) {
    NSFileManager *manager = NSFileManager.defaultManager;
    NSURL *downloads = [root URLByAppendingPathComponent:@"Downloads" isDirectory:YES];
    NSArray<NSURL *> *items = [[manager enumeratorAtURL:downloads
        includingPropertiesForKeys:@[NSURLIsDirectoryKey]
                           options:0 errorHandler:nil] allObjects];
    for (NSURL *source in items) {
        NSNumber *directory = nil;
        [source getResourceValue:&directory forKey:NSURLIsDirectoryKey error:nil];
        if (directory.boolValue) continue;
        NSString *relative = WolFoxRelativeStoragePath(source, downloads);
        NSArray<NSString *> *components = relative.pathComponents;
        NSUInteger categoryIndex = NSNotFound;
        NSString *category = nil;
        for (NSUInteger index = 0; index < components.count; index++) {
            for (NSString *candidate in @[@"Video", @"Audio", @"Shorts"]) {
                if ([components[index] caseInsensitiveCompare:candidate] == NSOrderedSame) {
                    categoryIndex = index;
                    category = candidate;
                    break;
                }
            }
            if (categoryIndex != NSNotFound) break;
        }
        if (categoryIndex == NSNotFound || categoryIndex + 1 >= components.count) continue;
        NSURL *target = [downloads URLByAppendingPathComponent:category isDirectory:YES];
        for (NSUInteger index = categoryIndex + 1; index < components.count; index++) {
            target = [target URLByAppendingPathComponent:components[index]];
        }
        if ([source.URLByResolvingSymlinksInPath.path
                isEqualToString:target.URLByResolvingSymlinksInPath.path]) continue;
        [manager createDirectoryAtURL:target.URLByDeletingLastPathComponent
          withIntermediateDirectories:YES attributes:nil error:nil];
        if ([manager fileExistsAtPath:target.path]) {
            [manager removeItemAtURL:source error:nil];
        } else {
            [manager moveItemAtURL:source toURL:target error:nil];
        }
    }
    for (NSString *name in @[@"Downloads", @"ownloads"]) {
        [manager removeItemAtURL:[downloads URLByAppendingPathComponent:name isDirectory:YES]
                           error:nil];
    }
}

NSUInteger WolFoxPurgeSystemCaches(void) {
    NSFileManager *manager = NSFileManager.defaultManager;
    NSArray<NSURL *> *roots = [manager URLsForDirectory:NSCachesDirectory
                                             inDomains:NSUserDomainMask];
    NSUInteger freed = 0;
    for (NSURL *root in roots) {
        NSArray<NSURL *> *entries = [manager contentsOfDirectoryAtURL:root
            includingPropertiesForKeys:@[NSURLTotalFileAllocatedSizeKey]
                               options:0 error:nil];
        for (NSURL *entry in entries) {
            NSDirectoryEnumerator *walker = [manager enumeratorAtURL:entry
                includingPropertiesForKeys:@[NSURLTotalFileAllocatedSizeKey]
                                   options:0 errorHandler:nil];
            NSNumber *own = nil;
            [entry getResourceValue:&own forKey:NSURLTotalFileAllocatedSizeKey
                              error:nil];
            freed += own.unsignedIntegerValue;
            for (NSURL *child in walker) {
                NSNumber *size = nil;
                [child getResourceValue:&size
                                 forKey:NSURLTotalFileAllocatedSizeKey error:nil];
                freed += size.unsignedIntegerValue;
            }
            [manager removeItemAtURL:entry error:nil];
        }
    }
    return freed;
}

NSURL *WolFoxApplicationSupportDirectory(void) {
    NSFileManager *manager = NSFileManager.defaultManager;
    NSURL *documents = [manager URLsForDirectory:NSDocumentDirectory
                                        inDomains:NSUserDomainMask].firstObject;
    NSURL *directory = [documents URLByAppendingPathComponent:@"YTKACE"
                                                   isDirectory:YES];
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSURL *support = [manager URLsForDirectory:NSApplicationSupportDirectory
                                         inDomains:NSUserDomainMask].firstObject;
        NSURL *legacy = [support URLByAppendingPathComponent:@"YTKACE"
                                                  isDirectory:YES];
        BOOL targetExists = [manager fileExistsAtPath:directory.path];
        if (!targetExists && [manager fileExistsAtPath:legacy.path]) {
            [manager moveItemAtURL:legacy toURL:directory error:nil];
        }
        [manager createDirectoryAtURL:directory
          withIntermediateDirectories:YES
                           attributes:nil
                                error:nil];
        if ([manager fileExistsAtPath:legacy.path]) {
            NSDirectoryEnumerator<NSURL *> *items = [manager
                enumeratorAtURL:legacy
     includingPropertiesForKeys:@[NSURLIsDirectoryKey]
                        options:0
                   errorHandler:nil];
            for (NSURL *source in items) {
                NSString *relative = WolFoxRelativeStoragePath(source, legacy);
                if (relative.length == 0) continue;
                NSURL *destination = [directory URLByAppendingPathComponent:relative];
                NSNumber *isDirectory = nil;
                [source getResourceValue:&isDirectory forKey:NSURLIsDirectoryKey error:nil];
                if (isDirectory.boolValue) {
                    [manager createDirectoryAtURL:destination
                      withIntermediateDirectories:YES attributes:nil error:nil];
                } else if (![manager fileExistsAtPath:destination.path]) {
                    [manager createDirectoryAtURL:destination.URLByDeletingLastPathComponent
                      withIntermediateDirectories:YES attributes:nil error:nil];
                    [manager moveItemAtURL:source toURL:destination error:nil];
                }
            }
            [manager removeItemAtURL:legacy error:nil];
        }
        WolFoxRepairDownloads(directory);
    });
    return directory;
}
