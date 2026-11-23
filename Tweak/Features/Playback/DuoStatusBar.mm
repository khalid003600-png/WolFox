// iPhone Duo: the status items (camera, clock, Wi-Fi, Live Activities) sit at
// the top of the vertical bar column, and YouTube's watch page runs its video
// under them, so they cover the picture's top corner. While the watch page's
// video is under them, the watch page hides the status bar the way video apps
// do in full screen; the video keeps its full width and only the camera is
// left over it. Hiding the status bar does not change the window's safe area.
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "DuoKit.h"
#import "../../WolFox.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"

NSString * const WolFoxDuoStatusBarHiddenKey = @"YTKACE.Preference.Player.DuoStatusBarHidden";

static BOOL WolFoxStatusHidden;
// Where the status items end while they show. Hidden, only the camera is left
// and the area shrinks, which would otherwise bring the status bar back.
static CGFloat WolFoxStatusBottom;

static UIViewController *WolFoxWatchLayer(UIView *view) {
    Class watchClass = NSClassFromString(@"YTWatchLayerViewController");
    for (UIResponder *current = view; current != nil; current = current.nextResponder) {
        if (watchClass != Nil && [current isKindOfClass:watchClass]) return (UIViewController *)current;
    }
    return nil;
}

// Called from DuoDeskPlayer.mm's layoutSubviews hook on YTPlayerView (YTKACE
// hooks a method once).
void WolFoxDuoStatusBarPlayerLayout(UIView *player) {
    UIViewController *watch = WolFoxWatchLayer(player);
    if (watch == nil) return;
    BOOL hide = NO;
    UIWindow *window = player.window;
    CGRect items = WolFoxFeatureEnabled(WolFoxDuoStatusBarHiddenKey) ? DUOStatusItemsFrame(window) : CGRectNull;
    if (!CGRectIsNull(items)) {
        if (!WolFoxStatusHidden) WolFoxStatusBottom = CGRectGetMaxY(items);
        CGRect video = [player convertRect:player.bounds toView:window];
        BOOL besideColumn = CGRectGetMaxX(video) > CGRectGetMinX(items) && CGRectGetMinX(video) < CGRectGetMaxX(items);
        hide = besideColumn && CGRectGetMinY(video) < WolFoxStatusBottom && CGRectGetMaxY(video) > 0.0;
    }
    if (hide == WolFoxStatusHidden) return;
    WolFoxStatusHidden = hide;
    [UIView animateWithDuration:0.2 animations:^{
        [watch setNeedsStatusBarAppearanceUpdate];
        [window.rootViewController setNeedsStatusBarAppearanceUpdate];
    }];
}

static IMP WolFoxOrigWatchStatusHidden;

static BOOL WolFoxWatchStatusHidden(UIViewController *self, SEL _cmd) {
    if (WolFoxStatusHidden) return YES;
    return ((BOOL (*)(id, SEL))WolFoxOrigWatchStatusHidden)(self, _cmd);
}

void WolFoxInstallDuoStatusBarHooks(void) {
    if (!DUOIsDuo()) return;
    WolFoxInstallInstanceHook(@"YTWatchLayerViewController", @"prefersStatusBarHidden",
                              (IMP)WolFoxWatchStatusHidden, &WolFoxOrigWatchStatusHidden);
}
