#import "../../WolFox.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"
#import "../../Runtime/Localization.h"
#import "../Downloads/DownloadLog.h"

#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <CommonCrypto/CommonDigest.h>

// Shows the dislike count from the Return YouTube Dislike API next to the
// watch page dislike button.

static NSString *const WolFoxReturnDislikeKey = @"YTKACE.Preference.ActionBar.ReturnDislike";
static const void *WolFoxDislikeNumberAssociation = &WolFoxDislikeNumberAssociation;
static const void *WolFoxDislikeVideoAssociation = &WolFoxDislikeVideoAssociation;
static const void *WolFoxDislikeCountAssociation = &WolFoxDislikeCountAssociation;
static const void *WolFoxDislikeStyleAssociation = &WolFoxDislikeStyleAssociation;
static IMP OriginalRollingUpdate;
static IMP OriginalRollingPrepare;
static IMP OriginalRollingSize;
static IMP OriginalRollingLayout;
static const CGFloat WolFoxDislikeGap = 4.0;
static NSCache<NSString *, NSNumber *> *WolFoxDislikeCounts;
static NSMutableDictionary<NSString *, NSHashTable<UIView *> *> *WolFoxDislikeWaiting;

static id WolFoxDislikeGet(id object, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    if (object == nil || ![object respondsToSelector:selector]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(object, selector);
}

static id WolFoxDislikeIvar(id object, const char *name) {
    for (Class cls = [object class]; cls != Nil; cls = class_getSuperclass(cls)) {
        Ivar ivar = class_getInstanceVariable(cls, name);
        if (ivar != NULL) return object_getIvar(object, ivar);
    }
    return nil;
}

// ICU's short compact format ("1.5K", "1,5 mil", "1.5万"), so the count matches
// the language of YouTube's own like count next to it.
extern "C" {
void *unum_open(int style, const uint16_t *pattern, int32_t patternLength,
                const char *locale, void *parseError, int *status);
int32_t unum_formatDouble(const void *format, double number, uint16_t *result,
                          int32_t resultLength, void *position, int *status);
}

static NSString *WolFoxCompactNumber(double value) {
    static void *format;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *language = NSBundle.mainBundle.preferredLocalizations.firstObject ?: @"en";
        NSString *locale = [NSLocale canonicalLocaleIdentifierFromString:language];
        int status = 0;
        void *opened = unum_open(14 /* UNUM_DECIMAL_COMPACT_SHORT */, NULL, 0,
                                 locale.UTF8String, NULL, &status);
        if (status <= 0) format = opened;
    });
    if (format == NULL) return nil;
    uint16_t buffer[64];
    int status = 0;
    int32_t length = unum_formatDouble(format, value, buffer, 64, NULL, &status);
    if (status > 0 || length <= 0 || length > 64) return nil;
    return [NSString stringWithCharacters:buffer length:(NSUInteger)length];
}

static NSString *WolFoxDislikeText(long long count) {
    if (count < 1000) return [NSString stringWithFormat:@"%lld", count];
    // Round down like YouTube (1,565 shows as 1.5K), then let ICU write it.
    double scale = 1000.0;
    while ((double)count / scale >= 1000.0 && scale < 1e9) scale *= 1000.0;
    const double amount = (double)count / scale;
    const double rounded = amount < 10.0 ? floor(amount * 10.0) / 10.0 : floor(amount);
    NSString *compact = WolFoxCompactNumber(rounded * scale);
    if (compact.length != 0) return compact;
    NSArray<NSString *> *units = @[@"K", @"M", @"B"];
    double value = (double)count;
    NSUInteger unit = 0;
    value /= 1000.0;
    while (value >= 1000.0 && unit + 1 < units.count) {
        value /= 1000.0;
        unit++;
    }
    NSString *number = value < 10.0
        ? [NSString stringWithFormat:@"%.1f", floor(value * 10.0) / 10.0]
        : [NSString stringWithFormat:@"%.0f", floor(value)];
    if ([number hasSuffix:@".0"]) number = [number substringToIndex:number.length - 2];
    return [number stringByAppendingString:units[unit]];
}

static NSString *WolFoxDislikeVideoID(UIView *view) {
    for (UIResponder *responder = view; responder != nil; responder = responder.nextResponder) {
        id player = [NSStringFromClass(responder.class) isEqualToString:@"YTPlayerViewController"]
            ? responder : WolFoxDislikeGet(responder, @"playerViewController");
        id video = WolFoxDislikeGet(player, @"currentVideoID");
        if ([video isKindOfClass:NSString.class] && [video length] != 0) return video;
        if ([NSStringFromClass(responder.class) isEqualToString:@"YTReelContainerViewController"]) {
            id model = WolFoxDislikeGet(responder, @"model");
            for (NSString *name in @[@"videoId", @"videoID", @"onesieVideoID", @"contentVideoID"]) {
                id value = WolFoxDislikeGet(model, name);
                if ([value isKindOfClass:NSString.class] && [value length] == 11) return value;
            }
        }
    }
    return nil;
}

static id WolFoxDislikeLikeNumber(UIView *dislikeView) {
    for (UIView *sibling in dislikeView.superview.subviews) {
        if (![sibling.accessibilityIdentifier isEqualToString:@"id.video.like.button"]) continue;
        id likeNode = WolFoxDislikeGet(sibling, @"keepalive_node");
        for (id child in WolFoxDislikeGet(likeNode, @"yogaChildren")) {
            if ([NSStringFromClass([child class]) isEqualToString:@"YTRollingNumberNode"]) return child;
        }
    }
    return nil;
}

static void WolFoxDislikeRelayout(id node) {
    for (id current = node; current != nil; current = WolFoxDislikeGet(current, @"supernode")) {
        SEL invalidate = NSSelectorFromString(@"invalidateCalculatedLayout");
        if ([current respondsToSelector:invalidate]) ((void (*)(id, SEL))objc_msgSend)(current, invalidate);
        SEL needs = NSSelectorFromString(@"setNeedsLayout");
        if ([current respondsToSelector:needs]) ((void (*)(id, SEL))objc_msgSend)(current, needs);
    }
}


// Puts our count on one of our number nodes; YouTube's own nodes are untouched.
static BOOL WolFoxDislikeApplyCount(id number) {
    NSNumber *count = objc_getAssociatedObject(number, WolFoxDislikeCountAssociation);
    if (count == nil) return NO;
    UIView *rolling = WolFoxDislikeGet(number, @"rollingNumberView");
    // Match the like count's font and color as they are now; on a video that
    // is already disliked they aren't set yet the first time we get here.
    id likeNumber = [objc_getAssociatedObject(number, WolFoxDislikeStyleAssociation) anyObject];
    UIView *likeRolling = WolFoxDislikeGet(likeNumber, @"rollingNumberView");
    NSMutableDictionary *style = [NSMutableDictionary dictionary];
    for (NSString *key in @[@"font", @"fontAttributes", @"color"]) {
        id value = WolFoxDislikeGet(likeRolling, key);
        if (value != nil) style[key] = value;
    }
    if (style[@"font"] == nil) return YES;
    SEL set = NSSelectorFromString(@"setUpdatedCount:updatedCountNumber:font:fontAttributes:color:skipAnimation:");
    if (rolling == nil || ![rolling respondsToSelector:set]) return YES;
    NSString *text = WolFoxDislikeText(count.longLongValue);
    if ([WolFoxDislikeGet(rolling, @"updatedCount") isEqual:text]) return YES;
    ((void (*)(id, SEL, id, id, id, id, id, BOOL))objc_msgSend)(
        rolling, set, text, count, style[@"font"], style[@"fontAttributes"], style[@"color"], YES);
    return YES;
}

// On our node YouTube's update would put the like count back and fight with
// ours, leaving half-rolled digits, so only ours is applied there.
// Description panel ("more"): a Dislikes column after Likes in the stats row
// (number over label, three equal columns). Found by layout, not by text, so
// it works in every language. An empty node holds the space in YouTube's
// layout and our view sits over it, since the row drops subnodes it didn't make.
static NSString *WolFoxCurrentWatchVideo;
static NSHashTable<UIView *> *WolFoxStatViews;
static const void *WolFoxStatNodeAssociation = &WolFoxStatNodeAssociation;
static const void *WolFoxStatViewAssociation = &WolFoxStatViewAssociation;
static const void *WolFoxStatVideoAssociation = &WolFoxStatVideoAssociation;
static const NSInteger WolFoxStatValueTag = 0x52595356;
static const NSInteger WolFoxStatLabelTag = 0x5259534c;

static CGSize WolFoxStatSize(id receiver, __unused SEL selector, __unused CGSize constrained) {
    NSValue *size = objc_getAssociatedObject(receiver, WolFoxStatNodeAssociation);
    return size ? size.CGSizeValue : CGSizeMake(60, 38);
}

static Class WolFoxStatNodeClass(void) {
    static Class cls;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class base = NSClassFromString(@"ASDisplayNode");
        if (base == Nil) return;
        cls = objc_allocateClassPair(base, "WolFoxDislikeStatNode", 0);
        if (cls == Nil) { cls = NSClassFromString(@"WolFoxDislikeStatNode"); return; }
        class_addMethod(cls, NSSelectorFromString(@"calculateSizeThatFits:"),
                        (IMP)WolFoxStatSize, "{CGSize=dd}32@0:8{CGSize=dd}16");
        objc_registerClassPair(cls);
    });
    return cls;
}

static CGRect WolFoxNodeFrame(id node) {
    return node ? ((CGRect (*)(id, SEL))objc_msgSend)(node, @selector(frame)) : CGRectZero;
}

static const void *WolFoxStatFullAssociation = &WolFoxStatFullAssociation;

static void WolFoxStatSetCount(UIView *view) {
    NSNumber *count = [WolFoxDislikeCounts objectForKey:objc_getAssociatedObject(view, WolFoxStatVideoAssociation) ?: @""];
    UILabel *value = [view viewWithTag:WolFoxStatValueTag];
    if (count == nil) {
        value.text = @"-";
    } else if ([objc_getAssociatedObject(view, WolFoxStatFullAssociation) boolValue]) {
        // Likes are written out in full (105,735), so match that.
        value.text = [NSNumberFormatter localizedStringFromNumber:count numberStyle:NSNumberFormatterDecimalStyle];
    } else {
        value.text = WolFoxDislikeText(count.longLongValue);
    }
}

// Puts our view over the space the empty node holds, lined up with Likes.
static void WolFoxStatPlace(id row, id stat, id holder, id labelNode) {
    UIView *view = objc_getAssociatedObject(row, WolFoxStatViewAssociation);
    id node = objc_getAssociatedObject(row, WolFoxStatNodeAssociation);
    UIView *rowView = WolFoxDislikeIvar(row, "_view");
    if (view == nil || node == nil || rowView == nil) return;
    if (view.superview != rowView) [rowView addSubview:view];
    CGRect slot = WolFoxNodeFrame(node);
    CGRect statFrame = WolFoxNodeFrame(stat);
    if (slot.size.width <= 0) return;
    view.frame = CGRectMake(slot.origin.x, statFrame.origin.y, slot.size.width, statFrame.size.height);
    UILabel *value = [view viewWithTag:WolFoxStatValueTag];
    UILabel *label = [view viewWithTag:WolFoxStatLabelTag];
    CGRect holderFrame = WolFoxNodeFrame(holder);
    CGRect labelFrame = WolFoxNodeFrame(labelNode);
    value.frame = CGRectMake(0, holderFrame.origin.y, slot.size.width, holderFrame.size.height);
    label.frame = CGRectMake(0, labelFrame.origin.y, slot.size.width, labelFrame.size.height);
}

// The likes stat: a column whose first child holds this number and whose
// second is the label, first of a row of three or more such columns.
static void WolFoxStatConsider(id number) {
    if (!WolFoxFeatureEnabled(WolFoxReturnDislikeKey) || WolFoxCurrentWatchVideo == nil) return;
    id holder = WolFoxDislikeGet(number, @"supernode");
    id stat = WolFoxDislikeGet(holder, @"supernode");
    id row = WolFoxDislikeGet(stat, @"supernode");
    NSArray *statKids = WolFoxDislikeGet(stat, @"yogaChildren");
    NSArray *rowKids = WolFoxDislikeGet(row, @"yogaChildren");
    if (statKids.count != 2 || statKids[0] != holder || rowKids.count < 3 || rowKids.firstObject != stat) return;
    id labelNode = statKids[1];
    if (![NSStringFromClass([labelNode class]) isEqualToString:@"ELMTextNode"]) return;
    if (objc_getAssociatedObject(row, WolFoxStatNodeAssociation) != nil) {
        WolFoxStatPlace(row, stat, holder, labelNode);
        return;
    }
    for (id other in rowKids) {
        if (other == stat) continue;
        NSArray *kids = WolFoxDislikeGet(other, @"yogaChildren");
        if (kids.count != 2 || ![NSStringFromClass([kids[1] class]) isEqualToString:@"ELMTextNode"]) return;
    }

    // The digits are labels inside the number's view; copy the first one's style.
    UILabel *digit = nil;
    NSMutableArray<UIView *> *queue = [NSMutableArray array];
    UIView *numberView = WolFoxDislikeGet(number, @"rollingNumberView");
    if (numberView != nil) [queue addObject:numberView];
    while (queue.count != 0 && digit == nil) {
        UIView *view = queue.firstObject;
        [queue removeObjectAtIndex:0];
        if ([view isKindOfClass:UILabel.class]) digit = (UILabel *)view;
        [queue addObjectsFromArray:view.subviews];
    }
    NSAttributedString *likesLabel = WolFoxDislikeGet(labelNode, @"attributedText");
    if (digit.font == nil || ![likesLabel isKindOfClass:NSAttributedString.class] || likesLabel.length == 0) return;

    UIView *view = [UIView new];
    view.userInteractionEnabled = NO;
    UILabel *value = [UILabel new];
    value.tag = WolFoxStatValueTag;
    value.font = digit.font;
    value.textColor = digit.textColor ?: UIColor.labelColor;
    value.textAlignment = NSTextAlignmentCenter;
    UILabel *label = [UILabel new];
    label.tag = WolFoxStatLabelTag;
    NSMutableDictionary *labelAttributes = [[likesLabel attributesAtIndex:0 effectiveRange:NULL] mutableCopy];
    [labelAttributes removeObjectForKey:NSParagraphStyleAttributeName];
    [labelAttributes removeObjectForKey:NSBaselineOffsetAttributeName];
    label.attributedText = [[NSAttributedString alloc] initWithString:WolFoxLocalized(@"Dislikes")
                                                           attributes:labelAttributes];
    label.textAlignment = NSTextAlignmentCenter;
    [view addSubview:value];
    [view addSubview:label];
    objc_setAssociatedObject(view, WolFoxStatVideoAssociation, WolFoxCurrentWatchVideo, OBJC_ASSOCIATION_COPY_NONATOMIC);
    id likesText = WolFoxDislikeGet(numberView, @"updatedCount");
    BOOL full = [likesText isKindOfClass:NSString.class] && [likesText length] != 0 &&
        [likesText rangeOfCharacterFromSet:NSCharacterSet.letterCharacterSet].location == NSNotFound;
    objc_setAssociatedObject(view, WolFoxStatFullAssociation, @(full), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (WolFoxStatViews == nil) WolFoxStatViews = [NSHashTable weakObjectsHashTable];
    [WolFoxStatViews addObject:view];
    WolFoxStatSetCount(view);

    id node = [WolFoxStatNodeClass() new];
    if (node == nil) return;
    CGRect statFrame = WolFoxNodeFrame(stat);
    CGFloat width = ceil(MAX([value sizeThatFits:CGSizeZero].width, [label sizeThatFits:CGSizeZero].width));
    objc_setAssociatedObject(node, WolFoxStatNodeAssociation,
        [NSValue valueWithCGSize:CGSizeMake(MAX(width, 40.0), statFrame.size.height > 0 ? statFrame.size.height : 38.0)],
        OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ((void (*)(id, SEL))objc_msgSend)(node, NSSelectorFromString(@"enableYoga"));
    // Same flex as the likes column, so the row stays evenly spaced.
    id style = WolFoxDislikeGet(node, @"style");
    id statStyle = WolFoxDislikeGet(stat, @"style");
    SEL grow = NSSelectorFromString(@"flexGrow"), shrink = NSSelectorFromString(@"flexShrink");
    if ([statStyle respondsToSelector:grow] && [style respondsToSelector:NSSelectorFromString(@"setFlexGrow:")]) {
        ((void (*)(id, SEL, CGFloat))objc_msgSend)(style, NSSelectorFromString(@"setFlexGrow:"),
            ((CGFloat (*)(id, SEL))objc_msgSend)(statStyle, grow));
        ((void (*)(id, SEL, CGFloat))objc_msgSend)(style, NSSelectorFromString(@"setFlexShrink:"),
            ((CGFloat (*)(id, SEL))objc_msgSend)(statStyle, shrink));
    }
    @try {
        ((void (*)(id, SEL, id, NSUInteger))objc_msgSend)(row, NSSelectorFromString(@"insertYogaChild:atIndex:"), node, 1);
    } @catch (NSException *exception) {
        WolFoxDebugLog(@"ryd", @"stat insert threw %@", exception.reason);
        return;
    }
    objc_setAssociatedObject(row, WolFoxStatNodeAssociation, node, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(row, WolFoxStatViewAssociation, view, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    WolFoxDislikeRelayout(row);
    WolFoxDebugLog(@"ryd", @"stat column added for %@", WolFoxCurrentWatchVideo);
}

static void WolFoxRollingUpdate(id receiver, SEL selector) {
    if (WolFoxDislikeApplyCount(receiver)) return;
    if (OriginalRollingUpdate != NULL) ((void (*)(id, SEL))OriginalRollingUpdate)(receiver, selector);
}

static void WolFoxRollingPrepare(id receiver, SEL selector) {
    if (OriginalRollingPrepare != NULL) ((void (*)(id, SEL))OriginalRollingPrepare)(receiver, selector);
    WolFoxDislikeApplyCount(receiver);
}

static CGSize WolFoxRollingSize(id receiver, SEL selector, CGSize constrained) {
    CGSize size = OriginalRollingSize != NULL
        ? ((CGSize (*)(id, SEL, CGSize))OriginalRollingSize)(receiver, selector, constrained) : CGSizeZero;
    if (!WolFoxDislikeApplyCount(receiver)) return size;
    UIView *rolling = WolFoxDislikeGet(receiver, @"rollingNumberView");
    if (rolling == nil) return size;
    CGSize fit = [rolling sizeThatFits:constrained];
    return CGSizeMake(ceil(fit.width) + WolFoxDislikeGap, MAX(size.height, ceil(fit.height)));
}

// Same gap between the icon and the number as the like side.
static void WolFoxRollingLayout(id receiver, SEL selector) {
    if (OriginalRollingLayout != NULL) ((void (*)(id, SEL))OriginalRollingLayout)(receiver, selector);
    if (objc_getAssociatedObject(receiver, WolFoxDislikeCountAssociation) == nil) {
        __weak id weakNumber = receiver;
        dispatch_async(dispatch_get_main_queue(), ^{ WolFoxStatConsider(weakNumber); });
        return;
    }
    UIView *rolling = WolFoxDislikeGet(receiver, @"rollingNumberView");
    UIView *host = WolFoxDislikeGet(receiver, @"view");
    if (rolling == nil || host == nil) return;
    CGRect frame = rolling.frame;
    frame.origin.x = WolFoxDislikeGap;
    frame.size.width = MAX(0.0, host.bounds.size.width - WolFoxDislikeGap);
    frame.origin.y = round((host.bounds.size.height - frame.size.height) / 2.0);
    rolling.frame = frame;
    rolling.userInteractionEnabled = NO;
}

static NSHashTable<UIView *> *WolFoxWatchDislikeViews;

// iPhone watch layout: the like count isn't on the button but in the line
// under the title ("1.4M likes  149M views  8y ago"), so the dislike count
// goes in that line after the likes.
static const void *WolFoxMetaVideoAssociation = &WolFoxMetaVideoAssociation;
static const void *WolFoxMetaOriginalAssociation = &WolFoxMetaOriginalAssociation;
static const void *WolFoxMetaViewsAssociation = &WolFoxMetaViewsAssociation;
static NSString *const WolFoxMetaGap = @"  ";

// The likes part is the first one with a number that isn't the @handle.
static NSInteger WolFoxMetaLikesIndex(NSArray<NSString *> *parts) {
    for (NSUInteger index = 0; index + 2 < parts.count; index++) {
        NSString *part = parts[index];
        if ([part hasPrefix:@"@"]) continue;
        if ([part rangeOfCharacterFromSet:NSCharacterSet.decimalDigitCharacterSet].location != NSNotFound) return index;
        return -1;
    }
    return -1;
}

static void WolFoxMetaForget(id node) {
    objc_setAssociatedObject(node, WolFoxMetaVideoAssociation, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(node, WolFoxMetaOriginalAssociation, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(node, WolFoxMetaViewsAssociation, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// Called from the ELMTextNode setAttributedText: hook for every text node.
NSAttributedString *WolFoxDislikeMetaText(id node, NSAttributedString *value) {
    NSString *videoID = objc_getAssociatedObject(node, WolFoxMetaVideoAssociation);
    if (videoID == nil || ![value isKindOfClass:NSAttributedString.class] || value.length == 0) return value;
    NSArray<NSString *> *parts = [value.string componentsSeparatedByString:WolFoxMetaGap];
    const NSInteger likes = WolFoxMetaLikesIndex(parts);
    // A different views count means the node now shows another video.
    if (likes < 0 || ![parts[likes + 1] isEqualToString:objc_getAssociatedObject(node, WolFoxMetaViewsAssociation)]) {
        WolFoxMetaForget(node);
        return value;
    }
    objc_setAssociatedObject(node, WolFoxMetaOriginalAssociation, value, OBJC_ASSOCIATION_COPY_NONATOMIC);
    NSNumber *count = [WolFoxDislikeCounts objectForKey:videoID];
    if (count == nil || !WolFoxFeatureEnabled(WolFoxReturnDislikeKey)) return value;
    NSString *label = [NSString stringWithFormat:WolFoxLocalized(@"%@ dislikes"),
                       WolFoxDislikeText(count.longLongValue)];
    NSDictionary *attributes = [value attributesAtIndex:0 effectiveRange:NULL];
    NSMutableAttributedString *text = [value mutableCopy];
    [text insertAttributedString:[[NSAttributedString alloc]
        initWithString:[WolFoxMetaGap stringByAppendingString:label] attributes:attributes]
                         atIndex:NSMaxRange([value.string rangeOfString:parts[likes]
                                                 options:0
                                                   range:NSMakeRange(0, value.length)])];
    return text;
}

static void WolFoxDislikeMetaShow(UIView *dislikeView, NSString *videoID) {
    UIView *list = dislikeView.superview;
    while (list != nil && ![list isKindOfClass:UICollectionView.class]) list = list.superview;
    if (list == nil) {
        WolFoxDebugLog(@"ryd", @"meta no list");
        return;
    }
    const CGFloat barY = [dislikeView convertPoint:CGPointZero toView:list].y;
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:list];
    NSUInteger visited = 0;
    while (stack.count != 0 && visited++ < 4000) {
        UIView *view = stack.lastObject;
        [stack removeLastObject];
        id node = WolFoxDislikeGet(view, @"keepalive_node");
        if ([NSStringFromClass([node class]) isEqualToString:@"ELMTextNode"] &&
            [view convertPoint:CGPointZero toView:list].y < barY) {
            NSAttributedString *current = objc_getAssociatedObject(node, WolFoxMetaOriginalAssociation)
                ?: WolFoxDislikeGet(node, @"attributedText");
            NSArray<NSString *> *parts = [current isKindOfClass:NSAttributedString.class]
                ? [current.string componentsSeparatedByString:WolFoxMetaGap] : nil;
            const NSInteger likes = WolFoxMetaLikesIndex(parts);
            if (likes >= 0) {
                objc_setAssociatedObject(node, WolFoxMetaVideoAssociation, videoID, OBJC_ASSOCIATION_COPY_NONATOMIC);
                objc_setAssociatedObject(node, WolFoxMetaViewsAssociation, parts[likes + 1], OBJC_ASSOCIATION_COPY_NONATOMIC);
                SEL set = NSSelectorFromString(@"setAttributedText:");
                if ([node respondsToSelector:set]) ((void (*)(id, SEL, id))objc_msgSend)(node, set, current);
                WolFoxDebugLog(@"ryd", @"meta line set for %@", videoID);
                return;
            }
        }
        for (UIView *sub in view.subviews) [stack addObject:sub];
    }
    WolFoxDebugLog(@"ryd", @"meta line not found");
}

static void WolFoxDislikeShow(UIView *dislikeView, NSNumber *count) {
    if (WolFoxWatchDislikeViews == nil) WolFoxWatchDislikeViews = [NSHashTable weakObjectsHashTable];
    [WolFoxWatchDislikeViews addObject:dislikeView];
    id dislikeNode = WolFoxDislikeGet(dislikeView, @"keepalive_node");
    id likeNumber = WolFoxDislikeLikeNumber(dislikeView);
    if (dislikeNode == nil || likeNumber == nil) {
        if (dislikeNode != nil && likeNumber == nil) {
            WolFoxDislikeMetaShow(dislikeView, objc_getAssociatedObject(dislikeView, WolFoxDislikeVideoAssociation));
            return;
        }
        WolFoxDebugLog(@"ryd", @"show missing node=%d like=%d", dislikeNode != nil, likeNumber != nil);
        return;
    }
    id number = objc_getAssociatedObject(dislikeNode, WolFoxDislikeNumberAssociation);
    if (number == nil) {
        id element = WolFoxDislikeGet(likeNumber, @"element");
        id context = WolFoxDislikeIvar(likeNumber, "_context");
        Class numberClass = NSClassFromString(@"YTRollingNumberNode");
        SEL init = NSSelectorFromString(@"initWithElement:context:");
        if (element == nil || numberClass == Nil) {
            WolFoxDebugLog(@"ryd", @"no element=%d context=%d", element != nil, context != nil);
            return;
        }
        @try {
            number = ((id (*)(id, SEL, id, id))objc_msgSend)([numberClass alloc], init, element, context);
        } @catch (__unused NSException *exception) {
            return;
        }
        if (number == nil) return;
        objc_setAssociatedObject(dislikeNode, WolFoxDislikeNumberAssociation, number,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        // A node made outside YouTube's build has no yoga node until this.
        SEL enable = NSSelectorFromString(@"enableYoga");
        if ([number respondsToSelector:enable]) ((void (*)(id, SEL))objc_msgSend)(number, enable);
        SEL add = NSSelectorFromString(@"addYogaChild:");
        @try {
            if ([dislikeNode respondsToSelector:add]) ((void (*)(id, SEL, id))objc_msgSend)(dislikeNode, add, number);
        } @catch (NSException *exception) {
            WolFoxDebugLog(@"ryd", @"add threw %@ %@", exception.name, exception.reason);
            objc_setAssociatedObject(dislikeNode, WolFoxDislikeNumberAssociation, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            return;
        }
        // Taps on the number go to the dislike button, like on the like side.
        SEL interaction = @selector(setUserInteractionEnabled:);
        if ([number respondsToSelector:interaction]) ((void (*)(id, SEL, BOOL))objc_msgSend)(number, interaction, NO);
        UIView *numberView = WolFoxDislikeGet(number, @"view");
        numberView.userInteractionEnabled = NO;
        if (numberView != nil) [dislikeView addSubview:numberView];
    }
    NSHashTable *likeRef = [NSHashTable weakObjectsHashTable];
    [likeRef addObject:likeNumber];
    objc_setAssociatedObject(number, WolFoxDislikeStyleAssociation, likeRef, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(number, WolFoxDislikeCountAssociation, count, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    WolFoxDislikeApplyCount(number);
    SEL invalidate = NSSelectorFromString(@"invalidateCachedCalculatedSize");
    if ([number respondsToSelector:invalidate]) ((void (*)(id, SEL))objc_msgSend)(number, invalidate);
    UIView *rolling = WolFoxDislikeGet(number, @"rollingNumberView");
    WolFoxDislikeRelayout(number);
    WolFoxDebugLog(@"ryd", @"show %@ rolling=%d frame=%@", WolFoxDislikeText(count.longLongValue),
                   rolling != nil, NSStringFromCGRect(dislikeView.frame));
}


// Shorts: YouTube dropped the dislike button, so a node with the count goes in
// the button column right after Like, as part of YouTube's own layout.
static NSString *const WolFoxShortsDislikeKey = @"YTKACE.Preference.Shorts.DislikeCount";
static const void *WolFoxShortsDislikeNodeAssociation = &WolFoxShortsDislikeNodeAssociation;
static const NSInteger WolFoxShortsDislikeLabelTag = 0x52594444;

static const NSInteger WolFoxShortsDislikeIconTag = 0x52594449;
static const void *WolFoxShortsViewVideoAssociation = &WolFoxShortsViewVideoAssociation;
static NSMutableSet<NSString *> *WolFoxDislikedVideos;
static NSHashTable<UIView *> *WolFoxShortsDislikeViews;
static void WolFoxShortsDislikeTapped(UIView *view);

@interface WolFoxShortsDislikeTarget : NSObject
@end

@implementation WolFoxShortsDislikeTarget
- (void)tapped:(UITapGestureRecognizer *)recognizer {
    WolFoxShortsDislikeTapped(recognizer.view);
}
@end

static UIImage *WolFoxShortsDislikeIcon(BOOL filled) {
    return [UIImage systemImageNamed:filled ? @"hand.thumbsdown.fill" : @"hand.thumbsdown"
                   withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:20.0
                                                                                     weight:UIImageSymbolWeightRegular]];
}

static UIView *WolFoxShortsDislikeMakeView(void) {
    static WolFoxShortsDislikeTarget *target;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ target = [WolFoxShortsDislikeTarget new]; });
    UIView *view = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 64, 60)];
    view.userInteractionEnabled = YES;
    view.accessibilityTraits = UIAccessibilityTraitButton;
    [view addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:target action:@selector(tapped:)]];
    view.isAccessibilityElement = YES;
    view.accessibilityIdentifier = @"id.ytkace_dislike_button";
    UIImageView *icon = [[UIImageView alloc] initWithFrame:CGRectMake(20, 9, 24, 24)];
    icon.tag = WolFoxShortsDislikeIconTag;
    icon.image = WolFoxShortsDislikeIcon(NO);
    icon.contentMode = UIViewContentModeCenter;
    icon.tintColor = UIColor.whiteColor;
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(0, 36, 64, 16)];
    label.tag = WolFoxShortsDislikeLabelTag;
    label.textAlignment = NSTextAlignmentCenter;
    label.textColor = UIColor.whiteColor;
    label.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightMedium];
    for (UIView *part in @[icon, label]) {
        part.layer.shadowColor = UIColor.blackColor.CGColor;
        part.layer.shadowOpacity = 0.4;
        part.layer.shadowRadius = 2.0;
        part.layer.shadowOffset = CGSizeZero;
        [view addSubview:part];
    }
    return view;
}

static CGSize WolFoxShortsDislikeNodeSize(__unused id receiver, __unused SEL selector, __unused CGSize constrained) {
    return CGSizeMake(64.0, 60.0);
}

// ASDisplayNode subclass sized like the other Shorts buttons.
static Class WolFoxShortsDislikeNodeClass(void) {
    static Class cls;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class base = NSClassFromString(@"ASDisplayNode");
        if (base == Nil) return;
        cls = objc_allocateClassPair(base, "WolFoxShortsDislikeNode", 0);
        if (cls == Nil) { cls = NSClassFromString(@"WolFoxShortsDislikeNode"); return; }
        class_addMethod(cls, NSSelectorFromString(@"calculateSizeThatFits:"),
                        (IMP)WolFoxShortsDislikeNodeSize, "{CGSize=dd}32@0:8{CGSize=dd}16");
        objc_registerClassPair(cls);
    });
    return cls;
}

static BOOL WolFoxIsReelLike(id node) {
    return [node respondsToSelector:@selector(accessibilityIdentifier)] &&
        [[node accessibilityIdentifier] isEqualToString:@"id.reel_like_button"];
}

// Puts our node right after Like. Only called once the column is built.
static NSUInteger WolFoxShortsLikeIndex(NSArray *children) {
    for (NSUInteger i = 0; i < children.count; i++) {
        if (WolFoxIsReelLike(children[i])) return i;
    }
    return NSNotFound;
}


static id WolFoxShortsDislikeInsert(id rail) {
    NSArray *children = WolFoxDislikeGet(rail, @"yogaChildren");
    NSUInteger index = WolFoxShortsLikeIndex(children);
    if (index == NSNotFound) return nil;
    id node = objc_getAssociatedObject(rail, WolFoxShortsDislikeNodeAssociation);
    if (node != nil) {
        if ([children indexOfObjectIdenticalTo:node] == NSNotFound)
            ((void (*)(id, SEL, id, NSUInteger))objc_msgSend)(rail, NSSelectorFromString(@"insertYogaChild:atIndex:"),
                                                             node, index + 1);
        return node;
    }
    UIView *(^block)(void) = ^UIView *{ return WolFoxShortsDislikeMakeView(); };
    node = ((id (*)(id, SEL, id))objc_msgSend)([WolFoxShortsDislikeNodeClass() alloc],
                                               NSSelectorFromString(@"initWithViewBlock:"), block);
    if (node == nil) return nil;
    ((void (*)(id, SEL))objc_msgSend)(node, NSSelectorFromString(@"enableYoga"));
    objc_setAssociatedObject(rail, WolFoxShortsDislikeNodeAssociation, node, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ((void (*)(id, SEL, id, NSUInteger))objc_msgSend)(rail, NSSelectorFromString(@"insertYogaChild:atIndex:"),
                                                     node, index + 1);
    // The column adds subnodes from its layout; adding ours by hand drops the
    // buttons after it.
    SEL managesSelector = NSSelectorFromString(@"automaticallyManagesSubnodes");
    BOOL managed = [rail respondsToSelector:managesSelector] &&
        ((BOOL (*)(id, SEL))objc_msgSend)(rail, managesSelector);
    if (!managed) ((void (*)(id, SEL, id))objc_msgSend)(rail, NSSelectorFromString(@"addSubnode:"), node);
    return node;
}

static IMP OriginalNodeAddYogaChild;
static IMP OriginalNodeInsertYogaChild;
static IMP OriginalNodeSetYogaChildren;

// These hooks see every node YouTube adds, so they check a cached flag first.
static volatile BOOL WolFoxShortsDislikeOn;

static void WolFoxShortsRefreshFlag(void) {
    WolFoxShortsDislikeOn = WolFoxFeatureEnabled(WolFoxShortsDislikeKey);
}

static NSUInteger WolFoxShortsOurIndex(id rail) {
    id node = objc_getAssociatedObject(rail, WolFoxShortsDislikeNodeAssociation);
    return node == nil ? NSNotFound : [WolFoxDislikeGet(rail, @"yogaChildren") indexOfObjectIdenticalTo:node];
}

// Our node goes in while YouTube builds the column, right after Like, so the
// first layout already has it. YouTube's later inserts use its own indexes,
// which are shifted past our node so its order is kept.
static void WolFoxShortsAfterChange(id rail) {
    if (!WolFoxShortsDislikeOn) return;
    if (WolFoxShortsDislikeInsert(rail) != nil) WolFoxDebugLog(@"ryd", @"shorts inserted at build");
}

static void WolFoxNodeAddYogaChild(id receiver, SEL selector, id child) {
    if (OriginalNodeAddYogaChild != NULL) ((void (*)(id, SEL, id))OriginalNodeAddYogaChild)(receiver, selector, child);
    if (WolFoxShortsDislikeOn && WolFoxIsReelLike(child)) WolFoxShortsAfterChange(receiver);
}

static void WolFoxNodeInsertYogaChild(id receiver, SEL selector, id child, NSUInteger index) {
    id ours = WolFoxShortsDislikeOn ? objc_getAssociatedObject(receiver, WolFoxShortsDislikeNodeAssociation) : nil;
    if (ours != nil && child != ours) {
        NSUInteger position = WolFoxShortsOurIndex(receiver);
        if (position != NSNotFound && index >= position) index++;
    }
    if (OriginalNodeInsertYogaChild != NULL)
        ((void (*)(id, SEL, id, NSUInteger))OriginalNodeInsertYogaChild)(receiver, selector, child, index);
    if (WolFoxShortsDislikeOn && child != ours && WolFoxIsReelLike(child)) WolFoxShortsAfterChange(receiver);
}

static void WolFoxNodeSetYogaChildren(id receiver, SEL selector, NSArray *children) {
    if (OriginalNodeSetYogaChildren != NULL) ((void (*)(id, SEL, id))OriginalNodeSetYogaChildren)(receiver, selector, children);
    if (!WolFoxShortsDislikeOn) return;
    for (id child in children) {
        if (WolFoxIsReelLike(child)) {
            WolFoxShortsAfterChange(receiver);
            return;
        }
    }
}

static void WolFoxShortsDislikeShow(UIView *likeView, NSNumber *count) {
    id likeNode = WolFoxDislikeGet(likeView, @"keepalive_node");
    id rail = WolFoxDislikeGet(likeNode, @"supernode");
    BOOL late = objc_getAssociatedObject(rail, WolFoxShortsDislikeNodeAssociation) == nil;
    id node = WolFoxShortsDislikeInsert(rail);
    if (node == nil) return;
    UIView *view = WolFoxDislikeGet(node, @"view");
    UILabel *label = [view viewWithTag:WolFoxShortsDislikeLabelTag];
    label.text = count != nil ? WolFoxDislikeText(count.longLongValue) : WolFoxLocalized(@"Dislike");
    view.accessibilityLabel = count != nil ? [NSString stringWithFormat:@"%@ dislikes", label.text] : label.text;
    NSString *videoID = objc_getAssociatedObject(likeView, WolFoxDislikeVideoAssociation);
    objc_setAssociatedObject(view, WolFoxShortsViewVideoAssociation, videoID, OBJC_ASSOCIATION_COPY_NONATOMIC);
    ((UIImageView *)[view viewWithTag:WolFoxShortsDislikeIconTag]).image =
        WolFoxShortsDislikeIcon(videoID != nil && [WolFoxDislikedVideos containsObject:videoID]);
    if (WolFoxShortsDislikeViews == nil) WolFoxShortsDislikeViews = [NSHashTable weakObjectsHashTable];
    [WolFoxShortsDislikeViews addObject:view];
    if (!late) return;
    // Fallback if the column got past layout without us.
    WolFoxDebugLog(@"ryd", @"shorts inserted late rail=%p", rail);
    WolFoxDislikeRelayout(node);
    for (id current = rail; current != nil; current = WolFoxDislikeGet(current, @"supernode")) {
        [(UIView *)WolFoxDislikeGet(current, @"view") setNeedsLayout];
        SEL layoutIfNeeded = NSSelectorFromString(@"layoutIfNeeded");
        if ([current respondsToSelector:layoutIfNeeded]) ((void (*)(id, SEL))objc_msgSend)(current, layoutIfNeeded);
    }
}

static void WolFoxDislikeFetch(NSString *videoID) {
    NSString *address = [@"https://returnyoutubedislikeapi.com/votes?videoId="
        stringByAppendingString:[videoID stringByAddingPercentEncodingWithAllowedCharacters:
                                 NSCharacterSet.URLQueryAllowedCharacterSet]];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:address]];
    request.timeoutInterval = 10.0;
    [[NSURLSession.sharedSession dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        id json = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        id dislikes = [json isKindOfClass:NSDictionary.class] ? json[@"dislikes"] : nil;
        WolFoxDebugLog(@"ryd", @"fetch video=%@ status=%ld dislikes=%@ error=%@", videoID,
                       (long)[(NSHTTPURLResponse *)response statusCode], dislikes, error.localizedDescription ?: @"-");
        if (![dislikes isKindOfClass:NSNumber.class]) return;
        [WolFoxDislikeCounts setObject:dislikes forKey:videoID];
        dispatch_async(dispatch_get_main_queue(), ^{
            for (UIView *stat in WolFoxStatViews.allObjects) WolFoxStatSetCount(stat);
            NSArray<UIView *> *views;
            @synchronized (WolFoxDislikeWaiting) {
                views = WolFoxDislikeWaiting[videoID].allObjects;
                [WolFoxDislikeWaiting removeObjectForKey:videoID];
            }
            for (UIView *view in views) {
                if (view.window != nil &&
                    [objc_getAssociatedObject(view, WolFoxDislikeVideoAssociation) isEqualToString:videoID]) {
                    if ([view.accessibilityIdentifier isEqualToString:@"id.reel_like_button"]) {
                        WolFoxShortsDislikeShow(view, dislikes);
                    } else {
                        WolFoxDislikeShow(view, dislikes);
                    }
                }
            }
        });
    }] resume];
}

// The iPhone bar puts the count in the line under the title, not on a
// button. The dislike button can be moved into ⋯ there, so the like button
// can start it too.
static BOOL WolFoxInFixedActionBar(UIView *view) {
    for (UIView *ancestor = view.superview; ancestor != nil; ancestor = ancestor.superview) {
        if ([ancestor.accessibilityIdentifier containsString:@"non_scrollable_action_bar"]) return YES;
    }
    return NO;
}

void WolFoxReturnDislikeConsiderView(UIView *view) {
    if (view.window == nil) return;
    NSString *identifier = view.accessibilityIdentifier;
    BOOL shorts = [identifier isEqualToString:@"id.reel_like_button"];
    const BOOL fixedLike = [identifier isEqualToString:@"id.video.like.button"] && WolFoxInFixedActionBar(view);
    if (shorts) {
        if (!WolFoxFeatureEnabled(WolFoxShortsDislikeKey)) return;
    } else if ((![identifier isEqualToString:@"id.video.dislike.button"] && !fixedLike) ||
               !WolFoxFeatureEnabled(WolFoxReturnDislikeKey) ||
               WolFoxFeatureEnabled(@"YTKACE.Preference.ActionBar.DislikeHidden")) {
        return;
    }
    NSString *videoID = WolFoxDislikeVideoID(view);
    if (videoID.length == 0) return;
    if (!shorts) WolFoxCurrentWatchVideo = [videoID copy];
    objc_setAssociatedObject(view, WolFoxDislikeVideoAssociation, videoID, OBJC_ASSOCIATION_COPY_NONATOMIC);
    // Shorts: make room right away so the button doesn't pop in after the fetch.
    if (shorts) WolFoxShortsDislikeShow(view, nil);
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        WolFoxDislikeCounts = [NSCache new];
        WolFoxDislikeCounts.countLimit = 200;
        WolFoxDislikeWaiting = [NSMutableDictionary dictionary];
    });
    NSNumber *cached = [WolFoxDislikeCounts objectForKey:videoID];
    if (cached != nil) {
        if (shorts) WolFoxShortsDislikeShow(view, cached);
        else WolFoxDislikeShow(view, cached);
        return;
    }
    BOOL first;
    @synchronized (WolFoxDislikeWaiting) {
        NSHashTable *views = WolFoxDislikeWaiting[videoID];
        first = views == nil;
        if (first) views = WolFoxDislikeWaiting[videoID] = [NSHashTable weakObjectsHashTable];
        [views addObject:view];
    }
    if (first) WolFoxDislikeFetch(videoID);
}

// Every like, dislike and removal goes through YouTube's like service, from
// the watch page, fullscreen and Shorts.
static __weak id WolFoxLikeService;
static IMP OriginalLikeRequest;
static IMP OriginalLikeRequestDispatch;
static IMP OriginalLikeServiceInit;

static id WolFoxLikeServiceInit(id receiver, SEL selector, id account) {
    id service = ((id (*)(id, SEL, id))OriginalLikeServiceInit)(receiver, selector, account);
    WolFoxLikeService = service;
    return service;
}

static NSString *WolFoxLikeTargetVideoID(id target) {
    for (NSString *name in @[@"videoId", @"videoID"]) {
        id value = WolFoxDislikeGet(target, name);
        if ([value isKindOfClass:NSString.class] && [value length] != 0) return value;
    }
    return nil;
}

// ---- Vote submission (off by default). Only a random ID, the video ID and the
// vote are sent. The API asks for a small proof of work before it takes votes.
static NSString *const WolFoxVotesKey = @"YTKACE.Preference.ActionBar.ReturnDislikeVotes";
static NSString *const WolFoxRYDUserKey = @"WolFox.Cache.RYDUserID";
static NSString *const WolFoxRYDRegisteredKey = @"WolFox.Cache.RYDRegistered";

static dispatch_queue_t WolFoxVoteQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ queue = dispatch_queue_create("com.ytkace.ryd-votes", DISPATCH_QUEUE_SERIAL); });
    return queue;
}

static NSString *WolFoxRYDUserID(void) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSString *user = [defaults stringForKey:WolFoxRYDUserKey];
    if (user.length == 36) return user;
    static const char letters[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
    char buffer[37] = {0};
    for (int i = 0; i < 36; i++) buffer[i] = letters[arc4random_uniform((uint32_t)(sizeof letters - 1))];
    user = @(buffer);
    [defaults setObject:user forKey:WolFoxRYDUserKey];
    [defaults setBool:NO forKey:WolFoxRYDRegisteredKey];
    return user;
}

static id WolFoxRYDRequest(NSString *method, NSString *path, NSDictionary *body, NSInteger *status) {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:
        [NSURL URLWithString:[@"https://returnyoutubedislikeapi.com" stringByAppendingString:path]]];
    request.HTTPMethod = method;
    request.timeoutInterval = 15.0;
    if (body != nil) {
        [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
        request.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    }
    __block id result = nil;
    __block NSInteger code = 0;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    [[NSURLSession.sharedSession dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response, __unused NSError *error) {
        code = [(NSHTTPURLResponse *)response statusCode];
        if (data.length != 0) result = [NSJSONSerialization JSONObjectWithData:data
                                                                       options:NSJSONReadingFragmentsAllowed error:nil];
        dispatch_semaphore_signal(done);
    }] resume];
    dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(20 * NSEC_PER_SEC)));
    if (status != NULL) *status = code;
    return result;
}

// Finds a 4-byte prefix whose SHA-512 with the challenge starts with enough zero bits.
static NSString *WolFoxRYDSolve(NSDictionary *puzzle) {
    if (![puzzle isKindOfClass:NSDictionary.class]) return nil;
    NSData *challenge = [[NSData alloc] initWithBase64EncodedString:puzzle[@"challenge"] ?: @"" options:0];
    NSInteger difficulty = [puzzle[@"difficulty"] integerValue];
    if (challenge.length == 0 || difficulty <= 0 || difficulty > 30) return nil;
    uint8_t buffer[20] = {0};
    memcpy(buffer + 4, challenge.bytes, MIN((NSUInteger)16, challenge.length));
    uint64_t limit = ((uint64_t)1 << difficulty) * 5;
    uint8_t hash[CC_SHA512_DIGEST_LENGTH];
    for (uint64_t attempt = 0; attempt < limit && attempt <= UINT32_MAX; attempt++) {
        uint32_t value = (uint32_t)attempt;
        buffer[0] = value & 0xff; buffer[1] = (value >> 8) & 0xff;
        buffer[2] = (value >> 16) & 0xff; buffer[3] = (value >> 24) & 0xff;
        CC_SHA512(buffer, sizeof buffer, hash);
        NSInteger zeros = 0;
        for (int i = 0; i < CC_SHA512_DIGEST_LENGTH; i++) {
            if (hash[i] == 0) { zeros += 8; continue; }
            zeros += __builtin_clz((unsigned int)hash[i]) - 24;
            break;
        }
        if (zeros >= difficulty) return [[NSData dataWithBytes:buffer length:4] base64EncodedStringWithOptions:0];
    }
    return nil;
}

static BOOL WolFoxRYDRegister(NSString *user) {
    NSString *path = [@"/puzzle/registration?userId=" stringByAppendingString:user];
    NSString *solution = WolFoxRYDSolve(WolFoxRYDRequest(@"GET", path, nil, NULL));
    if (solution == nil) return NO;
    id result = WolFoxRYDRequest(@"POST", path, @{@"solution": solution}, NULL);
    BOOL ok = [result isKindOfClass:NSNumber.class] && [result boolValue];
    [NSUserDefaults.standardUserDefaults setBool:ok forKey:WolFoxRYDRegisteredKey];
    WolFoxDebugLog(@"ryd", @"vote register ok=%d", ok);
    return ok;
}

static void WolFoxRYDSubmitVote(NSString *videoID, NSInteger value) {
    dispatch_async(WolFoxVoteQueue(), ^{
        NSString *user = WolFoxRYDUserID();
        if (![NSUserDefaults.standardUserDefaults boolForKey:WolFoxRYDRegisteredKey] && !WolFoxRYDRegister(user)) return;
        for (int attempt = 0; attempt < 2; attempt++) {
            NSInteger code = 0;
            id puzzle = WolFoxRYDRequest(@"POST", @"/interact/vote",
                                         @{@"userId": user, @"videoId": videoID, @"value": @(value)}, &code);
            if (code == 401 && attempt == 0 && WolFoxRYDRegister(user)) continue;
            NSString *solution = WolFoxRYDSolve(puzzle);
            if (solution == nil) {
                WolFoxDebugLog(@"ryd", @"vote video=%@ value=%ld status=%ld no puzzle", videoID, (long)value, (long)code);
                return;
            }
            id result = WolFoxRYDRequest(@"POST", @"/interact/confirmVote",
                                         @{@"userId": user, @"videoId": videoID, @"solution": solution}, &code);
            WolFoxDebugLog(@"ryd", @"vote video=%@ value=%ld confirmed=%@ status=%ld", videoID, (long)value,
                           result, (long)code);
            return;
        }
    });
}

// ---- Count and Shorts state follow the user's own like, dislike or removal.
static NSMutableDictionary<NSString *, NSNumber *> *WolFoxLastLikeStatus;

static void WolFoxDislikeAdjust(NSString *videoID, NSInteger delta) {
    NSNumber *cached = [WolFoxDislikeCounts objectForKey:videoID];
    if (cached == nil || delta == 0) return;
    NSNumber *updated = @(MAX(0LL, cached.longLongValue + delta));
    [WolFoxDislikeCounts setObject:updated forKey:videoID];
    for (UIView *stat in WolFoxStatViews.allObjects) WolFoxStatSetCount(stat);
    for (UIView *view in WolFoxWatchDislikeViews.allObjects) {
        if (view.window != nil && [objc_getAssociatedObject(view, WolFoxDislikeVideoAssociation) isEqualToString:videoID]) {
            WolFoxDislikeShow(view, updated);
        }
    }
    for (UIView *view in WolFoxShortsDislikeViews.allObjects) {
        if (![objc_getAssociatedObject(view, WolFoxShortsViewVideoAssociation) isEqualToString:videoID]) continue;
        UILabel *label = [view viewWithTag:WolFoxShortsDislikeLabelTag];
        label.text = WolFoxDislikeText(updated.longLongValue);
    }
}

static void WolFoxLikeRequested(id service, int status, id target) {
    WolFoxLikeService = service;
    NSString *videoID = WolFoxLikeTargetVideoID(target);
    WolFoxDebugLog(@"ryd", @"like request status=%d video=%@", status, videoID ?: @"-");
    if (videoID.length == 0 || status < 0 || status > 2) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (WolFoxLastLikeStatus == nil) WolFoxLastLikeStatus = [NSMutableDictionary dictionary];
        if (WolFoxDislikedVideos == nil) WolFoxDislikedVideos = [NSMutableSet set];
        BOOL wasDisliked = [WolFoxDislikedVideos containsObject:videoID] ||
            [WolFoxLastLikeStatus[videoID] intValue] == 1;
        if (WolFoxLastLikeStatus[videoID] != nil && [WolFoxLastLikeStatus[videoID] intValue] == status) return;
        WolFoxLastLikeStatus[videoID] = @(status);
        BOOL disliked = status == 1;
        if (disliked) [WolFoxDislikedVideos addObject:videoID];
        else [WolFoxDislikedVideos removeObject:videoID];
        WolFoxDislikeAdjust(videoID, disliked && !wasDisliked ? 1 : (!disliked && wasDisliked ? -1 : 0));
        for (UIView *view in WolFoxShortsDislikeViews.allObjects) {
            if ([objc_getAssociatedObject(view, WolFoxShortsViewVideoAssociation) isEqualToString:videoID])
                ((UIImageView *)[view viewWithTag:WolFoxShortsDislikeIconTag]).image = WolFoxShortsDislikeIcon(disliked);
        }
        if (WolFoxFeatureEnabled(WolFoxVotesKey)) WolFoxRYDSubmitVote(videoID, status == 0 ? 1 : (status == 1 ? -1 : 0));
    });
}

// Tapping the Shorts count dislikes the Short through YouTube's like service.
static void WolFoxShortsDislikeTapped(UIView *view) {
    NSString *videoID = objc_getAssociatedObject(view, WolFoxShortsViewVideoAssociation);
    id service = WolFoxLikeService;
    Class targetClass = NSClassFromString(@"YTILikeTarget");
    if (videoID.length == 0 || service == nil || targetClass == Nil) {
        WolFoxDebugLog(@"ryd", @"shorts tap video=%@ service=%d", videoID ?: @"-", service != nil);
        return;
    }
    [[UIImpactFeedbackGenerator.alloc initWithStyle:UIImpactFeedbackStyleLight] impactOccurred];
    id target = [targetClass new];
    ((void (*)(id, SEL, id))objc_msgSend)(target, NSSelectorFromString(@"setVideoId:"), videoID);
    int status = [WolFoxDislikedVideos containsObject:videoID] ? 2 : 1;
    void (^response)(id) = ^(__unused id result) {};
    void (^failure)(id) = ^(id error) { WolFoxDebugLog(@"ryd", @"shorts dislike failed %@", error); };
    SEL request = NSSelectorFromString(
        @"makeRequestWithStatus:target:clickTrackingParams:queueContextParams:requestParams:responseBlock:errorBlock:");
    ((void (*)(id, SEL, int, id, id, id, id, id, id))objc_msgSend)(service, request, status, target, nil, nil, nil,
                                                                  response, failure);
}

static void WolFoxLikeRequest(id receiver, SEL selector, int status, id target, id tracking, id queue, id params,
                              id response, id error) {
    WolFoxLikeService = receiver;
    ((void (*)(id, SEL, int, id, id, id, id, id, id))OriginalLikeRequest)(receiver, selector, status, target, tracking,
                                                                         queue, params, response, error);
}

static void WolFoxLikeRequestDispatch(id receiver, SEL selector, int status, id target, id tracking, id queue,
                                      id params, int dispatch, id response, id error) {
    WolFoxLikeRequested(receiver, status, target);
    ((void (*)(id, SEL, int, id, id, id, id, int, id, id))OriginalLikeRequestDispatch)(
        receiver, selector, status, target, tracking, queue, params, dispatch, response, error);
}

void WolFoxInstallReturnDislikeHooks(void) {
    WolFoxShortsRefreshFlag();
    [NSNotificationCenter.defaultCenter addObserverForName:NSUserDefaultsDidChangeNotification object:nil
                                                     queue:nil usingBlock:^(__unused NSNotification *note) {
        WolFoxShortsRefreshFlag();
    }];
    WolFoxInstallInstanceHook(@"YTLikeServiceImpl", @"initWithAccountID:",
                              (IMP)WolFoxLikeServiceInit, &OriginalLikeServiceInit);
    WolFoxInstallInstanceHook(@"YTLikeServiceImpl",
        @"makeRequestWithStatus:target:clickTrackingParams:queueContextParams:requestParams:responseBlock:errorBlock:",
        (IMP)WolFoxLikeRequest, &OriginalLikeRequest);
    WolFoxInstallInstanceHook(@"YTLikeServiceImpl",
        @"makeRequestWithStatus:target:clickTrackingParams:queueContextParams:requestParams:requestDispatchType:responseBlock:errorBlock:",
        (IMP)WolFoxLikeRequestDispatch, &OriginalLikeRequestDispatch);
    WolFoxInstallInstanceHook(@"YTRollingNumberNode", @"updateRollingNumberView",
                              (IMP)WolFoxRollingUpdate, &OriginalRollingUpdate);
    WolFoxInstallInstanceHook(@"YTRollingNumberNode", @"prepareInitialRollingNumberView",
                              (IMP)WolFoxRollingPrepare, &OriginalRollingPrepare);
    WolFoxInstallInstanceHook(@"YTRollingNumberNode", @"layout",
                              (IMP)WolFoxRollingLayout, &OriginalRollingLayout);
    WolFoxInstallInstanceHook(@"YTRollingNumberNode", @"calculateSizeThatFits:",
                              (IMP)WolFoxRollingSize, &OriginalRollingSize);
    WolFoxInstallInstanceHook(@"ASDisplayNode", @"addYogaChild:",
                              (IMP)WolFoxNodeAddYogaChild, &OriginalNodeAddYogaChild);
    WolFoxInstallInstanceHook(@"ASDisplayNode", @"insertYogaChild:atIndex:",
                              (IMP)WolFoxNodeInsertYogaChild, &OriginalNodeInsertYogaChild);
    WolFoxInstallInstanceHook(@"ASDisplayNode", @"setYogaChildren:",
                              (IMP)WolFoxNodeSetYogaChildren, &OriginalNodeSetYogaChildren);
}
