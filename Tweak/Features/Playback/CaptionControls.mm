#import "../../WolFox.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"
#import "../Downloads/DownloadLog.h"

#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#import <objc/runtime.h>

static IMP OriginalSetActiveCaptionTrack;
static IMP OriginalSetSingleVideoCaptionTrack;
static IMP OriginalSetCaptionError;
static IMP OriginalSetLocalCaptionTrack;
static IMP OriginalSetMDXCaptionTrack;
static BOOL WolFoxHasRememberedSource;
static NSMutableSet<NSString *> *WolFoxAppliedKeys;
static NSMutableDictionary<NSString *, NSNumber *> *WolFoxRestoredAt;
static const NSTimeInterval WolFoxRestoreWindow = 4.0;
static NSMutableSet<NSString *> *WolFoxFailedKeys;
static NSString *WolFoxLastAppliedKey;

static BOOL WolFoxCaptionKeyFailed(NSString *key) {
    if (key.length == 0 || WolFoxFailedKeys == nil) return NO;
    @synchronized (WolFoxFailedKeys) {
        return [WolFoxFailedKeys containsObject:key];
    }
}

static void WolFoxNoteCaptionFailure(NSString *key) {
    if (key.length == 0) return;
    if (WolFoxFailedKeys == nil) {
        WolFoxFailedKeys = [NSMutableSet set];
    }
    @synchronized (WolFoxFailedKeys) {
        if (WolFoxFailedKeys.count >= 128) {
            [WolFoxFailedKeys removeAllObjects];
        }
        [WolFoxFailedKeys addObject:key];
    }
}

static NSString *WolFoxCurrentVideoID(id player) {
    SEL selector = NSSelectorFromString(@"currentVideoID");
    if (![player respondsToSelector:selector]) return nil;
    id value = ((id (*)(id, SEL))objc_msgSend)(player, selector);
    return [value isKindOfClass:NSString.class] ? value : nil;
}
static NSTimeInterval WolFoxCaptionBackoffUntil;

static __weak id WolFoxRememberedTrack;
static NSString *WolFoxRememberedVSSID;
static NSString *WolFoxRememberedLanguage;
static long long WolFoxRememberedSource;
static BOOL WolFoxHasRememberedTrack;
static NSString *const WolFoxCaptionsUserOffKey = @"WolFox.State.CaptionsUserOff";

static NSString *WolFoxCaptionString(id track, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    if (track == nil || ![track respondsToSelector:selector]) return nil;
    id value = ((id (*)(id, SEL))objc_msgSend)(track, selector);
    return [value isKindOfClass:NSString.class] ? value : nil;
}

static id WolFoxCaptionValueForKey(id receiver, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    if (receiver == nil || ![receiver respondsToSelector:selector]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(receiver, selector);
}

static void WolFoxRememberTrack(id track, long long source) {
    WolFoxRememberedTrack = track;
    WolFoxRememberedVSSID = [WolFoxCaptionString(track, @"VSSID") copy];
    WolFoxRememberedLanguage = [WolFoxCaptionString(track, @"languageCode") copy];
    WolFoxRememberedSource = source;
    WolFoxHasRememberedSource = YES;
    WolFoxHasRememberedTrack = YES;
}

static void WolFoxSetActiveCaptionTrack(id receiver,
                                        SEL selector,
                                        id track,
                                        long long source) {
    WolFoxDownloadLog(@"caption", @"app set track=%@ source=%lld class=%@",
                      WolFoxCaptionString(track, @"languageCode") ?: @"nil",
                      source, NSStringFromClass(object_getClass(receiver)));
    if (track == nil && source == 4) {
        [NSUserDefaults.standardUserDefaults setBool:YES forKey:WolFoxCaptionsUserOffKey];
    } else if (track != nil && source != 3) {
        [NSUserDefaults.standardUserDefaults setBool:NO forKey:WolFoxCaptionsUserOffKey];
    }
    if (track != nil) {
        WolFoxRememberTrack(track, source);
    } else {
        WolFoxHasRememberedTrack = NO;
        WolFoxRememberedTrack = nil;
        WolFoxRememberedVSSID = nil;
        WolFoxRememberedLanguage = nil;
    }
    if (OriginalSetActiveCaptionTrack != NULL) {
        ((void (*)(id, SEL, id, long long))OriginalSetActiveCaptionTrack)(
            receiver, selector, track, source);
    }
}

static void WolFoxSetSingleVideoCaptionTrack(id receiver,
                                             SEL selector,
                                             id track,
                                             long long source) {
    WolFoxDownloadLog(@"caption", @"single set track=%@ source=%lld class=%@",
                      WolFoxCaptionString(track, @"languageCode") ?: @"nil",
                      source, NSStringFromClass(object_getClass(receiver)));
    if (track != nil) {
        WolFoxRememberTrack(track, source);
    }
    if (OriginalSetSingleVideoCaptionTrack != NULL) {
        ((void (*)(id, SEL, id, long long))OriginalSetSingleVideoCaptionTrack)(
            receiver, selector, track, source);
    }
}

static void WolFoxSetCaptionError(id receiver, SEL selector, id error) {
    if (error != nil) {
        NSError *value = [error isKindOfClass:NSError.class] ? error : nil;
        WolFoxDownloadLog(@"caption",
                          @"ERROR domain=%@ code=%ld desc=%@ class=%@",
                          value.domain ?: @"?", (long)value.code,
                          value.localizedDescription ?: [error description],
                          NSStringFromClass(object_getClass(receiver)));
        if (value.code == 429) {
            WolFoxNoteCaptionFailure(WolFoxLastAppliedKey);
            WolFoxCaptionBackoffUntil = CACurrentMediaTime() + 30;
            WolFoxDownloadLog(@"caption",
                              @"429 cooldown 30s blamed=%@",
                              WolFoxLastAppliedKey ?: @"nil");
        }
    }
    if (OriginalSetCaptionError != NULL) {
        ((void (*)(id, SEL, id))OriginalSetCaptionError)(receiver, selector,
                                                        error);
    }
}

static void WolFoxSetLocalCaptionTrack(id receiver, SEL selector, id track,
                                       long long source) {
    WolFoxDownloadLog(@"caption", @"local set track=%@ source=%lld class=%@",
                      WolFoxCaptionString(track, @"languageCode") ?: @"nil",
                      source, NSStringFromClass(object_getClass(receiver)));
    if (OriginalSetLocalCaptionTrack != NULL) {
        ((void (*)(id, SEL, id, long long))OriginalSetLocalCaptionTrack)(
            receiver, selector, track, source);
    }
}

static void WolFoxSetMDXCaptionTrack(id receiver, SEL selector, id track,
                                     long long source) {
    WolFoxDownloadLog(@"caption", @"mdx set track=%@ source=%lld class=%@",
                      WolFoxCaptionString(track, @"languageCode") ?: @"nil",
                      source, NSStringFromClass(object_getClass(receiver)));
    if (OriginalSetMDXCaptionTrack != NULL) {
        ((void (*)(id, SEL, id, long long))OriginalSetMDXCaptionTrack)(
            receiver, selector, track, source);
    }
}

static id WolFoxMatchingTrack(id player) {
    id video = WolFoxCaptionValueForKey(player, @"activeVideo");
    id available = WolFoxCaptionValueForKey(video, @"availableCaptionTracks")
        ?: WolFoxCaptionValueForKey(player, @"availableCaptionTracks");
    if (![available isKindOfClass:NSArray.class]) return WolFoxRememberedTrack;
    for (id track in (NSArray *)available) {
        NSString *vssID = WolFoxCaptionString(track, @"VSSID");
        if (WolFoxRememberedVSSID.length != 0 &&
            [vssID isEqualToString:WolFoxRememberedVSSID]) {
            return track;
        }
    }
    for (id track in (NSArray *)available) {
        NSString *language = WolFoxCaptionString(track, @"languageCode");
        if (WolFoxRememberedLanguage.length != 0 &&
            [language isEqualToString:WolFoxRememberedLanguage]) {
            return track;
        }
    }
    return WolFoxRememberedTrack;
}


static NSString *const WolFoxPreferredLanguageKey =
    @"YTKACE.Preference.Playback.CaptionLanguage";

static NSString *WolFoxTrackLanguage(id track) {
    id value = WolFoxCaptionValueForKey(track, @"languageCode");
    return [value isKindOfClass:NSString.class] ? value : nil;
}

void WolFoxApplyPreferredCaptionLanguage(id player) {
    if (WolFoxCaptionsMode() == 2) return;
    NSString *preferred = [NSUserDefaults.standardUserDefaults
        stringForKey:WolFoxPreferredLanguageKey];
    if (preferred.length == 0) return;

    id video = WolFoxCaptionValueForKey(player, @"activeVideo");
    id available = WolFoxCaptionValueForKey(video, @"availableCaptionTracks")
        ?: WolFoxCaptionValueForKey(player, @"availableCaptionTracks");
    if (![available isKindOfClass:NSArray.class] || [available count] == 0) {
        return;
    }
    id active = WolFoxCaptionValueForKey(video, @"activeCaptionTrack");
    if (active != nil &&
        [NSUserDefaults.standardUserDefaults boolForKey:WolFoxCaptionsUserOffKey]) {
        // captions are showing again, so the user turned them back on
        [NSUserDefaults.standardUserDefaults setBool:NO forKey:WolFoxCaptionsUserOffKey];
        WolFoxDebugLog(@"caption", @"captions back on, clearing off flag");
    }
    if (active != nil &&
        [WolFoxTrackLanguage(active) hasPrefix:preferred]) {
        return;
    }
    if (active == nil && WolFoxCaptionsMode() != 1 &&
        [NSUserDefaults.standardUserDefaults boolForKey:WolFoxCaptionsUserOffKey]) {
        WolFoxDebugLog(@"caption", @"skip, user turned captions off");
        __weak id weakPlayer = player;
        const double delays[] = { 2.0, 5.0 };
        for (size_t index = 0; index < 2; index++) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delays[index] * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                id strong = weakPlayer;
                id current = WolFoxCaptionValueForKey(strong, @"activeVideo");
                if (WolFoxCaptionValueForKey(current, @"activeCaptionTrack") != nil) {
                    WolFoxApplyPreferredCaptionLanguage(strong);
                }
            });
        }
        return;
    }

    if (WolFoxCaptionBackoffUntil != 0 &&
        CACurrentMediaTime() < WolFoxCaptionBackoffUntil) {
        return;
    }

    NSString *videoID = nil;
    SEL videoIDSel = NSSelectorFromString(@"currentVideoID");
    if ([player respondsToSelector:videoIDSel]) {
        id value = ((id (*)(id, SEL))objc_msgSend)(player, videoIDSel);
        if ([value isKindOfClass:NSString.class]) videoID = value;
    }
    NSString *appliedKey = videoID.length != 0
        ? [NSString stringWithFormat:@"%@|%@", videoID, preferred] : nil;
    if (WolFoxAppliedKeys == nil) {
        WolFoxAppliedKeys = [NSMutableSet set];
    }
    if (appliedKey != nil && [WolFoxAppliedKeys containsObject:appliedKey]) {
        return;
    }
    if (WolFoxCaptionKeyFailed(appliedKey)) {
        WolFoxDownloadLog(@"caption", @"skip known-failed %@", appliedKey);
        return;
    }

    id exact = nil;
    NSInteger exactRank = NSIntegerMax;
    id prefix = nil;
    NSMutableArray<NSString *> *vssList = [NSMutableArray array];
    for (id track in (NSArray *)available) {
        NSString *code = WolFoxTrackLanguage(track);
        if (code.length == 0) continue;
        NSString *vss = WolFoxCaptionString(track, @"VSSID") ?: @"";
        if ([code caseInsensitiveCompare:preferred] == NSOrderedSame) {
            [vssList addObject:vss.length != 0 ? vss : @"-"];
            NSInteger rank = 2;
            if ([vss hasPrefix:@"."]) {
                rank = 0;
            } else if ([vss hasPrefix:@"a."]) {
                rank = 1;
            }
            if (rank < exactRank) {
                exactRank = rank;
                exact = track;
            }
            continue;
        }
        if (prefix == nil && [code.lowercaseString
                hasPrefix:preferred.lowercaseString]) {
            prefix = track;
        }
    }
    if (vssList.count > 1) {
        WolFoxDownloadLog(@"caption", @"candidates %@ picked rank=%ld",
                          [vssList componentsJoinedByString:@","],
                          (long)exactRank);
    }
    NSMutableArray<NSString *> *codes = [NSMutableArray array];
    for (id track in (NSArray *)available) {
        [codes addObject:WolFoxTrackLanguage(track) ?: @"?"];
    }
    WolFoxDownloadLog(@"caption",
                      @"apply preferred=%@ count=%lu tracks=%@ active=%@ "
                       "haveSource=%d source=%lld",
                      preferred, (unsigned long)[available count],
                      [codes componentsJoinedByString:@","],
                      WolFoxTrackLanguage(active) ?: @"nil",
                      WolFoxHasRememberedSource, WolFoxRememberedSource);

    id chosen = exact ?: prefix;
    if (chosen == nil) {
        WolFoxDownloadLog(@"caption",
                          @"no usable track for %@ translatedOnly=%@",
                          preferred,
                          vssList.count != 0
                            ? [vssList componentsJoinedByString:@","] : @"-");
        return;
    }
    SEL setter = NSSelectorFromString(@"setActiveCaptionTrack:source:");
    if (![player respondsToSelector:setter]) return;
    if (appliedKey != nil) {
        if (WolFoxAppliedKeys.count >= 64) {
            [WolFoxAppliedKeys removeAllObjects];
        }
        [WolFoxAppliedKeys addObject:appliedKey];
        WolFoxLastAppliedKey = appliedKey;
    }
    const long long applySource = 3;
    ((void (*)(id, SEL, id, long long))objc_msgSend)(
        player, setter, chosen, applySource);
    WolFoxDownloadLog(@"caption",
                      @"applied preferred=%@ chosen=%@ vss=%@ exact=%d "
                       "source=%lld video=%@",
                      preferred, WolFoxTrackLanguage(chosen) ?: @"?",
                      WolFoxCaptionString(chosen, @"VSSID") ?: @"-",
                      exact != nil, applySource,
                      videoID ?: @"?");
}

void WolFoxCaptionsSnapshot(id player) {
    id video = WolFoxCaptionValueForKey(player, @"activeVideo");
    id active = WolFoxCaptionValueForKey(video, @"activeCaptionTrack");
    if (active != nil) {
        WolFoxRememberTrack(active, WolFoxRememberedSource);
    }
}

void WolFoxCaptionsRestore(id player) {
    if (!WolFoxHasRememberedTrack) return;
    if (WolFoxCaptionBackoffUntil != 0 &&
        CACurrentMediaTime() < WolFoxCaptionBackoffUntil) {
        return;
    }
    id video = WolFoxCaptionValueForKey(player, @"activeVideo");
    if (WolFoxCaptionValueForKey(video, @"activeCaptionTrack") != nil) return;

    id track = WolFoxMatchingTrack(player);
    if (track == nil) return;

    NSString *videoID = WolFoxCurrentVideoID(player);
    NSString *language = WolFoxCaptionString(track, @"languageCode") ?: @"?";
    NSString *restoreKey = videoID.length != 0
        ? [NSString stringWithFormat:@"%@|%@", videoID, language] : nil;
    if (WolFoxRestoredAt == nil) {
        WolFoxRestoredAt = [NSMutableDictionary dictionary];
    }
    const NSTimeInterval now = CACurrentMediaTime();
    NSNumber *lastRestore = restoreKey != nil ? WolFoxRestoredAt[restoreKey] : nil;
    if (lastRestore != nil && now - lastRestore.doubleValue < WolFoxRestoreWindow) {
        return;
    }
    if (WolFoxCaptionKeyFailed(restoreKey)) return;

    SEL setter = NSSelectorFromString(@"setActiveCaptionTrack:source:");
    if (![player respondsToSelector:setter]) return;
    if (restoreKey != nil) {
        if (WolFoxRestoredAt.count >= 64) {
            [WolFoxRestoredAt removeAllObjects];
        }
        WolFoxRestoredAt[restoreKey] = @(now);
        WolFoxLastAppliedKey = restoreKey;
    }
    ((void (*)(id, SEL, id, long long))objc_msgSend)(
        player, setter, track, WolFoxRememberedSource);
    WolFoxDownloadLog(@"fix", @"captions restored %@ video=%@", language,
                      videoID ?: @"?");
}

void WolFoxInstallCaptionHooks(void) {
    BOOL pvc = WolFoxInstallInstanceHook(@"YTPlayerViewController",
                                        @"setActiveCaptionTrack:source:",
                                        (IMP)WolFoxSetActiveCaptionTrack,
                                        &OriginalSetActiveCaptionTrack);
    BOOL svc = WolFoxInstallInstanceHook(
        @"YTSingleVideoController", @"setActiveCaptionTrack:source:",
        (IMP)WolFoxSetSingleVideoCaptionTrack,
        &OriginalSetSingleVideoCaptionTrack);
    BOOL err = WolFoxInstallInstanceHook(
        @"YTMainAppVideoPlayerOverlayViewController", @"setCaptionError:",
        (IMP)WolFoxSetCaptionError, &OriginalSetCaptionError);
    BOOL loc = WolFoxInstallInstanceHook(
        @"YTLocalPlaybackController", @"setActiveCaptionTrack:source:",
        (IMP)WolFoxSetLocalCaptionTrack, &OriginalSetLocalCaptionTrack);
    BOOL mdx = WolFoxInstallInstanceHook(
        @"MDXPlaybackController", @"setActiveCaptionTrack:source:",
        (IMP)WolFoxSetMDXCaptionTrack, &OriginalSetMDXCaptionTrack);
    WolFoxDownloadLog(@"caption",
                      @"hooks pvc=%d single=%d error=%d local=%d mdx=%d",
                      pvc, svc, err, loc, mdx);
}
