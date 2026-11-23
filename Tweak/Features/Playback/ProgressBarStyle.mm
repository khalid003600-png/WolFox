#import "../Downloads/DownloadLog.h"
#import "../../WolFox.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <math.h>
#import <objc/message.h>
#import <objc/runtime.h>

static NSString * const WolFoxProgressStyleKey = @"YTKACE.Preference.Progress.Style";
static NSString * const WolFoxProgressMainColorKey = @"YTKACE.Preference.Progress.MainColor";
static NSString * const WolFoxProgressGradientColorKey = @"YTKACE.Preference.Progress.HighlightColor";
static NSString * const WolFoxProgressScrubberColorKey = @"YTKACE.Preference.Progress.ScrubberColor";

static IMP OriginalDecorationViewColor;
static IMP OriginalDecorationControllerColor;
static IMP OriginalContainerQuietColor;
static IMP OriginalScrubberDotColorV1;
static IMP OriginalScrubberDotColorV2;
static IMP OriginalSetScrubberDotColor;
static IMP OriginalSetScrubberDotColorV1;
static IMP OriginalSetScrubberDotColorV2;

static UIColor *WolFoxProgressColorFromHex(NSString *hex, UIColor *fallback) {
    if (![hex isKindOfClass:NSString.class]) return fallback;
    NSString *value = [[hex stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet]
        stringByReplacingOccurrencesOfString:@"#" withString:@""];
    if (value.length != 6) return fallback;
    unsigned int rgb = 0;
    if (![[NSScanner scannerWithString:value] scanHexInt:&rgb]) return fallback;
    return [UIColor colorWithRed:((rgb >> 16) & 0xFF) / 255.0
                           green:((rgb >> 8) & 0xFF) / 255.0
                            blue:(rgb & 0xFF) / 255.0
                           alpha:1.0];
}

static NSInteger WolFoxStyleCache = -1;
static NSMutableDictionary<NSString *, UIColor *> *WolFoxPatternCache = nil;
static NSMutableDictionary<NSString *, UIImage *> *WolFoxStripCache = nil;
static NSMutableDictionary<NSString *, UIColor *> *WolFoxColorCache = nil;
static NSUInteger WolFoxProgressGeneration = 0;
static NSUInteger WolFoxCachedGeneration = NSUIntegerMax;

static void WolFoxRelayoutBars(UIView *view, NSUInteger depth) {
    if (view == nil || depth > 14) return;
    NSString *name = NSStringFromClass(view.class);
    if ([name containsString:@"PlayerBar"] ||
        [name containsString:@"MiniplayerProgressBar"] ||
        [name isEqualToString:@"YTBrandGradientView"] ||
        [name isEqualToString:@"YTGridVideoCell"]) {
        [view setNeedsLayout];
        [view setNeedsDisplay];
    }
    for (UIView *subview in view.subviews) {
        WolFoxRelayoutBars(subview, depth + 1);
    }
}

static void WolFoxProgressSyncGeneration(void) {
    static dispatch_once_t observerToken;
    dispatch_once(&observerToken, ^{
        [NSNotificationCenter.defaultCenter
            addObserverForName:WolFoxPreferencesDidChangeNotification
                        object:nil
                         queue:NSOperationQueue.mainQueue
                    usingBlock:^(NSNotification *note) {
            NSString *key = note.userInfo[@"key"];
            if (![key hasPrefix:@"YTKACE.Preference.Progress."]) return;
            WolFoxProgressGeneration++;
            for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
                if (![scene isKindOfClass:UIWindowScene.class]) continue;
                for (UIWindow *window in ((UIWindowScene *)scene).windows) {
                    WolFoxRelayoutBars(window, 0);
                }
            }
        }];
    });
    if (WolFoxCachedGeneration == WolFoxProgressGeneration) return;
    WolFoxCachedGeneration = WolFoxProgressGeneration;
    WolFoxStyleCache = -1;
    WolFoxColorCache = nil;
    WolFoxPatternCache = nil;
    WolFoxStripCache = nil;
}

static NSInteger WolFoxProgressStyle(void) {
    WolFoxProgressSyncGeneration();
    if (WolFoxStyleCache >= 0) return WolFoxStyleCache;
    id value = WolFoxPreferenceObject(WolFoxProgressStyleKey);
    WolFoxStyleCache =
        [value respondsToSelector:@selector(integerValue)] ? [value integerValue] : 0;
    return WolFoxStyleCache;
}

static UIColor *WolFoxStoredColor(NSString *key, UIColor *fallback) {
    WolFoxProgressSyncGeneration();
    UIColor *hit = WolFoxColorCache[key];
    if (hit != nil) return hit;
    UIColor *value = WolFoxProgressColorFromHex(WolFoxPreferenceObject(key), fallback);
    if (WolFoxColorCache == nil) WolFoxColorCache = [NSMutableDictionary dictionary];
    if (value != nil) WolFoxColorCache[key] = value;
    return value;
}

static UIColor *WolFoxMainColor(void) {
    return WolFoxStoredColor(WolFoxProgressMainColorKey, UIColor.systemRedColor);
}

static UIColor *WolFoxPlayedColor(void) {
    UIColor *main = WolFoxMainColor();
    if (WolFoxProgressStyle() != 2) return main;
    UIColor *highlight = WolFoxStoredColor(WolFoxProgressGradientColorKey, main);
    static UIImage *cached = nil;
    static NSString *cachedKey = nil;
    NSString *key = [NSString stringWithFormat:@"%@|%@", main, highlight];
    if (cached == nil || ![key isEqualToString:cachedKey]) {
        CGSize size = CGSizeMake(CGRectGetWidth(UIScreen.mainScreen.bounds), 6.0);
        UIGraphicsImageRenderer *renderer =
            [[UIGraphicsImageRenderer alloc] initWithSize:size];
        cached = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
            CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
            NSArray *colors = @[(id)main.CGColor, (id)highlight.CGColor];
            CGFloat locations[] = {0.0, 1.0};
            CGGradientRef gradient = CGGradientCreateWithColors(
                space, (__bridge CFArrayRef)colors, locations);
            CGContextDrawLinearGradient(context.CGContext, gradient,
                                        CGPointZero, CGPointMake(size.width, 0.0), 0);
            CGGradientRelease(gradient);
            CGColorSpaceRelease(space);
        }];
        cachedKey = key;
    }
    return [UIColor colorWithPatternImage:cached];
}

static UIImage *WolFoxGradientStrip(CGFloat width, CGFloat height) {
    UIColor *main = WolFoxMainColor();
    UIColor *highlight = WolFoxStoredColor(WolFoxProgressGradientColorKey, main);
    NSString *stripKey = [NSString stringWithFormat:@"%.0f|%.0f|%@|%@",
                          width, height, main, highlight];
    UIImage *cachedStrip = WolFoxStripCache[stripKey];
    if (cachedStrip != nil) return cachedStrip;
    CGSize size = CGSizeMake(MAX(width, 1.0), MAX(height, 1.0));
    UIGraphicsImageRenderer *renderer =
        [[UIGraphicsImageRenderer alloc] initWithSize:size];
    UIImage *strip = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
        NSArray *colors = @[(id)main.CGColor, (id)highlight.CGColor];
        CGFloat locations[] = {0.0, 1.0};
        CGGradientRef gradient = CGGradientCreateWithColors(
            space, (__bridge CFArrayRef)colors, locations);
        CGContextDrawLinearGradient(context.CGContext, gradient,
                                    CGPointZero, CGPointMake(size.width, 0.0), 0);
        CGGradientRelease(gradient);
        CGColorSpaceRelease(space);
    }];
    if (WolFoxStripCache == nil) WolFoxStripCache = [NSMutableDictionary dictionary];
    if (WolFoxStripCache.count > 24) [WolFoxStripCache removeAllObjects];
    WolFoxStripCache[stripKey] = strip;
    return strip;
}

UIImage *WolFoxProgressFillImage(CGFloat width, CGFloat height) {
    if (!isfinite(width) || width <= 0.0) width = 1.0;
    if (!isfinite(height) || height <= 0.0) height = 1.0;
    CGSize size = CGSizeMake(MAX(width, 1.0), MAX(height, 1.0));
    NSInteger style = WolFoxProgressStyle();
    UIColor *start = nil;
    UIColor *end = nil;
    if (style == 1) {
        start = WolFoxMainColor();
        end = start;
    } else if (style == 2) {
        start = WolFoxMainColor();
        end = WolFoxStoredColor(WolFoxProgressGradientColorKey, start);
    } else {
        start = [UIColor colorWithRed:1.0 green:0.0 blue:0.0 alpha:1.0];
        end = [UIColor colorWithRed:1.0 green:0.29 blue:0.16 alpha:1.0];
    }
    NSString *key = [NSString stringWithFormat:@"fill|%.0f|%.0f|%ld|%@|%@",
                     size.width, size.height, (long)style, start, end];
    UIImage *cached = WolFoxStripCache[key];
    if (cached != nil) return cached;
    UIGraphicsImageRenderer *renderer =
        [[UIGraphicsImageRenderer alloc] initWithSize:size];
    UIImage *image = [renderer imageWithActions:
        ^(UIGraphicsImageRendererContext *context) {
        CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
        NSArray *colors = @[(id)start.CGColor, (id)end.CGColor];
        CGFloat locations[] = {0.0, 1.0};
        CGGradientRef gradient = CGGradientCreateWithColors(
            space, (__bridge CFArrayRef)colors, locations);
        CGContextDrawLinearGradient(context.CGContext, gradient, CGPointZero,
                                    CGPointMake(size.width, 0.0), 0);
        CGGradientRelease(gradient);
        CGColorSpaceRelease(space);
    }];
    if (WolFoxStripCache == nil) WolFoxStripCache = [NSMutableDictionary dictionary];
    if (WolFoxStripCache.count > 40) [WolFoxStripCache removeAllObjects];
    WolFoxStripCache[key] = image;
    return image;
}

static UIView *WolFoxBarAncestor(UIView *view) {
    UIView *node = view;
    while (node != nil) {
        NSString *name = NSStringFromClass(node.class);
        if ([name isEqualToString:@"YTModularPlayerBarView"] ||
            [name isEqualToString:@"YTInlinePlayerBarContainerView"]) {
            return node;
        }
        node = node.superview;
    }
    return view.superview ?: view;
}

static UIColor *WolFoxPlayedColorForView(id receiver) {
    if (WolFoxProgressStyle() != 2) return WolFoxMainColor();
    if (![receiver isKindOfClass:UIView.class]) return WolFoxPlayedColor();
    UIView *view = (UIView *)receiver;
    UIView *bar = WolFoxBarAncestor(view);
    CGFloat barWidth = CGRectGetWidth(bar.bounds);
    CGFloat viewWidth = CGRectGetWidth(view.bounds);
    CGFloat height = MAX(CGRectGetHeight(view.bounds), 2.0);
    if (barWidth < 2.0 || viewWidth < 1.0) return WolFoxPlayedColor();
    CGRect inBar = [view convertRect:view.bounds toView:bar];
    CGFloat offset = CGRectGetMinX(inBar);
    if (offset < 0.0) offset = 0.0;
    if (barWidth - offset < viewWidth) barWidth = offset + viewWidth;

    NSString *patternKey = [NSString stringWithFormat:@"%.0f|%.0f|%.0f|%.0f",
                            offset, viewWidth, height, barWidth];
    UIColor *cachedPattern = WolFoxPatternCache[patternKey];
    if (cachedPattern != nil) return cachedPattern;
    CGFloat scale = UIScreen.mainScreen.scale;
    UIImage *full = WolFoxGradientStrip(barWidth, height);
    CGRect crop = CGRectMake(offset * scale, 0.0,
                             viewWidth * scale, height * scale);
    CGImageRef slice = CGImageCreateWithImageInRect(full.CGImage, crop);
    if (slice == NULL) return WolFoxPlayedColor();
    UIImage *tile = [UIImage imageWithCGImage:slice
                                        scale:scale
                                  orientation:UIImageOrientationUp];
    CGImageRelease(slice);
    UIColor *pattern = [UIColor colorWithPatternImage:tile];
    if (WolFoxPatternCache == nil) WolFoxPatternCache = [NSMutableDictionary dictionary];
    if (WolFoxPatternCache.count > 96) [WolFoxPatternCache removeAllObjects];
    WolFoxPatternCache[patternKey] = pattern;
    return pattern;
}

static UIColor *WolFoxScrubberColor(void) {
    return WolFoxStoredColor(WolFoxProgressScrubberColorKey, WolFoxMainColor());
}

UIColor *WolFoxProgressScrubberTint(void) {
    UIColor *tint = WolFoxProgressStyle() != 0 ? WolFoxScrubberColor()
        : [UIColor colorWithRed:1.0 green:0.0 blue:0.0 alpha:1.0];
    static NSString *logged;
    NSString *state = [NSString stringWithFormat:@"style=%ld main=%@ highlight=%@ scrubber=%@",
                       (long)WolFoxProgressStyle(), WolFoxPreferenceObject(WolFoxProgressMainColorKey),
                       WolFoxPreferenceObject(WolFoxProgressGradientColorKey),
                       WolFoxPreferenceObject(WolFoxProgressScrubberColorKey)];
    if (![state isEqualToString:logged]) {
        logged = state;
    }
    return tint;
}


static id WolFoxDecorationViewColor(id receiver, SEL selector) {
    if (WolFoxProgressStyle() != 0) return WolFoxPlayedColorForView(receiver);
    return OriginalDecorationViewColor == NULL ? nil :
        ((id (*)(id, SEL))OriginalDecorationViewColor)(receiver, selector);
}

static id WolFoxDecorationControllerColor(id receiver, SEL selector) {
    if (WolFoxProgressStyle() != 0) return WolFoxPlayedColor();
    return OriginalDecorationControllerColor == NULL ? nil :
        ((id (*)(id, SEL))OriginalDecorationControllerColor)(receiver, selector);
}

static id WolFoxContainerQuietColor(id receiver, SEL selector) {
    if (WolFoxProgressStyle() != 0) return WolFoxPlayedColor();
    return OriginalContainerQuietColor == NULL ? nil :
        ((id (*)(id, SEL))OriginalContainerQuietColor)(receiver, selector);
}


static id WolFoxDotColorV1(id receiver, SEL selector) {
    if (WolFoxProgressStyle() != 0) return WolFoxScrubberColor();
    return OriginalScrubberDotColorV1 == NULL ? nil :
        ((id (*)(id, SEL))OriginalScrubberDotColorV1)(receiver, selector);
}

static id WolFoxDotColorV2(id receiver, SEL selector) {
    if (WolFoxProgressStyle() != 0) return WolFoxScrubberColor();
    return OriginalScrubberDotColorV2 == NULL ? nil :
        ((id (*)(id, SEL))OriginalScrubberDotColorV2)(receiver, selector);
}

static void WolFoxSetDotColor(id receiver, SEL selector, id color) {
    id replacement = WolFoxProgressStyle() != 0 ? WolFoxScrubberColor() : color;
    if (OriginalSetScrubberDotColor != NULL) {
        ((void (*)(id, SEL, id))OriginalSetScrubberDotColor)(receiver, selector, replacement);
    }
}

static void WolFoxSetDotColorV1(id receiver, SEL selector, id color) {
    id replacement = WolFoxProgressStyle() != 0 ? WolFoxScrubberColor() : color;
    if (OriginalSetScrubberDotColorV1 != NULL) {
        ((void (*)(id, SEL, id))OriginalSetScrubberDotColorV1)(receiver, selector, replacement);
    }
}

static void WolFoxSetDotColorV2(id receiver, SEL selector, id color) {
    id replacement = WolFoxProgressStyle() != 0 ? WolFoxScrubberColor() : color;
    if (OriginalSetScrubberDotColorV2 != NULL) {
        ((void (*)(id, SEL, id))OriginalSetScrubberDotColorV2)(receiver, selector, replacement);
    }
}

static IMP OriginalModularBarLayout;
static IMP OriginalDrawProgressRectWithColor;
static IMP OriginalDecorationDrawRect;
static IMP OriginalDrawProgressRect;
static IMP OriginalDrawRectDecorationProgress;
static IMP OriginalDrawRectDecoration;
static IMP OriginalSegmentedLayout;

static UIImage *WolFoxThumbBarImage(CGFloat width, CGFloat height,
                                    CGFloat trackWidth);

static BOOL WolFoxColorIsYouTubeRed(CGColorRef color) {
    if (color == NULL) return NO;
    const CGFloat *components = CGColorGetComponents(color);
    if (components == NULL || CGColorGetNumberOfComponents(color) < 3) return NO;
    return components[0] > 0.6 && components[1] < 0.4 && components[2] < 0.4;
}

static void WolFoxApplyLayerFill(CALayer *layer, UIColor *colour,
                                 CGFloat width, CGFloat height) {
    if (colour == nil) return;
    CGColorRef reference = colour.CGColor;
    if (CGColorGetPattern(reference) == NULL) {
        layer.backgroundColor = reference;
        return;
    }
    CGFloat track = CGRectGetWidth(layer.superlayer.bounds);
    if (track < width) track = width;
    UIImage *fill = WolFoxThumbBarImage(width, height, track);
    layer.backgroundColor = WolFoxMainColor().CGColor;
    if (fill.CGImage != NULL) {
        layer.contents = (__bridge id)fill.CGImage;
        layer.contentsScale = fill.scale;
        layer.contentsGravity = kCAGravityResize;
    }
}

static void WolFoxPaintLayers(CALayer *layer, UIColor *played, UIColor *dot,
                              NSUInteger depth) {
    if (layer == nil || depth > 7) return;
    CGRect bounds = layer.bounds;
    CGFloat width = CGRectGetWidth(bounds);
    CGFloat height = CGRectGetHeight(bounds);
    if (width > 0.0 && height > 0.0 && WolFoxColorIsYouTubeRed(layer.backgroundColor)) {
        WolFoxApplyLayerFill(layer, (width <= height + 2.0) ? dot : played,
                             width, height);
    }
    for (CALayer *sublayer in layer.sublayers) {
        WolFoxPaintLayers(sublayer, played, dot, depth + 1);
    }
}

static void WolFoxModularBarLayout(UIView *receiver, SEL selector) {
    if (OriginalModularBarLayout != NULL) {
        ((void (*)(id, SEL))OriginalModularBarLayout)(receiver, selector);
    }
    if (WolFoxProgressStyle() == 0) return;
    WolFoxPaintLayers(receiver.layer, WolFoxPlayedColor(), WolFoxScrubberColor(), 0);
    UIView *node = receiver;
    while (node != nil) {
        if ([NSStringFromClass(node.class)
                isEqualToString:@"YTInlinePlayerBarContainerView"]) {
            SEL setter = NSSelectorFromString(@"setPlayedProgressBarColor:");
            if ([node respondsToSelector:setter]) {
                ((void (*)(id, SEL, id))objc_msgSend)(node, setter, WolFoxPlayedColor());
            }
            WolFoxPaintLayers(node.layer, WolFoxPlayedColor(), WolFoxScrubberColor(), 0);
            break;
        }
        node = node.superview;
    }
}

static BOOL WolFoxDrawGradientInRect(id receiver, CGRect rect) {
    if (WolFoxProgressStyle() != 2) return NO;
    CGContextRef context = UIGraphicsGetCurrentContext();
    if (context == NULL || ![receiver isKindOfClass:UIView.class]) return NO;
    CGFloat height = CGRectGetHeight(rect);
    if (height < 0.5 || CGRectGetWidth(rect) < 0.5) return NO;

    UIView *view = (UIView *)receiver;
    UIView *bar = WolFoxBarAncestor(view);
    CGFloat track = CGRectGetWidth(bar.bounds);
    CGFloat own = CGRectGetWidth(view.bounds);
    if (track < own) track = own;
    if (track < 2.0) return NO;

    CGRect inBar = [view convertRect:view.bounds toView:bar];
    CGFloat offset = CGRectGetMinX(inBar);
    if (offset < 0.0 || offset > track) offset = 0.0;

    UIImage *strip = WolFoxGradientStrip(track, height);
    if (strip == nil) return NO;

    CGContextSaveGState(context);
    CGContextClipToRect(context, rect);
    [strip drawInRect:CGRectMake(-offset, CGRectGetMinY(rect), track, height)];
    CGContextRestoreGState(context);
    return YES;
}

static void WolFoxDrawProgressRectWithColor(id receiver, SEL selector,
                                            CGRect rect, id color) {
    if (WolFoxDrawGradientInRect(receiver, rect)) return;
    id replacement = WolFoxProgressStyle() != 0 ? WolFoxMainColor() : color;
    if (OriginalDrawProgressRectWithColor != NULL) {
        ((void (*)(id, SEL, CGRect, id))OriginalDrawProgressRectWithColor)(
            receiver, selector, rect, replacement);
    }
}

static void WolFoxForceBarColor(id receiver) {
    if (WolFoxProgressStyle() == 0) return;
    SEL setter = NSSelectorFromString(@"setPlayedProgressBarColor:");
    if (![receiver respondsToSelector:setter]) return;
    UIColor *colour = WolFoxPlayedColorForView(receiver);
    if (CGColorGetPattern(colour.CGColor) != NULL) {
        colour = WolFoxMainColor();
    }
    ((void (*)(id, SEL, id))objc_msgSend)(receiver, setter, colour);
}

static void WolFoxDecorationDrawRect(id receiver, SEL selector, CGRect rect) {
    WolFoxForceBarColor(receiver);
    if (OriginalDecorationDrawRect != NULL) {
        ((void (*)(id, SEL, CGRect))OriginalDecorationDrawRect)(receiver, selector, rect);
    }
}

static void WolFoxRecolorSegments(id receiver) {
    if (WolFoxProgressStyle() == 0) return;
    if (![receiver isKindOfClass:UIView.class]) return;
    WolFoxPaintLayers(((UIView *)receiver).layer,
                      WolFoxPlayedColor(), WolFoxScrubberColor(), 0);
    SEL segments = NSSelectorFromString(@"segmentViews");
    if (![receiver respondsToSelector:segments]) return;
    NSArray *views = ((id (*)(id, SEL))objc_msgSend)(receiver, segments);
    if (![views isKindOfClass:NSArray.class]) return;
    for (id view in views) {
        if ([view isKindOfClass:UIView.class]) {
            WolFoxPaintLayers(((UIView *)view).layer,
                              WolFoxPlayedColor(), WolFoxScrubberColor(), 0);
        }
    }
}


static void WolFoxSegmentedLayout(id receiver, SEL selector) {
    if (OriginalSegmentedLayout != NULL) {
        ((void (*)(id, SEL))OriginalSegmentedLayout)(receiver, selector);
    }
    WolFoxRecolorSegments(receiver);
}


static void WolFoxDrawProgressRect(id receiver, SEL selector, CGRect rect) {
    if (WolFoxDrawGradientInRect(receiver, rect)) return;
    WolFoxForceBarColor(receiver);
    if (OriginalDrawProgressRect != NULL) {
        ((void (*)(id, SEL, CGRect))OriginalDrawProgressRect)(receiver, selector, rect);
    }
}

static void WolFoxDrawRectDecorationProgress(id receiver, SEL selector, CGRect rect) {
    WolFoxForceBarColor(receiver);
    if (OriginalDrawRectDecorationProgress != NULL) {
        ((void (*)(id, SEL, CGRect))OriginalDrawRectDecorationProgress)(
            receiver, selector, rect);
    }
}

static void WolFoxDrawRectDecoration(id receiver, SEL selector, CGRect rect) {
    WolFoxForceBarColor(receiver);
    if (OriginalDrawRectDecoration != NULL) {
        ((void (*)(id, SEL, CGRect))OriginalDrawRectDecoration)(receiver, selector, rect);
    }
}

static UIView *WolFoxFindProgressView(UIView *view, NSUInteger depth) {
    if (view == nil || depth > 4) return nil;
    if ([NSStringFromClass(view.class) isEqualToString:@"YTProgressView"]) return view;
    for (UIView *subview in view.subviews) {
        UIView *found = WolFoxFindProgressView(subview, depth + 1);
        if (found != nil) return found;
    }
    return nil;
}

void WolFoxStyleProgressLayer(CALayer *layer, CGFloat trackWidth) {
    if (layer == nil) return;
    if (WolFoxProgressStyle() == 0) return;
    CGFloat width = CGRectGetWidth(layer.bounds);
    CGFloat height = CGRectGetHeight(layer.bounds);
    if (width < 1.0 || height < 1.0) return;
    if (trackWidth < width) trackWidth = width;
    if (WolFoxProgressStyle() == 2) {
        UIImage *fill = WolFoxThumbBarImage(width, height, trackWidth);
        layer.backgroundColor = WolFoxMainColor().CGColor;
        if (fill.CGImage != NULL) {
            layer.contents = (__bridge id)fill.CGImage;
            layer.contentsScale = fill.scale;
            layer.contentsGravity = kCAGravityResize;
        }
    } else {
        layer.contents = nil;
        layer.backgroundColor = WolFoxMainColor().CGColor;
    }
}

void WolFoxApplyProgressStyleToBar(UIView *bar) {
    if (WolFoxProgressStyle() == 0 || ![bar isKindOfClass:UIView.class]) return;
    UIView *progress = WolFoxFindProgressView(bar, 0);
    if (progress == nil) return;

    SEL brand = NSSelectorFromString(@"setBrandGradientEnabled:");
    if ([progress respondsToSelector:brand]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(progress, brand, NO);
    }

    UIColor *color = WolFoxMainColor();
    CGFloat width = CGRectGetWidth(bar.bounds);
    CGFloat height = MAX(CGRectGetHeight(progress.bounds), 2.0);
    if (WolFoxProgressStyle() == 2 && width > 2.0) {
        color = [UIColor colorWithPatternImage:WolFoxGradientStrip(width, height)];
    }
    SEL setter = NSSelectorFromString(@"setProgressBarColor:");
    if ([progress respondsToSelector:setter]) {
        ((void (*)(id, SEL, id))objc_msgSend)(progress, setter, color);
    }
    WolFoxPaintLayers(progress.layer, color, WolFoxScrubberColor(), 0);
}

static IMP OriginalThumbBarLayout;
static IMP OriginalThumbContainerLayout;
static const void *WolFoxThumbBarFillAssociation = &WolFoxThumbBarFillAssociation;
static const void *WolFoxThumbBarGenerationAssociation =
    &WolFoxThumbBarGenerationAssociation;

static const void *WolFoxThumbGeneratedAssociation =
    &WolFoxThumbGeneratedAssociation;
static const void *WolFoxBarTouchedAssociation = &WolFoxBarTouchedAssociation;

static CGFloat WolFoxThumbTrackWidth(id node, CGFloat fillWidth,
                                     CGFloat fillHeight) {
    CGFloat track = fillWidth;
    SEL supernode = NSSelectorFromString(@"supernode");
    id parent = node;
    for (NSUInteger depth = 0; depth < 4; depth++) {
        if (![parent respondsToSelector:supernode]) break;
        parent = ((id (*)(id, SEL))objc_msgSend)(parent, supernode);
        if (parent == nil) break;
        CGRect bounds = ((CGRect (*)(id, SEL))objc_msgSend)(
            parent, NSSelectorFromString(@"bounds"));
        if (fabs(CGRectGetHeight(bounds) - fillHeight) > 1.5) continue;
        if (CGRectGetWidth(bounds) > track) track = CGRectGetWidth(bounds);
    }
    return track;
}

static UIImage *WolFoxThumbBarImage(CGFloat width, CGFloat height,
                                    CGFloat trackWidth) {
    if (WolFoxProgressStyle() == 2) {
        if (trackWidth <= width + 1.0) return WolFoxGradientStrip(width, height);
        NSString *sliceKey = [NSString stringWithFormat:@"thumb|%.0f|%.0f|%.0f|%@|%@",
                              width, height, trackWidth, WolFoxMainColor(),
                              WolFoxStoredColor(WolFoxProgressGradientColorKey,
                                                WolFoxMainColor())];
        UIImage *cachedSlice = WolFoxStripCache[sliceKey];
        if (cachedSlice != nil) return cachedSlice;
        UIImage *full = WolFoxGradientStrip(trackWidth, height);
        CGFloat scale = full.scale;
        CGImageRef cropped = CGImageCreateWithImageInRect(
            full.CGImage, CGRectMake(0.0, 0.0, width * scale, height * scale));
        if (cropped == NULL) return WolFoxGradientStrip(width, height);
        UIImage *slice = [UIImage imageWithCGImage:cropped
                                             scale:scale
                                       orientation:UIImageOrientationUp];
        CGImageRelease(cropped);
        if (WolFoxStripCache == nil) WolFoxStripCache = [NSMutableDictionary dictionary];
        if (WolFoxStripCache.count > 24) [WolFoxStripCache removeAllObjects];
        objc_setAssociatedObject(slice, WolFoxThumbGeneratedAssociation, @YES,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        WolFoxStripCache[sliceKey] = slice;
        return slice;
    }
    UIColor *main = WolFoxMainColor();
    NSString *key = [NSString stringWithFormat:@"solid|%.0f|%.0f|%@",
                     width, height, main];
    UIImage *cached = WolFoxStripCache[key];
    if (cached != nil) return cached;
    CGSize size = CGSizeMake(MAX(width, 1.0), MAX(height, 1.0));
    UIGraphicsImageRenderer *renderer =
        [[UIGraphicsImageRenderer alloc] initWithSize:size];
    UIImage *image = [renderer imageWithActions:
        ^(UIGraphicsImageRendererContext *context) {
        [main setFill];
        CGRect rect = CGRectMake(0.0, 0.0, size.width, size.height);
        [[UIBezierPath bezierPathWithRoundedRect:rect
                                    cornerRadius:size.height / 2.0] fill];
        (void)context;
    }];
    if (WolFoxStripCache == nil) WolFoxStripCache = [NSMutableDictionary dictionary];
    if (WolFoxStripCache.count > 24) [WolFoxStripCache removeAllObjects];
    objc_setAssociatedObject(image, WolFoxThumbGeneratedAssociation, @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    WolFoxStripCache[key] = image;
    return image;
}

static void WolFoxThumbBarApply(id node) {
    if (WolFoxProgressStyle() == 0) return;

    CGRect bounds = ((CGRect (*)(id, SEL))objc_msgSend)(
        node, NSSelectorFromString(@"bounds"));
    CGFloat width = CGRectGetWidth(bounds);
    CGFloat height = CGRectGetHeight(bounds);

    NSString *name = NSStringFromClass([node class]);
    SEL imageGetter = NSSelectorFromString(@"image");
    SEL imageSetter = NSSelectorFromString(@"setImage:");
    UIImage *current = [node respondsToSelector:imageGetter]
        ? ((id (*)(id, SEL))objc_msgSend)(node, imageGetter) : nil;

    if (height < 1.0 || height > 4.0 || width < 8.0) return;
    if (![name isEqualToString:@"ELMImageNode"]) return;
    if (![node respondsToSelector:imageSetter]) return;
    if (current == nil) return;

    BOOL ours = objc_getAssociatedObject(
        current, WolFoxThumbGeneratedAssociation) != nil;
    NSNumber *appliedWidth = objc_getAssociatedObject(
        node, WolFoxThumbBarFillAssociation);
    NSNumber *applied = objc_getAssociatedObject(
        node, WolFoxThumbBarGenerationAssociation);
    if (ours && applied != nil &&
        applied.unsignedIntegerValue == WolFoxProgressGeneration &&
        appliedWidth != nil &&
        fabs(appliedWidth.doubleValue - width) < 1.0) return;

    UIImage *replacement = WolFoxThumbBarImage(
        width, height, WolFoxThumbTrackWidth(node, width, height));
    if (current == replacement) return;

    SEL modifier = NSSelectorFromString(@"imageModificationBlock");
    SEL setModifier = NSSelectorFromString(@"setImageModificationBlock:");
    BOOL hadModifier = NO;
    if ([node respondsToSelector:modifier]) {
        hadModifier = ((id (*)(id, SEL))objc_msgSend)(node, modifier) != nil;
    }
    if (hadModifier && [node respondsToSelector:setModifier]) {
        ((void (*)(id, SEL, id))objc_msgSend)(node, setModifier, nil);
    }
    SEL setTint = NSSelectorFromString(@"setTintColor:");
    if ([node respondsToSelector:NSSelectorFromString(@"tintColor")] &&
        [node respondsToSelector:setTint]) {
        ((void (*)(id, SEL, id))objc_msgSend)(
            node, setTint, WolFoxProgressStyle() == 2
                ? WolFoxStoredColor(WolFoxProgressGradientColorKey,
                                    WolFoxMainColor())
                : WolFoxMainColor());
    }

    ((void (*)(id, SEL, id))objc_msgSend)(node, imageSetter, replacement);
    SEL redisplay = NSSelectorFromString(@"setNeedsDisplay");
    if ([node respondsToSelector:redisplay]) {
        __weak id weakNode = node;
        dispatch_async(dispatch_get_main_queue(), ^{
            id strongNode = weakNode;
            if (strongNode == nil) return;
            UIImage *shown = ((id (*)(id, SEL))objc_msgSend)(
                strongNode, NSSelectorFromString(@"image"));
            if (objc_getAssociatedObject(
                    shown, WolFoxThumbGeneratedAssociation) == nil) return;
            ((void (*)(id, SEL))objc_msgSend)(strongNode, redisplay);
        });
    }
    objc_setAssociatedObject(node, WolFoxThumbBarFillAssociation, @(width),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(node, WolFoxThumbBarGenerationAssociation,
                             @(WolFoxProgressGeneration),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

}

static void WolFoxThumbBarLayout(id node, SEL selector) {
    if (OriginalThumbBarLayout != NULL) {
        ((void (*)(id, SEL))OriginalThumbBarLayout)(node, selector);
    }
    WolFoxThumbBarApply(node);
}

static IMP OriginalThumbVisible;
static IMP OriginalThumbDisplayWillStart;

static void WolFoxThumbDisplayWillStart(id node, SEL selector) {
    if (OriginalThumbDisplayWillStart != NULL) {
        ((void (*)(id, SEL))OriginalThumbDisplayWillStart)(node, selector);
    }
    WolFoxThumbBarApply(node);
}

static void WolFoxThumbDidEnterVisible(id node, SEL selector) {
    if (OriginalThumbVisible != NULL) {
        ((void (*)(id, SEL))OriginalThumbVisible)(node, selector);
    }
    WolFoxThumbBarApply(node);
}

static void WolFoxThumbContainerLayout(id node, SEL selector) {
    if (OriginalThumbContainerLayout != NULL) {
        ((void (*)(id, SEL))OriginalThumbContainerLayout)(node, selector);
    }
    WolFoxThumbBarApply(node);
}

static IMP OriginalInlineScrubberLayout;
static IMP OriginalInlinePostScrubberLayout;

static void WolFoxTintInlineSliders(UIView *view, NSUInteger depth) {
    if (view == nil || depth > 4) return;
    if ([view isKindOfClass:UISlider.class]) {
        UISlider *slider = (UISlider *)view;
        UIColor *dot = WolFoxScrubberColor();
        UIImage *thumb = [slider thumbImageForState:UIControlStateNormal];
        if (thumb == nil) {
            if (CGColorGetPattern(dot.CGColor) == NULL) slider.thumbTintColor = dot;
        } else {
            if (thumb.renderingMode != UIImageRenderingModeAlwaysTemplate) {
                [slider setThumbImage:
                    [thumb imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate]
                             forState:UIControlStateNormal];
            }
            slider.tintColor = dot;
        }
        UIColor *played = WolFoxMainColor();
        if (CGColorGetPattern(played.CGColor) == NULL) {
            slider.minimumTrackTintColor = played;
        }
    }
    for (UIView *subview in view.subviews) {
        WolFoxTintInlineSliders(subview, depth + 1);
    }
}

static void WolFoxInlineScrubberLayout(UIView *receiver, SEL selector) {
    if (OriginalInlineScrubberLayout != NULL) {
        ((void (*)(id, SEL))OriginalInlineScrubberLayout)(receiver, selector);
    }
    if (WolFoxProgressStyle() == 0) return;
    WolFoxTintInlineSliders(receiver, 0);
}

static void WolFoxInlinePostScrubberLayout(UIView *receiver, SEL selector) {
    if (OriginalInlinePostScrubberLayout != NULL) {
        ((void (*)(id, SEL))OriginalInlinePostScrubberLayout)(receiver, selector);
    }
    if (WolFoxProgressStyle() == 0) return;
    WolFoxTintInlineSliders(receiver, 0);
}

static NSUInteger WolFoxInstallProgressHookSet(void) {
    NSUInteger landed = 0;
    struct { const char *cls; const char *sel; IMP replacement; IMP *storage; } entries[] = {
        {"YTPlayerBarProgressDecorationView", "playedProgressBarColor",
         (IMP)WolFoxDecorationViewColor, &OriginalDecorationViewColor},
        {"YTPlayerBarProgressDecorationController", "playedProgressBarColor",
         (IMP)WolFoxDecorationControllerColor, &OriginalDecorationControllerColor},
        {"YTInlinePlayerBarContainerView", "quietProgressBarColor",
         (IMP)WolFoxContainerQuietColor, &OriginalContainerQuietColor},
        {"YTPlayerBarScrubberDotDecorationViewV1", "scrubberDotColor",
         (IMP)WolFoxDotColorV1, &OriginalScrubberDotColorV1},
        {"YTPlayerBarScrubberDotDecorationViewV2", "scrubberDotColor",
         (IMP)WolFoxDotColorV2, &OriginalScrubberDotColorV2},
        {"YTPlayerBarScrubberDotDecorationView", "setScrubberDotColor:",
         (IMP)WolFoxSetDotColor, &OriginalSetScrubberDotColor},
        {"YTPlayerBarScrubberDotDecorationViewV1", "setScrubberDotColor:",
         (IMP)WolFoxSetDotColorV1, &OriginalSetScrubberDotColorV1},
        {"YTPlayerBarScrubberDotDecorationViewV2", "setScrubberDotColor:",
         (IMP)WolFoxSetDotColorV2, &OriginalSetScrubberDotColorV2},
        {"YTModularPlayerBarView", "layoutSubviews",
         (IMP)WolFoxModularBarLayout, &OriginalModularBarLayout},
        {"YTPlayerBarProgressDecorationView", "drawProgressRect:withColor:",
         (IMP)WolFoxDrawProgressRectWithColor, &OriginalDrawProgressRectWithColor},
        {"YTPlayerBarProgressDecorationView", "drawRect:",
         (IMP)WolFoxDecorationDrawRect, &OriginalDecorationDrawRect},
        {"YTPlayerBarScrubberDotDecorationViewV1", "layoutSubviews",
         (IMP)WolFoxSegmentedLayout, &OriginalSegmentedLayout},
        {"YTPlayerBarProgressDecorationView", "drawProgressRect:",
         (IMP)WolFoxDrawProgressRect, &OriginalDrawProgressRect},
        {"YTPlayerBarProgressDecorationView", "drawRectangleDecorationWithProgress:",
         (IMP)WolFoxDrawRectDecorationProgress, &OriginalDrawRectDecorationProgress},
        {"YTPlayerBarProgressDecorationView", "drawRectangleDecoration:",
         (IMP)WolFoxDrawRectDecoration, &OriginalDrawRectDecoration},
        {"YTInlineMutedPlaybackScrubberView", "layoutSubviews",
         (IMP)WolFoxInlineScrubberLayout, &OriginalInlineScrubberLayout},
        {"YTInlineMutedPlaybackPostVideoScrubberView", "layoutSubviews",
         (IMP)WolFoxInlinePostScrubberLayout, &OriginalInlinePostScrubberLayout}
    };
    for (size_t i = 0; i < sizeof(entries) / sizeof(entries[0]); i++) {
        NSString *cls = @(entries[i].cls);
        NSString *sel = @(entries[i].sel);
        BOOL ok = WolFoxInstallInstanceHook(cls, sel, entries[i].replacement,
                                            entries[i].storage);
        if (ok) landed++;
    }
    return landed;
}

static BOOL WolFoxCGImageIsRed(CGImageRef bitmap) {
    if (bitmap == NULL) return NO;
    size_t pixelWidth = CGImageGetWidth(bitmap);
    size_t pixelHeight = CGImageGetHeight(bitmap);
    if (pixelWidth == 0 || pixelHeight == 0) return NO;
    unsigned char pixel[4] = {0, 0, 0, 0};
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(
        pixel, 1, 1, 8, 4, space,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(space);
    if (context == NULL) return NO;
    CGContextDrawImage(context,
                       CGRectMake(-(CGFloat)(pixelWidth / 2),
                                  -(CGFloat)(pixelHeight / 2),
                                  (CGFloat)pixelWidth, (CGFloat)pixelHeight),
                       bitmap);
    CGContextRelease(context);
    return pixel[3] > 100 && pixel[0] > 120 &&
           pixel[1] < 100 && pixel[2] < 100;
}

static BOOL WolFoxColourIsRed(CGColorRef colour) {
    if (colour == NULL) return NO;
    size_t count = CGColorGetNumberOfComponents(colour);
    const CGFloat *parts = CGColorGetComponents(colour);
    if (parts == NULL || count < 4) return NO;
    return parts[3] > 0.4 && parts[0] > 0.5 && parts[1] < 0.4 && parts[2] < 0.4;
}

static void WolFoxRecolourRedBars(CALayer *layer, NSUInteger depth,
                                  UIView *host, NSString *trail) {
    if (layer == nil || depth > 8) return;
    CGFloat width = CGRectGetWidth(layer.bounds);
    CGFloat height = CGRectGetHeight(layer.bounds);
    if (height >= 1.0 && height <= 6.0 && width >= 6.0) {
        BOOL redBackground = WolFoxColourIsRed(layer.backgroundColor);
        CGImageRef drawn = (__bridge CGImageRef)layer.contents;
        BOOL redContents = drawn != NULL &&
            CFGetTypeID(drawn) == CGImageGetTypeID() &&
            WolFoxCGImageIsRed(drawn);
        NSNumber *touched = objc_getAssociatedObject(
            layer, WolFoxBarTouchedAssociation);
        BOOL stale = touched != nil &&
            touched.unsignedIntegerValue != WolFoxProgressGeneration;
        if (redBackground || redContents || stale) {
            CGFloat track = CGRectGetWidth(layer.superlayer.bounds);
            if (track < width) track = width;
            UIImage *fill = WolFoxThumbBarImage(width, height, track);
            layer.backgroundColor = WolFoxMainColor().CGColor;
            layer.cornerRadius = height / 2.0;
            if (WolFoxProgressStyle() == 2 && fill.CGImage != NULL) {
                layer.contents = (__bridge id)fill.CGImage;
                layer.contentsScale = fill.scale;
                layer.contentsGravity = kCAGravityResize;
            } else if (fill.CGImage != NULL && layer.contents != NULL) {
                layer.contents = (__bridge id)fill.CGImage;
                layer.contentsScale = fill.scale;
            }
            if (host != nil && host.layer == layer) {
                host.backgroundColor = WolFoxMainColor();
            }
            objc_setAssociatedObject(layer, WolFoxBarTouchedAssociation,
                                     @(WolFoxProgressGeneration),
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
    for (CALayer *sublayer in layer.sublayers) {
        WolFoxRecolourRedBars(sublayer, depth + 1, host, trail);
    }
}

static IMP OriginalThumbSetImage;

static void WolFoxThumbSetImage(id node, SEL selector, UIImage *image) {
    UIImage *use = image;
    if (image != nil && WolFoxProgressStyle() != 0 &&
        objc_getAssociatedObject(image, WolFoxThumbGeneratedAssociation) == nil) {
        CGRect bounds = ((CGRect (*)(id, SEL))objc_msgSend)(
            node, NSSelectorFromString(@"bounds"));
        CGFloat width = CGRectGetWidth(bounds);
        CGFloat height = CGRectGetHeight(bounds);
        if (width < 1.0 || height < 1.0) {
            CGFloat scale = image.scale > 0.0 ? image.scale : 1.0;
            width = image.size.width / (scale > 1.0 ? 1.0 : 2.0);
            height = image.size.height / (scale > 1.0 ? 1.0 : 2.0);
        }
        if (height >= 1.0 && height <= 4.0 && width >= 8.0) {
            use = WolFoxThumbBarImage(
                width, height, WolFoxThumbTrackWidth(node, width, height));
        }
    }
    if (OriginalThumbSetImage != NULL) {
        ((void (*)(id, SEL, id))OriginalThumbSetImage)(node, selector, use);
    }
}

static IMP OriginalGridCellLayout;
static IMP OriginalBrandGradientDraw;

static void WolFoxBrandGradientDraw(UIView *receiver, SEL selector, CGRect rect) {
    CGRect bounds = receiver.bounds;
    CGFloat width = CGRectGetWidth(bounds);
    CGFloat height = CGRectGetHeight(bounds);
    CGContextRef context = UIGraphicsGetCurrentContext();
    BOOL eligible = WolFoxProgressStyle() != 0 && context != NULL &&
                    height >= 1.0 && height <= 6.0 && width >= 4.0;

    if (!eligible) {
        if (OriginalBrandGradientDraw != NULL) {
            ((void (*)(id, SEL, CGRect))OriginalBrandGradientDraw)(
                receiver, selector, rect);
        }
        return;
    }
    CGFloat track = width;
    UIView *ancestor = receiver.superview;
    for (NSUInteger level = 0; ancestor != nil && level < 5; level++) {
        CGFloat ancestorHeight = CGRectGetHeight(ancestor.bounds);
        CGFloat ancestorWidth = CGRectGetWidth(ancestor.bounds);
        if (ancestorHeight <= 10.0 && ancestorWidth > track) {
            track = ancestorWidth;
        }
        ancestor = ancestor.superview;
    }
    UIImage *fill = WolFoxThumbBarImage(width, height, track);
    [fill drawInRect:bounds];
}

static void WolFoxRefreshBrandGradients(UIView *view, NSUInteger depth) {
    if (view == nil || depth > 10) return;
    if ([NSStringFromClass(view.class) isEqualToString:@"YTBrandGradientView"]) {
        NSNumber *drawn = objc_getAssociatedObject(
            view, WolFoxBarTouchedAssociation);
        if (drawn == nil ||
            drawn.unsignedIntegerValue != WolFoxProgressGeneration) {
            objc_setAssociatedObject(view, WolFoxBarTouchedAssociation,
                                     @(WolFoxProgressGeneration),
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [view setNeedsDisplay];
        }
        return;
    }
    for (UIView *subview in view.subviews) {
        WolFoxRefreshBrandGradients(subview, depth + 1);
    }
}

static BOOL WolFoxHasBrandGradient(UIView *view, NSUInteger depth) {
    if (view == nil || depth > 10) return NO;
    if ([NSStringFromClass(view.class) isEqualToString:@"YTBrandGradientView"]) {
        return YES;
    }
    for (UIView *subview in view.subviews) {
        if (WolFoxHasBrandGradient(subview, depth + 1)) return YES;
    }
    return NO;
}

static void WolFoxGridCellLayout(UIView *receiver, SEL selector) {
    if (OriginalGridCellLayout != NULL) {
        ((void (*)(id, SEL))OriginalGridCellLayout)(receiver, selector);
    }
    if (WolFoxProgressStyle() == 0) return;
    BOOL brand = WolFoxHasBrandGradient(receiver, 0);
    if (brand) {
        WolFoxRefreshBrandGradients(receiver, 0);
        return;
    }
    WolFoxRecolourRedBars(receiver.layer, 0, receiver,
                          NSStringFromClass(receiver.class));
}

void WolFoxInstallProgressBarHooks(void) {
    static dispatch_once_t sweepToken;
    dispatch_once(&sweepToken, ^{
        BOOL grid = WolFoxInstallInstanceHook(@"YTGridVideoCell", @"layoutSubviews",
                                              (IMP)WolFoxGridCellLayout,
                                              &OriginalGridCellLayout);
        BOOL brand = WolFoxInstallInstanceHook(@"YTBrandGradientView", @"drawRect:",
                                               (IMP)WolFoxBrandGradientDraw,
                                               &OriginalBrandGradientDraw);
        (void)grid;
        (void)brand;
    });
    static dispatch_once_t thumbToken;
    dispatch_once(&thumbToken, ^{
        BOOL image = WolFoxInstallInstanceHook(@"ELMImageNode", @"layoutDidFinish",
                                               (IMP)WolFoxThumbBarLayout,
                                               &OriginalThumbBarLayout);
        BOOL container = WolFoxInstallInstanceHook(@"ELMContainerNode",
                                                   @"layoutDidFinish",
                                                   (IMP)WolFoxThumbContainerLayout,
                                                   &OriginalThumbContainerLayout);
        WolFoxInstallInstanceHook(@"ELMImageNode", @"displayWillStart",
                                  (IMP)WolFoxThumbDisplayWillStart,
                                  &OriginalThumbDisplayWillStart);
        WolFoxInstallInstanceHook(@"ELMImageNode", @"didEnterVisibleState",
                                  (IMP)WolFoxThumbDidEnterVisible,
                                  &OriginalThumbVisible);
        WolFoxInstallInstanceHook(@"ELMImageNode", @"setImage:",
                                  (IMP)WolFoxThumbSetImage,
                                  &OriginalThumbSetImage);
        (void)image;
        (void)container;
    });
    static NSUInteger attempt = 0;
    NSUInteger landed = WolFoxInstallProgressHookSet();
    attempt++;
    if (landed >= 15 || attempt >= 20) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        WolFoxInstallProgressBarHooks();
    });
}
