#import "../../WolFox.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"
#import "../Interface/NavigationVisibility.h"

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static NSMutableDictionary<NSString *, NSValue *> *WolFoxOLEDOriginals;
static IMP OriginalQualitySheetDidAppear;
static IMP OriginalAppTraitChanged;
static IMP OriginalAppStatusBarStyle;

static NSValue *WolFoxOLEDValue(IMP implementation) {
    return [NSValue value:&implementation withObjCType:@encode(IMP)];
}

static IMP WolFoxOLEDImplementation(NSValue *value) {
    IMP implementation = NULL;
    [value getValue:&implementation];
    return implementation;
}

static NSString *WolFoxOLEDOriginalKey(id receiver, SEL selector) {
    BOOL classMethod = object_isClass(receiver);
    Class cls = classMethod ? receiver : [receiver class];
    return [NSString stringWithFormat:@"%@|%@|%@",
            classMethod ? @"+" : @"-",
            NSStringFromClass(cls),
            NSStringFromSelector(selector)];
}

static UIColor *WolFoxOLEDColor(id receiver, SEL selector) {
    IMP original = WolFoxOLEDImplementation(
        WolFoxOLEDOriginals[WolFoxOLEDOriginalKey(receiver, selector)]
    );
    UIColor *base = original == NULL
        ? nil
        : ((id (*)(id, SEL))original)(receiver, selector);
    if (!WolFoxFeatureEnabled(WolFoxOLEDKey)) return base;
    // light mode: leave YouTube's colors alone
    if (!WolFoxOLEDActive(nil)) return base;
    __weak id weakReceiver = receiver;
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
        if (WolFoxOLEDActive(traits)) return UIColor.blackColor;
        id target = weakReceiver;
        UIColor *current = target == nil || original == NULL
            ? base
            : ((id (*)(id, SEL))original)(target, selector);
        return current == nil ? [UIColor.systemBackgroundColor
            resolvedColorWithTraitCollection:traits]
            : [current resolvedColorWithTraitCollection:traits];
    }];
}

static void WolFoxRefreshStatusBars(UIViewController *controller) {
    if (controller == nil) return;
    [controller setNeedsStatusBarAppearanceUpdate];
    if ([controller isKindOfClass:UINavigationController.class]) {
        WolFoxRefreshStatusBars(((UINavigationController *)controller).visibleViewController);
    } else if ([controller isKindOfClass:UITabBarController.class]) {
        WolFoxRefreshStatusBars(((UITabBarController *)controller).selectedViewController);
    }
    WolFoxRefreshStatusBars(controller.presentedViewController);
}

static NSInteger WolFoxAppStatusBarStyle(UIViewController *receiver,
                                         SEL selector) {
    NSInteger original = OriginalAppStatusBarStyle == NULL
        ? UIStatusBarStyleDefault
        : ((NSInteger (*)(id, SEL))OriginalAppStatusBarStyle)(receiver, selector);
    if (!WolFoxFeatureEnabled(WolFoxOLEDKey)) return original;
    UIUserInterfaceStyle style = receiver.traitCollection.userInterfaceStyle;
    NSInteger result = style == UIUserInterfaceStyleDark
        ? UIStatusBarStyleLightContent
        : UIStatusBarStyleDarkContent;
    return result;
}

static void WolFoxAppTraitChanged(UIViewController *receiver,
                                  SEL selector,
                                  UITraitCollection *previous) {
    if (OriginalAppTraitChanged != NULL) {
        ((void (*)(id, SEL, id))OriginalAppTraitChanged)(receiver, selector, previous);
    }
    if (previous != nil &&
        ![receiver.traitCollection
            hasDifferentColorAppearanceComparedToTraitCollection:previous]) return;
    if (!WolFoxFeatureEnabled(WolFoxOLEDKey)) return;
    [receiver setNeedsStatusBarAppearanceUpdate];
    [receiver.view setNeedsLayout];
    WolFoxRefreshNavigationAppearance();
    dispatch_async(dispatch_get_main_queue(), ^{
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:UIWindowScene.class] ||
                scene.activationState != UISceneActivationStateForegroundActive) continue;
            for (UIWindow *window in ((UIWindowScene *)scene).windows) {
                WolFoxRefreshStatusBars(window.rootViewController);
                [window setNeedsLayout];
            }
        }
        WolFoxRefreshNavigationAppearance();
    });
}

static void WolFoxInstallColorHook(NSString *className,
                                   NSString *selectorName,
                                   BOOL classMethod) {
    IMP original = NULL;
    BOOL installed = classMethod
        ? WolFoxInstallClassHook(className,
                                selectorName,
                                (IMP)WolFoxOLEDColor,
                                &original)
        : WolFoxInstallInstanceHook(className,
                                   selectorName,
                                   (IMP)WolFoxOLEDColor,
                                   &original);
    if (!installed || original == NULL) {
        return;
    }
    NSString *key = [NSString stringWithFormat:@"%@|%@|%@",
                     classMethod ? @"+" : @"-",
                     className,
                     selectorName];
    if (WolFoxOLEDOriginals[key] == nil) {
        WolFoxOLEDOriginals[key] = WolFoxOLEDValue(original);
    }
}

static void WolFoxCollectQualityLabels(UIView *view,
                                       NSMutableArray<UILabel *> *labels) {
    if ([view isKindOfClass:UILabel.class]) {
        UILabel *label = (UILabel *)view;
        NSString *text = label.text ?: @"";
        NSRegularExpression *pattern = [NSRegularExpression
            regularExpressionWithPattern:@"^\\s*\\d{3,4}p(?:60)?" options:0 error:nil];
        if ([text localizedCaseInsensitiveContainsString:@"quality"] ||
            [pattern firstMatchInString:text options:0
                range:NSMakeRange(0, text.length)] != nil) {
            [labels addObject:label];
        }
    }
    for (UIView *child in view.subviews) {
        WolFoxCollectQualityLabels(child, labels);
    }
}

static UIView *WolFoxCommonAncestor(NSArray<UIView *> *views, UIView *limit) {
    UIView *candidate = views.firstObject;
    while (candidate != nil && candidate != limit.superview) {
        BOOL containsAll = YES;
        for (UIView *view in views) {
            if (view != candidate && ![view isDescendantOfView:candidate]) {
                containsAll = NO;
                break;
            }
        }
        if (containsAll) return candidate;
        candidate = candidate.superview;
    }
    return nil;
}

static void WolFoxBlackenQualitySurface(UIView *view) {
    if ([view isKindOfClass:UIVisualEffectView.class]) {
        UIVisualEffectView *effect = (UIVisualEffectView *)view;
        effect.effect = nil;
        effect.contentView.backgroundColor = UIColor.blackColor;
    }
    UIColor *background = view.backgroundColor;
    CGFloat alpha = background == nil ? 0.0 : CGColorGetAlpha(background.CGColor);
    if (alpha > 0.01 || [view isKindOfClass:UITableView.class] ||
        [view isKindOfClass:UICollectionView.class]) {
        view.backgroundColor = UIColor.blackColor;
    }
    if ([view isKindOfClass:UILabel.class]) {
        ((UILabel *)view).textColor = UIColor.whiteColor;
    }
    for (UIView *child in view.subviews) {
        WolFoxBlackenQualitySurface(child);
    }
}

static void WolFoxQualitySheetDidAppear(id receiver, SEL selector, BOOL animated) {
    if (OriginalQualitySheetDidAppear != NULL) {
        ((void (*)(id, SEL, BOOL))OriginalQualitySheetDidAppear)(
            receiver, selector, animated);
    }
    if (![receiver isKindOfClass:UIViewController.class] ||
        !WolFoxOLEDActive(((UIViewController *)receiver).traitCollection)) return;
    if (WolFoxLiquidGlassAvailable() && WolFoxFeatureEnabled(@"YTKACE.Preference.Glass.Menus")) return;
    UIView *root = ((UIViewController *)receiver).view;
    dispatch_async(dispatch_get_main_queue(), ^{
        NSMutableArray<UILabel *> *labels = [NSMutableArray array];
        WolFoxCollectQualityLabels(root, labels);
        NSUInteger qualityRows = 0;
        for (UILabel *label in labels) {
            if ([label.text rangeOfString:@"p"].location != NSNotFound) qualityRows++;
        }
        if (qualityRows < 2) return;
        UIView *surface = WolFoxCommonAncestor(labels, root);
        if (surface == nil || surface == root) {
            for (UIView *child in root.subviews) {
                NSUInteger count = 0;
                for (UILabel *label in labels) {
                    if ([label isDescendantOfView:child]) count++;
                }
                if (count == labels.count) {
                    surface = child;
                    break;
                }
            }
        }
        if (surface != nil && surface != root) {
            surface.backgroundColor = UIColor.blackColor;
            WolFoxBlackenQualitySurface(surface);
        }
    });
}

void WolFoxInstallOLEDHooks(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        WolFoxOLEDOriginals = [NSMutableDictionary dictionary];
    });

    for (NSString *selector in @[@"black0", @"black1", @"black2", @"black3", @"black4"]) {
        WolFoxInstallColorHook(@"YTColor", selector, YES);
    }

    NSArray<NSString *> *paletteSelectors = @[
        @"baseBackground",
        @"brandBackgroundPrimary",
        @"brandBackgroundSecondary",
        @"brandBackgroundSolid",
        @"brandSurfaceContainer",
        @"brandSurfaceContainerHigh",
        @"brandSurfaceContainerHighest",
        @"raisedBackground",
        @"staticBrandBlack",
        @"generalBackgroundA",
        @"generalBackgroundB",
        @"generalBackgroundC",
        @"menuBackground",
        @"dialogBackgroundColor",
        @"elevatedBackgroundColor"
    ];
    for (NSString *selector in paletteSelectors) {
        WolFoxInstallColorHook(@"YTCommonColorPalette", selector, NO);
        WolFoxInstallColorHook(@"YTCommonColorPalette", selector, YES);
    }

    WolFoxInstallInstanceHook(@"YTActionSheetDialogViewController",
                              @"viewDidAppear:",
                              (IMP)WolFoxQualitySheetDidAppear,
                              &OriginalQualitySheetDidAppear);
    WolFoxInstallInstanceHook(@"YTAppViewController",
                              @"traitCollectionDidChange:",
                              (IMP)WolFoxAppTraitChanged,
                              &OriginalAppTraitChanged);
    WolFoxInstallInstanceHook(@"YTAppViewController",
                              @"preferredStatusBarStyle",
                              (IMP)WolFoxAppStatusBarStyle,
                              &OriginalAppStatusBarStyle);

}
