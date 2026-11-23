#import "../../WolFox.h"
#import "../../UI/Notice.h"
#import "../../Runtime/Localization.h"

#import <UIKit/UIKit.h>

static NSString * const WolFoxOnboardingKey = @"YTKACE.Preference.Onboarding.Shown";

@interface WolFoxFirstLaunchFlow : NSObject <NSNetServiceBrowserDelegate>
@property(nonatomic, strong) NSNetServiceBrowser *browser;
@property(nonatomic, assign) NSInteger attempts;
@end

static WolFoxFirstLaunchFlow *WolFoxFirstLaunchInstance;

static UIViewController *WolFoxFirstLaunchPresenter(void) {
    UIWindow *window = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class] ||
            scene.activationState != UISceneActivationStateForegroundActive) continue;
        for (UIWindow *candidate in ((UIWindowScene *)scene).windows) {
            if (candidate.isKeyWindow) {
                window = candidate;
                break;
            }
        }
    }
    UIViewController *controller = window.rootViewController;
    while (controller.presentedViewController != nil) {
        controller = controller.presentedViewController;
    }
    return controller;
}

@implementation WolFoxFirstLaunchFlow

- (void)startCastRequest {
    self.browser = [NSNetServiceBrowser new];
    self.browser.delegate = self;
    [self.browser searchForServicesOfType:@"_googlecast._tcp." inDomain:@"local."];
    WolFoxStartCastDiscovery();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC),
        dispatch_get_main_queue(), ^{
            [self.browser stop];
            self.browser = nil;
        });
}

- (void)showSponsorBlockFrom:(UIViewController *)presenter {
    (void)presenter;
    if (WolFoxShowYouTubeDialog(
        WolFoxLocalized(@"SponsorBlock"),
        WolFoxLocalized(@"WolFox uses SponsorBlock data.\nLicensed under CC BY-NC-SA 4.0."))) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC),
            dispatch_get_main_queue(), ^{ [self startCastRequest]; });
        return;
    }
    WolFoxShowNotice(WolFoxLocalized(@"SponsorBlock data: CC BY-NC-SA 4.0"));
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 400 * NSEC_PER_MSEC),
        dispatch_get_main_queue(), ^{ [self startCastRequest]; });
}

- (void)show {
    UIViewController *presenter = WolFoxFirstLaunchPresenter();
    if (presenter == nil || presenter.view.window == nil) {
        self.attempts += 1;
        if (self.attempts < 20) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC),
                dispatch_get_main_queue(), ^{ [self show]; });
        }
        return;
    }
    [NSUserDefaults.standardUserDefaults setBool:YES forKey:WolFoxOnboardingKey];
    if (WolFoxShowYouTubeDialog(
        @"WolFox",
        WolFoxLocalized(@"To change these, open the WolFox tab and use the gear icon above."))) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC),
            dispatch_get_main_queue(), ^{
                UIViewController *nextPresenter = WolFoxFirstLaunchPresenter();
                if (nextPresenter != nil) [self showSponsorBlockFrom:nextPresenter];
            });
        return;
    }
    WolFoxShowNotice(WolFoxLocalized(@"Settings live in the WolFox tab, behind the gear icon."));
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 300 * NSEC_PER_MSEC),
        dispatch_get_main_queue(), ^{
            UIViewController *nextPresenter = WolFoxFirstLaunchPresenter();
            if (nextPresenter != nil) [self showSponsorBlockFrom:nextPresenter];
        });
}

@end

void WolFoxScheduleFirstLaunch(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        if ([NSUserDefaults.standardUserDefaults boolForKey:WolFoxOnboardingKey]) return;
        WolFoxFirstLaunchInstance = [WolFoxFirstLaunchFlow new];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC),
            dispatch_get_main_queue(), ^{ [WolFoxFirstLaunchInstance show]; });
    });
}
