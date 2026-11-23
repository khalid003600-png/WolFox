#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface WolFoxRootOptionsController : UIViewController
@end

FOUNDATION_EXPORT UINavigationController *WolFoxMakeSettingsNavigationController(void);
FOUNDATION_EXPORT void WolFoxApplyAppearance(UIViewController *controller);
FOUNDATION_EXPORT UIViewController *WolFoxMakeDownloadLogController(void);
FOUNDATION_EXPORT NSString *WolFoxDeviceInformationText(void);
FOUNDATION_EXPORT BOOL WolFoxOwnsNavigationController(
    UINavigationController *_Nullable navigation);

NS_ASSUME_NONNULL_END
