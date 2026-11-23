#import "../../WolFox.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Localization.h"
#import "../../Runtime/Preferences.h"
#import "../../UI/Notice.h"
#import "../Downloads/DownloadCoordinator.h"
#import "../Downloads/DownloadLog.h"
#import "../Downloads/SABRDownloader.h"

#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

static NSString *const WolFoxQueueKey = @"YTKACE.Preference.Playback.LocalQueue";

static NSString *WolFoxQueueClip(id object, NSUInteger limit);
static NSUInteger WolFoxQueueIndexOfVideo(NSString *videoID);
static NSUInteger WolFoxQueueCurrentIndex(void);
static NSString *WolFoxQueueOpenVideoID(void);
static NSUInteger WolFoxQueueUpcomingIndex(NSString *playing);
static void WolFoxQueueRemoveAt(NSUInteger index);
static BOOL WolFoxQueueVideoIsOpen(void);
static NSString *WolFoxQueueDescribeHost(id candidate);
static void WolFoxQueuePruneController(void);
static NSString *WolFoxQueueCursor(void);
static NSUInteger WolFoxQueueNextIndex(void);
static id WolFoxQueueWatchCommand(NSString *videoID);
static BOOL WolFoxQueueSendCommand(id command, NSString *videoID);
static BOOL WolFoxQueueOpenMinimized(NSString *videoID);
static BOOL WolFoxQueueNoteStarted(NSString *videoID);
static id WolFoxQueueItemMenu(NSString *videoID);
static BOOL WolFoxQueueIsActive(void);
static NSString *WolFoxQueueCurrentVideoID(void);
static id WolFoxQueueValue(id object, NSArray<NSString *> *keys);
static id WolFoxQueueSentinelCommand(NSString *action, NSString *videoID);
static void WolFoxQueueRefreshPanel(void);
static void WolFoxQueueRebuildWatchPage(void);
static void WolFoxQueueRestoreLoopMode(id controller);
static long long WolFoxQueueSavedLoopMode(void);
static void WolFoxQueueStoreLoopMode(long long mode);
static void WolFoxQueueApplyLoopMode(id controller, long long mode);
static void WolFoxQueueAppendToController(NSDictionary *entry,
                                          NSUInteger insertIndex);

static IMP OriginalDiscoveryExecute;
static IMP OriginalPanelParse;
static IMP OriginalResponsePanel;
static IMP OriginalSetWatchNext;
static IMP OriginalPrepareWatchNext;
static IMP OriginalViewUpdateWatchNext;
static IMP OriginalPanelInit;
static IMP OriginalPanelInitQueue;
static IMP OriginalQueueControllerInit;
static IMP OriginalDidPressNext;
static IMP OriginalDidPressPrevious;
static IMP OriginalAutonavPlayNext;
static IMP OriginalMoveItem;
static IMP OriginalRemoveItem;
static IMP OriginalRemoveIndex;
static IMP OriginalClearQueue;
static IMP OriginalIsQueue;
static IMP OriginalHasQueueContents;
static IMP OriginalCanMoveItem;
static IMP OriginalNextVideoTitle;
static IMP OriginalNextVideoIndex;
static IMP OriginalReplaceAutoplay;
static IMP OriginalSetCanReorder;
static IMP OriginalAllowsReordering;
static IMP OriginalCellControllerSetCell;
static IMP OriginalCellPrepareForReuse;
static IMP OriginalAlphaForIndex;
static IMP OriginalUpdateCellForIndex;
static IMP OriginalSlideLayoutSubviews;
static NSTimeInterval WolFoxQueueActiveVideoTime;
static IMP OriginalSetVideoCountText;
static IMP OriginalDidTapShuffle;
static IMP OriginalDidTapLoop;
static IMP OriginalDidTapAction;
static IMP OriginalAutonavHasNext;
static IMP OriginalAutonavHasPrevious;
static IMP OriginalQueueHasNext;
static IMP OriginalQueueHasPrevious;
static IMP OriginalNextNavigable;
static IMP OriginalPreviousNavigable;
static IMP OriginalPanelByline;
static NSString *const WolFoxQueueLoopKey = @"YTKACE.Preference.Playback.QueueLoopMode";
static __weak id WolFoxQueuePlayerViewController;
static NSString *WolFoxQueueCurrentOverride;
static NSString *WolFoxQueueActiveVideo;
static __weak id WolFoxQueuePanelController;
static __weak id WolFoxQueueControllerInstance;
static id WolFoxLastWatchNextResponse;
static BOOL WolFoxQueuePanelInjected;
static __weak id WolFoxQueueWatchViewController;
static IMP OriginalRouterHandle;
static IMP OriginalRouterHandleCompletion;
static IMP OriginalScopedRouterHandle;
static IMP OriginalScopedRouterHandleCompletion;

static NSMutableArray<NSDictionary *> *WolFoxQueueItems;
static __weak id WolFoxQueueResponder;
static NSString *WolFoxQueueAdvancedFromVideoID;
static BOOL WolFoxQueueSyncSuppressed;

// The cursor is the queue item that most recently played. Items after it are
// upcoming; nil means the queue was built while idle and has not started yet.
static NSString *const WolFoxQueueCursorKey = @"WolFox.Queue.Cursor";

static NSString *WolFoxQueueCursor(void) {
    id value = [NSUserDefaults.standardUserDefaults
        objectForKey:WolFoxQueueCursorKey];
    return [value isKindOfClass:NSString.class] ? value : nil;
}

// Set once the last queued video has played to the end with no loop.
static NSString *const WolFoxQueueFinishedKey = @"WolFox.Queue.Finished";

static BOOL WolFoxQueueFinished(void) {
    return [NSUserDefaults.standardUserDefaults boolForKey:WolFoxQueueFinishedKey];
}

static void WolFoxQueueSetFinished(BOOL finished) {
    if (finished == WolFoxQueueFinished()) return;
    [NSUserDefaults.standardUserDefaults setBool:finished
                                          forKey:WolFoxQueueFinishedKey];
}

static void WolFoxQueueSetCursor(NSString *videoID) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if (videoID.length == 0) {
        [defaults removeObjectForKey:WolFoxQueueCursorKey];
    } else if (![videoID isEqualToString:WolFoxQueueCursor()]) {
        [defaults setObject:videoID forKey:WolFoxQueueCursorKey];
    }
}

static NSString *WolFoxQueueStorePath(void) {
    NSString *documents = NSSearchPathForDirectoriesInDomains(
        NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    if (documents.length == 0) return nil;
    NSString *folder = [documents stringByAppendingPathComponent:@"YTKACE"];
    [NSFileManager.defaultManager createDirectoryAtPath:folder
                            withIntermediateDirectories:YES
                                             attributes:nil
                                                  error:NULL];
    return [folder stringByAppendingPathComponent:@"queue.plist"];
}

static void WolFoxQueueSave(void) {
    NSString *path = WolFoxQueueStorePath();
    if (path.length == 0) return;
    if (WolFoxQueueItems.count == 0) {
        [NSFileManager.defaultManager removeItemAtPath:path error:NULL];
        WolFoxQueueSetCursor(nil);
        WolFoxQueueSetFinished(NO);
        return;
    }
    [WolFoxQueueItems writeToFile:path atomically:YES];
}

static NSMutableArray<NSDictionary *> *WolFoxQueue(void) {
    if (WolFoxQueueItems != nil) return WolFoxQueueItems;
    NSString *path = WolFoxQueueStorePath();
    NSArray *stored = path.length != 0
        ? [NSArray arrayWithContentsOfFile:path]
        : nil;
    WolFoxQueueItems = stored != nil ? [stored mutableCopy] : [NSMutableArray array];
    return WolFoxQueueItems;
}

BOOL WolFoxQueueHasItems(void) {
    if (!WolFoxFeatureEnabled(WolFoxQueueKey)) return NO;
    return WolFoxQueueNextIndex() != NSNotFound;
}

// True when the queue decides what plays after the current video, including
// a video opened outside the queue while queued videos are still waiting.
BOOL WolFoxQueueOwnsCurrentVideo(void) {
    if (!WolFoxFeatureEnabled(WolFoxQueueKey)) return NO;
    return WolFoxQueueIndexOfVideo(WolFoxQueueCurrentVideoID()) != NSNotFound ||
        WolFoxQueueNextIndex() != NSNotFound;
}

static NSString *WolFoxQueueVideoIDFromParams(NSData *data, int *position) {
    const unsigned char *bytes = (const unsigned char *)data.bytes;
    const NSUInteger length = data.length;
    if (position != NULL) *position = 0;
    for (NSUInteger index = 0; index + 1 < length; index++) {
        if (bytes[index] == 0x08 && (bytes[index + 1] == 0x02 ||
                                     bytes[index + 1] == 0x03)) {
            if (position != NULL) *position = bytes[index + 1];
            break;
        }
    }
    for (NSUInteger index = 0; index + 12 < length; index++) {
        if (bytes[index] != 0x0a || bytes[index + 1] != 0x0b) continue;
        NSString *candidate = [[NSString alloc]
            initWithBytes:bytes + index + 2 length:11
                 encoding:NSUTF8StringEncoding];
        if (candidate.length != 11) continue;
        NSCharacterSet *invalid = [[NSCharacterSet characterSetWithCharactersInString:
            @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-"]
            invertedSet];
        if ([candidate rangeOfCharacterFromSet:invalid].location != NSNotFound) {
            continue;
        }
        return candidate;
    }
    return nil;
}

static NSString *WolFoxQueueDiscoveryParams(id command) {
    NSString *dump = nil;
    @try {
        dump = [command description];
    } @catch (__unused NSException *exception) {
        return nil;
    }
    if (dump.length == 0) return nil;
    if (![dump containsString:@"discovery_params"]) return nil;
    // A plain video tap carries discovery params too; only treat a command
    // as a queue add when it is not a bare watch endpoint.
    const BOOL watch = [dump containsString:@"watch_endpoint"] ||
        [dump containsString:@"watchEndpoint"];
    if (watch && [dump rangeOfString:@"queue"
                             options:NSCaseInsensitiveSearch].location == NSNotFound) {
        return nil;
    }
    static NSRegularExpression *expression;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        expression = [NSRegularExpression
            regularExpressionWithPattern:@"discovery_params:\\s*\"([^\"]+)\""
                                 options:0
                                   error:NULL];
    });
    NSTextCheckingResult *match = [expression firstMatchInString:dump options:0
        range:NSMakeRange(0, dump.length)];
    if (match == nil) return nil;
    return [dump substringWithRange:[match rangeAtIndex:1]];
}

static NSString *WolFoxQueueTitleNearView(id view) {
    UIView *current = [view isKindOfClass:UIView.class] ? view : nil;
    NSString *best = nil;
    for (NSUInteger depth = 0; depth < 6 && current != nil; depth++) {
        NSString *label = current.accessibilityLabel;
        if (label.length > best.length) best = label;
        current = current.superview;
    }
    if (best.length < 6) return nil;
    return best;
}


static void WolFoxQueueUpdateEntry(NSString *videoID, NSString *title,
                                   NSString *author, NSString *length) {
    if (videoID.length == 0 || title.length == 0) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        NSMutableArray *queue = WolFoxQueue();
        for (NSUInteger index = 0; index < queue.count; index++) {
            if (![queue[index][@"videoId"] isEqualToString:videoID]) continue;
            NSMutableDictionary *entry = [queue[index] mutableCopy];
            entry[@"title"] = title;
            if (author.length != 0) entry[@"author"] = author;
            if (length.length != 0) entry[@"length"] = length;
            queue[index] = entry;
            WolFoxQueueSave();
            WolFoxQueueRefreshPanel();
            break;
        }
    });
}


static id WolFoxQueueValue(id object, NSArray<NSString *> *keys) {
    if (object == nil) return nil;
    for (NSString *key in keys) {
        SEL selector = NSSelectorFromString(key);
        if (![object respondsToSelector:selector]) continue;
        NSMethodSignature *signature =
            [object methodSignatureForSelector:selector];
        const char *type = signature.methodReturnType;
        if (type == NULL) continue;
        if (strcmp(type, @encode(id)) == 0) {
            NSInvocation *invocation =
                [NSInvocation invocationWithMethodSignature:signature];
            invocation.selector = selector;
            [invocation invokeWithTarget:object];
            void *raw = NULL;
            [invocation getReturnValue:&raw];
            id value = (__bridge id)raw;
            if (value != nil) return value;
            continue;
        }
        if (strcmp(type, @encode(int)) == 0 ||
            strcmp(type, @encode(unsigned int)) == 0 ||
            strcmp(type, @encode(long long)) == 0 ||
            strcmp(type, @encode(unsigned long long)) == 0) {
            NSInvocation *invocation =
                [NSInvocation invocationWithMethodSignature:signature];
            invocation.selector = selector;
            [invocation invokeWithTarget:object];
            long long number = 0;
            [invocation getReturnValue:&number];
            if (number != 0) return @(number);
        }
    }
    return nil;
}

static id WolFoxQueueVideoDetails(id response) {
    id details = WolFoxQueueValue(response, @[@"videoDetails"]);
    if (details != nil) return details;
    for (NSString *wrapper in @[@"playerData", @"playerResponse",
                                @"playerResponseData"]) {
        id inner = WolFoxQueueValue(response, @[wrapper]);
        details = WolFoxQueueValue(inner, @[@"videoDetails"]);
        if (details != nil) return details;
    }
    return nil;
}

static NSString *WolFoxQueueLengthText(NSString *seconds) {
    const NSInteger total = seconds.integerValue;
    if (total <= 0) return nil;
    const NSInteger hours = total / 3600;
    const NSInteger minutes = (total % 3600) / 60;
    const NSInteger remainder = total % 60;
    if (hours > 0) {
        return [NSString stringWithFormat:@"%ld:%02ld:%02ld", (long)hours,
            (long)minutes, (long)remainder];
    }
    return [NSString stringWithFormat:@"%ld:%02ld", (long)minutes,
        (long)remainder];
}

static void WolFoxQueueFetchFromOEmbed(NSString *videoID) {
    NSString *address = [NSString stringWithFormat:
        @"https://www.youtube.com/oembed?url=https%%3A%%2F%%2Fwww.youtube.com"
        @"%%2Fwatch%%3Fv%%3D%@&format=json", videoID];
    NSURL *url = [NSURL URLWithString:address];
    if (url == nil) return;
    NSURLSessionDataTask *task = [NSURLSession.sharedSession
        dataTaskWithURL:url
      completionHandler:^(NSData *data, __unused NSURLResponse *response,
                          __unused NSError *error) {
        if (data.length == 0) return;
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data
            options:0 error:NULL];
        if (![json isKindOfClass:NSDictionary.class]) return;
        WolFoxQueueUpdateEntry(videoID, json[@"title"], json[@"author_name"],
                               nil);
    }];
    [task resume];
}

static void WolFoxQueueFetchTitle(NSString *videoID) {
    if (videoID.length == 0) return;
    static NSMutableSet<NSString *> *pending;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        pending = [NSMutableSet set];
    });
    @synchronized (pending) {
        if ([pending containsObject:videoID]) return;
        [pending addObject:videoID];
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(20 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        @synchronized (pending) {
            [pending removeObject:videoID];
        }
    });
    WolFoxQueueFetchFromOEmbed(videoID);
    WolFoxResolvePlayerResponse(videoID, ^(id response, __unused NSError *error) {
        id details = WolFoxQueueVideoDetails(response);
        id rawTitle = WolFoxQueueValue(details, @[@"title"]);
        NSString *title = [rawTitle isKindOfClass:NSString.class] ? rawTitle : nil;
        id rawAuthor = WolFoxQueueValue(details,
            @[@"author", @"channelTitle", @"ownerChannelName"]);
        NSString *author = [rawAuthor isKindOfClass:NSString.class]
            ? rawAuthor : nil;
        id rawSeconds = WolFoxQueueValue(details,
            @[@"lengthSeconds", @"lengthSecondsString", @"videoLengthSeconds"]);
        NSString *seconds = nil;
        if ([rawSeconds isKindOfClass:NSString.class]) {
            seconds = rawSeconds;
        } else if ([rawSeconds isKindOfClass:NSNumber.class]) {
            seconds = [rawSeconds stringValue];
        }
        NSString *length = WolFoxQueueLengthText(seconds);

        if (title.length != 0) {
            WolFoxQueueUpdateEntry(videoID, title, author, length);
        }
    });
}

static void WolFoxQueueAdd(NSString *videoID, NSString *title,
                           BOOL playNext) {
    NSMutableArray *queue = WolFoxQueue();
    NSString *playing = WolFoxQueueOpenVideoID();
    WolFoxDebugLog(@"queue", @"add %@ next=%d playing=%@ current=%@ queue=%lu cursor=%@ "
          @"watch=[%@] player=[%@] responder=[%@]",
          videoID, playNext, playing ?: @"nil", WolFoxQueueCurrentVideoID() ?: @"nil",
          (unsigned long)queue.count, WolFoxQueueCursor() ?: @"nil",
          WolFoxQueueDescribeHost(WolFoxQueueWatchViewController),
          WolFoxQueueDescribeHost(WolFoxQueuePlayerViewController),
          WolFoxQueueDescribeHost(WolFoxQueueResponder));
    if ([playing isEqualToString:videoID] &&
        WolFoxQueueIndexOfVideo(videoID) != NSNotFound) {
        return;
    }
    // With nothing open the old queue went away with the player, so this
    // starts a new one, opened paused in the miniplayer like YouTube's own.
    if (playing.length == 0) {
        [queue removeAllObjects];
        WolFoxQueueSetCursor(nil);
    }
    NSUInteger existing = WolFoxQueueIndexOfVideo(videoID);
    if (existing != NSNotFound) WolFoxQueueRemoveAt(existing);
    if (playing.length != 0) {
        WolFoxQueueNoteStarted(playing);
        // A new queue starts with the video on screen; an existing one keeps
        // its order and the new video goes after what is already queued.
        if (queue.count == 0) {
            NSMutableDictionary *seed = [NSMutableDictionary dictionary];
            seed[@"videoId"] = playing;
            [queue addObject:seed];
            WolFoxQueueSetCursor(playing);
            WolFoxQueueFetchTitle(playing);
        }
    }
    NSMutableDictionary *item = [NSMutableDictionary dictionary];
    item[@"videoId"] = videoID;
    if (title.length != 0) item[@"title"] = title;
    if (playNext) {
        [queue insertObject:item atIndex:MIN(WolFoxQueueUpcomingIndex(playing),
                                             queue.count)];
    } else {
        [queue addObject:item];
    }
    WolFoxQueueSetFinished(NO);
    WolFoxQueueSave();
    WolFoxDebugLog(@"queue", @"add done queue=%@", [queue valueForKey:@"videoId"]);
    if (title.length == 0) WolFoxQueueFetchTitle(videoID);
    WolFoxShowNotice(playNext ? WolFoxLocalized(@"Playing next")
                              : WolFoxLocalized(@"Added to queue"));
    if (playing.length == 0) {
        if (WolFoxQueueOpenMinimized(videoID)) WolFoxQueueSetCursor(videoID);
        return;
    }
    WolFoxQueueAppendToController(item, WolFoxQueueIndexOfVideo(videoID));
    WolFoxQueuePruneController();
    if (!WolFoxQueuePanelInjected || queue.count <= 2) {
        WolFoxQueueRebuildWatchPage();
    }
    WolFoxQueueRefreshPanel();
}

static __weak id WolFoxQueueCommandSender;
static __weak id WolFoxQueueCommandView;
static __weak id WolFoxQueueRouter;
static IMP WolFoxQueueRouterOriginal;
static BOOL WolFoxQueueRouterHasCompletion;

static void WolFoxQueueNoteRouter(id router, IMP original, BOOL completion,
                                  id view, id sender) {
    WolFoxQueueCommandSender = sender;
    WolFoxQueueCommandView = view;
    if (router == nil || original == NULL) return;
    WolFoxQueueRouter = router;
    WolFoxQueueRouterOriginal = original;
    WolFoxQueueRouterHasCompletion = completion;
}

static BOOL WolFoxQueueSendViaRouter(id command, id view, id sender) {
    id router = WolFoxQueueRouter;
    IMP original = WolFoxQueueRouterOriginal;
    if (command == nil || router == nil || original == NULL) return NO;
    @try {
        if (WolFoxQueueRouterHasCompletion) {
            return ((BOOL (*)(id, SEL, id, id, id, id, id))original)(router,
                @selector(handleCommand:entry:fromView:sender:completionBlock:),
                command, nil, view, sender, nil);
        }
        return ((BOOL (*)(id, SEL, id, id, id, id))original)(router,
            @selector(handleCommand:entry:fromView:sender:), command, nil, view,
            sender);
    } @catch (__unused NSException *exception) {
        return NO;
    }
}

static BOOL WolFoxQueueSendViaEvent(id command, id view, id responder) {
    Class eventClass = NSClassFromString(@"YTCommandResponderEvent");
    SEL eventSelector =
        @selector(eventWithCommand:fromView:displayTitle:firstResponder:);
    if (command == nil || responder == nil ||
        ![eventClass respondsToSelector:eventSelector]) {
        return NO;
    }
    @try {
        id event = ((id (*)(id, SEL, id, id, id, id))objc_msgSend)(
            eventClass, eventSelector, command, view, nil, responder);
        if (event == nil) return NO;
        ((void (*)(id, SEL))objc_msgSend)(event, @selector(send));
    } @catch (__unused NSException *exception) {
        return NO;
    }
    return YES;
}

static void WolFoxQueueNoteSent(NSString *videoID) {
    WolFoxQueueActiveVideo = videoID;
    WolFoxQueueActiveVideoTime = NSDate.timeIntervalSinceReferenceDate;
}

// Moving through the queue goes through the playing player first; it is the
// responder that keeps the watch page.
static BOOL WolFoxQueueSendCommand(id command, NSString *videoID) {
    id view = WolFoxQueueCommandView;
    id sender = WolFoxQueueCommandSender;
    const BOOL sent =
        WolFoxQueueSendViaEvent(command, nil, WolFoxQueueResponder) ||
        WolFoxQueueSendViaRouter(command, view, sender) ||
        WolFoxQueueSendViaEvent(command, view, sender);
    if (sent) WolFoxQueueNoteSent(videoID);
    return sent;
}

static BOOL WolFoxQueuePlay(NSString *videoID) {
    return WolFoxQueueSendCommand(WolFoxQueueWatchCommand(videoID), videoID);
}

static BOOL WolFoxQueueReplayCurrent(void) {
    id player = WolFoxQueuePlayerViewController;
    if (player == nil) return NO;
    @try {
        if ([player respondsToSelector:@selector(replayWithSeekSource:)]) {
            ((void (*)(id, SEL, int))objc_msgSend)(player,
                @selector(replayWithSeekSource:), 0);
            return YES;
        }
        if ([player respondsToSelector:@selector(seekToTime:)]) {
            ((void (*)(id, SEL, double))objc_msgSend)(player,
                @selector(seekToTime:), 0.0);
            if ([player respondsToSelector:@selector(play)]) {
                ((void (*)(id, SEL))objc_msgSend)(player, @selector(play));
            }
            return YES;
        }
    } @catch (__unused NSException *exception) {
        return NO;
    }
    return NO;
}

static BOOL WolFoxQueueOverlayLoop(void) {
    return WolFoxFeatureEnabled(WolFoxLoopKey) &&
        [NSUserDefaults.standardUserDefaults boolForKey:@"defaultLoop_enabled"];
}

// Repeat-one only replays when a video ends on its own; pressing Next or
// Previous still moves through the queue.
static BOOL WolFoxQueueStep(NSInteger offset, BOOL manual) {
    if (!WolFoxFeatureEnabled(WolFoxQueueKey)) return NO;
    NSArray *queue = [WolFoxQueue() copy];
    NSUInteger current = WolFoxQueueIndexOfVideo(WolFoxQueueCurrentVideoID());
    if (current == NSNotFound) {
        // A video opened outside the queue: carry on with what is queued.
        NSUInteger next = offset > 0 ? WolFoxQueueNextIndex() : NSNotFound;
        if (next == NSNotFound) return NO;
        return WolFoxQueuePlay(queue[next][@"videoId"]);
    }
    const long long loop = WolFoxQueueSavedLoopMode();
    NSInteger target = (NSInteger)current + offset;
    if (loop == 2 && !manual) return WolFoxQueueReplayCurrent();
    if (target < 0 || target >= (NSInteger)queue.count) {
        if (loop == 0 || queue.count == 0) return NO;
        target = target < 0 ? (NSInteger)queue.count - 1 : 0;
    }
    NSString *videoID = queue[(NSUInteger)target][@"videoId"];
    if (videoID.length == 0) return NO;
    return WolFoxQueuePlay(videoID);
}

static long long WolFoxQueueLoopMode(void) {
    return WolFoxQueueSavedLoopMode();
}

static void WolFoxQueueAdvance(NSString *finishing) {
    NSArray *queue = [WolFoxQueue() copy];
    NSUInteger current = WolFoxQueueIndexOfVideo(finishing);
    if (current == NSNotFound) {
        NSUInteger next = WolFoxQueueNextIndex();
        if (next != NSNotFound) WolFoxQueuePlay(queue[next][@"videoId"]);
        return;
    }
    const long long loop = WolFoxQueueLoopMode();
    if (loop == 2 || WolFoxQueueOverlayLoop()) {
        WolFoxQueueReplayCurrent();
        return;
    }
    if (current + 1 >= queue.count) {
        if (loop != 1 || queue.count == 0) {
            WolFoxQueueSetFinished(YES);
            return;
        }
        NSString *first = queue.firstObject[@"videoId"];
        if (first.length != 0) WolFoxQueuePlay(first);
        return;
    }
    NSString *videoID = queue[current + 1][@"videoId"];
    if (videoID.length == 0) return;
    WolFoxQueuePlay(videoID);
}

static id WolFoxQueueMessage(NSString *className) {
    Class cls = NSClassFromString(className);
    if (cls == Nil) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(cls, @selector(message));
}

static id WolFoxQueueFormatted(NSString *text) {
    Class cls = NSClassFromString(@"YTIFormattedString");
    if (cls == Nil || text.length == 0) return nil;
    return ((id (*)(id, SEL, id))objc_msgSend)(
        cls, @selector(formattedStringWithString:), text);
}

static id WolFoxQueueWatchCommand(NSString *videoID) {
    id endpoint = WolFoxQueueMessage(@"YTIWatchEndpoint");
    id command = WolFoxQueueMessage(@"YTICommand");
    if (endpoint == nil || command == nil) return nil;
    [endpoint setValue:videoID forKey:@"videoId"];
    [endpoint setValue:@0 forKey:@"startTimeSeconds"];
    [command setValue:endpoint forKey:@"watchEndpoint"];
    return command;
}

static NSString *WolFoxQueueTitleForVideo(NSString *videoID, NSString *stored) {
    if (stored.length != 0) return stored;
    id response = WolFoxCachedPlayerResponse(videoID);
    if (response == nil) return nil;
    @try {
        id details = [response valueForKey:@"videoDetails"];
        id title = [details valueForKey:@"title"];
        if ([title isKindOfClass:NSString.class] && [title length] != 0) {
            return title;
        }
    } @catch (__unused NSException *exception) {
        return nil;
    }
    return nil;
}

static void WolFoxQueueSafeSet(id object, id value, NSString *key) {
    if (object == nil) return;
    @try {
        [object setValue:value forKey:key];
    } @catch (__unused NSException *exception) {
        static NSMutableSet<NSString *> *reported;
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{ reported = [NSMutableSet set]; });
        NSString *name = [NSString stringWithFormat:@"%@.%@", NSStringFromClass([object class]), key];
        @synchronized (reported) {
            if ([reported containsObject:name]) return;
            [reported addObject:name];
        }
        WolFoxDebugLog(@"queue", @"skipped unsupported field %@", name);
    }
}

static id WolFoxQueuePanelItem(NSString *videoID, NSString *title,
                               NSString *author, NSString *length,
                               BOOL selected, NSUInteger index) {
    id renderer = WolFoxQueueMessage(@"YTIPlaylistPanelVideoRenderer");
    id wrapper = WolFoxQueueMessage(
        @"YTIPlaylistPanelRenderer_PlaylistPanelVideoSupportedRenderers");
    if (renderer == nil || wrapper == nil) return nil;
    WolFoxQueueSafeSet(renderer, videoID, @"videoId");
    WolFoxQueueSafeSet(renderer, videoID, @"playlistSetVideoId");
    id titleText = WolFoxQueueFormatted(
        WolFoxQueueTitleForVideo(videoID, title) ?: videoID);
    if (titleText != nil) WolFoxQueueSafeSet(renderer, titleText, @"title");
    id indexText = WolFoxQueueFormatted(
        [NSString stringWithFormat:@"%lu", (unsigned long)(index + 1)]);
    if (indexText != nil) WolFoxQueueSafeSet(renderer, indexText, @"indexText");
    id thumbnails = WolFoxQueueMessage(@"YTIThumbnailDetails");
    if (thumbnails != nil) {
        NSArray<NSArray *> *sizes = @[@[@"mqdefault", @320, @180],
                                      @[@"hqdefault", @480, @360]];
        for (NSArray *size in sizes) {
            id thumbnail = WolFoxQueueMessage(@"YTIThumbnailDetails_Thumbnail");
            if (thumbnail == nil) continue;
            WolFoxQueueSafeSet(thumbnail, [NSString stringWithFormat:
                @"https://i.ytimg.com/vi/%@/%@.jpg", videoID, size[0]], @"URL");
            WolFoxQueueSafeSet(thumbnail, size[1], @"width");
            WolFoxQueueSafeSet(thumbnail, size[2], @"height");
            [[thumbnails valueForKey:@"thumbnailsArray"] addObject:thumbnail];
        }
        WolFoxQueueSafeSet(renderer, thumbnails, @"thumbnail");
    }
    id style = WolFoxQueueMessage(@"YTIMainAppCompactRendererStyle");
    if (style != nil) {
        WolFoxQueueSafeSet(style, @2, @"value");
        WolFoxQueueSafeSet(renderer, style, @"mainAppStyle");
    }
    if (length.length != 0) {
        id overlay = WolFoxQueueMessage(@"YTIThumbnailOverlaySupportedRenderers");
        id timeStatus =
            WolFoxQueueMessage(@"YTIThumbnailOverlayTimeStatusRenderer");
        id overlayText = WolFoxQueueFormatted(length);
        if (overlay != nil && timeStatus != nil && overlayText != nil) {
            WolFoxQueueSafeSet(timeStatus, overlayText, @"text");
            WolFoxQueueSafeSet(overlay, timeStatus, @"thumbnailOverlayTimeStatusRenderer");
            [[renderer valueForKey:@"thumbnailOverlaysArray"]
                addObject:overlay];
        }
    }
    id menu = WolFoxQueueItemMenu(videoID);
    if (menu != nil) WolFoxQueueSafeSet(renderer, menu, @"menu");
    id removeCommand = WolFoxQueueSentinelCommand(@"remove", videoID);
    if (removeCommand != nil) {
        WolFoxQueueSafeSet(renderer, removeCommand, @"onSwipeLeftCommand");
        WolFoxQueueSafeSet(renderer, removeCommand, @"onItemRemovedCommand");
    }
    if (!selected) {
        id swipe = WolFoxQueueMessage(
            @"YTIPlaylistPanelVideoSwipeToRevealButtonSupportedRenderers");
        id button = WolFoxQueueMessage(@"YTIButtonRenderer");
        id swipeCommand = WolFoxQueueSentinelCommand(@"remove", videoID);
        if (swipe != nil && button != nil && swipeCommand != nil) {
            id label = WolFoxQueueFormatted(WolFoxLocalized(@"Remove"));
            if (label != nil) WolFoxQueueSafeSet(button, label, @"text");
            WolFoxQueueSafeSet(button, swipeCommand, @"serviceEndpoint");
            WolFoxQueueSafeSet(swipe, button, @"buttonRenderer");
            [[renderer valueForKey:@"swipeButtonsArray"] addObject:swipe];
        }
    }
    id byline = WolFoxQueueFormatted(author);
    if (byline != nil) {
        WolFoxQueueSafeSet(renderer, byline, @"shortBylineText");
        WolFoxQueueSafeSet(renderer, byline, @"longBylineText");
    }
    id command = WolFoxQueueWatchCommand(videoID);
    if (command != nil) WolFoxQueueSafeSet(renderer, command, @"navigationEndpoint");
    WolFoxQueueSafeSet(renderer, @(selected), @"selected");
    WolFoxQueueSafeSet(wrapper, renderer, @"playlistPanelVideoRenderer");
    return wrapper;
}

static NSUInteger WolFoxQueueIndexOfVideo(NSString *videoID) {
    if (videoID.length == 0) return NSNotFound;
    NSArray *queue = WolFoxQueue();
    for (NSUInteger index = 0; index < queue.count; index++) {
        if ([queue[index][@"videoId"] isEqualToString:videoID]) return index;
    }
    return NSNotFound;
}

static NSString *WolFoxQueueCurrentVideoID(void) {
    if (WolFoxQueueCurrentOverride.length != 0) {
        return WolFoxQueueCurrentOverride;
    }
    id player = WolFoxQueuePlayerViewController;
    id playerValue =
        WolFoxQueueValue(player, @[@"currentVideoID", @"contentVideoID"]);
    NSMutableArray<NSString *> *candidates = [NSMutableArray array];
    const NSTimeInterval age =
        NSDate.timeIntervalSinceReferenceDate - WolFoxQueueActiveVideoTime;
    const BOOL preferOwn =
        WolFoxQueueActiveVideo.length != 0 && age < 4.0;
    if (preferOwn) [candidates addObject:WolFoxQueueActiveVideo];
    if ([playerValue isKindOfClass:NSString.class] &&
        [playerValue length] != 0) {
        [candidates addObject:playerValue];
    }
    if (!preferOwn && WolFoxQueueActiveVideo.length != 0) {
        [candidates addObject:WolFoxQueueActiveVideo];
    }
    NSString *last = WolFoxLastVideoID();
    if (last.length != 0) [candidates addObject:last];
    for (NSString *candidate in candidates) {
        if (WolFoxQueueIndexOfVideo(candidate) != NSNotFound) return candidate;
    }
    return candidates.firstObject;
}

static NSUInteger WolFoxQueueCurrentIndex(void) {
    return WolFoxQueueIndexOfVideo(WolFoxQueueCurrentVideoID());
}

static BOOL WolFoxQueueViewOnScreen(id candidate) {
    if (![candidate isKindOfClass:UIViewController.class]) return NO;
    UIViewController *controller = candidate;
    return controller.isViewLoaded && controller.view.window != nil;
}

static NSString *WolFoxQueueDescribeHost(id candidate) {
    if (candidate == nil) return @"nil";
    if (![candidate isKindOfClass:UIViewController.class]) {
        return [NSString stringWithFormat:@"%@(not a VC)", [candidate class]];
    }
    UIViewController *controller = candidate;
    return [NSString stringWithFormat:@"%@ loaded=%d window=%d",
        [candidate class], controller.isViewLoaded,
        controller.isViewLoaded && controller.view.window != nil];
}

// The miniplayer takes the watch view out of the window but keeps the watch
// player in it, so a video is open while either is on screen. Only the watch
// player counts: feed previews run players of their own.
static BOOL WolFoxQueueVideoIsOpen(void) {
    return WolFoxQueueViewOnScreen(WolFoxQueueWatchViewController) ||
        WolFoxQueueViewOnScreen(WolFoxQueuePlayerViewController);
}

static NSString *WolFoxQueueOpenVideoID(void) {
    if (!WolFoxQueueVideoIsOpen()) return nil;
    id live = WolFoxQueueValue(WolFoxQueuePlayerViewController,
                               @[@"currentVideoID", @"contentVideoID"]);
    if ([live isKindOfClass:NSString.class] && [live length] != 0) return live;
    return WolFoxQueueCurrentVideoID();
}

// Index where "play next" inserts: right after the open video when it is in
// the queue, otherwise right after the last item that played.
static NSUInteger WolFoxQueueUpcomingIndex(NSString *playing) {
    NSUInteger index = WolFoxQueueIndexOfVideo(playing);
    if (index == NSNotFound) index = WolFoxQueueIndexOfVideo(WolFoxQueueCursor());
    return index == NSNotFound ? 0 : index + 1;
}

static void WolFoxQueueRemoveAt(NSUInteger index) {
    NSMutableArray *queue = WolFoxQueue();
    if (index >= queue.count) return;
    if ([queue[index][@"videoId"] isEqualToString:WolFoxQueueCursor()]) {
        WolFoxQueueSetCursor(index > 0 ? queue[index - 1][@"videoId"] : nil);
    }
    [queue removeObjectAtIndex:index];
}

// Position the queue continues from: the open video when it is queued,
// otherwise the last queue item that played.
static NSUInteger WolFoxQueueAnchorIndex(void) {
    NSUInteger current = WolFoxQueueCurrentIndex();
    if (current != NSNotFound) return current;
    return WolFoxQueueIndexOfVideo(WolFoxQueueCursor());
}

// The queue item that plays after the current video, or NSNotFound.
static NSUInteger WolFoxQueueNextIndex(void) {
    NSUInteger anchor = WolFoxQueueAnchorIndex();
    NSUInteger next = anchor == NSNotFound ? 0 : anchor + 1;
    return next < WolFoxQueue().count ? next : NSNotFound;
}

// Called when a video starts. A queued video moves the cursor. A video
// opened from elsewhere while the queue is running goes in front of the video
// that was playing and becomes the current item, like YouTube's own queue.
// Once the last queued video has played to the end the queue is finished,
// so the next video starts fresh and the queue is cleared.
// Returns YES when the queue changed.
static BOOL WolFoxQueueNoteStarted(NSString *videoID) {
    NSMutableArray *queue = WolFoxQueue();
    if (videoID.length == 0 || queue.count == 0) return NO;
    if (WolFoxQueueIndexOfVideo(videoID) != NSNotFound) {
        const BOOL moved = ![videoID isEqualToString:WolFoxQueueCursor()];
        WolFoxQueueSetCursor(videoID);
        WolFoxQueueSetFinished(NO);
        return moved;
    }
    NSUInteger cursor = WolFoxQueueIndexOfVideo(WolFoxQueueCursor());
    if (cursor != NSNotFound && cursor + 1 >= queue.count &&
        WolFoxQueueFinished()) {
        WolFoxDebugLog(@"queue", @"finished queue cleared on start of %@", videoID);
        [queue removeAllObjects];
        WolFoxQueueSave();
        return YES;
    }
    NSMutableDictionary *entry = [NSMutableDictionary dictionary];
    entry[@"videoId"] = videoID;
    [queue insertObject:entry atIndex:cursor == NSNotFound ? 0 : cursor];
    WolFoxQueueSetCursor(videoID);
    WolFoxQueueSave();
    WolFoxQueueFetchTitle(videoID);
    return YES;
}

static NSString *WolFoxQueuePausePendingID;
static NSTimeInterval WolFoxQueuePauseDeadline;

// The first video of a queue built while idle opens paused. The watch player
// is paused as soon as it takes the video and again on its first time tick,
// which is when YouTube may have started it; only the watch player counts.
static void WolFoxQueuePauseIfPending(id player, id videoID, BOOL final) {
    if (WolFoxQueuePausePendingID.length == 0 ||
        ![videoID isEqual:WolFoxQueuePausePendingID] ||
        player != WolFoxQueuePlayerViewController) {
        return;
    }
    if (final) WolFoxQueuePausePendingID = nil;
    WolFoxDebugLog(@"queue", @"pausing %@ final=%d player=[%@]", videoID,
                      final, WolFoxQueueDescribeHost(player));
    if (NSDate.timeIntervalSinceReferenceDate < WolFoxQueuePauseDeadline &&
        [player respondsToSelector:@selector(pause)]) {
        @try {
            ((void (*)(id, SEL))objc_msgSend)(player, @selector(pause));
        } @catch (__unused NSException *exception) {
        }
    }
}

static void WolFoxQueueSetMiniplayerMode(id endpoint) {
    id config = WolFoxQueueMessage(@"YTIWatchEndpointMainAppConfig");
    if (endpoint == nil || config == nil) return;
    @try {
        SEL descriptorSel = NSSelectorFromString(@"descriptor");
        SEL fieldSel = NSSelectorFromString(@"fieldWithName:");
        SEL enumSel = NSSelectorFromString(@"enumDescriptor");
        SEL nameSel = NSSelectorFromString(@"enumNameForValue:");
        if (![[config class] respondsToSelector:descriptorSel]) return;
        id descriptor = ((id (*)(id, SEL))objc_msgSend)([config class],
                                                        descriptorSel);
        if (![descriptor respondsToSelector:fieldSel]) return;
        id field = ((id (*)(id, SEL, id))objc_msgSend)(descriptor, fieldSel,
            @"suggestedInitialPlayerMode");
        if (![field respondsToSelector:enumSel]) return;
        id enumDescriptor = ((id (*)(id, SEL))objc_msgSend)(field, enumSel);
        if (![enumDescriptor respondsToSelector:nameSel]) return;
        for (int32_t value = 0; value < 16; value++) {
            NSString *name = ((id (*)(id, SEL, int32_t))objc_msgSend)(
                enumDescriptor, nameSel, value);
            if (![name isKindOfClass:NSString.class]) continue;
            if ([name rangeOfString:@"Miniplayer"
                            options:NSCaseInsensitiveSearch].location ==
                NSNotFound) {
                continue;
            }
            [config setValue:@(value) forKey:@"suggestedInitialPlayerMode"];
            [endpoint setValue:config forKey:@"watchEndpointMainAppConfig"];
            return;
        }
    } @catch (__unused NSException *exception) {
    }
}

static BOOL WolFoxQueueOpenVia(id command, id view, id sender) {
    return WolFoxQueueSendViaRouter(command, view, sender) ||
        WolFoxQueueSendViaEvent(command, view, sender) ||
        WolFoxQueueSendViaEvent(command, nil, WolFoxQueueResponder);
}

// Opens the first video of a new queue in the miniplayer and pauses it as
// soon as it loads, so the queue is ready without anything playing. It goes
// through the tap that queued it (the last player may be gone) once the menu
// has closed, and falls back to the regular player if no miniplayer appears.
static BOOL WolFoxQueueOpenMinimized(NSString *videoID) {
    id view = WolFoxQueueCommandView;
    id sender = WolFoxQueueCommandSender;
    WolFoxQueuePausePendingID = videoID;
    WolFoxQueuePauseDeadline = NSDate.timeIntervalSinceReferenceDate + 20.0;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        id command = WolFoxQueueWatchCommand(videoID);
        @try {
            WolFoxQueueSetMiniplayerMode([command valueForKey:@"watchEndpoint"]);
        } @catch (__unused NSException *exception) {
        }
        if (WolFoxQueueOpenVia(command, view, sender)) {
            WolFoxQueueNoteSent(videoID);
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)(4.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            // A player that already has the video, even one still loading,
            // must not be sent it again: that reopens the watch page and
            // restarts it.
            id live = WolFoxQueueValue(WolFoxQueuePlayerViewController,
                                       @[@"currentVideoID", @"contentVideoID"]);
            if (![WolFoxQueuePausePendingID isEqualToString:videoID] ||
                WolFoxQueueVideoIsOpen() || [live isEqual:videoID] ||
                [WolFoxLastVideoID() isEqualToString:videoID]) {
                return;
            }
            WolFoxDebugLog(@"queue", @"retrying open of %@", videoID);
            WolFoxQueuePauseDeadline =
                NSDate.timeIntervalSinceReferenceDate + 20.0;
            if (WolFoxQueueOpenVia(WolFoxQueueWatchCommand(videoID), view,
                                   sender)) {
                WolFoxQueueNoteSent(videoID);
            }
        });
    });
    return YES;
}

static NSArray<NSString *> *WolFoxQueueControllerIDs(id controller) {
    NSArray *items = nil;
    @try {
        items = [controller valueForKey:@"playbackQueueItems"];
    } @catch (__unused NSException *exception) {
        return nil;
    }
    if (![items isKindOfClass:NSArray.class]) return nil;
    NSMutableArray<NSString *> *ids = [NSMutableArray array];
    for (id item in items) {
        NSString *videoID = nil;
        @try {
            videoID = [[item valueForKey:@"videoRenderer"] valueForKey:@"videoId"];
        } @catch (__unused NSException *exception) {
            videoID = nil;
        }
        if ([videoID isKindOfClass:NSString.class] && videoID.length != 0) {
            [ids addObject:videoID];
        }
    }
    return ids;
}

// Drops anything YouTube's own queue controller picked up that the user did
// not queue, so the panel mirrors the local queue exactly.
static void WolFoxQueuePruneController(void) {
    id controller = WolFoxQueueControllerInstance;
    if (![controller respondsToSelector:@selector(removeVideoID:)]) return;
    NSString *playing = WolFoxQueueOpenVideoID();
    WolFoxQueueSyncSuppressed = YES;
    for (NSString *videoID in WolFoxQueueControllerIDs(controller)) {
        if (WolFoxQueueIndexOfVideo(videoID) != NSNotFound) continue;
        if ([videoID isEqualToString:playing]) continue;
        @try {
            ((void (*)(id, SEL, id))objc_msgSend)(controller,
                @selector(removeVideoID:), videoID);
        } @catch (__unused NSException *exception) {
        }
    }
    WolFoxQueueSyncSuppressed = NO;
}

static id WolFoxQueuePanelRenderer(void) {
    NSUInteger currentIndex = WolFoxQueueCurrentIndex();
    NSArray<NSDictionary *> *queue = [WolFoxQueue() copy];
    if (queue.count == 0) return nil;
    id panel = WolFoxQueueMessage(@"YTIPlaylistPanelRenderer");
    if (panel == nil) return nil;
    NSMutableArray *contents = [panel valueForKey:@"contentsArray"];
    if (contents == nil) return nil;
    for (NSUInteger index = 0; index < queue.count; index++) {
        NSDictionary *entry = queue[index];
        NSString *videoID = entry[@"videoId"];
        if (videoID.length == 0) continue;
        if (entry[@"title"] == nil || entry[@"length"] == nil) {
            WolFoxQueueFetchTitle(videoID);
        }
        id item = WolFoxQueuePanelItem(videoID, entry[@"title"],
                                       entry[@"author"], entry[@"length"],
                                       index == currentIndex, index);
        if (item == nil) continue;
        [contents addObject:item];
    }
    if (contents.count == 0) return nil;
    [panel setValue:@"WolFoxQueue" forKey:@"playlistId"];
    [panel setValue:WolFoxLocalized(@"Queue") forKey:@"title"];
    id title = WolFoxQueueFormatted(WolFoxLocalized(@"Queue"));
    if (title != nil) [panel setValue:title forKey:@"titleText"];
    [panel setValue:@(contents.count) forKey:@"totalVideos"];
    [panel setValue:@(currentIndex == NSNotFound ? 0 : currentIndex)
             forKey:@"currentIndex"];
    [panel setValue:@(currentIndex == NSNotFound ? 0 : currentIndex)
             forKey:@"localCurrentIndex"];
    [panel setValue:@YES forKey:@"isEditable"];
    id reorder = WolFoxQueueSentinelCommand(@"reorder", @"");
    if (reorder != nil) [panel setValue:reorder forKey:@"onReorderEndpoint"];
    return panel;
}

static void WolFoxQueueAppendToController(NSDictionary *entry,
                                          NSUInteger insertIndex) {
    id controller = WolFoxQueueControllerInstance;
    if (controller == nil || entry[@"videoId"] == nil) return;
    SEL selector = @selector(addItemsFromPlaylistPanel:response:atIndex:
                             ignoreSelectedProperty:notifyObservers:);
    if (![controller respondsToSelector:selector]) return;
    id panel = WolFoxQueueMessage(@"YTIPlaylistPanelRenderer");
    if (panel == nil) return;
    NSMutableArray *contents = [panel valueForKey:@"contentsArray"];
    id item = WolFoxQueuePanelItem(entry[@"videoId"], entry[@"title"],
                                   entry[@"author"], entry[@"length"], NO,
                                   insertIndex);
    if (contents == nil || item == nil) return;
    [contents addObject:item];
    [panel setValue:@"WolFoxQueue" forKey:@"playlistId"];
    [panel setValue:@1 forKey:@"totalVideos"];
    @try {
        ((void (*)(id, SEL, id, id, unsigned long long, BOOL, BOOL))objc_msgSend)(
            controller, selector, panel, WolFoxLastWatchNextResponse,
            (unsigned long long)insertIndex, YES, YES);
    } @catch (NSException *exception) {
        return;
    }
}

static void WolFoxQueueRebuildWatchPage(void) {
    id watch = WolFoxQueueWatchViewController;
    id response = WolFoxLastWatchNextResponse;
    if (watch == nil || response == nil) return;
    if (WolFoxQueuePanelInjected) {
        WolFoxQueueRefreshPanel();
        return;
    }
    if (![watch respondsToSelector:@selector(updateWithWatchNextResponse:)]) {
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            ((void (*)(id, SEL, id))objc_msgSend)(watch,
                @selector(updateWithWatchNextResponse:), response);
        } @catch (NSException *exception) {
            return;
        }
    });
}

static void WolFoxQueueRefreshPanel(void) {
    id controller = WolFoxQueuePanelController;
    if (controller == nil) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        id panel = WolFoxQueuePanelRenderer();
        if (panel == nil) return;
        @try {
            [controller setValue:panel forKey:@"playlistPanelRenderer"];
            if ([controller respondsToSelector:
                    @selector(refreshPlaylistCollectionViewController)]) {
                ((void (*)(id, SEL))objc_msgSend)(controller,
                    @selector(refreshPlaylistCollectionViewController));
            }
            if ([controller respondsToSelector:
                    @selector(updateViewForCurrentVideo)]) {
                ((void (*)(id, SEL))objc_msgSend)(controller,
                    @selector(updateViewForCurrentVideo));
            }
        } @catch (NSException *exception) {
            return;
        }
        WolFoxQueueRestoreLoopMode(controller);
        id watchController = WolFoxQueueWatchViewController;
        if ([watchController respondsToSelector:
                @selector(showPlaylistMiniBarIfNeeded)]) {
            @try {
                ((void (*)(id, SEL))objc_msgSend)(watchController,
                    @selector(showPlaylistMiniBarIfNeeded));
            } @catch (__unused NSException *exception) {
            }
        }
    });
}

static id WolFoxQueuePanelParse(id receiver, SEL selector, id response) {
    id original = nil;
    if (OriginalPanelParse != NULL) {
        original = ((id (*)(id, SEL, id))OriginalPanelParse)(
            receiver, selector, response);
    }
    if (!WolFoxFeatureEnabled(WolFoxQueueKey)) return original;
    if (WolFoxQueue().count == 0) return original;
    if (original != nil) {
        return original;
    }
    id panel = WolFoxQueuePanelRenderer();
    return panel ?: original;
}

static id WolFoxQueueResponsePanel(id receiver, SEL selector) {
    id original = NULL;
    if (OriginalResponsePanel != NULL) {
        original = ((id (*)(id, SEL))OriginalResponsePanel)(receiver, selector);
    }
    if (!WolFoxFeatureEnabled(WolFoxQueueKey)) return original;
    if (WolFoxQueue().count == 0) return original;
    if (original != nil) return original;
    id panel = WolFoxQueuePanelRenderer();
    return panel ?: original;
}








static NSString *WolFoxQueuePanelField(id wrapper) {
    static NSString *cached;
    if (cached != nil) return cached;
    NSString *found = nil;
    SEL descriptorSel = NSSelectorFromString(@"descriptor");
    id descriptor = [[wrapper class] respondsToSelector:descriptorSel]
        ? ((id (*)(id, SEL))objc_msgSend)([wrapper class], descriptorSel) : nil;
    NSArray *fields = [descriptor respondsToSelector:NSSelectorFromString(@"fields")]
        ? [descriptor valueForKey:@"fields"] : nil;
    Class panelClass = NSClassFromString(@"YTIPlaylistPanelRenderer");
    for (id field in fields) {
        NSString *name = [field valueForKey:@"name"];
        if (![name isKindOfClass:NSString.class]) continue;
        SEL msgClassSel = NSSelectorFromString(@"msgClass");
        Class type = [field respondsToSelector:msgClassSel]
            ? ((Class (*)(id, SEL))objc_msgSend)(field, msgClassSel) : Nil;
        if (found == nil && panelClass != Nil && type == panelClass) found = name;
    }
    cached = found ?: @"playlist";
    return cached;
}

// The video a watch-next response belongs to, but only once the player is
// actually on it, so prefetched responses never touch the queue.
static NSString *WolFoxQueueStartedVideoID(id response) {
    id videoID = nil;
    @try {
        videoID = [response valueForKeyPath:
            @"currentVideoEndpoint.watchEndpoint.videoId"];
    } @catch (__unused NSException *exception) {
        videoID = nil;
    }
    if (![videoID isKindOfClass:NSString.class] || [videoID length] == 0) {
        return WolFoxQueueCurrentOverride;
    }
    id live = WolFoxQueueValue(WolFoxQueuePlayerViewController,
                               @[@"currentVideoID", @"contentVideoID"]);
    if ([videoID isEqual:WolFoxQueueCurrentOverride] || [videoID isEqual:live] ||
        [videoID isEqual:WolFoxQueueActiveVideo]) {
        return videoID;
    }
    return nil;
}

static void WolFoxQueueInjectPanel(id response) {
    WolFoxLastWatchNextResponse = response;
    if (!WolFoxFeatureEnabled(WolFoxQueueKey)) return;
    if (WolFoxQueue().count == 0) return;
    @try {
        id contents = [response valueForKey:@"contents"];
        id single = [contents valueForKey:@"singleColumnWatchNextResults"];
        if (single == nil) return;
        id existing = [single valueForKey:@"playlist"];
        NSString *field = existing != nil ? WolFoxQueuePanelField(existing) : @"playlist";
        id current = existing != nil ? [existing valueForKey:field] : nil;
        id owner = current != nil ? WolFoxQueueValue(current, @[@"playlistId"]) : nil;
        if ([owner isKindOfClass:NSString.class] && [owner length] != 0) {
            if (![owner isEqual:@"WolFoxQueue"]) {
                    return;
            }
        }
        WolFoxQueueNoteStarted(WolFoxQueueStartedVideoID(response));
        id panel = WolFoxQueuePanelRenderer();
        if (panel == nil) return;
        id wrapper = WolFoxQueueMessage(
            @"YTISingleColumnWatchNextResultsRenderer_"
            @"SingleColumnWatchNextPlaylistSupportedRenderers");
        if (wrapper == nil) return;
        [wrapper setValue:panel forKey:WolFoxQueuePanelField(wrapper)];
        [single setValue:wrapper forKey:@"playlist"];
        WolFoxQueuePanelInjected = YES;
    } @catch (__unused NSException *exception) {
    }
}

static void WolFoxQueueSetWatchNext(id receiver, SEL selector, id response) {
    WolFoxQueuePlayerViewController = receiver;
    WolFoxDebugLog(@"queue", @"setWatchNext player=[%@] video=%@",
          WolFoxQueueDescribeHost(receiver),
          WolFoxQueueValue(receiver, @[@"currentVideoID", @"contentVideoID"]));
    id fresh = WolFoxQueueValue(receiver, @[@"currentVideoID", @"contentVideoID"]);
    WolFoxQueueCurrentOverride =
        [fresh isKindOfClass:NSString.class] ? fresh : nil;
    if (WolFoxQueueCurrentOverride.length != 0) {
        WolFoxQueueActiveVideo = WolFoxQueueCurrentOverride;
        WolFoxQueueActiveVideoTime = 0;
    }
    WolFoxQueuePauseIfPending(receiver, WolFoxQueueCurrentOverride, NO);
    WolFoxQueueInjectPanel(response);
    WolFoxQueueCurrentOverride = nil;
    if (OriginalSetWatchNext == NULL) return;
    ((void (*)(id, SEL, id))OriginalSetWatchNext)(receiver, selector, response);
}

static void WolFoxQueuePrepareWatchNext(id receiver, SEL selector, id response) {
    WolFoxQueueInjectPanel(response);
    if (OriginalPrepareWatchNext != NULL) {
        ((void (*)(id, SEL, id))OriginalPrepareWatchNext)(
            receiver, selector, response);
    }
}




static void WolFoxQueueViewUpdateWatchNext(id receiver, SEL selector,
                                           id response) {
    WolFoxQueueWatchViewController = receiver;
    WolFoxDebugLog(@"queue", @"viewUpdateWatchNext watch=[%@]",
          WolFoxQueueDescribeHost(receiver));
    WolFoxQueuePanelInjected = NO;
    WolFoxQueueInjectPanel(response);
    if (OriginalViewUpdateWatchNext != NULL) {
        ((void (*)(id, SEL, id))OriginalViewUpdateWatchNext)(
            receiver, selector, response);
    }
}


static void WolFoxQueueEnableEditing(id panelController, id queueController) {
    if (!WolFoxFeatureEnabled(WolFoxQueueKey)) return;
    NSArray<NSString *> *flags = @[@"_enableSwipeToRemove",
                                   @"_enableQueueEditBuffer",
                                   @"_queuePhase4Enabled"];
    for (NSString *flag in flags) {
        @try {
            [panelController setValue:@YES forKey:flag];
        } @catch (__unused NSException *exception) {
        }
    }
    @try {
        [queueController setValue:@YES forKey:@"userModifiedQueue"];
    } @catch (__unused NSException *exception) {
    }
}

static id WolFoxQueuePanelInit(id receiver, SEL selector, id account,
                               id responder) {
    id result = NULL;
    if (OriginalPanelInit != NULL) {
        result = ((id (*)(id, SEL, id, id))OriginalPanelInit)(
            receiver, selector, account, responder);
    }
    WolFoxQueuePanelController = result;
    return result;
}

static id WolFoxQueuePanelInitQueue(id receiver, SEL selector, id account,
                                    id responder, id controller) {
    id result = NULL;
    if (OriginalPanelInitQueue != NULL) {
        result = ((id (*)(id, SEL, id, id, id))OriginalPanelInitQueue)(
            receiver, selector, account, responder, controller);
    }
    WolFoxQueuePanelController = result;
    WolFoxQueueControllerInstance = controller;
    WolFoxQueueEnableEditing(result, controller);
    WolFoxQueueRestoreLoopMode(result);
    return result;
}

static id WolFoxQueueControllerInit(id receiver, SEL selector, id account,
                                    id responder) {
    id result = NULL;
    if (OriginalQueueControllerInit != NULL) {
        result = ((id (*)(id, SEL, id, id))OriginalQueueControllerInit)(
            receiver, selector, account, responder);
    }
    WolFoxQueueControllerInstance = result;
    return result;
}

static BOOL WolFoxQueueIsActive(void) {
    if (!WolFoxFeatureEnabled(WolFoxQueueKey)) return NO;
    return WolFoxQueueIndexOfVideo(WolFoxQueueCurrentVideoID()) != NSNotFound;
}

static void WolFoxQueueDidPressNext(id receiver, SEL selector, id sender) {
    if (WolFoxQueueStep(1, YES)) {
        return;
    }
    if (WolFoxQueueIsActive()) {
        return;
    }
    if (OriginalDidPressNext == NULL) return;
    ((void (*)(id, SEL, id))OriginalDidPressNext)(receiver, selector, sender);
}

static void WolFoxQueueDidPressPrevious(id receiver, SEL selector, id sender) {
    if (WolFoxQueueStep(-1, YES)) {
        return;
    }
    if (WolFoxQueueIsActive()) {
        return;
    }
    if (OriginalDidPressPrevious == NULL) return;
    ((void (*)(id, SEL, id))OriginalDidPressPrevious)(receiver, selector,
                                                      sender);
}

static void WolFoxQueueAutonavPlayNext(id receiver, SEL selector) {
    // Returning to the live edge of a stream can report it as ended; a live
    // stream never hands over to the queue.
    id player = WolFoxQueuePlayerViewController;
    id playing = WolFoxQueueValue(player, @[@"currentVideoID", @"contentVideoID"]);
    NSString *current = [playing isKindOfClass:NSString.class] ? playing : WolFoxQueueActiveVideo;
    const BOOL live = WolFoxQueueVideoIsLive(current, player);
    if (live) {
        if (OriginalAutonavPlayNext != NULL) {
            ((void (*)(id, SEL))OriginalAutonavPlayNext)(receiver, selector);
        }
        return;
    }
    BOOL active = WolFoxQueueIsActive();
    if (active && WolFoxQueueOverlayLoop()) {
        if (WolFoxQueueReplayCurrent()) return;
    }
    if (WolFoxQueueStep(1, NO)) {
        return;
    }
    if (active) {
        return;
    }
    if (OriginalAutonavPlayNext == NULL) return;
    ((void (*)(id, SEL))OriginalAutonavPlayNext)(receiver, selector);
}


// Applies a move or removal made in YouTube's queue controller to the local
// queue. Only videos the controller dropped are removed, and only videos it
// knows about are reordered; anything else (e.g. queued while idle) stays put.
static void WolFoxQueueSyncFromController(id controller,
                                          NSArray<NSString *> *before) {
    if (!WolFoxFeatureEnabled(WolFoxQueueKey) || WolFoxQueueSyncSuppressed) {
        return;
    }
    NSArray<NSString *> *after = WolFoxQueueControllerIDs(controller);
    if (after == nil) return;
    NSMutableArray *queue = WolFoxQueue();
    __block BOOL changed = NO;
    for (NSString *videoID in before) {
        if ([after containsObject:videoID]) continue;
        NSUInteger index = WolFoxQueueIndexOfVideo(videoID);
        if (index == NSNotFound) continue;
        WolFoxQueueRemoveAt(index);
        changed = YES;
    }
    NSMutableIndexSet *slots = [NSMutableIndexSet indexSet];
    for (NSUInteger index = 0; index < queue.count; index++) {
        if ([after containsObject:queue[index][@"videoId"]]) [slots addIndex:index];
    }
    NSMutableArray *ordered = [NSMutableArray array];
    for (NSString *videoID in after) {
        NSUInteger index = WolFoxQueueIndexOfVideo(videoID);
        if (index == NSNotFound) continue;
        if ([ordered indexOfObjectIdenticalTo:queue[index]] != NSNotFound) continue;
        [ordered addObject:queue[index]];
    }
    if (ordered.count == slots.count) {
        NSArray *snapshot = [queue copy];
        __block NSUInteger next = 0;
        [slots enumerateIndexesUsingBlock:^(NSUInteger slot, __unused BOOL *stop) {
            if (snapshot[slot] != ordered[next]) changed = YES;
            queue[slot] = ordered[next++];
        }];
    }
    if (changed) WolFoxQueueSave();
}

static void WolFoxQueueMoveItem(id receiver, SEL selector, id from, id to,
                                BOOL triggered) {
    NSArray *before = WolFoxQueueControllerIDs(receiver);
    if (OriginalMoveItem != NULL) {
        ((void (*)(id, SEL, id, id, BOOL))OriginalMoveItem)(
            receiver, selector, from, to, triggered);
    }
    WolFoxQueueSyncFromController(receiver, before);
}

static void WolFoxQueueRemoveItem(id receiver, SEL selector, id path,
                                  BOOL triggered) {
    NSArray *before = WolFoxQueueControllerIDs(receiver);
    if (OriginalRemoveItem != NULL) {
        ((void (*)(id, SEL, id, BOOL))OriginalRemoveItem)(
            receiver, selector, path, triggered);
    }
    WolFoxQueueSyncFromController(receiver, before);
}

static void WolFoxQueueRemoveIndex(id receiver, SEL selector,
                                   unsigned long long index) {
    NSArray *before = WolFoxQueueControllerIDs(receiver);
    if (OriginalRemoveIndex != NULL) {
        ((void (*)(id, SEL, unsigned long long))OriginalRemoveIndex)(
            receiver, selector, index);
    }
    WolFoxQueueSyncFromController(receiver, before);
}

static void WolFoxQueueClearQueue(id receiver, SEL selector) {
    // YouTube clears its own controller internally (e.g. when the player
    // closes); the local queue is only cleared by the user's Clear action.
    if (OriginalClearQueue != NULL) {
        ((void (*)(id, SEL))OriginalClearQueue)(receiver, selector);
    }
}

static BOOL WolFoxQueueCanMoveItem(id receiver, SEL selector, id from, id to) {
    if (WolFoxQueueIsActive()) return YES;
    if (OriginalCanMoveItem == NULL) return NO;
    return ((BOOL (*)(id, SEL, id, id))OriginalCanMoveItem)(receiver, selector,
                                                            from, to);
}

static NSDictionary *WolFoxQueueUpcomingEntry(void) {
    NSArray *queue = [WolFoxQueue() copy];
    NSUInteger current = WolFoxQueueIndexOfVideo(WolFoxQueueCurrentVideoID());
    if (current == NSNotFound || current + 1 >= queue.count) return nil;
    return queue[current + 1];
}

static id WolFoxQueueNextVideoTitle(id receiver, SEL selector) {
    NSDictionary *entry = WolFoxQueueIsActive() ? WolFoxQueueUpcomingEntry()
                                                : nil;
    NSString *title = entry[@"title"];
    if (title.length != 0) return title;
    if (entry != nil) return entry[@"videoId"];
    if (OriginalNextVideoTitle == NULL) return nil;
    return ((id (*)(id, SEL))OriginalNextVideoTitle)(receiver, selector);
}

static long long WolFoxQueueNextVideoIndex(id receiver, SEL selector) {
    if (WolFoxQueueIsActive()) {
        NSUInteger current =
            WolFoxQueueIndexOfVideo(WolFoxQueueCurrentVideoID());
        if (current != NSNotFound && current + 1 < WolFoxQueue().count) {
            return (long long)(current + 1);
        }
    }
    if (OriginalNextVideoIndex == NULL) return -1;
    return ((long long (*)(id, SEL))OriginalNextVideoIndex)(receiver, selector);
}

static void WolFoxQueueReplaceAutoplay(id receiver, SEL selector, id response) {
    if (WolFoxQueueIsActive()) {
        return;
    }
    if (OriginalReplaceAutoplay == NULL) return;
    ((void (*)(id, SEL, id))OriginalReplaceAutoplay)(receiver, selector,
                                                     response);
}

static void WolFoxQueueCellControllerSetCell(id receiver, SEL selector,
                                             id cell) {
    if (WolFoxQueueIsActive()) {
        for (NSString *flag in @[@"_enableSwipeToRemove",
                                 @"_enableSwipeToRemoveInPlaylistWatchEp2"]) {
            @try {
                [receiver setValue:@YES forKey:flag];
            } @catch (__unused NSException *exception) {
            }
        }
    }
    if (OriginalCellControllerSetCell == NULL) return;
    ((void (*)(id, SEL, id))OriginalCellControllerSetCell)(receiver, selector,
                                                            cell);
}

static double WolFoxQueueAlphaForIndex(id receiver, SEL selector,
                                       unsigned long long index) {
    double value = 1.0;
    if (OriginalAlphaForIndex != NULL) {
        value = ((double (*)(id, SEL, unsigned long long))OriginalAlphaForIndex)(
            receiver, selector, index);
    }
    if (WolFoxQueueIsActive()) {
        if (value < 1.0) {
        }
        return 1.0;
    }
    return value;
}




static void WolFoxQueueClearSlideBackground(UIView *view, NSUInteger depth) {
    if (view == nil || depth > 3) return;
    if ([NSStringFromClass([view class]) isEqualToString:
            @"YTSlideForActionsView"]) {
        view.backgroundColor = UIColor.clearColor;
        view.opaque = NO;
    }
    for (UIView *child in view.subviews) {
        WolFoxQueueClearSlideBackground(child, depth + 1);
    }
}

static void WolFoxQueueSlideLayoutSubviews(id receiver, SEL selector) {
    if (OriginalSlideLayoutSubviews != NULL) {
        ((void (*)(id, SEL))OriginalSlideLayoutSubviews)(receiver, selector);
    }
    if (!WolFoxQueueIsActive()) return;
    if (![receiver isKindOfClass:UIView.class]) return;
    UIView *view = receiver;
    UIView *content = nil;
    @try {
        id value = [receiver valueForKey:@"contentView"];
        content = [value isKindOfClass:UIView.class] ? value : nil;
    } @catch (__unused NSException *exception) {
        content = nil;
    }
    const BOOL sliding = content != nil &&
        fabs(CGRectGetMinX(content.frame)) > 0.5;
    view.backgroundColor = sliding
        ? [UIColor colorWithWhite:0.62 alpha:1.0]
        : UIColor.clearColor;
}

static void WolFoxQueueUpdateCellForIndex(id receiver, SEL selector, id cell,
                                          __unused long long index) {
    if (OriginalUpdateCellForIndex != NULL) {
        ((void (*)(id, SEL, id, long long))OriginalUpdateCellForIndex)(
            receiver, selector, cell, index);
    }
    if (!WolFoxQueueIsActive()) return;
    if ([cell isKindOfClass:UIView.class]) {
        WolFoxQueueClearSlideBackground(cell, 0);
    }
}

static void WolFoxQueueCellPrepareForReuse(id receiver, SEL selector) {
    @try {
        id button = [receiver valueForKey:@"_swipeToRevealButton"];
        if ([button isKindOfClass:UIView.class]) {
            UIView *view = button;
            view.hidden = YES;
            view.frame = CGRectZero;
        }
    } @catch (__unused NSException *exception) {
    }
    @try {
        [receiver setValue:@NO forKey:@"_isRemovingWithAnimation"];
    } @catch (__unused NSException *exception) {
    }
    if ([receiver isKindOfClass:UIView.class]) {
        UIView *cell = receiver;
        WolFoxQueueClearSlideBackground(cell, 0);
        cell.alpha = 1.0;
        cell.transform = CGAffineTransformIdentity;
        for (UIView *subview in cell.subviews) {
            subview.alpha = 1.0;
            subview.transform = CGAffineTransformIdentity;
        }
    }
    if (OriginalCellPrepareForReuse == NULL) return;
    ((void (*)(id, SEL))OriginalCellPrepareForReuse)(receiver, selector);
}

static void WolFoxQueueSetCanReorder(id receiver, SEL selector, BOOL value) {
    if (OriginalSetCanReorder == NULL) return;
    ((void (*)(id, SEL, BOOL))OriginalSetCanReorder)(receiver, selector,
        WolFoxQueueIsActive() ? YES : value);
}

static BOOL WolFoxQueueAllowsReordering(id receiver, SEL selector,
                                        CGPoint point) {
    if (WolFoxQueueIsActive()) return YES;
    if (OriginalAllowsReordering == NULL) return NO;
    return ((BOOL (*)(id, SEL, CGPoint))OriginalAllowsReordering)(
        receiver, selector, point);
}

static void WolFoxQueueSetVideoCountText(id receiver, SEL selector, id text,
                                         BOOL countHidden, BOOL shuffleEnabled,
                                         BOOL shuffleSelected,
                                         BOOL loopEnabled, BOOL loopSelected,
                                         BOOL saveEnabled, BOOL shareEnabled,
                                         BOOL saveSelected, BOOL actionEnabled,
                                         long long loopMode, id renderer,
                                         BOOL useRendererSaveIcons,
                                         BOOL headerHidden) {
    if (OriginalSetVideoCountText == NULL) return;
    if (WolFoxQueueIsActive()) {
        shuffleEnabled = YES;
        loopEnabled = YES;
        actionEnabled = YES;
        loopMode = WolFoxQueueSavedLoopMode();
        loopSelected = loopMode != 0;
    }
    ((void (*)(id, SEL, id, BOOL, BOOL, BOOL, BOOL, BOOL, BOOL, BOOL, BOOL,
               BOOL, long long, id, BOOL, BOOL))OriginalSetVideoCountText)(
        receiver, selector, text, countHidden, shuffleEnabled, shuffleSelected,
        loopEnabled, loopSelected, saveEnabled, shareEnabled, saveSelected,
        actionEnabled, loopMode, renderer, useRendererSaveIcons, headerHidden);
}

static IMP OriginalLegacySetVideoCountText;
static IMP OriginalShouldShowPlaylist;

static void WolFoxQueueLegacySetVideoCountText(id receiver, SEL selector, id text,
                                               BOOL countHidden, BOOL shuffleEnabled,
                                               BOOL shuffleSelected,
                                               BOOL loopEnabled, BOOL loopSelected,
                                               BOOL saveEnabled, BOOL shareEnabled,
                                               BOOL saveSelected, BOOL actionEnabled,
                                               long long loopMode, id renderer,
                                               BOOL useRendererSaveIcons) {
    if (OriginalLegacySetVideoCountText == NULL) return;
    if (WolFoxQueueIsActive()) {
        shuffleEnabled = YES;
        loopEnabled = YES;
        actionEnabled = YES;
        loopMode = WolFoxQueueSavedLoopMode();
        loopSelected = loopMode != 0;
    }
    ((void (*)(id, SEL, id, BOOL, BOOL, BOOL, BOOL, BOOL, BOOL, BOOL, BOOL,
               BOOL, long long, id, BOOL))OriginalLegacySetVideoCountText)(
        receiver, selector, text, countHidden, shuffleEnabled, shuffleSelected,
        loopEnabled, loopSelected, saveEnabled, shareEnabled, saveSelected,
        actionEnabled, loopMode, renderer, useRendererSaveIcons);
}

static BOOL WolFoxQueueShouldShowPlaylist(id receiver, SEL selector) {
    if (WolFoxQueuePanelController != receiver) {
        WolFoxQueuePanelController = receiver;
    }
    if (WolFoxQueueIsActive()) return YES;
    if (OriginalShouldShowPlaylist == NULL) return NO;
    return ((BOOL (*)(id, SEL))OriginalShouldShowPlaylist)(receiver, selector);
}

static void WolFoxQueueDidTapShuffle(id receiver, SEL selector) {
    if (!WolFoxQueueIsActive()) {
        if (OriginalDidTapShuffle == NULL) return;
        ((void (*)(id, SEL))OriginalDidTapShuffle)(receiver, selector);
        return;
    }
    NSMutableArray *queue = WolFoxQueue();
    NSString *currentID = WolFoxQueueCurrentVideoID();
    NSUInteger current = WolFoxQueueIndexOfVideo(currentID);
    if (current == NSNotFound || queue.count < 3) return;
    NSDictionary *entry = queue[current];
    [queue removeObjectAtIndex:current];
    for (NSUInteger index = queue.count; index > 1; index--) {
        const uint32_t pick = arc4random_uniform((uint32_t)index);
        [queue exchangeObjectAtIndex:index - 1 withObjectAtIndex:pick];
    }
    [queue insertObject:entry atIndex:0];
    WolFoxQueueSave();
    NSMutableArray<NSString *> *order = [NSMutableArray array];
    for (NSDictionary *item in queue) {
        [order addObject:item[@"videoId"] ?: @"?"];
    }
    WolFoxQueueRebuildWatchPage();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        WolFoxQueueRefreshPanel();
        WolFoxQueueApplyLoopMode(WolFoxQueuePanelController,
                                 WolFoxQueueSavedLoopMode());
    });
}

static long long WolFoxQueueSavedLoopMode(void) {
    id value = WolFoxPreferenceObject(WolFoxQueueLoopKey);
    return [value respondsToSelector:@selector(longLongValue)]
        ? [value longLongValue] : 0;
}

static void WolFoxQueueStoreLoopMode(long long mode) {
    WolFoxSetPreferenceObject(WolFoxQueueLoopKey, @(mode));
}

static void WolFoxQueueApplyLoopMode(id controller, long long mode) {
    if (controller == nil) return;
    @try {
        [controller setValue:@(mode) forKey:@"loopMode"];
    } @catch (__unused NSException *exception) {
    }
    id collection = nil;
    @try {
        collection =
            [controller valueForKey:@"playlistPanelCollectionViewController"];
    } @catch (__unused NSException *exception) {
        collection = nil;
    }
    if (collection == nil) return;
    @try {
        if ([collection respondsToSelector:@selector(setLoopButtonMode:)]) {
            ((void (*)(id, SEL, long long))objc_msgSend)(collection,
                @selector(setLoopButtonMode:), mode);
        }
        if ([collection respondsToSelector:@selector(setLoopButtonSelected:)]) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(collection,
                @selector(setLoopButtonSelected:), mode != 0);
        }
    } @catch (__unused NSException *exception) {
    }
}

static void WolFoxQueueRestoreLoopMode(id controller) {
    if (controller == nil || !WolFoxQueueIsActive()) return;
    WolFoxQueueApplyLoopMode(controller, WolFoxQueueSavedLoopMode());
}

static void WolFoxQueueClearAll(void) {
    [WolFoxQueue() removeAllObjects];
    WolFoxQueueSave();
    id controller = WolFoxQueueControllerInstance;
    if ([controller respondsToSelector:@selector(clearQueue)]) {
        @try {
            ((void (*)(id, SEL))objc_msgSend)(controller,
                @selector(clearQueue));
        } @catch (__unused NSException *exception) {
        }
    }
    WolFoxShowNotice(WolFoxLocalized(@"Queue cleared"));
    WolFoxQueueRebuildWatchPage();
}

static void WolFoxQueueConfirmClear(void) {
    WolFoxShowYouTubeConfirmation(WolFoxLocalized(@"Clear queue"),
        WolFoxLocalized(@"Remove every video from the queue?"),
        WolFoxLocalized(@"Clear"), ^{
        WolFoxQueueClearAll();
    });
}

// Closing the miniplayer ends the queue, as it ends YouTube's own.
// Originals of hooks installed on every class implementing a selector,
// keyed "selector|class"; a receiver finds its own through its class chain.
static NSMutableDictionary<NSString *, NSValue *> *WolFoxQueueFoundOriginals;

static IMP WolFoxQueueFoundOriginal(id receiver, SEL selector) {
    for (Class cls = object_getClass(receiver); cls != Nil;
         cls = class_getSuperclass(cls)) {
        NSValue *value = WolFoxQueueFoundOriginals[[NSString
            stringWithFormat:@"%s|%@", sel_getName(selector),
            NSStringFromClass(cls)]];
        if (value != nil) return (IMP)value.pointerValue;
    }
    return NULL;
}

// Hooks each selector on every app class whose own method list has it; the
// miniplayer comes in more than one flavour. Only the method lists are read:
// asking the runtime to look a method up would run +initialize on classes
// that are not ready for it this early.
static void WolFoxQueueInstallFoundHooks(NSDictionary<NSString *, NSValue *> *hooks) {
    if (WolFoxQueueFoundOriginals == nil) {
        WolFoxQueueFoundOriginals = [NSMutableDictionary dictionary];
    }
    NSMutableSet<NSString *> *missing = [NSMutableSet setWithArray:hooks.allKeys];
    for (NSString *name in WolFoxAppClassNames()) {
        Class cls = NSClassFromString(name);
        if (cls == Nil) continue;
        unsigned int count = 0;
        Method *methods = class_copyMethodList(cls, &count);
        for (unsigned int index = 0; index < count; index++) {
            NSString *selectorName = NSStringFromSelector(
                method_getName(methods[index]));
            NSValue *replacement = hooks[selectorName];
            if (replacement == nil) continue;
            IMP original = NULL;
            if (!WolFoxInstallInstanceHook(name, selectorName,
                                           (IMP)replacement.pointerValue,
                                           &original)) {
                continue;
            }
            WolFoxQueueFoundOriginals[[NSString stringWithFormat:@"%@|%@",
                selectorName, name]] =
                [NSValue valueWithPointer:(void *)original];
            [missing removeObject:selectorName];
            WolFoxDebugLog(@"queue", @"hook %@ on %@", selectorName, name);
        }
        free(methods);
    }
    for (NSString *selectorName in missing) {
        WolFoxDebugLog(@"queue", @"hook %@: no class", selectorName);
    }
}

// Drops the queue without touching the watch page, for when it is closing.
static void WolFoxQueueDropAll(void) {
    if (!WolFoxFeatureEnabled(WolFoxQueueKey) || WolFoxQueue().count == 0) return;
    [WolFoxQueue() removeAllObjects];
    WolFoxQueueSetCursor(nil);
    WolFoxQueueSave();
}

static void WolFoxQueueDidDismissMiniBar(id receiver, SEL selector) {
    WolFoxDebugLog(@"queue", @"miniplayer dismissed queue=%lu",
                      (unsigned long)WolFoxQueue().count);
    WolFoxQueueDropAll();
    IMP original = WolFoxQueueFoundOriginal(receiver, selector);
    if (original == NULL) return;
    ((void (*)(id, SEL))original)(receiver, selector);
}

static void WolFoxQueueDidTapAction(id receiver, SEL selector, id button) {
    if (!WolFoxQueueIsActive()) {
        if (OriginalDidTapAction == NULL) return;
        ((void (*)(id, SEL, id))OriginalDidTapAction)(receiver, selector,
                                                      button);
        return;
    }
    UIView *source = [button isKindOfClass:UIView.class] ? button : nil;
    WolFoxDownloadCoordinator *coordinator =
        WolFoxDownloadCoordinator.sharedCoordinator;
    NSMutableArray *actions = [NSMutableArray array];
    if (WolFoxQueue().count != 0 && WolFoxDownloadsEnabled()) {
        [actions addObject:[coordinator nativeSheetAction:
            WolFoxLocalized(@"Download") icon:@"arrow.down.circle"
            handler:^{
                NSArray *queue = [WolFoxQueue() copy];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                    (int64_t)(0.12 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                        WolFoxPresentVideoListDownloadMenu(queue,
                            WolFoxLocalized(@"Queue"), source);
                    });
            }]];
    }
    [actions addObject:[coordinator nativeSheetAction:
        WolFoxLocalized(@"Clear queue") icon:@"trash" handler:^{
            WolFoxQueueConfirmClear();
        }]];
    [coordinator presentPlaylistSheetWithTitle:nil subtitle:nil
                                    sourceView:source actions:actions];
}

static void WolFoxQueueDidTapLoop(id receiver, SEL selector) {
    if (OriginalDidTapLoop != NULL) {
        ((void (*)(id, SEL))OriginalDidTapLoop)(receiver, selector);
    }
    if (!WolFoxQueueIsActive()) return;
    const long long resolved = (WolFoxQueueSavedLoopMode() + 1) % 3;
    WolFoxQueueStoreLoopMode(resolved);
    WolFoxQueueApplyLoopMode(receiver, resolved);
}

static BOOL WolFoxQueueHasStep(NSInteger offset) {
    if (!WolFoxFeatureEnabled(WolFoxQueueKey)) return NO;
    NSUInteger current = WolFoxQueueIndexOfVideo(WolFoxQueueCurrentVideoID());
    if (current == NSNotFound) {
        return offset > 0 && WolFoxQueueNextIndex() != NSNotFound;
    }
    if (WolFoxQueueSavedLoopMode() != 0) return WolFoxQueue().count > 1;
    const NSInteger target = (NSInteger)current + offset;
    return target >= 0 && target < (NSInteger)WolFoxQueue().count;
}

static BOOL WolFoxQueueAutonavHasNext(id receiver, SEL selector) {
    if (WolFoxQueueHasStep(1)) return YES;
    if (OriginalAutonavHasNext == NULL) return NO;
    return ((BOOL (*)(id, SEL))OriginalAutonavHasNext)(receiver, selector);
}

static BOOL WolFoxQueueAutonavHasPrevious(id receiver, SEL selector) {
    if (WolFoxQueueHasStep(-1)) return YES;
    if (OriginalAutonavHasPrevious == NULL) return NO;
    return ((BOOL (*)(id, SEL))OriginalAutonavHasPrevious)(receiver, selector);
}

static BOOL WolFoxQueueControllerHasNext(id receiver, SEL selector) {
    if (WolFoxQueueHasStep(1)) return YES;
    if (OriginalQueueHasNext == NULL) return NO;
    return ((BOOL (*)(id, SEL))OriginalQueueHasNext)(receiver, selector);
}

static BOOL WolFoxQueueControllerHasPrevious(id receiver, SEL selector) {
    if (WolFoxQueueHasStep(-1)) return YES;
    if (OriginalQueueHasPrevious == NULL) return NO;
    return ((BOOL (*)(id, SEL))OriginalQueueHasPrevious)(receiver, selector);
}

static unsigned long long WolFoxQueueNextNavigable(id receiver, SEL selector) {
    if (WolFoxQueueHasStep(1)) {
        NSUInteger current =
            WolFoxQueueIndexOfVideo(WolFoxQueueCurrentVideoID());
        if (current != NSNotFound) {
            const NSUInteger count = WolFoxQueue().count;
            return (unsigned long long)((current + 1) % MAX(count, 1u));
        }
        return (unsigned long long)WolFoxQueueNextIndex();
    }
    if (OriginalNextNavigable == NULL) return 0;
    return ((unsigned long long (*)(id, SEL))OriginalNextNavigable)(receiver,
                                                                    selector);
}

static unsigned long long WolFoxQueuePreviousNavigable(id receiver,
                                                       SEL selector) {
    if (WolFoxQueueHasStep(-1)) {
        NSUInteger current =
            WolFoxQueueIndexOfVideo(WolFoxQueueCurrentVideoID());
        const NSUInteger count = WolFoxQueue().count;
        if (current != NSNotFound && count != 0) {
            return (unsigned long long)(current == 0 ? count - 1 : current - 1);
        }
    }
    if (OriginalPreviousNavigable == NULL) return 0;
    return ((unsigned long long (*)(id, SEL))OriginalPreviousNavigable)(
        receiver, selector);
}

static id WolFoxQueuePanelByline(id receiver, SEL selector) {
    if (WolFoxQueueIsActive()) {
        NSUInteger current =
            WolFoxQueueIndexOfVideo(WolFoxQueueCurrentVideoID());
        const NSUInteger count = WolFoxQueue().count;
        if (current != NSNotFound && count != 0) {
            return [NSString stringWithFormat:@"%@ • %lu/%lu",
                WolFoxLocalized(@"Queue"), (unsigned long)(current + 1),
                (unsigned long)count];
        }
    }
    if (OriginalPanelByline == NULL) return nil;
    return ((id (*)(id, SEL))OriginalPanelByline)(receiver, selector);
}

static BOOL WolFoxQueueIsQueue(id receiver, SEL selector) {
    if (WolFoxQueuePanelController != receiver) {
        WolFoxQueuePanelController = receiver;
    }
    if (WolFoxQueueIsActive()) return YES;
    if (OriginalIsQueue == NULL) return NO;
    return ((BOOL (*)(id, SEL))OriginalIsQueue)(receiver, selector);
}

static BOOL WolFoxQueueHasContents(id receiver, SEL selector) {
    if (WolFoxQueuePanelController != receiver) {
        WolFoxQueuePanelController = receiver;
    }
    if (WolFoxQueueIsActive()) return YES;
    if (OriginalHasQueueContents == NULL) return NO;
    return ((BOOL (*)(id, SEL))OriginalHasQueueContents)(receiver, selector);
}

// Whether the player is on a live stream. At the live edge the playback time
// equals the length, which would otherwise look like the end of the video.
BOOL WolFoxQueueVideoIsLive(NSString *videoID, id player) {
    id single = WolFoxQueueValue(player, @[@"activeVideo"]);
    SEL pegged = NSSelectorFromString(@"isPeggedToLive");
    if ([single respondsToSelector:pegged] &&
        ((BOOL (*)(id, SEL))objc_msgSend)(single, pegged)) {
        return YES;
    }
    static NSString *cachedID;
    static BOOL cachedLive;
    if (videoID.length != 0 && [videoID isEqualToString:cachedID]) return cachedLive;
    id details = nil;
    @try {
        details = WolFoxQueueVideoDetails(
            WolFoxQueueValue(player, @[@"contentPlayerResponse", @"playerResponse"]));
        if (details == nil && videoID.length != 0) {
            details = WolFoxQueueVideoDetails(WolFoxCachedPlayerResponse(videoID));
        }
    } @catch (__unused NSException *exception) {
    }
    SEL liveSelector = NSSelectorFromString(@"isLive");
    if (details == nil || ![details respondsToSelector:liveSelector]) return NO;
    const BOOL live = ((BOOL (*)(id, SEL))objc_msgSend)(details, liveSelector);
    cachedID = [videoID copy];
    cachedLive = live;
    return live;
}

static void WolFoxQueueHandlePlaybackTime(NSNotification *notification) {
    if (!WolFoxFeatureEnabled(WolFoxQueueKey)) return;
    id receiver = notification.object;
    if (receiver == nil) return;
    // Feed previews run their own player; only the watch player drives the
    // queue and names its current video.
    id watchPlayer = WolFoxQueuePlayerViewController;
    if (watchPlayer != nil && receiver != watchPlayer) return;
    WolFoxQueueResponder = receiver;
    id live = WolFoxQueueValue(receiver, @[@"currentVideoID", @"contentVideoID"]);
    if ([live isKindOfClass:NSString.class] && [live length] != 0 &&
        ![live isEqualToString:WolFoxQueueActiveVideo]) {
        WolFoxQueueActiveVideo = live;
        WolFoxQueueActiveVideoTime = 0;
        if (receiver == WolFoxQueuePlayerViewController &&
            WolFoxQueueNoteStarted(live)) {
            WolFoxQueueRefreshPanel();
        }
    }
    WolFoxQueuePauseIfPending(receiver, live, YES);
    if (WolFoxQueue().count == 0) return;
    SEL totalSelector = NSSelectorFromString(@"currentVideoTotalMediaTime");
    if (![receiver respondsToSelector:totalSelector]) return;
    const double total = ((double (*)(id, SEL))objc_msgSend)(receiver, totalSelector);
    const double time = [notification.userInfo[@"time"] doubleValue];
    if (total <= 0.0 || time <= 0.0) return;
    // Track the video that is finishing itself rather than the last requested
    // ID, which prefetching changes; otherwise a late tick from the old video
    // advances a second time and skips a queued item.
    NSString *finishing = [live isKindOfClass:NSString.class] && [live length] != 0
        ? (NSString *)live : WolFoxLastVideoID();
    if (finishing.length == 0) return;
    if (WolFoxQueueVideoIsLive(finishing, receiver)) return;
    const BOOL advanced =
        [finishing isEqualToString:WolFoxQueueAdvancedFromVideoID];
    if (time < total - 0.75) {
        if (advanced && time < MAX(total - 5.0, total * 0.5)) {
            WolFoxQueueAdvancedFromVideoID = nil;
        }
        return;
    }
    if (advanced) return;
    if (WolFoxQueueIndexOfVideo(finishing) == NSNotFound) {
        // Only the watch player, never a muted feed preview, hands over to
        // the queue after a video that was opened outside it.
        if (receiver != WolFoxQueuePlayerViewController ||
            !WolFoxQueueVideoIsOpen() ||
            WolFoxQueueNextIndex() == NSNotFound) {
            return;
        }
    }
    if (WolFoxFeatureEnabled(@"YTKACE.Preference.Playback.AutoplayDisabled")) {
        return;
    }
    WolFoxQueueAdvancedFromVideoID = finishing;
    WolFoxQueueAdvance(finishing);
}


static NSString *const WolFoxQueueSentinelPrefix = @"WolFoxQ|";

static id WolFoxQueueSentinelCommand(NSString *action, NSString *videoID) {
    id command = WolFoxQueueMessage(@"YTICommand");
    if (command == nil) return nil;
    NSString *marker = [NSString stringWithFormat:@"%@%@|%@",
        WolFoxQueueSentinelPrefix, action, videoID];
    [command setValue:[marker dataUsingEncoding:NSUTF8StringEncoding]
               forKey:@"clickTrackingParams"];
    return command;
}

static id WolFoxQueueMenuItem(NSString *label, NSString *action,
                              NSString *videoID) {
    id wrapper = WolFoxQueueMessage(@"YTIMenuItemSupportedRenderers");
    id item = WolFoxQueueMessage(@"YTIMenuServiceItemRenderer");
    id command = WolFoxQueueSentinelCommand(action, videoID);
    if (wrapper == nil || item == nil || command == nil) return nil;
    id text = WolFoxQueueFormatted(label);
    if (text != nil) [item setValue:text forKey:@"text"];
    [item setValue:command forKey:@"serviceEndpoint"];
    [wrapper setValue:item forKey:@"menuServiceItemRenderer"];
    return wrapper;
}

static id WolFoxQueueItemMenu(NSString *videoID) {
    id supported = WolFoxQueueMessage(@"YTIMenuSupportedRenderers");
    id renderer = WolFoxQueueMessage(@"YTIMenuRenderer");
    if (supported == nil || renderer == nil) return nil;
    NSMutableArray *items = [renderer valueForKey:@"itemsArray"];
    if (items == nil) return nil;
    id playNext = WolFoxQueueMenuItem(WolFoxLocalized(@"Play next in queue"),
                                      @"next", videoID);
    id remove = WolFoxQueueMenuItem(WolFoxLocalized(@"Remove from queue"),
                                    @"remove", videoID);
    if (playNext != nil) [items addObject:playNext];
    if (remove != nil) [items addObject:remove];
    if (items.count == 0) return nil;
    [supported setValue:renderer forKey:@"menuRenderer"];
    return supported;
}

static BOOL WolFoxQueueHandleSentinel(id command) {
    if (!WolFoxFeatureEnabled(WolFoxQueueKey)) return NO;
    NSString *dump = WolFoxQueueClip(command, 600);
    NSRange range = [dump rangeOfString:WolFoxQueueSentinelPrefix];
    if (range.location == NSNotFound) return NO;
    NSString *tail = [dump substringFromIndex:NSMaxRange(range)];
    NSArray<NSString *> *parts = [tail componentsSeparatedByString:@"|"];
    if (parts.count < 2) return NO;
    NSString *action = parts[0];
    NSString *videoID = [parts[1] substringToIndex:
        MIN((NSUInteger)11, [parts[1] length])];
    NSUInteger index = WolFoxQueueIndexOfVideo(videoID);
    if (index == NSNotFound) return NO;
    NSDictionary *entry = WolFoxQueue()[index];
    if ([action isEqualToString:@"remove"]) {
        WolFoxQueueRemoveAt(index);
        WolFoxQueueSave();
        id controller = WolFoxQueueControllerInstance;
        if ([controller respondsToSelector:@selector(removeVideoID:)]) {
            @try {
                ((void (*)(id, SEL, id))objc_msgSend)(controller,
                    @selector(removeVideoID:), videoID);
            } @catch (__unused NSException *exception) {
            }
        }
        WolFoxShowNotice(WolFoxLocalized(@"Removed from queue"));
        WolFoxQueueRebuildWatchPage();
    } else if ([action isEqualToString:@"next"]) {
        NSUInteger target = WolFoxQueueUpcomingIndex(WolFoxQueueOpenVideoID());
        if (index < target) target--;
        if (index == target) {
            WolFoxShowNotice(WolFoxLocalized(@"Playing next"));
            return YES;
        }
        [WolFoxQueue() removeObjectAtIndex:index];
        [WolFoxQueue() insertObject:entry atIndex:MIN(target,
            WolFoxQueue().count)];
        WolFoxQueueSave();
        WolFoxShowNotice(WolFoxLocalized(@"Playing next"));
    } else {
        return NO;
    }
    WolFoxQueueRefreshPanel();
    return YES;
}

static BOOL WolFoxQueueHandleDiscovery(id command, id view) {
    if (!WolFoxFeatureEnabled(WolFoxQueueKey)) return NO;
    NSString *params = nil;
    @try {
        params = WolFoxQueueDiscoveryParams(command);
    } @catch (__unused NSException *exception) {
        return NO;
    }
    if (params.length == 0) return NO;
    NSString *decoded = [params stringByRemovingPercentEncoding] ?: params;
    NSData *data = [[NSData alloc] initWithBase64EncodedString:decoded
        options:NSDataBase64DecodingIgnoreUnknownCharacters];
    if (data.length == 0) return NO;
    int position = 0;
    NSString *videoID = WolFoxQueueVideoIDFromParams(data, &position);
    if (videoID.length == 0) return NO;
    if (position != 2 && position != 3) return NO;
    WolFoxQueueAdd(videoID, WolFoxQueueTitleNearView(view), position == 2);
    return YES;
}

static void WolFoxQueueDiscoveryExecute(id receiver, SEL selector, id command,
                                        id entry, id view, id sender) {
    if (WolFoxQueueHandleDiscovery(command, view)) return;
    if (OriginalDiscoveryExecute == NULL) return;
    ((void (*)(id, SEL, id, id, id, id))OriginalDiscoveryExecute)(
        receiver, selector, command, entry, view, sender);
}


static NSString *WolFoxQueueClip(id object, NSUInteger limit) {
    NSString *text = nil;
    @try {
        text = [object description];
    } @catch (__unused NSException *exception) {
        return @"<description failed>";
    }
    if (text.length == 0) return @"<empty>";
    text = [text stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
    if (text.length <= limit) return text;
    return [text substringToIndex:limit];
}




// Queue adds that carry the video directly (queueAddEndpoint, or the
// queueAddMenuItemCommand YouTube sends when nothing is playing).
static BOOL WolFoxQueueHandleEndpointAdd(NSString *dump, id view) {
    NSRange marker = [dump rangeOfString:@"queue_add_endpoint"];
    if (marker.location == NSNotFound) marker = [dump rangeOfString:@"queueAddEndpoint"];
    if (marker.location == NSNotFound) {
        marker = [dump rangeOfString:@"queue_add_menu_item_command"];
    }
    if (marker.location == NSNotFound) {
        marker = [dump rangeOfString:@"queueAddMenuItemCommand"];
    }
    // Only a command that is itself a queue add, not one (like a menu) that
    // merely contains queue options somewhere inside it.
    if (marker.location == NSNotFound || marker.location > 300) return NO;
    if ([dump containsString:@"menu_renderer"] ||
        [dump containsString:@"menuRenderer"] ||
        [dump containsString:@"popup"]) {
        return NO;
    }
    static NSRegularExpression *expression;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        expression = [NSRegularExpression regularExpressionWithPattern:
            @"video_?[iI]d:\\s*\"([A-Za-z0-9_-]{11})\""
                                                               options:0 error:NULL];
    });
    NSRange tail = NSMakeRange(marker.location, dump.length - marker.location);
    NSTextCheckingResult *match = [expression firstMatchInString:dump options:0
                                                           range:tail];
    if (match == nil) return NO;
    NSString *videoID = [dump substringWithRange:[match rangeAtIndex:1]];
    NSString *upper = dump.uppercaseString;
    const BOOL playNext = [upper containsString:@"AFTER_CURRENT"] ||
        [upper containsString:@"PLAY_NEXT"];
    WolFoxQueueAdd(videoID, WolFoxQueueTitleNearView(view), playNext);
    return YES;
}

static BOOL WolFoxQueueHandleMenuAdd(id command, id view) {
    if (!WolFoxFeatureEnabled(WolFoxQueueKey)) return NO;
    NSString *dump = nil;
    @try {
        dump = [command description];
    } @catch (__unused NSException *exception) {
        return NO;
    }
    if (![dump containsString:@"getWatchNextQueueAddCommand"]) {
        return WolFoxQueueHandleEndpointAdd(dump, view);
    }
    static NSRegularExpression *expression;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        expression = [NSRegularExpression regularExpressionWithPattern:
            @"getWatchNextQueueAddCommand\\]\\s*params:\\s*\"([^\"]+)\""
                                                               options:0 error:NULL];
    });
    NSTextCheckingResult *match = [expression firstMatchInString:dump options:0
        range:NSMakeRange(0, dump.length)];
    if (match == nil) return NO;
    NSString *params = [dump substringWithRange:[match rangeAtIndex:1]];
    NSString *decoded = [params stringByRemovingPercentEncoding] ?: params;
    NSData *data = [[NSData alloc] initWithBase64EncodedString:decoded
        options:NSDataBase64DecodingIgnoreUnknownCharacters];
    NSString *videoID = data.length ? WolFoxQueueVideoIDFromParams(data, NULL) : nil;
    if (videoID.length == 0) return NO;
    BOOL playNext = YES;
    const unsigned char *bytes = (const unsigned char *)data.bytes;
    for (NSUInteger index = 0; index + 1 < data.length; index++) {
        if (bytes[index] == 0x18 && (bytes[index + 1] == 0x01 || bytes[index + 1] == 0x02)) {
            playNext = bytes[index + 1] == 0x01;
            break;
        }
    }
    WolFoxQueueAdd(videoID, WolFoxQueueTitleNearView(view), playNext);
    return YES;
}

static id WolFoxQueueConditionalItem(id wrapper) {
    SEL getter = NSSelectorFromString(@"menuConditionalServiceItemRenderer");
    SEL has = NSSelectorFromString(@"hasMenuConditionalServiceItemRenderer");
    if (![wrapper respondsToSelector:getter] || ![wrapper respondsToSelector:has]) return nil;
    if (!((BOOL (*)(id, SEL))objc_msgSend)(wrapper, has)) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(wrapper, getter);
}

void WolFoxQueuePrepareMenuRenderers(id renderers) {
    if (![renderers isKindOfClass:NSArray.class]) return;
    if (!WolFoxFeatureEnabled(WolFoxQueueKey)) return;
    NSMutableDictionary<NSString *, id> *commands = [NSMutableDictionary dictionary];
    NSMutableArray *upsells = [NSMutableArray array];
    for (id wrapper in renderers) {
        id item = WolFoxQueueConditionalItem(wrapper);
        if (item == nil) continue;
        NSString *dump = [item description];
        NSString *icon = [dump containsString:@"QUEUE_PLAY_NEXT"] ? @"next"
            : ([dump containsString:@"ADD_TO_REMOTE_QUEUE"] ? @"last" : nil);
        if (icon == nil) continue;
        if ([dump containsString:@"getWatchNextQueueAddCommand"]) {
            if (commands[icon] == nil) commands[icon] = [item valueForKey:@"serviceEndpoint"];
        } else if ([dump containsString:@"SPunlimited"]) {
            [upsells addObject:@[item, icon]];
        }
    }
    for (NSArray *pair in upsells) {
        id command = commands[pair[1]];
        if (command == nil) continue;
        id item = pair[0];
        [item setValue:command forKey:@"serviceEndpoint"];
        SEL clearIcon = NSSelectorFromString(@"setSecondaryIcon:");
        if ([item respondsToSelector:clearIcon]) {
            ((void (*)(id, SEL, id))objc_msgSend)(item, clearIcon, nil);
        }
    }
}

static BOOL WolFoxQueueRouterHandle(id receiver, SEL selector, id command,
                                    id entry, id view, id sender) {
    WolFoxQueueNoteRouter(receiver, OriginalRouterHandle, NO, view, sender);
    if (WolFoxQueueHandleMenuAdd(command, view)) return YES;
    if (WolFoxQueueHandleSentinel(command)) return YES;
    if (WolFoxQueueHandleDiscovery(command, view)) return YES;
    if (OriginalRouterHandle == NULL) return NO;
    return ((BOOL (*)(id, SEL, id, id, id, id))OriginalRouterHandle)(
        receiver, selector, command, entry, view, sender);
}

static BOOL WolFoxQueueRouterHandleCompletion(id receiver, SEL selector,
                                              id command, id entry, id view,
                                              id sender, id block) {
    WolFoxQueueNoteRouter(receiver, OriginalRouterHandleCompletion, YES, view,
                          sender);
    if (WolFoxQueueHandleMenuAdd(command, view)) return YES;
    if (WolFoxQueueHandleSentinel(command)) return YES;
    if (WolFoxQueueHandleDiscovery(command, view)) return YES;
    if (OriginalRouterHandleCompletion == NULL) return NO;
    return ((BOOL (*)(id, SEL, id, id, id, id, id))OriginalRouterHandleCompletion)(
        receiver, selector, command, entry, view, sender, block);
}

static BOOL WolFoxQueueScopedRouterHandle(id receiver, SEL selector, id command,
                                          id entry, id view, id sender) {
    WolFoxQueueNoteRouter(receiver, OriginalScopedRouterHandle, NO, view,
                          sender);
    if (WolFoxQueueHandleMenuAdd(command, view)) return YES;
    if (WolFoxQueueHandleSentinel(command)) return YES;
    if (WolFoxQueueHandleDiscovery(command, view)) return YES;
    if (OriginalScopedRouterHandle == NULL) return NO;
    return ((BOOL (*)(id, SEL, id, id, id, id))OriginalScopedRouterHandle)(
        receiver, selector, command, entry, view, sender);
}

static BOOL WolFoxQueueScopedRouterHandleCompletion(id receiver, SEL selector,
                                                    id command, id entry,
                                                    id view, id sender,
                                                    id block) {
    WolFoxQueueNoteRouter(receiver, OriginalScopedRouterHandleCompletion, YES,
                          view, sender);
    if (WolFoxQueueHandleMenuAdd(command, view)) return YES;
    if (WolFoxQueueHandleSentinel(command)) return YES;
    if (WolFoxQueueHandleDiscovery(command, view)) return YES;
    if (OriginalScopedRouterHandleCompletion == NULL) return NO;
    return ((BOOL (*)(id, SEL, id, id, id, id, id))
        OriginalScopedRouterHandleCompletion)(
        receiver, selector, command, entry, view, sender, block);
}

static IMP OriginalLegacyQueueMenuAdd;
static IMP OriginalLegacyWatchNextQueueAdd;

static void WolFoxLegacyQueueMenuAdd(id receiver, SEL selector, id command,
                                     id entry, id view, id sender) {
    if (WolFoxQueueHandleMenuAdd(command, view)) return;
    ((void (*)(id, SEL, id, id, id, id))OriginalLegacyQueueMenuAdd)(
        receiver, selector, command, entry, view, sender);
}

static void WolFoxLegacyWatchNextQueueAdd(id receiver, SEL selector, id command,
                                          id entry, id view, id sender) {
    if (WolFoxQueueHandleMenuAdd(command, view)) return;
    ((void (*)(id, SEL, id, id, id, id))OriginalLegacyWatchNextQueueAdd)(
        receiver, selector, command, entry, view, sender);
}

// This YouTube build routes queue menu taps to the Impl subclasses, which
// override the base-class methods hooked above.
static IMP OriginalImplMenuExecute;
static IMP OriginalImplMenuExecuteCompletion;
static IMP OriginalImplMenuHandle;
static IMP OriginalImplMenuHandleCompletion;
static IMP OriginalImplWatchNextExecute;
static IMP OriginalImplWatchNextExecuteCompletion;

static BOOL WolFoxQueueTakeMenuCommand(id command, id view, id sender) {
    WolFoxQueueCommandSender = sender;
    WolFoxQueueCommandView = view;
    return WolFoxQueueHandleMenuAdd(command, view);
}

static CFAbsoluteTime WolFoxQueueMenuTapTime;

static void WolFoxImplMenuExecute(id receiver, SEL selector, id command,
                                  id entry, id view, id sender) {
    if (WolFoxQueueTakeMenuCommand(command, view, sender)) return;
    if (OriginalImplMenuExecute == NULL) return;
    ((void (*)(id, SEL, id, id, id, id))OriginalImplMenuExecute)(
        receiver, selector, command, entry, view, sender);
}

static void WolFoxImplMenuExecuteCompletion(id receiver, SEL selector,
                                            id command, id entry, id view,
                                            id sender, id block) {
    if (WolFoxQueueTakeMenuCommand(command, view, sender)) return;
    if (OriginalImplMenuExecuteCompletion == NULL) return;
    ((void (*)(id, SEL, id, id, id, id, id))OriginalImplMenuExecuteCompletion)(
        receiver, selector, command, entry, view, sender, block);
}

static void WolFoxImplMenuHandle(id receiver, SEL selector, id command,
                                 id entry, id view, id sender) {
    if (WolFoxQueueTakeMenuCommand(command, view, sender)) return;
    if (OriginalImplMenuHandle == NULL) return;
    ((void (*)(id, SEL, id, id, id, id))OriginalImplMenuHandle)(
        receiver, selector, command, entry, view, sender);
}

static void WolFoxImplMenuHandleCompletion(id receiver, SEL selector,
                                           id command, id entry, id view,
                                           id sender, id block) {
    if (WolFoxQueueTakeMenuCommand(command, view, sender)) return;
    if (OriginalImplMenuHandleCompletion == NULL) return;
    ((void (*)(id, SEL, id, id, id, id, id))OriginalImplMenuHandleCompletion)(
        receiver, selector, command, entry, view, sender, block);
}

static void WolFoxImplWatchNextExecute(id receiver, SEL selector, id command,
                                       id entry, id view, id sender) {
    if (WolFoxQueueTakeMenuCommand(command, view, sender)) return;
    if (OriginalImplWatchNextExecute == NULL) return;
    ((void (*)(id, SEL, id, id, id, id))OriginalImplWatchNextExecute)(
        receiver, selector, command, entry, view, sender);
}

static void WolFoxImplWatchNextExecuteCompletion(id receiver, SEL selector,
                                                 id command, id entry,
                                                 id view, id sender,
                                                 id block) {
    if (WolFoxQueueTakeMenuCommand(command, view, sender)) return;
    if (OriginalImplWatchNextExecuteCompletion == NULL) return;
    ((void (*)(id, SEL, id, id, id, id, id))
        OriginalImplWatchNextExecuteCompletion)(
        receiver, selector, command, entry, view, sender, block);
}

void WolFoxInstallQueueHooks(void) {
    WolFoxInstallInstanceHook(@"YTQueueAddMenuItemCommandHandlerImpl",
        @"executeWithCommand:entry:fromView:sender:",
        (IMP)WolFoxImplMenuExecute, &OriginalImplMenuExecute);
    WolFoxInstallInstanceHook(@"YTQueueAddMenuItemCommandHandlerImpl",
        @"executeWithCommand:entry:fromView:sender:completionBlock:",
        (IMP)WolFoxImplMenuExecuteCompletion,
        &OriginalImplMenuExecuteCompletion);
    WolFoxInstallInstanceHook(@"YTQueueAddMenuItemCommandHandlerImpl",
        @"handleQueueAddMenuItemWithCommand:entry:fromView:sender:",
        (IMP)WolFoxImplMenuHandle, &OriginalImplMenuHandle);
    WolFoxInstallInstanceHook(@"YTQueueAddMenuItemCommandHandlerImpl",
        @"handleQueueAddMenuItemWithCommand:entry:fromView:sender:"
        @"completionBlock:",
        (IMP)WolFoxImplMenuHandleCompletion,
        &OriginalImplMenuHandleCompletion);
    WolFoxInstallInstanceHook(@"YTGetWatchNextQueueAddCommandHandlerImpl",
        @"executeWithCommand:entry:fromView:sender:",
        (IMP)WolFoxImplWatchNextExecute, &OriginalImplWatchNextExecute);
    WolFoxInstallInstanceHook(@"YTGetWatchNextQueueAddCommandHandlerImpl",
        @"executeWithCommand:entry:fromView:sender:completionBlock:",
        (IMP)WolFoxImplWatchNextExecuteCompletion,
        &OriginalImplWatchNextExecuteCompletion);
    WolFoxInstallInstanceHook(@"YTQueueAddMenuItemCommandHandler",
        @"executeWithCommand:entry:fromView:sender:",
        (IMP)WolFoxLegacyQueueMenuAdd, &OriginalLegacyQueueMenuAdd);
    WolFoxInstallInstanceHook(@"YTGetWatchNextQueueAddCommandHandler",
        @"executeWithCommand:entry:fromView:sender:",
        (IMP)WolFoxLegacyWatchNextQueueAdd, &OriginalLegacyWatchNextQueueAdd);
    WolFoxInstallInstanceHook(
        @"MDXRequestDeviceDiscoveryCommandHandlerImpl",
        @"executeWithCommand:entry:fromView:sender:",
        (IMP)WolFoxQueueDiscoveryExecute, &OriginalDiscoveryExecute);
    WolFoxInstallInstanceHook(
        @"YTDefaultQueueWatchNextResponseParser",
        @"playlistPanelRendererFromWatchNextResponse:",
        (IMP)WolFoxQueuePanelParse, &OriginalPanelParse);
    if (!WolFoxInstallInstanceHook(@"YTPlaylistPanelSectionController",
        @"setVideoCountText:videoCountHidden:shuffleEnabled:shuffleSelected:"
        @"loopEnabled:loopSelected:saveEnabled:shareEnabled:saveSelected:"
        @"actionEnabled:loopMode:playlistPanelRenderer:useRendererSaveIcons:"
        @"headerHidden:",
        (IMP)WolFoxQueueSetVideoCountText, &OriginalSetVideoCountText)) {
        WolFoxInstallInstanceHook(@"YTPlaylistPanelSectionController",
            @"setVideoCountText:videoCountHidden:shuffleEnabled:shuffleSelected:"
            @"loopEnabled:loopSelected:saveEnabled:shareEnabled:saveSelected:"
            @"actionEnabled:loopMode:playlistPanelRenderer:useRendererSaveIcons:",
            (IMP)WolFoxQueueLegacySetVideoCountText, &OriginalLegacySetVideoCountText);
    }
    WolFoxInstallInstanceHook(@"YTPlaylistPanelController",
        @"didTapShuffleButton", (IMP)WolFoxQueueDidTapShuffle,
        &OriginalDidTapShuffle);
    WolFoxInstallInstanceHook(@"YTAutoplayAutonavController", @"hasNextVideo",
        (IMP)WolFoxQueueAutonavHasNext, &OriginalAutonavHasNext);
    WolFoxInstallInstanceHook(@"YTAutoplayAutonavController",
        @"hasPreviousVideo", (IMP)WolFoxQueueAutonavHasPrevious,
        &OriginalAutonavHasPrevious);
    WolFoxInstallInstanceHook(@"YTQueueController", @"nextNavigableVideoIndex",
        (IMP)WolFoxQueueNextNavigable, &OriginalNextNavigable);
    WolFoxInstallInstanceHook(@"YTQueueController",
        @"previousNavigableVideoIndex", (IMP)WolFoxQueuePreviousNavigable,
        &OriginalPreviousNavigable);
    WolFoxInstallInstanceHook(@"YTQueueController", @"hasNextVideo",
        (IMP)WolFoxQueueControllerHasNext, &OriginalQueueHasNext);
    WolFoxInstallInstanceHook(@"YTQueueController", @"hasPreviousVideo",
        (IMP)WolFoxQueueControllerHasPrevious, &OriginalQueueHasPrevious);
    WolFoxInstallInstanceHook(@"YTPlaylistPanelController",
        @"didTapActionButton:", (IMP)WolFoxQueueDidTapAction,
        &OriginalDidTapAction);
    WolFoxInstallInstanceHook(@"YTPlaylistPanelController", @"didTapLoopButton",
        (IMP)WolFoxQueueDidTapLoop, &OriginalDidTapLoop);
    WolFoxInstallInstanceHook(
        @"YTPlaylistPanelProminentThumbnailVideoCellController", @"setCell:",
        (IMP)WolFoxQueueCellControllerSetCell, &OriginalCellControllerSetCell);
    WolFoxInstallInstanceHook(@"YTSlideForActionsView", @"layoutSubviews",
        (IMP)WolFoxQueueSlideLayoutSubviews, &OriginalSlideLayoutSubviews);
    WolFoxInstallInstanceHook(@"YTPlaylistPanelSectionController",
        @"updateCell:forIndex:", (IMP)WolFoxQueueUpdateCellForIndex,
        &OriginalUpdateCellForIndex);
    WolFoxInstallInstanceHook(@"YTPlaylistPanelSectionController",
        @"alphaForIndex:", (IMP)WolFoxQueueAlphaForIndex,
        &OriginalAlphaForIndex);
    WolFoxInstallInstanceHook(@"YTPlaylistPanelProminentThumbnailVideoCell",
        @"prepareForReuse", (IMP)WolFoxQueueCellPrepareForReuse,
        &OriginalCellPrepareForReuse);
    WolFoxInstallInstanceHook(@"YTPlaylistPanelProminentThumbnailVideoCell",
        @"setCanReorder:", (IMP)WolFoxQueueSetCanReorder,
        &OriginalSetCanReorder);
    WolFoxInstallInstanceHook(@"YTPlaylistPanelProminentThumbnailVideoCell",
        @"allowsReorderingAtPoint:", (IMP)WolFoxQueueAllowsReordering,
        &OriginalAllowsReordering);
    WolFoxInstallInstanceHook(@"YTPlaylistPanelController", @"nextVideoTitle",
        (IMP)WolFoxQueueNextVideoTitle, &OriginalNextVideoTitle);
    WolFoxInstallInstanceHook(@"YTPlaylistPanelController", @"nextVideoIndex",
        (IMP)WolFoxQueueNextVideoIndex, &OriginalNextVideoIndex);
    WolFoxInstallInstanceHook(@"YTQueueAutoplayController",
        @"replaceAutoplayItemsWithWatchNextResponse:",
        (IMP)WolFoxQueueReplaceAutoplay, &OriginalReplaceAutoplay);
    WolFoxInstallInstanceHook(@"YTQueueController",
        @"canMoveItemAtIndexPath:toIndexPath:", (IMP)WolFoxQueueCanMoveItem,
        &OriginalCanMoveItem);
    WolFoxInstallInstanceHook(@"YTPlaylistPanelController", @"byline",
        (IMP)WolFoxQueuePanelByline, &OriginalPanelByline);
    WolFoxInstallInstanceHook(@"YTPlaylistPanelController", @"isQueue",
        (IMP)WolFoxQueueIsQueue, &OriginalIsQueue);
    if (!WolFoxInstallInstanceHook(@"YTPlaylistPanelController",
        @"hasQueueContents", (IMP)WolFoxQueueHasContents,
        &OriginalHasQueueContents)) {
        WolFoxInstallInstanceHook(@"YTPlaylistPanelController",
            @"shouldShowPlaylist", (IMP)WolFoxQueueShouldShowPlaylist,
            &OriginalShouldShowPlaylist);
    }
    WolFoxInstallInstanceHook(@"YTQueueController",
        @"moveItemAtIndexPath:toIndexPath:userTriggered:",
        (IMP)WolFoxQueueMoveItem, &OriginalMoveItem);
    WolFoxInstallInstanceHook(@"YTQueueController",
        @"removeItemAtIndexPath:userTriggered:",
        (IMP)WolFoxQueueRemoveItem, &OriginalRemoveItem);
    WolFoxInstallInstanceHook(@"YTQueueController", @"removeQueueItemAtIndex:",
        (IMP)WolFoxQueueRemoveIndex, &OriginalRemoveIndex);
    WolFoxInstallInstanceHook(@"YTQueueController", @"clearQueue",
        (IMP)WolFoxQueueClearQueue, &OriginalClearQueue);
    WolFoxInstallInstanceHook(@"YTMainAppVideoPlayerOverlayViewController",
        @"didPressNext:", (IMP)WolFoxQueueDidPressNext, &OriginalDidPressNext);
    WolFoxInstallInstanceHook(@"YTMainAppVideoPlayerOverlayViewController",
        @"didPressPrevious:", (IMP)WolFoxQueueDidPressPrevious,
        &OriginalDidPressPrevious);
    WolFoxInstallInstanceHook(@"YTAutoplayAutonavController", @"playNext",
        (IMP)WolFoxQueueAutonavPlayNext, &OriginalAutonavPlayNext);
    WolFoxInstallInstanceHook(
        @"YTWatchViewController", @"updateWithWatchNextResponse:",
        (IMP)WolFoxQueueViewUpdateWatchNext, &OriginalViewUpdateWatchNext);
    WolFoxInstallInstanceHook(
        @"YTPlaylistPanelController", @"initWithAccountID:parentResponder:",
        (IMP)WolFoxQueuePanelInit, &OriginalPanelInit);
    WolFoxInstallInstanceHook(
        @"YTPlaylistPanelController",
        @"initWithAccountID:parentResponder:queueController:",
        (IMP)WolFoxQueuePanelInitQueue, &OriginalPanelInitQueue);
    WolFoxInstallInstanceHook(
        @"YTQueueController", @"initWithAccountID:parentResponder:",
        (IMP)WolFoxQueueControllerInit, &OriginalQueueControllerInit);
    WolFoxInstallInstanceHook(
        @"YTWatchController", @"prepareWithWatchNextResponse:",
        (IMP)WolFoxQueuePrepareWatchNext, &OriginalPrepareWatchNext);
    WolFoxInstallInstanceHook(
        @"YTPlayerViewController", @"setWatchNextResponse:",
        (IMP)WolFoxQueueSetWatchNext, &OriginalSetWatchNext);
    WolFoxInstallInstanceHook(
        @"YTIWatchNextResponse", @"yt_playlistPanelRenderer",
        (IMP)WolFoxQueueResponsePanel, &OriginalResponsePanel);
    WolFoxInstallInstanceHook(@"YTCommandRouter",
        @"handleCommand:entry:fromView:sender:",
        (IMP)WolFoxQueueRouterHandle, &OriginalRouterHandle);
    WolFoxInstallInstanceHook(@"YTCommandRouter",
        @"handleCommand:entry:fromView:sender:completionBlock:",
        (IMP)WolFoxQueueRouterHandleCompletion, &OriginalRouterHandleCompletion);
    WolFoxInstallInstanceHook(@"YTAccountScopedCommandRouter",
        @"handleCommand:entry:fromView:sender:",
        (IMP)WolFoxQueueScopedRouterHandle, &OriginalScopedRouterHandle);
    WolFoxInstallInstanceHook(@"YTAccountScopedCommandRouter",
        @"handleCommand:entry:fromView:sender:completionBlock:",
        (IMP)WolFoxQueueScopedRouterHandleCompletion,
        &OriginalScopedRouterHandleCompletion);
    WolFoxQueueInstallFoundHooks(@{
        @"didDismissMiniBar":
            [NSValue valueWithPointer:(void *)WolFoxQueueDidDismissMiniBar],
    });
    [NSNotificationCenter.defaultCenter
        addObserverForName:@"WolFoxPlaybackTimeDidChange"
                    object:nil
                     queue:NSOperationQueue.mainQueue
                usingBlock:^(NSNotification *notification) {
        WolFoxQueueHandlePlaybackTime(notification);
    }];
}

// The Premium page that opens after a queue tap: swap the line under the
// headline for a pointer to Local Queue. That line is the only long 20pt
// regular text without numbers (the price line under it has them).
NSAttributedString *WolFoxQueuePremiumText(NSAttributedString *value) {
    if (WolFoxQueueMenuTapTime == 0 || CFAbsoluteTimeGetCurrent() - WolFoxQueueMenuTapTime > 8.0) return nil;
    if (![value isKindOfClass:NSAttributedString.class] || value.length < 20) return nil;
    NSString *text = value.string;
    UIFont *font = [value attribute:NSFontAttributeName atIndex:0 effectiveRange:NULL];
    const BOOL bold = [font isKindOfClass:UIFont.class] &&
        (font.fontDescriptor.symbolicTraits & UIFontDescriptorTraitBold);
    const BOOL digits = [text rangeOfCharacterFromSet:NSCharacterSet.decimalDigitCharacterSet].location != NSNotFound;
    const BOOL lines = [text containsString:@"\n"];
    const CGFloat size = [font isKindOfClass:UIFont.class] ? font.pointSize : 0.0;
    if (bold || digits || lines || size < 15.0 || size > 24.0) return nil;
    WolFoxQueueMenuTapTime = 0;
    WolFoxDebugLog(@"queue", @"premium line replaced size=%.1f '%@'", size, [text substringToIndex:MIN((NSUInteger)40, text.length)]);
    NSDictionary *attributes = [value attributesAtIndex:0 effectiveRange:NULL];
    return [[NSAttributedString alloc] initWithString:
        WolFoxLocalized(@"To queue videos without Premium, turn on Local Queue in WolFox settings.")
                                           attributes:attributes];
}

// Remember queue taps from video menus while Local Queue is off.
void WolFoxQueueWrapMenuActions(id renderers, id actions) {
    if (WolFoxFeatureEnabled(WolFoxQueueKey)) return;
    if (![renderers isKindOfClass:NSArray.class] || ![actions isKindOfClass:NSArray.class]) return;
    NSMutableSet<NSData *> *tracking = [NSMutableSet set];
    for (id wrapper in (NSArray *)renderers) {
        id item = WolFoxQueueConditionalItem(wrapper);
        NSString *dump = [item description];
        if (![dump containsString:@"QUEUE_PLAY_NEXT"] && ![dump containsString:@"QUEUE_PLAY_LAST"] &&
            ![dump containsString:@"ADD_TO_REMOTE_QUEUE"]) continue;
        id params = nil;
        @try { params = [item valueForKey:@"trackingParams"]; } @catch (__unused NSException *e) {}
        if ([params isKindOfClass:NSData.class] && [params length]) [tracking addObject:params];
    }
    WolFoxDebugLog(@"queue", @"menu queue items=%lu", (unsigned long)tracking.count);
    if (tracking.count == 0) return;
    SEL getHandler = NSSelectorFromString(@"handler");
    SEL setHandler = NSSelectorFromString(@"setHandler:");
    for (id action in (NSArray *)actions) {
        id params = nil;
        @try { params = [action valueForKey:@"trackingParams"]; } @catch (__unused NSException *e) {}
        if (![params isKindOfClass:NSData.class] || ![tracking containsObject:params]) continue;
        if (![action respondsToSelector:getHandler] || ![action respondsToSelector:setHandler]) continue;
        dispatch_block_t original = ((id (*)(id, SEL))objc_msgSend)(action, getHandler);
        dispatch_block_t wrapped = ^{
            WolFoxQueueMenuTapTime = CFAbsoluteTimeGetCurrent();
            WolFoxDebugLog(@"queue", @"queue tap without Local Queue");
            if (original) original();
        };
        ((void (*)(id, SEL, id))objc_msgSend)(action, setHandler, wrapped);
    }
}
