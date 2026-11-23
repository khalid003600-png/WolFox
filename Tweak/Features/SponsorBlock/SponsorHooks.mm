#import "SponsorClient.h"
#import "SponsorPreferences.h"
#import "../../WolFox.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"
#import "../../UI/Notice.h"
#import "../../Runtime/Localization.h"
#import "../Downloads/DownloadLog.h"
#import "../../UI/Assets.h"
#import "../Interface/AiSList.h"

#import <QuartzCore/QuartzCore.h>
#import <AudioToolbox/AudioToolbox.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <math.h>

static IMP OriginalDidActivateVideo;
static IMP OriginalSingleVideoTimeChanged;
static IMP OriginalMutatedVideoTimeChanged;
static IMP OriginalPlayerBarLayout;
static IMP OriginalMiniplayerBarLayout;

static const void *WolFoxSponsorSegmentsAssociation = &WolFoxSponsorSegmentsAssociation;
static const void *WolFoxSponsorVideoAssociation = &WolFoxSponsorVideoAssociation;
static const void *WolFoxSponsorSkippedAssociation = &WolFoxSponsorSkippedAssociation;
static const void *WolFoxSponsorMarkerAssociation = &WolFoxSponsorMarkerAssociation;
static const void *WolFoxSponsorRenderedSegmentsAssociation = &WolFoxSponsorRenderedSegmentsAssociation;
static const void *WolFoxSponsorMarkerBoundsAssociation = &WolFoxSponsorMarkerBoundsAssociation;
static const void *WolFoxSponsorMarkerDurationAssociation = &WolFoxSponsorMarkerDurationAssociation;
static __weak id WolFoxCurrentSponsorController;
static const void *WolFoxSponsorWhitelistedAssociation = &WolFoxSponsorWhitelistedAssociation;
static const void *WolFoxSponsorHandleAssociation = &WolFoxSponsorHandleAssociation;
static NSString * const WolFoxSponsorWhitelistKey = @"YTKACE.Preference.SponsorBlock.Whitelist";
static NSHashTable<UIView *> *WolFoxSponsorBars;
static BOOL WolFoxSponsorTimeUpdatesEnabled;
static BOOL WolFoxPlaybackTimeNotificationsNeeded;
static id WolFoxPlaybackPreferenceObserver;

static void WolFoxRefreshPlaybackTimePreferenceState(void) {
    WolFoxSponsorTimeUpdatesEnabled =
        WolFoxFeatureEnabled(WolFoxSponsorBlockKey);
    WolFoxPlaybackTimeNotificationsNeeded =
        WolFoxFeatureEnabled(@"shortsProgress") ||
        WolFoxFeatureEnabled(@"autoSkipShorts") ||
        WolFoxFeatureEnabled(WolFoxSpeedKey) ||
        WolFoxFeatureEnabled(WolFoxSleepTimerKey) ||
        WolFoxFeatureEnabled(@"YTKACE.Preference.Playback.LocalQueue") ||
        WolFoxFeatureEnabled(@"YTKACE.Preference.Player.ExitFullscreenAtEnd");
}

static void WolFoxPublishPlaybackTime(id receiver, double time) {
    if (!WolFoxPlaybackTimeNotificationsNeeded) return;
    [NSNotificationCenter.defaultCenter
        postNotificationName:@"WolFoxPlaybackTimeDidChange"
        object:receiver
        userInfo:@{@"time": @(time)}];
}

static id WolFoxObjectMessage(id receiver, NSString *selectorName) {
    SEL selector = NSSelectorFromString(selectorName);
    if (receiver == nil || ![receiver respondsToSelector:selector]) {
        return nil;
    }
    return ((id (*)(id, SEL))objc_msgSend)(receiver, selector);
}

static double WolFoxDoubleMessage(id receiver, NSArray<NSString *> *selectorNames) {
    for (NSString *selectorName in selectorNames) {
        SEL selector = NSSelectorFromString(selectorName);
        if ([receiver respondsToSelector:selector]) {
            return ((double (*)(id, SEL))objc_msgSend)(receiver, selector);
        }
    }
    return 0.0;
}

static NSString *WolFoxVideoIDFromObject(id object) {
    if ([object isKindOfClass:NSString.class]) {
        return object;
    }
    for (NSString *selector in @[@"videoID", @"videoId", @"currentVideoID", @"identifier"]) {
        id value = WolFoxObjectMessage(object, selector);
        if ([value isKindOfClass:NSString.class] && [value length] != 0) {
            return value;
        }
    }
    id details = WolFoxObjectMessage(object, @"videoDetails");
    if (details != nil && details != object) {
        return WolFoxVideoIDFromObject(details);
    }
    return nil;
}

static BOOL WolFoxSponsorFeedbackEnabled(void) {
    return WolFoxFeatureEnabled(@"YTKACE.Preference.SponsorBlock.AudioFeedback");
}

static NSString *WolFoxSponsorCategoryTitle(NSString *category) {
    for (NSDictionary *definition in WolFoxSponsorCategoryDefinitions()) {
        if ([definition[@"id"] isEqualToString:category]) return definition[@"title"];
    }
    return WolFoxLocalized(@"Sponsor");
}

static UIViewController *WolFoxTopController(void) {
    UIWindow *window = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class] ||
            scene.activationState != UISceneActivationStateForegroundActive) {
            continue;
        }
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
    if ([controller isKindOfClass:UINavigationController.class]) {
        controller = ((UINavigationController *)controller).visibleViewController;
    } else if ([controller isKindOfClass:UITabBarController.class]) {
        controller = ((UITabBarController *)controller).selectedViewController;
    }
    return controller;
}

static void WolFoxSeekToTime(id controller, double time) {
    SEL selector = NSSelectorFromString(@"seekToTime:");
    if ([controller respondsToSelector:selector]) {
        ((void (*)(id, SEL, double))objc_msgSend)(controller, selector, time);
    }
}

static UIVisualEffectView *WolFoxSponsorBannerGlass(UIView *banner) {
    for (UIView *subview in banner.subviews) {
        if ([subview isKindOfClass:UIVisualEffectView.class]) return (UIVisualEffectView *)subview;
    }
    return nil;
}

static const void *WolFoxSponsorBannerExpired = &WolFoxSponsorBannerExpired;

static void WolFoxFadeOutSponsorBanner(UIView *banner) {
    if (banner == nil || banner.superview == nil) return;
    for (UIGestureRecognizer *gesture in banner.gestureRecognizers) {
        if (gesture.state == UIGestureRecognizerStateBegan || gesture.state == UIGestureRecognizerStateChanged) {
            objc_setAssociatedObject(banner, WolFoxSponsorBannerExpired, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            return;
        }
    }
    UIVisualEffectView *glass = WolFoxSponsorBannerGlass(banner);
    [UIView animateWithDuration:0.25 delay:0.0
                        options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionCurveEaseIn
                     animations:^{
        banner.alpha = 0.0;
        banner.transform = CGAffineTransformScale(banner.transform, 0.96, 0.96);
        glass.effect = nil;
    } completion:^(__unused BOOL finished) {
        [banner removeFromSuperview];
    }];
}

static void WolFoxFadeInSponsorBanner(UIView *banner) {
    UIVisualEffectView *glass = WolFoxSponsorBannerGlass(banner);
    UIVisualEffect *effect = glass.effect;
    [banner.superview layoutIfNeeded];
    banner.alpha = 0.0;
    banner.transform = CGAffineTransformMakeScale(0.96, 0.96);
    glass.effect = nil;
    dispatch_async(dispatch_get_main_queue(), ^{
        [UIView animateWithDuration:0.3 delay:0.0
                            options:UIViewAnimationOptionCurveEaseOut | UIViewAnimationOptionAllowUserInteraction
                         animations:^{
            banner.alpha = 1.0;
            banner.transform = CGAffineTransformIdentity;
            glass.effect = effect;
        } completion:nil];
    });
}

@interface WolFoxSponsorBannerSwipe : NSObject
+ (instancetype)shared;
- (void)panned:(UIPanGestureRecognizer *)pan;
@end

@implementation WolFoxSponsorBannerSwipe
+ (instancetype)shared {
    static WolFoxSponsorBannerSwipe *shared;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ shared = [WolFoxSponsorBannerSwipe new]; });
    return shared;
}
- (void)panned:(UIPanGestureRecognizer *)pan {
    UIView *banner = pan.view;
    CGPoint move = [pan translationInView:banner.superview];
    CGFloat dx = move.x;
    CGFloat dy = MAX(move.y, 0.0);
    if (pan.state == UIGestureRecognizerStateBegan || pan.state == UIGestureRecognizerStateChanged) {
        CGFloat distance = MAX(fabs(dx), dy);
        banner.transform = CGAffineTransformMakeTranslation(dx, dy);
        banner.alpha = MAX(0.2, 1.0 - distance / 160.0);
        return;
    }
    if (pan.state != UIGestureRecognizerStateEnded && pan.state != UIGestureRecognizerStateCancelled) return;
    CGPoint velocity = [pan velocityInView:banner.superview];
    BOOL sideways = fabs(dx) > 70.0 || fabs(velocity.x) > 600.0;
    BOOL down = dy > 30.0 || velocity.y > 400.0;
    if (pan.state == UIGestureRecognizerStateEnded && (sideways || down)) {
        CGAffineTransform away = sideways
            ? CGAffineTransformMakeTranslation((dx < 0 ? -1.0 : 1.0) * banner.superview.bounds.size.width, dy)
            : CGAffineTransformMakeTranslation(dx, dy + 120.0);
        banner.userInteractionEnabled = NO;
        [UIView animateWithDuration:0.22 delay:0.0 options:UIViewAnimationOptionCurveEaseOut animations:^{
            banner.transform = away;
            banner.alpha = 0.0;
        } completion:^(__unused BOOL finished) {
            [banner removeFromSuperview];
        }];
        return;
    }
    if ([objc_getAssociatedObject(banner, WolFoxSponsorBannerExpired) boolValue]) {
        WolFoxFadeOutSponsorBanner(banner);
        return;
    }
    [UIView animateWithDuration:0.35 delay:0.0 usingSpringWithDamping:0.75 initialSpringVelocity:0.0
                        options:UIViewAnimationOptionAllowUserInteraction animations:^{
        banner.transform = CGAffineTransformIdentity;
        banner.alpha = 1.0;
    } completion:nil];
}
@end

static void WolFoxAddSponsorBannerSwipe(UIView *banner) {
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc]
        initWithTarget:WolFoxSponsorBannerSwipe.shared action:@selector(panned:)];
    pan.cancelsTouchesInView = YES;
    [banner addGestureRecognizer:pan];
}

@interface WolFoxSponsorUndoTarget : NSObject
+ (instancetype)sharedTarget;
@property(nonatomic, weak) id controller;
@property(nonatomic, assign) double startTime;
@property(nonatomic, weak) UIView *banner;
- (void)unskip;
@end

@implementation WolFoxSponsorUndoTarget
+ (instancetype)sharedTarget {
    static WolFoxSponsorUndoTarget *target;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ target = [WolFoxSponsorUndoTarget new]; });
    return target;
}
- (void)unskip {
    id controller = self.controller;
    if (controller != nil) {
        WolFoxSeekToTime(controller, self.startTime);
    }
    WolFoxFadeOutSponsorBanner(self.banner);
}
@end

static void WolFoxShowSponsorSkippedHUD(id controller, double start, NSString *category) {
    NSInteger notificationMode = WolFoxSponsorNotificationMode();
    if (notificationMode == 2) {
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *presenter = WolFoxTopController();
        if (presenter.view.window == nil) {
            return;
        }
        WolFoxSponsorUndoTarget *target = WolFoxSponsorUndoTarget.sharedTarget;
        WolFoxFadeOutSponsorBanner(target.banner);
        UIView *banner = [UIView new];
        banner.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.94];
        banner.layer.cornerRadius = 12.0;
        banner.translatesAutoresizingMaskIntoConstraints = NO;
        UILabel *label = [UILabel new];
        label.text = [NSString stringWithFormat:@"%@ %@",
                      WolFoxSponsorCategoryTitle(category),
                      WolFoxLocalized(@"segment skipped")];
        label.textColor = UIColor.whiteColor;
        label.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightSemibold];
        UIButton *undo = [UIButton buttonWithType:UIButtonTypeSystem];
        [undo setTitle:WolFoxLocalized(@"Unskip") forState:UIControlStateNormal];
        [undo setTitleColor:WolFoxAccentColor() forState:UIControlStateNormal];
        undo.titleLabel.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightSemibold];
        [undo addTarget:target action:@selector(unskip)
            forControlEvents:UIControlEventTouchUpInside];
        NSArray *views = notificationMode == 0 ? @[label, undo] : @[label];
        UIStackView *content = [[UIStackView alloc] initWithArrangedSubviews:views];
        content.axis = UILayoutConstraintAxisHorizontal;
        content.alignment = UIStackViewAlignmentCenter;
        content.spacing = 18.0;
        content.translatesAutoresizingMaskIntoConstraints = NO;
        [banner addSubview:content];
        WolFoxApplyGlassBackground(banner, YES);
        [presenter.view addSubview:banner];
        UILayoutGuide *safe = presenter.view.safeAreaLayoutGuide;
        [NSLayoutConstraint activateConstraints:@[
            [banner.centerXAnchor constraintEqualToAnchor:safe.centerXAnchor],
            [banner.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-54.0],
            [banner.widthAnchor constraintLessThanOrEqualToAnchor:safe.widthAnchor constant:-28.0],
            [content.topAnchor constraintEqualToAnchor:banner.topAnchor constant:11.0],
            [content.leadingAnchor constraintEqualToAnchor:banner.leadingAnchor constant:16.0],
            [content.trailingAnchor constraintEqualToAnchor:banner.trailingAnchor constant:-12.0],
            [content.bottomAnchor constraintEqualToAnchor:banner.bottomAnchor constant:-11.0]
        ]];
        target.controller = controller;
        target.startTime = start;
        target.banner = banner;
        WolFoxAddSponsorBannerSwipe(banner);
        WolFoxFadeInSponsorBanner(banner);
        NSTimeInterval duration = notificationMode == 0
            ? WolFoxSponsorUnskipAlertDuration()
            : WolFoxSponsorSkipAlertDuration();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
            (int64_t)(duration * NSEC_PER_SEC)),
            dispatch_get_main_queue(), ^{
                if (target.banner == banner) {
                    WolFoxFadeOutSponsorBanner(banner);
                }
            });
    });
}

static void WolFoxPerformSponsorSkip(id controller, double start, double end,
                                     NSString *category) {
    WolFoxSeekToTime(controller, end);
    WolFoxShowSponsorSkippedHUD(controller, start, category);
    if (WolFoxSponsorFeedbackEnabled()) {
        AudioServicesPlaySystemSound(1057);
        UINotificationFeedbackGenerator *feedback =
            [UINotificationFeedbackGenerator new];
        [feedback notificationOccurred:UINotificationFeedbackTypeSuccess];
    }
}

@interface WolFoxSponsorSkipTarget : NSObject
+ (instancetype)sharedTarget;
@property(nonatomic, weak) id controller;
@property(nonatomic, assign) double startTime;
@property(nonatomic, assign) double endTime;
@property(nonatomic, copy) NSString *category;
@property(nonatomic, weak) UIView *banner;
- (void)skip;
@end

@implementation WolFoxSponsorSkipTarget
+ (instancetype)sharedTarget {
    static WolFoxSponsorSkipTarget *target;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ target = [WolFoxSponsorSkipTarget new]; });
    return target;
}
- (void)skip {
    id controller = self.controller;
    [self.banner removeFromSuperview];
    if (controller != nil) {
        WolFoxPerformSponsorSkip(controller, self.startTime, self.endTime, self.category);
    }
}
@end

static void WolFoxAskToSkipSponsor(id controller, double start, double end,
                                   NSString *category) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *presenter = WolFoxTopController();
        if (presenter.view.window == nil) {
            return;
        }
        WolFoxSponsorSkipTarget *target = WolFoxSponsorSkipTarget.sharedTarget;
        WolFoxFadeOutSponsorBanner(target.banner);
        UIView *banner = [UIView new];
        banner.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.94];
        banner.layer.cornerRadius = 12.0;
        banner.translatesAutoresizingMaskIntoConstraints = NO;
        UILabel *label = [UILabel new];
        label.text = [NSString stringWithFormat:@"%@ segment detected",
                      WolFoxSponsorCategoryTitle(category)];
        label.textColor = UIColor.whiteColor;
        label.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightSemibold];
        UIButton *skip = [UIButton buttonWithType:UIButtonTypeSystem];
        [skip setTitle:WolFoxLocalized(@"Skip") forState:UIControlStateNormal];
        [skip setTitleColor:WolFoxAccentColor() forState:UIControlStateNormal];
        skip.titleLabel.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightSemibold];
        [skip addTarget:target action:@selector(skip)
            forControlEvents:UIControlEventTouchUpInside];
        UIStackView *content = [[UIStackView alloc] initWithArrangedSubviews:@[
            label, skip
        ]];
        content.axis = UILayoutConstraintAxisHorizontal;
        content.alignment = UIStackViewAlignmentCenter;
        content.spacing = 18.0;
        content.translatesAutoresizingMaskIntoConstraints = NO;
        [banner addSubview:content];
        WolFoxApplyGlassBackground(banner, YES);
        [presenter.view addSubview:banner];
        UILayoutGuide *safe = presenter.view.safeAreaLayoutGuide;
        [NSLayoutConstraint activateConstraints:@[
            [banner.centerXAnchor constraintEqualToAnchor:safe.centerXAnchor],
            [banner.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-54.0],
            [banner.widthAnchor constraintLessThanOrEqualToAnchor:safe.widthAnchor constant:-28.0],
            [content.topAnchor constraintEqualToAnchor:banner.topAnchor constant:11.0],
            [content.leadingAnchor constraintEqualToAnchor:banner.leadingAnchor constant:16.0],
            [content.trailingAnchor constraintEqualToAnchor:banner.trailingAnchor constant:-12.0],
            [content.bottomAnchor constraintEqualToAnchor:banner.bottomAnchor constant:-11.0]
        ]];
        target.controller = controller;
        target.startTime = start;
        target.endTime = end;
        target.category = category;
        target.banner = banner;
        WolFoxAddSponsorBannerSwipe(banner);
        WolFoxFadeInSponsorBanner(banner);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
            (int64_t)(WolFoxSponsorSkipAlertDuration() * NSEC_PER_SEC)),
            dispatch_get_main_queue(), ^{
                if (target.banner == banner) {
                    WolFoxFadeOutSponsorBanner(banner);
                }
            });
    });
}

static void WolFoxEvaluateSponsorTime(id controller, double time) {
    if (!WolFoxSponsorBlockEnabled()) {
        return;
    }
    if ([objc_getAssociatedObject(controller, WolFoxSponsorWhitelistedAssociation) boolValue]) {
        return;
    }

    NSArray<NSDictionary<NSString *, id> *> *segments =
        objc_getAssociatedObject(controller, WolFoxSponsorSegmentsAssociation);
    NSMutableSet<NSNumber *> *skipped =
        objc_getAssociatedObject(controller, WolFoxSponsorSkippedAssociation);
    if (skipped == nil) {
        skipped = [NSMutableSet set];
        objc_setAssociatedObject(controller,
                                 WolFoxSponsorSkippedAssociation,
                                 skipped,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    const double minimum = WolFoxSponsorMinimumSegmentLength();
    [segments enumerateObjectsUsingBlock:
        ^(NSDictionary<NSString *, id> *segment, NSUInteger index, BOOL *stop) {
            double start = [segment[@"start"] doubleValue];
            double end = [segment[@"end"] doubleValue];
            NSString *category = [segment[@"category"] isKindOfClass:NSString.class]
                ? segment[@"category"] : @"sponsor";
            NSInteger behavior = WolFoxSponsorCategoryBehavior(category);
            if (behavior == 2 || behavior == 3) return;
            // Segments shorter than the minimum just play.
            if (end - start < minimum) return;
            NSNumber *token = @(index);
            if (time < start - 1.0) {
                [skipped removeObject:token];
            }
            if (time >= start && time < end - 0.25 && ![skipped containsObject:token]) {
                [skipped addObject:token];
                if (behavior == 1) {
                    WolFoxAskToSkipSponsor(controller, start, end, category);
                } else {
                    WolFoxPerformSponsorSkip(controller, start, end, category);
                }
                *stop = YES;
            }
        }];
}

static __weak id WolFoxLastPlayerController;

id WolFoxSponsorActiveController(void) {
    return WolFoxLastPlayerController;
}

NSString *WolFoxSponsorActiveVideoID(void) {
    return objc_getAssociatedObject(WolFoxLastPlayerController, WolFoxSponsorVideoAssociation);
}

NSArray *WolFoxSponsorActiveSegments(void) {
    id segments = objc_getAssociatedObject(WolFoxLastPlayerController, WolFoxSponsorSegmentsAssociation);
    return [segments isKindOfClass:NSArray.class] ? segments : @[];
}

double WolFoxSponsorActiveTime(void) {
    return WolFoxDoubleMessage(WolFoxLastPlayerController, @[@"currentVideoMediaTime"]);
}

double WolFoxSponsorActiveDuration(void) {
    return WolFoxDoubleMessage(WolFoxLastPlayerController, @[@"currentVideoTotalMediaTime",
                                                            @"currentVideoDuration", @"totalMediaTime"]);
}

void WolFoxSponsorSeekActive(double time) {
    WolFoxSeekToTime(WolFoxLastPlayerController, time);
}

NSString *WolFoxSponsorActiveHandle(void) {
    return objc_getAssociatedObject(WolFoxLastPlayerController, WolFoxSponsorHandleAssociation);
}

void WolFoxSponsorSetActiveHandle(NSString *handle) {
    id controller = WolFoxLastPlayerController;
    if (controller == nil || handle.length == 0) return;
    objc_setAssociatedObject(controller, WolFoxSponsorHandleAssociation, handle, OBJC_ASSOCIATION_COPY_NONATOMIC);
    NSArray *whitelist = [NSUserDefaults.standardUserDefaults arrayForKey:WolFoxSponsorWhitelistKey];
    objc_setAssociatedObject(controller, WolFoxSponsorWhitelistedAssociation,
                             @([whitelist containsObject:handle.lowercaseString]), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

void WolFoxPauseYouTubePlayer(void) {
    id controller = WolFoxLastPlayerController;
    SEL pause = NSSelectorFromString(@"pause");
    if ([controller respondsToSelector:pause]) {
        ((void (*)(id, SEL))objc_msgSend)(controller, pause);
    }
}

static void WolFoxDidActivateVideo(id receiver,
                                   SEL selector,
                                   id playbackController,
                                   id video,
                                   id playbackData) {
    if (OriginalDidActivateVideo != NULL) {
        ((void (*)(id, SEL, id, id, id))OriginalDidActivateVideo)(
            receiver, selector, playbackController, video, playbackData
        );
    }

    WolFoxOpenPausedVideoActivated(receiver);
    WolFoxFullscreenVideoActivated(receiver);
    WolFoxLastPlayerController = receiver;

    if (!WolFoxSponsorBlockEnabled()) {
        objc_setAssociatedObject(receiver,
                                 WolFoxSponsorSegmentsAssociation,
                                 nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }

    NSString *videoID =
        WolFoxVideoIDFromObject(receiver) ?:
        WolFoxVideoIDFromObject(video) ?:
        WolFoxVideoIDFromObject(playbackData);
    if (videoID.length == 0) {
        return;
    }

    objc_setAssociatedObject(receiver,
                             WolFoxSponsorVideoAssociation,
                             videoID,
                             OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(receiver,
                             WolFoxSponsorSegmentsAssociation,
                             @[],
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(receiver,
                             WolFoxSponsorSkippedAssociation,
                             [NSMutableSet set],
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    WolFoxCurrentSponsorController = receiver;
    objc_setAssociatedObject(receiver, WolFoxSponsorWhitelistedAssociation, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(receiver, WolFoxSponsorHandleAssociation, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
    NSArray *whitelist = [NSUserDefaults.standardUserDefaults arrayForKey:WolFoxSponsorWhitelistKey];
    if (whitelist.count != 0) {
        __weak id weakController = receiver;
        WolFoxLookupChannelHandle(videoID, ^(NSString *handle, __unused NSString *channel, __unused NSString *title) {
            id strongController = weakController;
            NSString *current = objc_getAssociatedObject(strongController, WolFoxSponsorVideoAssociation);
            if (strongController == nil || ![current isEqualToString:videoID] || handle.length == 0) return;
            objc_setAssociatedObject(strongController, WolFoxSponsorHandleAssociation, handle,
                                     OBJC_ASSOCIATION_COPY_NONATOMIC);
            BOOL listed = [whitelist containsObject:handle.lowercaseString];
            objc_setAssociatedObject(strongController, WolFoxSponsorWhitelistedAssociation, @(listed),
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            WolFoxDebugLog(@"sponsor", @"whitelist check %@ listed=%d", handle, listed);
        });
    }

    __weak id weakReceiver = receiver;
    [WolFoxSponsorClient.sharedClient segmentsForVideoID:videoID
                                             completion:^(NSArray *segments) {
        id strongReceiver = weakReceiver;
        NSString *current =
            objc_getAssociatedObject(strongReceiver, WolFoxSponsorVideoAssociation);
        if (strongReceiver == nil || ![current isEqualToString:videoID]) {
            return;
        }
        objc_setAssociatedObject(strongReceiver,
                                 WolFoxSponsorSegmentsAssociation,
                                 segments,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        for (UIView *bar in WolFoxSponsorBars.allObjects) {
            [bar setNeedsLayout];
            [bar layoutIfNeeded];
        }
    }];
}

static void WolFoxSingleVideoTimeChanged(id receiver,
                                         SEL selector,
                                         id video,
                                         double time) {
    if (OriginalSingleVideoTimeChanged != NULL) {
        ((void (*)(id, SEL, id, double))OriginalSingleVideoTimeChanged)(
            receiver, selector, video, time
        );
    }
    double current = WolFoxDoubleMessage(receiver, @[@"currentVideoMediaTime"]);
    double resolved = current > 0.0 ? current : time;
    if (WolFoxSponsorTimeUpdatesEnabled) {
        WolFoxEvaluateSponsorTime(receiver, resolved);
    }
    WolFoxPublishPlaybackTime(receiver, resolved);
}

static void WolFoxMutatedVideoTimeChanged(id receiver,
                                          SEL selector,
                                          id video,
                                          double time) {
    if (OriginalMutatedVideoTimeChanged != NULL) {
        ((void (*)(id, SEL, id, double))OriginalMutatedVideoTimeChanged)(
            receiver, selector, video, time
        );
    }
    double current = WolFoxDoubleMessage(receiver, @[@"currentVideoMediaTime"]);
    double resolved = current > 0.0 ? current : time;
    if (WolFoxSponsorTimeUpdatesEnabled) {
        WolFoxEvaluateSponsorTime(receiver, resolved);
    }
    WolFoxPublishPlaybackTime(receiver, resolved);
}

static BOOL WolFoxTrackGeometry(UIView *target, CGFloat *thickness,
                                CGFloat *offset) {
    CGFloat width = CGRectGetWidth(target.bounds);
    if (width <= 0.0) return NO;
    CGFloat bestWidth = 0.0;
    CGFloat bestHeight = 0.0;
    CGFloat bestY = 0.0;
    BOOL found = NO;
    NSMutableArray<UIView *> *pending = [NSMutableArray arrayWithObject:target];
    NSUInteger visited = 0;
    while (pending.count != 0 && visited < 60) {
        UIView *node = pending.firstObject;
        [pending removeObjectAtIndex:0];
        visited++;
        if (node != target && !node.hidden && node.alpha > 0.05) {
            CGRect frame = [node convertRect:node.bounds toView:target];
            CGFloat nodeWidth = CGRectGetWidth(frame);
            CGFloat nodeHeight = CGRectGetHeight(frame);
            if (nodeWidth >= width * 0.55 && nodeHeight > 0.5 && nodeHeight <= 16.0) {
                BOOL better = !found;
                if (!better && nodeWidth > bestWidth + 2.0) better = YES;
                else if (!better && nodeWidth >= bestWidth - 2.0) {
                    if (CGRectGetMinY(frame) > bestY + 0.5) better = YES;
                    else if (fabs(CGRectGetMinY(frame) - bestY) <= 0.5 &&
                             nodeHeight > bestHeight) better = YES;
                }
                if (better) {
                    bestWidth = nodeWidth;
                    bestHeight = nodeHeight;
                    bestY = CGRectGetMinY(frame);
                    found = YES;
                }
            }
        }
        [pending addObjectsFromArray:node.subviews];
    }
    if (!found) return NO;
    *thickness = bestHeight;
    *offset = bestY;
    return YES;
}

static void WolFoxRenderSponsorMarkers(UIView *receiver, UIView *target,
                                       BOOL fullHeight) {
    CAShapeLayer *container =
        objc_getAssociatedObject(receiver, WolFoxSponsorMarkerAssociation);
    if (container == nil) {
        container = [CAShapeLayer layer];
        container.name = @"WolFoxSponsorMarkers";
        objc_setAssociatedObject(receiver,
                                 WolFoxSponsorMarkerAssociation,
                                 container,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    BOOL reattached = NO;
    if (container.superlayer != target.layer) {
        [container removeFromSuperlayer];
        [target.layer addSublayer:container];
        reattached = YES;
    }
    container.frame = target.bounds;
    container.zPosition = 10000.0;

    id controller = WolFoxCurrentSponsorController;
    NSArray<NSDictionary<NSString *, id> *> *segments =
        objc_getAssociatedObject(controller, WolFoxSponsorSegmentsAssociation);
    double duration = WolFoxDoubleMessage(
        controller,
        @[@"currentVideoTotalMediaTime", @"currentVideoTotalTime",
          @"currentVideoDuration", @"totalMediaTime"]
    );
    BOOL enabled = WolFoxSponsorBlockEnabled() && duration > 0.0 && segments.count != 0;
    container.hidden = !enabled;
    if (!enabled) return;

    CGFloat width = CGRectGetWidth(target.bounds);
    CGFloat height = CGRectGetHeight(target.bounds);
    NSArray *renderedSegments = objc_getAssociatedObject(
        receiver, WolFoxSponsorRenderedSegmentsAssociation);
    BOOL rebuild = renderedSegments != segments || container.sublayers.count != segments.count;
    if (rebuild) {
        [container.sublayers makeObjectsPerformSelector:@selector(removeFromSuperlayer)];
        for (NSDictionary<NSString *, id> *segment in segments) {
            CALayer *marker = [CALayer layer];
            NSString *category = [segment[@"category"] isKindOfClass:NSString.class]
                ? segment[@"category"] : @"sponsor";
            marker.backgroundColor = WolFoxSponsorCategoryColor(category).CGColor;
            marker.zPosition = 1.0;
            [container addSublayer:marker];
        }
        objc_setAssociatedObject(receiver,
                                 WolFoxSponsorRenderedSegmentsAssociation,
                                 segments,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    CGFloat trackThickness = 2.0;
    CGFloat trackOffset = MAX(0.0, height - 2.0);
    if (!fullHeight) {
        CGFloat measured = 0.0;
        CGFloat measuredOffset = 0.0;
        if (WolFoxTrackGeometry(target, &measured, &measuredOffset)) {
            trackThickness = measured;
            trackOffset = measuredOffset;
        }
    }
    CGRect previousBounds = [objc_getAssociatedObject(
        receiver, WolFoxSponsorMarkerBoundsAssociation) CGRectValue];
    double previousDuration = [objc_getAssociatedObject(
        receiver, WolFoxSponsorMarkerDurationAssociation) doubleValue];
    CGRect signature = CGRectMake(CGRectGetWidth(target.bounds),
                                  CGRectGetHeight(target.bounds),
                                  trackThickness, trackOffset);
    if (!rebuild && !reattached && CGRectEqualToRect(previousBounds, signature) &&
        fabs(previousDuration - duration) < 0.001) return;
    objc_setAssociatedObject(receiver,
                             WolFoxSponsorMarkerBoundsAssociation,
                             [NSValue valueWithCGRect:signature],
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(receiver,
                             WolFoxSponsorMarkerDurationAssociation,
                             @(duration),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    [segments enumerateObjectsUsingBlock:
        ^(NSDictionary<NSString *, id> *segment, NSUInteger index, __unused BOOL *stop) {
        double start = [segment[@"start"] doubleValue];
        double end = MIN([segment[@"end"] doubleValue], duration);
        CALayer *marker = container.sublayers[index];
        marker.hidden = end <= start;
        if (marker.hidden) return;
        CGFloat markerHeight = fullHeight ? MAX(height, 1.0) : trackThickness;
        marker.frame = CGRectMake((CGFloat)(start / duration) * width,
                                  fullHeight ? 0.0 : trackOffset,
                                  MAX(1.0, (CGFloat)((end - start) / duration) * width),
                                  markerHeight);
    }];
    [CATransaction commit];
}

static void WolFoxPlayerBarLayout(UIView *receiver, SEL selector) {
    if (OriginalPlayerBarLayout != NULL) {
        ((void (*)(id, SEL))OriginalPlayerBarLayout)(receiver, selector);
    }

    WolFoxConfigureTapToSeek(receiver);

    [WolFoxSponsorBars addObject:receiver];
    UIView *target = receiver;
    for (UIView *subview in receiver.subviews) {
        if ([NSStringFromClass(subview.class) isEqualToString:@"YTModularPlayerBarView"]) {
            target = subview;
            break;
        }
    }
    WolFoxRenderSponsorMarkers(receiver, target, NO);
}

static void WolFoxMiniplayerBarLayout(UIView *receiver, SEL selector) {
    if (OriginalMiniplayerBarLayout != NULL) {
        ((void (*)(id, SEL))OriginalMiniplayerBarLayout)(receiver, selector);
    }
    [WolFoxSponsorBars addObject:receiver];
    WolFoxApplyProgressStyleToBar(receiver);
    WolFoxRenderSponsorMarkers(receiver, receiver, YES);
}

void WolFoxInstallSponsorBlockHooks(void) {
    if (WolFoxSponsorBars == nil) {
        WolFoxSponsorBars = [NSHashTable weakObjectsHashTable];
    }
    WolFoxRefreshPlaybackTimePreferenceState();
    if (WolFoxPlaybackPreferenceObserver == nil) {
        WolFoxPlaybackPreferenceObserver = [NSNotificationCenter.defaultCenter
            addObserverForName:WolFoxPreferencesDidChangeNotification
            object:nil
            queue:NSOperationQueue.mainQueue
            usingBlock:^(__unused NSNotification *notification) {
                WolFoxRefreshPlaybackTimePreferenceState();
            }];
    }
    WolFoxInstallInstanceHook(@"YTPlayerViewController",
                              @"playbackController:didActivateVideo:withPlaybackData:",
                              (IMP)WolFoxDidActivateVideo,
                              &OriginalDidActivateVideo);
    WolFoxInstallInstanceHook(@"YTPlayerViewController",
                              @"singleVideo:currentVideoTimeDidChange:",
                              (IMP)WolFoxSingleVideoTimeChanged,
                              &OriginalSingleVideoTimeChanged);
    WolFoxInstallInstanceHook(@"YTPlayerViewController",
                              @"potentiallyMutatedSingleVideo:currentVideoTimeDidChange:",
                              (IMP)WolFoxMutatedVideoTimeChanged,
                              &OriginalMutatedVideoTimeChanged);
    WolFoxInstallInstanceHook(@"YTInlinePlayerBarContainerView",
                              @"layoutSubviews",
                              (IMP)WolFoxPlayerBarLayout,
                              &OriginalPlayerBarLayout);
    WolFoxInstallInstanceHook(@"YTWatchFloatingMiniplayerProgressBarView",
                              @"layoutSubviews",
                              (IMP)WolFoxMiniplayerBarLayout,
                              &OriginalMiniplayerBarLayout);
}
