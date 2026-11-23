#import "../../WolFox.h"
#import "../../Runtime/Localization.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"
#import "../Downloads/DownloadCoordinator.h"
#import "../Downloads/DownloadLog.h"

#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

static NSHashTable<UIView *> *WolFoxReelViews;
static NSMutableDictionary<NSString *, NSValue *> *WolFoxShortsOriginals;
static NSMutableSet<NSString *> *WolFoxShortsInstalledHooks;
static const void *WolFoxShortsTrackAssociation = &WolFoxShortsTrackAssociation;
static const void *WolFoxShortsFillAssociation = &WolFoxShortsFillAssociation;
static const void *WolFoxShortsSkipAssociation = &WolFoxShortsSkipAssociation;
static const void *WolFoxShortsLastTimeAssociation = &WolFoxShortsLastTimeAssociation;
static const void *WolFoxShortsDownloadAssociation = &WolFoxShortsDownloadAssociation;
static const void *WolFoxShortsHiddenAssociation = &WolFoxShortsHiddenAssociation;
static const void *WolFoxShortsDownloadConstraintsAssociation =
    &WolFoxShortsDownloadConstraintsAssociation;
static const void *WolFoxShortsDownloadAnchoredAssociation =
    &WolFoxShortsDownloadAnchoredAssociation;
static const void *WolFoxShortsRailTransformAssociation =
    &WolFoxShortsRailTransformAssociation;
static const void *WolFoxShortsInitialRefreshAssociation =
    &WolFoxShortsInitialRefreshAssociation;
static NSInteger const WolFoxShortsDownloadTag = 0x59544B44;
static double WolFoxLastShortsTime;
static double WolFoxLastShortsDuration;
static id WolFoxLatestShortsPlayerResponse;

static void WolFoxReelLayout(UIView *receiver, SEL selector);
static void WolFoxReelOverlayLayout(UIView *receiver, SEL selector);
static void WolFoxShortsControllerLayout(UIViewController *receiver,
                                         SEL selector);
static void WolFoxPausedLayout(UIView *receiver, SEL selector);
static void WolFoxInteractiveStickerLayout(UIView *receiver, SEL selector);
static NSArray<NSArray<NSString *> *> *WolFoxShortsRules(void);

static void WolFoxSetShortsHidden(UIView *view, BOOL hidden) {
    NSNumber *owned = objc_getAssociatedObject(
        view, WolFoxShortsHiddenAssociation);
    if (hidden) {
        if (owned == nil) {
            objc_setAssociatedObject(view, WolFoxShortsHiddenAssociation, @YES,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        view.hidden = YES;
        view.userInteractionEnabled = NO;
    } else if (owned != nil) {
        view.hidden = NO;
        view.userInteractionEnabled = YES;
        objc_setAssociatedObject(view, WolFoxShortsHiddenAssociation, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static BOOL WolFoxAnyShortsActionHidden(void) {
    for (NSArray<NSString *> *rule in WolFoxShortsRules()) {
        if (WolFoxFeatureEnabled(rule.firstObject)) return YES;
    }
    return NO;
}

static NSArray<NSArray<NSString *> *> *WolFoxShortsRules(void) {
    static NSArray<NSArray<NSString *> *> *rules;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        rules = @[
            @[@"YTKACE.Preference.Shorts.RemixHidden", @"id.reel_remix_button"],
            @[@"YTKACE.Preference.Shorts.SoundHidden", @"id.reel_pivot_button"],
            @[@"YTKACE.Preference.Shorts.ShareHidden", @"id.reel_share_button"],
            @[@"YTKACE.Preference.Shorts.CommentsHidden", @"id.reel_comment_button"],
            @[@"YTKACE.Preference.Shorts.LikeHidden", @"id.reel_like_button"],
            @[@"YTKACE.Preference.Shorts.SaveHidden"]
        ];
    });
    return rules;
}

typedef struct {
    CGFloat minX;
    CGFloat width;
    CGFloat height;
    BOOL valid;
} WolFoxRailMetrics;

static BOOL WolFoxIsIdentifiedRailButton(NSString *identifier) {
    return [identifier hasPrefix:@"id.reel_"] &&
        [identifier hasSuffix:@"_button"];
}

static void WolFoxCollectRailMetrics(UIView *view,
                                     UIView *root,
                                     WolFoxRailMetrics *metrics) {
    NSString *identifier = view.accessibilityIdentifier.lowercaseString ?: @"";
    if (WolFoxIsIdentifiedRailButton(identifier)) {
        CGRect frame = [view convertRect:view.bounds toView:root];
        if (CGRectGetWidth(frame) > 32.0 && CGRectGetHeight(frame) > 32.0) {
            metrics->minX = CGRectGetMinX(frame);
            metrics->width = CGRectGetWidth(frame);
            metrics->height = CGRectGetHeight(frame);
            metrics->valid = YES;
        }
    }
    for (UIView *child in view.subviews) {
        WolFoxCollectRailMetrics(child, root, metrics);
    }
}

static BOOL WolFoxShortsIsSaveButton(UIView *view,
                                     UIView *root,
                                     const WolFoxRailMetrics *metrics) {
    if (metrics == NULL || !metrics->valid) return NO;
    if (view.accessibilityIdentifier.length != 0) return NO;
    if (view.accessibilityLabel.length == 0) return NO;
    if (view.tag == WolFoxShortsDownloadTag) return NO;
    CGRect frame = [view convertRect:view.bounds toView:root];
    return fabs(CGRectGetMinX(frame) - metrics->minX) < 6.0 &&
        fabs(CGRectGetWidth(frame) - metrics->width) < 8.0 &&
        fabs(CGRectGetHeight(frame) - metrics->height) < 14.0;
}

static BOOL WolFoxShortsActionHidden(UIView *view,
                                     UIView *root,
                                     const WolFoxRailMetrics *metrics) {
    if (view.tag == WolFoxShortsDownloadTag ||
        [view.accessibilityIdentifier hasPrefix:@"WolFox"]) {
        return NO;
    }
    NSString *identifier = view.accessibilityIdentifier.lowercaseString ?: @"";
    BOOL actionable = [view isKindOfClass:UIControl.class] ||
        view.accessibilityIdentifier.length != 0 ||
        view.accessibilityLabel.length != 0;
    if (!actionable) return NO;
    if (WolFoxFeatureEnabled(@"YTKACE.Preference.Shorts.SaveHidden") &&
        WolFoxShortsIsSaveButton(view, root, metrics)) {
        return YES;
    }
    for (NSArray<NSString *> *rule in WolFoxShortsRules()) {
        if (!WolFoxFeatureEnabled(rule.firstObject)) continue;
        for (NSUInteger index = 1; index < rule.count; index++) {
            NSString *needle = rule[index];
            if (identifier.length != 0 && [identifier containsString:needle]) {
                return YES;
            }
        }
    }
    return NO;
}

static void WolFoxApplyShortsVisibilityWalk(UIView *view,
                                            UIView *root,
                                            const WolFoxRailMetrics *metrics) {
    WolFoxSetShortsHidden(view, WolFoxShortsActionHidden(view, root, metrics));
    for (UIView *subview in view.subviews) {
        WolFoxApplyShortsVisibilityWalk(subview, root, metrics);
    }
}

static void WolFoxApplyShortsActionVisibility(UIView *view) {
    WolFoxRailMetrics metrics = {0.0, 0.0, 0.0, NO};
    WolFoxCollectRailMetrics(view, view, &metrics);
    WolFoxApplyShortsVisibilityWalk(view, view, &metrics);
}

static BOOL WolFoxIsShortsActionIdentifier(NSString *identifier) {
    return [identifier isEqualToString:@"id.reel_like_button"] ||
        [identifier isEqualToString:@"id.reel_comment_button"] ||
        [identifier isEqualToString:@"id.reel_share_button"] ||
        [identifier isEqualToString:@"id.reel_remix_button"] ||
        [identifier isEqualToString:@"id.reel_pivot_button"] ||
        [identifier isEqualToString:@"id.ytkace_dislike_button"];
}

static BOOL WolFoxIsShortsActionView(UIView *view, UIView *root,
                                     const WolFoxRailMetrics *metrics) {
    NSString *identifier = view.accessibilityIdentifier.lowercaseString ?: @"";
    if (identifier.length != 0) {
        return WolFoxIsShortsActionIdentifier(identifier);
    }
    return WolFoxShortsIsSaveButton(view, root, metrics);
}

static BOOL WolFoxActionIsFullyVisible(UIView *view, UIView *root) {
    CGRect frame = [view convertRect:view.bounds toView:root];
    return CGRectGetWidth(frame) > 20.0 &&
        CGRectGetHeight(frame) > 20.0 &&
        CGRectGetMidX(frame) > CGRectGetWidth(root.bounds) * 0.55 &&
        CGRectGetMinY(frame) >= 0.0 &&
        CGRectGetMaxY(frame) <= CGRectGetHeight(root.bounds);
}

static UIView *WolFoxShortsPlaybackOverlay(UIView *view, UIView *root) {
    for (UIView *candidate = view; candidate != nil;
         candidate = candidate.superview) {
        if ([NSStringFromClass(candidate.class)
                containsString:@"ReelWatchPlaybackOverlayView"]) {
            return candidate;
        }
        if (candidate == root) break;
    }
    CGSize full = root.bounds.size;
    for (UIView *candidate = view.superview; candidate != nil && candidate != root;
         candidate = candidate.superview) {
        CGSize size = candidate.bounds.size;
        if (size.width >= full.width * 0.9 && size.height >= full.height * 0.6) return candidate;
    }
    return nil;
}

static void WolFoxCollectShortsActionsWalk(UIView *view,
                                           UIView *root,
                                           BOOL includeHidden,
                                           const WolFoxRailMetrics *metrics,
                                           NSMutableArray<UIView *> *views) {
    if (view.tag != WolFoxShortsDownloadTag &&
        (includeHidden || (!view.hidden && view.alpha > 0.05)) &&
        WolFoxIsShortsActionView(view, root, metrics) &&
        WolFoxActionIsFullyVisible(view, root)) {
        [views addObject:view];
    }
    for (UIView *subview in view.subviews) {
        WolFoxCollectShortsActionsWalk(subview, root, includeHidden, metrics, views);
    }
}

static void WolFoxCollectShortsActions(UIView *view,
                                       UIView *root,
                                       BOOL includeHidden,
                                       NSMutableArray<UIView *> *views) {
    WolFoxRailMetrics metrics = {0.0, 0.0, 0.0, NO};
    WolFoxCollectRailMetrics(root, root, &metrics);
    WolFoxCollectShortsActionsWalk(view, root, includeHidden, &metrics, views);
}

static BOOL WolFoxShortsHasDislikeView(NSArray<UIView *> *actions) {
    for (UIView *action in actions) {
        if (!action.hidden && [action.accessibilityIdentifier isEqualToString:@"id.ytkace_dislike_button"]) return YES;
    }
    return NO;
}

static UIView *WolFoxVisibleShortsAction(UIView *root) {
    NSMutableArray<UIView *> *actions = [NSMutableArray array];
    WolFoxCollectShortsActions(root, root, NO, actions);
    NSString *expected = nil;
    if (!WolFoxFeatureEnabled(@"YTKACE.Preference.Shorts.LikeHidden")) {
        expected = @"id.reel_like_button";
    } else if (WolFoxFeatureEnabled(@"YTKACE.Preference.Shorts.DislikeCount") &&
               WolFoxShortsHasDislikeView(actions)) {
        expected = @"id.ytkace_dislike_button";
    } else if (!WolFoxFeatureEnabled(@"YTKACE.Preference.Shorts.CommentsHidden")) {
        expected = @"id.reel_comment_button";
    } else if (!WolFoxFeatureEnabled(@"YTKACE.Preference.Shorts.ShareHidden")) {
        expected = @"id.reel_share_button";
    } else if (!WolFoxFeatureEnabled(@"YTKACE.Preference.Shorts.RemixHidden")) {
        expected = @"id.reel_remix_button";
    } else if (!WolFoxFeatureEnabled(@"YTKACE.Preference.Shorts.SoundHidden")) {
        expected = @"id.reel_pivot_button";
    }
    if (expected == nil) return nil;
    for (UIView *action in actions) {
        if (WolFoxShortsPlaybackOverlay(action, root) == nil) continue;
        if ([action.accessibilityIdentifier.lowercaseString
                isEqualToString:expected]) {
            return action;
        }
    }
    return nil;
}

static UIView *WolFoxVisibleShortsPlaybackOverlay(UIView *root) {
    NSString *className = NSStringFromClass(root.class);
    if ([className containsString:@"ReelWatchPlaybackOverlayView"] &&
        root.window != nil && !root.hidden && root.alpha > 0.05 &&
        CGRectGetWidth(root.bounds) > 200.0 &&
        CGRectGetHeight(root.bounds) > 300.0) {
        return root;
    }
    for (UIView *subview in root.subviews) {
        UIView *overlay = WolFoxVisibleShortsPlaybackOverlay(subview);
        if (overlay != nil) return overlay;
    }
    return nil;
}

static UIView *WolFoxCurrentShortsPlaybackOverlay(UIView *root) {
    UIView *visibleOverlay = WolFoxVisibleShortsPlaybackOverlay(root);
    if (visibleOverlay != nil) return visibleOverlay;
    NSMutableArray<UIView *> *actions = [NSMutableArray array];
    WolFoxCollectShortsActions(root, root, YES, actions);
    for (UIView *action in actions) {
        UIView *overlay = WolFoxShortsPlaybackOverlay(action, root);
        if (overlay != nil) return overlay;
    }
    return nil;
}

static void WolFoxCompactShortsRail(UIView *root) {
    if (!WolFoxAnyShortsActionHidden()) return;
    NSMutableArray<UIView *> *actions = [NSMutableArray array];
    WolFoxCollectShortsActions(root, root, YES, actions);
    for (UIView *action in actions) {
        NSValue *baselineValue = objc_getAssociatedObject(
            action, WolFoxShortsRailTransformAssociation);
        if (baselineValue == nil) {
            baselineValue = [NSValue valueWithCGAffineTransform:action.transform];
            objc_setAssociatedObject(action,
                WolFoxShortsRailTransformAssociation, baselineValue,
                OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        action.transform = baselineValue.CGAffineTransformValue;
    }
    for (UIView *action in actions) {
        NSValue *baselineValue = objc_getAssociatedObject(
            action, WolFoxShortsRailTransformAssociation);
        CGFloat offset = 0.0;
        if (!action.hidden) {
            CGFloat actionY = CGRectGetMinY(
                [action convertRect:action.bounds toView:root]);
            for (UIView *candidate in actions) {
                if (!candidate.hidden) continue;
                CGFloat hiddenY = CGRectGetMinY(
                    [candidate convertRect:candidate.bounds toView:root]);
                if (hiddenY > actionY) {
                    offset += 64.0;
                }
            }
        }
        action.transform = CGAffineTransformTranslate(
            baselineValue.CGAffineTransformValue, 0.0, offset);
    }
}

static void WolFoxPositionShortsDownload(UIView *host,
                                         UIView *action,
                                         UIButton *download) {
    NSArray<NSLayoutConstraint *> *constraints = objc_getAssociatedObject(
        download, WolFoxShortsDownloadConstraintsAssociation);
    NSInteger position = [NSUserDefaults.standardUserDefaults
        integerForKey:@"YTKACE.Preference.Shorts.DownloadPosition"];
    BOOL legacyHost = [NSStringFromClass(host.class) containsString:@"ReelWatchPlaybackOverlayView"];
    if (position == 0 && !legacyHost) {
        if (constraints.count != 0) [NSLayoutConstraint deactivateConstraints:constraints];
        download.translatesAutoresizingMaskIntoConstraints = YES;
        UIEdgeInsets safe = host.safeAreaInsets;
        download.frame = CGRectMake(round(CGRectGetWidth(host.bounds) - safe.right - 12.0 - 36.0),
                                    round(safe.top + 65.0), 36.0, 36.0);
        download.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleBottomMargin;
        return;
    }
    if (position == 0) {
        if (download.translatesAutoresizingMaskIntoConstraints) {
            download.translatesAutoresizingMaskIntoConstraints = NO;
        }
        if (constraints == nil) {
            constraints = @[
                [download.widthAnchor constraintEqualToConstant:36.0],
                [download.heightAnchor constraintEqualToConstant:36.0],
                [download.trailingAnchor constraintEqualToAnchor:
                    host.safeAreaLayoutGuide.trailingAnchor constant:-12.0],
                [download.topAnchor constraintEqualToAnchor:
                    host.safeAreaLayoutGuide.topAnchor constant:65.0]
            ];
            objc_setAssociatedObject(download,
                WolFoxShortsDownloadConstraintsAssociation,
                constraints, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        [NSLayoutConstraint activateConstraints:constraints];
        [host layoutIfNeeded];
        return;
    }

    if (constraints.count != 0) {
        [NSLayoutConstraint deactivateConstraints:constraints];
    }
    download.translatesAutoresizingMaskIntoConstraints = YES;
    CGFloat centerX = CGRectGetWidth(host.bounds) - 32.0;
    CGFloat top = host.safeAreaInsets.top + 65.0;
    if (action == nil && !CGRectIsEmpty(download.frame) &&
        CGRectGetWidth(download.frame) >= 35.0) {
        return;
    }
    if (action != nil) {
        CGRect frame = [action convertRect:action.bounds toView:host];
        centerX = CGRectGetMidX(frame);
        top = CGRectGetMinY(frame) - 48.0;
    }
    top = MAX(host.safeAreaInsets.top + 52.0, top);
    download.frame = CGRectMake(round(centerX - 18.0), round(top), 36.0, 36.0);
    download.autoresizingMask =
        UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleTopMargin;
}

static NSString *WolFoxShortsHookKey(Class cls, SEL selector) {
    return [NSString stringWithFormat:@"%@|%@", NSStringFromClass(cls),
                                      NSStringFromSelector(selector)];
}

static IMP WolFoxShortsOriginal(id receiver, SEL selector,
                                NSUInteger ordinal) {
    NSUInteger candidate = 0;
    for (Class cls = object_getClass(receiver); cls != Nil;
         cls = class_getSuperclass(cls)) {
        IMP original = (IMP)[WolFoxShortsOriginals[
            WolFoxShortsHookKey(cls, selector)] pointerValue];
        if (original != NULL &&
            original != (IMP)WolFoxReelLayout &&
            original != (IMP)WolFoxReelOverlayLayout &&
            original != (IMP)WolFoxShortsControllerLayout &&
            original != (IMP)WolFoxPausedLayout &&
            original != (IMP)WolFoxInteractiveStickerLayout) {
            if (candidate == ordinal) {
                return original;
            }
            candidate++;
        }
    }
    return NULL;
}

static void WolFoxInvokeShortsOriginal(id receiver, SEL selector) {
    NSMutableDictionary *threadState = NSThread.currentThread.threadDictionary;
    NSString *depthKey = [NSString stringWithFormat:
        @"WolFox.Shorts.%p.%@", receiver, NSStringFromSelector(selector)];
    NSUInteger depth = [threadState[depthKey] unsignedIntegerValue];
    IMP original = WolFoxShortsOriginal(receiver, selector, depth);
    if (original == NULL) return;

    threadState[depthKey] = @(depth + 1);
    @try {
        ((void (*)(id, SEL))original)(receiver, selector);
    } @finally {
        if (depth == 0) {
            [threadState removeObjectForKey:depthKey];
        } else {
            threadState[depthKey] = @(depth);
        }
    }
}

static Method WolFoxShortsDirectMethod(Class cls, SEL selector) {
    if (cls == Nil) return NULL;
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    Method result = NULL;
    for (unsigned int index = 0; index < count; index++) {
        if (method_getName(methods[index]) == selector) {
            result = methods[index];
            break;
        }
    }
    free(methods);
    return result;
}

static BOOL WolFoxShortsIsReplacement(IMP implementation) {
    return implementation == (IMP)WolFoxReelLayout ||
        implementation == (IMP)WolFoxReelOverlayLayout ||
        implementation == (IMP)WolFoxShortsControllerLayout ||
        implementation == (IMP)WolFoxPausedLayout ||
        implementation == (IMP)WolFoxInteractiveStickerLayout;
}

static id WolFoxShortsObject(id receiver, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    return [receiver respondsToSelector:selector]
        ? ((id (*)(id, SEL))objc_msgSend)(receiver, selector) : nil;
}

static id WolFoxShortsResponseFromObject(id object,
                                         NSHashTable *visited,
                                         NSUInteger depth) {
    if (object == nil || depth > 7 || [visited containsObject:object]) {
        return nil;
    }
    [visited addObject:object];
    id response = WolFoxShortsObject(object, @"contentPlayerResponse") ?:
        WolFoxShortsObject(object, @"playerResponse");
    if (response != nil) {
        return response;
    }
    for (NSString *name in @[@"_youtubeiOSPlayerViewController", @"parentResponder",
                              @"parentViewController", @"eventsDelegate",
                              @"playbackController", @"activeVideoPlayerOverlay"]) {
        id related = WolFoxShortsObject(object, name);
        response = WolFoxShortsResponseFromObject(related, visited, depth + 1);
        if (response != nil) {
            return response;
        }
    }
    if ([object isKindOfClass:UIResponder.class]) {
        return WolFoxShortsResponseFromObject(
            ((UIResponder *)object).nextResponder, visited, depth + 1);
    }
    return nil;
}

static NSMutableDictionary<NSString *, NSNumber *> *WolFoxShortsBarrenClasses;

static id WolFoxShortsPlayerResponseFromObject(id object) {
    if (object == nil) return nil;
    NSString *name = NSStringFromClass([object class]);
    if (WolFoxShortsBarrenClasses == nil) {
        WolFoxShortsBarrenClasses = [NSMutableDictionary dictionary];
    }
    if (WolFoxShortsBarrenClasses[name].integerValue >= 3) return nil;

    NSHashTable *visited = [NSHashTable hashTableWithOptions:
        NSPointerFunctionsObjectPointerPersonality];
    id result = WolFoxShortsResponseFromObject(object, visited, 0);
    if (result != nil) {
        [WolFoxShortsBarrenClasses removeObjectForKey:name];
    } else {
        WolFoxShortsBarrenClasses[name] =
            @(WolFoxShortsBarrenClasses[name].integerValue + 1);
    }
    return result;
}

@interface WolFoxShortsDownloadTarget : NSObject
+ (instancetype)sharedTarget;
- (void)downloadTapped:(UIButton *)sender;
@end

@implementation WolFoxShortsDownloadTarget
+ (instancetype)sharedTarget {
    static WolFoxShortsDownloadTarget *target;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ target = [WolFoxShortsDownloadTarget new]; });
    return target;
}
- (void)downloadTapped:(UIButton *)sender {
    [WolFoxShortsBarrenClasses removeAllObjects];
    id fromView = WolFoxShortsPlayerResponseFromObject(sender);
    id response = fromView ?: WolFoxLatestShortsPlayerResponse;
    WolFoxDownloadCoordinator.sharedCoordinator.playerResponse = response;
    [WolFoxDownloadCoordinator.sharedCoordinator
        showShortsDownloadMenuFromView:sender];
}
@end

static double WolFoxShortsDouble(id receiver, NSArray<NSString *> *names) {
    for (NSString *name in names) {
        SEL selector = NSSelectorFromString(name);
        if ([receiver respondsToSelector:selector]) {
            return ((double (*)(id, SEL))objc_msgSend)(receiver, selector);
        }
    }
    return 0.0;
}

static id WolFoxShortsParent(id receiver) {
    SEL selector = NSSelectorFromString(@"parentViewController");
    return [receiver respondsToSelector:selector]
        ? ((id (*)(id, SEL))objc_msgSend)(receiver, selector)
        : nil;
}

static id WolFoxFindShortsController(id receiver) {
    id current = receiver;
    for (NSInteger index = 0; current != nil && index < 10; index++) {
        NSString *name = NSStringFromClass([current class]).lowercaseString;
        if ([name containsString:@"shorts"] || [name containsString:@"reel"]) {
            return current;
        }
        id parent = WolFoxShortsParent(current);
        if (parent != nil && parent != current) {
            current = parent;
        } else if ([current isKindOfClass:UIResponder.class]) {
            current = ((UIResponder *)current).nextResponder;
        } else {
            break;
        }
    }
    return nil;
}

static BOOL WolFoxAdvanceShort(id controller, id sender) {
    for (NSString *name in @[
        @"reelContentViewRequestsAdvanceToNextVideo:",
        @"advanceToNextVideo:",
        @"advanceToNextVideo",
        @"scrollToNextVideo"
    ]) {
        SEL selector = NSSelectorFromString(name);
        Method method = class_getInstanceMethod([controller class], selector);
        if (method == NULL) {
            continue;
        }
        if (method_getNumberOfArguments(method) == 3) {
            ((void (*)(id, SEL, id))objc_msgSend)(controller, selector, sender);
        } else {
            ((void (*)(id, SEL))objc_msgSend)(controller, selector);
        }
        return YES;
    }
    SEL reelAdvance = NSSelectorFromString(@"advanceToNextReelWithTransitionType:");
    id current = controller;
    for (NSInteger depth = 0; current != nil && depth < 8; depth++) {
        Method method = class_getInstanceMethod([current class], reelAdvance);
        if (method != NULL) {
            char type[8] = {0};
            method_getArgumentType(method, 2, type, sizeof(type));
            if (strchr("qQiIlL", type[0]) != NULL && type[1] == 0) {
                ((void (*)(id, SEL, long long))objc_msgSend)(current, reelAdvance, 0);
                return YES;
            }
        }
        id parent = WolFoxShortsParent(current);
        current = parent != nil && parent != current ? parent
            : ([current isKindOfClass:UIResponder.class] ? ((UIResponder *)current).nextResponder : nil);
    }
    UIView *view = [controller isKindOfClass:UIViewController.class] ? ((UIViewController *)controller).view : nil;
    for (UIView *candidate = view.superview; candidate != nil; candidate = candidate.superview) {
        if (![candidate isKindOfClass:UIScrollView.class]) continue;
        UIScrollView *pager = (UIScrollView *)candidate;
        CGFloat page = CGRectGetHeight(pager.bounds);
        if (page < 100.0 || page < CGRectGetHeight(view.bounds) * 0.9) continue;
        CGFloat next = round(pager.contentOffset.y / page) * page + page;
        if (next > pager.contentSize.height - page + 1.0) break;
        [pager setContentOffset:CGPointMake(pager.contentOffset.x, next) animated:YES];
        return YES;
    }
    return NO;
}

static void WolFoxUpdateShortsProgress(void) {
    BOOL enabled = WolFoxFeatureEnabled(@"shortsProgress");
    CGFloat ratio = WolFoxLastShortsDuration > 0.0
        ? (CGFloat)MIN(1.0, MAX(0.0, WolFoxLastShortsTime / WolFoxLastShortsDuration))
        : 0.0;
    for (UIView *view in WolFoxReelViews.allObjects) {
        CALayer *track = objc_getAssociatedObject(view, WolFoxShortsTrackAssociation);
        CALayer *fill = objc_getAssociatedObject(view, WolFoxShortsFillAssociation);
        track.hidden = !enabled;
        fill.hidden = !enabled;
        if (enabled) {
            CGFloat height = 3.0;
            track.frame = CGRectMake(0.0,
                                     MAX(0.0, CGRectGetHeight(view.bounds) - height),
                                     CGRectGetWidth(view.bounds),
                                     height);
            fill.frame = CGRectMake(0.0, 0.0,
                                    CGRectGetWidth(track.bounds) * ratio,
                                    height);
            WolFoxStyleProgressLayer(fill, CGRectGetWidth(track.bounds));
        }
    }
}

@interface WolFoxShortsPinchTarget : NSObject <UIGestureRecognizerDelegate>
@end

@implementation WolFoxShortsPinchTarget
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gesture shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    if ([other isKindOfClass:UIPinchGestureRecognizer.class]) return NO;
    if ([other.view isKindOfClass:UIScrollView.class] &&
        other == ((UIScrollView *)other.view).panGestureRecognizer) return NO;
    return YES;
}

- (void)stopPagerUnder:(UIView *)view {
    UIScrollView *pager = nil;
    for (UIView *candidate = view.superview; candidate != nil; candidate = candidate.superview) {
        if ([candidate isKindOfClass:UIScrollView.class]) {
            pager = (UIScrollView *)candidate;
            break;
        }
    }
    if (pager == nil) return;
    CGFloat page = CGRectGetHeight(pager.bounds);
    CGPoint offset = pager.contentOffset;
    pager.panGestureRecognizer.enabled = NO;
    pager.panGestureRecognizer.enabled = YES;
    if (page > 1.0) {
        CGFloat snapped = round(offset.y / page) * page;
        if (fabs(snapped - offset.y) > 0.5) [pager setContentOffset:CGPointMake(offset.x, snapped) animated:YES];
    }
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gesture shouldBeRequiredToFailByGestureRecognizer:(UIGestureRecognizer *)other {
    if (![other isKindOfClass:UIPinchGestureRecognizer.class] || other == gesture) return NO;
    return YES;
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gesture {
    return WolFoxFeatureEnabled(@"YTKACE.Preference.Shorts.PinchFullscreen");
}

- (void)pinched:(UIPinchGestureRecognizer *)pinch {
    if (pinch.state == UIGestureRecognizerStateBegan) {
        [self stopPagerUnder:pinch.view];
        return;
    }
    if (pinch.state != UIGestureRecognizerStateEnded) return;
    BOOL active = WolFoxShortsNewFullscreenActive();
    if (pinch.scale > 1.0 && !active) {
        WolFoxSetShortsNewFullscreen(pinch.view, YES);
    } else if (pinch.scale < 1.0 && active) {
        WolFoxSetShortsNewFullscreen(pinch.view, NO);
    }
}
@end

static const void *WolFoxShortsPinchAssociation = &WolFoxShortsPinchAssociation;
static const void *WolFoxShortsRetryAssociation = &WolFoxShortsRetryAssociation;
static void WolFoxConfigureReelView(UIView *receiver, BOOL showDownload);
static IMP OriginalReelElementLayout;

static void WolFoxReelElementLayout(UIView *receiver, SEL selector) {
    if (OriginalReelElementLayout != NULL) ((void (*)(id, SEL))OriginalReelElementLayout)(receiver, selector);
    if (!WolFoxShortsNewFullscreenActive() || receiver.alpha <= 0.01 || receiver.window == nil) return;
    Class containerClass = NSClassFromString(@"YTReelContainerView");
    UIView *container = receiver.superview;
    for (NSUInteger depth = 0; container != nil && depth < 8 && ![container isKindOfClass:containerClass]; depth++) {
        container = container.superview;
    }
    if (![container isKindOfClass:containerClass]) return;
    WolFoxRegisterFadedShortsContainer(container);
    WolFoxFadeShortsElement(receiver);
}

static void WolFoxPrepareNewShortsContainer(UIView *receiver) {
    if (![NSStringFromClass(receiver.class) isEqualToString:@"YTReelContainerView"]) return;
    if (objc_getAssociatedObject(receiver, WolFoxShortsPinchAssociation) == nil) {
        static WolFoxShortsPinchTarget *target;
        if (target == nil) target = [WolFoxShortsPinchTarget new];
        UIPinchGestureRecognizer *pinch = [[UIPinchGestureRecognizer alloc] initWithTarget:target
                                                                                    action:@selector(pinched:)];
        pinch.delegate = target;
        pinch.cancelsTouchesInView = NO;
        [receiver addGestureRecognizer:pinch];
        objc_setAssociatedObject(receiver, WolFoxShortsPinchAssociation, pinch, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static void WolFoxConfigureReelView(UIView *receiver, BOOL showDownload) {
    [WolFoxReelViews addObject:receiver];
    WolFoxPrepareNewShortsContainer(receiver);
    CALayer *track = objc_getAssociatedObject(receiver, WolFoxShortsTrackAssociation);
    CALayer *fill = objc_getAssociatedObject(receiver, WolFoxShortsFillAssociation);
    if (track == nil) {
        track = [CALayer layer];
        track.backgroundColor = [UIColor colorWithWhite:0.45 alpha:0.55].CGColor;
        track.zPosition = 10000.0;
        fill = [CALayer layer];
        fill.backgroundColor = UIColor.redColor.CGColor;
        objc_setAssociatedObject(receiver, WolFoxShortsFillAssociation,
                                 fill, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [track addSublayer:fill];
        [receiver.layer addSublayer:track];
        objc_setAssociatedObject(receiver, WolFoxShortsTrackAssociation,
                                 track, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(receiver, WolFoxShortsFillAssociation,
                                 fill, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (showDownload) {
        WolFoxApplyShortsActionVisibility(receiver);
        WolFoxCompactShortsRail(receiver);
    }
    BOOL visibleHost = receiver.window != nil && !receiver.hidden &&
        receiver.alpha > 0.05 && CGRectGetWidth(receiver.bounds) > 200.0 &&
        CGRectGetHeight(receiver.bounds) > 300.0;
    UIView *action = showDownload && visibleHost
        ? WolFoxVisibleShortsAction(receiver)
        : nil;
    UIView *downloadHost = action == nil
        ? WolFoxCurrentShortsPlaybackOverlay(receiver)
        : WolFoxShortsPlaybackOverlay(action, receiver);
    if (![NSStringFromClass(downloadHost.class) containsString:@"ReelWatchPlaybackOverlayView"]) {
        Class containerClass = NSClassFromString(@"YTReelContainerView");
        UIView *container = nil;
        for (UIView *candidate = action ?: receiver; candidate != nil; candidate = candidate.superview) {
            if (containerClass != Nil && [candidate isKindOfClass:containerClass]) {
                container = candidate;
                break;
            }
        }
        if (container == nil && containerClass != Nil && [receiver isKindOfClass:containerClass]) container = receiver;
        if (container != nil && showDownload && visibleHost) downloadHost = container;
        else if (container == nil && downloadHost != nil &&
                 ![NSStringFromClass(downloadHost.class) containsString:@"ReelWatchPlaybackOverlayView"]) downloadHost = nil;
    }
    UIButton *download = objc_getAssociatedObject(
        downloadHost, WolFoxShortsDownloadAssociation);
    if (showDownload && visibleHost && downloadHost != nil &&
        download == nil) {
        download = [UIButton buttonWithType:UIButtonTypeSystem];
        download.tag = WolFoxShortsDownloadTag;
        download.accessibilityIdentifier = @"WolFox Shorts Download";
        download.accessibilityLabel = WolFoxLocalized(@"Download Short");
        download.tintColor = UIColor.whiteColor;
        [download setImage:WolFoxDownloadGlyphImage()
                  forState:UIControlStateNormal];
        UIImageSymbolConfiguration *configuration =
            [UIImageSymbolConfiguration configurationWithPointSize:20.0
                                                            weight:UIImageSymbolWeightMedium];
        [download setPreferredSymbolConfiguration:configuration
                                  forImageInState:UIControlStateNormal];
        download.layer.shadowColor = UIColor.blackColor.CGColor;
        download.layer.shadowOpacity = 0.55;
        download.layer.shadowRadius = 4.0;
        download.layer.shadowOffset = CGSizeMake(0.0, 2.0);
        download.translatesAutoresizingMaskIntoConstraints = NO;
        [download addTarget:WolFoxShortsDownloadTarget.sharedTarget
                     action:@selector(downloadTapped:)
           forControlEvents:UIControlEventTouchUpInside];
        [downloadHost addSubview:download];
        objc_setAssociatedObject(downloadHost, WolFoxShortsDownloadAssociation,
            download, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (download != nil && download.superview == downloadHost) {
        if (action != nil) {
            objc_setAssociatedObject(download,
                WolFoxShortsDownloadAnchoredAssociation, @YES,
                OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        BOOL railMode = [NSUserDefaults.standardUserDefaults
            integerForKey:@"YTKACE.Preference.Shorts.DownloadPosition"] != 0;
        BOOL anchored = [objc_getAssociatedObject(download,
            WolFoxShortsDownloadAnchoredAssociation) boolValue];
        BOOL legacyHost = [NSStringFromClass(downloadHost.class) containsString:@"ReelWatchPlaybackOverlayView"];
        download.hidden = !WolFoxDownloadsEnabled() ||
            (railMode && !anchored && (legacyHost || !WolFoxShortsNewFullscreenActive()));
        WolFoxPositionShortsDownload(downloadHost, action, download);
        [downloadHost bringSubviewToFront:download];
        NSMutableArray<UIView *> *stack =
            [NSMutableArray arrayWithObject:downloadHost];
        NSUInteger duplicates = 0;
        while (stack.count != 0) {
            UIView *candidate = stack.lastObject;
            [stack removeLastObject];
            for (UIView *subview in candidate.subviews) {
                if (subview.tag == WolFoxShortsDownloadTag &&
                    subview != download) {
                    duplicates++;
                    [subview removeFromSuperview];
                } else {
                    [stack addObject:subview];
                }
            }
        }
        (void)duplicates;
    }
    if (showDownload && download != nil && download.hidden && WolFoxDownloadsEnabled() && action == nil &&
        downloadHost != nil) {
        NSUInteger retries = [objc_getAssociatedObject(downloadHost, WolFoxShortsRetryAssociation) unsignedIntegerValue];
        if (retries < 4) {
            objc_setAssociatedObject(downloadHost, WolFoxShortsRetryAssociation, @(retries + 1),
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            static const double delays[] = {0.3, 0.7, 1.5, 3.0};
            __weak UIView *weakReceiver = receiver;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delays[retries] * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                UIView *strongReceiver = weakReceiver;
                if (strongReceiver.window != nil) WolFoxConfigureReelView(strongReceiver, YES);
            });
        }
    } else if (download != nil && !download.hidden) {
        objc_setAssociatedObject(downloadHost, WolFoxShortsRetryAssociation, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    static NSTimeInterval lastResolve = 0.0;
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    if (WolFoxLatestShortsPlayerResponse == nil || now - lastResolve > 0.5) {
        lastResolve = now;
        id response = WolFoxShortsPlayerResponseFromObject(receiver);
        if (response != nil) {
            WolFoxLatestShortsPlayerResponse = response;
        }
    }
    WolFoxUpdateShortsProgress();
}

static void WolFoxReelLayout(UIView *receiver, SEL selector) {
    WolFoxInvokeShortsOriginal(receiver, selector);
    WolFoxConfigureReelView(receiver, NO);
}

static void WolFoxReelOverlayLayout(UIView *receiver, SEL selector) {
    WolFoxInvokeShortsOriginal(receiver, selector);
    WolFoxConfigureReelView(receiver, YES);
}

static void WolFoxShortsControllerLayout(UIViewController *receiver,
                                         SEL selector) {
    WolFoxInvokeShortsOriginal(receiver, selector);
    WolFoxConfigureReelView(receiver.view, YES);
    if (![objc_getAssociatedObject(receiver,
            WolFoxShortsInitialRefreshAssociation) boolValue]) {
        objc_setAssociatedObject(receiver,
            WolFoxShortsInitialRefreshAssociation, @YES,
            OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        __weak UIViewController *weakReceiver = receiver;
        for (NSNumber *delay in @[@0.08, @0.30]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                dispatch_get_main_queue(), ^{
                    UIViewController *controller = weakReceiver;
                    if (controller.view.window != nil) {
                        WolFoxConfigureReelView(controller.view, YES);
                    }
                });
        }
    }
}

static void WolFoxPausedLayout(UIView *receiver, SEL selector) {
    WolFoxInvokeShortsOriginal(receiver, selector);
    BOOL hidden = WolFoxFeatureEnabled(@"YTKACE.Preference.Shorts.PauseCardHidden");
    WolFoxSetShortsHidden(receiver, hidden);
}

static void WolFoxInteractiveStickerLayout(UIView *receiver, SEL selector) {
    WolFoxInvokeShortsOriginal(receiver, selector);
    NSString *token = [NSString stringWithFormat:@"%@ %@ %@",
        NSStringFromClass(receiver.class).lowercaseString,
        receiver.accessibilityIdentifier.lowercaseString ?: @"",
        receiver.description.lowercaseString ?: @""];
    BOOL product = WolFoxFeatureEnabled(@"YTKACE.Preference.Overlay.ProductsHidden") &&
        ([token containsString:@"product"] ||
         [token containsString:@"shopping"]);
    BOOL stickerAd = WolFoxFeatureEnabled(@"YTKACE.Preference.Shorts.StickerAdsHidden") &&
        (([token containsString:@"sticker"] &&
          ([token containsString:@"sponsor"] ||
           [token containsString:@"promot"] ||
           [token containsString:@"brand"] ||
           [token containsString:@"product"])) ||
         [token containsString:@"shorts_ads_shopping"]);
    WolFoxSetShortsHidden(receiver, product || stickerAd);
}

static void WolFoxInstallShortsLayout(NSString *className, IMP replacement) {
    Class cls = NSClassFromString(className);
    SEL selector = @selector(layoutSubviews);
    if (WolFoxShortsDirectMethod(cls, selector) == NULL) return;
    NSString *key = WolFoxShortsHookKey(cls, selector);
    if ([WolFoxShortsInstalledHooks containsObject:key]) return;
    IMP current = method_getImplementation(class_getInstanceMethod(cls, selector));
    if (WolFoxShortsIsReplacement(current)) return;
    IMP original = NULL;
    if (WolFoxInstallInstanceHook(className, @"layoutSubviews",
                                  replacement, &original) &&
        original != NULL && !WolFoxShortsIsReplacement(original)) {
        WolFoxShortsOriginals[key] =
            [NSValue valueWithPointer:(const void *)original];
        [WolFoxShortsInstalledHooks addObject:key];
    }
}

static void WolFoxInstallShortsController(NSString *className) {
    SEL selector = @selector(viewDidLayoutSubviews);
    Class cls = NSClassFromString(className);
    if (WolFoxShortsDirectMethod(cls, selector) == NULL) return;
    NSString *key = WolFoxShortsHookKey(cls, selector);
    if ([WolFoxShortsInstalledHooks containsObject:key]) return;
    IMP current = method_getImplementation(class_getInstanceMethod(cls, selector));
    if (WolFoxShortsIsReplacement(current)) return;
    IMP original = NULL;
    if (WolFoxInstallInstanceHook(className,
                                  NSStringFromSelector(selector),
                                  (IMP)WolFoxShortsControllerLayout,
                                  &original) && original != NULL &&
        !WolFoxShortsIsReplacement(original)) {
        WolFoxShortsOriginals[key] =
            [NSValue valueWithPointer:(const void *)original];
        [WolFoxShortsInstalledHooks addObject:key];
    }
}

static const void *WolFoxShortsLoopAssociation = &WolFoxShortsLoopAssociation;

// Comments (or the description) are open over the Short.
static BOOL WolFoxShortsPanelOpen(id shorts) {
    if (!WolFoxFeatureEnabled(@"YTKACE.Preference.Shorts.AutoScrollWaitForComments")) return NO;
    UIWindow *window = [shorts isKindOfClass:UIViewController.class]
        ? ((UIViewController *)shorts).view.window : nil;
    if (window == nil) return NO;
    static Class panelClass;
    if (panelClass == Nil) panelClass = NSClassFromString(@"YTEngagementPanelView");
    if (panelClass == Nil) return NO;
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:window];
    while (stack.count != 0) {
        UIView *view = stack.lastObject;
        [stack removeLastObject];
        if (view.hidden || view.alpha < 0.01) continue;
        if ([view isKindOfClass:panelClass]) {
            CGRect frame = [view convertRect:view.bounds toView:nil];
            if (CGRectGetHeight(CGRectIntersection(frame, window.bounds)) > 40.0) return YES;
            continue;
        }
        [stack addObjectsFromArray:view.subviews];
    }
    return NO;
}

static void WolFoxShortsTimeChanged(NSNotification *notification) {
    id player = notification.object;
    id shorts = WolFoxFindShortsController(player);
    if (shorts == nil) {
        return;
    }
    static CFTimeInterval lastLookup = 0.0;
    if (WolFoxLatestShortsPlayerResponse == nil ||
        CACurrentMediaTime() - lastLookup > 1.0) {
        lastLookup = CACurrentMediaTime();
        id response = WolFoxShortsPlayerResponseFromObject(player) ?:
            WolFoxShortsPlayerResponseFromObject(shorts);
        if (response != nil) {
            WolFoxLatestShortsPlayerResponse = response;
        }
    }
    double time = [notification.userInfo[@"time"] doubleValue];
    double duration = WolFoxShortsDouble(player, @[
        @"currentVideoTotalMediaTime",
        @"currentVideoTotalTime",
        @"currentVideoDuration",
        @"totalMediaTime"
    ]);
    WolFoxLastShortsTime = time;
    WolFoxLastShortsDuration = duration;
    WolFoxUpdateShortsProgress();

    if (WolFoxShortsLimitReached()) {
        return;
    }
    if (!WolFoxFeatureEnabled(@"autoSkipShorts") && WolFoxFeatureEnabled(@"YTKACE.Preference.Shorts.LoopDisabled") &&
        duration > 1.0) {
        if (time < duration * 0.5) {
            objc_setAssociatedObject(shorts, WolFoxShortsLoopAssociation, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        } else if (time >= duration - 0.3 &&
                   ![objc_getAssociatedObject(shorts, WolFoxShortsLoopAssociation) boolValue]) {
            objc_setAssociatedObject(shorts, WolFoxShortsLoopAssociation, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            SEL pause = NSSelectorFromString(@"pause");
            if ([player respondsToSelector:pause]) ((void (*)(id, SEL))objc_msgSend)(player, pause);
        }
        return;
    }
    if (!WolFoxFeatureEnabled(@"autoSkipShorts") || duration <= 1.0) {
        return;
    }
    const double previous =
        [objc_getAssociatedObject(shorts, WolFoxShortsLastTimeAssociation) doubleValue];
    objc_setAssociatedObject(shorts, WolFoxShortsLastTimeAssociation, @(time),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    // Wait for the real end: either the last frames, or the jump back to the
    // start when the Short loops.
    const BOOL ended = time >= duration - 0.08 ||
        (previous >= duration - 1.0 && time < 1.0);
    if (!ended) {
        if (time < duration * 0.5 && time >= 1.0) {
            objc_setAssociatedObject(shorts, WolFoxShortsSkipAssociation, nil,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        return;
    }
    if ([objc_getAssociatedObject(shorts, WolFoxShortsSkipAssociation) boolValue]) {
        return;
    }
    // Hold off while comments are open; the next loop end tries again.
    if (WolFoxShortsPanelOpen(shorts)) return;
    objc_setAssociatedObject(shorts, WolFoxShortsSkipAssociation, @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    id delayValue = WolFoxPreferenceObject(@"YTKACE.Preference.Shorts.AutoScrollDelay");
    const double delay = [delayValue respondsToSelector:@selector(doubleValue)]
        ? MAX(0.0, MIN([delayValue doubleValue], 5.0)) : 0.0;
    if (delay <= 0.0) {
        if (!WolFoxAdvanceShort(shorts, player)) {
            objc_setAssociatedObject(shorts, WolFoxShortsSkipAssociation, nil,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        return;
    }
    __weak id weakShorts = shorts;
    __weak id weakPlayer = player;
    SEL videoGetter = NSSelectorFromString(@"currentVideoID");
    id videoID = [player respondsToSelector:videoGetter]
        ? ((id (*)(id, SEL))objc_msgSend)(player, videoGetter) : nil;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        id strongShorts = weakShorts;
        id strongPlayer = weakPlayer;
        if (strongShorts == nil || strongPlayer == nil ||
            !WolFoxFeatureEnabled(@"autoSkipShorts")) {
            return;
        }
        // Skip if the user already moved to another Short.
        id nowID = [strongPlayer respondsToSelector:videoGetter]
            ? ((id (*)(id, SEL))objc_msgSend)(strongPlayer, videoGetter) : nil;
        if (videoID != nil && ![videoID isEqual:nowID]) return;
        if (WolFoxShortsPanelOpen(strongShorts)) {
            objc_setAssociatedObject(strongShorts, WolFoxShortsSkipAssociation, nil,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            return;
        }
        if (!WolFoxAdvanceShort(strongShorts, strongPlayer)) {
            objc_setAssociatedObject(strongShorts, WolFoxShortsSkipAssociation, nil,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    });
}

void WolFoxInstallShortsHooks(void) {
    if (WolFoxReelViews == nil) {
        WolFoxReelViews = [NSHashTable weakObjectsHashTable];
        WolFoxShortsOriginals = [NSMutableDictionary dictionary];
        WolFoxShortsInstalledHooks = [NSMutableSet set];
        [NSNotificationCenter.defaultCenter
            addObserverForName:@"WolFoxPlaybackTimeDidChange"
            object:nil
            queue:NSOperationQueue.mainQueue
            usingBlock:^(NSNotification *notification) {
                WolFoxShortsTimeChanged(notification);
            }];
    }
    for (NSString *className in @[
        @"YTReelContentView",
        @"YTReelPlayerView",
        @"YTShortsPlayerView",
        @"YTShortsPlayerViewControllerView",
        @"YTShortsPlayerViewSwift"
    ]) {
        WolFoxInstallShortsLayout(className, (IMP)WolFoxReelLayout);
    }
    WolFoxInstallInstanceHook(@"YTReelElementAsyncComponentView", @"layoutSubviews",
                              (IMP)WolFoxReelElementLayout, &OriginalReelElementLayout);
    WolFoxInstallShortsLayout(@"YTReelWatchPlaybackOverlayView",
                              (IMP)WolFoxReelOverlayLayout);
    for (NSString *className in @[
        @"YTAppReelWatchRootViewController",
        @"YTReelWatchRootViewController",
        @"YTReelContainerViewController",
        @"YTReelPlaybackViewController",
        @"YTReelPlayerViewController",
        @"YTShortsPlayerViewController"
    ]) {
        WolFoxInstallShortsController(className);
    }
    for (NSString *className in @[
        @"YTReelPausedStateCarouselView",
        @"YTReelPlayerPausedStateView"
    ]) {
        WolFoxInstallShortsLayout(className, (IMP)WolFoxPausedLayout);
    }
    for (NSString *className in @[
        @"YTReelInteractiveStickerView",
        @"YTShortsStickersView",
        @"YTShortsStickersViewSwift"
    ]) {
        WolFoxInstallShortsLayout(className,
                                  (IMP)WolFoxInteractiveStickerLayout);
    }
}
