#import "../../WolFox.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"
#import "../../UI/OverlayButtonHost.h"
#import "../Downloads/DownloadLog.h"

#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

static NSString *const WolFoxQualityButtonKey = @"YTKACE.Preference.Player.QualityButton";
static const void *WolFoxQualityStyledAssociation = &WolFoxQualityStyledAssociation;
static NSHashTable<UIButton *> *WolFoxQualityButtons;
static IMP OriginalRedesignedDidSelectFormat;
static IMP OriginalOriginalDidSelectFormat;

static id WolFoxQualityGet(id object, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    if (object == nil || ![object respondsToSelector:selector]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(object, selector);
}

static BOOL WolFoxQualityCompact(void) {
    return [WolFoxPreferenceObject(@"YTKACE.Preference.Player.QualityButtonStyle") integerValue] == 1;
}

static NSArray<NSString *> *WolFoxQualityWords(NSString *label) {
    NSMutableArray<NSString *> *words = [NSMutableArray array];
    for (NSString *word in [label componentsSeparatedByCharactersInSet:
             NSCharacterSet.whitespaceCharacterSet]) {
        if (word.length != 0) [words addObject:word];
    }
    return words;
}

static BOOL WolFoxQualityIsPremium(NSString *label) {
    return [label rangeOfString:@"Premium" options:NSCaseInsensitiveSearch].location != NSNotFound;
}

// Standard: "1080p60 HDR" -> "1080p60", "1080p Premium" -> "1080p+"
// Compact: "1080p60" -> "HD\n60", "2160p60 HDR" -> "4K\n60\nHDR", "1080p Premium" -> "HD+"
static NSString *WolFoxShortQualityLabel(NSString *label) {
    NSArray<NSString *> *words = WolFoxQualityWords(label);
    NSString *first = words.firstObject;
    if (first.length == 0) return nil;
    if (!WolFoxQualityCompact()) {
        return WolFoxQualityIsPremium(label) ? [first stringByAppendingString:@"+"] : first;
    }
    NSRange p = [first rangeOfString:@"p"];
    NSString *resolution = p.location == NSNotFound ? first : [first substringToIndex:p.location];
    NSString *fps = p.location == NSNotFound ? @"" : [first substringFromIndex:p.location + 1];
    NSString *name = @{@"2160": @"4K", @"1440": @"2K", @"1080": @"HD"}[resolution]
        ?: (p.location == NSNotFound ? first : [resolution stringByAppendingString:@"p"]);
    if (WolFoxQualityIsPremium(label)) name = [name stringByAppendingString:@"+"];
    NSMutableArray<NSString *> *lines = [NSMutableArray arrayWithObject:name];
    if (fps.length != 0) [lines addObject:fps];
    for (NSUInteger index = 1; index < words.count && lines.count < 3; index++) {
        if (!WolFoxQualityIsPremium(words[index])) [lines addObject:words[index]];
    }
    return [lines componentsJoinedByString:@"\n"];
}

// The last label from the quality switch, which keeps "Premium".
static NSString *WolFoxQualityLastLabel;

// The quality of the stream that's playing right now.
static NSString *WolFoxCurrentQualityLabel(UIView *overlay) {
    for (UIResponder *responder = overlay; responder != nil; responder = responder.nextResponder) {
        if (![NSStringFromClass(responder.class) isEqualToString:@"YTPlayerViewController"]) continue;
        id format = WolFoxQualityGet(WolFoxQualityGet(responder, @"activeVideo"), @"selectedVideoFormat");
        id label = WolFoxQualityGet(format, @"qualityLabel");
        if (![label isKindOfClass:NSString.class]) return nil;
        NSString *last = WolFoxQualityLastLabel;
        BOOL same = last.length != 0 &&
            [WolFoxQualityWords(last).firstObject isEqualToString:WolFoxQualityWords(label).firstObject];
        return same ? last : label;
    }
    return nil;
}

@interface WolFoxQualityButtonTarget : NSObject
+ (instancetype)sharedTarget;
- (void)openQuality:(UIButton *)sender;
@end

@implementation WolFoxQualityButtonTarget

+ (instancetype)sharedTarget {
    static WolFoxQualityButtonTarget *target;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        target = [WolFoxQualityButtonTarget new];
    });
    return target;
}

// Opens YouTube's own quality menu, like the quality row in the settings sheet.
- (void)openQuality:(UIButton *)sender {
    SEL open = NSSelectorFromString(@"didPressVideoQuality:");
    for (UIResponder *responder = sender; responder != nil; responder = responder.nextResponder) {
        if ([responder respondsToSelector:open]) {
            ((void (*)(id, SEL, id))objc_msgSend)(responder, open, sender);
            return;
        }
    }
    WolFoxDebugLog(@"quality", @"no responder for didPressVideoQuality:");
}

@end

static const void *WolFoxQualityMinWidthAssociation = &WolFoxQualityMinWidthAssociation;

static void WolFoxStyleQualityButton(UIButton *button) {
    BOOL compact = WolFoxQualityCompact();
    if (objc_getAssociatedObject(button, WolFoxQualityStyledAssociation) == nil) {
        objc_setAssociatedObject(button, WolFoxQualityStyledAssociation, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        button.titleLabel.adjustsFontSizeToFitWidth = NO;
        button.titleLabel.lineBreakMode = NSLineBreakByClipping;
        button.titleLabel.textAlignment = NSTextAlignmentCenter;
        // fit the text; the row used to squeeze it and cut "1080p+" to "1080"
        for (NSLayoutConstraint *constraint in button.constraints) {
            if (constraint.firstItem == button && constraint.firstAttribute == NSLayoutAttributeWidth &&
                constraint.relation == NSLayoutRelationEqual) constraint.active = NO;
        }
        NSLayoutConstraint *minimum = [button.widthAnchor constraintGreaterThanOrEqualToConstant:40.0];
        minimum.active = YES;
        objc_setAssociatedObject(button, WolFoxQualityMinWidthAssociation, minimum, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [button setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        [button setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    }
    button.titleLabel.font = [UIFont systemFontOfSize:compact ? 10.0 : 17.0 weight:UIFontWeightSemibold];
    button.titleLabel.numberOfLines = compact ? 3 : 1;
    NSLayoutConstraint *minimum = objc_getAssociatedObject(button, WolFoxQualityMinWidthAssociation);
    minimum.constant = compact ? 24.0 : 40.0;
}

static void WolFoxSetQualityTitle(UIButton *button, NSString *quality) {
    if ([quality isEqualToString:[button titleForState:UIControlStateNormal]]) return;
    [button setTitle:quality forState:UIControlStateNormal];
    [button setImage:quality.length != 0 ? nil
        : [UIImage systemImageNamed:@"slider.horizontal.3"
                  withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:21.0
                                                                                    weight:UIImageSymbolWeightMedium]]
            forState:UIControlStateNormal];
    WolFoxOverlayButtonResized(button);
}

// The stream switched quality (Auto changing it, or a pick in the menu).
static void WolFoxQualityDidSelectFormat(id receiver, SEL selector, id video, id format, IMP original) {
    if (original != NULL) ((void (*)(id, SEL, id, id))original)(receiver, selector, video, format);
    id label = WolFoxQualityGet(format, @"qualityLabel");
    if (![label isKindOfClass:NSString.class] || !WolFoxFeatureEnabled(WolFoxQualityButtonKey)) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        WolFoxQualityLastLabel = [label copy];
        NSString *quality = WolFoxShortQualityLabel(label);
        for (UIButton *button in WolFoxQualityButtons.allObjects) {
            if (!button.hidden && button.window != nil) {
                WolFoxStyleQualityButton(button);
                WolFoxSetQualityTitle(button, quality);
            }
        }
    });
}

static void WolFoxRedesignedDidSelectFormat(id receiver, SEL selector, id video, id format) {
    WolFoxQualityDidSelectFormat(receiver, selector, video, format, OriginalRedesignedDidSelectFormat);
}

static void WolFoxOriginalDidSelectFormat(id receiver, SEL selector, id video, id format) {
    WolFoxQualityDidSelectFormat(receiver, selector, video, format, OriginalOriginalDidSelectFormat);
}

void WolFoxInstallQualityButtonHooks(void) {
    WolFoxQualityButtons = [NSHashTable weakObjectsHashTable];
    WolFoxInstallInstanceHook(@"YTVideoQualitySwitchRedesignedController", @"singleVideo:didSelectVideoFormat:",
                              (IMP)WolFoxRedesignedDidSelectFormat, &OriginalRedesignedDidSelectFormat);
    WolFoxInstallInstanceHook(@"YTVideoQualitySwitchOriginalController", @"singleVideo:didSelectVideoFormat:",
                              (IMP)WolFoxOriginalDidSelectFormat, &OriginalOriginalDidSelectFormat);
    WolFoxRegisterOverlayConfigurator(@"quality", ^(UIView *overlay, UIStackView *stack) {
        UIButton *button = WolFoxOverlayButton(stack, @"WolFox Quality", @"slider.horizontal.3",
                                               WolFoxQualityButtonTarget.sharedTarget,
                                               @selector(openQuality:));
        button.hidden = !WolFoxFeatureEnabled(WolFoxQualityButtonKey);
        if (button.hidden) return;
        WolFoxStyleQualityButton(button);
        [WolFoxQualityButtons addObject:button];
        // shows the icon until the stream has a quality
        NSString *label = WolFoxCurrentQualityLabel(overlay);
        WolFoxSetQualityTitle(button, label != nil ? WolFoxShortQualityLabel(label) : nil);
    });
}
