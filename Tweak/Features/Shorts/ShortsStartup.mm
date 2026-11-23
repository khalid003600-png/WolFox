#import "../../WolFox.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"
#import "../Downloads/DownloadLog.h"

#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>

static NSString *const WolFoxPreventShortsOpenKey =
    @"YTKACE.Preference.Shorts.PreventAutoOpen";

static IMP OriginalEligibilityModern;
static IMP OriginalEligibilityLegacy;
static IMP OriginalExecuteModern;
static IMP OriginalExecuteLegacy;
static IMP OriginalResumeToShorts;
static IMP OriginalShortsTargeted;
static IMP OriginalLaunchToShorts;

static BOOL WolFoxStartupTabIsOther(void) {
    id stored = [NSUserDefaults.standardUserDefaults objectForKey:@"YTKACE.Preference.Tabs.Startup"];
    if ([stored isKindOfClass:NSString.class]) {
        NSString *token = stored;
        return token.length != 0 && ![token isEqualToString:@"shorts"];
    }
    NSInteger index = [stored respondsToSelector:@selector(integerValue)] ? [stored integerValue] : 0;
    return index > 0 && index != 3;
}

static BOOL WolFoxPreventShortsOpen(void) {
    return WolFoxFeatureEnabled(WolFoxPreventShortsOpenKey) || WolFoxStartupTabIsOther();
}

static BOOL WolFoxEligibilityModern(id receiver,
                                    SEL selector,
                                    id launchOptions,
                                    id sceneOptions) {
    if (WolFoxPreventShortsOpen()) {
        WolFoxDownloadLog(@"shorts", @"eligibility suppressed");
        return NO;
    }
    return OriginalEligibilityModern == NULL ? NO
        : ((BOOL (*)(id, SEL, id, id))OriginalEligibilityModern)(
            receiver, selector, launchOptions, sceneOptions);
}

static BOOL WolFoxEligibilityLegacy(id receiver,
                                    SEL selector,
                                    long long applicationState,
                                    id launchOptions) {
    if (WolFoxPreventShortsOpen()) {
        WolFoxDownloadLog(@"shorts", @"eligibility suppressed");
        return NO;
    }
    return OriginalEligibilityLegacy == NULL ? NO
        : ((BOOL (*)(id, SEL, long long, id))OriginalEligibilityLegacy)(
            receiver, selector, applicationState, launchOptions);
}

static BOOL WolFoxExecuteModern(id receiver,
                                SEL selector,
                                id responder,
                                id launchOptions,
                                id sceneOptions) {
    if (WolFoxPreventShortsOpen()) {
        WolFoxDownloadLog(@"shorts", @"execution suppressed");
        return NO;
    }
    return OriginalExecuteModern == NULL ? NO
        : ((BOOL (*)(id, SEL, id, id, id))OriginalExecuteModern)(
            receiver, selector, responder, launchOptions, sceneOptions);
}

static BOOL WolFoxExecuteLegacy(id receiver,
                                SEL selector,
                                id responder,
                                long long applicationState,
                                id launchOptions) {
    if (WolFoxPreventShortsOpen()) {
        WolFoxDownloadLog(@"shorts", @"execution suppressed");
        return NO;
    }
    return OriginalExecuteLegacy == NULL ? NO
        : ((BOOL (*)(id, SEL, id, long long, id))OriginalExecuteLegacy)(
            receiver, selector, responder, applicationState, launchOptions);
}

static id WolFoxResumeToShorts(id receiver, SEL selector) {
    if (WolFoxPreventShortsOpen()) return nil;
    return OriginalResumeToShorts == NULL ? nil
        : ((id (*)(id, SEL))OriginalResumeToShorts)(receiver, selector);
}

static id WolFoxShortsTargeted(id receiver, SEL selector) {
    if (WolFoxPreventShortsOpen()) return nil;
    return OriginalShortsTargeted == NULL ? nil
        : ((id (*)(id, SEL))OriginalShortsTargeted)(receiver, selector);
}

static id WolFoxLaunchToShorts(id receiver, SEL selector) {
    if (WolFoxPreventShortsOpen()) return nil;
    return OriginalLaunchToShorts == NULL ? nil
        : ((id (*)(id, SEL))OriginalLaunchToShorts)(receiver, selector);
}

void WolFoxInstallShortsStartupHooks(void) {
    NSString *coordinator = nil;
    for (NSString *name in @[@"YTShortsStartupCoordinatorImpl",
                             @"YTShortsStartupCoordinator"]) {
        if (NSClassFromString(name) != Nil) {
            coordinator = name;
            break;
        }
    }
    if (coordinator == nil) {
        WolFoxDownloadLog(@"shorts", @"startup coordinator not found");
        return;
    }

    const BOOL eligibilityModern = WolFoxInstallInstanceHook(
        coordinator,
        @"evaluateShortsStartupEligibilityWithLaunchOptions:sceneConnectionOptions:",
        (IMP)WolFoxEligibilityModern, &OriginalEligibilityModern);
    const BOOL eligibilityLegacy = WolFoxInstallInstanceHook(
        coordinator,
        @"evaluateShortsStartupEligibilityWithApplicationState:launchOptions:",
        (IMP)WolFoxEligibilityLegacy, &OriginalEligibilityLegacy);
    const BOOL executeModern = WolFoxInstallInstanceHook(
        coordinator,
        @"executeStartupWithResponder:launchOptions:sceneConnectionOptions:",
        (IMP)WolFoxExecuteModern, &OriginalExecuteModern);
    const BOOL executeLegacy = WolFoxInstallInstanceHook(
        coordinator,
        @"executeStartupWithResponder:applicationState:launchOptions:",
        (IMP)WolFoxExecuteLegacy, &OriginalExecuteLegacy);
    const BOOL resume = WolFoxInstallInstanceHook(
        coordinator, @"evaluateResumeToShorts",
        (IMP)WolFoxResumeToShorts, &OriginalResumeToShorts);
    const BOOL targeted = WolFoxInstallInstanceHook(
        coordinator, @"evaluateShortsTargeted",
        (IMP)WolFoxShortsTargeted, &OriginalShortsTargeted);
    const BOOL launch = WolFoxInstallInstanceHook(
        coordinator, @"launchToShorts",
        (IMP)WolFoxLaunchToShorts, &OriginalLaunchToShorts);

    WolFoxDownloadLog(@"shorts",
                      @"startup hooks on %@ em=%d el=%d xm=%d xl=%d r=%d t=%d l=%d enabled=%d",
                      coordinator, eligibilityModern, eligibilityLegacy,
                      executeModern, executeLegacy, resume, targeted, launch,
                      WolFoxPreventShortsOpen());
}
