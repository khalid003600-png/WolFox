#import <Foundation/Foundation.h>

@class UIColor, UITraitCollection;

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString * const WolFoxMasterEnabledKey;
FOUNDATION_EXPORT NSString * const WolFoxOLEDKey;
FOUNDATION_EXPORT NSString * const WolFoxNoAdsKey;
FOUNDATION_EXPORT NSString * const WolFoxSponsorBlockKey;
FOUNDATION_EXPORT NSString * const WolFoxDownloadKey;
FOUNDATION_EXPORT NSString * const WolFoxBackgroundPlaybackKey;
FOUNDATION_EXPORT NSString * const WolFoxPiPKey;
FOUNDATION_EXPORT NSString * const WolFoxFullscreenOrientationKey;
FOUNDATION_EXPORT NSString * const WolFoxSpeedKey;
FOUNDATION_EXPORT NSString * const WolFoxLoopKey;
FOUNDATION_EXPORT NSString * const WolFoxSleepTimerKey;
FOUNDATION_EXPORT NSString * const WolFoxPreferencesDidChangeNotification;

typedef NS_ENUM(NSInteger, WolFoxFullscreenOrientation) {
    WolFoxFullscreenOrientationNeither = 0,
    WolFoxFullscreenOrientationLeft,
    WolFoxFullscreenOrientationRight,
};

FOUNDATION_EXPORT void WolFoxRegisterDefaults(void);
FOUNDATION_EXPORT BOOL WolFoxMasterEnabled(void);
FOUNDATION_EXPORT BOOL WolFoxFeatureEnabled(NSString *key);
FOUNDATION_EXPORT BOOL WolFoxDownloadsEnabled(void);
FOUNDATION_EXPORT NSInteger WolFoxDownloadPlacement(void);
FOUNDATION_EXPORT BOOL WolFoxOLEDActive(UITraitCollection * _Nullable traits);
FOUNDATION_EXPORT UIColor *WolFoxInterfaceBackgroundColor(
    UITraitCollection * _Nullable traits);
FOUNDATION_EXPORT UIColor *WolFoxInterfaceSurfaceColor(
    UITraitCollection * _Nullable traits);
FOUNDATION_EXPORT BOOL WolFoxSponsorBlockEnabled(void);
FOUNDATION_EXPORT void WolFoxSetPreference(NSString *key, BOOL enabled);
FOUNDATION_EXPORT id _Nullable WolFoxPreferenceObject(NSString *key);
FOUNDATION_EXPORT void WolFoxSetPreferenceObject(NSString *key, id _Nullable value);
FOUNDATION_EXPORT NSURL *WolFoxApplicationSupportDirectory(void);
FOUNDATION_EXPORT NSUInteger WolFoxPurgeSystemCaches(void);

NS_ASSUME_NONNULL_END
