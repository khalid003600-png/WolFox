#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT UIViewController *WolFoxMakeSettingsPage(NSString *pageID);
FOUNDATION_EXPORT NSArray<NSDictionary *> *WolFoxSettingsMenu(void);
FOUNDATION_EXPORT UIViewController *WolFoxMakePlayerControlsController(void);
FOUNDATION_EXPORT UIViewController *WolFoxMakeSponsorBlockController(void);
FOUNDATION_EXPORT UIViewController *WolFoxMakeTabBarOptionsController(void);
FOUNDATION_EXPORT UIViewController *WolFoxMakeOverlayOptionsController(void);
FOUNDATION_EXPORT UIViewController *WolFoxMakeStreamingOptionsController(void);
FOUNDATION_EXPORT UIViewController *WolFoxMakeNavigationOptionsController(void);
FOUNDATION_EXPORT UIViewController *WolFoxMakeShortsOptionsController(void);
FOUNDATION_EXPORT UIViewController *WolFoxMakeGlassOptionsController(void);
FOUNDATION_EXPORT UIViewController *WolFoxMakeMiscOptionsController(void);
FOUNDATION_EXPORT UIViewController *WolFoxMakeGestureOptionsController(void);
FOUNDATION_EXPORT void WolFoxStartupDestinations(
    NSArray<NSString *> * _Nullable * _Nullable titles,
    NSArray<NSString *> * _Nullable * _Nullable values);
FOUNDATION_EXPORT UIViewController *WolFoxMakeStartupPickerController(void);
FOUNDATION_EXPORT UIViewController *WolFoxMakeWiFiQualityController(void);
FOUNDATION_EXPORT UIViewController *WolFoxMakeCellularQualityController(void);
FOUNDATION_EXPORT NSString *WolFoxPickerSummary(NSString *key,
                                                NSArray<NSString *> *titles,
                                                NSArray *values,
                                                NSUInteger defaultIndex);
FOUNDATION_EXPORT void WolFoxShowRestartNotice(UIViewController *controller);
FOUNDATION_EXPORT BOOL WolFoxPreferenceNeedsRestart(NSString *key);
typedef void (^WolFoxChoiceHandler)(NSUInteger index);
FOUNDATION_EXPORT void WolFoxPresentSelectionMenu(UIViewController *presenter,
                                                  UIView *sourceView,
                                                  NSString *title,
                                                  NSArray<NSString *> *titles,
                                                  NSUInteger selectedIndex,
                                                  WolFoxChoiceHandler handler);
FOUNDATION_EXPORT void WolFoxPresentChoiceMenu(UIViewController *presenter,
                                               UIView *sourceView,
                                               NSString *title,
                                               NSArray<NSString *> *titles,
                                               NSArray *values,
                                               NSString *key,
                                               NSUInteger defaultIndex,
                                               WolFoxChoiceHandler handler);

FOUNDATION_EXPORT NSArray<NSDictionary *> *WolFoxAllPageDefinitions(void);
FOUNDATION_EXPORT UIViewController *WolFoxMakeSettingsResultsController(
    NSArray<NSArray<NSDictionary *> *> *sections,
    NSArray<NSString *> *sectionTitles);
FOUNDATION_EXPORT void WolFoxUpdateSettingsResultsController(
    UIViewController *controller,
    NSArray<NSArray<NSDictionary *> *> *sections,
    NSArray<NSString *> *sectionTitles);

NS_ASSUME_NONNULL_END
