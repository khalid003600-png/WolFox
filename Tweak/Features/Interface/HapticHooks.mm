#import "../../WolFox.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"
#import "../Downloads/DownloadLog.h"

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static NSString * const WolFoxHapticsDisabledKey = @"YTKACE.Preference.App.HapticsDisabled";
static NSMutableDictionary<NSString *, NSValue *> *WolFoxHapticOriginals;

static IMP WolFoxHapticOriginal(id receiver, SEL selector) {
    if (WolFoxFeatureEnabled(WolFoxHapticsDisabledKey)) return NULL;
    for (Class cls = object_getClass(receiver); cls != Nil; cls = class_getSuperclass(cls)) {
        NSString *key = [NSString stringWithFormat:@"%s|%s", class_getName(cls), sel_getName(selector)];
        IMP original = (IMP)[WolFoxHapticOriginals[key] pointerValue];
        if (original != NULL) return original;
    }
    return NULL;
}

static void WolFoxHapticPlain(id receiver, SEL selector) {
    IMP original = WolFoxHapticOriginal(receiver, selector);
    if (original != NULL) ((void (*)(id, SEL))original)(receiver, selector);
}

static void WolFoxHapticIntensity(id receiver, SEL selector, CGFloat intensity) {
    IMP original = WolFoxHapticOriginal(receiver, selector);
    if (original != NULL) ((void (*)(id, SEL, CGFloat))original)(receiver, selector, intensity);
}

static void WolFoxHapticLocation(id receiver, SEL selector, CGPoint location) {
    IMP original = WolFoxHapticOriginal(receiver, selector);
    if (original != NULL) ((void (*)(id, SEL, CGPoint))original)(receiver, selector, location);
}

static void WolFoxHapticIntensityLocation(id receiver, SEL selector, CGFloat intensity, CGPoint location) {
    IMP original = WolFoxHapticOriginal(receiver, selector);
    if (original != NULL) {
        ((void (*)(id, SEL, CGFloat, CGPoint))original)(receiver, selector, intensity, location);
    }
}

static void WolFoxHapticType(id receiver, SEL selector, NSInteger type) {
    IMP original = WolFoxHapticOriginal(receiver, selector);
    if (original != NULL) ((void (*)(id, SEL, NSInteger))original)(receiver, selector, type);
}

static void WolFoxHapticTypeLocation(id receiver, SEL selector, NSInteger type, CGPoint location) {
    IMP original = WolFoxHapticOriginal(receiver, selector);
    if (original != NULL) {
        ((void (*)(id, SEL, NSInteger, CGPoint))original)(receiver, selector, type, location);
    }
}

static BOOL WolFoxInstallHapticHook(NSString *className, NSString *selectorName, IMP replacement) {
    IMP original = NULL;
    if (!WolFoxInstallInstanceHook(className, selectorName, replacement, &original) || original == NULL) {
        return NO;
    }
    WolFoxHapticOriginals[[NSString stringWithFormat:@"%@|%@", className, selectorName]] =
        [NSValue valueWithPointer:(const void *)original];
    return YES;
}

void WolFoxInstallHapticHooks(void) {
    if (WolFoxHapticOriginals == nil) WolFoxHapticOriginals = [NSMutableDictionary dictionary];
    NSString *impact = @"UIImpactFeedbackGenerator";
    NSString *selection = @"UISelectionFeedbackGenerator";
    NSString *notification = @"UINotificationFeedbackGenerator";
    NSString *canvas = @"UICanvasFeedbackGenerator";
    BOOL impactPlain = WolFoxInstallHapticHook(impact, @"impactOccurred", (IMP)WolFoxHapticPlain);
    BOOL impactIntensity = WolFoxInstallHapticHook(impact, @"impactOccurredWithIntensity:",
                                                   (IMP)WolFoxHapticIntensity);
    BOOL impactLocation = WolFoxInstallHapticHook(impact, @"impactOccurredAtLocation:",
                                                  (IMP)WolFoxHapticLocation);
    BOOL impactBoth = WolFoxInstallHapticHook(impact, @"impactOccurredWithIntensity:atLocation:",
                                              (IMP)WolFoxHapticIntensityLocation);
    BOOL selectionPlain = WolFoxInstallHapticHook(selection, @"selectionChanged", (IMP)WolFoxHapticPlain);
    BOOL selectionLocation = WolFoxInstallHapticHook(selection, @"selectionChangedAtLocation:",
                                                     (IMP)WolFoxHapticLocation);
    BOOL notificationPlain = WolFoxInstallHapticHook(notification, @"notificationOccurred:",
                                                     (IMP)WolFoxHapticType);
    BOOL notificationLocation = WolFoxInstallHapticHook(notification, @"notificationOccurred:atLocation:",
                                                        (IMP)WolFoxHapticTypeLocation);
    BOOL canvasAlignment = WolFoxInstallHapticHook(canvas, @"alignmentOccurredAtLocation:",
                                                   (IMP)WolFoxHapticLocation);
    BOOL canvasPath = WolFoxInstallHapticHook(canvas, @"pathCompletedAtLocation:", (IMP)WolFoxHapticLocation);
    WolFoxDownloadLog(@"haptics", @"hooks impact=%d/%d/%d/%d selection=%d/%d notification=%d/%d canvas=%d/%d",
                      impactPlain, impactIntensity, impactLocation, impactBoth, selectionPlain, selectionLocation,
                      notificationPlain, notificationLocation, canvasAlignment, canvasPath);
}
