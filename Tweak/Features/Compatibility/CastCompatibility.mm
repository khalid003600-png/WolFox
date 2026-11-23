#import "../../WolFox.h"
#import "../../Runtime/Hooking.h"
#import "../Downloads/DownloadLog.h"

#import <UIKit/UIKit.h>
#import <objc/message.h>

static BOOL WolFoxCastYes(id receiver, SEL selector) {
    (void)receiver;
    (void)selector;
    return YES;
}

static BOOL WolFoxCastNo(id receiver, SEL selector) {
    (void)receiver;
    (void)selector;
    return NO;
}

static NSInteger WolFoxCastAllowedStatus(id receiver, SEL selector) {
    (void)receiver;
    (void)selector;
    return 1;
}

static void WolFoxSkipLocalNetworkPage(id receiver,
                                       SEL selector,
                                       id completion) {
    (void)receiver;
    (void)selector;
    WolFoxDownloadLog(@"cast", @"permission page bypassed");
    WolFoxStartCastDiscovery();
    if (completion == nil) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            ((void (^)(BOOL))completion)(YES);
        } @catch (__unused NSException *exception) {
            WolFoxDownloadLog(@"cast", @"permission completion failed");
        }
    });
}

static void WolFoxRefreshCastHooks(void) {
    WolFoxInstallInstanceHook(@"MDXRoutePresentationController",
                              @"hasSufficientLocalNetworkPermissions",
                              (IMP)WolFoxCastYes,
                              NULL);
    WolFoxInstallInstanceHook(@"MDXLocalNetworkPermissions",
                              @"lastKnownPermissionsStatus",
                              (IMP)WolFoxCastAllowedStatus,
                              NULL);
    WolFoxInstallInstanceHook(@"MDXLocalNetworkPermissions",
                              @"isAuthorized",
                              (IMP)WolFoxCastYes,
                              NULL);
    WolFoxInstallInstanceHook(@"MDXLocalStorage",
                              @"localNetworkPermissionsStatus",
                              (IMP)WolFoxCastAllowedStatus,
                              NULL);
    WolFoxInstallInstanceHook(
        @"MDXPermissionsController",
        @"showLocalNetworkPermissionsRequiredPageWithCompletion:",
        (IMP)WolFoxSkipLocalNetworkPage,
        NULL
    );
    WolFoxInstallInstanceHook(@"CADPLocalNetworkPermissionInfo",
                              @"isLocalNetworkPermissionAllowed",
                              (IMP)WolFoxCastYes,
                              NULL);
    WolFoxInstallInstanceHook(@"CADPLocalNetworkPermissionInfo",
                              @"wasLocalNetworkPermissionAllowed",
                              (IMP)WolFoxCastYes,
                              NULL);
    WolFoxInstallInstanceHook(
        @"CADPLocalNetworkPermissionInfo",
        @"shouldPresentLocalNetworkAccessPermissionDialog",
        (IMP)WolFoxCastNo,
        NULL
    );
    WolFoxInstallInstanceHook(
        @"YTBAMediaHubUiDeviceItemsResult",
        @"shouldShowLocalNetworkPermissionPrompt",
        (IMP)WolFoxCastNo,
        NULL
    );
}

void WolFoxStartCastDiscovery(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            Class contextClass = NSClassFromString(@"GCKCastContext");
            SEL sharedSelector = NSSelectorFromString(@"sharedInstance");
            if (contextClass == Nil ||
                ![contextClass respondsToSelector:sharedSelector]) {
                WolFoxDownloadLog(@"cast", @"context unavailable");
                return;
            }
            id context = ((id (*)(id, SEL))objc_msgSend)(contextClass,
                                                         sharedSelector);
            SEL managerSelector = NSSelectorFromString(@"discoveryManager");
            if (context == nil || ![context respondsToSelector:managerSelector]) {
                WolFoxDownloadLog(@"cast", @"manager unavailable");
                return;
            }
            id manager = ((id (*)(id, SEL))objc_msgSend)(context,
                                                         managerSelector);
            SEL startSelector = NSSelectorFromString(@"startDiscovery");
            if (manager != nil && [manager respondsToSelector:startSelector]) {
                ((void (*)(id, SEL))objc_msgSend)(manager, startSelector);
                WolFoxDownloadLog(@"cast", @"discovery started");
                dispatch_after(
                    dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                    dispatch_get_main_queue(), ^{
                        SEL countSelector = NSSelectorFromString(@"deviceCount");
                        if ([manager respondsToSelector:countSelector]) {
                            NSUInteger count = ((NSUInteger (*)(id, SEL))objc_msgSend)(
                                manager,
                                countSelector
                            );
                            WolFoxDownloadLog(@"cast", @"devices=%lu",
                                             (unsigned long)count);
                        }
                    }
                );
            }
        } @catch (__unused NSException *exception) {
            WolFoxDownloadLog(@"cast", @"discovery exception");
        }
    });
}

void WolFoxInstallCastCompatibilityHooks(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        WolFoxRefreshCastHooks();

        [NSNotificationCenter.defaultCenter
            addObserverForName:UIApplicationDidBecomeActiveNotification
                    object:nil
                         queue:NSOperationQueue.mainQueue
                    usingBlock:^(__unused NSNotification *notification) {
                        WolFoxRefreshCastHooks();
                        WolFoxDownloadLog(@"cast", @"app active");
                    }];
    });
}
