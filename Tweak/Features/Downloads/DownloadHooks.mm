#import "../Interface/AiSList.h"
#import "DownloadCoordinator.h"
#import "DownloadLog.h"
#import "SABRDownloader.h"
#import "StreamResolver.h"
#import "../../WolFox.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"
#import "../../UI/Notice.h"
#import "../../Runtime/Localization.h"
#import "../../UI/OverlayButtonHost.h"
#import "../../UI/Assets.h"
#import <objc/message.h>
#import <objc/runtime.h>

UIImage *WolFoxDownloadGlyphImage(void) {
    UIImageSymbolConfiguration *configuration =
        [UIImageSymbolConfiguration configurationWithPointSize:22.0
                                                        weight:UIImageSymbolWeightMedium];
    UIImage *image = [WolFoxDownloadTabImage(NO)
        imageByApplyingSymbolConfiguration:configuration];
    return [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

static IMP OriginalSetPlayerResponse;
static IMP OriginalSetPoToken;
static IMP OriginalMintWithVideoID;
static IMP OriginalMakePlayerRequest;
static IMP OriginalMakePlaybackRequest;
static IMP OriginalMakePrefetchPlayerRequest;
static IMP OriginalFactoryRequest;
static IMP OriginalFactoryRequestExtended;
static IMP OriginalOnesieRequest;
static IMP OriginalOnesieRequestAsync;
static IMP OriginalOnesieRequestCompletion;
static IMP OriginalHAMBuildURLRequest;
static id WolFoxLastPlayerService;
static id WolFoxLastPlayerRequest;
static id WolFoxLastPlaybackRequest;
static id WolFoxLastPlayerFactory;
static id WolFoxLastRequestProperties;
static NSMutableDictionary<NSString *, NSArray *> *WolFoxPlayerRequests;
static NSMutableDictionary<NSString *, id> *WolFoxPlaybackRequests;
static NSInteger WolFoxPlayerHookAttempts;
static NSString *WolFoxLastCapturedVideoID;
id WolFoxLatestPlayerAuthorization;

NSString *WolFoxLastVideoID(void) {
    return [WolFoxLastCapturedVideoID copy];
}
static NSString *WolFoxRequestVideoID(id request);
static void WolFoxPersistPlayerRequest(id request);
static BOOL WolFoxUsingRestoredRequest;
static id WolFoxCopyObject(id object);

static NSURLRequest *WolFoxURLRequestFromObject(id object) {
    if ([object isKindOfClass:NSURLRequest.class]) return object;
    SEL builder = NSSelectorFromString(@"buildURLRequest");
    if ([object respondsToSelector:builder]) {
        id result = ((id (*)(id, SEL))objc_msgSend)(object, builder);
        if ([result isKindOfClass:NSURLRequest.class]) return result;
    }
    return nil;
}

@interface WolFoxOnesieSessionState : NSObject
@property(nonatomic, strong) id factory;
@property(nonatomic, strong) id playerRequest;
@property(nonatomic, strong, nullable) id authorization;
@property(nonatomic, strong) id dataLoader;
@property(nonatomic, strong) id context;
@property(nonatomic, strong) id cryptor;
@property(nonatomic, copy) NSString *videoID;
@property(nonatomic, assign) NSInteger observedRequestNumber;
@property(nonatomic, assign) NSInteger nextRequestNumber;
@property(nonatomic, assign) BOOL asynchronous;
@property(nonatomic, strong) NSDate *capturedAt;
@end

@implementation WolFoxOnesieSessionState
@end

static NSMutableDictionary<NSString *, WolFoxOnesieSessionState *> *
    WolFoxOnesieSessions;
static WolFoxOnesieSessionState *WolFoxLastOnesieSession;

static void WolFoxPruneOnesieSessions(void) {
    NSDate *cutoff = [NSDate dateWithTimeIntervalSinceNow:-900.0];
    NSMutableArray<NSString *> *expired = [NSMutableArray array];
    for (NSString *key in WolFoxOnesieSessions) {
        WolFoxOnesieSessionState *state = WolFoxOnesieSessions[key];
        if ([state.capturedAt compare:cutoff] == NSOrderedAscending) {
            [expired addObject:key];
        }
    }
    [WolFoxOnesieSessions removeObjectsForKeys:expired];
    if (WolFoxOnesieSessions.count <= 16) return;
    NSArray<NSString *> *keys = [WolFoxOnesieSessions keysSortedByValueUsingComparator:
        ^NSComparisonResult(WolFoxOnesieSessionState *left,
                            WolFoxOnesieSessionState *right) {
            return [left.capturedAt compare:right.capturedAt];
        }];
    NSUInteger removeCount = WolFoxOnesieSessions.count - 16;
    [WolFoxOnesieSessions removeObjectsForKeys:
        [keys subarrayWithRange:NSMakeRange(0, removeCount)]];
}

static void WolFoxCaptureOnesieSession(id factory,
                                       id playerRequest,
                                       id authorization,
                                       id dataLoader,
                                       id context,
                                       id cryptor,
                                       NSInteger requestNumber,
                                       BOOL asynchronous) {
    if (factory == nil || playerRequest == nil || dataLoader == nil ||
        context == nil || cryptor == nil) {
        return;
    }
    NSString *videoID = WolFoxRequestVideoID(playerRequest);
    if (videoID.length == 0) videoID = WolFoxLastCapturedVideoID;
    WolFoxOnesieSessionState *state = [WolFoxOnesieSessionState new];
    state.factory = factory;
    state.playerRequest = WolFoxCopyObject(playerRequest);
    state.authorization = WolFoxCopyObject(authorization);
    if (authorization != nil) WolFoxLatestPlayerAuthorization = authorization;
    state.dataLoader = dataLoader;
    state.context = context;
    state.cryptor = cryptor;
    state.videoID = videoID ?: @"";
    state.observedRequestNumber = requestNumber;
    state.nextRequestNumber = requestNumber + 1;
    state.asynchronous = asynchronous;
    state.capturedAt = NSDate.date;
    @synchronized (WolFoxSABRDownloader.class) {
        if (WolFoxOnesieSessions == nil) {
            WolFoxOnesieSessions = [NSMutableDictionary dictionary];
        }
        WolFoxLastOnesieSession = state;
        if (videoID.length != 0) WolFoxOnesieSessions[videoID] = state;
        WolFoxPruneOnesieSessions();
    }
}

static WolFoxOnesieSessionState *WolFoxOnesieSessionForVideo(
    NSString *videoID) {
    @synchronized (WolFoxSABRDownloader.class) {
        WolFoxPruneOnesieSessions();
        WolFoxOnesieSessionState *state = WolFoxOnesieSessions[videoID];
        if (state != nil) return state;
        if (WolFoxLastOnesieSession.videoID.length == 0 ||
            [WolFoxLastOnesieSession.videoID isEqualToString:videoID]) {
            return WolFoxLastOnesieSession;
        }
        return nil;
    }
}

BOOL WolFoxHasNativeOnesieSession(NSString *videoID) {
    return WolFoxOnesieSessionForVideo(videoID) != nil;
}

void WolFoxBuildNativeOnesieRequest(
    NSString *videoID,
    WolFoxNativeRequestCompletion completion) {
    WolFoxOnesieSessionState *state = WolFoxOnesieSessionForVideo(videoID);
    if (state == nil) {
        completion(nil, NSNotFound, [NSError errorWithDomain:@"WolFoxOnesie"
            code:1 userInfo:@{NSLocalizedDescriptionKey:
                @"No native Onesie session is available."}]);
        return;
    }
    NSInteger requestNumber = 0;
    @synchronized (WolFoxSABRDownloader.class) {
        requestNumber = MAX(state.nextRequestNumber,
            state.observedRequestNumber + 1);
        state.nextRequestNumber = requestNumber + 1;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        if (state.asynchronous && OriginalOnesieRequestAsync != NULL) {
            void (^nativeCompletion)(id, NSError *) = ^(id result, NSError *error) {
                NSURLRequest *request = WolFoxURLRequestFromObject(result);
                if (request != nil) WolFoxSABRSetNativeRequest(request);
                completion(request, requestNumber, error);
            };
            ((void (*)(id, SEL, id, id, id, id, id, NSInteger, id))
                OriginalOnesieRequestAsync)(
                    state.factory,
                    NSSelectorFromString(
                        @"onesieRequestForPlayerRequest:authorization:dataLoader:"
                         "context:cryptor:requestNumber:completionHandler:"),
                    WolFoxCopyObject(state.playerRequest), state.authorization,
                    state.dataLoader, state.context, state.cryptor,
                    requestNumber, nativeCompletion);
            return;
        }
        if (OriginalOnesieRequest != NULL) {
            NSError *error = nil;
            id result = ((id (*)(id, SEL, id, id, id, id, NSInteger, NSError **))
                OriginalOnesieRequest)(
                    state.factory,
                    NSSelectorFromString(
                        @"onesieRequestForPlayerRequest:dataLoader:context:"
                         "cryptor:requestNumber:error:"),
                    WolFoxCopyObject(state.playerRequest), state.dataLoader,
                    state.context, state.cryptor, requestNumber, &error);
            NSURLRequest *request = WolFoxURLRequestFromObject(result);
            if (request != nil) WolFoxSABRSetNativeRequest(request);
            completion(request, requestNumber, error);
            return;
        }
        completion(nil, requestNumber, [NSError errorWithDomain:@"WolFoxOnesie"
            code:2 userInfo:@{NSLocalizedDescriptionKey:
                @"YouTube's native Onesie factory is unavailable."}]);
    });
}

static id WolFoxOnesieRequest(id receiver,
                              SEL selector,
                              id playerRequest,
                              id dataLoader,
                              id context,
                              id cryptor,
                              NSInteger requestNumber,
                              NSError **error) {
    if (WolFoxPlaybackFixMode() == 2) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:@"WolFoxHLS" code:1
                userInfo:@{NSLocalizedDescriptionKey: @"Onesie is off for HLS streams."}];
        }
        return nil;
    }
    id result = OriginalOnesieRequest != NULL
        ? ((id (*)(id, SEL, id, id, id, id, NSInteger, NSError **))OriginalOnesieRequest)(
            receiver, selector, playerRequest, dataLoader, context, cryptor,
            requestNumber, error)
        : nil;
    NSURLRequest *builtRequest = WolFoxURLRequestFromObject(result);
    if (builtRequest != nil) {
        NSURLRequest *request = builtRequest;
        WolFoxSABRSetNativeRequest(request);
    }
    WolFoxCaptureOnesieSession(receiver, playerRequest, nil, dataLoader,
        context, cryptor, requestNumber, NO);
    return result;
}

static void WolFoxOnesieRequestAsync(id receiver,
                                     SEL selector,
                                     id playerRequest,
                                     id authorization,
                                     id dataLoader,
                                     id context,
                                     id cryptor,
                                     NSInteger requestNumber,
                                     void (^completion)(id, NSError *)) {
    if (WolFoxPlaybackFixMode() == 2) {
        if (completion != nil) {
            completion(nil, [NSError errorWithDomain:@"WolFoxHLS" code:1
                userInfo:@{NSLocalizedDescriptionKey: @"Onesie is off for HLS streams."}]);
        }
        return;
    }
    void (^wrapped)(id, NSError *) = ^(id result, NSError *error) {
        NSURLRequest *builtRequest = WolFoxURLRequestFromObject(result);
        if (builtRequest != nil) {
            NSURLRequest *request = builtRequest;
            WolFoxSABRSetNativeRequest(request);
        }
        WolFoxCaptureOnesieSession(receiver, playerRequest, authorization,
            dataLoader, context, cryptor, requestNumber, YES);
        if (completion != nil) completion(result, error);
    };
    if (OriginalOnesieRequestAsync != NULL) {
        ((void (*)(id, SEL, id, id, id, id, id, NSInteger, id))OriginalOnesieRequestAsync)(
            receiver, selector, playerRequest, authorization, dataLoader, context,
            cryptor, requestNumber, wrapped);
    }
}

static void WolFoxOnesieRequestCompletion(id receiver,
                                          SEL selector,
                                          id request,
                                          id error) {
    NSURLRequest *builtRequest = WolFoxURLRequestFromObject(request);
    if (builtRequest != nil) {
        NSURLRequest *URLRequest = builtRequest;
        WolFoxSABRSetNativeRequest(URLRequest);
    }
    if (OriginalOnesieRequestCompletion != NULL) {
        ((void (*)(id, SEL, id, id))OriginalOnesieRequestCompletion)(
            receiver, selector, request, error);
    }
}

static id WolFoxHAMBuildURLRequest(id receiver, SEL selector) {
    id result = OriginalHAMBuildURLRequest != NULL
        ? ((id (*)(id, SEL))OriginalHAMBuildURLRequest)(receiver, selector)
        : nil;
    if ([result isKindOfClass:NSURLRequest.class]) {
        NSURLRequest *request = result;
        NSString *host = request.URL.host.lowercaseString;
        if ([host containsString:@"googlevideo.com"] &&
            [request.HTTPMethod.uppercaseString isEqualToString:@"POST"]) {
            NSData *rawBody = nil;
            SEL bodySelector = NSSelectorFromString(@"HTTPBody");
            if ([receiver respondsToSelector:bodySelector]) {
                rawBody = ((id (*)(id, SEL))objc_msgSend)(receiver, bodySelector);
            }
            NSMutableURLRequest *nativeRequest = [request mutableCopy];
            if ([rawBody isKindOfClass:NSData.class] && rawBody.length != 0) {
                nativeRequest.HTTPBody = rawBody;
                [nativeRequest setValue:nil forHTTPHeaderField:@"Content-Encoding"];
            }
            WolFoxSABRSetNativeRequest(nativeRequest);
        }
    }
    return result;
}

static id WolFoxGetValue(id object, NSArray<NSString *> *keys) {
    if (object == nil) return nil;
    for (NSString *key in keys) {
        SEL selector = NSSelectorFromString(key);
        if ([object respondsToSelector:selector]) {
            id value = ((id (*)(id, SEL))objc_msgSend)(object, selector);
            if (value != nil) return value;
        }
        @try {
            id value = [object valueForKey:key];
            if (value != nil) return value;
        } @catch (__unused NSException *exception) {
        }
    }
    return nil;
}

static BOOL WolFoxSetValue(id object, NSString *key, id value) {
    if (object == nil || key.length == 0) return NO;
    NSString *first = [[key substringToIndex:1] uppercaseString];
    NSString *setterName = [NSString stringWithFormat:@"set%@%@:", first,
        [key substringFromIndex:1]];
    SEL setter = NSSelectorFromString(setterName);
    if ([object respondsToSelector:setter]) {
        ((void (*)(id, SEL, id))objc_msgSend)(object, setter, value);
        return YES;
    }
    @try {
        [object setValue:value forKey:key];
        return YES;
    } @catch (__unused NSException *exception) {
        return NO;
    }
}

static id WolFoxCopyObject(id object) {
    if ([object respondsToSelector:@selector(copyWithZone:)]) {
        return [object copy];
    }
    return object;
}

static NSString *WolFoxRequestVideoID(id request) {
    id value = WolFoxGetValue(request, @[@"videoId", @"videoID", @"videoIdString"]);
    return [value isKindOfClass:NSString.class] ? value : nil;
}

static void WolFoxCaptureService(id receiver, id request) {
    NSString *videoID = WolFoxRequestVideoID(request);
    if (videoID.length != 0) WolFoxLastCapturedVideoID = videoID;
    WolFoxSABRSetCurrentVideoID(videoID);
    id requestCopy = WolFoxCopyObject(request);
    @synchronized (WolFoxSABRDownloader.class) {
        WolFoxLastPlayerService = receiver;
        WolFoxLastPlayerRequest = requestCopy;
        WolFoxUsingRestoredRequest = NO;
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
            WolFoxPersistPlayerRequest(requestCopy ?: request);
        });
        if (WolFoxPlayerRequests == nil) WolFoxPlayerRequests = [NSMutableDictionary dictionary];
        if (videoID.length != 0) {
            WolFoxPlayerRequests[videoID] = @[receiver, requestCopy ?: request];
        }
    }
}

static NSMutableDictionary<NSString *, id> *WolFoxPlayerResponses;
static NSMutableArray<NSString *> *WolFoxPlayerResponseOrder;

static NSString *WolFoxResponseVideoID(id response) {
    if (response == nil) return nil;
    id details = WolFoxGetValue(response, @[@"videoDetails"]);
    id value = WolFoxGetValue(details != nil ? details : response,
                              @[@"videoId", @"videoID", @"videoIdString"]);
    return [value isKindOfClass:NSString.class] ? value : nil;
}

__attribute__((unused))
static void WolFoxReportStreamingData(id response) {
    static NSUInteger logged = 0;
    if (response == nil || logged >= 2) return;
    SEL selector = NSSelectorFromString(@"streamingData");
    if (![response respondsToSelector:selector]) {
        WolFoxDownloadLog(@"spoof", @"player response has no streamingData (%@)",
                          NSStringFromClass([response class]));
        logged++;
        return;
    }
    id streaming = ((id (*)(id, SEL))objc_msgSend)(response, selector);
    if (streaming == nil) {
        WolFoxDownloadLog(@"spoof", @"player response streamingData nil");
        logged++;
        return;
    }
    logged++;
    NSString *text = [[streaming description]
        stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
    while ([text containsString:@"  "]) {
        text = [text stringByReplacingOccurrencesOfString:@"  " withString:@" "];
    }
    const NSUInteger limit = 1500;
    for (NSUInteger offset = 0; offset < text.length && offset < limit * 3;
         offset += limit) {
        const NSUInteger length = MIN(limit, text.length - offset);
        WolFoxDownloadLog(@"spoof", @"streaming[%lu] %@",
                          (unsigned long)(offset / limit),
                          [text substringWithRange:NSMakeRange(offset, length)]);
    }
}

static void WolFoxCachePlayerResponse(id response) {
    if (response == nil) return;
    NSString *videoID =
        [WolFoxStreamResolver videoIDFromPlayerResponse:response];
    if (videoID.length == 0) videoID = WolFoxResponseVideoID(response);
    if (videoID.length == 0) return;
    @synchronized (WolFoxSABRDownloader.class) {
        if (WolFoxPlayerResponses == nil) {
            WolFoxPlayerResponses = [NSMutableDictionary dictionary];
            WolFoxPlayerResponseOrder = [NSMutableArray array];
        }
        if (WolFoxPlayerResponses[videoID] == nil) {
            [WolFoxPlayerResponseOrder addObject:videoID];
        }
        WolFoxPlayerResponses[videoID] = response;
        while (WolFoxPlayerResponseOrder.count > 8) {
            NSString *oldest = WolFoxPlayerResponseOrder.firstObject;
            [WolFoxPlayerResponseOrder removeObjectAtIndex:0];
            [WolFoxPlayerResponses removeObjectForKey:oldest];
        }
    }
}

void WolFoxStorePlayerResponse(NSString *videoID, id response) {
    if (videoID.length == 0 || response == nil) return;
    @synchronized (WolFoxSABRDownloader.class) {
        if (WolFoxPlayerResponses == nil) {
            WolFoxPlayerResponses = [NSMutableDictionary dictionary];
            WolFoxPlayerResponseOrder = [NSMutableArray array];
        }
        if (WolFoxPlayerResponses[videoID] == nil) {
            [WolFoxPlayerResponseOrder addObject:videoID];
        }
        WolFoxPlayerResponses[videoID] = response;
        while (WolFoxPlayerResponseOrder.count > 8) {
            NSString *oldest = WolFoxPlayerResponseOrder.firstObject;
            [WolFoxPlayerResponseOrder removeObjectAtIndex:0];
            [WolFoxPlayerResponses removeObjectForKey:oldest];
        }
    }
}

id WolFoxCachedPlayerResponse(NSString *videoID) {
    if (videoID.length == 0) return nil;
    id original = WolFoxHLSOriginalResponse(videoID);
    if (original != nil) return original;
    @synchronized (WolFoxSABRDownloader.class) {
        return WolFoxPlayerResponses[videoID];
    }
}

static id WolFoxObservedResponseBlock(id responseBlock) {
    if (responseBlock == nil) return nil;
    void (^original)(id, void *) = responseBlock;
    return [^(id playerResponse, void *cacheContext) {
        WolFoxCachePlayerResponse(playerResponse);
        original(playerResponse, cacheContext);
    } copy];
}

static void WolFoxMakePlayerRequest(id receiver,
                                    SEL selector,
                                    id request,
                                    id responseBlock,
                                    id errorBlock) {
    WolFoxCaptureService(receiver, request);
    if (OriginalMakePlayerRequest != NULL) {
        ((void (*)(id, SEL, id, id, id))OriginalMakePlayerRequest)(
            receiver, selector, request,
            WolFoxObservedResponseBlock(responseBlock), errorBlock
        );
    }
}

static id WolFoxMakePlaybackRequest(id receiver,
                                    SEL selector,
                                    id request,
                                    id responseBlock,
                                    id errorBlock) {
    WolFoxCaptureService(receiver, request);
    @synchronized (WolFoxSABRDownloader.class) {
        WolFoxLastPlaybackRequest = WolFoxCopyObject(request);
        NSString *videoID = WolFoxRequestVideoID(request);
        if (WolFoxPlaybackRequests == nil) {
            WolFoxPlaybackRequests = [NSMutableDictionary dictionary];
        }
        if (videoID.length != 0) {
            WolFoxPlaybackRequests[videoID] = WolFoxCopyObject(request);
        }
    }
    return OriginalMakePlaybackRequest != NULL
        ? ((id (*)(id, SEL, id, id, id))OriginalMakePlaybackRequest)(
            receiver, selector, request,
            WolFoxObservedResponseBlock(responseBlock), errorBlock)
        : nil;
}

static void WolFoxMakePrefetchPlayerRequest(id receiver,
                                            SEL selector,
                                            id request,
                                            id responseBlock,
                                            id errorBlock) {
    WolFoxCaptureService(receiver, request);
    if (OriginalMakePrefetchPlayerRequest != NULL) {
        ((void (*)(id, SEL, id, id, id))OriginalMakePrefetchPlayerRequest)(
            receiver, selector, request, responseBlock, errorBlock
        );
    }
}

static void WolFoxCaptureFactory(id receiver, id request, id properties, id result) {
    NSString *videoID = WolFoxRequestVideoID(request);
    if (videoID.length != 0) WolFoxLastCapturedVideoID = videoID;
    WolFoxSABRSetCurrentVideoID(videoID);
    @synchronized (WolFoxSABRDownloader.class) {
        WolFoxLastPlayerFactory = receiver;
        WolFoxLastPlayerRequest = WolFoxCopyObject(request);
        WolFoxUsingRestoredRequest = NO;
        id persistCopy = WolFoxLastPlayerRequest;
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
            WolFoxPersistPlayerRequest(persistCopy);
        });
        WolFoxLastRequestProperties = properties;
        if (videoID.length != 0 && WolFoxLastPlayerService != nil) {
            if (WolFoxPlayerRequests == nil) {
                WolFoxPlayerRequests = [NSMutableDictionary dictionary];
            }
            WolFoxPlayerRequests[videoID] = @[
                WolFoxLastPlayerService, WolFoxCopyObject(request)
            ];
            if (WolFoxLastPlaybackRequest != nil) {
                if (WolFoxPlaybackRequests == nil) {
                    WolFoxPlaybackRequests = [NSMutableDictionary dictionary];
                }
                WolFoxPlaybackRequests[videoID] =
                    WolFoxCopyObject(WolFoxLastPlaybackRequest);
            }
        }
    }
    static BOOL dumped = YES;
    if (!dumped) {
        dumped = YES;
        for (NSArray *pair in @[@[@"request", request ?: [NSNull null]],
                                @[@"result", result ?: [NSNull null]]]) {
            id value = pair[1];
            if (value == [NSNull null]) continue;
            NSString *text = [[value description]
                stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
            while ([text containsString:@"  "]) {
                text = [text stringByReplacingOccurrencesOfString:@"  "
                                                       withString:@" "];
            }
            const NSUInteger limit = 1800;
            for (NSUInteger offset = 0; offset < text.length && offset < limit * 3;
                 offset += limit) {
                const NSUInteger length = MIN(limit, text.length - offset);
                WolFoxDownloadLog(@"spoof", @"%@[%lu] %@", pair[0],
                                  (unsigned long)(offset / limit),
                                  [text substringWithRange:NSMakeRange(offset, length)]);
            }
        }
    }
}

static id WolFoxFactoryRequest(id receiver, SEL selector, id request, id properties) {
    WolFoxSABRSetCurrentVideoID(WolFoxRequestVideoID(request));
    id result = OriginalFactoryRequest != NULL
        ? ((id (*)(id, SEL, id, id))OriginalFactoryRequest)(receiver, selector, request, properties)
        : nil;
    WolFoxCaptureFactory(receiver, request, properties, result);
    return result;
}

static id WolFoxFactoryRequestExtended(id receiver,
                                       SEL selector,
                                       id request,
                                       id properties,
                                       BOOL relaxation,
                                       id cacheToken,
                                       BOOL skipCache) {
    WolFoxSABRSetCurrentVideoID(WolFoxRequestVideoID(request));
    id result = OriginalFactoryRequestExtended != NULL
        ? ((id (*)(id, SEL, id, id, BOOL, id, BOOL))OriginalFactoryRequestExtended)(
            receiver, selector, request, properties, relaxation, cacheToken, skipCache)
        : nil;
    WolFoxCaptureFactory(receiver, request, properties, result);
    return result;
}

static id WolFoxLastInnerTubeContext;
static IMP OriginalContextShort;
static IMP OriginalContextMedium;
static IMP OriginalContextLong;

static void WolFoxCaptureContext(id context) {
    if (context == nil) return;
    @synchronized (WolFoxSABRDownloader.class) {
        if (WolFoxLastInnerTubeContext == nil) {
        }
        WolFoxLastInnerTubeContext = context;
    }
}

static id WolFoxContextShort(id receiver, SEL selector, id pageID,
                             BOOL incognito, int criticality, id tracking,
                             BOOL sendIdentifier, long long serviceType) {
    id result = OriginalContextShort == NULL ? nil :
        ((id (*)(id, SEL, id, BOOL, int, id, BOOL, long long))OriginalContextShort)(
            receiver, selector, pageID, incognito, criticality, tracking,
            sendIdentifier, serviceType);
    WolFoxCaptureContext(result);
    return result;
}

static id WolFoxContextMedium(id receiver, SEL selector, id pageID,
                              BOOL incognito, int criticality, id tracking,
                              BOOL sendIdentifier, id nonce, id jars,
                              id attestation, long long serviceType) {
    id result = OriginalContextMedium == NULL ? nil :
        ((id (*)(id, SEL, id, BOOL, int, id, BOOL, id, id, id, long long))
            OriginalContextMedium)(receiver, selector, pageID, incognito,
                criticality, tracking, sendIdentifier, nonce, jars,
                attestation, serviceType);
    WolFoxCaptureContext(result);
    return result;
}

static id WolFoxContextLong(id receiver, SEL selector, id pageID,
                            BOOL incognito, int criticality, id tracking,
                            BOOL sendIdentifier, id nonce, id jars,
                            id attestation, id reauth, long long serviceType,
                            BOOL isPrefetch) {
    id result = OriginalContextLong == NULL ? nil :
        ((id (*)(id, SEL, id, BOOL, int, id, BOOL, id, id, id, id, long long, BOOL))
            OriginalContextLong)(receiver, selector, pageID, incognito,
                criticality, tracking, sendIdentifier, nonce, jars, attestation,
                reauth, serviceType, isPrefetch);
    WolFoxCaptureContext(result);
    return result;
}

static IMP OriginalPlayerServiceInit;

static id WolFoxPlayerServiceInit(id receiver, SEL selector) {
    id result = OriginalPlayerServiceInit == NULL ? receiver :
        ((id (*)(id, SEL))OriginalPlayerServiceInit)(receiver, selector);
    if (result != nil) {
        @synchronized (WolFoxSABRDownloader.class) {
            if (WolFoxLastPlayerService == nil) {
                WolFoxLastPlayerService = result;
            }
        }
    }
    return result;
}

static void WolFoxInstallPlayerServiceHook(void) {
    WolFoxInstallInstanceHook(@"YTPlayerService", @"init",
                              (IMP)WolFoxPlayerServiceInit,
                              &OriginalPlayerServiceInit);
    WolFoxInstallInstanceHook(@"YTAccountScopedInnerTubeContextFactory",
        @"contextWithPageID:isIncognitoActive:criticality:clickTrackingInfo:sendDeviceIdentifier:serviceType:",
        (IMP)WolFoxContextShort, &OriginalContextShort);
    WolFoxInstallInstanceHook(@"YTAccountScopedInnerTubeContextFactory",
        @"contextWithPageID:isIncognitoActive:criticality:clickTrackingInfo:sendDeviceIdentifier:clientScreenNonce:consistencyTokenJars:attestationResponseData:serviceType:",
        (IMP)WolFoxContextMedium, &OriginalContextMedium);
    WolFoxInstallInstanceHook(@"YTAccountScopedInnerTubeContextFactory",
        @"contextWithPageID:isIncognitoActive:criticality:clickTrackingInfo:sendDeviceIdentifier:clientScreenNonce:consistencyTokenJars:attestationResponseData:reauthProofToken:serviceType:isPrefetch:",
        (IMP)WolFoxContextLong, &OriginalContextLong);
    BOOL serviceInstalled = WolFoxInstallInstanceHook(
        @"YTPlayerService",
        @"makePlayerRequest:responseBlock:errorBlock:",
        (IMP)WolFoxMakePlayerRequest,
        &OriginalMakePlayerRequest
    );
    BOOL playbackInstalled = WolFoxInstallInstanceHook(
        @"YTPlayerService",
        @"makePlaybackRequest:responseBlock:errorBlock:",
        (IMP)WolFoxMakePlaybackRequest,
        &OriginalMakePlaybackRequest
    );
    BOOL prefetchInstalled = WolFoxInstallInstanceHook(
        @"YTPlayerService",
        @"makePrefetchPlayerRequest:responseBlock:errorBlock:",
        (IMP)WolFoxMakePrefetchPlayerRequest,
        &OriginalMakePrefetchPlayerRequest
    );
    BOOL factoryInstalled = WolFoxInstallInstanceHook(
        @"YTPlayerRequestFactoryImpl",
        @"requestForPlayerWithPlayerRequest:URLRequestProperties:",
        (IMP)WolFoxFactoryRequest,
        &OriginalFactoryRequest
    );
    BOOL extendedInstalled = WolFoxInstallInstanceHook(
        @"YTPlayerRequestFactoryImpl",
        @"requestForPlayerWithPlayerRequest:URLRequestProperties:enablePlayerResponseCacheKeyRelaxation:playerResponseCacheToken:skipInnertubeCacheLookup:",
        (IMP)WolFoxFactoryRequestExtended,
        &OriginalFactoryRequestExtended
    );
    BOOL onesieInstalled = WolFoxInstallInstanceHook(
        @"MLOnesieRequestFactory",
        @"onesieRequestForPlayerRequest:dataLoader:context:cryptor:requestNumber:error:",
        (IMP)WolFoxOnesieRequest,
        &OriginalOnesieRequest
    );
    BOOL onesieAsyncInstalled = WolFoxInstallInstanceHook(
        @"MLOnesieRequestFactory",
        @"onesieRequestForPlayerRequest:authorization:dataLoader:context:cryptor:requestNumber:completionHandler:",
        (IMP)WolFoxOnesieRequestAsync,
        &OriginalOnesieRequestAsync
    );
    BOOL onesieCompletionInstalled = WolFoxInstallInstanceHook(
        @"MLOnesieUMPFetcherTask",
        @"onRequestFactoryCompletionWithRequest:error:",
        (IMP)WolFoxOnesieRequestCompletion,
        &OriginalOnesieRequestCompletion
    );
    BOOL HAMRequestInstalled = WolFoxInstallInstanceHook(
        @"HAMDataLoadRequest",
        @"buildURLRequest",
        (IMP)WolFoxHAMBuildURLRequest,
        &OriginalHAMBuildURLRequest
    );
    if (serviceInstalled && playbackInstalled && prefetchInstalled &&
        factoryInstalled && extendedInstalled && onesieInstalled &&
        onesieAsyncInstalled && onesieCompletionInstalled && HAMRequestInstalled) {
        WolFoxDownloadLog(@"reload", @"player path hooked");
        return;
    }
    WolFoxPlayerHookAttempts += 1;
    if (WolFoxPlayerHookAttempts >= 30) {
        WolFoxDownloadLog(@"reload", @"player path unavailable service=%d playback=%d prefetch=%d factory=%d extended=%d onesie=%d async=%d completion=%d ham=%d",
            serviceInstalled, playbackInstalled, prefetchInstalled,
            factoryInstalled, extendedInstalled, onesieInstalled,
            onesieAsyncInstalled, onesieCompletionInstalled, HAMRequestInstalled);
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)NSEC_PER_SEC),
        dispatch_get_main_queue(), ^{ WolFoxInstallPlayerServiceHook(); });
}

void WolFoxPreparePlayerWithRoute(NSString *videoID,
                                  BOOL forcePlayerRoute,
                                  WolFoxPlayerReloadCompletion completion) {
    id service = nil;
    id request = nil;
    id playbackRequest = nil;
    @synchronized (WolFoxSABRDownloader.class) {
        NSArray *pair = WolFoxPlayerRequests[videoID];
        service = pair.count > 0 ? pair[0] : nil;
        request = pair.count > 1 ? pair[1] : nil;
        playbackRequest = WolFoxPlaybackRequests[videoID];
        if (service == nil &&
            [WolFoxRequestVideoID(WolFoxLastPlayerRequest) isEqualToString:videoID]) {
            service = WolFoxLastPlayerService;
            request = WolFoxLastPlayerRequest;
            playbackRequest = WolFoxLastPlaybackRequest;
        }
    }
    if (service == nil || request == nil) {
        NSError *error = [NSError errorWithDomain:@"WolFoxPlayerPrepare" code:1
            userInfo:@{NSLocalizedDescriptionKey:
                @"YouTube has not created a player request for this video."}];
        completion(nil, error);
        return;
    }
    if (forcePlayerRoute) playbackRequest = nil;
    WolFoxSABRSetCurrentVideoID(videoID);
    WolFoxDownloadLog(@"prepare", @"native request video=%@ route=%@", videoID,
        playbackRequest != nil && OriginalMakePlaybackRequest != NULL
            ? @"playback" : @"player");
    dispatch_async(dispatch_get_main_queue(), ^{
        void (^response)(id, id) = ^(id playerResponse, __unused id cacheContext) {
            completion(WolFoxHLSOriginalResponse(videoID) ?: playerResponse, nil);
        };
        void (^failure)(NSError *) = ^(NSError *error) {
            completion(nil, error);
        };
        if (playbackRequest != nil && OriginalMakePlaybackRequest != NULL) {
            ((id (*)(id, SEL, id, id, id))OriginalMakePlaybackRequest)(
                service,
                NSSelectorFromString(@"makePlaybackRequest:responseBlock:errorBlock:"),
                WolFoxCopyObject(playbackRequest), response, failure);
        } else if (OriginalMakePlayerRequest != NULL) {
            ((void (*)(id, SEL, id, id, id))OriginalMakePlayerRequest)(
                service,
                NSSelectorFromString(@"makePlayerRequest:responseBlock:errorBlock:"),
                WolFoxCopyObject(request), response, failure);
        } else {
            NSError *error = [NSError errorWithDomain:@"WolFoxPlayerPrepare" code:2
                userInfo:@{NSLocalizedDescriptionKey:
                    @"YouTube's player service is unavailable."}];
            completion(nil, error);
        }
    });
}

void WolFoxPreparePlayer(NSString *videoID,
                         WolFoxPlayerReloadCompletion completion) {
    WolFoxPreparePlayerWithRoute(videoID, NO, completion);
}

static NSURL *WolFoxRequestSeedURL(void) {
    return [WolFoxApplicationSupportDirectory()
        URLByAppendingPathComponent:@"player-request.pb"];
}

static void WolFoxPersistPlayerRequest(id request) {
    static NSTimeInterval lastWrite;
    NSTimeInterval now = NSDate.date.timeIntervalSinceReferenceDate;
    if (now - lastWrite < 60.0) return;
    if (![request respondsToSelector:NSSelectorFromString(@"data")]) {
        return;
    }
    NSData *encoded = ((id (*)(id, SEL))objc_msgSend)(
        request, NSSelectorFromString(@"data"));
    if (![encoded isKindOfClass:NSData.class] || encoded.length == 0) return;
    lastWrite = now;
    [encoded writeToURL:WolFoxRequestSeedURL() atomically:YES];
}

NSString *WolFoxPlayerOnBehalfOfUser(void) {
    id request = nil;
    @synchronized (WolFoxSABRDownloader.class) {
        request = WolFoxLastPlayerRequest;
    }
    if (request == nil) return nil;
    @try {
        id value = [request valueForKeyPath:@"context.user.onBehalfOfUser"];
        return [value isKindOfClass:NSString.class] && [value length] != 0 ? value : nil;
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

void WolFoxDiscardRestoredRequest(void) {
    BOOL restored = NO;
    @synchronized (WolFoxSABRDownloader.class) {
        restored = WolFoxUsingRestoredRequest;
        if (restored) {
            WolFoxLastPlayerRequest = nil;
            WolFoxUsingRestoredRequest = NO;
        }
    }
    if (!restored) return;
    [NSFileManager.defaultManager removeItemAtURL:WolFoxRequestSeedURL()
                                            error:NULL];
    WolFoxDownloadLog(@"resolve", @"discarded stale player request seed");
}

void WolFoxRestorePlayerRequest(void) {
    @synchronized (WolFoxSABRDownloader.class) {
        if (WolFoxLastPlayerRequest != nil) return;
    }
    NSData *encoded = [NSData dataWithContentsOfURL:WolFoxRequestSeedURL()];
    if (encoded.length == 0) return;
    Class requestClass = NSClassFromString(@"YTIPlayerRequest");
    SEL parse = NSSelectorFromString(@"parseFromData:error:");
    if (requestClass == Nil || ![requestClass respondsToSelector:parse]) return;
    NSError *error = nil;
    id restored = ((id (*)(id, SEL, id, NSError **))objc_msgSend)(
        requestClass, parse, encoded, &error);
    if (restored == nil) {
        WolFoxDownloadLog(@"resolve", @"request seed parse failed error=%@",
            error.localizedDescription ?: @"unknown");
        return;
    }
    @synchronized (WolFoxSABRDownloader.class) {
        WolFoxLastPlayerRequest = restored;
        WolFoxUsingRestoredRequest = YES;
    }
    WolFoxDownloadLog(@"resolve", @"restored player request bytes=%lu",
        (unsigned long)encoded.length);
}

static IMP OriginalOfflineVideoExecute;
static IMP OriginalOfflineVideoExecuteCompletion;

static __weak UIView *WolFoxMenuSourceView;

static void WolFoxCaptureMenuSource(id view) {
    if ([view isKindOfClass:UIView.class]) {
        WolFoxMenuSourceView = view;
    }
}

static IMP OriginalShowMenuCompletion;
static IMP OriginalShowMenuSkipCompletion;
static IMP OriginalActionsForRenderersLog;

static void WolFoxShowMenuCompletion(id receiver, SEL selector, id renderer,
                                     id view, id entry, id block, BOOL cancel,
                                     BOOL log, id responder, id completion) {
    WolFoxCaptureMenuSource(view);
    if (OriginalShowMenuCompletion == NULL) return;
    ((void (*)(id, SEL, id, id, id, id, BOOL, BOOL, id, id))
        OriginalShowMenuCompletion)(receiver, selector, renderer, view, entry,
                                    block, cancel, log, responder, completion);
}

static void WolFoxShowMenuSkipCompletion(id receiver, SEL selector, id renderer,
                                         id view, id entry, id block,
                                         BOOL cancel, BOOL log, BOOL skip,
                                         id responder, id completion) {
    WolFoxCaptureMenuSource(view);
    if (OriginalShowMenuSkipCompletion == NULL) return;
    ((void (*)(id, SEL, id, id, id, id, BOOL, BOOL, BOOL, id, id))
        OriginalShowMenuSkipCompletion)(receiver, selector, renderer, view,
                                        entry, block, cancel, log, skip,
                                        responder, completion);
}

static NSString *WolFoxMenuItemIcon(id renderer) {
    NSString *text = nil;
    @try {
        text = [renderer description];
    } @catch (__unused NSException *exception) {
        return nil;
    }
    NSRange range = [text rangeOfString:@"icon_type: "];
    if (range.location == NSNotFound) return nil;
    NSUInteger start = NSMaxRange(range);
    NSUInteger end = start;
    while (end < text.length) {
        unichar character = [text characterAtIndex:end];
        if (!((character >= 'A' && character <= 'Z') || character == '_' || (character >= '0' && character <= '9'))) break;
        end++;
    }
    return end > start ? [text substringWithRange:NSMakeRange(start, end - start)] : nil;
}

static id WolFoxFilteredMenuRenderers(id renderers) {
    if (![renderers isKindOfClass:NSArray.class] || [renderers count] == 0) return renderers;
    NSDictionary<NSString *, NSString *> *hidden = @{
        @"CAST_ICON": @"YTKACE.Preference.Menu.CastHidden",
        @"QUEUE_PLAY_NEXT": @"YTKACE.Preference.Menu.PlayNextHidden",
        @"QUEUE_PLAY_LAST": @"YTKACE.Preference.Menu.PlayLastHidden",
        @"ADD_TO_REMOTE_QUEUE": @"YTKACE.Preference.Menu.PlayLastHidden",
        @"FLAG": @"YTKACE.Preference.Menu.ReportHidden",
        @"ADD_TO_WATCH_LATER": @"YTKACE.Preference.Menu.WatchLaterHidden",
        @"BOOKMARK_BORDER": @"YTKACE.Preference.Menu.SaveHidden",
        @"OFFLINE_ADD": @"YTKACE.Preference.Menu.DownloadHidden",
        @"SHARE_ARROW": @"YTKACE.Preference.Menu.ShareHidden",
        @"HIDE": @"YTKACE.Preference.Menu.NotInterestedHidden",
        @"PERSON_CIRCLE_SLASH": @"YTKACE.Preference.Menu.DontRecommendHidden",
        @"OUTLINE_YOUTUBE_MUSIC": @"YTKACE.Preference.Menu.YouTubeMusicHidden"
    };
    BOOL any = NO;
    for (NSString *key in [NSSet setWithArray:hidden.allValues]) {
        if (WolFoxFeatureEnabled(key)) any = YES;
    }
    if (!any) return renderers;
    NSMutableArray *kept = [NSMutableArray arrayWithCapacity:[renderers count]];
    for (id renderer in (NSArray *)renderers) {
        NSString *key = hidden[WolFoxMenuItemIcon(renderer) ?: @""];
        if (key != nil && WolFoxFeatureEnabled(key)) continue;
        [kept addObject:renderer];
    }
    return kept.count == [renderers count] ? renderers : kept;
}

static id WolFoxActionsForRenderersLog(id receiver, SEL selector, id renderers,
                                       id view, id entry, BOOL log,
                                       id responder) {
    id allRenderers = renderers;
    renderers = WolFoxFilteredMenuRenderers(renderers);
    WolFoxQueuePrepareMenuRenderers(renderers);
    WolFoxCaptureMenuSource(view);
    if (OriginalActionsForRenderersLog == NULL) return nil;
    id actions = ((id (*)(id, SEL, id, id, id, BOOL, id))OriginalActionsForRenderersLog)(
        receiver, selector, renderers, view, entry, log, responder);
    WolFoxRouteSpeedMenuItem(renderers, actions, view, responder);
    WolFoxQueueWrapMenuActions(renderers, actions);
    return WolFoxAiSListAppendMenuAction(allRenderers, actions);
}

static UIView *WolFoxOverflowButtonInside(UIView *root) {
    if (root == nil || root.window == nil) return nil;
    NSString *identifier = root.accessibilityIdentifier.lowercaseString ?: @"";
    if ([identifier containsString:@"menu"] ||
        [identifier containsString:@"overflow"] ||
        [identifier containsString:@"action_button"]) {
        CGRect frame = root.bounds;
        if (CGRectGetWidth(frame) > 8.0 && CGRectGetWidth(frame) < 80.0 &&
            CGRectGetHeight(frame) > 8.0) {
            return root;
        }
    }
    for (UIView *child in root.subviews) {
        UIView *found = WolFoxOverflowButtonInside(child);
        if (found != nil) return found;
    }
    return nil;
}

static NSString *WolFoxOfflineCommandVideoID(id command) {
    for (NSString *name in @[@"offlineVideoEndpoint", @"offlineVideoCommand"]) {
        id endpoint = WolFoxGetValue(command, @[name]);
        id value = WolFoxGetValue(endpoint, @[@"videoId", @"videoID"]);
        if ([value isKindOfClass:NSString.class] && [value length] != 0) {
            return value;
        }
    }
    id direct = WolFoxGetValue(command, @[@"videoId", @"videoID"]);
    if ([direct isKindOfClass:NSString.class] && [direct length] != 0) {
        return direct;
    }
    NSString *dump = nil;
    @try {
        dump = [command description];
    } @catch (__unused NSException *exception) {
        return nil;
    }
    if (dump.length == 0) return nil;
    static NSRegularExpression *expression;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        expression = [NSRegularExpression
            regularExpressionWithPattern:
                @"video_?[Ii]d:\\s*\"([A-Za-z0-9_-]{11})\""
                                 options:0
                                   error:NULL];
    });
    NSTextCheckingResult *match = [expression firstMatchInString:dump options:0
        range:NSMakeRange(0, dump.length)];
    if (match != nil) {
        return [dump substringWithRange:[match rangeAtIndex:1]];
    }
    static NSRegularExpression *packed;
    static dispatch_once_t packedToken;
    dispatch_once(&packedToken, ^{
        packed = [NSRegularExpression
            regularExpressionWithPattern:@"\\\\n\\\\013([A-Za-z0-9_-]{11})"
                                 options:0
                                   error:NULL];
    });
    NSTextCheckingResult *packedMatch = [packed firstMatchInString:dump options:0
        range:NSMakeRange(0, dump.length)];
    if (packedMatch != nil) {
        return [dump substringWithRange:[packedMatch rangeAtIndex:1]];
    }
    WolFoxDownloadLog(@"feed", @"no video id in command dump=%@",
        dump.length > 300 ? [dump substringToIndex:300] : dump);
    return nil;
}

static BOOL WolFoxHandleFeedDownload(id command, id view, id sender) {
    const NSInteger placement = WolFoxDownloadPlacement();
    NSString *videoID = WolFoxOfflineCommandVideoID(command);
    UIView *anchor = [view isKindOfClass:UIView.class] ? view : nil;
    if (anchor.window == nil && [sender isKindOfClass:UIView.class]) {
        anchor = sender;
    }
    if (anchor.window == nil) {
        id senderView = WolFoxGetValue(sender, @[@"view", @"contentView", @"cell", @"_cell"]);
        if ([senderView respondsToSelector:@selector(contentView)] &&
            ![senderView isKindOfClass:UIView.class]) {
            senderView = WolFoxGetValue(senderView, @[@"contentView"]);
        }
        if ([senderView isKindOfClass:UIView.class]) {
            UIView *cell = senderView;
            UIView *overflow = WolFoxOverflowButtonInside(cell);
            anchor = overflow ?: cell;
        }
    }
    if (anchor.window == nil && WolFoxMenuSourceView.window != nil) {
        anchor = WolFoxMenuSourceView;
    }
    if (placement != 2 && placement != 3) return NO;
    if (videoID.length == 0) return NO;
    WolFoxShowNotice(WolFoxLocalized(@"Preparing download"));
    WolFoxResolvePlayerResponse(videoID, ^(id response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (response == nil) {
                WolFoxDownloadLog(@"feed", @"resolve failed video=%@ error=%@",
                    videoID, error.localizedDescription ?: @"unknown");
                WolFoxShowNotice(WolFoxLocalized(@"Download unavailable"));
                return;
            }
            [WolFoxDownloadCoordinator.sharedCoordinator
                showDownloadMenuForResponse:response
                                 sourceView:anchor];
        });
    });
    return YES;
}

static void WolFoxOfflineVideoExecute(id receiver, SEL selector, id command,
                                      id entry, id view, id sender) {
    if (WolFoxHandleFeedDownload(command, view, sender)) return;
    if (OriginalOfflineVideoExecute == NULL) return;
    ((void (*)(id, SEL, id, id, id, id))OriginalOfflineVideoExecute)(
        receiver, selector, command, entry, view, sender);
}

static IMP OriginalLegacyOfflineVideoExecute;

static void WolFoxLegacyOfflineVideoExecute(id receiver, SEL selector, id command,
                                            id entry, id view, id sender) {
    if (WolFoxHandleFeedDownload(command, view, sender)) return;
    if (OriginalLegacyOfflineVideoExecute == NULL) return;
    ((void (*)(id, SEL, id, id, id, id))OriginalLegacyOfflineVideoExecute)(
        receiver, selector, command, entry, view, sender);
}

static void WolFoxOfflineVideoExecuteCompletion(id receiver, SEL selector,
                                                id command, id entry, id view,
                                                id sender, id block) {
    if (WolFoxHandleFeedDownload(command, view, sender)) return;
    if (OriginalOfflineVideoExecuteCompletion == NULL) return;
    ((void (*)(id, SEL, id, id, id, id, id))OriginalOfflineVideoExecuteCompletion)(
        receiver, selector, command, entry, view, sender, block);
}

void WolFoxInstallFeedDownloadHooks(void) {
    WolFoxInstallInstanceHook(@"YTMenuController",
        @"showMenuWithMenuRenderer:fromView:entry:dismissalBlock:addCancelAction:shouldLogItems:firstResponder:completion:",
        (IMP)WolFoxShowMenuCompletion, &OriginalShowMenuCompletion);
    WolFoxInstallInstanceHook(@"YTMenuController",
        @"showMenuWithMenuRenderer:fromView:entry:dismissalBlock:addCancelAction:shouldLogItems:skipCollapsedState:firstResponder:completion:",
        (IMP)WolFoxShowMenuSkipCompletion, &OriginalShowMenuSkipCompletion);
    WolFoxInstallInstanceHook(@"YTMenuController",
        @"actionsForRenderers:fromView:entry:shouldLogItems:firstResponder:",
        (IMP)WolFoxActionsForRenderersLog, &OriginalActionsForRenderersLog);
    BOOL a = WolFoxInstallInstanceHook(@"YTOfflineVideoEndpointCommandHandlerImpl",
        @"executeWithCommand:entry:fromView:sender:",
        (IMP)WolFoxOfflineVideoExecute, &OriginalOfflineVideoExecute);
    BOOL b = WolFoxInstallInstanceHook(@"YTOfflineVideoEndpointCommandHandlerImpl",
        @"executeWithCommand:entry:fromView:sender:completionBlock:",
        (IMP)WolFoxOfflineVideoExecuteCompletion,
        &OriginalOfflineVideoExecuteCompletion);
    BOOL legacy = NO;
    if (!a) {
        legacy = WolFoxInstallInstanceHook(@"YTOfflineVideoEndpointCommandHandler",
            @"executeWithCommand:entry:fromView:sender:",
            (IMP)WolFoxLegacyOfflineVideoExecute, &OriginalLegacyOfflineVideoExecute);
    }
    WolFoxDownloadLog(@"feed", @"hooks execute=%d completion=%d legacy=%d", a, b, legacy);
}

BOOL WolFoxPlaybackTemplateReady(void) {
    @synchronized (WolFoxSABRDownloader.class) {
        if (WolFoxLastPlayerRequest == nil) return NO;
        if (WolFoxLastPlayerService != nil) return YES;
    }
    return NSClassFromString(@"YTPlayerService") != Nil;
}

void WolFoxResolvePlayerResponse(NSString *videoID,
                                 WolFoxPlayerReloadCompletion completion) {
    if (videoID.length == 0) {
        completion(nil, [NSError errorWithDomain:@"WolFoxPlayerResolve" code:1
            userInfo:@{NSLocalizedDescriptionKey: @"No video identifier."}]);
        return;
    }
    id cached = WolFoxCachedPlayerResponse(videoID);
    if (cached != nil) {
        WolFoxDownloadLog(@"resolve", @"cached video=%@", videoID);
        completion(cached, nil);
        return;
    }
    id service = nil;
    id sourceRequest = nil;
    @synchronized (WolFoxSABRDownloader.class) {
        NSArray *pair = WolFoxPlayerRequests[videoID];
        if (pair.count > 1) {
            service = pair[0];
            sourceRequest = pair[1];
        } else {
            service = WolFoxLastPlayerService;
            sourceRequest = WolFoxLastPlayerRequest;
        }
    }
    if (service == nil) {
        Class serviceClass = NSClassFromString(@"YTPlayerService");
        if (serviceClass != Nil) {
            @try {
                service = [[serviceClass alloc] init];
            } @catch (__unused NSException *exception) {
                service = nil;
            }
            WolFoxDownloadLog(@"resolve", @"constructed player service=%d",
                service != nil);
            if (service != nil) {
                @synchronized (WolFoxSABRDownloader.class) {
                    if (WolFoxLastPlayerService == nil) {
                        WolFoxLastPlayerService = service;
                    }
                }
            }
        }
    }
    if (sourceRequest == nil && WolFoxLastInnerTubeContext != nil) {
        id built = [NSClassFromString(@"YTIPlayerRequest") new];
        if (WolFoxSetValue(built, @"context",
                           WolFoxCopyObject(WolFoxLastInnerTubeContext))) {
            sourceRequest = built;
        }
    }
    if (service == nil || sourceRequest == nil || OriginalMakePlayerRequest == NULL) {
        completion(nil, [NSError errorWithDomain:@"WolFoxPlayerResolve" code:2
            userInfo:@{NSLocalizedDescriptionKey:
                [NSString stringWithFormat:
                    @"No player request template (service=%d context=%d).",
                    service != nil, WolFoxLastInnerTubeContext != nil]}]);
        return;
    }
    id request = WolFoxCopyObject(sourceRequest);
    if (!WolFoxSetValue(request, @"videoId", videoID)) {
        completion(nil, [NSError errorWithDomain:@"WolFoxPlayerResolve" code:3
            userInfo:@{NSLocalizedDescriptionKey:
                @"YouTube's player request could not be retargeted."}]);
        return;
    }
    WolFoxSetValue(request, @"playlistId", @"");
    WolFoxSetValue(request, @"params", @"");
    WolFoxSetValue(request, @"playlistIndex", @0);
    id playback = WolFoxGetValue(request, @[@"playbackContext"]);
    id contentPlayback = WolFoxGetValue(playback, @[@"contentPlaybackContext"]);
    WolFoxSetValue(contentPlayback, @"currentUrl", @"");
    WolFoxSetValue(contentPlayback, @"referer", @"");
    WolFoxDownloadLog(@"resolve", @"request video=%@", videoID);
    dispatch_async(dispatch_get_main_queue(), ^{
        ((void (*)(id, SEL, id, id, id))OriginalMakePlayerRequest)(
            service,
            NSSelectorFromString(@"makePlayerRequest:responseBlock:errorBlock:"),
            request,
            ^(id receivedResponse, __unused id cacheContext) {
                id playerResponse = WolFoxHLSOriginalResponse(videoID) ?: receivedResponse;
                NSString *resolved = nil;
                id details = WolFoxGetValue(playerResponse, @[@"videoDetails"]);
                id value = WolFoxGetValue(details, @[@"videoId", @"videoID"]);
                if ([value isKindOfClass:NSString.class]) resolved = value;
                id streaming = WolFoxGetValue(playerResponse, @[@"streamingData"]);
                if (streaming == nil) {
                    id nested = WolFoxGetValue(playerResponse, @[@"playerData"]);
                    streaming = WolFoxGetValue(nested, @[@"streamingData"]);
                }
                id ustreamer = WolFoxGetValue(streaming,
                    @[@"mediaUstreamerRequestConfig"]);
                id config = WolFoxGetValue(ustreamer,
                    @[@"videoPlaybackUstreamerConfig"]);
                WolFoxDownloadLog(@"resolve",
                    @"response video=%@ resolved=%@ streaming=%d ustreamer=%d config=%d",
                    videoID, resolved ?: @"none", streaming != nil,
                    ustreamer != nil, config != nil);
                if (playerResponse != nil) {
                    WolFoxStorePlayerResponse(videoID, playerResponse);
                }
                completion(playerResponse, nil);
            },
            ^(NSError *error) {
                WolFoxDownloadLog(@"resolve", @"error video=%@ error=%@",
                    videoID, error.localizedDescription ?: @"unknown");
                completion(nil, error);
            });
    });
}

void WolFoxReloadPlayer(NSString * _Nullable videoID,
                        NSString *token,
                        WolFoxPlayerReloadCompletion completion) {
    id service = nil;
    id request = nil;
    id playbackRequest = nil;
    @synchronized (WolFoxSABRDownloader.class) {
        NSArray *pair = videoID.length != 0 ? WolFoxPlayerRequests[videoID] : nil;
        service = pair.count > 0 ? pair[0] : WolFoxLastPlayerService;
        request = pair.count > 1 ? pair[1] : WolFoxLastPlayerRequest;
        playbackRequest = WolFoxLastPlaybackRequest;
    }
    if ((OriginalMakePlayerRequest == NULL && OriginalMakePlaybackRequest == NULL) ||
        service == nil || request == nil || token.length == 0) {
        NSError *error = [NSError errorWithDomain:@"WolFoxPlayerReload" code:1
            userInfo:@{NSLocalizedDescriptionKey: @"No matching YouTube player request is available."}];
        completion(nil, error);
        return;
    }
    id mutableRequest = WolFoxCopyObject(request);
    id playback = WolFoxCopyObject(WolFoxGetValue(mutableRequest, @[@"playbackContext"]));
    if (playback == nil) playback = [NSClassFromString(@"YTIPlaybackContext") new];
    id params = [NSClassFromString(@"YTIReloadPlaybackParams") new];
    id reload = [NSClassFromString(@"YTIReloadPlaybackContext") new];
    BOOL configured = WolFoxSetValue(params, @"token", token) &&
        WolFoxSetValue(reload, @"reloadPlaybackParams", params) &&
        WolFoxSetValue(playback, @"reloadPlaybackContext", reload) &&
        WolFoxSetValue(mutableRequest, @"playbackContext", playback);
    if (!configured) {
        NSError *error = [NSError errorWithDomain:@"WolFoxPlayerReload" code:2
            userInfo:@{NSLocalizedDescriptionKey: @"YouTube's reload request could not be configured."}];
        completion(nil, error);
        return;
    }
    id routedRequest = nil;
    if (playbackRequest != nil && OriginalMakePlaybackRequest != NULL) {
        Class playbackClass = NSClassFromString(@"YTPlaybackRequest");
        SEL initializer = NSSelectorFromString(
            @"initWithProtoRequest:URLRequestProperties:CPN:QOEController:latencyLogger:streamingWatchEnabled:enablePlayerResponseCacheKeyRelaxation:playerResponseCacheToken:streamingWatchHandlers:");
        id allocated = [playbackClass alloc];
        if ([allocated respondsToSelector:initializer]) {
            BOOL streaming = ((BOOL (*)(id, SEL))objc_msgSend)(
                playbackRequest, NSSelectorFromString(@"streamingWatchEnabled"));
            BOOL relaxation = ((BOOL (*)(id, SEL))objc_msgSend)(
                playbackRequest, NSSelectorFromString(@"enablePlayerResponseCacheKeyRelaxation"));
            routedRequest = ((id (*)(id, SEL, id, id, id, id, id, BOOL, BOOL, id, id))objc_msgSend)(
                allocated,
                initializer,
                mutableRequest,
                WolFoxGetValue(playbackRequest, @[@"URLRequestProperties"]),
                WolFoxGetValue(playbackRequest, @[@"CPN"]),
                WolFoxGetValue(playbackRequest, @[@"QOEController"]),
                WolFoxGetValue(playbackRequest, @[@"latencyLogger"]),
                streaming,
                relaxation,
                WolFoxGetValue(playbackRequest, @[@"playerResponseCacheToken"]),
                WolFoxGetValue(playbackRequest, @[@"streamingWatchHandlers"])
            );
        }
    }
    WolFoxDownloadLog(@"reload", @"native request video=%@ token=%lu route=%@",
        videoID ?: @"unknown", (unsigned long)token.length,
        routedRequest != nil ? @"playback" : @"player");
    dispatch_async(dispatch_get_main_queue(), ^{
        void (^response)(id, id) = ^(id playerResponse, __unused id cacheContext) {
            WolFoxDownloadLog(@"reload", @"native response video=%@ class=%@",
                videoID ?: @"unknown", NSStringFromClass([playerResponse class]));
            completion(playerResponse, nil);
        };
        void (^failure)(NSError *) = ^(NSError *error) {
            WolFoxDownloadLog(@"reload", @"native error video=%@ error=%@",
                videoID ?: @"unknown", error.localizedDescription ?: @"unknown");
            completion(nil, error);
        };
        if (routedRequest != nil && OriginalMakePlaybackRequest != NULL) {
            ((id (*)(id, SEL, id, id, id))OriginalMakePlaybackRequest)(
                service, NSSelectorFromString(@"makePlaybackRequest:responseBlock:errorBlock:"),
                routedRequest, response, failure
            );
        } else {
            ((void (*)(id, SEL, id, id, id))OriginalMakePlayerRequest)(
                service, NSSelectorFromString(@"makePlayerRequest:responseBlock:errorBlock:"),
                mutableRequest, response, failure
            );
        }
    });
}

static id WolFoxMintWithVideoID(id receiver, SEL selector, id videoID) {
    if ([videoID isKindOfClass:NSString.class]) WolFoxSABRSetCurrentVideoID(videoID);
    id result = nil;
    if (OriginalMintWithVideoID != NULL) {
        result = ((id (*)(id, SEL, id))OriginalMintWithVideoID)(receiver, selector, videoID);
    }
    WolFoxSABRSetPoToken(result);
    if ([videoID isKindOfClass:NSString.class]) {
        static NSMutableArray<NSString *> *logged;
        static dispatch_once_t once;
        dispatch_once(&once, ^{ logged = [NSMutableArray array]; });
        BOOL fresh = NO;
        @synchronized (logged) {
            if (![logged containsObject:videoID]) {
                [logged addObject:videoID];
                if (logged.count > 30) [logged removeObjectAtIndex:0];
                fresh = YES;
            }
        }
        if (fresh) {
            WolFoxDownloadLog(@"token", @"video=%@ potoken=%lu", videoID,
                              (unsigned long)WolFoxSABRPoTokenLength());
        }
    }
    return result;
}

static void WolFoxSetPlayerResponse(id receiver,
                                    SEL selector,
                                    id playerResponse,
                                    id cpn) {
    if (OriginalSetPlayerResponse != NULL) {
        ((void (*)(id, SEL, id, id))OriginalSetPlayerResponse)(
            receiver, selector, playerResponse, cpn
        );
    }
    WolFoxDownloadCoordinator.sharedCoordinator.playerResponse = playerResponse;
}

static void WolFoxSetPoToken(id receiver, SEL selector, NSData *token) {
    if (OriginalSetPoToken != NULL) {
        ((void (*)(id, SEL, id))OriginalSetPoToken)(receiver, selector, token);
    }
    WolFoxSABRSetPoToken(token);
}

void WolFoxInstallDownloadHooks(void) {
    WolFoxInstallInstanceHook(@"YTProofOfOriginTokenManager",
                              @"mintWithVideoID:",
                              (IMP)WolFoxMintWithVideoID,
                              &OriginalMintWithVideoID);
    WolFoxInstallInstanceHook(@"YTIServiceIntegrityDimensions",
                              @"setPoToken:",
                              (IMP)WolFoxSetPoToken,
                              &OriginalSetPoToken);
    WolFoxInstallPlayerServiceHook();
    WolFoxInstallInstanceHook(@"MLOnesieRequestFactory",
                              @"onesieRequestForPlayerRequest:dataLoader:context:cryptor:requestNumber:error:",
                              (IMP)WolFoxOnesieRequest,
                              &OriginalOnesieRequest);
    WolFoxInstallInstanceHook(@"YTMainAppVideoPlayerOverlayViewController",
                              @"setPlayerResponse:CPN:",
                              (IMP)WolFoxSetPlayerResponse,
                              &OriginalSetPlayerResponse);


    WolFoxRegisterOverlayConfigurator(@"downloads", ^(UIView *overlay, UIStackView *stack) {
        (void)overlay;
        UIButton *button = WolFoxOverlayButton(
            stack,
            @"WolFox Download",
            @"arrow.down.circle.fill",
            WolFoxDownloadCoordinator.sharedCoordinator,
            @selector(showDownloadMenuFromButton:)
        );
        [button setImage:WolFoxDownloadGlyphImage()
                forState:UIControlStateNormal];
        const NSInteger placement = WolFoxDownloadPlacement();
        button.hidden = placement != 1 && placement != 3;
    });
}
