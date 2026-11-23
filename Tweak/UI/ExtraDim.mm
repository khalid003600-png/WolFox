#import "../WolFox.h"
#import "../Runtime/Preferences.h"

#import <UIKit/UIKit.h>

static NSString *const WolFoxExtraDimKey = @"YTKACE.Preference.Appearance.ExtraDim";
static UIWindow *WolFoxDimWindow;

// The dim window sits above the app, so iOS asks it for orientation and
// status bar. Pass those through to the app's own window.
static UIViewController *WolFoxAppViewController(UIWindow *dimWindow) {
    UIWindow *appWindow = nil;
    for (UIWindow *window in dimWindow.windowScene.windows) {
        if (window == dimWindow || window.hidden || window.rootViewController == nil) continue;
        if (window.isKeyWindow) { appWindow = window; break; }
        if (appWindow == nil) appWindow = window;
    }
    UIViewController *controller = appWindow.rootViewController;
    while (controller.presentedViewController != nil &&
           !controller.presentedViewController.isBeingDismissed) {
        controller = controller.presentedViewController;
    }
    return controller;
}

@interface WolFoxDimWindowController : UIViewController
@end

@implementation WolFoxDimWindowController
- (UIViewController *)ytkace_appController {
    return WolFoxAppViewController(self.view.window);
}
- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    UIViewController *app = [self ytkace_appController];
    return app != nil ? app.supportedInterfaceOrientations : UIInterfaceOrientationMaskAll;
}
- (BOOL)shouldAutorotate {
    UIViewController *app = [self ytkace_appController];
    return app != nil ? app.shouldAutorotate : YES;
}
- (UIViewController *)childViewControllerForStatusBarHidden {
    return [self ytkace_appController];
}
- (UIViewController *)childViewControllerForStatusBarStyle {
    return [self ytkace_appController];
}
- (UIViewController *)childViewControllerForHomeIndicatorAutoHidden {
    return [self ytkace_appController];
}
@end

@interface WolFoxDimOverlayWindow : UIWindow
@end

@implementation WolFoxDimOverlayWindow
- (BOOL)_canAffectStatusBarAppearance {
    return NO;
}
- (BOOL)_canBecomeKeyWindow {
    return NO;
}
@end

static UIWindowScene *WolFoxActiveScene(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if ([scene isKindOfClass:UIWindowScene.class] &&
            scene.activationState == UISceneActivationStateForegroundActive) {
            return (UIWindowScene *)scene;
        }
    }
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if ([scene isKindOfClass:UIWindowScene.class]) return (UIWindowScene *)scene;
    }
    return nil;
}

static void WolFoxUpdateExtraDim(void) {
    double percent = WolFoxMasterEnabled() ? [WolFoxPreferenceObject(WolFoxExtraDimKey) doubleValue] : 0.0;
    CGFloat alpha = (CGFloat)MAX(0.0, MIN(85.0, percent)) / 100.0;
    if (alpha <= 0.001) {
        WolFoxDimWindow.hidden = YES;
        return;
    }
    UIWindowScene *scene = WolFoxActiveScene();
    if (scene == nil) return;
    if (WolFoxDimWindow == nil || WolFoxDimWindow.windowScene != scene) {
        WolFoxDimWindow = [[WolFoxDimOverlayWindow alloc] initWithWindowScene:scene];
        WolFoxDimWindow.rootViewController = [WolFoxDimWindowController new];
        WolFoxDimWindow.rootViewController.view.backgroundColor = UIColor.clearColor;
        WolFoxDimWindow.windowLevel = UIWindowLevelStatusBar + 100.0;
        WolFoxDimWindow.userInteractionEnabled = NO;
    }
    WolFoxDimWindow.backgroundColor = [UIColor colorWithWhite:0.0 alpha:alpha];
    WolFoxDimWindow.hidden = NO;
}

__attribute__((constructor)) static void WolFoxInstallExtraDim(void) {
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    for (NSNotificationName name in @[UIApplicationDidBecomeActiveNotification,
                                       WolFoxPreferencesDidChangeNotification]) {
        [center addObserverForName:name object:nil queue:NSOperationQueue.mainQueue
                        usingBlock:^(__unused NSNotification *note) {
            WolFoxUpdateExtraDim();
        }];
    }
}
