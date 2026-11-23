#import "../../WolFox.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"

#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

static NSMutableDictionary<NSString *, NSValue *> *WolFoxStartupOriginals;

static IMP WolFoxStartupOriginal(id receiver, SEL selector) {
    for (Class cls = [receiver class]; cls != Nil; cls = class_getSuperclass(cls)) {
        NSString *key = [NSString stringWithFormat:@"%@|%@",
                         NSStringFromClass(cls),
                         NSStringFromSelector(selector)];
        NSValue *value = WolFoxStartupOriginals[key];
        if (value == nil) continue;
        IMP implementation = NULL;
        [value getValue:&implementation];
        return implementation;
    }
    return NULL;
}

static void WolFoxStartupBlacken(UIView *view) {
    if (view == nil) return;
    UIColor *background = view.backgroundColor;
    if (background != nil && CGColorGetAlpha(background.CGColor) > 0.01) {
        view.backgroundColor = UIColor.blackColor;
    }
    for (UIView *child in view.subviews) {
        WolFoxStartupBlacken(child);
    }
}

static void WolFoxStartupViewDidLoad(UIViewController *receiver,
                                     SEL selector) {
    IMP original = WolFoxStartupOriginal(receiver, selector);
    if (original != NULL) {
        ((void (*)(id, SEL))original)(receiver, selector);
    }
    if (WolFoxOLEDActive(receiver.traitCollection)) {
        receiver.view.backgroundColor = UIColor.blackColor;
        WolFoxStartupBlacken(receiver.view);
        receiver.view.window.backgroundColor = UIColor.blackColor;
    }
}

static void WolFoxFinishStartup(UIViewController *receiver) {
    SEL delegateSelector = NSSelectorFromString(@"delegate");
    id delegate = [receiver respondsToSelector:delegateSelector]
        ? ((id (*)(id, SEL))objc_msgSend)(receiver, delegateSelector)
        : nil;
    SEL completionSelector = NSSelectorFromString(@"startupAnimationDidComplete");
    if ([delegate respondsToSelector:completionSelector]) {
        ((void (*)(id, SEL))objc_msgSend)(delegate, completionSelector);
        return;
    }
    SEL forceSelector =
        NSSelectorFromString(@"forceDismissStartupAnimationAnimated:");
    if ([delegate respondsToSelector:forceSelector]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(delegate, forceSelector, NO);
        return;
    }
    [receiver dismissViewControllerAnimated:NO completion:nil];
}

static void WolFoxStartupViewDidAppear(UIViewController *receiver,
                                       SEL selector,
                                       BOOL animated) {
    IMP original = WolFoxStartupOriginal(receiver, selector);
    if (original != NULL) {
        ((void (*)(id, SEL, BOOL))original)(receiver, selector, animated);
    }
    if (WolFoxOLEDActive(receiver.traitCollection)) {
        receiver.view.backgroundColor = UIColor.blackColor;
        WolFoxStartupBlacken(receiver.view);
        receiver.view.window.backgroundColor = UIColor.blackColor;
    }
    if (WolFoxFeatureEnabled(@"YTKACE.Preference.Appearance.LaunchAnimationDisabled")) {
        dispatch_async(dispatch_get_main_queue(), ^{
            WolFoxFinishStartup(receiver);
        });
    }
}

static void WolFoxInstallStartupHook(NSString *className,
                                     NSString *selectorName,
                                     IMP replacement) {
    IMP original = NULL;
    if (!WolFoxInstallInstanceHook(className, selectorName,
                                   replacement, &original) ||
        original == NULL || original == replacement) {
        return;
    }
    WolFoxStartupOriginals[
        [NSString stringWithFormat:@"%@|%@", className, selectorName]
    ] = [NSValue value:&original withObjCType:@encode(IMP)];
}

void WolFoxInstallStartupHooks(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        WolFoxStartupOriginals = [NSMutableDictionary dictionary];
    });

    for (NSString *className in @[
        @"YTStartupAnimationViewController",
        @"YTRiveStartupAnimationViewController"
    ]) {
        WolFoxInstallStartupHook(className, @"viewDidLoad",
                                 (IMP)WolFoxStartupViewDidLoad);
        WolFoxInstallStartupHook(className, @"viewDidAppear:",
                                 (IMP)WolFoxStartupViewDidAppear);
    }
}
