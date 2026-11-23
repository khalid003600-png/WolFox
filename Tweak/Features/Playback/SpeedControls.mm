#import "../../WolFox.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"
#import "../../UI/Assets.h"
#import "../../UI/OverlayButtonHost.h"
#import "../Downloads/DownloadLog.h"

#import <AVFoundation/AVFoundation.h>
#import <math.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <stdlib.h>
#import <string.h>

static NSMutableDictionary<NSString *, NSNumber *> *WolFoxMaximumRateOriginals;

static NSString * const WolFoxLastRateKey = @"YTKACE.Preference.Player.SavedRate";
static NSString * const WolFoxStartRateKey = @"YTKACE.Preference.Player.StartRate";
static NSString * const WolFoxLegacyRateKey = @"YTKACE.Preference.Player.DefaultRate";
static NSString * const WolFoxLegacyModeKey =
    @"YTKACE.Preference.Player.DefaultRateMode";

static NSString * const WolFoxCustomRateKey = @"YTKACE.Preference.Player.CustomRate";
static NSString * const WolFoxShortsRateKey = @"YTKACE.Preference.Shorts.PlaybackRate";

static const double WolFoxRateFollowApp = 0.0;
static const double WolFoxRateReuseLast = -1.0;
static const double WolFoxRateUseCustom = -2.0;
static const double WolFoxRateFloor = 0.25;
static const double WolFoxRateCeiling = 5.0;

static BOOL WolFoxRateIsUsable(double rate) {
    return isfinite(rate) && rate >= WolFoxRateFloor && rate <= WolFoxRateCeiling;
}

static double WolFoxLastPlayedRate(void) {
    double rate = [NSUserDefaults.standardUserDefaults doubleForKey:WolFoxLastRateKey];
    return WolFoxRateIsUsable(rate) ? rate : 0.0;
}

static NSString * const WolFoxRateMigratedKey =
    @"YTKACE.Preference.Player.StartRateMigrated";

static double WolFoxConfiguredStartRate(void) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if ([defaults boolForKey:WolFoxRateMigratedKey]) {
        return [defaults doubleForKey:WolFoxStartRateKey];
    }
    [defaults setBool:YES forKey:WolFoxRateMigratedKey];
    double migrated = WolFoxRateFollowApp;
    switch ([defaults integerForKey:WolFoxLegacyModeKey]) {
        case 1:
            migrated = WolFoxRateReuseLast;
            break;
        case 2: {
            double legacy = [defaults doubleForKey:WolFoxLegacyRateKey];
            if (WolFoxRateIsUsable(legacy)) {
                [defaults setDouble:legacy forKey:WolFoxCustomRateKey];
                migrated = WolFoxRateUseCustom;
            }
            break;
        }
        default:
            break;
    }
    [defaults setDouble:migrated forKey:WolFoxStartRateKey];
    return migrated;
}

static double WolFoxShortsRate(void) {
    const double rate =
        [NSUserDefaults.standardUserDefaults doubleForKey:WolFoxShortsRateKey];
    return WolFoxRateIsUsable(rate) ? rate : 0.0;
}

static BOOL WolFoxSourceUsesShortsRate(id source) {
    return WolFoxShortsRate() > 0.0 && source != nil && WolFoxPlayerIsShorts(source);
}

double WolFoxStartPlaybackRate(void) {
    const double configured = WolFoxConfiguredStartRate();
    if (configured == WolFoxRateReuseLast) {
        const double last = WolFoxLastPlayedRate();
        return last > 0.0 ? last : 1.0;
    }
    if (configured == WolFoxRateUseCustom) {
        const double custom =
            [NSUserDefaults.standardUserDefaults doubleForKey:WolFoxCustomRateKey];
        return WolFoxRateIsUsable(custom) ? custom : 1.0;
    }
    return WolFoxRateIsUsable(configured) ? configured : 1.0;
}

static BOOL WolFoxSpeedMenuStyle(void) {
    return [WolFoxPreferenceObject(@"YTKACE.Preference.Player.SpeedButtonStyle") integerValue] == 1;
}

static BOOL WolFoxRateCeilingRaised(void) {
    return YES;
}

static BOOL WolFoxDeliverRate(id target, NSString *name, double rate) {
    SEL selector = NSSelectorFromString(name);
    if (![target respondsToSelector:selector]) return NO;
    NSMethodSignature *signature = [target methodSignatureForSelector:selector];
    if (signature == nil || signature.numberOfArguments != 3) return NO;

    NSInvocation *call = [NSInvocation invocationWithMethodSignature:signature];
    call.target = target;
    call.selector = selector;

    const long long scaled = llround(rate * 100.0);
    switch ([signature getArgumentTypeAtIndex:2][0]) {
        case 'd': {
            double value = rate;
            [call setArgument:&value atIndex:2];
            break;
        }
        case 'f': {
            float value = (float)rate;
            [call setArgument:&value atIndex:2];
            break;
        }
        case '@': {
            id value = @(rate);
            [call setArgument:&value atIndex:2];
            break;
        }
        case 'c': case 'C': {
            char value = (char)scaled;
            [call setArgument:&value atIndex:2];
            break;
        }
        case 's': case 'S': {
            short value = (short)scaled;
            [call setArgument:&value atIndex:2];
            break;
        }
        case 'i': case 'I': {
            int value = (int)scaled;
            [call setArgument:&value atIndex:2];
            break;
        }
        case 'l': case 'L': case 'q': case 'Q': {
            long long value = scaled;
            [call setArgument:&value atIndex:2];
            break;
        }
        default:
            return NO;
    }
    [call invoke];
    return YES;
}

static NSString *WolFoxSpeedText(double rate) {
    if (fabs(rate - round(rate)) < 0.001) {
        return [NSString stringWithFormat:@"%.0fx", rate];
    }
    if (fabs(rate * 2.0 - round(rate * 2.0)) < 0.001) {
        return [NSString stringWithFormat:@"%.1fx", rate];
    }
    return [NSString stringWithFormat:@"%.2fx", rate];
}

UIImage *WolFoxSpeedButtonImage(BOOL plus) {
    CGSize size = CGSizeMake(22.0, 22.0);
    UIGraphicsBeginImageContextWithOptions(size, NO, 0.0);
    CGContextRef context = UIGraphicsGetCurrentContext();
    CGContextSetStrokeColorWithColor(context, UIColor.whiteColor.CGColor);
    CGContextSetLineWidth(context, 2.0);
    CGContextAddEllipseInRect(context, CGRectInset((CGRect){CGPointZero, size}, 1.5, 1.5));
    CGContextMoveToPoint(context, 6.5, 11.0);
    CGContextAddLineToPoint(context, 15.5, 11.0);
    if (plus) {
        CGContextMoveToPoint(context, 11.0, 6.5);
        CGContextAddLineToPoint(context, 11.0, 15.5);
    }
    CGContextStrokePath(context);
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

// System buttons crossfade title changes, which made fast +/- taps feel laggy.
static void WolFoxSetSpeedTitle(UIButton *button, NSString *title) {
    if (button == nil || [title isEqualToString:[button titleForState:UIControlStateNormal]]) return;
    [UIView performWithoutAnimation:^{
        [button setTitle:title forState:UIControlStateNormal];
        [button layoutIfNeeded];
    }];
    WolFoxOverlayButtonResized(button);
}

@interface WolFoxSpeedCoordinator : NSObject
+ (instancetype)sharedCoordinator;
@property(nonatomic, weak) UIView *overlay;
@property(nonatomic, weak) UIButton *valueButton;
@property(nonatomic, weak) id rateSource;
@property(nonatomic, copy) NSString *primedVideo;
@property(nonatomic, assign) double observedRate;
@property(nonatomic, readonly) double currentRate;
- (void)decrease;
- (void)increase;
- (void)reset;
- (void)valueTapped:(UIButton *)sender;
- (void)valueHeld:(UILongPressGestureRecognizer *)recognizer;
- (BOOL)openSpeedMenuFrom:(UIButton *)sender;
@end

@implementation WolFoxSpeedCoordinator

+ (instancetype)sharedCoordinator {
    static WolFoxSpeedCoordinator *coordinator;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        coordinator = [WolFoxSpeedCoordinator new];
    });
    return coordinator;
}

- (instancetype)init {
    self = [super init];
    if (self != nil) {
        _observedRate = 0.0;
        [NSNotificationCenter.defaultCenter
            addObserver:self
               selector:@selector(playbackTimeChanged:)
                   name:@"WolFoxPlaybackTimeDidChange"
                 object:nil];
        [NSNotificationCenter.defaultCenter
            addObserver:self
               selector:@selector(preferencesChanged:)
                   name:WolFoxPreferencesDidChangeNotification
                 object:nil];
    }
    return self;
}

- (double)rateFromObject:(id)object depth:(NSUInteger)depth {
    if (object == nil || depth > 2) {
        return 0.0;
    }
    for (NSString *name in @[@"playbackRate", @"currentPlaybackRate", @"rate"]) {
        SEL selector = NSSelectorFromString(name);
        NSMethodSignature *signature = [object methodSignatureForSelector:selector];
        if (![object respondsToSelector:selector] || signature == nil) {
            continue;
        }
        const char *type = signature.methodReturnType;
        double rate = 0.0;
        if (type[0] == 'd') {
            rate = ((double (*)(id, SEL))objc_msgSend)(object, selector);
        } else if (type[0] == 'f') {
            rate = ((float (*)(id, SEL))objc_msgSend)(object, selector);
        } else if (strchr("cislqCISLQ", type[0]) != NULL) {
            rate = ((NSInteger (*)(id, SEL))objc_msgSend)(object, selector);
        } else if (type[0] == '@') {
            id value = ((id (*)(id, SEL))objc_msgSend)(object, selector);
            if ([value respondsToSelector:@selector(doubleValue)]) {
                rate = [value doubleValue];
            }
        }
        if (isfinite(rate) && rate >= 0.25 && rate <= 5.0) {
            return rate;
        }
    }
    for (NSString *name in @[@"eventsDelegate", @"playbackController",
                              @"playerController", @"player"]) {
        SEL selector = NSSelectorFromString(name);
        if (![object respondsToSelector:selector]) {
            continue;
        }
        id child = ((id (*)(id, SEL))objc_msgSend)(object, selector);
        if (child == object) {
            continue;
        }
        double rate = [self rateFromObject:child depth:depth + 1];
        if (rate >= 0.25) {
            return rate;
        }
    }
    return 0.0;
}

- (NSString *)identifierForSource:(id)source {
    NSString *resolved = nil;
    for (NSString *probe in @[@"currentVideoID", @"videoID", @"videoId"]) {
        SEL selector = NSSelectorFromString(probe);
        if (![source respondsToSelector:selector]) continue;
        id candidate = ((id (*)(id, SEL))objc_msgSend)(source, selector);
        if (![candidate isKindOfClass:NSString.class]) continue;
        if ([candidate length] == 0) continue;
        resolved = candidate;
        break;
    }
    return resolved.length != 0 ? resolved : WolFoxLastVideoID();
}

- (BOOL)primeStartRateForSource:(id)source {
    NSString *identifier = [self identifierForSource:source];
    if (identifier.length == 0) return NO;
    if ([self.primedVideo isEqualToString:identifier]) return NO;
    self.primedVideo = identifier;

    const double target = WolFoxSourceUsesShortsRate(source)
        ? WolFoxShortsRate() : WolFoxStartPlaybackRate();
    if (!WolFoxRateIsUsable(target)) return NO;
    const double playing = [self rateFromObject:source depth:0];
    if (fabs(playing - target) < 0.01) return NO;

    [self setRate:target];
    return YES;
}

- (void)preferencesChanged:(NSNotification *)notification {
    NSString *key = notification.userInfo[@"key"];
    if (![key isEqualToString:WolFoxStartRateKey] &&
        ![key isEqualToString:WolFoxLegacyRateKey] &&
        ![key isEqualToString:WolFoxLegacyModeKey] &&
        ![key isEqualToString:WolFoxShortsRateKey]) {
        return;
    }
    self.primedVideo = nil;
    id source = self.rateSource;
    if ([self rateFromObject:source depth:0] >= 0.25) {
        [self primeStartRateForSource:source];
    }
}

- (void)playbackTimeChanged:(NSNotification *)notification {
    self.rateSource = notification.object;
    if ([self primeStartRateForSource:notification.object]) {
        return;
    }
    double rate = [self rateFromObject:notification.object depth:0];
    if (rate < 0.25) {
        AVPlayer *player = self.activePlayer;
        if (player.rate >= 0.25f) {
            rate = player.rate;
        }
    }
    if (rate < 0.25 || rate > 5.0) {
        return;
    }
    self.observedRate = rate;
    if (!WolFoxSourceUsesShortsRate(notification.object)) {
        [NSUserDefaults.standardUserDefaults setFloat:(float)rate
                                               forKey:WolFoxLastRateKey];
    }
    WolFoxSetSpeedTitle(self.valueButton, WolFoxSpeedText(rate));
}

- (id)eventsDelegate {
    SEL selector = NSSelectorFromString(@"eventsDelegate");
    if ([self.overlay respondsToSelector:selector]) {
        return ((id (*)(id, SEL))objc_msgSend)(self.overlay, selector);
    }
    return nil;
}

- (double)currentRate {
    if (isfinite(self.observedRate) && self.observedRate >= 0.25 &&
        self.observedRate <= 5.0) {
        return self.observedRate;
    }
    double saved = WolFoxLastPlayedRate();
    return saved >= 0.25 ? saved : 1.0;
}

- (AVPlayer *)activePlayerInLayer:(CALayer *)layer {
    if ([layer isKindOfClass:AVPlayerLayer.class]) {
        AVPlayer *player = ((AVPlayerLayer *)layer).player;
        if (player != nil) {
            return player;
        }
    }
    for (CALayer *child in layer.sublayers) {
        AVPlayer *player = [self activePlayerInLayer:child];
        if (player != nil) {
            return player;
        }
    }
    return nil;
}

- (AVPlayer *)activePlayer {
    UIView *root = self.overlay;
    while (root.superview != nil) {
        root = root.superview;
    }
    return [self activePlayerInLayer:root.layer];
}

- (BOOL)applyRate:(double)rate toObject:(id)object depth:(NSUInteger)depth {
    if (object == nil || depth > 2) {
        return NO;
    }
    if (WolFoxDeliverRate(object, @"setPlaybackRate:", rate)) {
        return YES;
    }
    if (depth == 0 && WolFoxDeliverRate(object, @"setRate:", rate)) {
        return YES;
    }
    for (NSString *name in @[@"eventsDelegate", @"playbackController",
                              @"playerController"]) {
        SEL selector = NSSelectorFromString(name);
        if (![object respondsToSelector:selector]) {
            continue;
        }
        id child = ((id (*)(id, SEL))objc_msgSend)(object, selector);
        if (child == object) {
            continue;
        }
        if ([self applyRate:rate toObject:child depth:depth + 1]) {
            return YES;
        }
    }
    return NO;
}

- (void)setRate:(double)rate {
    rate = MIN(5.0, MAX(0.25, rate));
    if (![self applyRate:rate toObject:self.eventsDelegate depth:0]) {
        [self applyRate:rate toObject:self.rateSource depth:0];
    }
    if (!WolFoxSourceUsesShortsRate(self.rateSource)) {
        [NSUserDefaults.standardUserDefaults setFloat:(float)rate
                                               forKey:WolFoxLastRateKey];
    }
    self.observedRate = rate;
    WolFoxSetSpeedTitle(self.valueButton, WolFoxSpeedText(rate));
}

- (void)decrease {
    [self setRate:(ceil(self.currentRate * 4.0 - 0.001) - 1.0) / 4.0];
}

- (void)increase {
    [self setRate:(floor(self.currentRate * 4.0 + 0.001) + 1.0) / 4.0];
}

- (void)reset {
    [self setRate:1.0];
}

- (void)valueTapped:(UIButton *)sender {
    if (!WolFoxSpeedMenuStyle() || ![self openSpeedMenuFrom:sender]) {
        [self reset];
    }
}

// Holding the number opens YouTube's speed menu in either style.
- (void)valueHeld:(UILongPressGestureRecognizer *)recognizer {
    if (recognizer.state != UIGestureRecognizerStateBegan) return;
    UIButton *button = [recognizer.view isKindOfClass:UIButton.class] ? (UIButton *)recognizer.view : nil;
    button.highlighted = NO;
    [button cancelTrackingWithEvent:nil];
    [[UIImpactFeedbackGenerator.alloc initWithStyle:UIImpactFeedbackStyleLight] impactOccurred];
    [self openSpeedMenuFrom:button];
}

- (BOOL)openSpeedMenuFrom:(UIButton *)sender {
    SEL open = NSSelectorFromString(@"didPressVarispeed:");
    // start from the tapped button: the last laid out overlay can be another player's
    for (UIResponder *responder = sender.window != nil ? (UIResponder *)sender : self.overlay; responder != nil;
         responder = responder.nextResponder) {
        if ([responder respondsToSelector:open]) {
            ((void (*)(id, SEL, id))objc_msgSend)(responder, open, sender);
            return YES;
        }
    }
    return NO;
}

@end

double WolFoxCurrentPlaybackRate(void) {
    return [WolFoxSpeedCoordinator sharedCoordinator].currentRate;
}

static IMP WolFoxMaximumOriginal(id receiver, SEL selector) {
    NSString *key = [NSString stringWithFormat:@"%@|%@",
        NSStringFromClass([receiver class]), NSStringFromSelector(selector)];
    return (IMP)(uintptr_t)WolFoxMaximumRateOriginals[key].unsignedLongLongValue;
}

static double WolFoxMaximumPlaybackRateDouble(id receiver, SEL selector) {
    if (WolFoxRateCeilingRaised()) {
        return 5.0;
    }
    IMP original = WolFoxMaximumOriginal(receiver, selector);
    return original == NULL
        ? 2.0
        : ((double (*)(id, SEL))original)(receiver, selector);
}

static float WolFoxMaximumPlaybackRateFloat(id receiver, SEL selector) {
    if (WolFoxRateCeilingRaised()) {
        return 5.0f;
    }
    IMP original = WolFoxMaximumOriginal(receiver, selector);
    return original == NULL
        ? 2.0f
        : ((float (*)(id, SEL))original)(receiver, selector);
}

static NSInteger WolFoxMaximumPlaybackRateInteger(id receiver, SEL selector) {
    if (WolFoxRateCeilingRaised()) {
        return 500;
    }
    IMP original = WolFoxMaximumOriginal(receiver, selector);
    return original == NULL
        ? 2
        : ((NSInteger (*)(id, SEL))original)(receiver, selector);
}

static NSUInteger WolFoxMaximumPlaybackRateUnsigned(id receiver, SEL selector) {
    if (WolFoxRateCeilingRaised()) {
        return 500;
    }
    IMP original = WolFoxMaximumOriginal(receiver, selector);
    return original == NULL
        ? 2
        : ((NSUInteger (*)(id, SEL))original)(receiver, selector);
}

static void WolFoxInstallMaximumRateHook(NSString *className,
                                         NSString *selectorName) {
    Class cls = NSClassFromString(className);
    Method method = class_getInstanceMethod(
        cls,
        NSSelectorFromString(selectorName)
    );
    if (method == NULL) {
        return;
    }
    char returnType[16] = {};
    method_getReturnType(method, returnType, sizeof(returnType));
    IMP replacement = NULL;
    if (strcmp(returnType, @encode(float)) == 0) {
        replacement = (IMP)WolFoxMaximumPlaybackRateFloat;
    } else if (strcmp(returnType, @encode(double)) == 0) {
        replacement = (IMP)WolFoxMaximumPlaybackRateDouble;
    } else if (strcmp(returnType, @encode(NSInteger)) == 0 ||
               strcmp(returnType, @encode(int)) == 0) {
        replacement = (IMP)WolFoxMaximumPlaybackRateInteger;
    } else if (strcmp(returnType, @encode(NSUInteger)) == 0 ||
               strcmp(returnType, @encode(unsigned int)) == 0) {
        replacement = (IMP)WolFoxMaximumPlaybackRateUnsigned;
    }
    if (replacement != NULL) {
        IMP original = NULL;
        if (WolFoxInstallInstanceHook(className,
                                      selectorName,
                                      replacement,
                                      &original)) {
            NSString *key = [NSString stringWithFormat:@"%@|%@",
                className, selectorName];
            WolFoxMaximumRateOriginals[key] = @((uintptr_t)original);
        }
    }
}

static void WolFoxInstallMaximumRateHooks(void) {
    WolFoxMaximumRateOriginals = [NSMutableDictionary dictionary];
    for (NSString *name in WolFoxAppClassNames()) {
        BOOL candidate = [name containsString:@"GranularVariableSpeedConfig"] ||
            [name containsString:@"PlayerHotConfig"];
        if (!candidate) {
            continue;
        }
        Class cls = NSClassFromString(name);
        if (cls == Nil) {
            continue;
        }
        for (NSString *selector in @[@"maximumPlaybackRate", @"maxPlaybackRate"]) {
            if (class_getInstanceMethod(cls,
                                        NSSelectorFromString(selector)) != NULL) {
                WolFoxInstallMaximumRateHook(name, selector);
            }
        }
    }

}

static NSString *const WolFoxHoldSpeedKey =
    @"YTKACE.Preference.Player.HoldSpeedEnabled";
static NSString *const WolFoxHoldSpeedRateKey =
    @"YTKACE.Preference.Player.HoldSpeedRate";


static IMP OriginalSpeedmasterActivated;
static IMP OriginalSpeedmasterLongPress;

static double WolFoxHoldPreviousRate;
static BOOL WolFoxHoldOverrideActive;
static BOOL WolFoxHoldPillActive;

// Holding for speed: other player gestures (swipe to seek) stay off.
BOOL WolFoxHoldSpeedActive(void) {
    return WolFoxHoldPillActive;
}
// Swiping up or down while holding changes the hold speed by 0.25x steps.
static double WolFoxHoldCurrentRate;
static CGFloat WolFoxHoldStartY;
static __weak id WolFoxHoldPillNode;
static NSDictionary *WolFoxHoldPillAttributes;
static NSString *WolFoxHoldPillOriginalText;
static IMP OriginalTextNodeSetAttributedText;
static const CGFloat WolFoxHoldStepDistance = 30.0;

static void WolFoxRestoreHoldRate(void);
static NSString *WolFoxWithPillMarks(NSString *original, NSString *speed);

static void WolFoxApplyHoldRate(NSString *source) {
    const BOOL on = WolFoxFeatureEnabled(WolFoxHoldSpeedKey);
    const double stored =
        [WolFoxPreferenceObject(WolFoxHoldSpeedRateKey) doubleValue];
    (void)source;
    if (!on || stored < 0.25 || stored > 5.0) return;
    if (!WolFoxHoldOverrideActive) {
        const double base = [WolFoxSpeedCoordinator sharedCoordinator].currentRate;
        WolFoxHoldPreviousRate =
            (base >= 0.25 && base <= 5.0) ? base : 1.0;
        WolFoxHoldOverrideActive = YES;
    }
    WolFoxHoldCurrentRate = stored;
    dispatch_async(dispatch_get_main_queue(), ^{
        [[WolFoxSpeedCoordinator sharedCoordinator] setRate:stored];
    });
}

static void WolFoxHoldSwipeChanged(UILongPressGestureRecognizer *recognizer) {
    if (!WolFoxHoldOverrideActive || WolFoxHoldCurrentRate <= 0.0 ||
        !WolFoxFeatureEnabled(@"YTKACE.Preference.Player.HoldSpeedSwipe")) return;
    const double stored = [WolFoxPreferenceObject(WolFoxHoldSpeedRateKey) doubleValue];
    const CGFloat rise = WolFoxHoldStartY - [recognizer locationInView:recognizer.view].y;
    const double steps = rise >= 0 ? floor(rise / WolFoxHoldStepDistance) : ceil(rise / WolFoxHoldStepDistance);
    const double rate = MIN(5.0, MAX(0.25, stored + steps * 0.25));
    if (fabs(rate - WolFoxHoldCurrentRate) < 0.001) return;
    WolFoxHoldCurrentRate = rate;
    [[UISelectionFeedbackGenerator new] selectionChanged];
    [[WolFoxSpeedCoordinator sharedCoordinator] setRate:rate];
    id node = WolFoxHoldPillNode;
    if (node != nil && OriginalTextNodeSetAttributedText != NULL) {
        NSAttributedString *text = [[NSAttributedString alloc]
            initWithString:WolFoxWithPillMarks(WolFoxHoldPillOriginalText ?: @"", WolFoxSpeedText(rate))
                attributes:WolFoxHoldPillAttributes ?: @{}];
        ((void (*)(id, SEL, id))OriginalTextNodeSetAttributedText)(
            node, NSSelectorFromString(@"setAttributedText:"), text);
    }
}

static void WolFoxRestoreHoldRate(void) {
    if (!WolFoxHoldOverrideActive) return;
    WolFoxHoldOverrideActive = NO;
    WolFoxHoldCurrentRate = 0.0;
    WolFoxHoldPillNode = nil;
    WolFoxHoldPillOriginalText = nil;
    const double previous = WolFoxHoldPreviousRate;
    WolFoxHoldPreviousRate = 0.0;
    if (previous < 0.25 || previous > 5.0) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        [[WolFoxSpeedCoordinator sharedCoordinator] setRate:previous];
    });
}

static void WolFoxSpeedmasterActivated(id receiver, SEL selector, BOOL active) {
    if (active) WolFoxHoldPillActive = YES;
    if (OriginalSpeedmasterActivated != NULL) {
        ((void (*)(id, SEL, BOOL))OriginalSpeedmasterActivated)(receiver,
                                                                selector, active);
    }
    if (!active) {
        WolFoxHoldPillActive = NO;
        WolFoxRestoreHoldRate();
        return;
    }
    WolFoxApplyHoldRate(@"activated");
}

static void WolFoxSpeedmasterLongPress(id receiver, SEL selector,
                                       UILongPressGestureRecognizer *recognizer) {
    if (recognizer.state == UIGestureRecognizerStateBegan) WolFoxHoldPillActive = YES;
    if (OriginalSpeedmasterLongPress != NULL) {
        ((void (*)(id, SEL, id))OriginalSpeedmasterLongPress)(receiver, selector,
                                                              recognizer);
    }
    if (recognizer.state == UIGestureRecognizerStateBegan) {
        WolFoxHoldStartY = [recognizer locationInView:recognizer.view].y;
        WolFoxApplyHoldRate(@"longpress");
        return;
    }
    if (recognizer.state == UIGestureRecognizerStateChanged) {
        WolFoxHoldSwipeChanged(recognizer);
        return;
    }
    if (recognizer.state == UIGestureRecognizerStateEnded ||
        recognizer.state == UIGestureRecognizerStateCancelled ||
        recognizer.state == UIGestureRecognizerStateFailed) {
        WolFoxHoldPillActive = NO;
        WolFoxRestoreHoldRate();
    }
}

// Right-to-left languages wrap the pill's "2x" in invisible direction marks.
static NSCharacterSet *WolFoxBidiMarks(void) {
    static NSCharacterSet *marks;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        marks = [NSCharacterSet characterSetWithCharactersInString:
            @"\u200E\u200F\u202A\u202B\u202C\u202D\u202E\u2066\u2067\u2068\u2069\u061C"];
    });
    return marks;
}

// The same marks around a new speed text, so the pill keeps its direction.
static NSString *WolFoxWithPillMarks(NSString *original, NSString *speed) {
    NSCharacterSet *marks = WolFoxBidiMarks();
    NSUInteger start = 0, end = original.length;
    while (start < end && [marks characterIsMember:[original characterAtIndex:start]]) start++;
    while (end > start && [marks characterIsMember:[original characterAtIndex:end - 1]]) end--;
    return [NSString stringWithFormat:@"%@%@%@", [original substringToIndex:start], speed,
                                      [original substringFromIndex:end]];
}

static BOOL WolFoxLooksLikeSpeedPill(NSString *text) {
    text = [text stringByTrimmingCharactersInSet:WolFoxBidiMarks()];
    if (text.length < 2 || ![text hasSuffix:@"x"]) return NO;
    NSString *number = [text substringToIndex:text.length - 1];
    NSCharacterSet *allowed =
        [NSCharacterSet characterSetWithCharactersInString:@"0123456789.,"];
    return [number stringByTrimmingCharactersInSet:allowed].length == 0;
}

static void WolFoxTextNodeSetAttributedText(id receiver, SEL selector,
                                            NSAttributedString *value) {
    value = WolFoxQueuePremiumText(value) ?: value;
    NSAttributedString *replacement = WolFoxDislikeMetaText(receiver,
        WolFoxSubtitleWithoutProductCount(receiver, value));
    NSString *text = [value isKindOfClass:NSAttributedString.class]
        ? value.string : nil;
    if (text.length != 0 && WolFoxHoldPillActive &&
        WolFoxFeatureEnabled(WolFoxHoldSpeedKey) && WolFoxLooksLikeSpeedPill(text)) {
        const double stored = WolFoxHoldCurrentRate > 0.0 ? WolFoxHoldCurrentRate :
            [WolFoxPreferenceObject(WolFoxHoldSpeedRateKey) doubleValue];
        NSString *wanted = WolFoxWithPillMarks(text, WolFoxSpeedText(stored));
        WolFoxHoldPillOriginalText = [text copy];
        NSDictionary *attributes = value.length != 0
            ? [value attributesAtIndex:0 effectiveRange:NULL] : @{};
        WolFoxHoldPillNode = receiver;
        WolFoxHoldPillAttributes = attributes;
        if (stored >= 0.25 && stored <= 5.0 && ![text isEqualToString:wanted]) {
            replacement = [[NSAttributedString alloc] initWithString:wanted
                                                          attributes:attributes];
        }
    }
    if (OriginalTextNodeSetAttributedText != NULL) {
        ((void (*)(id, SEL, id))OriginalTextNodeSetAttributedText)(
            receiver, selector, replacement);
    }
}

// YouTube turns hold for speed off while the video is already at 2x. With a
// custom hold speed that rule doesn't apply, so keep only its other checks.
static IMP OriginalSpeedmasterEligible;

static BOOL WolFoxSpeedmasterEligible(id receiver, SEL selector) {
    const BOOL eligible = ((BOOL (*)(id, SEL))OriginalSpeedmasterEligible)(receiver, selector);
    if (eligible || !WolFoxFeatureEnabled(WolFoxHoldSpeedKey)) return eligible;
    SEL videoDataSelector = NSSelectorFromString(@"videoData");
    SEL videoTypeSelector = NSSelectorFromString(@"videoType");
    SEL stateSelector = NSSelectorFromString(@"playerState");
    Ivar videoIvar = class_getInstanceVariable(object_getClass(receiver), "_currentSingleVideoObservable");
    id video = videoIvar != NULL ? object_getIvar(receiver, videoIvar) : nil;
    if (![receiver respondsToSelector:stateSelector] || ![video respondsToSelector:videoDataSelector]) return NO;
    id videoData = ((id (*)(id, SEL))objc_msgSend)(video, videoDataSelector);
    if (![videoData respondsToSelector:videoTypeSelector]) return NO;
    const long long videoType = ((long long (*)(id, SEL))objc_msgSend)(videoData, videoTypeSelector);
    const long long state = ((long long (*)(id, SEL))objc_msgSend)(receiver, stateSelector);
    WolFoxDebugLog(@"speed", @"hold eligible at 2x type=%lld state=%lld", videoType, state);
    return videoType == 0 && state == 3;
}

static void WolFoxInstallHoldSpeedHooks(void) {
    WolFoxInstallInstanceHook(
        @"YTMainAppVideoPlayerOverlayViewController", @"currentVideoIsEligibleToActivateSpeedmaster",
        (IMP)WolFoxSpeedmasterEligible, &OriginalSpeedmasterEligible);
    const BOOL node = WolFoxInstallInstanceHook(
        @"ELMTextNode", @"setAttributedText:",
        (IMP)WolFoxTextNodeSetAttributedText, &OriginalTextNodeSetAttributedText);
    const BOOL press = WolFoxInstallInstanceHook(
        @"YTSpeedmasterController", @"speedmasterDidLongPressWithRecognizer:",
        (IMP)WolFoxSpeedmasterLongPress, &OriginalSpeedmasterLongPress);
    const BOOL activated = WolFoxInstallInstanceHook(
        @"YTSpeedmasterController", @"setIsSpeedmasterActivated:",
        (IMP)WolFoxSpeedmasterActivated, &OriginalSpeedmasterActivated);
    (void)node;
    (void)activated;
    (void)press;
}

static IMP OriginalVarispeedInit;

static id WolFoxVarispeedInit(id receiver, SEL selector) {
    id controller = ((id (*)(id, SEL))OriginalVarispeedInit)(receiver, selector);
    if (controller == nil || !WolFoxRateCeilingRaised()) return controller;
    Class optionClass = NSClassFromString(@"YTVarispeedSwitchControllerOption");
    SEL initializer = NSSelectorFromString(@"initWithTitle:rate:");
    if (optionClass == Nil || ![optionClass instancesRespondToSelector:initializer]) return controller;
    NSMutableDictionary<NSNumber *, NSString *> *titles = [NSMutableDictionary dictionary];
    id existing = [controller valueForKey:@"_options"];
    for (id option in [existing isKindOfClass:NSArray.class] ? existing : @[]) {
        if (![option respondsToSelector:@selector(rate)]) continue;
        const float rate = ((float (*)(id, SEL))objc_msgSend)(option, @selector(rate));
        id title = [option respondsToSelector:@selector(title)] ? [option valueForKey:@"title"] : nil;
        if ([title isKindOfClass:NSString.class]) titles[@(llroundf(rate * 100.0f))] = title;
    }
    static const float rates[] = {0.25f, 0.5f, 0.75f, 1.0f, 1.25f, 1.5f, 1.75f, 2.0f,
                                  2.5f, 3.0f, 3.5f, 4.0f, 4.5f, 5.0f};
    NSMutableArray *options = [NSMutableArray array];
    for (size_t index = 0; index < sizeof(rates) / sizeof(rates[0]); index++) {
        NSString *title = titles[@(llroundf(rates[index] * 100.0f))] ?: WolFoxSpeedText(rates[index]);
        id option = ((id (*)(id, SEL, id, float))objc_msgSend)(
            [optionClass alloc], initializer, title, rates[index]);
        if (option != nil) [options addObject:option];
    }
    if (options.count != 0) [controller setValue:[options copy] forKey:@"_options"];
    return controller;
}

static id WolFoxSpeedValue(id object, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    return [object respondsToSelector:selector] ? ((id (*)(id, SEL))objc_msgSend)(object, selector) : nil;
}

void WolFoxRouteSpeedMenuItem(id renderers, id actions, UIView *view, id responder) {
    SEL open = NSSelectorFromString(@"didPressVarispeed:");
    SEL extensionSelector = NSSelectorFromString(@"messageForFieldNumber:");
    if (![renderers isKindOfClass:NSArray.class] || ![actions isKindOfClass:NSArray.class] ||
        ![responder respondsToSelector:open]) {
        return;
    }
    NSArray *items = renderers;
    NSArray *built = actions;
    for (NSUInteger index = 0; index < items.count && index < built.count; index++) {
        id options = WolFoxSpeedValue(WolFoxSpeedValue(items[index], @"elementRenderer"), @"compatibilityOptions");
        if (![options respondsToSelector:extensionSelector]) continue;
        id extension = ((id (*)(id, SEL, NSUInteger))objc_msgSend)(options, extensionSelector, 396644439);
        id identifier = WolFoxSpeedValue(extension, @"menuItemIdentifier");
        if (![identifier isKindOfClass:NSString.class] ||
            ![identifier isEqualToString:@"menu_item_playback_speed"]) {
            continue;
        }
        id action = built[index];
        SEL setHandler = NSSelectorFromString(@"setHandler:");
        if (![action respondsToSelector:setHandler]) return;
        __weak id weakResponder = responder;
        __weak UIView *weakView = view;
        dispatch_block_t handler = ^{
            id target = weakResponder;
            if ([target respondsToSelector:open]) {
                ((void (*)(id, SEL, id))objc_msgSend)(target, open, weakView);
            }
        };
        ((void (*)(id, SEL, id))objc_msgSend)(action, setHandler, handler);
        @try {
            UIView *elementView = [WolFoxSpeedValue(action, @"button") valueForKey:@"_elementView"];
            if ([elementView isKindOfClass:UIView.class]) elementView.userInteractionEnabled = NO;
        } @catch (__unused NSException *exception) {
        }
        return;
    }
}

void WolFoxInstallSpeedHooks(void) {
    WolFoxInstallInstanceHook(@"YTVarispeedSwitchControllerImpl", @"init",
                              (IMP)WolFoxVarispeedInit, &OriginalVarispeedInit);
    WolFoxInstallHoldSpeedHooks();
    if (WolFoxRateCeilingRaised()) {
        WolFoxInstallMaximumRateHooks();
    }
    (void)WolFoxSpeedCoordinator.sharedCoordinator;

    WolFoxRegisterOverlayConfigurator(@"speed", ^(UIView *overlay, UIStackView *stack) {
        WolFoxSpeedCoordinator *coordinator = WolFoxSpeedCoordinator.sharedCoordinator;
        coordinator.overlay = overlay;

        UIButton *minus = WolFoxOverlayButton(
            stack,
            @"WolFox Slower",
            @"minus.circle",
            coordinator,
            @selector(decrease)
        );
        UIButton *value = WolFoxOverlayButton(
            stack,
            @"WolFox Speed",
            @"speedometer",
            coordinator,
            @selector(valueTapped:)
        );
        UIButton *plus = WolFoxOverlayButton(
            stack,
            @"WolFox Faster",
            @"plus.circle",
            coordinator,
            @selector(increase)
        );
        [minus setImage:WolFoxSpeedButtonImage(NO) forState:UIControlStateNormal];
        [plus setImage:WolFoxSpeedButtonImage(YES) forState:UIControlStateNormal];
        coordinator.valueButton = value;
        WolFoxSetSpeedTitle(value, WolFoxSpeedText(coordinator.currentRate));
        BOOL hasHold = NO;
        for (UIGestureRecognizer *recognizer in value.gestureRecognizers) {
            if ([recognizer isKindOfClass:UILongPressGestureRecognizer.class]) hasHold = YES;
        }
        if (!hasHold) {
            UILongPressGestureRecognizer *hold = [[UILongPressGestureRecognizer alloc]
                initWithTarget:coordinator action:@selector(valueHeld:)];
            hold.minimumPressDuration = 0.4;
            [value addGestureRecognizer:hold];
        }
        [value setImage:nil forState:UIControlStateNormal];
        [value setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        value.titleLabel.font = [UIFont systemFontOfSize:17.0 weight:UIFontWeightSemibold];
        for (NSLayoutConstraint *constraint in value.constraints) {
            if (constraint.firstAttribute == NSLayoutAttributeWidth) {
                constraint.active = NO;
            }
        }
        [value.widthAnchor constraintGreaterThanOrEqualToConstant:52.0].active = YES;
        value.titleLabel.adjustsFontSizeToFitWidth = NO;
        value.titleLabel.lineBreakMode = NSLineBreakByClipping;
        [value sizeToFit];

        BOOL hidden = !WolFoxFeatureEnabled(WolFoxSpeedKey);
        minus.hidden = hidden || WolFoxSpeedMenuStyle();
        value.hidden = hidden;
        plus.hidden = hidden || WolFoxSpeedMenuStyle();
    });
}
