#import "../WolFox.h"
#import "../Runtime/Hooking.h"
#import "../Features/Interface/NavigationVisibility.h"
#import "../UI/Assets.h"
#import "WolFoxRootOptionsController.h"

#import <objc/runtime.h>

static IMP OriginalPivotViewDidAppear;
static IMP OriginalRightButtonsLayoutSubviews;
static const void *WolFoxSettingsButtonAssociation = &WolFoxSettingsButtonAssociation;

static UIViewController *WolFoxTopViewController(UIViewController *controller) {
    if (controller.presentedViewController != nil) {
        return WolFoxTopViewController(controller.presentedViewController);
    }
    if ([controller isKindOfClass:UINavigationController.class]) {
        return WolFoxTopViewController(((UINavigationController *)controller).visibleViewController);
    }
    if ([controller isKindOfClass:UITabBarController.class]) {
        return WolFoxTopViewController(((UITabBarController *)controller).selectedViewController);
    }
    return controller;
}

@interface WolFoxSettingsPresenter : NSObject
+ (instancetype)sharedPresenter;
- (void)openSettings;
@end

@implementation WolFoxSettingsPresenter

+ (instancetype)sharedPresenter {
    static WolFoxSettingsPresenter *presenter;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        presenter = [WolFoxSettingsPresenter new];
    });
    return presenter;
}

- (void)openSettings {
    UIWindow *window = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) {
            continue;
        }
        for (UIWindow *candidate in ((UIWindowScene *)scene).windows) {
            if (window == nil &&
                scene.activationState == UISceneActivationStateForegroundActive) {
                window = candidate;
            }
            if (candidate.isKeyWindow) {
                window = candidate;
                break;
            }
        }
        if (window != nil) {
            break;
        }
    }
    UIViewController *presenter = WolFoxTopViewController(window.rootViewController);
    if ([presenter.presentedViewController isKindOfClass:UINavigationController.class] &&
        [((UINavigationController *)presenter.presentedViewController).viewControllers.firstObject
            isKindOfClass:WolFoxRootOptionsController.class]) {
        return;
    }
    [presenter presentViewController:WolFoxMakeSettingsNavigationController()
                            animated:YES
                          completion:nil];
}

@end

static UIBarButtonItem *WolFoxSettingsBarButton(void) {
    UIImage *image = [WolFoxGearImage()
        imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    return [[UIBarButtonItem alloc] initWithImage:image
                                           style:UIBarButtonItemStylePlain
                                          target:WolFoxSettingsPresenter.sharedPresenter
                                          action:@selector(openSettings)];
}

static void WolFoxPivotViewDidAppear(id receiver, SEL selector, BOOL animated) {
    if (OriginalPivotViewDidAppear != NULL) {
        ((void (*)(id, SEL, BOOL))OriginalPivotViewDidAppear)(receiver, selector, animated);
    }

    if (![receiver isKindOfClass:UIViewController.class]) {
        return;
    }
    UIViewController *controller = receiver;
    if (objc_getAssociatedObject(controller, WolFoxSettingsButtonAssociation) != nil) {
        return;
    }

    NSMutableArray<UIBarButtonItem *> *items =
        [controller.navigationItem.rightBarButtonItems mutableCopy] ?: [NSMutableArray array];
    [items insertObject:WolFoxSettingsBarButton() atIndex:0];
    controller.navigationItem.rightBarButtonItems = items;
    objc_setAssociatedObject(controller,
                             WolFoxSettingsButtonAssociation,
                             @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void WolFoxRightButtonsLayoutSubviews(UIView *receiver, SEL selector) {
    if (OriginalRightButtonsLayoutSubviews != NULL) {
        ((void (*)(id, SEL))OriginalRightButtonsLayoutSubviews)(receiver, selector);
    }
    if (objc_getAssociatedObject(receiver, WolFoxSettingsButtonAssociation) != nil) {
        WolFoxApplyRightNavigationVisibility(receiver);
        WolFoxApplyTopNavigationGlass(receiver);
        return;
    }

    UIStackView *stack = nil;
    for (UIView *subview in receiver.subviews) {
        if ([subview isKindOfClass:UIStackView.class]) {
            stack = (UIStackView *)subview;
            break;
        }
    }
    if (stack == nil) {
        WolFoxApplyTopNavigationGlass(receiver);
        return;
    }

    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setImage:[WolFoxGearImage()
        imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate]
             forState:UIControlStateNormal];
    button.accessibilityLabel = @"WolFox Settings";
    [button addTarget:WolFoxSettingsPresenter.sharedPresenter
               action:@selector(openSettings)
     forControlEvents:UIControlEventTouchUpInside];
    [button.widthAnchor constraintEqualToConstant:32.0].active = YES;
    [button.heightAnchor constraintEqualToConstant:32.0].active = YES;
    [stack insertArrangedSubview:button atIndex:0];

    objc_setAssociatedObject(receiver,
                             WolFoxSettingsButtonAssociation,
                             button,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    WolFoxApplyRightNavigationVisibility(receiver);
    WolFoxApplyTopNavigationGlass(receiver);
}

void WolFoxInstallSettingsEntryHooks(void) {
    WolFoxInstallInstanceHook(@"YTPivotBarViewController",
                              @"viewDidAppear:",
                              (IMP)WolFoxPivotViewDidAppear,
                              &OriginalPivotViewDidAppear);
    WolFoxInstallInstanceHook(@"YTRightNavigationButtons",
                              @"layoutSubviews",
                              (IMP)WolFoxRightButtonsLayoutSubviews,
                              &OriginalRightButtonsLayoutSubviews);
}
