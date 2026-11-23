#import "../../WolFox.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"
#import "../Downloads/DownloadLog.h"

#import <UIKit/UIKit.h>
#import <objc/message.h>

static NSString *const WolFoxAutoFullscreenKey = @"YTKACE.Preference.Player.AutoFullscreen";
static NSString *const WolFoxExitFullscreenKey = @"YTKACE.Preference.Player.ExitFullscreenAtEnd";

static NSString *WolFoxFullscreenEnteredVideo;
static NSString *WolFoxFullscreenExitedVideo;

static IMP OriginalAllowedFullscreenOrientations;
static IMP OriginalWatchSupportedOrientations;
static IMP OriginalLegacyUpdateOrientations;
static IMP OriginalRequestFullscreenGeometry;
static IMP OriginalCompleteFullscreenPresentation;

static UIInterfaceOrientation WolFoxPreferredFullscreenOrientation(void) {
    if (!WolFoxMasterEnabled()) return UIInterfaceOrientationUnknown;

    id value = WolFoxPreferenceObject(WolFoxFullscreenOrientationKey);
    if ([value isEqual:@(WolFoxFullscreenOrientationLeft)]) return UIInterfaceOrientationLandscapeLeft;
    if ([value isEqual:@(WolFoxFullscreenOrientationRight)]) return UIInterfaceOrientationLandscapeRight;
    return UIInterfaceOrientationUnknown;
}

static UIInterfaceOrientationMask WolFoxFullscreenMask(UIInterfaceOrientation orientation) {
    return (UIInterfaceOrientationMask)(1UL << orientation);
}

static UIInterfaceOrientationMask WolFoxConstrainFullscreenLandscape(UIInterfaceOrientationMask mask) {
    if (!(mask & UIInterfaceOrientationMaskLandscape)) return mask;

    UIInterfaceOrientation preferred = WolFoxPreferredFullscreenOrientation();
    if (preferred == UIInterfaceOrientationUnknown) return mask;
    return (mask & ~UIInterfaceOrientationMaskLandscape) | WolFoxFullscreenMask(preferred);
}

// Keep YouTube's choice (vertical videos stay portrait) and only pick the
// landscape side.
static UIInterfaceOrientationMask WolFoxAllowedFullscreenOrientations(id receiver, SEL selector) {
    UIInterfaceOrientationMask mask =
        ((UIInterfaceOrientationMask (*)(id, SEL))OriginalAllowedFullscreenOrientations)(receiver, selector);
    return WolFoxConstrainFullscreenLandscape(mask);
}

static BOOL WolFoxWatchIsFullscreen(id receiver) {
    SEL selector = NSSelectorFromString(@"isWatchFullScreen");
    return [receiver respondsToSelector:selector] && ((BOOL (*)(id, SEL))objc_msgSend)(receiver, selector);
}

static BOOL WolFoxWatchHasLensOverlay(id receiver) {
    Ivar lens = class_getInstanceVariable(object_getClass(receiver), "_lensPostCaptureViewController");
    return lens != NULL && ivar_getTypeEncoding(lens)[0] == '@' && object_getIvar(receiver, lens) != nil;
}

static UIInterfaceOrientationMask WolFoxWatchSupportedOrientations(id receiver, SEL selector) {
    UIInterfaceOrientationMask mask =
        ((UIInterfaceOrientationMask (*)(id, SEL))OriginalWatchSupportedOrientations)(receiver, selector);
    // The watch layer also handles fullscreen without presenting a separate controller.
    if ((mask == UIInterfaceOrientationMaskLandscape || WolFoxWatchIsFullscreen(receiver)) &&
        !WolFoxWatchHasLensOverlay(receiver)) {
        return WolFoxConstrainFullscreenLandscape(mask);
    }
    return mask;
}

static void WolFoxLegacyUpdateOrientations(id receiver, SEL selector, UIInterfaceOrientation orientation) {
    if (UIInterfaceOrientationIsLandscape(orientation)) {
        UIInterfaceOrientation preferred = WolFoxPreferredFullscreenOrientation();
        if (preferred != UIInterfaceOrientationUnknown) orientation = preferred;
    }
    ((void (*)(id, SEL, UIInterfaceOrientation))OriginalLegacyUpdateOrientations)(receiver, selector, orientation);
}

static void WolFoxRequestFullscreenGeometry(id receiver, SEL selector, UIInterfaceOrientationMask mask,
                                           void (^errorHandler)(NSError *)) {
    ((void (*)(id, SEL, UIInterfaceOrientationMask, void (^)(NSError *)))OriginalRequestFullscreenGeometry)(
        receiver, selector, WolFoxConstrainFullscreenLandscape(mask), errorHandler);
}

static void WolFoxCompleteFullscreenPresentation(UIViewController *receiver, SEL selector) {
    ((void (*)(id, SEL))OriginalCompleteFullscreenPresentation)(receiver, selector);
    UIInterfaceOrientation preferred = WolFoxPreferredFullscreenOrientation();
    if (preferred == UIInterfaceOrientationUnknown || !WolFoxWatchIsFullscreen(receiver) ||
        WolFoxWatchHasLensOverlay(receiver)) return;

    if (@available(iOS 16.0, *)) {
        // YouTube can skip its geometry request when the scene is already in landscape.
        // Only the side: a vertical video in portrait fullscreen stays portrait.
        UIWindowScene *scene = receiver.viewIfLoaded.window.windowScene;
        if (scene == nil || scene.interfaceOrientation == preferred ||
            !UIInterfaceOrientationIsLandscape(scene.interfaceOrientation)) return;
        WolFoxDebugLog(@"fullscreen", @"turning to side %ld from %ld", (long)preferred,
                       (long)scene.interfaceOrientation);

        [receiver setNeedsUpdateOfSupportedInterfaceOrientations];
        UIWindowSceneGeometryPreferencesIOS *geometry = [[UIWindowSceneGeometryPreferencesIOS alloc]
            initWithInterfaceOrientations:WolFoxFullscreenMask(preferred)];
        [scene requestGeometryUpdateWithPreferences:geometry errorHandler:^(NSError *error) {
            WolFoxDebugLog(@"fullscreen", @"preferred landscape request failed: %@", error.localizedDescription);
        }];
    }
}

static id WolFoxFullscreenGet(id object, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    if (object == nil || ![object respondsToSelector:selector]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(object, selector);
}

static double WolFoxFullscreenDouble(id object, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    if (object == nil || ![object respondsToSelector:selector]) return 0.0;
    return ((double (*)(id, SEL))objc_msgSend)(object, selector);
}

static NSString *WolFoxFullscreenVideoID(id player) {
    id value = WolFoxFullscreenGet(player, @"currentVideoID");
    return [value isKindOfClass:NSString.class] ? value : nil;
}

// Only the watch page player, not feed previews or Shorts.
static id WolFoxMainOverlay(id player) {
    id overlay = WolFoxFullscreenGet(player, @"activeVideoPlayerOverlay");
    Class main = NSClassFromString(@"YTMainAppVideoPlayerOverlayViewController");
    return main != Nil && [overlay isKindOfClass:main] ? overlay : nil;
}

static BOOL WolFoxPlayerIsFullscreen(id overlay) {
    SEL selector = NSSelectorFromString(@"isFullscreen");
    return [overlay respondsToSelector:selector] &&
        ((BOOL (*)(id, SEL))objc_msgSend)(overlay, selector);
}

// The miniplayer and a backgrounded app shouldn't jump into fullscreen.
static BOOL WolFoxPlayerOnScreen(id player) {
    if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return NO;
    UIView *view = [player isKindOfClass:UIViewController.class] ? ((UIViewController *)player).view : nil;
    UIWindow *window = view.window;
    if (window == nil || view.hidden || CGRectIsEmpty(window.bounds)) return NO;
    CGRect frame = [view convertRect:view.bounds toView:window];
    return CGRectGetWidth(frame) >= CGRectGetWidth(window.bounds) * 0.5;
}

// The overlay has the toggle on new versions, the player on older ones.
static void WolFoxToggleFullscreen(id player, NSString *stage) {
    SEL toggle = NSSelectorFromString(@"didPressToggleFullscreen");
    id overlay = WolFoxMainOverlay(player);
    id target = [overlay respondsToSelector:toggle] ? overlay
        : [player respondsToSelector:toggle] ? player : nil;
    if (target == nil) {
        WolFoxDebugLog(@"fullscreen", @"%@ toggle unavailable", stage);
        return;
    }
    ((void (*)(id, SEL))objc_msgSend)(target, toggle);
    WolFoxDebugLog(@"fullscreen", @"%@ toggled on %@", stage, NSStringFromClass([target class]));
}

void WolFoxFullscreenVideoActivated(id player) {
    if (!WolFoxFeatureEnabled(WolFoxAutoFullscreenKey) || WolFoxMainOverlay(player) == nil) return;
    NSString *videoID = WolFoxFullscreenVideoID(player);
    if (videoID.length == 0 || [videoID isEqualToString:WolFoxFullscreenEnteredVideo]) return;
    WolFoxFullscreenEnteredVideo = [videoID copy];
    __weak id weakPlayer = player;
    // wait for the watch page to finish opening
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        id strong = weakPlayer;
        id overlay = WolFoxMainOverlay(strong);
        if (overlay == nil || ![WolFoxFullscreenVideoID(strong) isEqualToString:videoID]) return;
        if (WolFoxPlayerIsFullscreen(overlay)) return;
        if (!WolFoxPlayerOnScreen(strong)) {
            WolFoxDebugLog(@"fullscreen", @"auto skipped video=%@ not on screen", videoID);
            return;
        }
        WolFoxToggleFullscreen(strong, @"auto");
    });
}

static BOOL WolFoxLoopOn(void) {
    return WolFoxFeatureEnabled(WolFoxLoopKey) &&
        [NSUserDefaults.standardUserDefaults boolForKey:@"defaultLoop_enabled"];
}

@interface WolFoxFullscreenObserver : NSObject
@end

@implementation WolFoxFullscreenObserver

- (void)timeChanged:(NSNotification *)notification {
    if (!WolFoxFeatureEnabled(WolFoxExitFullscreenKey)) return;
    id player = notification.object;
    id overlay = WolFoxMainOverlay(player);
    if (overlay == nil) return;
    const double time = [notification.userInfo[@"time"] doubleValue];
    const double total = WolFoxFullscreenDouble(player, @"currentVideoTotalMediaTime");
    if (total <= 1.0 || time < total - 0.35) return;
    NSString *videoID = WolFoxFullscreenVideoID(player);
    if (videoID.length == 0 || [videoID isEqualToString:WolFoxFullscreenExitedVideo]) return;
    WolFoxFullscreenExitedVideo = [videoID copy];
    if (!WolFoxPlayerIsFullscreen(overlay) || WolFoxLoopOn() || WolFoxQueueVideoIsLive(videoID, player)) return;
    WolFoxToggleFullscreen(player, @"end");
}

@end

void WolFoxInstallFullscreenHooks(void) {
    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPhone) {
        NSString *watchLayer = @"YTWatchLayerViewController";
        WolFoxInstallInstanceHook(@"YTWatchViewController", @"allowedFullScreenOrientations",
                                  (IMP)WolFoxAllowedFullscreenOrientations, &OriginalAllowedFullscreenOrientations);
        WolFoxInstallInstanceHook(watchLayer, @"supportedInterfaceOrientations",
                                  (IMP)WolFoxWatchSupportedOrientations, &OriginalWatchSupportedOrientations);
        WolFoxInstallInstanceHook(watchLayer, @"updateSupportedInterfaceOrientations:",
                                  (IMP)WolFoxLegacyUpdateOrientations, &OriginalLegacyUpdateOrientations);
        WolFoxInstallInstanceHook(watchLayer, @"requestGeometryUpdateWithInterfaceOrientationMask:errorHandler:",
                                  (IMP)WolFoxRequestFullscreenGeometry, &OriginalRequestFullscreenGeometry);
        WolFoxInstallInstanceHook(watchLayer, @"didCompleteFullscreenPresentAnimation",
                                  (IMP)WolFoxCompleteFullscreenPresentation, &OriginalCompleteFullscreenPresentation);
    }

    static WolFoxFullscreenObserver *observer;
    observer = [WolFoxFullscreenObserver new];
    [NSNotificationCenter.defaultCenter addObserver:observer
                                           selector:@selector(timeChanged:)
                                               name:@"WolFoxPlaybackTimeDidChange"
                                             object:nil];
}
