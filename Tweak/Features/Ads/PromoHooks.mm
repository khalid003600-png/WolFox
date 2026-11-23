#import "../../WolFox.h"
#import "../Downloads/DownloadLog.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"

#import <Foundation/Foundation.h>

static IMP OriginalMealbarPromo;
static IMP OriginalPromosheet;
static IMP OriginalUpgradeDialog;
static IMP OriginalOldUpgradeDialog;
static IMP OriginalShouldShowUpgrade;
static IMP OriginalShouldShowUpgradeDialog;
static IMP OriginalYouTherePrompt;
static IMP OriginalThrottleInterstitial;

static BOOL WolFoxHidePromos(void) {
    return WolFoxFeatureEnabled(@"YTKACE.Preference.Ads.PremiumPromosHidden");
}

static void WolFoxMealbarPromo(id receiver, SEL selector, id event) {
    if (!WolFoxHidePromos() && OriginalMealbarPromo != NULL) {
        ((void (*)(id, SEL, id))OriginalMealbarPromo)(receiver, selector, event);
    }
}

static void WolFoxPromosheet(id receiver, SEL selector, id event) {
    if (!WolFoxHidePromos() && OriginalPromosheet != NULL) {
        ((void (*)(id, SEL, id))OriginalPromosheet)(receiver, selector, event);
    }
}

static void WolFoxUpgradeDialog(id receiver, SEL selector) {
    if (!WolFoxHidePromos() && OriginalUpgradeDialog != NULL) {
        ((void (*)(id, SEL))OriginalUpgradeDialog)(receiver, selector);
    }
}

static void WolFoxOldUpgradeDialog(id receiver, SEL selector) {
    if (!WolFoxHidePromos() && OriginalOldUpgradeDialog != NULL) {
        ((void (*)(id, SEL))OriginalOldUpgradeDialog)(receiver, selector);
    }
}

static BOOL WolFoxShouldShowUpgrade(id receiver, SEL selector) {
    return WolFoxHidePromos() ? NO :
        (OriginalShouldShowUpgrade != NULL &&
         ((BOOL (*)(id, SEL))OriginalShouldShowUpgrade)(receiver, selector));
}

static BOOL WolFoxShouldShowUpgradeDialog(id receiver, SEL selector) {
    return WolFoxHidePromos() ? NO :
        (OriginalShouldShowUpgradeDialog != NULL &&
         ((BOOL (*)(id, SEL))OriginalShouldShowUpgradeDialog)(receiver, selector));
}

// "Video paused. Continue watching?" YouTube can ask through the controller
// or a command from the server, so block every path.
static BOOL WolFoxBlockYouThere(void) {
    return WolFoxHidePromos() || WolFoxFeatureEnabled(@"YTKACE.Preference.Playback.YouThereDisabled");
}

static IMP OriginalShowYouThere;
static IMP OriginalLegacyShouldShowYouThere;
static IMP OriginalLegacyShowYouThere;
static IMP OriginalYouThereCommands;

static BOOL WolFoxShouldShowYouThere(id receiver, SEL selector) {
    return WolFoxBlockYouThere() ? NO :
        (OriginalYouTherePrompt != NULL &&
         ((BOOL (*)(id, SEL))OriginalYouTherePrompt)(receiver, selector));
}

static void WolFoxShowYouThere(id receiver, SEL selector) {
    if (WolFoxBlockYouThere()) {
        WolFoxDebugLog(@"youthere", @"blocked prompt");
        return;
    }
    if (OriginalShowYouThere != NULL) ((void (*)(id, SEL))OriginalShowYouThere)(receiver, selector);
}

static BOOL WolFoxLegacyShouldShowYouThere(id receiver, SEL selector) {
    return WolFoxBlockYouThere() ? NO :
        (OriginalLegacyShouldShowYouThere != NULL &&
         ((BOOL (*)(id, SEL))OriginalLegacyShouldShowYouThere)(receiver, selector));
}

static void WolFoxLegacyShowYouThere(id receiver, SEL selector) {
    if (WolFoxBlockYouThere()) return;
    if (OriginalLegacyShowYouThere != NULL) ((void (*)(id, SEL))OriginalLegacyShowYouThere)(receiver, selector);
}

static BOOL WolFoxYouThereCommands(id receiver, SEL selector) {
    return WolFoxBlockYouThere() ? NO :
        (OriginalYouThereCommands != NULL &&
         ((BOOL (*)(id, SEL))OriginalYouThereCommands)(receiver, selector));
}

static BOOL WolFoxInterstitialIsPromo(id command, NSString **outMatch) {
    if (command == nil) return NO;
    NSString *text = [[command description] lowercaseString];
    if (text.length == 0) return NO;
    if ([text containsString:@"post"] || [text containsString:@"image"] ||
        [text containsString:@"lightbox"] || [text containsString:@"attachment"]) {
        if (outMatch != NULL) *outMatch = @"post content";
        return NO;
    }
    for (NSString *marker in @[@"premium", @"upsell", @"mealbar",
                               @"promo_sheet", @"promosheet"]) {
        if ([text containsString:marker]) {
            if (outMatch != NULL) *outMatch = marker;
            return YES;
        }
    }
    return NO;
}

static BOOL WolFoxShouldThrottleInterstitial(id receiver, SEL selector) {
    if (WolFoxHidePromos()) {
        NSString *match = nil;
        BOOL promo = WolFoxInterstitialIsPromo(receiver, &match);
        if (promo) {
            return YES;
        }
    }
    return OriginalThrottleInterstitial != NULL &&
        ((BOOL (*)(id, SEL))OriginalThrottleInterstitial)(receiver, selector);
}

void WolFoxInstallPromoHooks(void) {
    WolFoxInstallInstanceHook(@"YTMealbarPromoController",
                              @"showMealbarPromoWithEvent:",
                              (IMP)WolFoxMealbarPromo,
                              &OriginalMealbarPromo);
    WolFoxInstallInstanceHook(@"YTPromosheetController",
                              @"presentPromosheetWithEvent:",
                              (IMP)WolFoxPromosheet,
                              &OriginalPromosheet);
    WolFoxInstallInstanceHook(@"YTUpgradeController", @"showUpgradeDialog",
                              (IMP)WolFoxUpgradeDialog,
                              &OriginalUpgradeDialog);
    WolFoxInstallInstanceHook(@"YTUpgradeController", @"showOldUpgradeDialog",
                              (IMP)WolFoxOldUpgradeDialog,
                              &OriginalOldUpgradeDialog);
    WolFoxInstallInstanceHook(@"YTGlobalConfig", @"shouldShowUpgrade",
                              (IMP)WolFoxShouldShowUpgrade,
                              &OriginalShouldShowUpgrade);
    WolFoxInstallInstanceHook(@"YTGlobalConfig", @"shouldShowUpgradeDialog",
                              (IMP)WolFoxShouldShowUpgradeDialog,
                              &OriginalShouldShowUpgradeDialog);
    WolFoxInstallInstanceHook(@"YTYouThereControllerImpl",
                              @"shouldShowYouTherePrompt",
                              (IMP)WolFoxShouldShowYouThere,
                              &OriginalYouTherePrompt);
    WolFoxInstallInstanceHook(@"YTYouThereControllerImpl", @"showYouTherePrompt",
                              (IMP)WolFoxShowYouThere, &OriginalShowYouThere);
    WolFoxInstallInstanceHook(@"YTYouThereController", @"shouldShowYouTherePrompt",
                              (IMP)WolFoxLegacyShouldShowYouThere, &OriginalLegacyShouldShowYouThere);
    WolFoxInstallInstanceHook(@"YTYouThereController", @"showYouTherePrompt",
                              (IMP)WolFoxLegacyShowYouThere, &OriginalLegacyShowYouThere);
    WolFoxInstallInstanceHook(@"YTColdConfig", @"enableYouthereCommandsOnIos",
                              (IMP)WolFoxYouThereCommands, &OriginalYouThereCommands);
    WolFoxInstallInstanceHook(@"YTIShowFullscreenInterstitialCommand",
                              @"shouldThrottleInterstitial",
                              (IMP)WolFoxShouldThrottleInterstitial,
                              &OriginalThrottleInterstitial);
}
