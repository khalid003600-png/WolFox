#import "../../WolFox.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Localization.h"
#import "../../Runtime/Preferences.h"
#import "../../UI/Notice.h"
#import "DownloadCoordinator.h"
#import "DownloadLog.h"
#import "SABRDownloader.h"

#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

static NSString *const WolFoxPlaylistDownloadKey =
    @"YTKACE.Preference.Downloads.PlaylistEnabled";
static NSInteger const WolFoxPlaylistButtonTag = 0x59544B50;

static IMP OriginalPlaylistContents;
static IMP OriginalPlaylistHeaderModel;

static NSMutableDictionary<NSString *, NSMutableArray<NSDictionary *> *> *WolFoxPlaylistItems;
static NSMutableDictionary<NSString *, NSMutableSet<NSString *> *> *WolFoxPlaylistSeen;
static NSString *WolFoxCurrentPlaylistID;
static __weak UIViewController *WolFoxPlaylistBrowseController;
static NSString *WolFoxCurrentPlaylistTitle;

static NSArray<NSDictionary *> *WolFoxCurrentPlaylistItems(void);

static BOOL WolFoxPlaylistDownloadEnabled(void) {
    return WolFoxDownloadsEnabled() &&
        WolFoxFeatureEnabled(WolFoxPlaylistDownloadKey);
}

static id WolFoxPlaylistValue(id object, NSString *name) {
    if (object == nil) return nil;
    SEL selector = NSSelectorFromString(name);
    if (![object respondsToSelector:selector]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(object, selector);
}

static NSString *WolFoxPlaylistText(id value) {
    if ([value isKindOfClass:NSString.class]) return value;
    for (NSString *name in @[@"text", @"simpleText", @"string"]) {
        id nested = WolFoxPlaylistValue(value, name);
        if ([nested isKindOfClass:NSString.class]) return nested;
    }
    return nil;
}

static id WolFoxPlaylistVideoRenderer(id entry) {
    id direct = WolFoxPlaylistValue(entry, @"playlistVideoRenderer");
    if (direct != nil) return direct;
    if (WolFoxPlaylistValue(entry, @"videoId") != nil) return entry;
    for (NSString *name in @[@"playlistPanelVideoRenderer", @"videoRenderer",
                             @"compactVideoRenderer", @"gridVideoRenderer"]) {
        id nested = WolFoxPlaylistValue(entry, name);
        if (nested != nil) return nested;
    }
    return nil;
}

static void WolFoxRecordPlaylistItem(NSString *playlistID, id renderer) {
    NSString *videoID = WolFoxPlaylistText(WolFoxPlaylistValue(renderer, @"videoId"));
    if (videoID.length == 0) return;
    NSMutableSet<NSString *> *seen = WolFoxPlaylistSeen[playlistID];
    if (seen == nil) {
        seen = [NSMutableSet set];
        WolFoxPlaylistSeen[playlistID] = seen;
        WolFoxPlaylistItems[playlistID] = [NSMutableArray array];
    }
    if ([seen containsObject:videoID]) return;
    [seen addObject:videoID];
    NSString *title = WolFoxPlaylistText(WolFoxPlaylistValue(renderer, @"title"));
    NSString *author = WolFoxPlaylistText(
        WolFoxPlaylistValue(renderer, @"shortBylineText")) ?:
        WolFoxPlaylistText(WolFoxPlaylistValue(renderer, @"longBylineText"));
    [WolFoxPlaylistItems[playlistID] addObject:@{
        @"videoId": videoID,
        @"title": title ?: videoID,
        @"author": author ?: @""
    }];
}

static NSArray *WolFoxPlaylistContents(id receiver, SEL selector) {
    NSArray *items = OriginalPlaylistContents == NULL ? nil :
        ((id (*)(id, SEL))OriginalPlaylistContents)(receiver, selector);
    if (![items isKindOfClass:NSArray.class] || items.count == 0) return items;
    NSString *playlistID = WolFoxPlaylistText(
        WolFoxPlaylistValue(receiver, @"playlistId"));
    if (playlistID.length == 0) playlistID = WolFoxCurrentPlaylistID;
    if (playlistID.length == 0) return items;
    NSUInteger before = WolFoxPlaylistItems[playlistID].count;
    for (id entry in items) {
        id renderer = WolFoxPlaylistVideoRenderer(entry);
        if (renderer != nil) WolFoxRecordPlaylistItem(playlistID, renderer);
    }
    NSUInteger after = WolFoxPlaylistItems[playlistID].count;
    if (after != before) {
        WolFoxCurrentPlaylistID = playlistID;
    }
    return items;
}

static void WolFoxPlaylistHeaderModel(id receiver, SEL selector, id model) {
    if (OriginalPlaylistHeaderModel != NULL) {
        ((void (*)(id, SEL, id))OriginalPlaylistHeaderModel)(receiver, selector, model);
    }
    id renderer = WolFoxPlaylistValue(model, @"playlistHeaderRenderer") ?: model;
    NSString *playlistID = WolFoxPlaylistText(
        WolFoxPlaylistValue(renderer, @"playlistId"));
    if (playlistID.length == 0) return;
    WolFoxCurrentPlaylistID = playlistID;
    WolFoxCurrentPlaylistTitle =
        WolFoxPlaylistText(WolFoxPlaylistValue(renderer, @"title")) ?: @"";
}

static NSMutableDictionary<NSString *, UIImage *> *WolFoxPlaylistThumbnails;

static UIImage *WolFoxPlaylistPlaceholderImage(void) {
    static UIImage *placeholder;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        CGSize size = CGSizeMake(80.0, 45.0);
        UIGraphicsBeginImageContextWithOptions(size, NO, 0.0);
        [[UIColor colorWithWhite:0.25 alpha:1.0] setFill];
        UIRectFill(CGRectMake(0.0, 0.0, size.width, size.height));
        placeholder = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
    });
    return placeholder;
}

@interface WolFoxPlaylistPickerController : UITableViewController
@property(nonatomic, copy) NSArray<NSDictionary *> *items;
@property(nonatomic, strong) NSMutableSet<NSString *> *selection;
@property(nonatomic, copy) void (^onDone)(NSSet<NSString *> *selection);
@end

@implementation WolFoxPlaylistPickerController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = WolFoxLocalized(@"Select videos");
    self.tableView.allowsMultipleSelection = YES;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithTitle:WolFoxLocalized(@"Done")
                style:UIBarButtonItemStyleDone
               target:self
               action:@selector(finish)];
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc]
        initWithTitle:WolFoxLocalized(@"Select all")
                style:UIBarButtonItemStylePlain
               target:self
               action:@selector(toggleAll)];
}

- (void)finish {
    if (self.onDone != nil) self.onDone(self.selection);
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)toggleAll {
    if (self.selection.count == self.items.count) {
        [self.selection removeAllObjects];
    } else {
        for (NSDictionary *item in self.items) {
            [self.selection addObject:item[@"videoId"]];
        }
    }
    [self.tableView reloadData];
}

- (NSInteger)tableView:(UITableView *)tableView
 numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)self.items.count;
}

- (CGFloat)tableView:(UITableView *)tableView
heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    return 64.0;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"ytkace"];
    if (cell == nil) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                      reuseIdentifier:@"ytkace"];
    }
    NSDictionary *item = self.items[(NSUInteger)indexPath.row];
    cell.textLabel.text = item[@"title"];
    cell.textLabel.numberOfLines = 2;
    cell.detailTextLabel.text = item[@"author"];
    cell.accessoryType = [self.selection containsObject:item[@"videoId"]]
        ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    cell.imageView.image = WolFoxPlaylistPlaceholderImage();
    NSString *thumbnail = item[@"thumbnail"];
    NSString *videoID = item[@"videoId"];
    if (thumbnail.length != 0) {
        UIImage *cached = WolFoxPlaylistThumbnails[videoID];
        if (cached != nil) {
            cell.imageView.image = cached;
        } else {
            __weak UITableView *weakTable = tableView;
            dispatch_async(dispatch_get_global_queue(
                DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
                NSData *data = [NSData dataWithContentsOfURL:
                    [NSURL URLWithString:thumbnail]];
                UIImage *image = data != nil ? [UIImage imageWithData:data] : nil;
                if (image == nil) return;
                dispatch_async(dispatch_get_main_queue(), ^{
                    WolFoxPlaylistThumbnails[videoID] = image;
                    [weakTable reloadRowsAtIndexPaths:@[indexPath]
                                     withRowAnimation:UITableViewRowAnimationNone];
                });
            });
        }
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView
didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    NSDictionary *item = self.items[(NSUInteger)indexPath.row];
    NSString *videoID = item[@"videoId"];
    if ([self.selection containsObject:videoID]) {
        [self.selection removeObject:videoID];
    } else {
        [self.selection addObject:videoID];
    }
    [tableView deselectRowAtIndexPath:indexPath animated:NO];
    [tableView reloadRowsAtIndexPaths:@[indexPath]
                     withRowAnimation:UITableViewRowAnimationNone];
}

@end

static UIViewController *WolFoxPlaylistTopController(void) {
    UIWindow *window = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *candidate in ((UIWindowScene *)scene).windows) {
            if (candidate.isKeyWindow) window = candidate;
        }
    }
    UIViewController *controller = window.rootViewController;
    while (controller.presentedViewController != nil) {
        controller = controller.presentedViewController;
    }
    return controller;
}

static UIViewController *WolFoxOwningController(UIView *view) {
    UIResponder *responder = view;
    for (NSUInteger depth = 0; responder != nil && depth < 24; depth++) {
        if ([responder isKindOfClass:UIViewController.class]) {
            return (UIViewController *)responder;
        }
        responder = responder.nextResponder;
    }
    return nil;
}

static UIView *WolFoxSheetAnchorForView(UIView *source) {
    if (source == nil || source.window == nil) return source;
    UIViewController *owner = WolFoxOwningController(source);
    UIViewController *browse = WolFoxPlaylistBrowseController;
    UIView *host = browse.viewIfLoaded ?: owner.viewIfLoaded;
    if (host == nil || host.window == nil) {
        host = WolFoxPlaylistTopController().viewIfLoaded;
    }
    if (host == nil) return source;
    if ([source isDescendantOfView:host]) return source;
    static UIView *anchor;
    if (anchor == nil) {
        anchor = [[UIView alloc] initWithFrame:CGRectZero];
        anchor.userInteractionEnabled = NO;
        anchor.backgroundColor = UIColor.clearColor;
        anchor.accessibilityIdentifier = @"WolFox Sheet Anchor";
    }
    if (anchor.superview != host) {
        [anchor removeFromSuperview];
        [host addSubview:anchor];
    }
    anchor.frame = [source convertRect:source.bounds toView:host];
    [host sendSubviewToBack:anchor];
    return anchor;
}

static void WolFoxWaitForIdleDownloads(NSUInteger attempt,
                                       dispatch_block_t next) {
    NSUInteger active = [WolFoxDownloadCoordinator.sharedCoordinator activeJobCount];
    if (active == 0 || attempt > 1200) {
        if (attempt > 1200) {
            WolFoxDownloadLog(@"playlist", @"idle wait timed out active=%lu",
                (unsigned long)active);
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
            (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), next);
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
        (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            WolFoxWaitForIdleDownloads(attempt + 1, next);
        });
}

static void WolFoxRunPlaylistQueue(NSArray<NSDictionary *> *queue,
                                   NSUInteger index,
                                   NSInteger quality,
                                   BOOL audioOnly,
                                   BOOL savesToPhotos,
                                   BOOL sharesFile,
                                   NSUInteger started,
                                   NSUInteger failed) {
    if (index >= queue.count) {
        WolFoxDownloadLog(@"playlist", @"queue finished started=%lu failed=%lu",
            (unsigned long)started, (unsigned long)failed);
        NSString *message = failed == 0
            ? [NSString stringWithFormat:
                WolFoxLocalized(@"Downloaded %lu videos"), (unsigned long)started]
            : [NSString stringWithFormat:
                WolFoxLocalized(@"Downloaded %lu videos, %lu unavailable"),
                (unsigned long)started, (unsigned long)failed];
        if (started == 0 && failed != 0) {
            WolFoxDiscardRestoredRequest();
            message = WolFoxLocalized(
                @"Play any video once to refresh downloads, then try again.");
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            WolFoxShowNotice(message);
            [WolFoxDownloadCoordinator.sharedCoordinator
                flushBatchSharingFromView:nil];
        });
        return;
    }
    NSDictionary *item = queue[index];
    NSString *videoID = item[@"videoId"];
    WolFoxResolvePlayerResponse(videoID, ^(id playerResponse, NSError *error) {
        BOOL queued = NO;
        if (playerResponse != nil) {
            queued = [WolFoxDownloadCoordinator.sharedCoordinator
                enqueueDownloadForResponse:playerResponse
                                   quality:quality
                                 audioOnly:audioOnly
                             savesToPhotos:savesToPhotos
                                sharesFile:sharesFile];
        }
        WolFoxDownloadLog(@"playlist", @"item %lu/%lu video=%@ queued=%d error=%@",
            (unsigned long)(index + 1), (unsigned long)queue.count, videoID,
            queued, error.localizedDescription ?: @"none");
        WolFoxWaitForIdleDownloads(0, ^{
            WolFoxRunPlaylistQueue(queue, index + 1, quality, audioOnly,
                savesToPhotos, sharesFile, started + (queued ? 1 : 0),
                failed + (queued ? 0 : 1));
        });
    });
}

static void WolFoxStartPlaylistDownload(NSArray<NSDictionary *> *items,
                                        NSSet<NSString *> *selection,
                                        NSInteger quality,
                                        BOOL audioOnly,
                                        UIView *source) {
    NSMutableArray<NSDictionary *> *queue = [NSMutableArray array];
    for (NSDictionary *item in items) {
        if (selection == nil || [selection containsObject:item[@"videoId"]]) {
            [queue addObject:item];
        }
    }
    if (queue.count == 0) {
        WolFoxShowNotice(WolFoxLocalized(@"No videos selected"));
        return;
    }
    if (!WolFoxPlaybackTemplateReady()) {
        WolFoxShowNotice(WolFoxLocalized(
            @"Play any video once so WolFox can prepare downloads, then try again."));
        return;
    }
    WolFoxDownloadLog(@"playlist", @"start count=%lu quality=%ld audioOnly=%d",
        (unsigned long)queue.count, (long)quality, audioOnly);
    [WolFoxDownloadCoordinator.sharedCoordinator
        resolvePlaylistDestinationFromView:source
                                 audioOnly:audioOnly
                                      then:^(BOOL savesToPhotos,
                                             BOOL sharesFile) {
            WolFoxShowNotice([NSString stringWithFormat:
                WolFoxLocalized(@"Preparing %lu videos"),
                (unsigned long)queue.count]);
            if (sharesFile) {
                [WolFoxDownloadCoordinator.sharedCoordinator beginBatchSharing];
            }
            WolFoxWaitForIdleDownloads(0, ^{
                WolFoxRunPlaylistQueue(queue, 0, quality, audioOnly,
                                       savesToPhotos, sharesFile, 0, 0);
            });
        }];
}

static void WolFoxPresentCustomQualityMenu(UIView *source,
                                           NSArray<NSDictionary *> *items,
                                           NSSet<NSString *> *selection) {
    WolFoxDownloadCoordinator *coordinator =
        WolFoxDownloadCoordinator.sharedCoordinator;
    NSArray<NSArray *> *heights = @[
        @[WolFoxLocalized(@"Up to 1080p"), @1080],
        @[WolFoxLocalized(@"Up to 720p"), @720],
        @[WolFoxLocalized(@"Up to 480p"), @480],
        @[WolFoxLocalized(@"Up to 360p"), @360]
    ];
    NSMutableArray *actions = [NSMutableArray array];
    for (NSArray *choice in heights) {
        NSInteger cap = [choice[1] integerValue];
        [actions addObject:[coordinator nativeSheetAction:choice[0]
            icon:@"play" handler:^{
                WolFoxStartPlaylistDownload(items, selection, cap, NO, source);
            }]];
    }
    [coordinator presentPlaylistSheetWithTitle:WolFoxLocalized(@"Maximum quality")
                                      subtitle:nil
                                    sourceView:WolFoxSheetAnchorForView(source)
                                       actions:actions];
}

static void WolFoxPresentQualityMenu(UIView *source,
                                     NSArray<NSDictionary *> *items,
                                     NSSet<NSString *> *selection) {
    WolFoxDownloadCoordinator *coordinator =
        WolFoxDownloadCoordinator.sharedCoordinator;
    NSMutableArray *actions = [NSMutableArray array];
    [actions addObject:[coordinator nativeSheetAction:
        WolFoxLocalized(@"Best available") icon:@"play" handler:^{
            WolFoxStartPlaylistDownload(items, selection, 0, NO, source);
        }]];
    [actions addObject:[coordinator nativeSheetAction:
        WolFoxLocalized(@"Custom quality") icon:@"chevron.right" handler:^{
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                (int64_t)(0.12 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    WolFoxPresentCustomQualityMenu(source, items, selection);
                });
        }]];
    [actions addObject:[coordinator nativeSheetAction:
        WolFoxLocalized(@"Audio only") icon:@"music.note" handler:^{
            WolFoxStartPlaylistDownload(items, selection, 0, YES, source);
        }]];
    [coordinator presentPlaylistSheetWithTitle:WolFoxLocalized(@"Download quality")
                                      subtitle:nil
                                    sourceView:WolFoxSheetAnchorForView(source)
                                       actions:actions];
}

static NSString *WolFoxPlaylistRunsText(NSDictionary *text) {
    if (![text isKindOfClass:NSDictionary.class]) return nil;
    if ([text[@"simpleText"] isKindOfClass:NSString.class]) return text[@"simpleText"];
    NSMutableString *out = [NSMutableString string];
    for (NSDictionary *run in text[@"runs"]) {
        if ([run isKindOfClass:NSDictionary.class] && [run[@"text"] isKindOfClass:NSString.class]) [out appendString:run[@"text"]];
    }
    return out.length != 0 ? out : nil;
}

static void WolFoxAddPlaylistToken(NSMutableArray<NSString *> *tokens, id token, BOOL inList) {
    if (![token isKindOfClass:NSString.class] || [token length] == 0 || [tokens containsObject:token]) return;
    if (inList) [tokens insertObject:token atIndex:0];
    else [tokens addObject:token];
}

static void WolFoxCollectPlaylistJSON(id node, NSMutableArray<NSDictionary *> *items, NSMutableSet<NSString *> *seen,
                                      NSMutableArray<NSString *> *tokens, BOOL inList, NSUInteger depth) {
    if (depth > 40) return;
    if ([node isKindOfClass:NSArray.class]) {
        for (id child in node) WolFoxCollectPlaylistJSON(child, items, seen, tokens, inList, depth + 1);
        return;
    }
    if (![node isKindOfClass:NSDictionary.class]) return;
    if (node[@"compactVideoModel"] != nil) return;
    NSDictionary *context = node[@"videoWithContextModel"];
    if ([context isKindOfClass:NSDictionary.class]) {
        id url = nil;
        id title = nil;
        id author = nil;
        @try {
            NSDictionary *videoData = context[@"videoWithContextData"][@"videoData"];
            url = videoData[@"dragAndDropUrl"];
            NSDictionary *meta = videoData[@"lockupMetadata"][@"lockupMetadataViewModel"];
            title = meta[@"title"][@"content"];
            author = meta[@"metadata"][@"contentMetadataViewModel"][@"metadataRows"][0][@"metadataParts"][0][@"text"][@"content"];
        } @catch (__unused NSException *exception) {
        }
        NSString *videoID = nil;
        for (NSURLQueryItem *item in [url isKindOfClass:NSString.class] ? [NSURLComponents componentsWithString:url].queryItems : @[]) {
            if ([item.name isEqualToString:@"v"]) videoID = item.value;
        }
        if (videoID.length == 11 && ![seen containsObject:videoID]) {
            [seen addObject:videoID];
            [items addObject:@{
                @"videoId": videoID,
                @"title": [title isKindOfClass:NSString.class] ? title : videoID,
                @"author": [author isKindOfClass:NSString.class] ? author : @"",
                @"thumbnail": [NSString stringWithFormat:@"https://i.ytimg.com/vi/%@/hqdefault.jpg", videoID]
            }];
        }
        return;
    }
    NSDictionary *nextData = node[@"nextContinuationData"];
    if ([nextData isKindOfClass:NSDictionary.class]) {
        WolFoxAddPlaylistToken(tokens, nextData[@"continuation"], inList);
        return;
    }
    NSDictionary *lockup = node[@"lockupViewModel"];
    if ([lockup isKindOfClass:NSDictionary.class]) {
        NSString *videoID = lockup[@"contentId"];
        if ([lockup[@"contentType"] isEqual:@"LOCKUP_CONTENT_TYPE_VIDEO"] && [videoID isKindOfClass:NSString.class] &&
            ![seen containsObject:videoID]) {
            NSDictionary *meta = lockup[@"metadata"][@"lockupMetadataViewModel"];
            id title = nil;
            id author = nil;
            @try {
                title = meta[@"title"][@"content"];
                author = meta[@"metadata"][@"contentMetadataViewModel"][@"metadataRows"][0][@"metadataParts"][0][@"text"][@"content"];
            } @catch (__unused NSException *exception) {
            }
            [seen addObject:videoID];
            [items addObject:@{
                @"videoId": videoID,
                @"title": [title isKindOfClass:NSString.class] ? title : videoID,
                @"author": [author isKindOfClass:NSString.class] ? author : @"",
                @"thumbnail": [NSString stringWithFormat:@"https://i.ytimg.com/vi/%@/hqdefault.jpg", videoID]
            }];
        }
        return;
    }
    NSDictionary *nextPage = node[@"continuationItemViewModel"];
    if ([nextPage isKindOfClass:NSDictionary.class]) {
        id token = nil;
        @try {
            token = nextPage[@"continuationCommand"][@"innertubeCommand"][@"continuationCommand"][@"token"];
        } @catch (__unused NSException *exception) {
        }
        WolFoxAddPlaylistToken(tokens, token, inList);
        return;
    }
    NSDictionary *video = node[@"playlistVideoRenderer"];
    if ([video isKindOfClass:NSDictionary.class]) {
        NSString *videoID = video[@"videoId"];
        if ([videoID isKindOfClass:NSString.class] && ![seen containsObject:videoID]) {
            [seen addObject:videoID];
            [items addObject:@{
                @"videoId": videoID,
                @"title": WolFoxPlaylistRunsText(video[@"title"]) ?: videoID,
                @"author": WolFoxPlaylistRunsText(video[@"shortBylineText"]) ?: @"",
                @"thumbnail": [NSString stringWithFormat:@"https://i.ytimg.com/vi/%@/hqdefault.jpg", videoID]
            }];
        }
        return;
    }
    NSDictionary *more = node[@"continuationItemRenderer"];
    if ([more isKindOfClass:NSDictionary.class]) {
        WolFoxAddPlaylistToken(tokens, more[@"continuationEndpoint"][@"continuationCommand"][@"token"], inList);
        return;
    }
    static NSSet<NSString *> *listKeys;
    if (listKeys == nil) listKeys = [NSSet setWithArray:@[@"itemSectionRenderer", @"itemSectionContinuation",
        @"playlistVideoListRenderer", @"playlistVideoListContinuation"]];
    for (NSString *key in (NSDictionary *)node) {
        BOOL childInList = inList || ([key isKindOfClass:NSString.class] && [listKeys containsObject:key]);
        WolFoxCollectPlaylistJSON(((NSDictionary *)node)[key], items, seen, tokens, childInList, depth + 1);
    }
}

extern id WolFoxLatestPlayerAuthorization;
extern NSString *WolFoxPlayerOnBehalfOfUser(void);
static id WolFoxRequestAuthorization;
static IMP OriginalAuthorizeCompletion;
static IMP OriginalAuthorizeCallback;

static void WolFoxNoteAuthorization(id receiver, id request) {
    if (![request isKindOfClass:NSURLRequest.class]) return;
    NSString *host = ((NSURLRequest *)request).URL.host;
    if ([host containsString:@"youtube"]) WolFoxRequestAuthorization = receiver;
}

static void WolFoxAuthorizeCompletion(id receiver, SEL selector, id request, id handler) {
    WolFoxNoteAuthorization(receiver, request);
    ((void (*)(id, SEL, id, id))OriginalAuthorizeCompletion)(receiver, selector, request, handler);
}

static void WolFoxAuthorizeCallback(id receiver, SEL selector, id request, id callback) {
    WolFoxNoteAuthorization(receiver, request);
    ((void (*)(id, SEL, id, id))OriginalAuthorizeCallback)(receiver, selector, request, callback);
}

static NSString *WolFoxPlaylistAuthHeader(void) {
    id auth = WolFoxLatestPlayerAuthorization ?: WolFoxRequestAuthorization;
    if (auth == nil) return nil;
    for (NSString *selectorName in @[@"accessToken", @"token", @"authToken", @"oauthToken"]) {
        SEL selector = NSSelectorFromString(selectorName);
        if (![auth respondsToSelector:selector]) continue;
        id value = ((id (*)(id, SEL))objc_msgSend)(auth, selector);
        if ([value isKindOfClass:NSString.class] && [value length] != 0)
            return [@"Bearer " stringByAppendingString:value];
    }
    SEL authorize = NSSelectorFromString(@"authorizeRequest:completionHandler:");
    if ([auth respondsToSelector:authorize]) {
        NSMutableURLRequest *probe = [NSMutableURLRequest requestWithURL:
            [NSURL URLWithString:@"https://youtubei.googleapis.com/youtubei/v1/browse"]];
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        ((void (*)(id, SEL, NSMutableURLRequest *, void (^)(NSError *)))objc_msgSend)(auth, authorize, probe,
            ^(__unused NSError *error) { dispatch_semaphore_signal(done); });
        dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10 * NSEC_PER_SEC)));
        NSString *header = [probe valueForHTTPHeaderField:@"Authorization"];
        if (header.length != 0) return header;
    }
    return nil;
}

static NSArray<NSDictionary *> *WolFoxFetchPlaylistPages(NSString *playlistID, NSString *authHeader, NSUInteger *pagesOut) {
    NSMutableArray<NSDictionary *> *items = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    NSString *continuation = nil;
    NSMutableArray<NSString *> *fallbacks = [NSMutableArray array];
    NSMutableSet<NSString *> *tried = [NSMutableSet set];
    NSUInteger empty = 0;
    NSString *visitor = nil;
    NSString *pageID = authHeader.length != 0 ? WolFoxPlayerOnBehalfOfUser() : nil;
    NSString *version = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"21.40.5";
    NSString *agent = [NSString stringWithFormat:
        @"com.google.ios.youtube/%@ (iPhone16,2; U; CPU iOS 18_6 like Mac OS X; en_US)", version];
    NSURLSessionConfiguration *config = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    config.HTTPCookieStorage = nil;
    config.HTTPShouldSetCookies = NO;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:config];
    NSUInteger page = 0;
    for (; page < 200; page++) {
        NSMutableDictionary *client = [@{@"clientName": @"IOS", @"clientVersion": version, @"deviceMake": @"Apple",
            @"deviceModel": @"iPhone16,2", @"osName": @"iPhone", @"osVersion": @"18.6", @"hl": @"en", @"gl": @"US"} mutableCopy];
        if (visitor.length != 0) client[@"visitorData"] = visitor;
        NSMutableDictionary *context = [@{@"client": client} mutableCopy];
        if (authHeader.length != 0 && pageID.length != 0) context[@"user"] = @{@"onBehalfOfUser": pageID};
        NSMutableDictionary *body = [@{@"context": context} mutableCopy];
        if (page == 0) body[@"browseId"] = [playlistID hasPrefix:@"VL"] ? playlistID : [@"VL" stringByAppendingString:playlistID];
        else body[@"continuation"] = continuation;
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:
            [NSURL URLWithString:@"https://youtubei.googleapis.com/youtubei/v1/browse?prettyPrint=false"]];
        request.HTTPMethod = @"POST";
        request.timeoutInterval = 20.0;
        [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
        [request setValue:agent forHTTPHeaderField:@"User-Agent"];
        [request setValue:@"5" forHTTPHeaderField:@"X-Youtube-Client-Name"];
        [request setValue:version forHTTPHeaderField:@"X-Youtube-Client-Version"];
        if (visitor.length != 0) [request setValue:visitor forHTTPHeaderField:@"X-Goog-Visitor-Id"];
        if (authHeader.length != 0) [request setValue:authHeader forHTTPHeaderField:@"Authorization"];
        if (authHeader.length != 0 && pageID.length != 0) [request setValue:pageID forHTTPHeaderField:@"X-Goog-PageId"];
        request.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        __block NSData *data = nil;
        __block NSInteger status = 0;
        [[session dataTaskWithRequest:request
            completionHandler:^(NSData *result, NSURLResponse *response, __unused NSError *error) {
            data = result;
            if ([response isKindOfClass:NSHTTPURLResponse.class]) status = ((NSHTTPURLResponse *)response).statusCode;
            dispatch_semaphore_signal(done);
        }] resume];
        dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(25 * NSEC_PER_SEC)));
        id json = data != nil ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        if (![json isKindOfClass:NSDictionary.class] || status >= 400) {
            WolFoxDownloadLog(@"playlist", @"page %lu failed status=%ld bytes=%lu auth=%d", (unsigned long)page,
                              (long)status, (unsigned long)data.length, authHeader.length != 0);
            break;
        }
        id newVisitor = json[@"responseContext"][@"visitorData"];
        if ([newVisitor isKindOfClass:NSString.class] && [newVisitor length] != 0) visitor = newVisitor;
        NSUInteger before = items.count;
        NSMutableArray<NSString *> *tokens = [NSMutableArray array];
        WolFoxCollectPlaylistJSON(json, items, seen, tokens, NO, 0);
        BOOL added = items.count != before;
        if (added) [fallbacks removeAllObjects];
        for (NSString *token in tokens.reverseObjectEnumerator) {
            if (![tried containsObject:token]) [fallbacks insertObject:token atIndex:0];
        }
        continuation = fallbacks.firstObject;
        if (continuation != nil) [fallbacks removeObjectAtIndex:0];
        NSString *alert = nil;
        id alerts = json[@"alerts"];
        if ([alerts isKindOfClass:NSArray.class] && [alerts count] != 0 && [[alerts firstObject] isKindOfClass:NSDictionary.class]) {
            NSDictionary *first = [alerts firstObject];
            NSDictionary *renderer = first[@"alertRenderer"] ?: first[@"alertWithButtonRenderer"];
            if ([renderer isKindOfClass:NSDictionary.class])
                alert = WolFoxPlaylistRunsText(renderer[@"text"]) ?: WolFoxPlaylistRunsText(renderer[@"title"]);
        }
        WolFoxDebugLog(@"playlist", @"page %lu auth=%d status=%ld bytes=%lu added=%lu tokens=%lu alert=%@",
                          (unsigned long)page, authHeader.length != 0, (long)status, (unsigned long)data.length,
                          (unsigned long)(items.count - before), (unsigned long)tokens.count, alert ?: @"-");
        empty = added ? 0 : empty + 1;
        if (continuation.length == 0 || empty >= 2) {
            WolFoxDownloadLog(@"playlist", @"page %lu end items=%lu", (unsigned long)page, (unsigned long)items.count);
            page++;
            break;
        }
        [tried addObject:continuation];
    }
    [session finishTasksAndInvalidate];
    if (pagesOut != NULL) *pagesOut = page;
    return items;
}

static void WolFoxFetchFullPlaylist(NSString *playlistID, void (^completion)(NSArray<NSDictionary *> *items)) {
    if (playlistID.length == 0) {
        completion(nil);
        return;
    }
    BOOL personal = [playlistID isEqualToString:@"WL"] || [playlistID isEqualToString:@"LL"];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSUInteger pages = 0;
        NSArray<NSDictionary *> *items = personal ? @[] : WolFoxFetchPlaylistPages(playlistID, nil, &pages);
        if (items.count == 0) {
            NSString *header = WolFoxPlaylistAuthHeader();
            WolFoxDebugLog(@"playlist", @"auth personal=%d header=%d player=%d request=%d page=%d", personal,
                              header.length != 0, WolFoxLatestPlayerAuthorization != nil,
                              WolFoxRequestAuthorization != nil, WolFoxPlayerOnBehalfOfUser().length != 0);
            if (header.length != 0) items = WolFoxFetchPlaylistPages(playlistID, header, &pages);
            else WolFoxDownloadLog(@"playlist", @"no auth header player=%d request=%d",
                                   WolFoxLatestPlayerAuthorization != nil, WolFoxRequestAuthorization != nil);
        }
        WolFoxDownloadLog(@"playlist", @"fetched %lu items in %lu pages for %@", (unsigned long)items.count,
                          (unsigned long)pages, playlistID);
        dispatch_async(dispatch_get_main_queue(), ^{ completion(items.count != 0 ? items : nil); });
    });
}

static void WolFoxShowPlaylistMenu(UIView *source, NSArray<NSDictionary *> *items);

static void WolFoxPresentPlaylistMenu(UIView *source) {
    NSArray<NSDictionary *> *loaded = WolFoxCurrentPlaylistItems();
    WolFoxShowNotice(WolFoxLocalized(@"Loading playlist…"));
    __weak UIView *weakSource = source;
    WolFoxFetchFullPlaylist(WolFoxCurrentPlaylistID, ^(NSArray<NSDictionary *> *full) {
        WolFoxShowPlaylistMenu(weakSource, full.count >= loaded.count ? full : loaded);
    });
}

static void WolFoxShowVideoListMenu(UIView *source, NSArray<NSDictionary *> *items,
                                    NSString *title, NSString *name) {
    WolFoxDownloadCoordinator *coordinator =
        WolFoxDownloadCoordinator.sharedCoordinator;
    NSMutableArray *actions = [NSMutableArray array];
    [actions addObject:[coordinator nativeSheetAction:
        [NSString stringWithFormat:WolFoxLocalized(@"Download all of %@ (%lu)"),
            name, (unsigned long)items.count]
        icon:@"play" handler:^{
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                (int64_t)(0.12 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    WolFoxPresentQualityMenu(source, items, nil);
                });
        }]];
    [actions addObject:[coordinator nativeSheetAction:
        WolFoxLocalized(@"Select videos") icon:@"doc.on.doc" handler:^{
            WolFoxPlaylistPickerController *picker =
                [[WolFoxPlaylistPickerController alloc]
                    initWithStyle:UITableViewStylePlain];
            picker.items = items;
            picker.selection = [NSMutableSet set];
            for (NSDictionary *item in items) {
                [picker.selection addObject:item[@"videoId"]];
            }
            picker.onDone = ^(NSSet<NSString *> *selection) {
                if (selection.count == 0) {
                    WolFoxShowNotice(WolFoxLocalized(@"No videos selected"));
                    return;
                }
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                    (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                        WolFoxPresentQualityMenu(source, items, selection);
                    });
            };
            UINavigationController *navigation = [[UINavigationController alloc]
                initWithRootViewController:picker];
            [WolFoxPlaylistTopController() presentViewController:navigation
                                                        animated:YES
                                                      completion:nil];
        }]];
    [coordinator presentPlaylistSheetWithTitle:title
        subtitle:[NSString stringWithFormat:WolFoxLocalized(@"%lu videos"),
            (unsigned long)items.count]
        sourceView:WolFoxSheetAnchorForView(source)
        actions:actions];
}

static void WolFoxShowPlaylistMenu(UIView *source, NSArray<NSDictionary *> *items) {
    if (items.count == 0) {
        WolFoxShowNotice(WolFoxLocalized(
            @"Scroll the playlist once so WolFox can read it, then try again."));
        return;
    }
    const BOOL named = WolFoxCurrentPlaylistTitle.length != 0;
    WolFoxShowVideoListMenu(source, items,
        named ? WolFoxCurrentPlaylistTitle : WolFoxLocalized(@"Playlist"),
        named ? WolFoxCurrentPlaylistTitle : WolFoxLocalized(@"playlist"));
}

void WolFoxPresentVideoListDownloadMenu(NSArray<NSDictionary *> *items,
                                        NSString *title, UIView *source) {
    NSMutableArray<NSDictionary *> *list = [NSMutableArray array];
    for (NSDictionary *item in items) {
        NSString *videoID = item[@"videoId"];
        if (videoID.length == 0) continue;
        if ([item[@"thumbnail"] length] != 0) {
            [list addObject:item];
            continue;
        }
        NSMutableDictionary *copy = [item mutableCopy];
        copy[@"thumbnail"] = [NSString stringWithFormat:
            @"https://i.ytimg.com/vi/%@/mqdefault.jpg", videoID];
        [list addObject:copy];
    }
    if (list.count == 0) {
        WolFoxShowNotice(WolFoxLocalized(@"No videos selected"));
        return;
    }
    WolFoxShowVideoListMenu(source, list, title, title);
}

@interface WolFoxPlaylistButtonTarget : NSObject
+ (instancetype)shared;
- (void)tapped:(UIButton *)sender;
@end

@implementation WolFoxPlaylistButtonTarget

+ (instancetype)shared {
    static WolFoxPlaylistButtonTarget *shared;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ shared = [self new]; });
    return shared;
}

- (void)tapped:(UIButton *)sender {
    WolFoxPresentPlaylistMenu(sender);
}

@end

static NSData *WolFoxDecodeBlob(NSString *line) {
    NSRange marker = [line rangeOfString:@": \""];
    NSString *escaped = marker.location != NSNotFound
        ? [line substringFromIndex:NSMaxRange(marker)] : line;
    NSUInteger length = escaped.length;
    NSMutableData *bytes = [NSMutableData dataWithCapacity:length];
    NSUInteger index = 0;
    while (index < length) {
        unichar c = [escaped characterAtIndex:index];
        if (c != '\\' || index + 1 >= length) {
            if (c < 128) {
                unsigned char raw = (unsigned char)c;
                [bytes appendBytes:&raw length:1];
            } else {
                NSString *piece = [NSString stringWithCharacters:&c length:1];
                [bytes appendData:[piece dataUsingEncoding:NSUTF8StringEncoding]];
            }
            index++;
            continue;
        }
        unichar next = [escaped characterAtIndex:index + 1];
        unsigned char raw = 0;
        if (next == 'n') { raw = '\n'; index += 2; }
        else if (next == 't') { raw = '\t'; index += 2; }
        else if (next == 'r') { raw = '\r'; index += 2; }
        else if (next == '"') { raw = '"'; index += 2; }
        else if (next == '\\') { raw = '\\'; index += 2; }
        else if (next >= '0' && next <= '7') {
            NSUInteger digits = 0;
            int value = 0;
            while (digits < 3 && index + 1 + digits < length) {
                unichar digit = [escaped characterAtIndex:index + 1 + digits];
                if (digit < '0' || digit > '7') break;
                value = value * 8 + (digit - '0');
                digits++;
            }
            if (digits == 0) { raw = '\\'; index++; }
            else { raw = (unsigned char)(value & 0xFF); index += 1 + digits; }
        } else { raw = '\\'; index++; }
        [bytes appendBytes:&raw length:1];
    }
    return bytes;
}

static BOOL WolFoxLooksLikeJunk(NSString *run) {
    static NSArray<NSString *> *phrases;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        phrases = @[@"SharePlay", @"Save to", @"Remove from", @"queue",
                    @"Play on", @"Action menu", @"Learn more", @"http", @"|",
                    @"%3D", @" views", @" ago", @"Delete", @"Download",
                    @"ytimg", @"googlevideo", @".eml"];
    });
    for (NSString *phrase in phrases) {
        if ([run containsString:phrase]) return YES;
    }
    return NO;
}

static NSString *WolFoxTitleFromBlob(NSData *blob) {
    const unsigned char *bytes = (const unsigned char *)blob.bytes;
    NSUInteger length = blob.length;
    NSMutableDictionary<NSString *, NSNumber *> *counts =
        [NSMutableDictionary dictionary];
    for (NSUInteger index = 0; index + 1 < length; index++) {
        NSUInteger runLength = bytes[index];
        if (runLength < 6 || runLength > 120) continue;
        if (index + 1 + runLength > length) continue;
        NSString *run = [[NSString alloc]
            initWithBytes:bytes + index + 1
                   length:runLength
                 encoding:NSUTF8StringEncoding];
        if (run == nil) continue;
        if ([run rangeOfString:@" "].location == NSNotFound) continue;
        if ([run rangeOfString:@"_"].location != NSNotFound) continue;
        if (![run isEqualToString:[run stringByTrimmingCharactersInSet:
                NSCharacterSet.whitespaceAndNewlineCharacterSet]]) {
            continue;
        }
        BOOL control = NO;
        for (NSUInteger i = 0; i < run.length; i++) {
            if ([run characterAtIndex:i] < 32) { control = YES; break; }
        }
        if (control || WolFoxLooksLikeJunk(run)) continue;
        counts[run] = @(counts[run].integerValue + 1);
    }
    NSString *best = nil;
    for (NSString *run in counts) {
        if (counts[run].integerValue < 2) continue;
        if (run.length > best.length) best = run;
    }
    return best;
}

static NSArray<NSDictionary *> *WolFoxExtractPlaylistItems(id model) {
    if (model == nil) return @[];
    NSString *dump = nil;
    @try {
        dump = [model description];
    } @catch (__unused NSException *exception) {
        return @[];
    }
    if (dump.length == 0) return @[];
    static NSRegularExpression *expression;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        expression = [NSRegularExpression
            regularExpressionWithPattern:@"\\\\n\\\\013([A-Za-z0-9_-]{11})"
                                 options:0
                                   error:NULL];
    });
    NSMutableArray<NSDictionary *> *items = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (NSString *line in [dump componentsSeparatedByString:@"\n"]) {
        NSArray<NSTextCheckingResult *> *matches = [expression
            matchesInString:line options:0 range:NSMakeRange(0, line.length)];
        if (matches.count == 0) continue;
        NSString *videoID = nil;
        for (NSTextCheckingResult *candidate in matches) {
            NSString *identifier =
                [line substringWithRange:[candidate rangeAtIndex:1]];
            if ([line containsString:[NSString stringWithFormat:
                    @"i.ytimg.com/vi/%@", identifier]]) {
                videoID = identifier;
                break;
            }
        }
        if (videoID == nil || [seen containsObject:videoID]) continue;
        [seen addObject:videoID];
        NSString *title = WolFoxTitleFromBlob(WolFoxDecodeBlob(line));
        [items addObject:@{
            @"videoId": videoID,
            @"title": title.length != 0 ? title : videoID,
            @"thumbnail": [NSString stringWithFormat:
                @"https://i.ytimg.com/vi/%@/hqdefault.jpg", videoID]
        }];
    }
    static NSRegularExpression *titleExpression;
    static dispatch_once_t titleToken;
    dispatch_once(&titleToken, ^{
        titleExpression = [NSRegularExpression
            regularExpressionWithPattern:@"page_title:\\s*\"([^\"]{1,120})\""
                                 options:0
                                   error:NULL];
    });
    NSTextCheckingResult *titleMatch = [titleExpression
        firstMatchInString:dump options:0 range:NSMakeRange(0, dump.length)];
    if (titleMatch != nil) {
        WolFoxCurrentPlaylistTitle =
            [dump substringWithRange:[titleMatch rangeAtIndex:1]];
    }
    return items;
}

static NSArray<NSDictionary *> *WolFoxCurrentPlaylistItems(void) {
    NSString *playlistID = WolFoxCurrentPlaylistID;
    UIViewController *browse = WolFoxPlaylistBrowseController;
    NSArray<NSDictionary *> *found = nil;
    for (NSString *name in @[@"response", @"model", @"browseResponse"]) {
        id model = WolFoxPlaylistValue(browse, name);
        NSArray<NSDictionary *> *items = WolFoxExtractPlaylistItems(model);
        if (items.count != 0) { found = items; break; }
    }
    if (playlistID.length == 0) return found ?: @[];
    NSMutableArray<NSDictionary *> *cached = WolFoxPlaylistItems[playlistID];
    if (cached == nil) {
        cached = [NSMutableArray array];
        WolFoxPlaylistItems[playlistID] = cached;
        WolFoxPlaylistSeen[playlistID] = [NSMutableSet set];
    }
    NSMutableSet<NSString *> *seen = WolFoxPlaylistSeen[playlistID];
    for (NSDictionary *item in found) {
        NSString *videoID = item[@"videoId"];
        if ([seen containsObject:videoID]) continue;
        [seen addObject:videoID];
        [cached addObject:item];
    }
    return [cached copy];
}

static IMP OriginalBrowseAppear;

static void WolFoxRefreshHeaderBars(UIView *root);

static IMP OriginalBrowseDisappear;

static void WolFoxBrowseDisappear(UIViewController *receiver, SEL selector,
                                  BOOL animated) {
    if (OriginalBrowseDisappear != NULL) {
        ((void (*)(id, SEL, BOOL))OriginalBrowseDisappear)(receiver, selector,
                                                            animated);
    }
    if (WolFoxPlaylistBrowseController != nil &&
        WolFoxPlaylistBrowseController != receiver) {
        return;
    }
    WolFoxCurrentPlaylistID = nil;
    WolFoxPlaylistBrowseController = nil;
    WolFoxRefreshHeaderBars(receiver.view.window ?: receiver.view);
}

static void WolFoxBrowseAppear(UIViewController *receiver, SEL selector,
                               BOOL animated) {
    if (OriginalBrowseAppear != NULL) {
        ((void (*)(id, SEL, BOOL))OriginalBrowseAppear)(receiver, selector,
                                                        animated);
    }
    id value = WolFoxPlaylistValue(receiver, @"browseIdentifier");
    NSString *browseID = [value isKindOfClass:NSString.class] ? value : nil;
    if (browseID.length == 0) return;
    if ([browseID hasPrefix:@"VL"]) {
        WolFoxCurrentPlaylistID = [browseID substringFromIndex:2];
        WolFoxPlaylistBrowseController = receiver;
    } else {
        WolFoxCurrentPlaylistID = nil;
        WolFoxPlaylistBrowseController = nil;
    }
    WolFoxRefreshHeaderBars(receiver.view.window ?: receiver.view);
}

static IMP OriginalSetRightBarButtonItems;

static UIBarButtonItem *WolFoxPlaylistBarItem(void) {
    static UIBarButtonItem *item;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
        button.tag = WolFoxPlaylistButtonTag;
        button.accessibilityIdentifier = @"WolFox Playlist Download";
        button.accessibilityLabel = WolFoxLocalized(@"Download playlist");
        button.tintColor = UIColor.whiteColor;
        button.frame = CGRectMake(0.0, 0.0, 32.0, 32.0);
        [button setImage:WolFoxDownloadGlyphImage() forState:UIControlStateNormal];
        [button addTarget:WolFoxPlaylistButtonTarget.shared
                   action:@selector(tapped:)
         forControlEvents:UIControlEventTouchUpInside];
        item = [[UIBarButtonItem alloc] initWithCustomView:button];
    });
    return item;
}

static void WolFoxSetRightBarButtonItems(UIView *receiver, SEL selector,
                                         NSArray *items) {
    NSArray *result = items;
    if (WolFoxPlaylistDownloadEnabled() && WolFoxCurrentPlaylistID.length != 0) {
        UIBarButtonItem *ours = WolFoxPlaylistBarItem();
        if (![items containsObject:ours]) {
            NSMutableArray *merged = items != nil
                ? [items mutableCopy] : [NSMutableArray array];
            [merged insertObject:ours atIndex:0];
            result = merged;
        }
    }
    if (OriginalSetRightBarButtonItems != NULL) {
        ((void (*)(id, SEL, id))OriginalSetRightBarButtonItems)(
            receiver, selector, result);
    }
}

static void WolFoxRefreshHeaderBars(UIView *root) {
    if (root == nil) return;
    if ([NSStringFromClass(root.class) isEqualToString:@"YTHeaderView"]) {
        SEL getter = NSSelectorFromString(@"rightBarButtonItems");
        SEL setter = NSSelectorFromString(@"setRightBarButtonItems:");
        if ([root respondsToSelector:getter] &&
            [root respondsToSelector:setter]) {
            id current = ((id (*)(id, SEL))objc_msgSend)(root, getter);
            ((void (*)(id, SEL, id))objc_msgSend)(root, setter, current);
        }
        return;
    }
    for (UIView *child in root.subviews) {
        WolFoxRefreshHeaderBars(child);
    }
}

void WolFoxInstallPlaylistDownloaderHooks(void) {
    if (WolFoxPlaylistItems == nil) {
        WolFoxPlaylistItems = [NSMutableDictionary dictionary];
        WolFoxPlaylistSeen = [NSMutableDictionary dictionary];
        WolFoxPlaylistThumbnails = [NSMutableDictionary dictionary];
    }
    BOOL contents = WolFoxInstallInstanceHook(@"YTIPlaylistVideoListRenderer",
                                              @"contentsArray",
                                              (IMP)WolFoxPlaylistContents,
                                              &OriginalPlaylistContents);
    BOOL header = WolFoxInstallInstanceHook(@"YTPageHeaderViewController",
                                            @"loadWithModel:",
                                            (IMP)WolFoxPlaylistHeaderModel,
                                            &OriginalPlaylistHeaderModel);
    BOOL layout = WolFoxInstallInstanceHook(@"YTHeaderView",
                                            @"setRightBarButtonItems:",
                                            (IMP)WolFoxSetRightBarButtonItems,
                                            &OriginalSetRightBarButtonItems);
    WolFoxDownloadLog(@"playlist",
        @"hooks contents=%d header=%d layout=%d", contents, header, layout);
    WolFoxInstallInstanceHook(@"SSOAuthorizationImpl", @"authorizeRequest:completionHandler:",
                              (IMP)WolFoxAuthorizeCompletion, &OriginalAuthorizeCompletion);
    WolFoxInstallInstanceHook(@"SSOAuthorizationImpl", @"authorizeRequest:callback:",
                              (IMP)WolFoxAuthorizeCallback, &OriginalAuthorizeCallback);
    WolFoxInstallInstanceHook(@"YTBrowseViewController", @"viewDidAppear:",
                              (IMP)WolFoxBrowseAppear, &OriginalBrowseAppear);
    WolFoxInstallInstanceHook(@"YTBrowseViewController", @"viewWillDisappear:",
                              (IMP)WolFoxBrowseDisappear,
                              &OriginalBrowseDisappear);
}
