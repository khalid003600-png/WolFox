#import "../../WolFox.h"
#import "../../Runtime/Localization.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"
#import "../../UI/Notice.h"

#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

static IMP OriginalControlSendAction;
static NSMutableDictionary<NSString *, NSValue *> *WolFoxStatusOriginals;
static BOOL WolFoxCastBypass;

static BOOL WolFoxIsCastControl(UIControl *control, SEL action, id target) {
    (void)target;
    NSString *token = [[NSString stringWithFormat:@"%@ %@ %@ %@",
        NSStringFromClass(control.class),
        control.accessibilityIdentifier ?: @"",
        control.accessibilityLabel ?: @"",
        NSStringFromSelector(action)]
        lowercaseString];
    return [token containsString:@"cast"] ||
        [token containsString:@"airplay"] ||
        [token containsString:@"routebutton"] ||
        [token containsString:@"mdx"];
}

static void WolFoxControlSendAction(UIControl *receiver,
                                    SEL selector,
                                    SEL action,
                                    id target,
                                    UIEvent *event) {
    if (OriginalControlSendAction == NULL) {
        return;
    }
    BOOL castControl = WolFoxIsCastControl(receiver, action, target);
    if (castControl) {
        WolFoxStartCastDiscovery();
    }
    if (WolFoxCastBypass ||
        !WolFoxFeatureEnabled(@"YTKACE.Preference.Navigation.CastConfirmation") ||
        !castControl) {
        ((void (*)(id, SEL, SEL, id, id))OriginalControlSendAction)(
            receiver, selector, action, target, event
        );
        return;
    }
    __weak UIControl *weakReceiver = receiver;
    __weak id weakTarget = target;
    BOOL shown = WolFoxShowYouTubeConfirmation(
        WolFoxLocalized(@"Connect to a device?"),
        WolFoxLocalized(@"YouTube is about to open the Cast menu."),
        WolFoxLocalized(@"Continue"),
        ^{
            UIControl *strongReceiver = weakReceiver;
            if (strongReceiver == nil) {
                return;
            }
            WolFoxCastBypass = YES;
            ((void (*)(id, SEL, SEL, id, id))OriginalControlSendAction)(
                strongReceiver, selector, action, weakTarget, event
            );
            WolFoxCastBypass = NO;
        }
    );
    if (!shown) {
        ((void (*)(id, SEL, SEL, id, id))OriginalControlSendAction)(
            receiver, selector, action, target, event
        );
    }
}

static NSString *WolFoxStatusKey(Class cls, SEL selector) {
    return [NSString stringWithFormat:@"%@|%@", NSStringFromClass(cls),
                                      NSStringFromSelector(selector)];
}

static IMP WolFoxStatusOriginal(id receiver, SEL selector) {
    for (Class cls = object_getClass(receiver); cls != Nil; cls = class_getSuperclass(cls)) {
        IMP original = (IMP)[WolFoxStatusOriginals[
            WolFoxStatusKey(cls, selector)] pointerValue];
        if (original != NULL) {
            return original;
        }
    }
    return NULL;
}

static BOOL WolFoxPrefersStatusHidden(id receiver, SEL selector) {
    if (WolFoxFeatureEnabled(@"YTKACE.Preference.Navigation.StatusBarHidden")) {
        return YES;
    }
    NSString *name = NSStringFromClass([receiver class]).lowercaseString;
    if (WolFoxFeatureEnabled(@"YTKACE.Preference.Overlay.StatusBarVisible") &&
        ([name containsString:@"player"] || [name containsString:@"watch"])) {
        return NO;
    }
    IMP original = WolFoxStatusOriginal(receiver, selector);
    return original != NULL ? ((BOOL (*)(id, SEL))original)(receiver, selector) : NO;
}

void WolFoxInstallNavigationBehaviorHooks(void) {
    if (WolFoxStatusOriginals == nil) {
        WolFoxStatusOriginals = [NSMutableDictionary dictionary];
    }
    WolFoxInstallInstanceHook(@"UIControl",
                              @"sendAction:to:forEvent:",
                              (IMP)WolFoxControlSendAction,
                              &OriginalControlSendAction);
    for (NSString *className in @[
        @"YTAppViewController",
        @"YTWatchViewController",
        @"YTWatchLayerViewController",
        @"YTPlayerViewController",
        @"YTMainAppVideoPlayerOverlayViewController",
        @"YTShortsPlayerViewController"
    ]) {
        IMP original = NULL;
        if (WolFoxInstallInstanceHook(className,
                                      @"prefersStatusBarHidden",
                                      (IMP)WolFoxPrefersStatusHidden,
                                      &original) && original != NULL) {
            Class cls = NSClassFromString(className);
            WolFoxStatusOriginals[WolFoxStatusKey(
                cls,
                NSSelectorFromString(@"prefersStatusBarHidden")
            )] = [NSValue valueWithPointer:(const void *)original];
        }
    }
}
