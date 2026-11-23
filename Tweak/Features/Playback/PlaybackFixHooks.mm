/*
 * Playback error recovery adapted from YTPlaybackFix by Mark02.
 * https://github.com/Mark02-2012/YTPlaybackFix
 *
 * Copyright (c) 2026 Mark02
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 * SOFTWARE.
 */

#import "../../WolFox.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"
#import "../Downloads/DownloadLog.h"
#import "../../Runtime/Localization.h"
#import <UIKit/UIKit.h>

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

static NSString *const WolFoxPlaybackFixKey = @"YTKACE.Preference.Playback.Fix";
static const NSTimeInterval WolFoxStallGrace = 0.8;
static const double WolFoxProgressEpsilon = 0.15;

static NSString *const WolFoxPlaybackErrorDomain =
    @"com.google.ios.youtube.ErrorDomain.playback";

static double gLatestTime = 0.0;
static BOOL gIsTimeToRetry = NO;
static bool gEmergencyCheckRunning = false;

static IMP OriginalCurrentVideoMediaTime;
static IMP OriginalSeekToTime;
static IMP OriginalHandleError;

NSInteger WolFoxPlaybackFixMode(void) {
    if (!WolFoxMasterEnabled()) return 0;
    id stored = WolFoxPreferenceObject(@"YTKACE.Preference.Playback.FixMode");
    if ([stored respondsToSelector:@selector(integerValue)]) {
        const NSInteger mode = [stored integerValue];
        return mode >= 0 && mode <= 2 ? mode : 0;
    }
    if (WolFoxFeatureEnabled(@"YTKACE.Preference.Playback.HLSMode")) return 2;
    return WolFoxFeatureEnabled(WolFoxPlaybackFixKey) ? 1 : 0;
}

static BOOL WolFoxPlaybackFixEnabled(void) {
    return WolFoxPlaybackFixMode() == 1;
}

static id WolFoxParentResponder(id overlay) {
    SEL responderGetter = NSSelectorFromString(@"parentResponder");
    if (![overlay respondsToSelector:responderGetter]) {
        WolFoxDownloadLog(@"fix", @"parentResponder unavailable");
        return nil;
    }
    return ((id (*)(id, SEL))objc_msgSend)(overlay, responderGetter);
}

static void WolFoxSendRetryEvent(id overlay, NSString *stage) {
    id responder = WolFoxParentResponder(overlay);
    if (responder == nil) {
        WolFoxDownloadLog(@"fix", @"%@ no responder", stage);
        return;
    }
    Class eventClass = NSClassFromString(@"YTPlayerTapToRetryResponderEvent");
    SEL factory = NSSelectorFromString(@"eventWithFirstResponder:");
    if (eventClass == Nil || ![eventClass respondsToSelector:factory]) {
        WolFoxDownloadLog(@"fix", @"%@ event class missing", stage);
        return;
    }
    id event = ((id (*)(Class, SEL, id))objc_msgSend)(eventClass, factory,
                                                      responder);
    SEL send = NSSelectorFromString(@"send");
    if (event == nil || ![event respondsToSelector:send]) {
        WolFoxDownloadLog(@"fix", @"%@ event not created", stage);
        return;
    }
    ((void (*)(id, SEL))objc_msgSend)(event, send);
    WolFoxDownloadLog(@"fix", @"%@ retry event sent to %@", stage,
                      NSStringFromClass([responder class]));
}

static BOOL WolFoxReloadPlayer(id pvc, NSString *stage) {
    SEL activeGetter = NSSelectorFromString(@"activeVideo");
    if (pvc == nil || ![pvc respondsToSelector:activeGetter]) return NO;
    id video = ((id (*)(id, SEL))objc_msgSend)(pvc, activeGetter);
    SEL reloadSel = NSSelectorFromString(@"player:reloadWithContext:");
    SEL mediaGetter = NSSelectorFromString(@"mediaPlayer");
    Class contextClass = NSClassFromString(@"MLPlayerReloadContext");
    SEL contextInit = NSSelectorFromString(
        @"initWithStartPlayback:refreshStreamingData:");
    if (video == nil || contextClass == Nil ||
        ![video respondsToSelector:reloadSel] ||
        ![video respondsToSelector:mediaGetter]) {
        WolFoxDownloadLog(@"fix", @"%@ player reload unavailable on %@", stage,
                          video == nil ? @"nil" : NSStringFromClass([video class]));
        WolFoxDebugLog(@"fix", @"%@ reload pvc=%@ video=%@ reload=%d media=%d context=%d", stage,
                       NSStringFromClass([pvc class]), video ? NSStringFromClass([video class]) : @"nil",
                       [video respondsToSelector:reloadSel], [video respondsToSelector:mediaGetter],
                       contextClass != Nil);
        return NO;
    }
    id allocated = [contextClass alloc];
    if (![allocated respondsToSelector:contextInit]) return NO;
    id context = ((id (*)(id, SEL, BOOL, BOOL))objc_msgSend)(
        allocated, contextInit, YES, YES);
    if (context == nil) return NO;
    id media = ((id (*)(id, SEL))objc_msgSend)(video, mediaGetter);
    ((void (*)(id, SEL, id, id))objc_msgSend)(video, reloadSel, media, context);
    WolFoxDownloadLog(@"fix", @"%@ player reload on %@", stage,
                      NSStringFromClass([video class]));
    return YES;
}

static void WolFoxSeek(id player, double position, NSString *stage) {
    SEL seek = NSSelectorFromString(@"seekToTime:");
    if (![player respondsToSelector:seek]) {
        WolFoxDownloadLog(@"fix", @"%@ seek unavailable", stage);
        return;
    }
    ((void (*)(id, SEL, double))objc_msgSend)(player, seek, position);
    WolFoxDownloadLog(@"fix", @"%@ seek %.2f", stage, position);
}


static void WolFoxScheduleCaptionRestore(id player) {
    __weak id weakPlayer = player;
    const double delays[] = { 0.6, 1.5, 3.0 };
    for (size_t index = 0; index < sizeof(delays) / sizeof(delays[0]); index++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)(delays[index] * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            WolFoxCaptionsRestore(weakPlayer);
        });
    }
}

static double WolFoxPosition(id player) {
    SEL time = NSSelectorFromString(@"currentVideoMediaTime");
    if (![player respondsToSelector:time]) return -1.0;
    return ((double (*)(id, SEL))objc_msgSend)(player, time);
}

static double WolFoxCurrentVideoMediaTime(id receiver, SEL selector) {
    const double value = OriginalCurrentVideoMediaTime == NULL
        ? 0.0
        : ((double (*)(id, SEL))OriginalCurrentVideoMediaTime)(receiver, selector);
    gLatestTime = value;
    return value;
}

static void WolFoxSeekToTime(id receiver, SEL selector, double time) {
    gLatestTime = time;
    if (OriginalSeekToTime != NULL) {
        ((void (*)(id, SEL, double))OriginalSeekToTime)(receiver, selector, time);
    }
}


// The player's "Something went wrong" screen: add the real reason, a hint for
// what to try in YTKACE, and a button that copies the log for an issue.
static NSString *WolFoxErrorReason;
static NSString *WolFoxErrorChain;
static BOOL WolFoxErrorNetwork;
static CFAbsoluteTime WolFoxErrorTime;
static IMP OriginalErrorShowMessage;
static IMP OriginalErrorLayout;
static const void *WolFoxErrorInfoKey = &WolFoxErrorInfoKey;

static void WolFoxRememberPlaybackError(id error) {
    if (![error isKindOfClass:NSError.class]) return;
    NSMutableArray<NSString *> *chain = [NSMutableArray array];
    NSString *reason = nil;
    BOOL network = NO;
    NSError *current = error;
    for (int depth = 0; current != nil && depth < 6; depth++) {
        [chain addObject:[NSString stringWithFormat:@"%@ %ld", current.domain, (long)current.code]];
        if ([current.domain isEqualToString:NSURLErrorDomain]) network = YES;
        NSString *text = current.userInfo[NSLocalizedDescriptionKey];
        if ([text isKindOfClass:NSString.class] && text.length != 0) reason = text;
        current = current.userInfo[NSUnderlyingErrorKey];
    }
    WolFoxErrorReason = reason;
    WolFoxErrorChain = [chain componentsJoinedByString:@" > "];
    WolFoxErrorNetwork = network;
    WolFoxErrorTime = CFAbsoluteTimeGetCurrent();
    WolFoxDownloadLog(@"fix", @"player error %@ reason=%@", WolFoxErrorChain, reason ?: @"-");
}

static NSString *WolFoxErrorHint(void) {
    if (WolFoxErrorNetwork) return WolFoxLocalized(@"Check your connection and try again.");
    NSString *fix = WolFoxLocalized(@"Playback Fix");
    NSString *option = WolFoxPlaybackFixMode() == 2 ? WolFoxLocalized(@"Reload") : WolFoxLocalized(@"HLS Streams");
    return [NSString stringWithFormat:WolFoxLocalized(@"Try %@ > %@ in WolFox settings."), fix, option];
}

@interface WolFoxErrorInfo : NSObject
@property(nonatomic, strong) UILabel *detail;
@end

@implementation WolFoxErrorInfo
@end

static UIView *WolFoxErrorSubview(UIView *view, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    if (![view respondsToSelector:selector]) return nil;
    id value = ((id (*)(id, SEL))objc_msgSend)(view, selector);
    return [value isKindOfClass:UIView.class] ? value : nil;
}

static void WolFoxErrorShowMessage(UIView *receiver, SEL selector, id message,
                                   BOOL allowRetry, BOOL showRetry, BOOL background) {
    ((void (*)(id, SEL, id, BOOL, BOOL, BOOL))OriginalErrorShowMessage)(
        receiver, selector, message, allowRetry, showRetry, background);
    WolFoxErrorInfo *info = objc_getAssociatedObject(receiver, WolFoxErrorInfoKey);
    const BOOL fresh = WolFoxErrorTime != 0 && CFAbsoluteTimeGetCurrent() - WolFoxErrorTime < 10.0;
    if (!allowRetry || !fresh) {
        info.detail.hidden = YES;
        return;
    }
    if (info == nil) {
        info = [WolFoxErrorInfo new];
        UILabel *detail = [UILabel new];
        detail.numberOfLines = 2;
        detail.lineBreakMode = NSLineBreakByTruncatingTail;
        detail.textAlignment = NSTextAlignmentCenter;
        detail.font = [UIFont systemFontOfSize:11.0];
        detail.textColor = [UIColor colorWithWhite:1.0 alpha:0.7];
        info.detail = detail;
        [receiver addSubview:detail];
        objc_setAssociatedObject(receiver, WolFoxErrorInfoKey, info, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    info.detail.text = WolFoxErrorReason.length != 0
        ? [NSString stringWithFormat:@"%@\n%@", WolFoxErrorReason, WolFoxErrorHint()] : WolFoxErrorHint();
    info.detail.hidden = NO;
    [receiver setNeedsLayout];
}

static void WolFoxErrorLayout(UIView *receiver, SEL selector) {
    ((void (*)(id, SEL))OriginalErrorLayout)(receiver, selector);
    WolFoxErrorInfo *info = objc_getAssociatedObject(receiver, WolFoxErrorInfoKey);
    if (info == nil || info.detail.hidden) return;
    UIView *retry = WolFoxErrorSubview(receiver, @"errorTapToRetryLabel");
    UIView *message = WolFoxErrorSubview(receiver, @"errorPlainTextLabel");
    UIView *anchor = retry != nil && !retry.hidden ? retry : message;
    if (anchor == nil) return;
    const CGFloat width = MIN(CGRectGetWidth(receiver.bounds) - 40.0, 480.0);
    const CGFloat y = CGRectGetMaxY(anchor.frame) + 4.0;
    const CGFloat room = CGRectGetHeight(receiver.bounds) - 6.0 - y;
    // When there isn't room under YouTube's text, nudge everything up.
    CGSize size = [info.detail sizeThatFits:CGSizeMake(width, CGFLOAT_MAX)];
    const CGFloat shift = MAX(0.0, size.height - room);
    for (UIView *view in receiver.subviews) {
        if (view == info.detail || CGRectGetHeight(view.frame) >= CGRectGetHeight(receiver.bounds) - 1.0) continue;
        view.frame = CGRectOffset(view.frame, 0.0, -shift);
    }
    info.detail.frame = CGRectMake((CGRectGetWidth(receiver.bounds) - width) / 2.0, y - shift, width, size.height);
    [receiver bringSubviewToFront:info.detail];
}

static void WolFoxCallOriginalHandleError(id receiver, SEL selector, id error) {
    if (OriginalHandleError != NULL) {
        ((void (*)(id, SEL, id))OriginalHandleError)(receiver, selector, error);
    }
}

static id WolFoxFixValue(id object, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    if (object == nil || ![object respondsToSelector:selector]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(object, selector);
}

// currentVideoID can be nil while the player is in an error state
static NSString *WolFoxPlayerVideoID(id pvc) {
    NSArray<NSArray<NSString *> *> *paths = @[
        @[@"currentVideoID"], @[@"contentVideoID"], @[@"activeVideo", @"videoID"],
        @[@"contentPlayerResponse", @"playerData", @"videoDetails", @"videoId"],
        @[@"playerResponse", @"playerData", @"videoDetails", @"videoId"]
    ];
    for (NSArray<NSString *> *path in paths) {
        id value = pvc;
        for (NSString *name in path) value = WolFoxFixValue(value, name);
        if ([value isKindOfClass:NSString.class] && [value length] != 0) {
            WolFoxDebugLog(@"hls", @"video id from %@", [path componentsJoinedByString:@"."]);
            return value;
        }
    }
    return nil;
}

static void WolFoxHandleError(id receiver, SEL selector, id error) {
    WolFoxRememberPlaybackError(error);
    if (WolFoxPlaybackFixMode() == 2) {
        NSError *hlsError = [error isKindOfClass:NSError.class] ? error : nil;
        WolFoxDownloadLog(@"hls", @"player error domain=%@ code=%ld", hlsError.domain ?: @"-",
                          (long)hlsError.code);
        SEL parentGetter = NSSelectorFromString(@"parentViewController");
        id pvc = [receiver respondsToSelector:parentGetter]
            ? ((id (*)(id, SEL))objc_msgSend)(receiver, parentGetter) : nil;
        NSString *videoID = WolFoxPlayerVideoID(pvc);
        const double savedTime = WolFoxPosition(pvc);
        __weak id weakReceiver = receiver;
        __weak id weakPlayer = pvc;
        const BOOL started = WolFoxHLSBeginFallback(videoID, ^(BOOL available) {
                id strongReceiver = weakReceiver;
                id strongPlayer = weakPlayer;
                BOOL switched = NO;
                if (available && strongPlayer != nil) WolFoxCaptionsSnapshot(strongPlayer);
                if (available && strongPlayer != nil && WolFoxReloadPlayer(strongPlayer, @"hls fallback")) {
                    WolFoxDownloadLog(@"hls", @"fallback to vision at %.2f", savedTime);
                    switched = YES;
                } else if (available && strongReceiver != nil) {
                    WolFoxSendRetryEvent(strongReceiver, @"hls fallback");
                    WolFoxDownloadLog(@"hls", @"fallback to vision at %.2f retry", savedTime);
                    switched = YES;
                }
                if (switched) {
                    // pick up where the failed stream stopped
                    if (strongPlayer != nil && savedTime > 1.0) {
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.30 * NSEC_PER_SEC)),
                                       dispatch_get_main_queue(), ^{
                            WolFoxSeek(weakPlayer, savedTime, @"hls fallback");
                            WolFoxScheduleCaptionRestore(weakPlayer);
                        });
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)),
                                       dispatch_get_main_queue(), ^{
                            const double now = WolFoxPosition(weakPlayer);
                            WolFoxDownloadLog(@"hls", @"fallback verify saved=%.2f now=%.2f", savedTime, now);
                            if (now >= 0 && now < savedTime - 2.0) WolFoxSeek(weakPlayer, savedTime, @"hls verify");
                        });
                    }
                    return;
                }
                WolFoxDownloadLog(@"hls", @"fallback unavailable video=%@", videoID);
                if (strongReceiver != nil) WolFoxCallOriginalHandleError(strongReceiver, selector, error);
            });
        if (started) return;
        WolFoxCallOriginalHandleError(receiver, selector, error);
        return;
    }
    if (!WolFoxPlaybackFixEnabled()) {
        WolFoxCallOriginalHandleError(receiver, selector, error);
        return;
    }

    if (gIsTimeToRetry) {
        WolFoxDownloadLog(@"fix", @"retry already in flight, passing through");
        WolFoxCallOriginalHandleError(receiver, selector, error);
        return;
    }

    NSError *failure = [error isKindOfClass:NSError.class] ? (NSError *)error : nil;
    if (failure != nil) {
        WolFoxDownloadLog(@"fix", @"handleError domain=%@ code=%ld",
                          failure.domain, (long)failure.code);
    } else {
        WolFoxDownloadLog(@"fix", @"handleError non-NSError %@",
                          NSStringFromClass([error class]));
    }

    if (failure != nil &&
        [failure.domain isEqualToString:WolFoxPlaybackErrorDomain] &&
        (failure.code == 14 || failure.code == 0)) {
        gIsTimeToRetry = YES;

        SEL parentGetter = NSSelectorFromString(@"parentViewController");
        id pvc = [receiver respondsToSelector:parentGetter]
            ? ((id (*)(id, SEL))objc_msgSend)(receiver, parentGetter)
            : nil;
        const double savedTime = gLatestTime;
        WolFoxDownloadLog(@"fix", @"intercepted code=%ld at %.2f parent=%@",
                          (long)failure.code, savedTime,
                          pvc == nil ? @"nil" : NSStringFromClass([pvc class]));

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)(WolFoxStallGrace * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            const double moved = WolFoxPosition(pvc);
            if (moved > savedTime + WolFoxProgressEpsilon) {
                gIsTimeToRetry = NO;
                WolFoxDownloadLog(@"fix", @"still playing %.2f -> %.2f, no retry",
                                  savedTime, moved);
                return;
            }
            WolFoxDownloadLog(@"fix", @"stalled at %.2f, retrying", savedTime);
            WolFoxCaptionsSnapshot(pvc);
            if (!WolFoxReloadPlayer(pvc, @"primary")) {
                WolFoxSendRetryEvent(receiver, @"primary");
            }

            if (pvc) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                             (int64_t)(0.20 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    WolFoxSeek(pvc, savedTime, @"primary");

                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                                 (int64_t)(0.10 * NSEC_PER_SEC)),
                                   dispatch_get_main_queue(), ^{
                        WolFoxScheduleCaptionRestore(pvc);

                        if (!gEmergencyCheckRunning) {
                            gEmergencyCheckRunning = true;

                            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                                         (int64_t)(3.00 * NSEC_PER_SEC)),
                                           dispatch_get_main_queue(), ^{
                                const double currentTime = WolFoxPosition(pvc);
                                WolFoxDownloadLog(@"fix",
                                    @"verify saved=%.2f now=%.2f", savedTime,
                                    currentTime);

                                if (currentTime <= savedTime + 0.05) {
                                    WolFoxDownloadLog(@"fix", @"still stalled");
                                    if (!WolFoxReloadPlayer(pvc, @"emergency")) {
                                        WolFoxSendRetryEvent(receiver, @"emergency");
                                    }
                                    WolFoxSeek(pvc, savedTime, @"emergency");

                                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                                                 (int64_t)(0.20 * NSEC_PER_SEC)),
                                                   dispatch_get_main_queue(), ^{
                                        WolFoxScheduleCaptionRestore(pvc);
                                        gIsTimeToRetry = NO;
                                        WolFoxDownloadLog(@"fix", @"emergency done");
                                    });
                                } else {
                                    gIsTimeToRetry = NO;
                                    WolFoxDownloadLog(@"fix", @"recovered");
                                }

                                gEmergencyCheckRunning = false;
                            });
                        } else {
                            WolFoxDownloadLog(@"fix", @"emergency check busy");
                        }
                    });
                });
            } else {
                gIsTimeToRetry = NO;
                WolFoxDownloadLog(@"fix", @"no parent view controller");
            }
        });

        return;
    }

    WolFoxCallOriginalHandleError(receiver, selector, error);
}

void WolFoxInstallPlaybackFixHooks(void) {
    const BOOL time = WolFoxInstallInstanceHook(
        @"YTPlayerViewController", @"currentVideoMediaTime",
        (IMP)WolFoxCurrentVideoMediaTime, &OriginalCurrentVideoMediaTime);
    const BOOL seek = WolFoxInstallInstanceHook(
        @"YTPlayerViewController", @"seekToTime:",
        (IMP)WolFoxSeekToTime, &OriginalSeekToTime);
    const BOOL handle = WolFoxInstallInstanceHook(
        @"YTMainAppVideoPlayerOverlayViewController", @"handleError:",
        (IMP)WolFoxHandleError, &OriginalHandleError);
    WolFoxInstallInstanceHook(@"YTErrorPlayerOverlayView",
        @"showErrorWithMessage:allowTapToRetry:showTapToRetryMessage:showErrorBackground:",
        (IMP)WolFoxErrorShowMessage, &OriginalErrorShowMessage);
    WolFoxInstallInstanceHook(@"YTErrorPlayerOverlayView", @"layoutSubviews",
        (IMP)WolFoxErrorLayout, &OriginalErrorLayout);
    WolFoxDownloadLog(@"fix", @"hooks time=%d seek=%d handle=%d enabled=%d",
                      time, seek, handle, WolFoxPlaybackFixEnabled());
}
