#import "../../WolFox.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"
#import "../Downloads/DownloadLog.h"
#import "../Downloads/SABRDownloader.h"

#import <Foundation/Foundation.h>
#import <VideoToolbox/VideoToolbox.h>
#import <objc/message.h>
#import <objc/runtime.h>

// visionOS client identifiers from yt-dlp (Unlicense, public domain)
static NSString *const WolFoxVisionClientName    = @"VISIONOS";
static NSString *const WolFoxVisionClientVersion = @"1.02";
static NSString *const WolFoxVisionDeviceMake    = @"Apple";
static NSString *const WolFoxVisionDeviceModel   = @"RealityDevice17,1";
static NSString *const WolFoxVisionOSName        = @"visionOS";
static NSString *const WolFoxVisionOSVersion     = @"26.5.23O471";
static NSString *const WolFoxVisionUserAgent     =
    @"Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) AppleWebKit/605.1.15 "
     "(KHTML, like Gecko) Version/26.0 Safari/605.1.15";

static const NSTimeInterval WolFoxHLSCacheLifetime = 4.0 * 60.0 * 60.0;

static IMP WolFoxHLSOrigInitFull;
static IMP WolFoxHLSOrigInitShort;
static IMP WolFoxHLSOrigInitRental;
static IMP WolFoxHLSOrigParseString;
static IMP WolFoxHLSOrigSetConstraint;
static IMP WolFoxHLSOrigPlay;
static IMP WolFoxHLSOrigPause;
static IMP WolFoxHLSOrigScrubStart;
static IMP WolFoxHLSOrigScrubEnd;

static NSMutableDictionary<NSString *, NSDictionary *> *WolFoxHLSCache;
static NSMutableDictionary<NSString *, NSMutableArray *> *WolFoxHLSPending;
static NSMutableDictionary<NSString *, id> *WolFoxHLSOriginals;

static NSMutableDictionary<NSString *, NSString *> *WolFoxHLSSources;
static NSMutableSet<NSString *> *WolFoxHLSFallbacks;
static BOOL WolFoxHLSInScrubStart;
static BOOL WolFoxHLSScrubPaused;
static NSUInteger WolFoxHLSScrubGeneration;

static BOOL WolFoxHLSEnabled(void) {
    return WolFoxPlaybackFixMode() == 2;
}

static id WolFoxHLSGet(id object, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    if (object == nil || ![object respondsToSelector:selector]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(object, selector);
}

static BOOL WolFoxHLSBool(id object, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    if (object == nil || ![object respondsToSelector:selector]) return NO;
    return ((BOOL (*)(id, SEL))objc_msgSend)(object, selector);
}

static long long WolFoxHLSInteger(id object, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    if (object == nil || ![object respondsToSelector:selector]) return LLONG_MIN;
    const char *type = [object methodSignatureForSelector:selector].methodReturnType;
    if (type[0] == 'i') return ((int (*)(id, SEL))objc_msgSend)(object, selector);
    if (type[0] == 'q' || type[0] == 'l') return ((long long (*)(id, SEL))objc_msgSend)(object, selector);
    if (type[0] == 'B' || type[0] == 'c') return ((BOOL (*)(id, SEL))objc_msgSend)(object, selector);
    return LLONG_MIN;
}

static NSDictionary *WolFoxVisionContext(NSString *visitor) {
    NSMutableDictionary *client = [@{
        @"clientName": WolFoxVisionClientName,
        @"clientVersion": WolFoxVisionClientVersion,
        @"deviceMake": WolFoxVisionDeviceMake,
        @"deviceModel": WolFoxVisionDeviceModel,
        @"osName": WolFoxVisionOSName,
        @"osVersion": WolFoxVisionOSVersion,
        @"userAgent": WolFoxVisionUserAgent,
        @"hl": @"en",
        @"gl": @"US"
    } mutableCopy];
    if (visitor.length != 0) client[@"visitorData"] = visitor;
    return @{@"client": client};
}

static NSMutableURLRequest *WolFoxVisionRequest(NSString *path, NSDictionary *body, NSString *visitor) {
    NSURL *url = [NSURL URLWithString:[@"https://youtubei.googleapis.com/youtubei/v1/" stringByAppendingString:path]];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.timeoutInterval = 12;
    request.HTTPMethod = @"POST";
    request.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:WolFoxVisionUserAgent forHTTPHeaderField:@"User-Agent"];
    if (visitor.length != 0) [request setValue:visitor forHTTPHeaderField:@"X-Goog-Visitor-Id"];
    return request;
}

static NSString *WolFoxVisionVisitor(void) {
    NSDictionary *cached = WolFoxPreferenceObject(@"WolFox.Cache.DirectVisitor");
    NSString *value = [cached isKindOfClass:NSDictionary.class] ? cached[@"id"] : nil;
    if ([value isKindOfClass:NSString.class] && value.length != 0) return value;
    static NSString *fetched;
    if (fetched.length != 0) return fetched;
    __block NSString *visitor = nil;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    [[NSURLSession.sharedSession dataTaskWithRequest:WolFoxVisionRequest(
        @"guide?prettyPrint=false&fields=responseContext.visitorData",
        @{@"context": WolFoxVisionContext(nil)}, nil)
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        id json = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        id found = [json isKindOfClass:NSDictionary.class] ? json[@"responseContext"][@"visitorData"] : nil;
        if ([found isKindOfClass:NSString.class]) visitor = found;
        if (visitor == nil) {
            WolFoxDownloadLog(@"hls", @"visitor failed http=%ld bytes=%lu error=%@",
                              [response isKindOfClass:NSHTTPURLResponse.class] ? (long)((NSHTTPURLResponse *)response).statusCode : 0L,
                              (unsigned long)data.length,
                              error != nil ? [NSString stringWithFormat:@"%@ %ld %@", error.domain, (long)error.code,
                                              error.localizedDescription] : @"none");
        }
        dispatch_semaphore_signal(done);
    }] resume];
    dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(12 * NSEC_PER_SEC)));
    fetched = visitor;
    return visitor;
}

static NSString *WolFoxHLSCachedURL(NSString *videoID) {
    @synchronized (WolFoxHLSCache) {
        NSDictionary *entry = WolFoxHLSCache[videoID];
        if (entry == nil) return nil;
        if (NSDate.date.timeIntervalSince1970 - [entry[@"time"] doubleValue] > WolFoxHLSCacheLifetime) {
            [WolFoxHLSCache removeObjectForKey:videoID];
            return nil;
        }
        return entry[@"url"];
    }
}

static void WolFoxHLSFetchVisionThen(NSString *videoID, void (^done)(BOOL ready));

static void WolFoxHLSFetchVision(NSString *videoID) {
    WolFoxHLSFetchVisionThen(videoID, nil);
}

static void WolFoxHLSFetchVisionThen(NSString *videoID, void (^done)(BOOL ready)) {
    @synchronized (WolFoxHLSCache) {
        const BOOL cached = WolFoxHLSCachedURL(videoID) != nil;
        if (cached) {
            if (done != nil) done(YES);
            return;
        }
        NSMutableArray *waiters = WolFoxHLSPending[videoID];
        if (waiters != nil) {
            if (done != nil) [waiters addObject:[done copy]];
            return;
        }
        waiters = [NSMutableArray array];
        if (done != nil) [waiters addObject:[done copy]];
        WolFoxHLSPending[videoID] = waiters;
    }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *visitor = WolFoxVisionVisitor();
        NSDictionary *body = @{
            @"context": WolFoxVisionContext(visitor),
            @"videoId": videoID,
            @"contentCheckOk": @YES,
            @"racyCheckOk": @YES
        };
        [[NSURLSession.sharedSession dataTaskWithRequest:WolFoxVisionRequest(@"player?prettyPrint=false", body, visitor)
            completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            id json = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
            NSDictionary *root = [json isKindOfClass:NSDictionary.class] ? json : @{};
            const NSInteger http = [response isKindOfClass:NSHTTPURLResponse.class]
                ? ((NSHTTPURLResponse *)response).statusCode : 0;
            NSDictionary *playability = [root[@"playabilityStatus"] isKindOfClass:NSDictionary.class]
                ? root[@"playabilityStatus"] : @{};
            NSDictionary *streaming = [root[@"streamingData"] isKindOfClass:NSDictionary.class]
                ? root[@"streamingData"] : @{};
            NSString *hls = [streaming[@"hlsManifestUrl"] isKindOfClass:NSString.class] ? streaming[@"hlsManifestUrl"] : nil;
            NSArray *waiters;
            @synchronized (WolFoxHLSCache) {
                waiters = [WolFoxHLSPending[videoID] copy];
                [WolFoxHLSPending removeObjectForKey:videoID];
                if (hls.length != 0) {
                    WolFoxHLSCache[videoID] = @{@"url": hls, @"time": @(NSDate.date.timeIntervalSince1970)};
                }
            }
            if (hls.length == 0) {
                // A missing status means the request itself failed (network,
                // proxy, non-JSON reply), not that YouTube refused the video.
                WolFoxDownloadLog(@"hls", @"vision video=%@ playability=%@ reason=%@ http=%ld bytes=%lu visitor=%d error=%@",
                                  videoID, playability[@"status"] ?: @"-", playability[@"reason"] ?: @"-", (long)http,
                                  (unsigned long)data.length, visitor.length != 0,
                                  error != nil ? [NSString stringWithFormat:@"%@ %ld %@", error.domain, (long)error.code,
                                                  error.localizedDescription] : @"none");
            }
            for (void (^waiter)(BOOL) in waiters) waiter(hls.length != 0);
        }] resume];
    });
}

static NSString *WolFoxHLSLastVideo;

BOOL WolFoxHLSBeginFallback(NSString *videoID, void (^ready)(BOOL available)) {
    if (!WolFoxHLSEnabled() || WolFoxHLSSources == nil) return NO;
    @synchronized (WolFoxHLSSources) {
        // the player has no video yet when the manifest fails on load
        if (videoID.length == 0) videoID = WolFoxHLSLastVideo;
        if (videoID.length == 0) return NO;
        if (![WolFoxHLSSources[videoID] isEqualToString:@"ios"]) return NO;
        if ([WolFoxHLSFallbacks containsObject:videoID]) return YES;
        [WolFoxHLSFallbacks addObject:videoID];
    }
    WolFoxHLSFetchVisionThen(videoID, ^(BOOL available) {
        dispatch_async(dispatch_get_main_queue(), ^{
            ready(available);
            @synchronized (WolFoxHLSSources) {
                [WolFoxHLSFallbacks removeObject:videoID];
            }
        });
    });
    return YES;
}

id WolFoxHLSOriginalResponse(NSString *videoID) {
    if (videoID.length == 0 || WolFoxHLSOriginals == nil) return nil;
    @synchronized (WolFoxHLSOriginals) {
        return WolFoxHLSOriginals[videoID];
    }
}

static void WolFoxHLSKeepOriginal(NSString *videoID, id data) {
    if (![data respondsToSelector:@selector(copyWithZone:)]) return;
    id copy = [data copy];
    if (copy == nil) return;
    @synchronized (WolFoxHLSOriginals) {
        if (WolFoxHLSOriginals.count > 20) [WolFoxHLSOriginals removeAllObjects];
        WolFoxHLSOriginals[videoID] = copy;
    }
}

static void WolFoxHLSSwap(id data) {
    if (!WolFoxHLSEnabled() || data == nil) return;
    NSString *videoID = WolFoxHLSGet(WolFoxHLSGet(data, @"videoDetails"), @"videoId");
    if (![videoID isKindOfClass:NSString.class] || videoID.length == 0) {
        WolFoxDebugLog(@"hls", @"skip no video id class=%@", NSStringFromClass([data class]));
        return;
    }
    id streaming = WolFoxHLSGet(data, @"streamingData");
    if (streaming == nil) {
        WolFoxDebugLog(@"hls", @"skip video=%@ no streaming data", videoID);
        return;
    }
    if (WolFoxHLSBool(streaming, @"isLivePlayback")) {
        WolFoxDebugLog(@"hls", @"skip video=%@ live", videoID);
        return;
    }
    SEL setHLS = NSSelectorFromString(@"setHlsManifestURL:");
    SEL setSABR = NSSelectorFromString(@"setHasServerAbrStreamingURL:");
    SEL setOnesie = NSSelectorFromString(@"setHasOnesieStreamingURL:");
    if (![streaming respondsToSelector:setHLS] || ![streaming respondsToSelector:setSABR] ||
        ![streaming respondsToSelector:setOnesie]) {
        WolFoxDebugLog(@"hls", @"skip video=%@ setters missing class=%@", videoID,
                       NSStringFromClass([streaming class]));
        return;
    }
    NSString *ios = WolFoxHLSGet(streaming, @"hlsManifestURL");
    if (![ios isKindOfClass:NSString.class]) ios = nil;
    const NSUInteger token = WolFoxSABRPoTokenLength();
    const BOOL untrusted = token > 0 && token < 100;
    WolFoxHLSFetchVision(videoID);
    NSString *vision = WolFoxHLSCachedURL(videoID);
    if (vision.length == 0 && (untrusted || ios.length == 0)) {
        const CFAbsoluteTime deadline = CFAbsoluteTimeGetCurrent() + 1.5;
        while (vision.length == 0 && CFAbsoluteTimeGetCurrent() < deadline) {
            usleep(20000);
            vision = WolFoxHLSCachedURL(videoID);
        }
    }
    WolFoxDebugLog(@"hls", @"check video=%@ token=%lu ios=%d vision=%d", videoID, (unsigned long)token,
                   ios.length != 0, vision.length != 0);
    NSString *chosen = vision.length != 0 ? vision : ios;
    if (chosen.length == 0) {
        WolFoxDownloadLog(@"hls", @"skip video=%@ no manifest", videoID);
        return;
    }
    WolFoxHLSKeepOriginal(videoID, data);
    ((void (*)(id, SEL, id))objc_msgSend)(streaming, setHLS, chosen);
    ((void (*)(id, SEL, BOOL))objc_msgSend)(streaming, setSABR, NO);
    ((void (*)(id, SEL, BOOL))objc_msgSend)(streaming, setOnesie, NO);
    NSMutableArray *formats = WolFoxHLSGet(streaming, @"adaptiveFormatsArray");
    if ([formats respondsToSelector:@selector(removeAllObjects)]) [formats removeAllObjects];
    @synchronized (WolFoxHLSSources) {
        if (WolFoxHLSSources.count > 50) [WolFoxHLSSources removeAllObjects];
        WolFoxHLSSources[videoID] = vision.length != 0 ? @"vision" : @"ios";
        WolFoxHLSLastVideo = [videoID copy];
    }
    WolFoxDownloadLog(@"hls", @"swap video=%@ source=%@", videoID, vision.length != 0 ? @"vision" : @"ios");
}

static id WolFoxHLSInitFull(id self, SEL _cmd, id data, id date, id offline, id state, BOOL trailer,
                            id qoe, id key, id context, id latency, BOOL rental) {
    WolFoxHLSSwap(data);
    return ((id (*)(id, SEL, id, id, id, id, BOOL, id, id, id, id, BOOL))WolFoxHLSOrigInitFull)(
        self, _cmd, data, date, offline, state, trailer, qoe, key, context, latency, rental);
}

static id WolFoxHLSInitShort(id self, SEL _cmd, id data, id date, id offline, id state, BOOL trailer) {
    WolFoxHLSSwap(data);
    return ((id (*)(id, SEL, id, id, id, id, BOOL))WolFoxHLSOrigInitShort)(
        self, _cmd, data, date, offline, state, trailer);
}

static id WolFoxHLSInitRental(id self, SEL _cmd, id data, id date, id offline, id state, BOOL trailer,
                              BOOL rental) {
    WolFoxHLSSwap(data);
    return ((id (*)(id, SEL, id, id, id, id, BOOL, BOOL))WolFoxHLSOrigInitRental)(
        self, _cmd, data, date, offline, state, trailer, rental);
}

static BOOL WolFoxHLSDeviceDecodesVP9(void) {
    static BOOL supported;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        supported = VTIsHardwareDecodeSupported('vp09');
        WolFoxDownloadLog(@"hls", @"device vp9=%d", supported);
    });
    return supported;
}

static NSString *WolFoxHLSFilterManifest(NSString *text) {
    if (![text containsString:@"vp09"] || WolFoxHLSDeviceDecodesVP9()) return text;
    NSMutableArray<NSString *> *kept = [NSMutableArray array];
    NSUInteger dropped = 0, total = 0;
    BOOL skipNext = NO;
    for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
        if (skipNext) {
            skipNext = NO;
            if (![line hasPrefix:@"#"]) continue;
        }
        if ([line hasPrefix:@"#EXT-X-STREAM-INF"]) {
            total++;
            if ([line containsString:@"vp09"]) {
                dropped++;
                skipNext = YES;
                continue;
            }
        }
        [kept addObject:line];
    }
    if (dropped == 0 || dropped == total) return text;
    return [kept componentsJoinedByString:@"\n"];
}

static id WolFoxHLSParseString(id self, SEL _cmd, NSString *string, NSError **error) {
    if (WolFoxHLSEnabled() && [string isKindOfClass:NSString.class]) string = WolFoxHLSFilterManifest(string);
    return ((id (*)(id, SEL, id, NSError **))WolFoxHLSOrigParseString)(self, _cmd, string, error);
}

static BOOL WolFoxHLSSameConstraint(id current, id incoming) {
    if (current == incoming) return YES;
    if (current == nil || incoming == nil) return NO;
    if ([current isEqual:incoming]) return YES;
    if ([current class] != [incoming class]) return NO;
    for (NSString *key in @[@"videoQualitySetting", @"stickyResolutionCap", @"disableTrack"]) {
        if (WolFoxHLSInteger(current, key) != WolFoxHLSInteger(incoming, key)) return NO;
    }
    id currentLabel = WolFoxHLSGet(current, @"qualityLabel");
    id incomingLabel = WolFoxHLSGet(incoming, @"qualityLabel");
    return currentLabel == incomingLabel || [currentLabel isEqual:incomingLabel];
}

static void WolFoxHLSSetConstraint(id self, SEL _cmd, id constraint) {
    if (WolFoxHLSSameConstraint(WolFoxHLSGet(self, @"videoFormatConstraint"), constraint)) return;
    ((void (*)(id, SEL, id))WolFoxHLSOrigSetConstraint)(self, _cmd, constraint);
}

static void WolFoxHLSScrubStart(id self, SEL _cmd, BOOL bar) {
    WolFoxHLSScrubPaused = NO;
    WolFoxHLSScrubGeneration++;
    WolFoxHLSInScrubStart = YES;
    ((void (*)(id, SEL, BOOL))WolFoxHLSOrigScrubStart)(self, _cmd, bar);
    WolFoxHLSInScrubStart = NO;
}

static void WolFoxHLSScrubEnd(id self, SEL _cmd, BOOL bar, BOOL cancelled, int source) {
    ((void (*)(id, SEL, BOOL, BOOL, int))WolFoxHLSOrigScrubEnd)(self, _cmd, bar, cancelled, source);
    if (!WolFoxHLSScrubPaused) return;
    const NSUInteger generation = WolFoxHLSScrubGeneration;
    __weak id weakOverlay = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        id overlay = weakOverlay;
        if (overlay == nil || !WolFoxHLSScrubPaused || generation != WolFoxHLSScrubGeneration) return;
        WolFoxHLSScrubPaused = NO;
        SEL play = NSSelectorFromString(@"didPressPlay:");
        if ([overlay respondsToSelector:play]) ((void (*)(id, SEL, id))objc_msgSend)(overlay, play, nil);
    });
}

static void WolFoxHLSPlay(id self, SEL _cmd) {
    WolFoxHLSScrubPaused = NO;
    ((void (*)(id, SEL))WolFoxHLSOrigPlay)(self, _cmd);
}

static void WolFoxHLSPause(id self, SEL _cmd, int reason) {
    if (WolFoxHLSInScrubStart) WolFoxHLSScrubPaused = YES;
    ((void (*)(id, SEL, int))WolFoxHLSOrigPause)(self, _cmd, reason);
}

void WolFoxInstallHLSPlaybackHooks(void) {
    if (!WolFoxHLSEnabled()) return;
    WolFoxDownloadLog(@"hls", @"enabled");
    WolFoxHLSCache = [NSMutableDictionary dictionary];
    WolFoxHLSPending = [NSMutableDictionary dictionary];
    WolFoxHLSOriginals = [NSMutableDictionary dictionary];
    WolFoxHLSSources = [NSMutableDictionary dictionary];
    WolFoxHLSFallbacks = [NSMutableSet set];
    NSString *response = @"YTPlayerResponse";
    WolFoxInstallInstanceHook(response,
        @"initWithPlayerData:responseDate:offlineStateDate:mutableState:trailer:QOEController:cacheKey:cacheContext:latencyLogger:offlineRentalActivated:",
        (IMP)WolFoxHLSInitFull, &WolFoxHLSOrigInitFull);
    WolFoxInstallInstanceHook(response,
        @"initWithPlayerData:responseDate:offlineStateDate:mutableState:trailer:",
        (IMP)WolFoxHLSInitShort, &WolFoxHLSOrigInitShort);
    WolFoxInstallInstanceHook(response,
        @"initWithPlayerData:responseDate:offlineStateDate:mutableState:trailer:offlineRentalActivated:",
        (IMP)WolFoxHLSInitRental, &WolFoxHLSOrigInitRental);
    WolFoxInstallInstanceHook(@"MLHLSMasterPlaylistParser", @"parseFromString:error:",
        (IMP)WolFoxHLSParseString, &WolFoxHLSOrigParseString);
    WolFoxInstallInstanceHook(@"MLAVPlayer", @"setVideoFormatConstraint:",
        (IMP)WolFoxHLSSetConstraint, &WolFoxHLSOrigSetConstraint);
    WolFoxInstallInstanceHook(@"MLAVPlayer", @"play", (IMP)WolFoxHLSPlay, &WolFoxHLSOrigPlay);
    WolFoxInstallInstanceHook(@"MLAVPlayer", @"pauseWithStoppageReason:",
        (IMP)WolFoxHLSPause, &WolFoxHLSOrigPause);
    WolFoxInstallInstanceHook(@"YTMainAppVideoPlayerOverlayViewController",
        @"didStartPlayerBarScrubbingWithGestureOriginatingInPlayerBar:",
        (IMP)WolFoxHLSScrubStart, &WolFoxHLSOrigScrubStart);
    WolFoxInstallInstanceHook(@"YTMainAppVideoPlayerOverlayViewController",
        @"didEndPlayerBarScrubbingWithGestureOriginatingInPlayerBar:withSeekCancelled:seekSource:",
        (IMP)WolFoxHLSScrubEnd, &WolFoxHLSOrigScrubEnd);
}
