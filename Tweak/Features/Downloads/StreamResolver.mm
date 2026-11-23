#import "StreamResolver.h"
#import "DownloadLog.h"
#import "../../Runtime/Localization.h"

#import <UIKit/UIKit.h>
#import <VideoToolbox/VideoToolbox.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <stdlib.h>
#import <string.h>

@implementation WolFoxStreamOption
@end

static id WolFoxStreamObject(id receiver, NSArray<NSString *> *selectors) {
    for (NSString *name in selectors) {
        SEL selector = NSSelectorFromString(name);
        if ([receiver respondsToSelector:selector]) {
            id value = ((id (*)(id, SEL))objc_msgSend)(receiver, selector);
            if (value != nil) {
                return value;
            }
        }
    }
    return nil;
}

static NSInteger WolFoxStreamInteger(id receiver, NSArray<NSString *> *selectors) {
    for (NSString *name in selectors) {
        SEL selector = NSSelectorFromString(name);
        if ([receiver respondsToSelector:selector]) {
            return ((NSInteger (*)(id, SEL))objc_msgSend)(receiver, selector);
        }
    }
    return 0;
}

static NSArray *WolFoxArrayValue(id receiver, NSArray<NSString *> *selectors) {
    id value = WolFoxStreamObject(receiver, selectors);
    return [value isKindOfClass:NSArray.class] ? value : @[];
}

static NSURL *WolFoxURLValue(id value) {
    if ([value isKindOfClass:NSURL.class]) {
        return value;
    }
    if ([value isKindOfClass:NSString.class]) {
        return [NSURL URLWithString:value];
    }
    return nil;
}

static id WolFoxFindNestedObject(id object,
                                 NSString *target,
                                 NSHashTable *visited,
                                 NSUInteger depth) {
    if (object == nil || depth > 8 || [visited containsObject:object]) {
        return nil;
    }
    [visited addObject:object];
    id value = WolFoxStreamObject(object, @[target]);
    if (value != nil) {
        return value;
    }
    for (NSString *name in @[@"playerData", @"contentPlayerResponse",
                              @"playerResponse", @"playbackData", @"video",
                              @"response", @"shortsPlayerData"]) {
        id nested = WolFoxStreamObject(object, @[name]);
        id found = WolFoxFindNestedObject(nested, target, visited, depth + 1);
        if (found != nil) {
            return found;
        }
    }
    return nil;
}

static id WolFoxNestedObject(id object, NSString *target) {
    NSHashTable *visited = [NSHashTable hashTableWithOptions:
        NSPointerFunctionsObjectPointerPersonality];
    return WolFoxFindNestedObject(object, target, visited, 0);
}

static NSString *WolFoxStringValue(id value) {
    if ([value isKindOfClass:NSString.class]) {
        return value;
    }
    for (NSString *name in @[@"text", @"string", @"simpleText"]) {
        id nested = WolFoxStreamObject(value, @[name]);
        if ([nested isKindOfClass:NSString.class]) {
            return nested;
        }
    }
    return nil;
}

static NSInteger WolFoxQualityHeight(NSString *label) {
    NSScanner *scanner = [NSScanner scannerWithString:label ?: @""];
    NSInteger height = 0;
    return [scanner scanInteger:&height] ? height : 0;
}

static NSInteger WolFoxVideoPreference(WolFoxStreamOption *option) {
    NSString *mime = option.mimeType.lowercaseString;
    if ([mime containsString:@"avc1"]) return 4;
    if ([mime containsString:@"av01"] || [mime containsString:@"av1"]) return 3;
    if ([mime containsString:@"vp09"] || [mime containsString:@"vp9"]) return 2;
    if ([mime containsString:@"video/mp4"]) return 1;
    return 0;
}

static BOOL WolFoxHighResolutionSupported(WolFoxStreamOption *option) {
    if (option.height <= 1080) return YES;
    NSString *mime = option.mimeType.lowercaseString;
    if ([mime containsString:@"av01"] || [mime containsString:@"av1"]) {
        return VTIsHardwareDecodeSupported('av01');
    }
    if ([mime containsString:@"vp09"] || [mime containsString:@"vp9"]) {
        return VTIsHardwareDecodeSupported('vp09');
    }
    if ([mime containsString:@"hvc1"] || [mime containsString:@"hev1"] ||
        [mime containsString:@"hevc"]) {
        return VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC);
    }
    if ([mime containsString:@"avc1"] || [mime containsString:@"h264"]) {
        return VTIsHardwareDecodeSupported(kCMVideoCodecType_H264);
    }
    return NO;
}

static NSString *WolFoxVideoRejectReason(WolFoxStreamOption *option) {
    if (![option.mimeType hasPrefix:@"video/"]) return @"not video";
    if (option.itag <= 0) return @"no itag";
    if (![option.mimeType containsString:@"video/mp4"] &&
        ![option.mimeType containsString:@"video/webm"]) {
        return @"container unsupported";
    }
    if (option.height <= 0) return @"no height";
    if (!WolFoxHighResolutionSupported(option)) return @"no hardware decode";
    return nil;
}

static id WolFoxPlayerData(id playerResponse) {
    return WolFoxNestedObject(playerResponse, @"playerData") ?: playerResponse;
}

static id WolFoxVideoDetails(id playerResponse) {
    return WolFoxNestedObject(playerResponse, @"videoDetails") ?:
        WolFoxPlayerData(playerResponse);
}

static id WolFoxStreamingData(id playerResponse) {
    id direct = WolFoxStreamObject(playerResponse, @[@"streamingData"]);
    return direct ?: WolFoxStreamObject(WolFoxPlayerData(playerResponse),
                                         @[@"streamingData"]);
}


static WolFoxStreamOption *WolFoxOptionFromFormat(id format, BOOL adaptive) {
    NSURL *url = WolFoxURLValue(WolFoxStreamObject(format, @[@"URL", @"url"]));
    if (url != nil && ![url.scheme.lowercaseString hasPrefix:@"http"]) {
        url = nil;
    }

    NSString *mime = WolFoxStreamObject(format, @[@"mimeType"]);
    if (![mime isKindOfClass:NSString.class]) {
        mime = @"application/octet-stream";
    }

    WolFoxStreamOption *option = [WolFoxStreamOption new];
    option.URL = url;
    option.mimeType = mime;
    option.qualityLabel = WolFoxStreamObject(format, @[@"qualityLabel", @"audioQuality"]) ?: @"";
    option.xtags = WolFoxStreamObject(format, @[@"xtags"]) ?: @"";
    option.bitrate = WolFoxStreamInteger(format, @[@"bitrate"]);
    option.itag = WolFoxStreamInteger(format, @[@"itag"]);
    option.contentLength = WolFoxStreamInteger(format, @[@"contentLength"]);
    option.lastModified = WolFoxStreamInteger(format, @[@"lastModified"]);
    option.width = WolFoxStreamInteger(format, @[@"width"]);
    option.height = WolFoxStreamInteger(format, @[@"height"]);
    option.audioOnly = [mime hasPrefix:@"audio/"] ||
        (adaptive && ![mime hasPrefix:@"video/"]);
    option.adaptive = adaptive;
    option.rawFormat = format;
    id audioTrack = WolFoxStreamObject(format, @[@"audioTrack"]);
    NSString *language = WolFoxStringValue(WolFoxStreamObject(
        audioTrack, @[@"displayName", @"display_name", @"name"]));
    if (language.length == 0) {
        NSString *description = [audioTrack description];
        NSRange marker = [description rangeOfString:@"display_name: \""];
        if (marker.location != NSNotFound) {
            NSUInteger start = NSMaxRange(marker);
            NSRange rest = NSMakeRange(start, description.length - start);
            NSRange end = [description rangeOfString:@"\"" options:0 range:rest];
            if (end.location != NSNotFound) {
                language = [description substringWithRange:
                    NSMakeRange(start, end.location - start)];
            }
        }
    }
    option.languageLabel = language.length != 0 ? language : WolFoxLocalized(@"Original audio");
    NSString *trackID = WolFoxStringValue(WolFoxStreamObject(
        audioTrack, @[@"id_p", @"audioTrackId", @"audioTrackID"]));
    if (trackID.length == 0) {
        NSString *description = [audioTrack description];
        NSRange marker = [description rangeOfString:@"id: \""];
        if (marker.location != NSNotFound) {
            NSUInteger start = NSMaxRange(marker);
            NSRange rest = NSMakeRange(start, description.length - start);
            NSRange end = [description rangeOfString:@"\"" options:0 range:rest];
            if (end.location != NSNotFound) {
                trackID = [description substringWithRange:
                    NSMakeRange(start, end.location - start)];
            }
        }
    }
    option.audioTrackID = trackID ?: @"";
    option.defaultAudio = WolFoxStreamInteger(
        audioTrack, @[@"audioIsDefault", @"isDefault", @"defaultAudio"]) != 0;
    return option;
}

@implementation WolFoxStreamResolver

+ (NSArray<WolFoxStreamOption *> *)optionsFromPlayerResponse:(id)playerResponse {
    id streamingData = WolFoxStreamingData(playerResponse);
    if (streamingData == nil) {
        return @[];
    }
    NSMutableArray<WolFoxStreamOption *> *result = [NSMutableArray array];
    for (id format in WolFoxArrayValue(streamingData, @[@"formatsArray", @"formats"])) {
        WolFoxStreamOption *option = WolFoxOptionFromFormat(format, NO);
        if (option != nil) {
            [result addObject:option];
        }
    }
    for (id format in WolFoxArrayValue(
             streamingData,
             @[@"adaptiveFormatsArray", @"adaptiveFormats"])) {
        WolFoxStreamOption *option = WolFoxOptionFromFormat(format, YES);
        if (option != nil) {
            [result addObject:option];
        }
    }
    return result;
}

+ (NSArray<WolFoxStreamOption *> *)videoOptionsFromPlayerResponse:(id)playerResponse {
    NSArray *options = [self optionsFromPlayerResponse:playerResponse];
    NSMutableDictionary<NSString *, WolFoxStreamOption *> *byQuality =
        [NSMutableDictionary dictionary];
    WolFoxDownloadLog(@"quality", @"formats=%lu video=%@ decode avc1=%d hevc=%d vp9=%d av1=%d",
        (unsigned long)options.count,
        [self videoIDFromPlayerResponse:playerResponse] ?: @"?",
        VTIsHardwareDecodeSupported(kCMVideoCodecType_H264),
        VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC),
        VTIsHardwareDecodeSupported('vp09'),
        VTIsHardwareDecodeSupported('av01'));
    for (WolFoxStreamOption *option in options) {
        if (option.height <= 0) {
            option.height = WolFoxQualityHeight(option.qualityLabel);
        }
        NSString *reason = WolFoxVideoRejectReason(option);
        if (reason != nil) {
            if (option.height >= 1080) {
                WolFoxDownloadLog(@"quality", @"dropped itag=%ld %@ %@ -> %@",
                    (long)option.itag,
                    option.qualityLabel.length != 0 ? option.qualityLabel : @"-",
                    option.mimeType, reason);
            }
            continue;
        }
        NSString *key = option.qualityLabel.length != 0
            ? option.qualityLabel : [NSString stringWithFormat:@"%ldp", (long)option.height];
        WolFoxStreamOption *current = byQuality[key];
        NSInteger preference = WolFoxVideoPreference(option);
        NSInteger currentPreference = WolFoxVideoPreference(current);
        if (current == nil || preference > currentPreference ||
            (preference == currentPreference && option.bitrate > current.bitrate)) {
            byQuality[key] = option;
        }
    }
    WolFoxDownloadLog(@"quality", @"offering %@",
        [[byQuality.allKeys sortedArrayUsingSelector:@selector(compare:)]
            componentsJoinedByString:@", "]);
    return [byQuality.allValues sortedArrayUsingComparator:
        ^NSComparisonResult(WolFoxStreamOption *left, WolFoxStreamOption *right) {
            if (left.height == right.height) {
                return left.bitrate > right.bitrate ? NSOrderedAscending : NSOrderedDescending;
            }
            return left.height > right.height ? NSOrderedAscending : NSOrderedDescending;
        }];
}

+ (NSArray<WolFoxStreamOption *> *)audioOptionsFromPlayerResponse:(id)playerResponse {
    NSArray *options = [self optionsFromPlayerResponse:playerResponse];
    NSMutableDictionary<NSString *, WolFoxStreamOption *> *byLanguage =
        [NSMutableDictionary dictionary];
    for (WolFoxStreamOption *option in options) {
        if (![option.mimeType hasPrefix:@"audio/mp4"]) {
            continue;
        }
        NSString *key = option.languageLabel.length != 0
            ? option.languageLabel : WolFoxLocalized(@"Original audio");
        WolFoxStreamOption *current = byLanguage[key];
        if (current == nil || option.isDefaultAudio || option.bitrate > current.bitrate) {
            byLanguage[key] = option;
        }
    }
    return [byLanguage.allValues sortedArrayUsingComparator:
        ^NSComparisonResult(WolFoxStreamOption *left, WolFoxStreamOption *right) {
            if (left.isDefaultAudio != right.isDefaultAudio) {
                return left.isDefaultAudio ? NSOrderedAscending : NSOrderedDescending;
            }
            return [left.languageLabel localizedCaseInsensitiveCompare:right.languageLabel];
        }];
}

+ (WolFoxStreamOption *)bestPiPVideoFromPlayerResponse:(id)playerResponse {
    id streamingData = WolFoxStreamingData(playerResponse);
    NSURL *hls = WolFoxURLValue(WolFoxStreamObject(
        streamingData,
        @[@"hlsManifestURL", @"hlsManifestUrl"]
    ));
    if (hls != nil) {
        WolFoxStreamOption *option = [WolFoxStreamOption new];
        option.URL = hls;
        option.mimeType = @"application/x-mpegURL";
        option.qualityLabel = @"HLS";
        return option;
    }
    return [self bestVideoFromPlayerResponse:playerResponse];
}

+ (WolFoxStreamOption *)bestVideoFromPlayerResponse:(id)playerResponse {
    NSArray<WolFoxStreamOption *> *options = [self optionsFromPlayerResponse:playerResponse];
    NSPredicate *video = [NSPredicate predicateWithBlock:
        ^BOOL(WolFoxStreamOption *option, NSDictionary *bindings) {
            (void)bindings;
            return !option.isAdaptive &&
                !option.isAudioOnly &&
                [option.mimeType hasPrefix:@"video/"];
        }];
    return [[options filteredArrayUsingPredicate:video]
        sortedArrayUsingComparator:^NSComparisonResult(WolFoxStreamOption *left,
                                                        WolFoxStreamOption *right) {
            if (left.bitrate == right.bitrate) {
                return NSOrderedSame;
            }
            return left.bitrate > right.bitrate ? NSOrderedAscending : NSOrderedDescending;
        }].firstObject;
}

+ (WolFoxStreamOption *)bestAudioFromPlayerResponse:(id)playerResponse {
    NSArray<WolFoxStreamOption *> *options = [self optionsFromPlayerResponse:playerResponse];
    NSPredicate *audio = [NSPredicate predicateWithBlock:
        ^BOOL(WolFoxStreamOption *option, NSDictionary *bindings) {
            (void)bindings;
            return option.isAudioOnly || [option.mimeType hasPrefix:@"audio/"];
        }];
    return [[options filteredArrayUsingPredicate:audio]
        sortedArrayUsingComparator:^NSComparisonResult(WolFoxStreamOption *left,
                                                        WolFoxStreamOption *right) {
            if (left.bitrate == right.bitrate) {
                return NSOrderedSame;
            }
            return left.bitrate > right.bitrate ? NSOrderedAscending : NSOrderedDescending;
        }].firstObject;
}

+ (NSString *)titleFromPlayerResponse:(id)playerResponse {
    id details = WolFoxVideoDetails(playerResponse);
    NSString *title = WolFoxStringValue(WolFoxStreamObject(
        details, @[@"title", @"videoTitle", @"headline"]));
    return title.length != 0
        ? title
        : @"YouTube Video";
}

+ (NSString *)authorFromPlayerResponse:(id)playerResponse {
    id details = WolFoxVideoDetails(playerResponse);
    NSString *author = WolFoxStringValue(WolFoxStreamObject(
        details, @[@"author", @"channelTitle", @"ownerChannelName"]));
    return author.length != 0
        ? author : @"YouTube";
}

+ (NSString *)descriptionFromPlayerResponse:(id)playerResponse {
    id details = WolFoxVideoDetails(playerResponse);
    id description = WolFoxStreamObject(details,
        @[@"shortDescription", @"videoDescription", @"descriptionText"]);
    return [description isKindOfClass:NSString.class]
        ? description : @"";
}

+ (NSString *)videoIDFromPlayerResponse:(id)playerResponse {
    id details = WolFoxVideoDetails(playerResponse);
    id videoID = WolFoxStreamObject(details, @[@"videoId", @"videoID"]);
    if (![videoID isKindOfClass:NSString.class] || [videoID length] == 0) {
        videoID = WolFoxStreamObject(playerResponse, @[@"videoId", @"videoID"]);
    }
    return [videoID isKindOfClass:NSString.class] ? videoID : nil;
}

+ (NSURL *)thumbnailURLFromPlayerResponse:(id)playerResponse {
    id details = WolFoxVideoDetails(playerResponse);
    id thumbnail = WolFoxStreamObject(details, @[@"thumbnail"]);
    NSArray *items = WolFoxArrayValue(thumbnail, @[@"thumbnailsArray", @"thumbnails"]);
    id candidate = items.lastObject;
    return WolFoxURLValue(WolFoxStreamObject(candidate, @[@"URL", @"url"]));
}

@end
