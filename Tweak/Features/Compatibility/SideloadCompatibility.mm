#import "../../WolFox.h"
#import "../../Runtime/Hooking.h"

#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

static NSString * const WolFoxYouTubeIdentifier = @"com.google.ios.youtube";
static NSString * const WolFoxYouTubeName = @"YouTube";

static IMP OriginalBundleWithIdentifier;
static IMP OriginalBundleIdentifier;
static IMP OriginalInfoDictionary;
static IMP OriginalInfoValue;
static IMP OriginalSSOSetTemporary;
static IMP OriginalSSOConfigurationInit;
static IMP OriginalGroupContainerURL;
static IMP OriginalApplicationSetDelegate;

static BOOL WolFoxIsSideloaded(void) {
    NSURL *receiptURL = NSBundle.mainBundle.appStoreReceiptURL;
    NSString *path = receiptURL.path;
    return path.length == 0 ||
        ![NSFileManager.defaultManager fileExistsAtPath:path];
}

static NSString *WolFoxCurrentAccessGroup(void) {
    static NSString *accessGroup;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSDictionary *query = @{
            (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
            (__bridge id)kSecAttrAccount: @"WolFoxDummyItem",
            (__bridge id)kSecAttrService: @"WolFoxDummyService",
            (__bridge id)kSecReturnAttributes: @YES
        };
        CFTypeRef result = NULL;
        OSStatus status = SecItemCopyMatching(
            (__bridge CFDictionaryRef)query,
            &result
        );
        if (status == errSecItemNotFound) {
            status = SecItemAdd((__bridge CFDictionaryRef)query, &result);
        }
        if (status == errSecDuplicateItem) {
            status = SecItemCopyMatching(
                (__bridge CFDictionaryRef)query,
                &result
            );
        }
        if (status == errSecSuccess && result != NULL) {
            NSDictionary *attributes = CFBridgingRelease(result);
            id value = attributes[(__bridge id)kSecAttrAccessGroup];
            if ([value isKindOfClass:NSString.class]) {
                accessGroup = [value copy];
            }
        } else if (result != NULL) {
            CFRelease(result);
        }
    });
    return accessGroup;
}

static NSString *WolFoxAccessGroup(id receiver, SEL selector) {
    (void)receiver;
    (void)selector;
    return WolFoxCurrentAccessGroup();
}

static NSBundle *WolFoxBundleWithIdentifier(id receiver,
                                            SEL selector,
                                            NSString *identifier) {
    if ([identifier isEqualToString:WolFoxYouTubeIdentifier]) {
        return NSBundle.mainBundle;
    }
    return OriginalBundleWithIdentifier == NULL
        ? nil
        : ((id (*)(id, SEL, id))OriginalBundleWithIdentifier)(
            receiver, selector, identifier
        );
}

static NSString *WolFoxBundleIdentifier(NSBundle *receiver, SEL selector) {
    if (receiver == NSBundle.mainBundle) {
        return WolFoxYouTubeIdentifier;
    }
    return OriginalBundleIdentifier == NULL
        ? nil
        : ((id (*)(id, SEL))OriginalBundleIdentifier)(receiver, selector);
}

static NSDictionary *WolFoxInfoDictionary(NSBundle *receiver, SEL selector) {
    NSDictionary *info = OriginalInfoDictionary == NULL
        ? nil
        : ((id (*)(id, SEL))OriginalInfoDictionary)(receiver, selector);
    if (receiver != NSBundle.mainBundle || info == nil) {
        return info;
    }
    NSMutableDictionary *updated = [info mutableCopy];
    updated[@"CFBundleIdentifier"] = WolFoxYouTubeIdentifier;
    updated[@"CFBundleDisplayName"] = WolFoxYouTubeName;
    updated[@"CFBundleName"] = WolFoxYouTubeName;
    return [updated copy];
}

static id WolFoxInfoValue(NSBundle *receiver,
                          SEL selector,
                          NSString *key) {
    if (receiver == NSBundle.mainBundle) {
        if ([key isEqualToString:@"CFBundleIdentifier"]) {
            return WolFoxYouTubeIdentifier;
        }
        if ([key isEqualToString:@"CFBundleDisplayName"] ||
            [key isEqualToString:@"CFBundleName"]) {
            return WolFoxYouTubeName;
        }
    }
    return OriginalInfoValue == NULL
        ? nil
        : ((id (*)(id, SEL, id))OriginalInfoValue)(receiver, selector, key);
}

static BOOL WolFoxTrue(id receiver, SEL selector) {
    (void)receiver;
    (void)selector;
    return YES;
}

static BOOL WolFoxFalse(id receiver, SEL selector) {
    (void)receiver;
    (void)selector;
    return NO;
}

static NSString *WolFoxAppName(id receiver, SEL selector) {
    (void)receiver;
    (void)selector;
    return WolFoxYouTubeName;
}

static NSString *WolFoxAppIdentifier(id receiver, SEL selector) {
    (void)receiver;
    (void)selector;
    return WolFoxYouTubeIdentifier;
}

static void WolFoxSetTemporaryDisabled(id receiver,
                                       SEL selector,
                                       BOOL disabled) {
    (void)disabled;
    if (OriginalSSOSetTemporary != NULL) {
        ((void (*)(id, SEL, BOOL))OriginalSSOSetTemporary)(
            receiver, selector, NO
        );
    }
}

static id WolFoxConfigurationInit(id receiver,
                                  SEL selector,
                                  id clientID,
                                  id services) {
    id value = OriginalSSOConfigurationInit == NULL
        ? receiver
        : ((id (*)(id, SEL, id, id))OriginalSSOConfigurationInit)(
            receiver, selector, clientID, services
        );
    if (value != nil) {
        @try {
            [value setValue:WolFoxYouTubeName forKey:@"_shortAppName"];
            [value setValue:WolFoxYouTubeIdentifier
                     forKey:@"_applicationIdentifier"];
        } @catch (__unused NSException *exception) {
        }
    }
    return value;
}

static NSURL *WolFoxGroupContainerURL(NSFileManager *receiver,
                                      SEL selector,
                                      NSString *identifier) {
    NSURL *original = OriginalGroupContainerURL == NULL
        ? nil
        : ((id (*)(id, SEL, id))OriginalGroupContainerURL)(
            receiver, selector, identifier
        );
    if (original != nil || ![identifier containsString:@"group."]) {
        return original;
    }
    NSURL *support = [[receiver URLsForDirectory:NSApplicationSupportDirectory
                                        inDomains:NSUserDomainMask] lastObject];
    if (support == nil) {
        return nil;
    }
    NSURL *fallback = [support URLByAppendingPathComponent:@"AppGroup"
                                               isDirectory:YES];
    [receiver createDirectoryAtURL:fallback
       withIntermediateDirectories:YES
                        attributes:nil
                             error:nil];
    return fallback;
}

static BOOL WolFoxApplicationOpenURL(id receiver,
                                     SEL selector,
                                     UIApplication *application,
                                     NSURL *URL,
                                     NSDictionary *options) {
    (void)selector;
    SEL legacy = NSSelectorFromString(
        @"application:openURL:sourceApplication:annotation:"
    );
    if ([receiver respondsToSelector:legacy]) {
        id source = options[UIApplicationOpenURLOptionsSourceApplicationKey];
        id annotation = options[UIApplicationOpenURLOptionsAnnotationKey];
        return ((BOOL (*)(id, SEL, id, id, id, id))objc_msgSend)(
            receiver,
            legacy,
            application,
            URL,
            source,
            annotation
        );
    }
    SEL older = NSSelectorFromString(@"application:handleOpenURL:");
    if ([receiver respondsToSelector:older]) {
        return ((BOOL (*)(id, SEL, id, id))objc_msgSend)(
            receiver,
            older,
            application,
            URL
        );
    }
    return NO;
}

static void WolFoxApplicationSetDelegate(UIApplication *receiver,
                                         SEL selector,
                                         id delegate) {
    if (delegate != nil &&
        [NSBundle.mainBundle objectForInfoDictionaryKey:
            @"LSSupportsOpeningDocumentsInPlace"] != nil) {
        SEL openSelector = NSSelectorFromString(@"application:openURL:options:");
        Class delegateClass = object_getClass(delegate);
        if (class_getInstanceMethod(delegateClass, openSelector) == NULL) {
            class_addMethod(delegateClass,
                            openSelector,
                            (IMP)WolFoxApplicationOpenURL,
                            "B@:@@@");
        }
    }
    if (OriginalApplicationSetDelegate != NULL) {
        ((void (*)(id, SEL, id))OriginalApplicationSetDelegate)(
            receiver,
            selector,
            delegate
        );
    }
}

void WolFoxInstallSideloadCompatibilityHooks(void) {
    if (!WolFoxIsSideloaded()) {
        return;
    }
    WolFoxCurrentAccessGroup();

    WolFoxInstallInstanceHook(@"UIApplication", @"setDelegate:",
                              (IMP)WolFoxApplicationSetDelegate,
                              &OriginalApplicationSetDelegate);

    NSString *realIdentifier = NSBundle.mainBundle.bundleIdentifier;
    if (![realIdentifier isEqualToString:WolFoxYouTubeIdentifier]) {
        WolFoxInstallClassHook(@"NSBundle", @"bundleWithIdentifier:",
                               (IMP)WolFoxBundleWithIdentifier,
                               &OriginalBundleWithIdentifier);
        WolFoxInstallInstanceHook(@"NSBundle", @"bundleIdentifier",
                                  (IMP)WolFoxBundleIdentifier,
                                  &OriginalBundleIdentifier);
        WolFoxInstallInstanceHook(@"NSBundle", @"infoDictionary",
                                  (IMP)WolFoxInfoDictionary,
                                  &OriginalInfoDictionary);
        WolFoxInstallInstanceHook(@"NSBundle", @"objectForInfoDictionaryKey:",
                                  (IMP)WolFoxInfoValue,
                                  &OriginalInfoValue);
    }

    WolFoxInstallClassHook(@"YTVersionUtils", @"appName",
                           (IMP)WolFoxAppName, NULL);
    WolFoxInstallClassHook(@"YTVersionUtils", @"appID",
                           (IMP)WolFoxAppIdentifier, NULL);
    WolFoxInstallInstanceHook(@"SSOConfiguration", @"shouldEnableSafariSignIn",
                              (IMP)WolFoxTrue, NULL);
    WolFoxInstallInstanceHook(@"SSOConfiguration", @"temporarilyDisableSafariSignIn",
                              (IMP)WolFoxFalse, NULL);
    WolFoxInstallInstanceHook(@"SSOConfiguration", @"setTemporarilyDisableSafariSignIn:",
                              (IMP)WolFoxSetTemporaryDisabled,
                              &OriginalSSOSetTemporary);
    WolFoxInstallInstanceHook(@"SSOConfiguration",
                              @"initWithClientID:supportedAccountServices:",
                              (IMP)WolFoxConfigurationInit,
                              &OriginalSSOConfigurationInit);

    WolFoxInstallClassHook(@"SSOKeychainHelper", @"accessGroup",
                           (IMP)WolFoxAccessGroup, NULL);
    WolFoxInstallClassHook(@"SSOKeychainHelper", @"sharedAccessGroup",
                           (IMP)WolFoxAccessGroup, NULL);
    WolFoxInstallClassHook(@"SSOKeychainCore", @"accessGroup",
                           (IMP)WolFoxAccessGroup, NULL);
    WolFoxInstallClassHook(@"SSOKeychainCore", @"sharedAccessGroup",
                           (IMP)WolFoxAccessGroup, NULL);
    WolFoxInstallInstanceHook(@"UICKeyChainStore", @"accessGroup",
                              (IMP)WolFoxAccessGroup, NULL);

    WolFoxInstallInstanceHook(@"NSFileManager",
                              @"containerURLForSecurityApplicationGroupIdentifier:",
                              (IMP)WolFoxGroupContainerURL,
                              &OriginalGroupContainerURL);
    WolFoxInstallClassHook(@"GULAppEnvironmentUtil", @"isFromAppStore",
                           (IMP)WolFoxTrue, NULL);
    WolFoxInstallClassHook(@"APMAEU", @"isFAS",
                           (IMP)WolFoxTrue, NULL);
    WolFoxInstallClassHook(@"SSOClientLogin", @"defaultSourceString",
                           (IMP)WolFoxAppIdentifier, NULL);
}
