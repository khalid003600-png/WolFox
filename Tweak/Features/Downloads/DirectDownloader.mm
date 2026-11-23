#import "DirectDownloader.h"
#import "StreamResolver.h"
#import "DownloadLog.h"
#import "../../Runtime/Preferences.h"

#import <objc/message.h>

NSString * const WolFoxDownloadMethodKey = @"YTKACE.Preference.Downloads.Method";

static NSString * const WolFoxDirectUserAgent =
    @"Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) AppleWebKit/605.1.15 "
     "(KHTML, like Gecko) Version/26.0 Safari/605.1.15";
static NSString * const WolFoxDirectVisitorKey = @"WolFox.Cache.DirectVisitor";
static const NSTimeInterval WolFoxDirectVisitorLifetime = 7.0 * 24.0 * 60.0 * 60.0;
static const int64_t WolFoxDirectChunkSize = 8 * 1024 * 1024;
static const NSInteger WolFoxDirectChunkAttempts = 4;

static NSInteger WolFoxDownloadMethod(void) {
    id stored = WolFoxPreferenceObject(WolFoxDownloadMethodKey);
    if ([stored respondsToSelector:@selector(integerValue)]) return [stored integerValue];
    return WolFoxFeatureEnabled(@"YTKACE.Preference.Downloads.TVClient") ? 2 : 0;
}

BOOL WolFoxDirectDownloadsEnabled(void) {
    return WolFoxDownloadMethod() == 1;
}

BOOL WolFoxTVDownloadsEnabled(void) {
    return WolFoxDownloadMethod() == 2;
}

@interface WolFoxDirectTask ()
@property(atomic, assign) BOOL cancelled;
@property(atomic, strong) NSURLSessionTask *currentTask;
@end

@implementation WolFoxDirectTask
- (void)cancel {
    self.cancelled = YES;
    [self.currentTask cancel];
}
@end

static NSError *WolFoxDirectError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:@"WolFoxDirect" code:code
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

static NSDictionary *WolFoxDirectContext(NSString *visitor) {
    NSMutableDictionary *client = [@{
        @"clientName": @"VISIONOS", @"clientVersion": @"1.02",
        @"osName": @"visionOS", @"osVersion": @"26.5.23O471",
        @"deviceMake": @"Apple", @"deviceModel": @"RealityDevice17,1",
        @"userAgent": WolFoxDirectUserAgent,
        @"hl": @"en", @"gl": @"US"} mutableCopy];
    if (visitor.length != 0) client[@"visitorData"] = visitor;
    return @{@"client": client};
}

static NSData *WolFoxDirectFetch(NSURLRequest *request, WolFoxDirectTask *task,
                                 NSInteger *status, NSError **error) {
    __block NSData *result = nil;
    __block NSInteger code = 0;
    __block NSError *failure = nil;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    NSURLSessionDataTask *dataTask = [NSURLSession.sharedSession dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *taskError) {
            result = data;
            failure = taskError;
            code = [response isKindOfClass:NSHTTPURLResponse.class]
                ? ((NSHTTPURLResponse *)response).statusCode : 0;
            dispatch_semaphore_signal(done);
        }];
    task.currentTask = dataTask;
    [dataTask resume];
    if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW,
            (int64_t)(90 * NSEC_PER_SEC))) != 0) {
        [dataTask cancel];
        failure = WolFoxDirectError(2, @"request timed out");
    }
    task.currentTask = nil;
    if (status != NULL) *status = code;
    if (error != NULL) *error = failure;
    return result;
}

@interface WolFoxDirectChunkReceiver : NSObject <NSURLSessionDataDelegate>
@property(nonatomic, strong) NSMutableData *data;
@property(nonatomic, assign) NSInteger status;
@property(nonatomic, strong) NSError *error;
@property(nonatomic, strong) dispatch_semaphore_t done;
@property(nonatomic, copy) void (^received)(int64_t bytes);
@property(nonatomic, assign) CFAbsoluteTime lastReport;
@end

@implementation WolFoxDirectChunkReceiver

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask
    didReceiveResponse:(NSURLResponse *)response
     completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {
    (void)session;
    (void)dataTask;
    self.status = [response isKindOfClass:NSHTTPURLResponse.class]
        ? ((NSHTTPURLResponse *)response).statusCode : 0;
    completionHandler(NSURLSessionResponseAllow);
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask
    didReceiveData:(NSData *)data {
    (void)session;
    (void)dataTask;
    [self.data appendData:data];
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (self.received != nil && now - self.lastReport >= 0.1) {
        self.lastReport = now;
        self.received((int64_t)self.data.length);
    }
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
    didCompleteWithError:(NSError *)error {
    (void)session;
    (void)task;
    self.error = error;
    dispatch_semaphore_signal(self.done);
}

@end

static NSData *WolFoxDirectFetchChunk(NSURLRequest *request, WolFoxDirectTask *task,
                                      void (^received)(int64_t bytes),
                                      NSInteger *status, NSError **error) {
    WolFoxDirectChunkReceiver *receiver = [WolFoxDirectChunkReceiver new];
    receiver.data = [NSMutableData data];
    receiver.done = dispatch_semaphore_create(0);
    receiver.received = received;
    NSURLSessionDataTask *dataTask = [NSURLSession.sharedSession dataTaskWithRequest:request];
    dataTask.delegate = receiver;
    task.currentTask = dataTask;
    [dataTask resume];
    if (dispatch_semaphore_wait(receiver.done, dispatch_time(DISPATCH_TIME_NOW,
            (int64_t)(90 * NSEC_PER_SEC))) != 0) {
        [dataTask cancel];
        receiver.error = WolFoxDirectError(2, @"request timed out");
    }
    task.currentTask = nil;
    if (status != NULL) *status = receiver.status;
    if (error != NULL) *error = receiver.error;
    return receiver.error == nil ? receiver.data : nil;
}

static NSMutableURLRequest *WolFoxDirectAPIRequest(NSString *path, NSDictionary *body,
                                                   NSString *visitor) {
    NSURL *URL = [NSURL URLWithString:
        [@"https://youtubei.googleapis.com/youtubei/v1/" stringByAppendingString:path]];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:URL];
    request.HTTPMethod = @"POST";
    request.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:WolFoxDirectUserAgent forHTTPHeaderField:@"User-Agent"];
    if (visitor.length != 0) [request setValue:visitor forHTTPHeaderField:@"X-Goog-Visitor-Id"];
    return request;
}

static NSString *WolFoxDirectVisitor(BOOL refresh, WolFoxDirectTask *task) {
    NSDictionary *cached = WolFoxPreferenceObject(WolFoxDirectVisitorKey);
    if (!refresh && [cached isKindOfClass:NSDictionary.class]) {
        NSString *value = cached[@"id"];
        NSNumber *time = cached[@"time"];
        if ([value isKindOfClass:NSString.class] && value.length != 0 &&
            [time isKindOfClass:NSNumber.class] &&
            NSDate.date.timeIntervalSince1970 - time.doubleValue < WolFoxDirectVisitorLifetime) {
            return value;
        }
    }
    NSString *visitor = nil;
    for (NSInteger attempt = 0; attempt < 3 && visitor.length == 0 && !task.cancelled; attempt++) {
        if (attempt > 0) [NSThread sleepForTimeInterval:0.4];
        NSData *data = WolFoxDirectFetch(WolFoxDirectAPIRequest(
            @"guide?prettyPrint=false&fields=responseContext.visitorData",
            @{@"context": WolFoxDirectContext(nil)}, nil), task, NULL, NULL);
        id json = data.length != 0 ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        id value = [json isKindOfClass:NSDictionary.class] ? json[@"responseContext"][@"visitorData"] : nil;
        visitor = [value isKindOfClass:NSString.class] ? value : nil;
    }
    if (visitor.length == 0) return nil;
    WolFoxSetPreferenceObject(WolFoxDirectVisitorKey,
        @{@"id": visitor, @"time": @(NSDate.date.timeIntervalSince1970)});
    return visitor;
}

static NSArray<WolFoxStreamOption *> *WolFoxDirectOptions(NSString *videoID, WolFoxDirectTask *task,
                                                          NSString **reason) {
    Class responseClass = NSClassFromString(@"YTIPlayerResponse");
    SEL initSelector = NSSelectorFromString(@"initWithData:error:");
    if (responseClass == Nil || ![responseClass instancesRespondToSelector:initSelector]) {
        if (reason != NULL) *reason = @"player response class unavailable";
        return @[];
    }
    for (NSInteger attempt = 0; attempt < 2 && !task.cancelled; attempt++) {
        NSString *visitor = WolFoxDirectVisitor(attempt > 0, task);
        NSDictionary *body = @{@"context": WolFoxDirectContext(visitor), @"videoId": videoID,
                               @"contentCheckOk": @YES, @"racyCheckOk": @YES};
        NSInteger status = 0;
        NSData *proto = WolFoxDirectFetch(
            WolFoxDirectAPIRequest(@"player?alt=proto", body, visitor), task, &status, NULL);
        id response = proto.length != 0
            ? ((id (*)(id, SEL, id, NSError **))objc_msgSend)(
                [responseClass alloc], initSelector, proto, NULL) : nil;
        NSMutableArray<WolFoxStreamOption *> *options = [NSMutableArray array];
        for (WolFoxStreamOption *option in [WolFoxStreamResolver optionsFromPlayerResponse:response]) {
            if (option.URL != nil && option.adaptive) [options addObject:option];
        }
        if (options.count != 0) return options;
        id playability = [response valueForKey:@"playabilityStatus"];
        if (reason != NULL) {
            *reason = [NSString stringWithFormat:@"no direct formats http=%ld reason=%@",
                (long)status, [playability valueForKey:@"reason"] ?: @"none"];
        }
    }
    return @[];
}

static NSString *WolFoxDirectCodec(WolFoxStreamOption *option) {
    NSString *mime = option.mimeType ?: @"";
    NSRange codecs = [mime rangeOfString:@"codecs=\""];
    if (codecs.location == NSNotFound) return mime;
    NSString *rest = [mime substringFromIndex:NSMaxRange(codecs)];
    NSRange dot = [rest rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@".\""]];
    NSString *family = dot.location == NSNotFound ? rest : [rest substringToIndex:dot.location];
    NSString *container = [mime componentsSeparatedByString:@";"].firstObject ?: @"";
    return [NSString stringWithFormat:@"%@|%@", container, family];
}

static WolFoxStreamOption *WolFoxDirectMatch(NSArray<WolFoxStreamOption *> *options,
                                             WolFoxStreamOption *wanted, BOOL audio) {
    NSMutableArray<WolFoxStreamOption *> *pool = [NSMutableArray array];
    for (WolFoxStreamOption *option in options) {
        if (option.audioOnly == audio) [pool addObject:option];
    }
    if (pool.count == 0) return nil;
    if (wanted == nil) return pool.firstObject;
    BOOL wantsTrack = audio && wanted.audioTrackID.length != 0;
    for (WolFoxStreamOption *option in pool) {
        if (option.itag == wanted.itag &&
            (!wantsTrack || [option.audioTrackID isEqualToString:wanted.audioTrackID])) {
            return option;
        }
    }
    for (WolFoxStreamOption *option in pool) {
        if (option.itag == wanted.itag) return option;
    }
    NSString *codec = WolFoxDirectCodec(wanted);
    for (WolFoxStreamOption *option in pool) {
        if (![WolFoxDirectCodec(option) isEqualToString:codec]) continue;
        if (audio) {
            if (!wantsTrack || [option.audioTrackID isEqualToString:wanted.audioTrackID]) return option;
        } else if (option.height == wanted.height) {
            return option;
        }
    }
    return nil;
}

@interface WolFoxDirectJob : NSObject
@property(nonatomic, copy) NSString *videoID;
@property(nonatomic, copy) NSString *identifier;
@property(nonatomic, strong) WolFoxDirectTask *task;
@property(nonatomic, copy) NSArray<WolFoxStreamOption *> *options;
@end

@implementation WolFoxDirectJob

- (BOOL)refreshOptions {
    NSString *reason = nil;
    NSArray *options = WolFoxDirectOptions(self.videoID, self.task, &reason);
    if (options.count == 0) {
        WolFoxDownloadLog(self.identifier, @"direct refresh failed %@", reason ?: @"");
        return NO;
    }
    self.options = options;
    return YES;
}

- (BOOL)downloadOption:(WolFoxStreamOption *)option
                 audio:(BOOL)audio
                toFile:(NSURL *)file
              progress:(void (^)(int64_t bytes))progress
                 error:(NSError **)error {
    [NSFileManager.defaultManager createFileAtPath:file.path contents:nil attributes:nil];
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingToURL:file error:error];
    if (handle == nil) return NO;
    WolFoxStreamOption *current = option;
    int64_t total = MAX((int64_t)current.contentLength, 0);
    int64_t offset = 0;
    BOOL finished = NO;
    while (!finished) {
        if (self.task.cancelled) {
            [handle closeFile];
            if (error != NULL) *error = [NSError errorWithDomain:NSURLErrorDomain
                code:NSURLErrorCancelled userInfo:nil];
            return NO;
        }
        int64_t end = total > 0 ? MIN(offset + WolFoxDirectChunkSize, total) - 1
                                : offset + WolFoxDirectChunkSize - 1;
        NSData *chunk = nil;
        NSInteger status = 0;
        for (NSInteger attempt = 0; attempt < WolFoxDirectChunkAttempts && chunk == nil; attempt++) {
            if (self.task.cancelled) break;
            if (attempt > 0) [NSThread sleepForTimeInterval:0.6 * attempt];
            NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:current.URL];
            [request setValue:[NSString stringWithFormat:@"bytes=%lld-%lld", offset, end]
                forHTTPHeaderField:@"Range"];
            [request setValue:WolFoxDirectUserAgent forHTTPHeaderField:@"User-Agent"];
            request.timeoutInterval = 45.0;
            NSError *fetchError = nil;
            int64_t chunkStart = offset;
            NSData *data = WolFoxDirectFetchChunk(request, self.task, ^(int64_t bytes) {
                if (progress != nil) progress(chunkStart + bytes);
            }, &status, &fetchError);
            BOOL ok = (status == 206 || status == 200) && data.length != 0 &&
                (total <= 0 || (int64_t)data.length == end - offset + 1);
            if (ok) {
                chunk = data;
                break;
            }
            WolFoxDownloadLog(self.identifier, @"direct chunk retry itag=%ld offset=%lld http=%ld error=%@",
                (long)current.itag, offset, (long)status, fetchError.localizedDescription ?: @"none");
            if ((status == 403 || status == 410 || attempt == 1) && [self refreshOptions]) {
                WolFoxStreamOption *renewed = WolFoxDirectMatch(self.options, current, audio);
                if (renewed != nil) current = renewed;
            }
        }
        if (chunk == nil) {
            [handle closeFile];
            if (error != NULL) {
                *error = self.task.cancelled
                    ? [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCancelled userInfo:nil]
                    : WolFoxDirectError(3, [NSString stringWithFormat:
                        @"chunk failed at %lld http=%ld", offset, (long)status]);
            }
            return NO;
        }
        [handle writeData:chunk];
        offset += (int64_t)chunk.length;
        if (progress != nil) progress(offset);
        finished = total > 0 ? offset >= total : (int64_t)chunk.length < WolFoxDirectChunkSize;
    }
    [handle closeFile];
    return YES;
}

@end

@implementation WolFoxDirectDownloader

+ (void)fetchOptionsForVideoID:(NSString *)videoID
                    completion:(void (^)(NSArray<WolFoxStreamOption *> *options))completion {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *reason = nil;
        NSArray *options = videoID.length == 0 ? @[] :
            WolFoxDirectOptions(videoID, [WolFoxDirectTask new], &reason);
        WolFoxDownloadLog(@"direct", @"formats video=%@ count=%lu %@", videoID,
            (unsigned long)options.count, reason ?: @"");
        dispatch_async(dispatch_get_main_queue(), ^{ completion(options); });
    });
}

+ (NSString *)codecNameForOption:(WolFoxStreamOption *)option {
    NSString *mime = option.mimeType.lowercaseString ?: @"";
    if ([mime containsString:@"avc1"]) return @"H.264";
    if ([mime containsString:@"av01"]) return @"AV1";
    if ([mime containsString:@"vp9"] || [mime containsString:@"vp09"]) return @"VP9";
    if ([mime containsString:@"opus"]) return @"Opus";
    if ([mime containsString:@"mp4a"]) return @"AAC";
    return [mime componentsSeparatedByString:@";"].firstObject ?: @"";
}

+ (WolFoxDirectTask *)downloadVideoID:(NSString *)videoID
                          videoOption:(WolFoxStreamOption *)videoOption
                          audioOption:(WolFoxStreamOption *)audioOption
                            audioOnly:(BOOL)audioOnly
                           identifier:(NSString *)identifier
                             progress:(WolFoxSABRProgress)progress
                           completion:(WolFoxSABRCompletion)completion {
    WolFoxDirectTask *task = [WolFoxDirectTask new];
    WolFoxDirectJob *job = [WolFoxDirectJob new];
    job.videoID = videoID;
    job.identifier = identifier;
    job.task = task;
    void (^finish)(NSURL *, NSURL *, NSError *) = ^(NSURL *video, NSURL *audio, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(video, audio, error); });
    };
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        if (videoID.length == 0) {
            finish(nil, nil, WolFoxDirectError(1, @"missing video id"));
            return;
        }
        if (![job refreshOptions]) {
            finish(nil, nil, WolFoxDirectError(1, @"no direct formats"));
            return;
        }
        WolFoxStreamOption *video = audioOnly ? nil : WolFoxDirectMatch(job.options, videoOption, NO);
        WolFoxStreamOption *audio = WolFoxDirectMatch(job.options, audioOption, YES);
        if (audio == nil || (!audioOnly && video == nil)) {
            finish(nil, nil, WolFoxDirectError(4, @"selected format not offered directly"));
            return;
        }
        WolFoxDownloadLog(identifier, @"direct start video=%ld audio=%ld",
            (long)video.itag, (long)audio.itag);
        NSURL *directory = [[NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES]
            URLByAppendingPathComponent:[NSString stringWithFormat:@"WolFox-%@",
                NSUUID.UUID.UUIDString] isDirectory:YES];
        [NSFileManager.defaultManager createDirectoryAtURL:directory
            withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *(^extension)(WolFoxStreamOption *) = ^NSString *(WolFoxStreamOption *option) {
            return [option.mimeType containsString:@"webm"] ? @"webm" :
                ([option.mimeType hasPrefix:@"audio/"] ? @"m4a" : @"mp4");
        };
        NSURL *videoURL = video == nil ? nil : [directory URLByAppendingPathComponent:
            [@"video." stringByAppendingString:extension(video)]];
        NSURL *audioURL = [directory URLByAppendingPathComponent:
            [@"audio." stringByAppendingString:extension(audio)]];
        __block int64_t videoBytes = 0;
        __block int64_t audioBytes = 0;
        int64_t videoTotal = MAX((int64_t)video.contentLength, 1);
        int64_t audioTotal = MAX((int64_t)audio.contentLength, 1);
        void (^report)(NSInteger) = ^(NSInteger phase) {
            if (progress == nil) return;
            double audioProgress = MIN(1.0, (double)audioBytes / (double)audioTotal);
            double videoProgress = MIN(1.0, (double)videoBytes / (double)videoTotal);
            int64_t a = audioBytes, v = videoBytes;
            dispatch_async(dispatch_get_main_queue(), ^{
                progress(audioProgress, videoProgress, a, v, phase);
            });
        };
        NSError *error = nil;
        if (video != nil && ![job downloadOption:video audio:NO toFile:videoURL
                progress:^(int64_t bytes) { videoBytes = bytes; report(0); } error:&error]) {
            [NSFileManager.defaultManager removeItemAtURL:directory error:nil];
            WolFoxDownloadLog(identifier, @"direct video failed %@", error.localizedDescription);
            finish(nil, nil, error);
            return;
        }
        if (![job downloadOption:audio audio:YES toFile:audioURL
                progress:^(int64_t bytes) { audioBytes = bytes; report(1); } error:&error]) {
            [NSFileManager.defaultManager removeItemAtURL:directory error:nil];
            WolFoxDownloadLog(identifier, @"direct audio failed %@", error.localizedDescription);
            finish(nil, nil, error);
            return;
        }
        WolFoxDownloadLog(identifier, @"direct complete video=%lld audio=%lld",
            videoBytes, audioBytes);
        finish(videoURL, audioURL, nil);
    });
    return task;
}

@end
