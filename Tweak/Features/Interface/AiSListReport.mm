#import "AiSList.h"
#import "../Downloads/DownloadLog.h"
#import "../../Runtime/Localization.h"
#import "../../Runtime/Preferences.h"
#import "../../UI/Notice.h"
#import "../../UI/OverlayButtonHost.h"

#import <UIKit/UIKit.h>
#import <objc/message.h>

static NSString * const WolFoxAiSListReportKey = @"YTKACE.Preference.Feed.AIChannelReporting";
static NSString * const WolFoxAiSListNameKey = @"YTKACE.Preference.Feed.AIReportName";

BOOL WolFoxAiSListReportingEnabled(void) {
    return WolFoxFeatureEnabled(WolFoxAiSListReportKey);
}

static NSString *WolFoxAiSListHandleFromURL(NSString *url) {
    if (![url isKindOfClass:NSString.class]) return nil;
    NSRange at = [url rangeOfString:@"/@"];
    if (at.location == NSNotFound) return nil;
    NSString *handle = [url substringFromIndex:at.location + 1];
    NSRange end = [handle rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"/?#"]];
    if (end.location != NSNotFound) handle = [handle substringToIndex:end.location];
    handle = handle.stringByRemovingPercentEncoding ?: handle;
    return handle.length >= 3 && handle.length <= 31 ? handle : nil;
}

void WolFoxLookupChannelHandle(NSString *videoID, void (^completion)(NSString *handle, NSString *channel,
                                                                     NSString *title)) {
    static NSCache<NSString *, NSDictionary *> *cache;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ cache = [NSCache new]; });
    NSDictionary *cached = videoID.length != 0 ? [cache objectForKey:videoID] : nil;
    if (cached != nil) {
        completion(cached[@"handle"], cached[@"channel"], cached[@"title"]);
        return;
    }
    NSURLComponents *components = [NSURLComponents componentsWithString:@"https://www.youtube.com/oembed"];
    components.queryItems = @[
        [NSURLQueryItem queryItemWithName:@"url"
                                    value:[@"https://www.youtube.com/watch?v=" stringByAppendingString:videoID]],
        [NSURLQueryItem queryItemWithName:@"format" value:@"json"]
    ];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:components.URL];
    request.timeoutInterval = 15.0;
    [[NSURLSession.sharedSession dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class]
            ? ((NSHTTPURLResponse *)response).statusCode : 0;
        id json = data != nil ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        NSDictionary *info = [json isKindOfClass:NSDictionary.class] ? json : nil;
        NSString *author = info[@"author_url"];
        NSString *name = [info[@"author_name"] isKindOfClass:NSString.class] ? info[@"author_name"] : nil;
        NSString *title = [info[@"title"] isKindOfClass:NSString.class] ? info[@"title"] : nil;
        NSString *handle = WolFoxAiSListHandleFromURL(author);
        WolFoxDebugLog(@"aislist", @"lookup video=%@ status=%ld author=%@ handle=%@ error=%@", videoID,
                       (long)status, author ?: @"-", handle ?: @"-", error.localizedDescription ?: @"-");
        if (handle.length != 0) {
            NSMutableDictionary *entry = [NSMutableDictionary dictionaryWithObject:handle forKey:@"handle"];
            if (name != nil) entry[@"channel"] = name;
            if (title != nil) entry[@"title"] = title;
            [cache setObject:entry forKey:videoID];
        }
        dispatch_async(dispatch_get_main_queue(), ^{ completion(handle, name, title); });
    }] resume];
}

static NSString *WolFoxAiSListResultMessage(NSInteger status) {
    switch (status) {
        case 200: return WolFoxLocalized(@"Reported to AiSList");
        case 409: return WolFoxLocalized(@"This channel was already reported");
        case 429: return WolFoxLocalized(@"Too many reports. Try again later.");
        case 400: return WolFoxLocalized(@"AiSList could not accept this report");
        default: return WolFoxLocalized(@"Could not reach AiSList");
    }
}

static void WolFoxAiSListSubmit(NSString *handle, NSString *videoID, NSString *name) {
    NSDictionary *body = @{
        @"channel_handle": handle,
        @"video_url": [@"https://youtu.be/" stringByAppendingString:videoID],
        @"username": name
    };
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:
        [NSURL URLWithString:@"https://api.aisloplist.com"]];
    request.HTTPMethod = @"POST";
    request.timeoutInterval = 20.0;
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:@"WolFox" forHTTPHeaderField:@"User-Agent"];
    request.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    [[NSURLSession.sharedSession dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class]
            ? ((NSHTTPURLResponse *)response).statusCode : 0;
        NSString *text = data.length != 0 ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
        WolFoxDownloadLog(@"aislist", @"report %@ video=%@ status=%ld", handle, videoID, (long)status);
        WolFoxDebugLog(@"aislist", @"report response=%@ error=%@",
                       text.length > 300 ? [text substringToIndex:300] : (text ?: @"-"),
                       error.localizedDescription ?: @"-");
        dispatch_async(dispatch_get_main_queue(), ^{
            WolFoxShowNotice(WolFoxAiSListResultMessage(status));
        });
    }] resume];
}

static void WolFoxAiSListConfirm(NSString *handle, NSString *channel, NSString *videoID) {
    NSString *name = [NSUserDefaults.standardUserDefaults stringForKey:WolFoxAiSListNameKey];
    if (name.length == 0) name = @"WolFox";
    UIImage *icon = [[UIImage systemImageNamed:@"flag"] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    WolFoxPresentNativeSheet(channel.length != 0 ? channel : handle, channel.length != 0 ? handle : nil, nil, @[
        @{@"title": WolFoxLocalized(@"Report as AI channel"),
          @"icon": icon ?: [UIImage new],
          @"handler": [^{ WolFoxAiSListSubmit(handle, videoID, name); } copy]}
    ]);
}

void WolFoxAiSListReportVideo(NSString *videoID) {
    if (videoID.length != 11) return;
    WolFoxShowNotice(WolFoxLocalized(@"Finding channel…"));
    WolFoxLookupChannelHandle(videoID, ^(NSString *handle, NSString *channel, __unused NSString *title) {
        if (handle.length == 0) {
            WolFoxShowNotice(WolFoxLocalized(@"Could not find this channel's handle"));
            return;
        }
        WolFoxAiSListConfirm(handle, channel, videoID);
    });
}

static NSString *WolFoxAiSListMenuVideoID(id renderers) {
    static NSRegularExpression *expression;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        expression = [NSRegularExpression regularExpressionWithPattern:@"video_?[Ii]d:\\s*\"([A-Za-z0-9_-]{11})\""
                                                               options:0 error:NULL];
    });
    NSArray *items = [renderers isKindOfClass:NSArray.class] ? renderers : (renderers != nil ? @[renderers] : @[]);
    NSString *found = nil;
    for (id item in items) {
        NSString *dump = nil;
        @try {
            dump = [item description];
        } @catch (__unused NSException *exception) {
            continue;
        }
        if (dump.length == 0) continue;
        for (NSTextCheckingResult *match in [expression matchesInString:dump options:0
                                                                   range:NSMakeRange(0, dump.length)]) {
            NSString *videoID = [dump substringWithRange:[match rangeAtIndex:1]];
            if (found == nil) found = videoID;
            else if (![found isEqualToString:videoID]) return nil;
        }
    }
    return found;
}

id WolFoxAiSListAppendMenuAction(id renderers, id actions) {
    if (!WolFoxAiSListReportingEnabled()) return actions;
    Class actionClass = NSClassFromString(@"YTActionSheetAction");
    NSString *videoID = WolFoxAiSListMenuVideoID(renderers);
    WolFoxDebugLog(@"aislist", @"menu actions=%@ count=%lu first=%@ renderers=%@ video=%@",
                      NSStringFromClass([actions class]),
                      (unsigned long)([actions isKindOfClass:NSArray.class] ? [actions count] : 0),
                      [actions isKindOfClass:NSArray.class] ? NSStringFromClass([[actions firstObject] class]) : @"-",
                      NSStringFromClass([renderers class]), videoID ?: @"-");
    if (![actions isKindOfClass:NSArray.class] || [actions count] == 0) return actions;
    if (actionClass == Nil || ![[actions firstObject] isKindOfClass:actionClass]) return actions;
    if (videoID.length == 0) return actions;
    SEL make = NSSelectorFromString(@"actionWithTitle:iconImage:style:handler:");
    if (![actionClass respondsToSelector:make]) return actions;
    UIImage *icon = [[UIImage systemImageNamed:@"flag"]
        imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    void (^handler)(void) = ^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            WolFoxAiSListReportVideo(videoID);
        });
    };
    id action = ((id (*)(id, SEL, id, id, NSInteger, id))objc_msgSend)(
        actionClass, make, WolFoxLocalized(@"Report AI Channel"), icon, 0, handler);
    if (action == nil) return actions;
    WolFoxDebugLog(@"aislist", @"menu action added video=%@ count=%lu", videoID, (unsigned long)[actions count]);
    return [(NSArray *)actions arrayByAddingObject:action];
}
