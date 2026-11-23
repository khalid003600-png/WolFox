#import "SponsorPreferences.h"
#import "../Downloads/DownloadLog.h"
#import "../Interface/AiSList.h"
#import "../../WolFox.h"
#import "../../Runtime/Localization.h"
#import "../../Runtime/Preferences.h"
#import "../../UI/Notice.h"
#import "../../UI/OverlayButtonHost.h"

#import <UIKit/UIKit.h>
#import <objc/message.h>

extern id WolFoxSponsorActiveController(void);
extern NSString *WolFoxSponsorActiveVideoID(void);
extern NSArray *WolFoxSponsorActiveSegments(void);
extern double WolFoxSponsorActiveTime(void);
extern double WolFoxSponsorActiveDuration(void);
extern void WolFoxSponsorSeekActive(double time);
extern NSString *WolFoxSponsorActiveHandle(void);
extern void WolFoxSponsorSetActiveHandle(NSString *handle);

static NSString * const WolFoxSponsorButtonKey = @"YTKACE.Preference.SponsorBlock.OverlayButton";
static NSString * const WolFoxSponsorWhitelistKey = @"YTKACE.Preference.SponsorBlock.Whitelist";
static NSString * const WolFoxSponsorUserIDKey = @"WolFox.SponsorBlock.UserID";

static NSString *WolFoxSponsorUserID(void) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSString *stored = [defaults stringForKey:WolFoxSponsorUserIDKey];
    if (stored.length >= 30) return stored;
    NSString *generated = [[NSString stringWithFormat:@"%@%@", NSUUID.UUID.UUIDString, NSUUID.UUID.UUIDString]
        stringByReplacingOccurrencesOfString:@"-" withString:@""];
    [defaults setObject:generated forKey:WolFoxSponsorUserIDKey];
    return generated;
}

static NSString *WolFoxSponsorTimeText(double seconds) {
    NSInteger total = (NSInteger)floor(MAX(seconds, 0.0));
    NSInteger hours = total / 3600;
    NSInteger minutes = (total / 60) % 60;
    NSInteger secs = total % 60;
    if (hours > 0) return [NSString stringWithFormat:@"%ld:%02ld:%02ld", (long)hours, (long)minutes, (long)secs];
    return [NSString stringWithFormat:@"%ld:%02ld", (long)minutes, (long)secs];
}

static NSString *WolFoxSponsorTitleForCategory(NSString *category) {
    for (NSDictionary *definition in WolFoxSponsorCategoryDefinitions()) {
        if ([definition[@"id"] isEqualToString:category]) return definition[@"title"];
    }
    return category;
}

static UIImage *WolFoxSponsorIcon(NSString *symbol) {
    UIImageSymbolConfiguration *configuration =
        [UIImageSymbolConfiguration configurationWithPointSize:19.0 weight:UIImageSymbolWeightRegular];
    UIImage *glyph = [UIImage systemImageNamed:symbol withConfiguration:configuration];
    if (glyph == nil) return [UIImage new];
    CGSize canvas = CGSizeMake(24.0, 24.0);
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    UIImage *image = [[[UIGraphicsImageRenderer alloc] initWithSize:canvas format:format]
        imageWithActions:^(__unused UIGraphicsImageRendererContext *context) {
        CGSize size = glyph.size;
        [glyph drawInRect:CGRectMake((canvas.width - size.width) / 2.0, (canvas.height - size.height) / 2.0,
                                     size.width, size.height)];
    }];
    return [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

static NSDictionary *WolFoxSponsorAction(NSString *title, NSString *symbol, BOOL checked, dispatch_block_t handler) {
    return @{@"title": title, @"icon": WolFoxSponsorIcon(symbol), @"check": @(checked), @"handler": [handler copy]};
}

static NSDictionary *WolFoxSponsorValueAction(NSString *title, NSString *value, NSString *symbol,
                                              dispatch_block_t handler) {
    return @{@"title": title, @"value": value ?: @"", @"icon": WolFoxSponsorIcon(symbol), @"handler": [handler copy]};
}

static NSDictionary *WolFoxSponsorSubtitledAction(NSString *title, NSString *subtitle, NSString *symbol,
                                                  dispatch_block_t handler) {
    return @{@"title": title, @"subtitle": subtitle ?: @"", @"icon": WolFoxSponsorIcon(symbol),
             @"handler": [handler copy]};
}

static void WolFoxSponsorLater(dispatch_block_t block) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), block);
}

static void WolFoxSponsorPost(NSString *path, NSDictionary *body, NSString *what,
                              void (^completion)(NSInteger status)) {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:
        [NSURL URLWithString:[@"https://sponsor.ajay.app" stringByAppendingString:path]]];
    request.HTTPMethod = @"POST";
    request.timeoutInterval = 20.0;
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    request.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    [[NSURLSession.sharedSession dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class]
            ? ((NSHTTPURLResponse *)response).statusCode : 0;
        NSString *text = data.length != 0 ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
        WolFoxDownloadLog(@"sponsor", @"%@ status=%ld", what, (long)status);
        WolFoxDebugLog(@"sponsor", @"%@ response=%@ error=%@", what,
                       text.length > 300 ? [text substringToIndex:300] : (text ?: @"-"),
                       error.localizedDescription ?: @"-");
        dispatch_async(dispatch_get_main_queue(), ^{ completion(status); });
    }] resume];
}

static void WolFoxSponsorVote(NSDictionary *segment, BOOL up) {
    NSString *uuid = segment[@"uuid"];
    if (uuid.length == 0) {
        WolFoxShowNotice(WolFoxLocalized(@"This segment can't be voted on"));
        return;
    }
    WolFoxSponsorPost(@"/api/voteOnSponsorTime",
                      @{@"UUID": uuid, @"userID": WolFoxSponsorUserID(), @"type": @(up ? 1 : 0)},
                      up ? @"upvote" : @"downvote", ^(NSInteger status) {
        if (status == 200) WolFoxShowNotice(WolFoxLocalized(@"Vote sent"));
        else if (status == 429) WolFoxShowNotice(WolFoxLocalized(@"Too many votes. Try again later."));
        else WolFoxShowNotice(WolFoxLocalized(@"Could not send vote"));
    });
}

static void WolFoxSponsorShowSegment(NSDictionary *segment, UIView *source) {
    double start = [segment[@"start"] doubleValue];
    double end = [segment[@"end"] doubleValue];
    NSString *title = [NSString stringWithFormat:@"%@ · %@ – %@", WolFoxSponsorTitleForCategory(segment[@"category"]),
                       WolFoxSponsorTimeText(start), WolFoxSponsorTimeText(end)];
    WolFoxPresentNativeSheet(title, nil, source, @[
        WolFoxSponsorAction(WolFoxLocalized(@"Upvote"), @"hand.thumbsup", NO, ^{ WolFoxSponsorVote(segment, YES); }),
        WolFoxSponsorAction(WolFoxLocalized(@"Downvote"), @"hand.thumbsdown", NO, ^{ WolFoxSponsorVote(segment, NO); }),
        WolFoxSponsorAction(WolFoxLocalized(@"Jump to Start"), @"arrow.uturn.backward", NO, ^{
            WolFoxSponsorSeekActive(start);
        })
    ]);
}

static void WolFoxSponsorShowSegments(UIView *source) {
    NSArray *segments = WolFoxSponsorActiveSegments();
    if (segments.count == 0) {
        WolFoxShowNotice(WolFoxLocalized(@"No segments for this video"));
        return;
    }
    NSMutableArray *actions = [NSMutableArray array];
    for (NSDictionary *segment in segments) {
        NSString *subtitle = [NSString stringWithFormat:@"%@ – %@", WolFoxSponsorTimeText([segment[@"start"] doubleValue]),
                              WolFoxSponsorTimeText([segment[@"end"] doubleValue])];
        [actions addObject:WolFoxSponsorSubtitledAction(WolFoxSponsorTitleForCategory(segment[@"category"]), subtitle,
                                                        @"shield", ^{
            WolFoxSponsorLater(^{ WolFoxSponsorShowSegment(segment, source); });
        })];
    }
    WolFoxPresentNativeSheet(WolFoxLocalized(@"Available segments"), nil, source, actions);
}

static double WolFoxSponsorMarkStart = -1.0;
static double WolFoxSponsorMarkEnd = -1.0;
static NSString *WolFoxSponsorMarkVideo;
static void WolFoxSponsorResetMarks(void);

static void WolFoxSponsorSubmit(NSString *category) {
    NSString *videoID = WolFoxSponsorActiveVideoID();
    double start = WolFoxSponsorMarkStart;
    double end = WolFoxSponsorMarkEnd;
    if (videoID.length == 0 || start < 0.0 || end <= start) {
        WolFoxShowNotice(WolFoxLocalized(@"Mark a start and end first"));
        return;
    }
    NSDictionary *body = @{
        @"videoID": videoID,
        @"userID": WolFoxSponsorUserID(),
        @"userAgent": [NSString stringWithFormat:@"WolFox/%@", WolFoxVersion],
        @"videoDuration": @(WolFoxSponsorActiveDuration()),
        @"segments": @[@{@"segment": @[@(start), @(end)], @"category": category, @"actionType": @"skip"}]
    };
    WolFoxSponsorPost(@"/api/skipSegments", body, @"submit", ^(NSInteger status) {
        if (status == 200) {
            WolFoxSponsorResetMarks();
            WolFoxShowNotice(WolFoxLocalized(@"Segment submitted"));
        } else if (status == 409) {
            WolFoxShowNotice(WolFoxLocalized(@"This segment was already submitted"));
        } else if (status == 429) {
            WolFoxShowNotice(WolFoxLocalized(@"Too many submissions. Try again later."));
        } else if (status == 400 || status == 403) {
            WolFoxShowNotice(WolFoxLocalized(@"SponsorBlock rejected this segment"));
        } else {
            WolFoxShowNotice(WolFoxLocalized(@"Could not reach SponsorBlock"));
        }
    });
}

static void WolFoxSponsorPickCategory(UIView *source) {
    NSMutableArray *actions = [NSMutableArray array];
    for (NSDictionary *definition in WolFoxSponsorCategoryDefinitions()) {
        NSString *category = definition[@"id"];
        if ([category isEqualToString:@"poi_highlight"]) continue;
        [actions addObject:WolFoxSponsorAction(definition[@"title"], @"tag", NO, ^{ WolFoxSponsorSubmit(category); })];
    }
    NSString *subtitle = [NSString stringWithFormat:@"%@ – %@", WolFoxSponsorTimeText(WolFoxSponsorMarkStart),
                          WolFoxSponsorTimeText(WolFoxSponsorMarkEnd)];
    WolFoxPresentNativeSheet(WolFoxLocalized(@"Choose a category"), subtitle, source, actions);
}

static __weak UIButton *WolFoxSponsorButton;

static void WolFoxSponsorRefreshButton(void) {
    UIButton *button = WolFoxSponsorButton;
    BOOL marking = WolFoxSponsorMarkStart >= 0.0 && [WolFoxSponsorMarkVideo isEqualToString:WolFoxSponsorActiveVideoID()];
    button.tintColor = marking ? UIColor.systemRedColor : UIColor.whiteColor;
}

static void WolFoxSponsorResetMarks(void) {
    WolFoxSponsorMarkStart = -1.0;
    WolFoxSponsorMarkEnd = -1.0;
    WolFoxSponsorRefreshButton();
}

static void WolFoxSponsorToggleWhitelist(NSString *handle) {
    NSString *key = handle.lowercaseString;
    NSMutableArray *list = [[NSUserDefaults.standardUserDefaults arrayForKey:WolFoxSponsorWhitelistKey] mutableCopy]
        ?: [NSMutableArray array];
    BOOL listed = [list containsObject:key];
    if (listed) [list removeObject:key];
    else [list addObject:key];
    [NSUserDefaults.standardUserDefaults setObject:list forKey:WolFoxSponsorWhitelistKey];
    WolFoxSponsorSetActiveHandle(handle);
    WolFoxShowNotice(listed ? WolFoxLocalized(@"Channel removed from whitelist")
                            : WolFoxLocalized(@"SponsorBlock won't skip on this channel"));
}

static void WolFoxSponsorPresentMenu(UIView *source, NSString *handle, NSString *channel, NSString *title) {
    NSString *videoID = WolFoxSponsorActiveVideoID();
    if (![WolFoxSponsorMarkVideo isEqualToString:videoID]) {
        WolFoxSponsorMarkVideo = videoID;
        WolFoxSponsorResetMarks();
    }
    NSArray *whitelist = [NSUserDefaults.standardUserDefaults arrayForKey:WolFoxSponsorWhitelistKey];
    BOOL listed = handle.length != 0 && [whitelist containsObject:handle.lowercaseString];
    double now = WolFoxSponsorActiveTime();
    NSMutableArray *actions = [NSMutableArray array];
    if (handle.length != 0) {
        [actions addObject:WolFoxSponsorAction(listed ? WolFoxLocalized(@"Remove from whitelist")
                                                      : WolFoxLocalized(@"Whitelist this channel"),
                                               listed ? @"star.fill" : @"star", NO, ^{
            WolFoxSponsorToggleWhitelist(handle);
        })];
    }
    NSUInteger count = WolFoxSponsorActiveSegments().count;
    [actions addObject:WolFoxSponsorValueAction(WolFoxLocalized(@"Available segments"),
                                                [NSString stringWithFormat:@"%lu", (unsigned long)count], @"list.bullet", ^{
        WolFoxSponsorLater(^{ WolFoxSponsorShowSegments(source); });
    })];
    if (WolFoxSponsorMarkStart < 0.0) {
        [actions addObject:WolFoxSponsorValueAction(WolFoxLocalized(@"Start a segment here"), WolFoxSponsorTimeText(now),
                                                    @"arrow.right.to.line", ^{
            WolFoxSponsorMarkStart = WolFoxSponsorActiveTime();
            WolFoxSponsorMarkEnd = -1.0;
            WolFoxSponsorRefreshButton();
            WolFoxShowNotice(WolFoxLocalized(@"Start marked. Tap the shield again where it ends."));
        })];
    } else {
        double start = WolFoxSponsorMarkStart;
        [actions addObject:WolFoxSponsorValueAction(WolFoxLocalized(@"End the segment here"),
            [NSString stringWithFormat:@"%@ – %@", WolFoxSponsorTimeText(start), WolFoxSponsorTimeText(now)],
            @"arrow.left.to.line", ^{
            double end = WolFoxSponsorActiveTime();
            if (end <= WolFoxSponsorMarkStart + 0.5) {
                WolFoxShowNotice(WolFoxLocalized(@"The end has to be after the start"));
                return;
            }
            WolFoxSponsorMarkEnd = end;
            WolFoxSponsorLater(^{ WolFoxSponsorPickCategory(source); });
        })];
        [actions addObject:WolFoxSponsorAction(WolFoxLocalized(@"Cancel the segment"), @"xmark", NO, ^{
            WolFoxSponsorResetMarks();
        })];
    }
    WolFoxPresentNativeSheet(channel.length != 0 ? channel : @"SponsorBlock", title.length != 0 ? title : handle,
                             source, actions);
}

@interface WolFoxSponsorMenuTarget : NSObject
+ (instancetype)shared;
- (void)open:(UIButton *)sender;
@end

@implementation WolFoxSponsorMenuTarget
+ (instancetype)shared {
    static WolFoxSponsorMenuTarget *target;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ target = [WolFoxSponsorMenuTarget new]; });
    return target;
}

- (void)open:(UIButton *)sender {
    NSString *videoID = WolFoxSponsorActiveVideoID();
    NSString *handle = WolFoxSponsorActiveHandle();
    (void)handle;
    if (videoID.length == 0) {
        WolFoxSponsorPresentMenu(sender, nil, nil, nil);
        return;
    }
    __weak UIButton *weakSender = sender;
    WolFoxLookupChannelHandle(videoID, ^(NSString *found, NSString *channel, NSString *title) {
        if (found.length != 0) WolFoxSponsorSetActiveHandle(found);
        WolFoxSponsorPresentMenu(weakSender, found, channel, title);
    });
}
@end

void WolFoxInstallSponsorMenu(void) {
    WolFoxRegisterOverlayConfigurator(@"sponsorblock", ^(__unused UIView *overlay, UIStackView *stack) {
        UIButton *button = WolFoxOverlayButton(stack, @"WolFox SponsorBlock", @"shield",
                                               WolFoxSponsorMenuTarget.shared, @selector(open:));
        UIImageSymbolConfiguration *configuration =
            [UIImageSymbolConfiguration configurationWithPointSize:20.0 weight:UIImageSymbolWeightMedium];
        [button setImage:[[UIImage systemImageNamed:@"shield.lefthalf.filled" withConfiguration:configuration]
            imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate] forState:UIControlStateNormal];
        button.hidden = !WolFoxFeatureEnabled(WolFoxSponsorButtonKey);
        WolFoxSponsorButton = button;
        WolFoxSponsorRefreshButton();
    });
}
