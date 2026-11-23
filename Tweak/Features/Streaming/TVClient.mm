#import "../../WolFox.h"
#import "../../Runtime/Preferences.h"
#import "../Downloads/DownloadLog.h"

#import <Foundation/Foundation.h>
#import <objc/message.h>

static NSString *const WolFoxTVName = @"TVHTML5";
static NSString *const WolFoxTVVersion = @"7.20260707.07.00";
static NSString *const WolFoxTVNumber = @"7";
static NSString *const WolFoxTVDeviceMake = @"Sony";
static NSString *const WolFoxTVDeviceModel = @"PS4";
static NSString *const WolFoxTVOSName = @"PlayStation 4";
static NSString *const WolFoxTVPlatform = @"GAME_CONSOLE";
static NSString *const WolFoxTVUserAgent =
    @"Mozilla/5.0 (PS4; Leanback Shell) Gecko/20100101 Firefox/65.0 "
     "LeanbackShell/01.00.01.75 Sony PS4/ (PS4, , no, CH)";
static NSString *const WolFoxTVVisitorKey = @"WolFox.Cache.TVVisitor";
static NSString *const WolFoxTVTimestampKey = @"WolFox.Cache.TVSignatureTimestamps";
static const NSTimeInterval WolFoxTVVisitorLifetime = 30.0 * 24.0 * 60.0 * 60.0;

static NSDictionary *WolFoxTVContext(NSString *visitor) {
    NSMutableDictionary *client = [@{
        @"clientName": WolFoxTVName, @"clientVersion": WolFoxTVVersion,
        @"platform": WolFoxTVPlatform, @"deviceMake": WolFoxTVDeviceMake,
        @"deviceModel": WolFoxTVDeviceModel, @"osName": WolFoxTVOSName, @"osVersion": @"",
        @"hl": @"en-GB", @"gl": @"GB", @"utcOffsetMinutes": @0} mutableCopy];
    if (visitor.length != 0) client[@"visitorData"] = visitor;
    return @{@"client": client, @"request": @{@"useSsl": @YES},
             @"user": @{@"lockedSafetyMode": @NO}};
}

NSDictionary<NSString *, NSString *> *WolFoxTVHeaders(NSString *visitor) {
    NSMutableDictionary *headers = [@{
        @"User-Agent": WolFoxTVUserAgent, @"X-YouTube-Client-Name": WolFoxTVNumber,
        @"X-YouTube-Client-Version": WolFoxTVVersion, @"Origin": @"https://www.youtube.com"} mutableCopy];
    if (visitor.length != 0) headers[@"X-Goog-Visitor-Id"] = visitor;
    return headers;
}

static void WolFoxTVAppendField(NSMutableData *data, uint64_t key, NSData *value) {
    while (key >= 0x80) { uint8_t byte = (uint8_t)(key | 0x80); [data appendBytes:&byte length:1]; key >>= 7; }
    uint8_t last = (uint8_t)key;
    [data appendBytes:&last length:1];
    if (value == nil) return;
    uint64_t length = value.length;
    while (length >= 0x80) { uint8_t byte = (uint8_t)(length | 0x80); [data appendBytes:&byte length:1]; length >>= 7; }
    uint8_t tail = (uint8_t)length;
    [data appendBytes:&tail length:1];
    [data appendData:value];
}

NSData *WolFoxTVClientInfo(void) {
    NSMutableData *data = [NSMutableData data];
    NSData *(^text)(NSString *) = ^NSData *(NSString *value) {
        return [value dataUsingEncoding:NSUTF8StringEncoding];
    };
    WolFoxTVAppendField(data, (12 << 3) | 2, text(WolFoxTVDeviceMake));
    WolFoxTVAppendField(data, (13 << 3) | 2, text(WolFoxTVDeviceModel));
    WolFoxTVAppendField(data, (16 << 3) | 0, nil);
    uint8_t name = 7;
    [data appendBytes:&name length:1];
    WolFoxTVAppendField(data, (17 << 3) | 2, text(WolFoxTVVersion));
    WolFoxTVAppendField(data, (18 << 3) | 2, text(WolFoxTVOSName));
    WolFoxTVAppendField(data, (21 << 3) | 2, text(@"en"));
    WolFoxTVAppendField(data, (22 << 3) | 2, text(@"GB"));
    return data;
}

static NSData *WolFoxTVFetch(NSURLRequest *request, NSInteger *status) {
    __block NSData *result = nil;
    __block NSInteger code = 0;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    [[NSURLSession.sharedSession dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response, __unused NSError *error) {
        result = data;
        code = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 0;
        dispatch_semaphore_signal(done);
    }] resume];
    dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(20 * NSEC_PER_SEC)));
    if (status != NULL) *status = code;
    return result;
}

static NSMutableURLRequest *WolFoxTVRequest(NSString *path, NSDictionary *body, NSString *visitor) {
    NSURL *URL = [NSURL URLWithString:[@"https://youtubei.googleapis.com/youtubei/v1/" stringByAppendingString:path]];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:URL];
    request.HTTPMethod = @"POST";
    request.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    NSDictionary *headers = WolFoxTVHeaders(visitor);
    for (NSString *key in headers) [request setValue:headers[key] forHTTPHeaderField:key];
    return request;
}

static NSString *WolFoxTVVisitor(BOOL refresh) {
    NSDictionary *cached = WolFoxPreferenceObject(WolFoxTVVisitorKey);
    if (!refresh && [cached isKindOfClass:NSDictionary.class]) {
        NSString *value = cached[@"id"];
        NSNumber *time = cached[@"time"];
        if ([value isKindOfClass:NSString.class] && value.length != 0 &&
            NSDate.date.timeIntervalSince1970 - time.doubleValue < WolFoxTVVisitorLifetime) {
            return value;
        }
    }
    NSInteger status = 0;
    NSData *data = WolFoxTVFetch(WolFoxTVRequest(
        @"guide?prettyPrint=false&fields=responseContext.visitorData",
        @{@"context": WolFoxTVContext(nil)}, nil), &status);
    id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    NSString *visitor = [json isKindOfClass:NSDictionary.class] ? json[@"responseContext"][@"visitorData"] : nil;
    if ([visitor isKindOfClass:NSString.class] && visitor.length != 0) {
        WolFoxSetPreferenceObject(WolFoxTVVisitorKey,
            @{@"id": visitor, @"time": @(NSDate.date.timeIntervalSince1970)});
        return visitor;
    }
    WolFoxDownloadLog(@"tv", @"visitor failed http=%ld", (long)status);
    return nil;
}

static NSString *WolFoxTVFirstMatch(NSString *text, NSString *pattern) {
    if (text.length == 0) return nil;
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:pattern options:0 error:nil];
    NSTextCheckingResult *match = [regex firstMatchInString:text options:0 range:NSMakeRange(0, text.length)];
    return match ? [text substringWithRange:[match rangeAtIndex:1]] : nil;
}

static BOOL WolFoxTVPlayer(NSString **playerID, NSString **playerJS, NSInteger *timestamp) {
    static NSString *cachedIdentifier;
    static CFAbsoluteTime cachedAt;
    NSString *identifier = nil;
    @synchronized (WolFoxTVTimestampKey) {
        if (cachedIdentifier.length != 0 && CFAbsoluteTimeGetCurrent() - cachedAt < 6.0 * 60.0 * 60.0) {
            identifier = cachedIdentifier;
        }
    }
    if (identifier.length == 0) {
        NSData *api = WolFoxTVFetch([NSURLRequest requestWithURL:
            [NSURL URLWithString:@"https://www.youtube.com/iframe_api"]], NULL);
        identifier = WolFoxTVFirstMatch(
            api ? [[NSString alloc] initWithData:api encoding:NSUTF8StringEncoding] : nil,
            @"player\\\\?/([0-9a-f]{8})\\\\?/");
        if (identifier.length == 0) return NO;
        @synchronized (WolFoxTVTimestampKey) {
            cachedIdentifier = identifier;
            cachedAt = CFAbsoluteTimeGetCurrent();
        }
    }
    *playerID = identifier;
    NSDictionary *known = WolFoxPreferenceObject(WolFoxTVTimestampKey);
    NSNumber *stored = [known isKindOfClass:NSDictionary.class] ? known[identifier] : nil;
    NSURL *caches = [NSFileManager.defaultManager URLsForDirectory:NSCachesDirectory
                                                         inDomains:NSUserDomainMask].firstObject;
    NSString *prepared = [caches URLByAppendingPathComponent:
        [NSString stringWithFormat:@"WolFox-player-%@.js", identifier]].path;
    if (stored != nil && [NSFileManager.defaultManager fileExistsAtPath:prepared]) {
        *timestamp = stored.integerValue;
        return YES;
    }
    NSString *address = [NSString stringWithFormat:
        @"https://www.youtube.com/s/player/%@/player_ias.vflset/en_US/base.js", identifier];
    NSData *js = WolFoxTVFetch([NSURLRequest requestWithURL:[NSURL URLWithString:address]], NULL);
    NSString *source = js ? [[NSString alloc] initWithData:js encoding:NSUTF8StringEncoding] : nil;
    NSString *value = WolFoxTVFirstMatch(source, @"(?:signatureTimestamp|sts)\\s*:\\s*(\\d{5})");
    if (source.length == 0) return NO;
    *playerJS = source;
    *timestamp = value.integerValue;
    NSMutableDictionary *updated = [known isKindOfClass:NSDictionary.class] ? [known mutableCopy] : [NSMutableDictionary dictionary];
    if (updated.count > 8) [updated removeAllObjects];
    updated[identifier] = @(value.integerValue);
    WolFoxSetPreferenceObject(WolFoxTVTimestampKey, updated);
    return YES;
}

void WolFoxTVFetchPlayerResponse(NSString *videoID, void (^completion)(id _Nullable response,
                                                                      NSString * _Nullable visitor,
                                                                      NSError * _Nullable error)) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *(^failure)(NSString *) = ^NSError *(NSString *message) {
            WolFoxDownloadLog(@"tv", @"video=%@ %@", videoID, message);
            return [NSError errorWithDomain:@"WolFoxTVClient" code:1
                                   userInfo:@{NSLocalizedDescriptionKey: message}];
        };
        NSString *playerID = nil, *playerJS = nil;
        NSInteger timestamp = 0;
        if (!WolFoxTVPlayer(&playerID, &playerJS, &timestamp)) {
            completion(nil, nil, failure(@"player script unavailable"));
            return;
        }
        id response = nil;
        NSString *visitor = nil;
        NSString *reason = nil;
        for (NSInteger attempt = 0; attempt < 2 && response == nil; attempt++) {
            visitor = WolFoxTVVisitor(attempt > 0);
            NSMutableDictionary *body = [@{
                @"context": WolFoxTVContext(visitor), @"videoId": videoID,
                @"contentCheckOk": @YES, @"racyCheckOk": @YES} mutableCopy];
            if (timestamp != 0) {
                body[@"playbackContext"] = @{@"contentPlaybackContext": @{
                    @"html5Preference": @"HTML5_PREF_WANTS", @"signatureTimestamp": @(timestamp)}};
            }
            NSInteger status = 0;
            NSData *proto = WolFoxTVFetch(WolFoxTVRequest(@"player?alt=proto", body, visitor), &status);
            Class responseClass = NSClassFromString(@"YTIPlayerResponse");
            id parsed = responseClass && proto.length
                ? ((id (*)(id, SEL, id, NSError **))objc_msgSend)([responseClass alloc],
                    NSSelectorFromString(@"initWithData:error:"), proto, NULL) : nil;
            id streaming = [parsed valueForKey:@"streamingData"];
            NSString *serverURL = [streaming valueForKey:@"serverAbrStreamingURL"];
            if ([serverURL isKindOfClass:NSString.class] && serverURL.length != 0) {
                response = parsed;
            } else {
                id playability = [parsed valueForKey:@"playabilityStatus"];
                reason = [NSString stringWithFormat:@"no stream http=%ld reason=%@", (long)status,
                          [playability valueForKey:@"reason"] ?: @"none"];
            }
        }
        if (response == nil) {
            completion(nil, nil, failure(reason ?: @"no response"));
            return;
        }
        id streaming = [response valueForKey:@"streamingData"];
        NSString *serverURL = [streaming valueForKey:@"serverAbrStreamingURL"];
        NSString *solved = WolFoxSolveURLParameterN(playerID, playerJS, serverURL);
        if ([solved isEqualToString:serverURL] && [serverURL containsString:@"&n="]) {
            completion(nil, nil, failure(@"n challenge unsolved"));
            return;
        }
        [streaming setValue:solved forKey:@"serverAbrStreamingURL"];
        WolFoxDownloadLog(@"tv", @"video=%@ ready player=%@", videoID, playerID);
        completion(response, visitor, nil);
    });
}
