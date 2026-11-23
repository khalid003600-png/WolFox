#import "../../WolFox.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"

#import <UIKit/UIKit.h>
#import <math.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <string.h>

static NSMutableDictionary<NSString *, NSValue *> *WolFoxDoubleTapOriginals;
static const void *WolFoxTapSeekHelperKey = &WolFoxTapSeekHelperKey;

static BOOL WolFoxCommitTapSeek(UIResponder *first, double time) {
    for (UIResponder *responder = first; responder != nil;
         responder = responder.nextResponder) {
        SEL detailed = NSSelectorFromString(@"seekToTime:seekSource:");
        SEL simple = NSSelectorFromString(@"seekToTime:");
        SEL legacy = NSSelectorFromString(
            @"didSeekToTime:toleranceBefore:toleranceAfter:");
        if ([responder respondsToSelector:detailed]) {
            ((void (*)(id, SEL, double, NSInteger))objc_msgSend)(
                responder, detailed, time, 0);
            return YES;
        }
        if ([responder respondsToSelector:simple]) {
            ((void (*)(id, SEL, double))objc_msgSend)(responder, simple, time);
            return YES;
        }
        if ([responder respondsToSelector:legacy]) {
            ((void (*)(id, SEL, double, double, double))objc_msgSend)(
                responder, legacy, time, 0.0, 0.0);
            return YES;
        }
    }
    return NO;
}

static double WolFoxMaximumSeekableTime(UIResponder *responder,
                                        NSString **providerName) {
    SEL selector = NSSelectorFromString(@"maximumSeekableTime");
    for (NSUInteger depth = 0; responder != nil && depth < 20; depth++) {
        Method method = class_getInstanceMethod(responder.class, selector);
        if (method != NULL) {
            char returnType[16] = {};
            method_getReturnType(method, returnType, sizeof(returnType));
            double value = 0.0;
            if (strcmp(returnType, @encode(double)) == 0) {
                value = ((double (*)(id, SEL))objc_msgSend)(responder,
                                                             selector);
            } else if (strcmp(returnType, @encode(float)) == 0) {
                value = ((float (*)(id, SEL))objc_msgSend)(responder,
                                                            selector);
            }
            if (isfinite(value) && value > 0.0) {
                if (providerName != NULL) {
                    *providerName = NSStringFromClass(responder.class);
                }
                return value;
            }
        }
        responder = responder.nextResponder;
    }
    return 0.0;
}

static UIView *WolFoxScrubberDot(UIView *view) {
    SEL selector = NSSelectorFromString(@"scrubberDot");
    if ([view respondsToSelector:selector]) {
        id dot = ((id (*)(id, SEL))objc_msgSend)(view, selector);
        if ([dot isKindOfClass:UIView.class]) return dot;
    }
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithArray:view.subviews];
    while (queue.count != 0) {
        UIView *candidate = queue.firstObject;
        [queue removeObjectAtIndex:0];
        NSString *token = [NSString stringWithFormat:@"%@ %@ %@",
            NSStringFromClass(candidate.class).lowercaseString,
            candidate.accessibilityIdentifier.lowercaseString ?: @"",
            candidate.accessibilityLabel.lowercaseString ?: @""];
        if ([token containsString:@"scrubber"] &&
            CGRectGetWidth(candidate.bounds) <= 64.0 &&
            CGRectGetHeight(candidate.bounds) <= 64.0) {
            return candidate;
        }
        [queue addObjectsFromArray:candidate.subviews];
    }
    return nil;
}

static BOOL WolFoxTapHitsScrubber(UIView *view, CGPoint point,
                                  CGFloat *trackY) {
    UIView *dot = WolFoxScrubberDot(view);
    CGFloat centerY = MAX(CGRectGetMinY(view.bounds),
                          CGRectGetMaxY(view.bounds) - 2.0);
    if (dot != nil && dot.superview != nil) {
        centerY = [dot.superview convertPoint:dot.center toView:view].y;
    }
    if (trackY != NULL) *trackY = centerY;
    return fabs(point.y - centerY) <= 14.0;
}

static BOOL WolFoxTapHitsOverlayControl(UIView *view, CGPoint point,
                                        NSString **controlName) {
    UIView *candidate = [view hitTest:point withEvent:nil];
    while (candidate != nil && candidate != view) {
        if ([candidate isKindOfClass:UIControl.class]) {
            NSString *token = [NSString stringWithFormat:@"%@ %@ %@",
                NSStringFromClass(candidate.class).lowercaseString,
                candidate.accessibilityIdentifier.lowercaseString ?: @"",
                candidate.accessibilityLabel.lowercaseString ?: @""];
            BOOL scrubberControl = [token containsString:@"scrub"] ||
                                   [token containsString:@"progress"] ||
                                   [token containsString:@"playerbar"];
            if (!scrubberControl) {
                if (controlName != NULL) *controlName = token;
                return YES;
            }
        }
        candidate = candidate.superview;
    }
    return NO;
}

@interface WolFoxTapSeekTarget : NSObject <UIGestureRecognizerDelegate>
@property(nonatomic, weak) UIView *view;
@end

@implementation WolFoxTapSeekTarget
- (void)tap:(UITapGestureRecognizer *)recognizer {
    UIView *view = self.view;
    if (!WolFoxFeatureEnabled(@"YTKACE.Preference.Playback.TapToSeek") || view == nil ||
        CGRectGetWidth(view.bounds) <= 1.0) return;
    CGPoint point = [recognizer locationInView:view];
    if (WolFoxTapHitsOverlayControl(view, point, NULL)) {
        return;
    }
    if (!WolFoxTapHitsScrubber(view, point, NULL)) {
        return;
    }
    double x = point.x;
    SEL rangeSelector = NSSelectorFromString(@"scrubRangeForScrubX:");
    SEL nativeSeek = NSSelectorFromString(@"fineScrubberDidSeekToTime:");
    if (![view respondsToSelector:rangeSelector]) {
        return;
    }
    double ratio = ((double (*)(id, SEL, double))objc_msgSend)(
        view, rangeSelector, x);
    if (!isfinite(ratio)) return;
    ratio = MIN(1.0, MAX(0.0, ratio));
    double duration = WolFoxMaximumSeekableTime(view, NULL);
    if (!isfinite(duration) || duration <= 0.0) {
        return;
    }
    double time = ratio * duration;
    BOOL committed = WolFoxCommitTapSeek(view, time);
    if (!committed && [view respondsToSelector:nativeSeek]) {
        ((void (*)(id, SEL, double))objc_msgSend)(view, nativeSeek, time);
    }
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
        shouldRecognizeSimultaneouslyWithGestureRecognizer:
            (UIGestureRecognizer *)otherGestureRecognizer {
    return WolFoxFeatureEnabled(@"YTKACE.Preference.Playback.TapToSeek");
}
@end

void WolFoxConfigureTapToSeek(UIView *receiver) {
    if (receiver == nil) return;
    WolFoxTapSeekTarget *target = objc_getAssociatedObject(
        receiver, WolFoxTapSeekHelperKey);
    if (target == nil) {
        target = [WolFoxTapSeekTarget new];
        target.view = receiver;
        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc]
            initWithTarget:target action:@selector(tap:)];
        tap.cancelsTouchesInView = NO;
        tap.delegate = target;
        [receiver addGestureRecognizer:tap];
        objc_setAssociatedObject(receiver, WolFoxTapSeekHelperKey, target,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static NSValue *WolFoxDoubleTapValueForIMP(IMP implementation) {
    return [NSValue value:&implementation withObjCType:@encode(IMP)];
}

static IMP WolFoxDoubleTapIMPFromValue(NSValue *value) {
    IMP implementation = NULL;
    [value getValue:&implementation];
    return implementation;
}

static double WolFoxDoubleTapValue(void) {
    double value = [NSUserDefaults.standardUserDefaults
        doubleForKey:@"YTKACE.Preference.Playback.DoubleTapSeconds"];
    return MIN(60.0, MAX(5.0, value > 0.0 ? value : 10.0));
}

static NSString *WolFoxDoubleTapKey(Class cls,
                                    BOOL classMethod,
                                    SEL selector) {
    return [NSString stringWithFormat:@"%@|%@|%@",
            NSStringFromClass(cls),
            classMethod ? @"+" : @"-",
            NSStringFromSelector(selector)];
}

static IMP WolFoxDoubleTapOriginal(id receiver, SEL selector) {
    BOOL classMethod = object_isClass(receiver);
    Class cls = classMethod ? (Class)receiver : [receiver class];
    while (cls != Nil) {
        NSValue *value =
            WolFoxDoubleTapOriginals[WolFoxDoubleTapKey(cls, classMethod, selector)];
        if (value != nil) {
            return WolFoxDoubleTapIMPFromValue(value);
        }
        cls = class_getSuperclass(cls);
    }
    return NULL;
}

static double WolFoxDoubleTapDoubleNoArg(id receiver, SEL selector) {
    if (WolFoxFeatureEnabled(@"YTKACE.Preference.Playback.CustomDoubleTap")) {
        return WolFoxDoubleTapValue();
    }
    IMP original = WolFoxDoubleTapOriginal(receiver, selector);
    return original == NULL
        ? 10.0
        : ((double (*)(id, SEL))original)(receiver, selector);
}

static float WolFoxDoubleTapFloatNoArg(id receiver, SEL selector) {
    if (WolFoxFeatureEnabled(@"YTKACE.Preference.Playback.CustomDoubleTap")) {
        return (float)WolFoxDoubleTapValue();
    }
    IMP original = WolFoxDoubleTapOriginal(receiver, selector);
    return original == NULL
        ? 10.0f
        : ((float (*)(id, SEL))original)(receiver, selector);
}

static NSInteger WolFoxDoubleTapIntegerNoArg(id receiver, SEL selector) {
    if (WolFoxFeatureEnabled(@"YTKACE.Preference.Playback.CustomDoubleTap")) {
        return (NSInteger)llround(WolFoxDoubleTapValue());
    }
    IMP original = WolFoxDoubleTapOriginal(receiver, selector);
    return original == NULL
        ? 10
        : ((NSInteger (*)(id, SEL))original)(receiver, selector);
}

static double WolFoxDoubleTapDouble(id receiver,
                                    SEL selector,
                                    id __unsafe_unretained config) {
    if (WolFoxFeatureEnabled(@"YTKACE.Preference.Playback.CustomDoubleTap")) {
        return WolFoxDoubleTapValue();
    }
    IMP original = WolFoxDoubleTapOriginal(receiver, selector);
    return original == NULL
        ? 10.0
        : ((double (*)(id, SEL, id))original)(receiver, selector, config);
}

static float WolFoxDoubleTapFloat(id receiver,
                                  SEL selector,
                                  id __unsafe_unretained config) {
    if (WolFoxFeatureEnabled(@"YTKACE.Preference.Playback.CustomDoubleTap")) {
        return (float)WolFoxDoubleTapValue();
    }
    IMP original = WolFoxDoubleTapOriginal(receiver, selector);
    return original == NULL
        ? 10.0f
        : ((float (*)(id, SEL, id))original)(receiver, selector, config);
}

static NSInteger WolFoxDoubleTapInteger(id receiver,
                                        SEL selector,
                                        id __unsafe_unretained config) {
    if (WolFoxFeatureEnabled(@"YTKACE.Preference.Playback.CustomDoubleTap")) {
        return (NSInteger)llround(WolFoxDoubleTapValue());
    }
    IMP original = WolFoxDoubleTapOriginal(receiver, selector);
    return original == NULL
        ? 10
        : ((NSInteger (*)(id, SEL, id))original)(receiver, selector, config);
}

static BOOL WolFoxTapToSeekDisabled(id receiver, SEL selector) {
    if (WolFoxFeatureEnabled(@"YTKACE.Preference.Playback.TapToSeek")) {
        return NO;
    }
    IMP original = WolFoxDoubleTapOriginal(receiver, selector);
    return original == NULL
        ? NO
        : ((BOOL (*)(id, SEL))original)(receiver, selector);
}

static BOOL WolFoxTapToSeekEnabled(id receiver, SEL selector) {
    if (WolFoxFeatureEnabled(@"YTKACE.Preference.Playback.TapToSeek")) {
        return YES;
    }
    IMP original = WolFoxDoubleTapOriginal(receiver, selector);
    return original != NULL &&
        ((BOOL (*)(id, SEL))original)(receiver, selector);
}

static BOOL WolFoxInstallTapToSeekHook(NSString *className,
                                       NSString *selectorName,
                                       IMP replacement,
                                       BOOL classMethod) {
    SEL selector = NSSelectorFromString(selectorName);
    Class cls = NSClassFromString(className);
    Class target = classMethod ? object_getClass(cls) : cls;
    Method method = class_getInstanceMethod(target, selector);
    if (method == NULL) return NO;
    IMP original = NULL;
    BOOL installed = classMethod
        ? WolFoxInstallClassHook(className, selectorName,
                                 replacement, &original)
        : WolFoxInstallInstanceHook(className, selectorName,
                                    replacement, &original);
    if (installed && original != NULL) {
        NSString *key = WolFoxDoubleTapKey(cls, classMethod, selector);
        if (WolFoxDoubleTapOriginals[key] == nil) {
            WolFoxDoubleTapOriginals[key] =
                WolFoxDoubleTapValueForIMP(original);
        }
    }
    return installed;
}

static void WolFoxInstallDoubleTapHook(NSString *className,
                                      NSString *selectorName,
                                      BOOL classMethod) {
    Class cls = NSClassFromString(className);
    Class target = classMethod ? object_getClass(cls) : cls;
    Method method = class_getInstanceMethod(
        target,
        NSSelectorFromString(selectorName)
    );
    if (method == NULL) {
        return;
    }

    char returnType[16] = {};
    method_getReturnType(method, returnType, sizeof(returnType));
    BOOL takesArgument = [selectorName containsString:@":"];
    IMP replacement = NULL;
    if (strcmp(returnType, @encode(double)) == 0) {
        replacement = takesArgument
            ? (IMP)WolFoxDoubleTapDouble
            : (IMP)WolFoxDoubleTapDoubleNoArg;
    } else if (strcmp(returnType, @encode(float)) == 0) {
        replacement = takesArgument
            ? (IMP)WolFoxDoubleTapFloat
            : (IMP)WolFoxDoubleTapFloatNoArg;
    } else if (strcmp(returnType, @encode(NSInteger)) == 0 ||
               strcmp(returnType, @encode(NSUInteger)) == 0 ||
               strcmp(returnType, @encode(int)) == 0) {
        replacement = takesArgument
            ? (IMP)WolFoxDoubleTapInteger
            : (IMP)WolFoxDoubleTapIntegerNoArg;
    }
    if (replacement == NULL) {
        return;
    }

    IMP original = NULL;
    BOOL installed = classMethod
        ? WolFoxInstallClassHook(className, selectorName, replacement, &original)
        : WolFoxInstallInstanceHook(className, selectorName, replacement, &original);
    if (installed && original != NULL) {
        NSString *key =
            WolFoxDoubleTapKey(cls, classMethod, NSSelectorFromString(selectorName));
        if (WolFoxDoubleTapOriginals[key] == nil) {
            WolFoxDoubleTapOriginals[key] =
                WolFoxDoubleTapValueForIMP(original);
        }
    }
}

void WolFoxInstallDoubleTapHooks(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        WolFoxDoubleTapOriginals = [NSMutableDictionary dictionary];
    });

    WolFoxInstallDoubleTapHook(@"YTSettings", @"doubleTapSeekDuration", NO);
    WolFoxInstallDoubleTapHook(@"YTUserDefaults", @"doubleTapSeekDuration", NO);
    for (NSString *selector in @[
        @"doubleTapSeekDurationForVideoPlayerOverlayConfig:",
        @"doubleTapSeekIntervalForVideoPlayerOverlayConfig:"
    ]) {
        WolFoxInstallDoubleTapHook(
            @"YTVideoPlayerOverlayConfigTransformer",
            selector,
            NO
        );
        WolFoxInstallDoubleTapHook(
            @"YTVideoPlayerOverlayConfigTransformer",
            selector,
            YES
        );
    }
    for (NSString *className in @[
        @"YTHotConfig",
        @"YTColdConfig",
        @"YTGlobalConfig",
        @"YTSettings"
    ]) {
        for (NSNumber *classMethodValue in @[@NO, @YES]) {
            BOOL classMethod = classMethodValue.boolValue;
            WolFoxInstallTapToSeekHook(
                className, @"androidDisableTimeBarTapToSeek",
                (IMP)WolFoxTapToSeekDisabled, classMethod);
            WolFoxInstallTapToSeekHook(
                className, @"iosEnableVideoPlayerScrubber",
                (IMP)WolFoxTapToSeekEnabled, classMethod);
        }
    }
}
