#import <Foundation/Foundation.h>

@class UIView;
@class CALayer;
@class UIImage;
@class UIColor;

NS_ASSUME_NONNULL_BEGIN

void WolFoxRouteSpeedMenuItem(id _Nullable renderers, id _Nullable actions, UIView *_Nullable view, id _Nullable responder);

FOUNDATION_EXPORT NSString * const WolFoxVersion;

void WolFoxInstallAdsHooks(void);
NSArray *WolFoxFilterAdSections(NSArray *sections);
void WolFoxInstallPromoHooks(void);
void WolFoxInstallSponsorBlockHooks(void);
void WolFoxInstallDownloadHooks(void);
void WolFoxInstallQueueHooks(void);
void WolFoxQueuePrepareMenuRenderers(id _Nullable renderers);
void WolFoxQueueWrapMenuActions(id _Nullable renderers, id _Nullable actions);
NSAttributedString *_Nullable WolFoxQueuePremiumText(NSAttributedString *_Nullable value);
BOOL WolFoxQueueHasItems(void);
BOOL WolFoxQueueOwnsCurrentVideo(void);
NSString * _Nullable WolFoxLastVideoID(void);
void WolFoxInstallGlobalDownloadMiniPlayer(void);
void WolFoxInstallOLEDHooks(void);
void WolFoxInstallStartupHooks(void);
void WolFoxInstallPremiumLogoHooks(void);
void WolFoxInstallBackgroundPlaybackHooks(void);
void WolFoxInstallPiPHooks(void);
void WolFoxInstallSpeedHooks(void);
double WolFoxStartPlaybackRate(void);
UIImage *WolFoxSpeedButtonImage(BOOL plus);
void WolFoxInstallLoopHooks(void);
void WolFoxInstallQualityButtonHooks(void);
void WolFoxInstallFullscreenHooks(void);
void WolFoxInstallPreviousNextSeekHooks(void);
NSInteger WolFoxPreviousNextSeekSeconds(void);
void WolFoxInstallSponsorMenu(void);
void WolFoxInstallLinkCleaningHooks(void);
void WolFoxInstallHapticHooks(void);
void WolFoxInstallAutoplayHooks(void);
void WolFoxOpenPausedVideoActivated(id player);
void WolFoxFullscreenVideoActivated(id player);
BOOL WolFoxQueueVideoIsLive(NSString * _Nullable videoID, id _Nullable player);
void WolFoxInstallCaptionHooks(void);
void WolFoxInstallTranscriptHooks(void);
NSArray<NSDictionary *> *_Nullable WolFoxParseCaptionCues(NSData *data);
NSArray *_Nullable WolFoxCaptionTracksForResponse(id playerResponse);
NSArray<NSDictionary *> *_Nullable WolFoxCaptionChoicesForResponse(id playerResponse);
NSString *WolFoxCaptionTrackLabel(id track);
NSString *_Nullable WolFoxCaptionTrackLanguage(id track);
NSURL *_Nullable WolFoxCaptionTrackURL(id track);
void WolFoxFetchCuesForURL(NSURL *_Nullable url,
                           void (^completion)(NSArray<NSDictionary *> *_Nullable cues));
void WolFoxFetchCaptionCues(id playerResponse,
                            void (^completion)(NSArray<NSDictionary *> *_Nullable cues,
                                               NSString *_Nullable language));
void WolFoxCaptionsSnapshot(id player);
void WolFoxCaptionsRestore(id player);
void WolFoxApplyPreferredCaptionLanguage(id player);
NSInteger WolFoxCaptionsMode(void);
void WolFoxInstallSleepTimerHooks(void);
void WolFoxInstallDoubleTapHooks(void);
void WolFoxInstallVideoZoomHooks(void);
void WolFoxPauseYouTubePlayer(void);
void WolFoxConfigureTapToSeek(UIView *view);
void WolFoxInstallShortsLimitHooks(void);
void WolFoxInstallShortsStartupHooks(void);
void WolFoxInstallShortsPinchHooks(void);
void WolFoxInstallShortsPiPHooks(void);
void WolFoxSetShortsOverlayFullscreen(UIView *overlay, BOOL fullscreen);
void WolFoxSetShortsElementsFullscreen(UIView *container, BOOL fullscreen);
UIView *WolFoxShortsContainerForView(UIView *view, UIView *fallbackRoot);
BOOL WolFoxShortsNewFullscreenActive(void);
void WolFoxRegisterFadedShortsContainer(UIView *container);
void WolFoxFadeShortsElement(UIView *element);
BOOL WolFoxShortsPivotShowBlocked(void);
void WolFoxSetShortsNewFullscreen(UIView *_Nullable container, BOOL fullscreen);
BOOL WolFoxShortsLimitReached(void);
BOOL WolFoxPlayerIsShorts(id player);
NSInteger WolFoxRealUserInterfaceIdiom(void);
void WolFoxInstallProgressBarHooks(void);
void WolFoxApplyProgressStyleToBar(UIView *bar);
void WolFoxStyleProgressLayer(CALayer *layer, CGFloat trackWidth);
UIImage *WolFoxProgressFillImage(CGFloat width, CGFloat height);
UIColor *WolFoxProgressScrubberTint(void);
void WolFoxInstallStreamingHooks(void);
void WolFoxInstallHLSPlaybackHooks(void);
NSInteger WolFoxPlaybackFixMode(void);
id _Nullable WolFoxHLSOriginalResponse(NSString * _Nullable videoID);
BOOL WolFoxHLSBeginFallback(NSString * _Nullable videoID, void (^ _Nonnull ready)(BOOL available));
void WolFoxInstallShortsHooks(void);
void WolFoxInstallShortsFeedFilterHooks(void);
void WolFoxInstallSideloadCompatibilityHooks(void);
void WolFoxInstallCastCompatibilityHooks(void);
void WolFoxStartCastDiscovery(void);
void WolFoxInstallTabBarHooks(void);
void WolFoxInstallDuoTabBarHooks(void);
void WolFoxInstallDuoDeskPlayerHooks(void);
void WolFoxInstallDuoStatusBarHooks(void);
void WolFoxRefreshPivotBarBackground(void);
BOOL WolFoxLiquidGlassAvailable(void);
NSInteger WolFoxTabBarGlassMode(void);
BOOL WolFoxTabBarOwnGlass(void);
NSInteger WolFoxFrostedTabBarMode(void);
void WolFoxApplyTopNavigationGlass(UIView *container);
UIView *WolFoxMakeSettingsGlass(void);
void WolFoxInstallNavigationBehaviorHooks(void);
void WolFoxInstallPlayerGestureHooks(void);
void WolFoxInstallSettingsEntryHooks(void);
void WolFoxInstallNativeSettingsHooks(void);
void WolFoxInstallOverlayVisibilityHooks(void);
void WolFoxInstallContentVisibilityHooks(void);
void WolFoxInstallNavigationVisibilityHooks(void);
void WolFoxInstallMiscellaneousHooks(void);
void WolFoxInstallCopyCommentHooks(void);
void WolFoxInstallProfilePictureHooks(void);
void WolFoxInstallPostImageSaverHooks(void);
void WolFoxInstallPlaylistDownloaderHooks(void);
BOOL WolFoxProductIdentifierMatches(NSString * _Nullable identifier);
BOOL WolFoxViewIsInsidePlayerOverlay(UIView *view);
void WolFoxHideProductSubtree(UIView *view);
BOOL WolFoxProductOverlayMatches(id overlay);
NSAttributedString * _Nullable WolFoxSubtitleWithoutProductCount(id _Nullable node,
    NSAttributedString * _Nullable text);
void WolFoxInstallNativeShareHooks(void);
void WolFoxReturnDislikeConsiderView(UIView *view);
NSAttributedString *WolFoxDislikeMetaText(id node, NSAttributedString *value);
void WolFoxInstallReturnDislikeHooks(void);
void WolFoxProfileConsiderDisplayView(UIView *view, id node);
void WolFoxScheduleFirstLaunch(void);

NS_ASSUME_NONNULL_END
void WolFoxInstallPlaybackFixHooks(void);
BOOL WolFoxShouldBlockPlaybackHeartbeat(NSURL * _Nullable URL);
NSDictionary<NSString *, NSString *> * _Nullable WolFoxSolveChallenges(NSString * _Nullable playerID,
    NSString * _Nullable playerJS, NSString * _Nonnull type, NSArray<NSString *> * _Nonnull challenges);
NSData * _Nonnull WolFoxTVClientInfo(void);
NSDictionary<NSString *, NSString *> * _Nonnull WolFoxTVHeaders(NSString * _Nullable visitor);
void WolFoxTVFetchPlayerResponse(NSString * _Nonnull videoID,
    void (^ _Nonnull completion)(id _Nullable response, NSString * _Nullable visitor, NSError * _Nullable error));
NSString * _Nonnull WolFoxSolveURLParameterN(NSString * _Nullable playerID, NSString * _Nullable playerJS,
    NSString * _Nonnull URLString);
