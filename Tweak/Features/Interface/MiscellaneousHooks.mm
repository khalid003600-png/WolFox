#import "../../WolFox.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"
#import "../Downloads/DownloadLog.h"

#import <UIKit/UIKit.h>
#import <mach-o/dyld.h>
#import <mach-o/getsect.h>
#import <mach-o/loader.h>
#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <stdlib.h>

static IMP OriginalAddInteraction;
static IMP OriginalSemanticContent;
static IMP OriginalSetSemanticContent;
static IMP OriginalCaptionControllerAlloc;
static NSMutableDictionary<NSString *, NSValue *> *WolFoxMiscOriginals;
static const void *WolFoxCaptionTracksAssociation =
    &WolFoxCaptionTracksAssociation;
static const void *WolFoxLastCaptionTrackAssociation =
    &WolFoxLastCaptionTrackAssociation;
static const void *WolFoxAppliedCaptionAssociation =
    &WolFoxAppliedCaptionAssociation;
static NSHashTable *WolFoxCaptionControllers;

static NSString *WolFoxCaptionTrackKey(id track) {
    if (track == nil) {
        return nil;
    }
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (NSString *key in @[@"languageCode", @"displayName", @"vssId",
                             @"kind"]) {
        @try {
            id value = [track valueForKey:key];
            if (value != nil) {
                [parts addObject:[value description]];
            }
        } @catch (__unused NSException *exception) {
        }
    }
    return parts.count != 0 ? [parts componentsJoinedByString:@"|"] :
        [NSString stringWithFormat:@"%p", (__bridge void *)track];
}

static BOOL WolFoxCaptionRequestReceiver(id receiver, SEL selector) {
    NSString *className = NSStringFromClass([receiver class]).lowercaseString;
    NSString *name = NSStringFromSelector(selector).lowercaseString;
    return [className containsString:@"request"] ||
        [className containsString:@"params"] ||
        [className containsString:@"config"] ||
        [name containsString:@"requested"] ||
        [name containsString:@"devicecaptions"] ||
        [name containsString:@"persistence"] ||
        [name containsString:@"respectdevice"] ||
        [name containsString:@"hiddenonstart"];
}

static NSString *WolFoxMiscKey(Class cls, SEL selector) {
    return [NSString stringWithFormat:@"%@|%@", NSStringFromClass(cls),
                                      NSStringFromSelector(selector)];
}

static IMP WolFoxMiscOriginal(id receiver, SEL selector) {
    for (Class cls = object_getClass(receiver); cls != Nil; cls = class_getSuperclass(cls)) {
        IMP original = (IMP)[WolFoxMiscOriginals[
            WolFoxMiscKey(cls, selector)] pointerValue];
        if (original != NULL) {
            return original;
        }
    }
    return NULL;
}

static BOOL WolFoxMiniPlayerEnabled(void) {
    return WolFoxFeatureEnabled(@"YTKACE.Preference.Playback.KidsMiniPlayer");
}

static NSString *const WolFoxLayoutIdiomKey = @"YTKACE.Preference.App.LayoutIdiom";

static BOOL WolFoxIdiomForced;
static UIUserInterfaceIdiom WolFoxForcedIdiom;
static UIUserInterfaceIdiom WolFoxRealIdiom;
static IMP OriginalDeviceIdiom;

typedef struct {
    uintptr_t start;
    uintptr_t end;
} WolFoxTextRange;

static WolFoxTextRange WolFoxIdiomRanges[2];
static NSUInteger WolFoxIdiomRangeCount;

static void WolFoxAddTextRange(const struct mach_header *header) {
    if (header == NULL || WolFoxIdiomRangeCount >= 2) return;
    unsigned long size = 0;
    const uint8_t *text = getsectiondata(
        (const struct mach_header_64 *)header, "__TEXT", "__text", &size);
    if (text == NULL || size == 0) return;
    WolFoxIdiomRanges[WolFoxIdiomRangeCount].start = (uintptr_t)text;
    WolFoxIdiomRanges[WolFoxIdiomRangeCount].end = (uintptr_t)text + size;
    WolFoxIdiomRangeCount++;
}

static void WolFoxComputeIdiomRanges(void) {
    for (uint32_t index = 0; index < _dyld_image_count(); index++) {
        const struct mach_header *header = _dyld_get_image_header(index);
        if (header == NULL) continue;
        if (header->filetype != MH_EXECUTE) continue;
        WolFoxAddTextRange(header);
        break;
    }
    Dl_info info;
    if (dladdr((const void *)&WolFoxComputeIdiomRanges, &info) != 0) {
        WolFoxAddTextRange((const struct mach_header *)info.dli_fbase);
    }
}

static inline BOOL WolFoxCallerIsApp(uintptr_t caller) {
    for (NSUInteger index = 0; index < WolFoxIdiomRangeCount; index++) {
        if (caller >= WolFoxIdiomRanges[index].start &&
            caller < WolFoxIdiomRanges[index].end) {
            return YES;
        }
    }
    return NO;
}

NSInteger WolFoxRealUserInterfaceIdiom(void) {
    if (WolFoxIdiomForced) {
        return (NSInteger)WolFoxRealIdiom;
    }
    return (NSInteger)UIDevice.currentDevice.userInterfaceIdiom;
}

static UIUserInterfaceIdiom WolFoxUserInterfaceIdiom(id receiver, SEL selector) {
    if (WolFoxIdiomForced &&
        WolFoxCallerIsApp((uintptr_t)__builtin_return_address(0))) {
        return WolFoxForcedIdiom;
    }
    return OriginalDeviceIdiom != NULL
        ? ((UIUserInterfaceIdiom (*)(id, SEL))OriginalDeviceIdiom)(receiver,
                                                                   selector)
        : WolFoxRealIdiom;
}

static void WolFoxResolveForcedIdiom(void) {
    UIUserInterfaceIdiom actual = UIDevice.currentDevice.userInterfaceIdiom;
    id stored = WolFoxPreferenceObject(WolFoxLayoutIdiomKey);
    NSInteger choice = [stored respondsToSelector:@selector(integerValue)]
        ? [stored integerValue] : 0;
    if (choice == 0 &&
        WolFoxFeatureEnabled(@"YTKACE.Preference.App.iPadLayout")) {
        choice = 2;
    }
    UIUserInterfaceIdiom desired;
    if (choice == 1) {
        desired = UIUserInterfaceIdiomPhone;
    } else if (choice == 2) {
        desired = UIUserInterfaceIdiomPad;
    } else {
        return;
    }
    if (desired == actual) return;
    WolFoxRealIdiom = actual;
    WolFoxForcedIdiom = desired;
    WolFoxIdiomForced = YES;
}

static BOOL WolFoxForcedIsIPad(__unused id receiver, __unused SEL selector) {
    return WolFoxForcedIdiom == UIUserInterfaceIdiomPad;
}

static void WolFoxAddInteraction(UIView *receiver, SEL selector, id interaction) {
    if (WolFoxFeatureEnabled(@"YTKACE.Preference.App.DragDropDisabled") &&
        ([interaction isKindOfClass:UIDragInteraction.class] ||
         [interaction isKindOfClass:UIDropInteraction.class])) {
        return;
    }
    if (OriginalAddInteraction != NULL) {
        ((void (*)(id, SEL, id))OriginalAddInteraction)(receiver, selector, interaction);
    }
}

static UISemanticContentAttribute WolFoxSemanticContent(id receiver, SEL selector) {
    if (WolFoxFeatureEnabled(@"YTKACE.Preference.App.RTLDisabled")) {
        return UISemanticContentAttributeForceLeftToRight;
    }
    return OriginalSemanticContent != NULL
        ? ((UISemanticContentAttribute (*)(id, SEL))OriginalSemanticContent)(receiver, selector)
        : UISemanticContentAttributeUnspecified;
}

static void WolFoxSetSemanticContent(id receiver,
                                     SEL selector,
                                     UISemanticContentAttribute value) {
    if (OriginalSetSemanticContent != NULL) {
        ((void (*)(id, SEL, UISemanticContentAttribute))OriginalSetSemanticContent)(
            receiver,
            selector,
            WolFoxFeatureEnabled(@"YTKACE.Preference.App.RTLDisabled")
                ? UISemanticContentAttributeForceLeftToRight
                : value
        );
    }
}

static BOOL WolFoxMiniPlayerValue(id receiver, SEL selector) {
    if (WolFoxMiniPlayerEnabled()) {
        NSString *name = NSStringFromSelector(selector).lowercaseString;
        return !([name containsString:@"disable"] ||
                 [name containsString:@"unavailable"] ||
                 [name containsString:@"blocked"] ||
                 [name containsString:@"prevent"] ||
                 [name containsString:@"hide"] ||
                 [name containsString:@"onlywhenplaying"]);
    }
    IMP original = WolFoxMiscOriginal(receiver, selector);
    return original != NULL ? ((BOOL (*)(id, SEL))original)(receiver, selector) : NO;
}

static BOOL WolFoxMiniPlayerPauseOnlyValue(id receiver, SEL selector) {
    if (WolFoxMiniPlayerEnabled()) {
        return NO;
    }
    IMP original = WolFoxMiscOriginal(receiver, selector);
    return original != NULL ? ((BOOL (*)(id, SEL))original)(receiver, selector) : NO;
}

static BOOL WolFoxAgeValue(id receiver, SEL selector) {
    if (WolFoxFeatureEnabled(@"YTKACE.Preference.Content.AgeGateBypass")) {
        NSString *name = NSStringFromSelector(selector).lowercaseString;
        return [name containsString:@"verified"] ||
            [name containsString:@"allowed"];
    }
    IMP original = WolFoxMiscOriginal(receiver, selector);
    return original != NULL ? ((BOOL (*)(id, SEL))original)(receiver, selector) : NO;
}

NSInteger WolFoxCaptionsMode(void) {
    if (!WolFoxMasterEnabled()) return 0;
    id stored = [NSUserDefaults.standardUserDefaults objectForKey:@"YTKACE.Preference.Playback.CaptionsMode"];
    if ([stored respondsToSelector:@selector(integerValue)]) return MAX(0, MIN(2, [stored integerValue]));
    if (WolFoxFeatureEnabled(@"YTKACE.Preference.Playback.CaptionsDisabled")) return 2;
    if (WolFoxFeatureEnabled(@"YTKACE.Preference.Playback.CaptionsAlwaysOn")) return 1;
    return 0;
}

static BOOL WolFoxCaptionValue(id receiver, SEL selector) {
    NSString *name = NSStringFromSelector(selector).lowercaseString;
    BOOL negative = [name containsString:@"disabled"] ||
        [name containsString:@"hidden"];
    if ((WolFoxCaptionsMode() == 2) && WolFoxCaptionRequestReceiver(receiver, selector)) {
        return negative;
    }
    if ((WolFoxCaptionsMode() == 1)) {
        if (!WolFoxCaptionRequestReceiver(receiver, selector)) {
            IMP original = WolFoxMiscOriginal(receiver, selector);
            return original != NULL
                ? ((BOOL (*)(id, SEL))original)(receiver, selector) : NO;
        }
        if ([name containsString:@"respectdevicecaption"] ||
            [name containsString:@"hiddenonstart"]) {
            return NO;
        }
        return !negative;
    }
    IMP original = WolFoxMiscOriginal(receiver, selector);
    return original != NULL ? ((BOOL (*)(id, SEL))original)(receiver, selector) : NO;
}

static void WolFoxCaptionSetter(id receiver, SEL selector, BOOL enabled) {
    IMP original = WolFoxMiscOriginal(receiver, selector);
    if (original == NULL) {
        return;
    }
    NSString *name = NSStringFromSelector(selector).lowercaseString;
    BOOL negative = [name containsString:@"disabled"] ||
        [name containsString:@"hidden"];
    BOOL value = enabled;
    if ((WolFoxCaptionsMode() == 2) && WolFoxCaptionRequestReceiver(receiver, selector)) {
        value = negative;
    } else if ((WolFoxCaptionsMode() == 1) &&
               WolFoxCaptionRequestReceiver(receiver, selector)) {
        value = !negative;
    }
    ((void (*)(id, SEL, BOOL))original)(receiver, selector, value);
}

static id WolFoxFirstCaptionTrack(id tracks) {
    if ([tracks isKindOfClass:NSArray.class]) {
        return [tracks firstObject];
    }
    if ([tracks respondsToSelector:@selector(allObjects)]) {
        id objects = ((id (*)(id, SEL))objc_msgSend)(tracks,
                                                     @selector(allObjects));
        return [objects isKindOfClass:NSArray.class] ? [objects firstObject] : nil;
    }
    return nil;
}

static NSString *WolFoxTrackText(id track, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    if (![track respondsToSelector:selector]) return nil;
    id value = ((id (*)(id, SEL))objc_msgSend)(track, selector);
    return [value isKindOfClass:NSString.class] ? value : nil;
}

static id WolFoxBestCaptionTrackForLanguage(NSArray *tracks, NSString *language) {
    if (language.length == 0) return nil;
    NSString *base = [[language.lowercaseString componentsSeparatedByCharactersInSet:
        [NSCharacterSet characterSetWithCharactersInString:@"-_"]] firstObject];
    id best = nil;
    NSInteger bestRank = NSIntegerMax;
    for (id track in tracks) {
        NSString *code = WolFoxTrackText(track, @"languageCode").lowercaseString;
        if (code.length == 0) continue;
        NSString *codeBase = [[code componentsSeparatedByCharactersInSet:
            [NSCharacterSet characterSetWithCharactersInString:@"-_"]] firstObject];
        if (![code isEqualToString:language.lowercaseString] && ![codeBase isEqualToString:base]) continue;
        NSString *vss = WolFoxTrackText(track, @"VSSID") ?: @"";
        NSInteger rank = [vss hasPrefix:@"."] ? 0 : ([vss hasPrefix:@"a."] ? 1 : 2);
        if (rank < bestRank) {
            bestRank = rank;
            best = track;
        }
    }
    return best;
}

static id WolFoxPreferredCaptionTrack(id tracks) {
    id first = WolFoxFirstCaptionTrack(tracks);
    if (first == nil) return nil;
    NSArray *list = [tracks isKindOfClass:NSArray.class] ? tracks
        : ([tracks respondsToSelector:@selector(allObjects)]
            ? ((id (*)(id, SEL))objc_msgSend)(tracks, @selector(allObjects)) : nil);
    if (![list isKindOfClass:NSArray.class]) return first;
    NSString *preferred = [NSUserDefaults.standardUserDefaults
        stringForKey:@"YTKACE.Preference.Playback.CaptionLanguage"];
    id match = WolFoxBestCaptionTrackForLanguage(list, preferred);
    for (NSString *language in NSLocale.preferredLanguages) {
        if (match != nil) break;
        match = WolFoxBestCaptionTrackForLanguage(list, language);
    }
    if (match != nil) return match;
    for (id track in list) {
        if (![[WolFoxTrackText(track, @"VSSID") ?: @"" lowercaseString] hasPrefix:@"t"]) return track;
    }
    return first;
}

static void WolFoxScheduleCaptionSelection(id track) {
    if (track == nil || !(WolFoxCaptionsMode() == 1)) {
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                  (int64_t)(0.45 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        NSString *key = WolFoxCaptionTrackKey(track);
        NSArray *controllers = nil;
        @synchronized (WolFoxCaptionControllers) {
            controllers = WolFoxCaptionControllers.allObjects;
        }
        for (id controller in controllers) {
            NSString *applied = objc_getAssociatedObject(
                controller, WolFoxAppliedCaptionAssociation);
            if ([applied isEqualToString:key]) {
                continue;
            }
            SEL selector = NSSelectorFromString(
                @"setSelectedCaptionTrack:selectionReason:");
            if (![controller respondsToSelector:selector]) {
                continue;
            }
            objc_setAssociatedObject(controller,
                WolFoxAppliedCaptionAssociation, key,
                OBJC_ASSOCIATION_COPY_NONATOMIC);
            ((void (*)(id, SEL, id, NSInteger))objc_msgSend)(
                controller, selector, track, 1);
        }
    });
}

static id WolFoxCaptionControllerAlloc(id receiver, SEL selector, NSZone *zone) {
    id result = OriginalCaptionControllerAlloc != NULL
        ? ((id (*)(id, SEL, NSZone *))OriginalCaptionControllerAlloc)(
            receiver, selector, zone) : nil;
    if (result != nil) {
        @synchronized (WolFoxCaptionControllers) {
            [WolFoxCaptionControllers addObject:result];
        }
    }
    return result;
}

static id WolFoxCaptionControllerInit(id receiver, SEL selector) {
    IMP original = WolFoxMiscOriginal(receiver, selector);
    id result = original != NULL
        ? ((id (*)(id, SEL))original)(receiver, selector) : receiver;
    if (result != nil) {
        @synchronized (WolFoxCaptionControllers) {
            [WolFoxCaptionControllers addObject:result];
        }
    }
    return result;
}

static void WolFoxCaptionTracksSetter(id receiver, SEL selector, id tracks) {
    IMP original = WolFoxMiscOriginal(receiver, selector);
    if (original != NULL) {
        ((void (*)(id, SEL, id))original)(receiver, selector, tracks);
    }
    id track = WolFoxPreferredCaptionTrack(tracks);
    id previousTrack = objc_getAssociatedObject(
        receiver, WolFoxLastCaptionTrackAssociation);
    if (previousTrack != track) {
        objc_setAssociatedObject(receiver, WolFoxLastCaptionTrackAssociation,
                                 track, OBJC_ASSOCIATION_ASSIGN);
        WolFoxScheduleCaptionSelection(track);
    }
    if (track == nil) {
        return;
    }
    objc_setAssociatedObject(receiver,
                             WolFoxCaptionTracksAssociation,
                             tracks,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void WolFoxCaptionTrackSetter(id receiver, SEL selector, id track) {
    IMP original = WolFoxMiscOriginal(receiver, selector);
    if (original != NULL) {
        ((void (*)(id, SEL, id))original)(receiver, selector, track);
    }
}

static void WolFoxCaptionSelectedTrackSetter(id receiver,
                                             SEL selector,
                                             id track,
                                             NSInteger reason) {
    IMP original = WolFoxMiscOriginal(receiver, selector);
    if (original != NULL) {
        ((void (*)(id, SEL, id, NSInteger))original)(receiver,
                                                      selector,
                                                      track,
                                                      reason);
    }
}

static void WolFoxHUDMessage(id receiver, SEL selector, id message) {
    if (WolFoxFeatureEnabled(@"YTKACE.Preference.App.HUDAlertsHidden")) {
        return;
    }
    NSString *text = nil;
    if ([message isKindOfClass:NSString.class]) {
        text = message;
    } else if ([message isKindOfClass:NSAttributedString.class]) {
        text = [(NSAttributedString *)message string];
    } else {
        for (NSString *name in @[@"text", @"message", @"title"]) {
            SEL valueSelector = NSSelectorFromString(name);
            if (![message respondsToSelector:valueSelector]) {
                continue;
            }
            id value = ((id (*)(id, SEL))objc_msgSend)(message,
                                                       valueSelector);
            if ([value isKindOfClass:NSString.class]) {
                text = value;
                break;
            }
            if ([value isKindOfClass:NSAttributedString.class]) {
                text = [(NSAttributedString *)value string];
                break;
            }
        }
    }
    NSString *lower = text.lowercaseString;
    if (WolFoxMiniPlayerEnabled() &&
        [lower containsString:@"miniplayer"] &&
        [lower containsString:@"kids"]) {
        return;
    }
    IMP original = WolFoxMiscOriginal(receiver, selector);
    if (original != NULL) {
        ((void (*)(id, SEL, id))original)(receiver, selector, message);
    }
}

static void WolFoxStoreMiscOriginal(NSString *className,
                                    NSString *selectorName,
                                    IMP original) {
    Class cls = NSClassFromString(className);
    if (cls != Nil && original != NULL) {
        WolFoxMiscOriginals[WolFoxMiscKey(
            cls,
            NSSelectorFromString(selectorName)
        )] = [NSValue valueWithPointer:(const void *)original];
    }
}

static void WolFoxInstallMiscBool(NSString *className,
                                  NSString *selectorName,
                                  IMP replacement) {
    Class cls = NSClassFromString(className);
    Method method = cls == Nil ? NULL : class_getInstanceMethod(
        cls,
        NSSelectorFromString(selectorName)
    );
    if (method == NULL || method_getNumberOfArguments(method) != 2) {
        return;
    }
    char type[8] = {0};
    method_getReturnType(method, type, sizeof(type));
    if (type[0] != 'B' && type[0] != 'c') {
        return;
    }
    IMP original = NULL;
    if (WolFoxInstallInstanceHook(className, selectorName, replacement, &original)) {
        WolFoxStoreMiscOriginal(className, selectorName, original);
    }
}

static void WolFoxInstallMiscSetter(NSString *className,
                                    NSString *selectorName,
                                    IMP replacement) {
    Class cls = NSClassFromString(className);
    Method method = cls == Nil ? NULL : class_getInstanceMethod(
        cls,
        NSSelectorFromString(selectorName)
    );
    if (method == NULL || method_getNumberOfArguments(method) != 3) {
        return;
    }
    IMP original = NULL;
    if (WolFoxInstallInstanceHook(className, selectorName, replacement, &original)) {
        WolFoxStoreMiscOriginal(className, selectorName, original);
    }
}

static void WolFoxInstallMiscObjectSetter(NSString *className,
                                          NSString *selectorName,
                                          IMP replacement) {
    Class cls = NSClassFromString(className);
    SEL selector = NSSelectorFromString(selectorName);
    Method method = cls == Nil ? NULL : class_getInstanceMethod(cls, selector);
    if (method == NULL || method_getNumberOfArguments(method) != 3) {
        return;
    }
    char type[8] = {0};
    method_getArgumentType(method, 2, type, sizeof(type));
    if (type[0] != '@') {
        return;
    }
    IMP original = NULL;
    if (WolFoxInstallInstanceHook(className, selectorName,
                                  replacement, &original)) {
        WolFoxStoreMiscOriginal(className, selectorName, original);
    }
}

static void WolFoxInstallCaptionSelectedSetter(NSString *className) {
    NSString *selectorName = @"setSelectedCaptionTrack:selectionReason:";
    Class cls = NSClassFromString(className);
    SEL selector = NSSelectorFromString(selectorName);
    Method method = cls == Nil ? NULL : class_getInstanceMethod(cls, selector);
    if (method == NULL || method_getNumberOfArguments(method) != 4) {
        return;
    }
    char type[8] = {0};
    method_getArgumentType(method, 2, type, sizeof(type));
    if (type[0] != '@') {
        return;
    }
    IMP original = NULL;
    if (WolFoxInstallInstanceHook(className, selectorName,
                                  (IMP)WolFoxCaptionSelectedTrackSetter,
                                  &original)) {
        WolFoxStoreMiscOriginal(className, selectorName, original);
    }
}

static BOOL WolFoxClassNameMatches(NSString *className,
                                   NSArray<NSString *> *tokens) {
    NSString *lower = className.lowercaseString;
    for (NSString *token in tokens) {
        if ([lower containsString:token]) {
            return YES;
        }
    }
    return NO;
}

static NSString *WolFoxMiscDiscoveryCacheKey(void) {
    NSString *version = NSBundle.mainBundle
        .infoDictionary[@"CFBundleShortVersionString"] ?: @"unknown";
    return [@"WolFoxMiscHookTargets." stringByAppendingString:version];
}

static void WolFoxApplyMiscDiscoveryTarget(NSString *target) {
    NSArray<NSString *> *parts = [target componentsSeparatedByString:@"|"];
    if (parts.count != 3) return;
    NSString *kind = parts[0];
    NSString *className = parts[1];
    NSString *selectorName = parts[2];
    if ([kind isEqualToString:@"mini"]) {
        WolFoxInstallMiscBool(className, selectorName,
                              (IMP)WolFoxMiniPlayerValue);
    } else if ([kind isEqualToString:@"miniPause"]) {
        WolFoxInstallMiscBool(className, selectorName,
                              (IMP)WolFoxMiniPlayerPauseOnlyValue);
    } else if ([kind isEqualToString:@"captionBool"]) {
        WolFoxInstallMiscBool(className, selectorName,
                              (IMP)WolFoxCaptionValue);
    } else if ([kind isEqualToString:@"captionSetter"]) {
        WolFoxInstallMiscSetter(className, selectorName,
                                (IMP)WolFoxCaptionSetter);
    } else if ([kind isEqualToString:@"captionTracks"]) {
        WolFoxInstallMiscObjectSetter(className, selectorName,
                                      (IMP)WolFoxCaptionTracksSetter);
    } else if ([kind isEqualToString:@"captionTrack"]) {
        WolFoxInstallMiscObjectSetter(className, selectorName,
                                      (IMP)WolFoxCaptionTrackSetter);
    } else if ([kind isEqualToString:@"captionSelected"]) {
        WolFoxInstallCaptionSelectedSetter(className);
    }
}

static void WolFoxApplyCachedMiscDiscovery(void) {
    NSArray<NSString *> *targets = [NSUserDefaults.standardUserDefaults
        arrayForKey:WolFoxMiscDiscoveryCacheKey()];
    for (NSString *target in targets) {
        WolFoxApplyMiscDiscoveryTarget(target);
    }
}

static void WolFoxDiscoverMiscHooks(void) {
    NSSet<NSString *> *miniSelectors = [NSSet setWithArray:@[
        @"isPlayableInMiniPlayer", @"isPlayableInMiniplayer",
        @"miniplayerEnabled", @"isMiniplayerDisabled",
        @"miniPlayerDisabled", @"isMiniplayerUnavailable",
        @"enableIosFloatingMiniplayer", @"enableMiniPlayerOnlyWhenPlaying",
        @"disableMiniPlayerWhenPaused", @"disableIphoneMiniplayerTransitionFix",
        @"enableIosFloatingMiniplayerTransitionBugFix",
        @"enableMiniplayerErrorFix", @"enableMiniplayerChangesPostCairo",
        @"shouldOpenMiniplayerOnStateChange", @"shouldShowMiniPlayer",
        @"hasShouldShowMiniPlayer", @"hasDisplayMiniPlayer",
        @"hasMiniplayer", @"isMiniplayer", @"allowDockingForMiniplayer",
        @"blockedForKidsContent", @"hasBlockedForKidsContent"
    ]];
    NSSet<NSString *> *captionGetters = [NSSet setWithArray:@[
        @"captionsEnabled", @"areCaptionsEnabled", @"captionEnabled",
        @"isCaptionEnabled", @"closedCaptionsEnabled",
        @"closedCaptioningEnabled", @"captionsEnabledWhenAvailable",
        @"shouldShowCaptions", @"captionsActive", @"captionVisible",
        @"captionsVisible", @"captionsRequested", @"deviceCaptionsOn",
        @"captionsDisabled", @"captionsHidden",
        @"captionVisibilityPersistenceEnabled",
        @"captionLanguagePersistenceEnabled", @"respectDeviceCaptionSetting",
        @"inlinePlaybackCaptionHiddenOnStartEnabled"
    ]];
    NSSet<NSString *> *captionSetters = [NSSet setWithArray:@[
        @"setCaptionsEnabled:", @"setClosedCaptionsEnabled:",
        @"setCaptionEnabled:", @"setIsCaptionEnabled:",
        @"setCaptionsActive:", @"setCaptionVisible:",
        @"setCaptionsVisible:", @"setCaptionsRequested:",
        @"setDeviceCaptionsOn:", @"setCaptionsDisabled:",
        @"setCaptionsHidden:", @"setPersistentUserCaptionVisibility:",
        @"setUserPreferredCaptionVisibilityAsHidden:"
    ]];
    NSSet<NSString *> *trackLists = [NSSet setWithArray:@[
        @"setAvailableCaptionTracks:", @"setCaptionTrackArray:",
        @"setUserVisibleCaptionTracks:", @"setTracklistCaptionTracks:"
    ]];
    NSSet<NSString *> *trackSetters = [NSSet setWithArray:@[
        @"setActiveCaptionTrack:", @"setCaptionTrack:"
    ]];
    NSArray<NSString *> *miniTokens = @[
        @"mini", @"playability", @"playerresponse",
        @"watch", @"playerhotconfig", @"globalconfig"
    ];
    NSArray<NSString *> *captionTokens = @[
        @"caption", @"player", @"playback", @"watch", @"globalconfig"
    ];
    NSMutableOrderedSet<NSString *> *targets = [NSMutableOrderedSet orderedSet];
    for (NSString *className in WolFoxAppClassNames()) {
        BOOL mini = WolFoxClassNameMatches(className, miniTokens);
        BOOL caption = WolFoxClassNameMatches(className, captionTokens);
        if (!mini && !caption) continue;
        Class cls = NSClassFromString(className);
        if (cls == Nil) continue;
        unsigned int methodCount = 0;
        Method *methods = class_copyMethodList(cls, &methodCount);
        for (unsigned int methodIndex = 0;
             methodIndex < methodCount;
             methodIndex++) {
            NSString *selectorName = NSStringFromSelector(
                method_getName(methods[methodIndex])
            );
            NSString *kind = nil;
            if (mini && [selectorName isEqualToString:
                         @"isMiniplayerRendererPlaybackModePauseOnly"]) {
                kind = @"miniPause";
            } else if (mini && [miniSelectors containsObject:selectorName]) {
                kind = @"mini";
            } else if (caption &&
                       [captionGetters containsObject:selectorName]) {
                kind = @"captionBool";
            } else if (caption &&
                       [captionSetters containsObject:selectorName]) {
                kind = @"captionSetter";
            } else if (caption &&
                       [trackLists containsObject:selectorName]) {
                kind = @"captionTracks";
            } else if (caption &&
                       [trackSetters containsObject:selectorName]) {
                kind = @"captionTrack";
            } else if (caption && [selectorName isEqualToString:
                       @"setSelectedCaptionTrack:selectionReason:"]) {
                kind = @"captionSelected";
            }
            if (kind != nil) {
                [targets addObject:[NSString stringWithFormat:@"%@|%@|%@",
                    kind, className, selectorName]];
            }
        }
        free(methods);
    }

    NSArray<NSString *> *result = targets.array;
    [NSUserDefaults.standardUserDefaults setObject:result
                                    forKey:WolFoxMiscDiscoveryCacheKey()];
    dispatch_async(dispatch_get_main_queue(), ^{
        for (NSString *target in result) {
            WolFoxApplyMiscDiscoveryTarget(target);
        }
    });
}

void WolFoxInstallMiscellaneousHooks(void) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if ([defaults objectForKey:@"YTKACE.Preference.Playback.CaptionsMode"] == nil) {
        NSInteger legacy = [defaults boolForKey:@"YTKACE.Preference.Playback.CaptionsDisabled"] ? 2
            : ([defaults boolForKey:@"YTKACE.Preference.Playback.CaptionsAlwaysOn"] ? 1 : 0);
        if (legacy != 0) [defaults setInteger:legacy forKey:@"YTKACE.Preference.Playback.CaptionsMode"];
    }
    if (WolFoxMiscOriginals == nil) {
        WolFoxMiscOriginals = [NSMutableDictionary dictionary];
        WolFoxCaptionControllers = [NSHashTable weakObjectsHashTable];
    }
    WolFoxResolveForcedIdiom();
    if (WolFoxIdiomForced) {
        WolFoxComputeIdiomRanges();
        for (NSString *name in @[@"YTCommonUtils", @"OGLMetrics"]) {
            WolFoxInstallClassHook(name, @"isIPad",
                                   (IMP)WolFoxForcedIsIPad, NULL);
        }
        WolFoxInstallInstanceHook(@"UIDevice", @"userInterfaceIdiom",
                                  (IMP)WolFoxUserInterfaceIdiom,
                                  &OriginalDeviceIdiom);
    }
    WolFoxInstallInstanceHook(@"UIView", @"addInteraction:",
                              (IMP)WolFoxAddInteraction,
                              &OriginalAddInteraction);
    WolFoxInstallInstanceHook(@"UIView", @"semanticContentAttribute",
                              (IMP)WolFoxSemanticContent,
                              &OriginalSemanticContent);
    WolFoxInstallInstanceHook(@"UIView", @"setSemanticContentAttribute:",
                              (IMP)WolFoxSetSemanticContent,
                              &OriginalSetSemanticContent);
    NSArray<NSString *> *miniClasses = @[
        @"YTIPlayabilityStatus",
        @"YTPlayerResponse",
        @"YTIPlayerResponse",
        @"YTMiniplayerController"
    ];
    NSArray<NSString *> *miniSelectors = @[
        @"isPlayableInMiniPlayer",
        @"isPlayableInMiniplayer",
        @"miniplayerEnabled",
        @"isMiniplayerDisabled",
        @"miniPlayerDisabled",
        @"isMiniplayerUnavailable"
    ];
    for (NSString *className in miniClasses) {
        WolFoxInstallMiscBool(className,
            @"isMiniplayerRendererPlaybackModePauseOnly",
            (IMP)WolFoxMiniPlayerPauseOnlyValue);
        for (NSString *selectorName in miniSelectors) {
            WolFoxInstallMiscBool(className, selectorName, (IMP)WolFoxMiniPlayerValue);
        }
    }

    for (NSString *className in @[@"YTIPlayabilityStatus", @"YTPlayerResponse"] ) {
        for (NSString *selectorName in @[
            @"isAgeRestricted",
            @"requiresAgeVerification",
            @"shouldShowAgeGate",
            @"ageGateRequired",
            @"isAgeVerified",
            @"isAgeAllowed"
        ]) {
            WolFoxInstallMiscBool(className, selectorName, (IMP)WolFoxAgeValue);
        }
    }

    NSArray<NSString *> *captionClasses = @[
        @"YTPlayerViewController",
        @"YTLocalPlaybackController",
        @"YTMainAppVideoPlayerOverlayViewController",
        @"YTCaptionController"
    ];
    for (NSString *className in captionClasses) {
        for (NSString *selectorName in @[
            @"captionsEnabled",
            @"areCaptionsEnabled",
            @"isCaptionTrackSelected",
            @"closedCaptionsEnabled",
            @"captionsDisabled"
        ]) {
            WolFoxInstallMiscBool(className, selectorName, (IMP)WolFoxCaptionValue);
        }
        for (NSString *selectorName in @[
            @"setCaptionsEnabled:",
            @"setClosedCaptionsEnabled:"
        ]) {
            WolFoxInstallMiscSetter(className, selectorName, (IMP)WolFoxCaptionSetter);
        }
    }

    NSString *controllerClass = @"MLInnerTubeCaptionController";
    WolFoxInstallClassHook(controllerClass, @"allocWithZone:",
                          (IMP)WolFoxCaptionControllerAlloc,
                          &OriginalCaptionControllerAlloc);
    IMP controllerOriginal = NULL;
    if (WolFoxInstallInstanceHook(controllerClass, @"init",
                                  (IMP)WolFoxCaptionControllerInit,
                                  &controllerOriginal)) {
        WolFoxStoreMiscOriginal(controllerClass, @"init",
                                controllerOriginal);
    }
    WolFoxApplyCachedMiscDiscovery();
    static dispatch_once_t discoveryObserverToken;
    dispatch_once(&discoveryObserverToken, ^{
        [NSNotificationCenter.defaultCenter
            addObserverForName:UIApplicationDidBecomeActiveNotification
                        object:nil
                         queue:nil
                    usingBlock:^(__unused NSNotification *notification) {
            if ([NSUserDefaults.standardUserDefaults
                    arrayForKey:WolFoxMiscDiscoveryCacheKey()].count != 0) {
                return;
            }
            static dispatch_once_t discoveryToken;
            dispatch_once(&discoveryToken, ^{
                for (NSNumber *delay in @[@0.5, @5.0]) {
                    dispatch_after(
                        dispatch_time(DISPATCH_TIME_NOW,
                          (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                        dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                            WolFoxDiscoverMiscHooks();
                        }
                    );
                }
            });
        }];
    });

    for (NSString *selectorName in @[@"showMessageMainThread:", @"showMessage:"]) {
        IMP original = NULL;
        if (WolFoxInstallInstanceHook(@"GOOHUDManagerInternal",
                                      selectorName,
                                      (IMP)WolFoxHUDMessage,
                                      &original)) {
            WolFoxStoreMiscOriginal(@"GOOHUDManagerInternal", selectorName, original);
        }
    }
}
