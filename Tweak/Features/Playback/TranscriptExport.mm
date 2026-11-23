#import "../../WolFox.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"
#import "../../Runtime/Localization.h"
#import "../../UI/Assets.h"
#import "../../UI/Notice.h"
#import "../../UI/OverlayButtonHost.h"
#import "../Downloads/DownloadLog.h"

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

static NSString *const WolFoxTranscriptKey =
    @"YTKACE.Preference.Playback.Transcript";

static id WolFoxTranscriptSend(id receiver, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    if (receiver == nil || ![receiver respondsToSelector:selector]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(receiver, selector);
}

static id WolFoxTranscriptPlayer(UIView *view) {
    UIResponder *responder = view;
    while (responder != nil) {
        if ([responder respondsToSelector:NSSelectorFromString(@"activeVideo")]) {
            return responder;
        }
        responder = responder.nextResponder;
    }
    return nil;
}

static NSArray *WolFoxTranscriptTracks(id player) {
    id video = WolFoxTranscriptSend(player, @"activeVideo");
    id tracks = WolFoxTranscriptSend(video, @"availableCaptionTracks")
        ?: WolFoxTranscriptSend(player, @"availableCaptionTracks");
    return [tracks isKindOfClass:NSArray.class] ? tracks : nil;
}

static NSString *WolFoxTrackLabel(id track) {
    NSString *name = WolFoxTranscriptSend(track, @"displayName");
    if ([name isKindOfClass:NSString.class] && name.length != 0) return name;
    NSString *language = WolFoxTranscriptSend(track, @"languageCode");
    if ([language isKindOfClass:NSString.class] && language.length != 0) {
        return language;
    }
    return WolFoxLocalized(@"Captions");
}

static NSURL *WolFoxTrackJSONURL(id track) {
    id value = WolFoxTranscriptSend(track, @"URL");
    NSURL *URL = [value isKindOfClass:NSURL.class] ? value
        : ([value isKindOfClass:NSString.class]
            ? [NSURL URLWithString:value] : nil);
    if (URL == nil) return nil;
    NSURLComponents *components =
        [NSURLComponents componentsWithURL:URL resolvingAgainstBaseURL:NO];
    if (components == nil) return URL;
    NSMutableArray<NSURLQueryItem *> *items = [NSMutableArray array];
    for (NSURLQueryItem *item in components.queryItems) {
        if ([item.name isEqualToString:@"fmt"]) continue;
        [items addObject:item];
    }
    [items addObject:[NSURLQueryItem queryItemWithName:@"fmt" value:@"json3"]];
    components.queryItems = items;
    return components.URL ?: URL;
}

static NSString *WolFoxTimestamp(double seconds) {
    if (seconds < 0.0) seconds = 0.0;
    const NSInteger total = (NSInteger)seconds;
    const NSInteger hours = total / 3600;
    const NSInteger minutes = (total % 3600) / 60;
    const NSInteger remainder = total % 60;
    if (hours > 0) {
        return [NSString stringWithFormat:@"%ld:%02ld:%02ld",
                (long)hours, (long)minutes, (long)remainder];
    }
    return [NSString stringWithFormat:@"%ld:%02ld",
            (long)minutes, (long)remainder];
}

static NSString *WolFoxParseTranscript(NSData *data, BOOL timestamps) {
    if (data.length == 0) return nil;
    NSDictionary *root = [NSJSONSerialization JSONObjectWithData:data
                                                         options:0
                                                           error:NULL];
    if (![root isKindOfClass:NSDictionary.class]) return nil;
    NSArray *events = root[@"events"];
    if (![events isKindOfClass:NSArray.class]) return nil;

    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    for (NSDictionary *event in events) {
        if (![event isKindOfClass:NSDictionary.class]) continue;
        NSArray *segments = event[@"segs"];
        if (![segments isKindOfClass:NSArray.class]) continue;
        NSMutableString *line = [NSMutableString string];
        for (NSDictionary *segment in segments) {
            if (![segment isKindOfClass:NSDictionary.class]) continue;
            NSString *text = segment[@"utf8"];
            if ([text isKindOfClass:NSString.class]) [line appendString:text];
        }
        NSString *trimmed = [line stringByTrimmingCharactersInSet:
            NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (trimmed.length == 0) continue;
        if (timestamps) {
            NSNumber *start = event[@"tStartMs"];
            const double seconds = [start isKindOfClass:NSNumber.class]
                ? start.doubleValue / 1000.0 : 0.0;
            [lines addObject:[NSString stringWithFormat:@"[%@] %@",
                              WolFoxTimestamp(seconds), trimmed]];
        } else {
            [lines addObject:trimmed];
        }
    }
    if (lines.count == 0) return nil;
    return [lines componentsJoinedByString:timestamps ? @"\n" : @" "];
}


static id WolFoxProbe(id object, NSArray<NSString *> *names) {
    for (NSString *name in names) {
        SEL selector = NSSelectorFromString(name);
        if (object != nil && [object respondsToSelector:selector]) {
            id value = ((id (*)(id, SEL))objc_msgSend)(object, selector);
            if (value != nil) return value;
        }
    }
    return nil;
}

static NSString *WolFoxFormattedText(id value);

static NSURL *WolFoxURLFromValue(id value) {
    if ([value isKindOfClass:NSURL.class]) return value;
    if ([value isKindOfClass:NSString.class]) return [NSURL URLWithString:value];
    id nested = WolFoxProbe(value, @[@"baseUrl", @"URL", @"url", @"privateDoNotAccessOrElseSafeUrlStringValue"]);
    if (nested != nil && nested != value) return WolFoxURLFromValue(nested);
    return nil;
}

NSArray<NSDictionary *> *WolFoxParseCaptionCues(NSData *data) {
    if (data.length == 0) return nil;
    NSDictionary *root = [NSJSONSerialization JSONObjectWithData:data
                                                         options:0 error:NULL];
    if (![root isKindOfClass:NSDictionary.class]) return nil;
    NSArray *events = root[@"events"];
    if (![events isKindOfClass:NSArray.class]) return nil;
    NSMutableArray<NSDictionary *> *cues = [NSMutableArray array];
    for (NSDictionary *event in events) {
        if (![event isKindOfClass:NSDictionary.class]) continue;
        NSArray *segments = event[@"segs"];
        if (![segments isKindOfClass:NSArray.class]) continue;
        NSMutableString *line = [NSMutableString string];
        for (NSDictionary *segment in segments) {
            if (![segment isKindOfClass:NSDictionary.class]) continue;
            NSString *piece = segment[@"utf8"];
            if ([piece isKindOfClass:NSString.class]) [line appendString:piece];
        }
        NSString *trimmed = [line stringByTrimmingCharactersInSet:
            NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (trimmed.length == 0) continue;
        NSNumber *startMs = event[@"tStartMs"];
        NSNumber *durationMs = event[@"dDurationMs"];
        if (![startMs isKindOfClass:NSNumber.class]) continue;
        const double start = startMs.doubleValue / 1000.0;
        const double duration = [durationMs isKindOfClass:NSNumber.class]
            ? durationMs.doubleValue / 1000.0 : 2.0;
        [cues addObject:@{ @"start": @(start),
                           @"end": @(start + MAX(duration, 0.4)),
                           @"text": trimmed }];
    }
    return cues.count != 0 ? cues : nil;
}

static BOOL WolFoxSkipObject(id object) {
    return object == nil ||
        [object isKindOfClass:NSString.class] ||
        [object isKindOfClass:NSNumber.class] ||
        [object isKindOfClass:NSData.class] ||
        [object isKindOfClass:NSDate.class] ||
        [object isKindOfClass:NSURL.class] ||
        [object isKindOfClass:NSValue.class];
}

static id WolFoxDeepCaptionTracks(id root, int depth, NSMutableSet *seen) {
    if (root == nil || depth < 0 || WolFoxSkipObject(root)) return nil;
    NSValue *identity = [NSValue valueWithNonretainedObject:root];
    if ([seen containsObject:identity]) return nil;
    [seen addObject:identity];
    if (seen.count > 400) return nil;

    id direct = WolFoxProbe(root, @[@"captionTracksArray", @"captionTracks"]);
    if ([direct isKindOfClass:NSArray.class] && [direct count] != 0) {
        WolFoxDownloadLog(@"subs", @"tracks on %@",
                          NSStringFromClass(object_getClass(root)));
        return direct;
    }
    if ([root isKindOfClass:NSArray.class]) {
        for (id child in (NSArray *)root) {
            id found = WolFoxDeepCaptionTracks(child, depth - 1, seen);
            if (found != nil) return found;
        }
        return nil;
    }
    for (Class cls = object_getClass(root); cls != Nil;
         cls = class_getSuperclass(cls)) {
        const char *name = class_getName(cls);
        if (strncmp(name, "NS", 2) == 0) break;
        unsigned int count = 0;
        objc_property_t *properties = class_copyPropertyList(cls, &count);
        if (properties == NULL) continue;
        for (unsigned int index = 0; index < count; index++) {
            const char *attributes = property_getAttributes(properties[index]);
            if (attributes == NULL || attributes[1] != '@') continue;
            NSString *key = [NSString stringWithUTF8String:
                property_getName(properties[index])];
            if (key.length == 0) continue;
            if ([key hasPrefix:@"thumbnail"] || [key hasPrefix:@"streaming"] ||
                [key hasPrefix:@"adPlacement"] || [key hasPrefix:@"contents"]) {
                continue;
            }
            SEL getter = NSSelectorFromString(key);
            if (![root respondsToSelector:getter]) continue;
            id value = ((id (*)(id, SEL))objc_msgSend)(root, getter);
            id found = WolFoxDeepCaptionTracks(value, depth - 1, seen);
            if (found != nil) {
                free(properties);
                return found;
            }
        }
        free(properties);
    }
    return nil;
}


NSArray *WolFoxCaptionTracksForResponse(id playerResponse) {
    id data = WolFoxProbe(playerResponse, @[@"playerData"]) ?: playerResponse;
    id captionsRoot = WolFoxProbe(data, @[@"captions"]);
    if (captionsRoot != nil) {
        NSMutableSet *budget = [NSMutableSet set];
        id found = WolFoxDeepCaptionTracks(captionsRoot, 6, budget);
        if ([found isKindOfClass:NSArray.class] && [found count] != 0) {
            WolFoxDownloadLog(@"subs", @"tracks via captions -> %lu",
                              (unsigned long)[found count]);
            return found;
        }
        WolFoxDownloadLog(@"subs", @"captions node %@ had no tracks",
                          NSStringFromClass(object_getClass(captionsRoot)));
    }
    id captions = WolFoxProbe(playerResponse, @[@"captions"]);
    id renderer = WolFoxProbe(captions, @[@"playerCaptionsTracklistRenderer",
                                          @"playerCaptionsTrackListRenderer"]);
    id tracks = WolFoxProbe(renderer, @[@"captionTracksArray", @"captionTracks"]);
    if (![tracks isKindOfClass:NSArray.class] || [tracks count] == 0) {
        NSMutableSet *seen = [NSMutableSet set];
        tracks = WolFoxDeepCaptionTracks(playerResponse, 6, seen);
    }
    if (![tracks isKindOfClass:NSArray.class] || [tracks count] == 0) {
        id data = WolFoxProbe(playerResponse, @[@"playerData", @"playerResponse"]);
        if (data != nil) {
            NSMutableSet *other = [NSMutableSet set];
            tracks = WolFoxDeepCaptionTracks(data, 6, other);
        }
    }
    WolFoxDownloadLog(@"subs", @"tracks for %@ -> %lu",
                      NSStringFromClass(object_getClass(playerResponse)),
                      (unsigned long)([tracks isKindOfClass:NSArray.class]
                                          ? [tracks count] : 0));
    return [tracks isKindOfClass:NSArray.class] ? tracks : nil;
}


NSArray<NSDictionary *> *WolFoxCaptionChoicesForResponse(id playerResponse) {
    NSArray *tracks = WolFoxCaptionTracksForResponse(playerResponse);
    if (tracks.count == 0) return nil;
    NSMutableArray<NSDictionary *> *choices = [NSMutableArray array];
    for (id track in tracks) {
        NSURL *URL = WolFoxCaptionTrackURL(track);
        if (URL == nil) continue;
        [choices addObject:@{
            @"label": WolFoxCaptionTrackLabel(track),
            @"url": URL,
            @"language": WolFoxCaptionTrackLanguage(track) ?: @""
        }];
    }

    id data = WolFoxProbe(playerResponse, @[@"playerData"]) ?: playerResponse;
    id captions = WolFoxProbe(data, @[@"captions"]);
    id renderer = WolFoxProbe(captions, @[@"playerCaptionsTracklistRenderer",
                                          @"playerCaptionsTrackListRenderer"]);
    if (renderer == nil && captions != nil) {
        NSMutableSet *seen = [NSMutableSet set];
        renderer = WolFoxDeepCaptionTracks(captions, 4, seen) != nil
            ? captions : nil;
    }
    id languages = WolFoxProbe(renderer, @[@"translationLanguagesArray",
                                           @"translationLanguages"]);
    WolFoxDownloadLog(@"subs", @"translations=%lu",
                      (unsigned long)([languages isKindOfClass:NSArray.class]
                                          ? [languages count] : 0));
    NSMutableSet<NSString *> *seenCodes = [NSMutableSet set];
    for (NSDictionary *choice in choices) {
        NSString *code = choice[@"language"];
        if (code.length != 0) [seenCodes addObject:code];
    }
    NSURL *base = choices.firstObject[@"url"];
    if ([languages isKindOfClass:NSArray.class] && base != nil) {
        for (id language in (NSArray *)languages) {
            id codeValue = WolFoxProbe(language, @[@"languageCode"]);
            if (![codeValue isKindOfClass:NSString.class] ||
                [codeValue length] == 0) {
                continue;
            }
            if ([seenCodes containsObject:codeValue]) continue;
            [seenCodes addObject:codeValue];
            NSString *label = WolFoxFormattedText(
                WolFoxProbe(language, @[@"languageName"]));
            if (label.length == 0) {
                label = [NSLocale.currentLocale
                    localizedStringForLanguageCode:codeValue];
            }
            if (label.length == 0) label = [codeValue uppercaseString];
            NSURLComponents *components =
                [NSURLComponents componentsWithURL:base
                           resolvingAgainstBaseURL:NO];
            if (components == nil) continue;
            NSMutableArray<NSURLQueryItem *> *items = [NSMutableArray array];
            for (NSURLQueryItem *item in components.queryItems) {
                if ([item.name isEqualToString:@"tlang"]) continue;
                [items addObject:item];
            }
            [items addObject:[NSURLQueryItem queryItemWithName:@"tlang"
                                                         value:codeValue]];
            components.queryItems = items;
            if (components.URL == nil) continue;
            [choices addObject:@{
                @"label": [NSString stringWithFormat:@"%@ (auto)", label],
                @"url": components.URL,
                @"language": codeValue
            }];
        }
    }
    WolFoxDownloadLog(@"subs", @"choices=%lu", (unsigned long)choices.count);
    return choices.count != 0 ? choices : nil;
}

static NSString *WolFoxFormattedText(id value) {
    if ([value isKindOfClass:NSString.class]) {
        return [value length] != 0 ? value : nil;
    }
    id simple = WolFoxProbe(value, @[@"simpleText", @"stringValue"]);
    if ([simple isKindOfClass:NSString.class] && [simple length] != 0) {
        return simple;
    }
    id runs = WolFoxProbe(value, @[@"runsArray", @"runs"]);
    if ([runs isKindOfClass:NSArray.class]) {
        NSMutableString *joined = [NSMutableString string];
        for (id run in (NSArray *)runs) {
            id text = WolFoxProbe(run, @[@"text"]);
            if ([text isKindOfClass:NSString.class]) [joined appendString:text];
        }
        if (joined.length != 0) return joined;
    }
    return nil;
}

NSString *WolFoxCaptionTrackLabel(id track) {
    NSString *text = WolFoxFormattedText(
        WolFoxProbe(track, @[@"name", @"displayName", @"trackName"]));
    if (text.length != 0) return text;
    id language = WolFoxProbe(track, @[@"languageCode"]);
    if ([language isKindOfClass:NSString.class] && [language length] != 0) {
        NSString *display = [NSLocale.currentLocale
            localizedStringForLanguageCode:language];
        return display.length != 0 ? display : [language uppercaseString];
    }
    return WolFoxLocalized(@"Captions");
}

NSString *WolFoxCaptionTrackLanguage(id track) {
    id language = WolFoxProbe(track, @[@"languageCode"]);
    return [language isKindOfClass:NSString.class] ? language : nil;
}

NSURL *WolFoxCaptionTrackURL(id track) {
    NSURL *URL = WolFoxURLFromValue(WolFoxProbe(track, @[@"baseUrl", @"baseURL"]));
    if (URL == nil) return nil;
    NSURLComponents *components =
        [NSURLComponents componentsWithURL:URL resolvingAgainstBaseURL:NO];
    if (components == nil) return URL;
    NSMutableArray<NSURLQueryItem *> *items = [NSMutableArray array];
    for (NSURLQueryItem *item in components.queryItems) {
        if ([item.name isEqualToString:@"fmt"]) continue;
        [items addObject:item];
    }
    [items addObject:[NSURLQueryItem queryItemWithName:@"fmt" value:@"json3"]];
    components.queryItems = items;
    return components.URL ?: URL;
}

void WolFoxFetchCuesForURL(NSURL *url,
                           void (^completion)(NSArray<NSDictionary *> *cues)) {
    if (url == nil) {
        completion(nil);
        return;
    }
    [[NSURLSession.sharedSession dataTaskWithURL:url
        completionHandler:^(NSData *data, NSURLResponse *response,
                            NSError *error) {
        (void)response;
        NSArray<NSDictionary *> *cues =
            error != nil ? nil : WolFoxParseCaptionCues(data);
        WolFoxDownloadLog(@"subs", @"fetched %lu cues",
                          (unsigned long)cues.count);
        dispatch_async(dispatch_get_main_queue(), ^{ completion(cues); });
    }] resume];
}

void WolFoxResolveCaptionTrack(id playerResponse,
                               void (^completion)(NSURL *url,
                                                  NSString *language)) {
    id captions = WolFoxProbe(playerResponse, @[@"captions"]);
    id renderer = WolFoxProbe(captions, @[@"playerCaptionsTracklistRenderer",
                                          @"playerCaptionsTrackListRenderer"]);
    id tracks = WolFoxProbe(renderer, @[@"captionTracksArray", @"captionTracks"]);
    if (![tracks isKindOfClass:NSArray.class] || [tracks count] == 0) {
        NSMutableSet *seen = [NSMutableSet set];
        tracks = WolFoxDeepCaptionTracks(playerResponse, 6, seen);
        if (tracks == nil) {
            id data = WolFoxProbe(playerResponse, @[@"playerData", @"playerResponse"]);
            if (data != nil) {
                NSMutableSet *other = [NSMutableSet set];
                tracks = WolFoxDeepCaptionTracks(data, 6, other);
            }
        }
    }
    WolFoxDownloadLog(@"subs", @"resolve root=%@ captions=%d renderer=%d tracks=%lu",
                      NSStringFromClass(object_getClass(playerResponse)),
                      captions != nil, renderer != nil,
                      (unsigned long)([tracks isKindOfClass:NSArray.class]
                                          ? [tracks count] : 0));
    if (![tracks isKindOfClass:NSArray.class] || [tracks count] == 0) {
        completion(nil, nil);
        return;
    }
    id track = [tracks firstObject];
    NSURL *URL = WolFoxURLFromValue(WolFoxProbe(track, @[@"baseUrl", @"baseURL"]));
    id languageValue = WolFoxProbe(track, @[@"languageCode"]);
    NSString *language = [languageValue isKindOfClass:NSString.class]
        ? languageValue : nil;
    if (URL == nil) {
        completion(nil, nil);
        return;
    }
    NSURLComponents *components =
        [NSURLComponents componentsWithURL:URL resolvingAgainstBaseURL:NO];
    NSMutableArray<NSURLQueryItem *> *items = [NSMutableArray array];
    for (NSURLQueryItem *item in components.queryItems) {
        if ([item.name isEqualToString:@"fmt"]) continue;
        [items addObject:item];
    }
    [items addObject:[NSURLQueryItem queryItemWithName:@"fmt" value:@"json3"]];
    components.queryItems = items;
    completion(components.URL ?: URL, language);
}

void WolFoxFetchCaptionCues(id playerResponse,
                            void (^completion)(NSArray<NSDictionary *> *cues,
                                               NSString *language)) {
    WolFoxResolveCaptionTrack(playerResponse, ^(NSURL *url, NSString *language) {
        if (url == nil) {
            completion(nil, nil);
            return;
        }
        [[NSURLSession.sharedSession dataTaskWithURL:url
            completionHandler:^(NSData *data, NSURLResponse *response,
                                NSError *error) {
            (void)response;
            NSArray<NSDictionary *> *cues =
                error != nil ? nil : WolFoxParseCaptionCues(data);
            WolFoxDownloadLog(@"subs", @"fetched %lu cues lang=%@",
                              (unsigned long)cues.count, language ?: @"?");
            completion(cues, language);
        }] resume];
    });
}

static UIViewController *WolFoxTranscriptPresenter(void) {
    UIWindow *key = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (window.isKeyWindow) key = window;
        }
    }
    UIViewController *controller = key.rootViewController;
    while (controller.presentedViewController != nil) {
        controller = controller.presentedViewController;
    }
    return controller;
}

static void WolFoxShareTranscript(NSString *text, UIView *sourceView) {
    UIViewController *presenter = WolFoxTranscriptPresenter();
    if (presenter == nil) return;
    UIActivityViewController *sheet =
        [[UIActivityViewController alloc] initWithActivityItems:@[text]
                                          applicationActivities:nil];
    UIPopoverPresentationController *popover = sheet.popoverPresentationController;
    if (popover != nil) {
        popover.sourceView = sourceView ?: presenter.view;
        popover.sourceRect = CGRectMake(
            CGRectGetMidX((sourceView ?: presenter.view).bounds),
            CGRectGetMidY((sourceView ?: presenter.view).bounds), 1.0, 1.0);
        popover.permittedArrowDirections = 0;
    }
    [presenter presentViewController:sheet animated:YES completion:nil];
}

static void WolFoxFetchTranscript(id track,
                                  BOOL timestamps,
                                  void (^completion)(NSString *)) {
    NSURL *URL = WolFoxTrackJSONURL(track);
    if (URL == nil) {
        completion(nil);
        return;
    }
    NSURLSessionDataTask *task = [NSURLSession.sharedSession
        dataTaskWithURL:URL
      completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        (void)response;
        NSString *text = error != nil
            ? nil : WolFoxParseTranscript(data, timestamps);
        dispatch_async(dispatch_get_main_queue(), ^{ completion(text); });
    }];
    [task resume];
}

@interface WolFoxTranscriptCoordinator : NSObject
@property(nonatomic, weak) UIView *overlay;
@property(nonatomic, weak) UIButton *button;
+ (instancetype)sharedCoordinator;
- (void)presentTranscript;
@end

@implementation WolFoxTranscriptCoordinator

+ (instancetype)sharedCoordinator {
    static WolFoxTranscriptCoordinator *shared;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ shared = [self new]; });
    return shared;
}

- (void)deliver:(id)track timestamps:(BOOL)timestamps share:(BOOL)share {
    __weak WolFoxTranscriptCoordinator *weakSelf = self;
    WolFoxShowNotice(WolFoxLocalized(@"Loading transcript…"));
    WolFoxFetchTranscript(track, timestamps, ^(NSString *text) {
        if (text.length == 0) {
            WolFoxShowNotice(WolFoxLocalized(@"No transcript available"));
            return;
        }
        if (share) {
            WolFoxShareTranscript(text, weakSelf.button);
            return;
        }
        UIPasteboard.generalPasteboard.string = text;
        WolFoxShowNotice(WolFoxLocalized(@"Transcript copied"));
    });
}

- (void)presentOptionsForTrack:(id)track {
    __weak WolFoxTranscriptCoordinator *weakSelf = self;
    WolFoxPresentNativeSheet(WolFoxLocalized(@"Transcript"),
                             WolFoxTrackLabel(track),
                             self.button, @[
        @{ @"title": WolFoxLocalized(@"Copy Text"),
           @"handler": ^{ [weakSelf deliver:track timestamps:NO share:NO]; } },
        @{ @"title": WolFoxLocalized(@"Copy With Timestamps"),
           @"handler": ^{ [weakSelf deliver:track timestamps:YES share:NO]; } },
        @{ @"title": WolFoxLocalized(@"Share…"),
           @"handler": ^{ [weakSelf deliver:track timestamps:YES share:YES]; } }
    ]);
}

- (void)presentTranscript {
    id player = WolFoxTranscriptPlayer(self.overlay);
    NSArray *tracks = WolFoxTranscriptTracks(player);
    if (tracks.count == 0) {
        WolFoxShowNotice(WolFoxLocalized(@"No captions for this video"));
        return;
    }
    if (tracks.count == 1) {
        [self presentOptionsForTrack:tracks.firstObject];
        return;
    }
    __weak WolFoxTranscriptCoordinator *weakSelf = self;
    NSMutableArray<NSDictionary *> *actions = [NSMutableArray array];
    for (id track in tracks) {
        [actions addObject:@{
            @"title": WolFoxTrackLabel(track),
            @"handler": ^{ [weakSelf presentOptionsForTrack:track]; }
        }];
    }
    WolFoxPresentNativeSheet(WolFoxLocalized(@"Transcript"),
                             WolFoxLocalized(@"Choose a caption track"),
                             self.button, actions);
}

@end

void WolFoxInstallTranscriptHooks(void) {
    WolFoxRegisterOverlayConfigurator(@"transcript",
        ^(UIView *overlay, UIStackView *stack) {
        WolFoxTranscriptCoordinator *coordinator =
            WolFoxTranscriptCoordinator.sharedCoordinator;
        coordinator.overlay = overlay;
        UIButton *button = WolFoxOverlayButton(
            stack,
            @"WolFox Transcript",
            @"text.bubble",
            coordinator,
            @selector(presentTranscript)
        );
        coordinator.button = button;
        button.hidden = !WolFoxFeatureEnabled(WolFoxTranscriptKey);
    });
}
