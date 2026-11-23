#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^WolFoxOverlayConfigurator)(UIView *overlay, UIStackView *stack);

FOUNDATION_EXPORT void WolFoxRegisterOverlayConfigurator(
    NSString *identifier,
    WolFoxOverlayConfigurator configurator
);

FOUNDATION_EXPORT UIButton *WolFoxOverlayButton(
    UIStackView *stack,
    NSString *identifier,
    NSString *symbolName,
    id target,
    SEL action
);

// A button's size changed (a new title): lay its row out again so the room
// made for it in YouTube's bars fits.
FOUNDATION_EXPORT void WolFoxOverlayButtonResized(UIButton *_Nullable button);
FOUNDATION_EXPORT void WolFoxFullscreenBarDidLayout(UIView *actions);

FOUNDATION_EXPORT void WolFoxPresentNativeSheet(
    NSString *_Nullable title,
    NSString *_Nullable subtitle,
    UIView *_Nullable sourceView,
    NSArray<NSDictionary *> *actions
);

FOUNDATION_EXPORT id _Nullable WolFoxMakeSheet(NSString *_Nullable title, NSString *_Nullable subtitle);

FOUNDATION_EXPORT BOOL WolFoxShowSheet(id _Nullable sheet, UIViewController *_Nullable presenter);

NS_ASSUME_NONNULL_END
