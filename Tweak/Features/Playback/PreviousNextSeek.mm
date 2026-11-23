#import "../../WolFox.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"
#import "../../UI/OverlayButtonHost.h"
#import "../Downloads/DownloadLog.h"

#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

// Previous and next skip back and forward instead of changing video.
static NSString *const WolFoxPreviousNextSeekKey = @"YTKACE.Preference.Overlay.PreviousNextSeek";
static const void *WolFoxSeekOriginalImageAssociation = &WolFoxSeekOriginalImageAssociation;
static const void *WolFoxSeekAppliedImageAssociation = &WolFoxSeekAppliedImageAssociation;
static NSMutableDictionary<NSString *, NSValue *> *WolFoxSeekOriginals;

NSInteger WolFoxPreviousNextSeekSeconds(void) {
    if (!WolFoxMasterEnabled()) return 0;
    const NSInteger seconds = [WolFoxPreferenceObject(WolFoxPreviousNextSeekKey) integerValue];
    return seconds == 5 || seconds == 10 || seconds == 15 || seconds == 30 ? seconds : 0;
}

static id WolFoxSeekGet(id object, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    if (object == nil || ![object respondsToSelector:selector]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(object, selector);
}

static double WolFoxSeekDouble(id object, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    if (object == nil || ![object respondsToSelector:selector]) return 0.0;
    return ((double (*)(id, SEL))objc_msgSend)(object, selector);
}

// The player behind an overlay view controller or overlay view.
static id WolFoxSeekPlayer(id receiver) {
    for (id candidate = receiver; candidate != nil;) {
        if ([NSStringFromClass([candidate class]) isEqualToString:@"YTPlayerViewController"]) return candidate;
        id parent = WolFoxSeekGet(candidate, @"parentViewController");
        if (parent == nil && [candidate isKindOfClass:UIResponder.class]) parent = [candidate nextResponder];
        candidate = parent;
    }
    return nil;
}

static void WolFoxSeekBy(id receiver, NSInteger direction) {
    id player = WolFoxSeekPlayer(receiver);
    SEL seek = NSSelectorFromString(@"seekToTime:");
    if (![player respondsToSelector:seek]) {
        WolFoxDebugLog(@"prevnext", @"no player for %@", NSStringFromClass([receiver class]));
        return;
    }
    const double total = WolFoxSeekDouble(player, @"currentVideoTotalMediaTime");
    double time = WolFoxSeekDouble(player, @"currentVideoMediaTime") +
        (double)(direction * WolFoxPreviousNextSeekSeconds());
    time = MAX(0.0, total > 1.0 ? MIN(total - 0.5, time) : time);
    ((void (*)(id, SEL, double))objc_msgSend)(player, seek, time);
    WolFoxDebugLog(@"prevnext", @"seek %+ld to %.1f", (long)(direction * WolFoxPreviousNextSeekSeconds()), time);
}

static IMP WolFoxSeekOriginal(id receiver, SEL selector) {
    for (Class cls = [receiver class]; cls != Nil; cls = class_getSuperclass(cls)) {
        NSValue *value = WolFoxSeekOriginals[[NSString stringWithFormat:@"%@|%@",
            NSStringFromClass(cls), NSStringFromSelector(selector)]];
        if (value != nil) return (IMP)value.pointerValue;
    }
    return NULL;
}

static void WolFoxSeekPressed(id receiver, SEL selector, NSInteger direction, id argument, BOOL takesArgument) {
    if (WolFoxPreviousNextSeekSeconds() > 0) {
        WolFoxSeekBy(receiver, direction);
        return;
    }
    IMP original = WolFoxSeekOriginal(receiver, selector);
    if (original == NULL) return;
    if (takesArgument) ((void (*)(id, SEL, id))original)(receiver, selector, argument);
    else ((void (*)(id, SEL))original)(receiver, selector);
}

static void WolFoxSeekPreviousArg(id receiver, SEL selector, id argument) {
    WolFoxSeekPressed(receiver, selector, -1, argument, YES);
}

static void WolFoxSeekNextArg(id receiver, SEL selector, id argument) {
    WolFoxSeekPressed(receiver, selector, 1, argument, YES);
}

static void WolFoxSeekPrevious(id receiver, SEL selector) {
    WolFoxSeekPressed(receiver, selector, -1, nil, NO);
}

static void WolFoxSeekNext(id receiver, SEL selector) {
    WolFoxSeekPressed(receiver, selector, 1, nil, NO);
}

static UIButton *WolFoxSeekButtonIn(UIView *view) {
    if ([view isKindOfClass:UIButton.class]) return (UIButton *)view;
    for (UIView *subview in view.subviews) {
        UIButton *button = WolFoxSeekButtonIn(subview);
        if (button != nil) return button;
    }
    return nil;
}

// gobackward.10 / goforward.10 while seeking, YouTube's own icons otherwise.
// YouTube can set its icon again at any time, so compare what is shown.
static void WolFoxSeekStyleButton(UIView *container, BOOL forward) {
    UIButton *button = WolFoxSeekButtonIn(container);
    if (button == nil) return;
    const NSInteger seconds = WolFoxPreviousNextSeekSeconds();
    UIImage *current = [button imageForState:UIControlStateNormal];
    UIImage *applied = objc_getAssociatedObject(button, WolFoxSeekAppliedImageAssociation);
    if (seconds == 0) {
        UIImage *saved = objc_getAssociatedObject(button, WolFoxSeekOriginalImageAssociation);
        if (applied != nil && current == applied && saved != nil) {
            [button setImage:saved forState:UIControlStateNormal];
        }
        objc_setAssociatedObject(button, WolFoxSeekOriginalImageAssociation, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(button, WolFoxSeekAppliedImageAssociation, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }
    NSString *symbol = [NSString stringWithFormat:@"%@.%ld", forward ? @"goforward" : @"gobackward", (long)seconds];
    if (applied != nil && current == applied && [applied.accessibilityIdentifier isEqualToString:symbol]) return;
    if (current != nil && current != applied) {
        objc_setAssociatedObject(button, WolFoxSeekOriginalImageAssociation, current, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    const CGFloat size = MAX(18.0, MIN(CGRectGetWidth(button.bounds), CGRectGetHeight(button.bounds)) * 0.5);
    UIImage *image = [[UIImage systemImageNamed:symbol withConfiguration:
        [UIImageSymbolConfiguration configurationWithPointSize:size weight:UIImageSymbolWeightSemibold]]
        imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    if (image == nil) return;
    image.accessibilityIdentifier = symbol;
    [button setImage:image forState:UIControlStateNormal];
    button.tintColor = UIColor.whiteColor;
    objc_setAssociatedObject(button, WolFoxSeekAppliedImageAssociation, image, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static UIView *WolFoxSeekIvar(id owner, const char *name) {
    Ivar ivar = class_getInstanceVariable(object_getClass(owner), name);
    id value = ivar != NULL ? object_getIvar(owner, ivar) : nil;
    return [value isKindOfClass:UIView.class] ? value : nil;
}

static void WolFoxSeekHook(NSString *className, NSString *selector, IMP replacement) {
    IMP original = NULL;
    if (!WolFoxInstallInstanceHook(className, selector, replacement, &original) || original == NULL) return;
    WolFoxSeekOriginals[[NSString stringWithFormat:@"%@|%@", className, selector]] =
        [NSValue valueWithPointer:(void *)original];
    WolFoxDebugLog(@"prevnext", @"hook %@ %@", className, selector);
}

void WolFoxInstallPreviousNextSeekHooks(void) {
    WolFoxSeekOriginals = [NSMutableDictionary dictionary];
    for (NSString *name in @[@"YTMainAppVideoPlayerOverlayViewController", @"YTMainAppControlsOverlayView"]) {
        WolFoxSeekHook(name, @"didPressPrevious:", (IMP)WolFoxSeekPreviousArg);
        WolFoxSeekHook(name, @"didPressNext:", (IMP)WolFoxSeekNextArg);
        WolFoxSeekHook(name, @"didPressPrevious", (IMP)WolFoxSeekPrevious);
        WolFoxSeekHook(name, @"didPressNext", (IMP)WolFoxSeekNext);
    }
    WolFoxRegisterOverlayConfigurator(@"prevnextseek", ^(UIView *overlay, __unused UIStackView *stack) {
        WolFoxSeekStyleButton(WolFoxSeekIvar(overlay, "_previousButtonView"), NO);
        WolFoxSeekStyleButton(WolFoxSeekIvar(overlay, "_nextButtonView"), YES);
    });
}
