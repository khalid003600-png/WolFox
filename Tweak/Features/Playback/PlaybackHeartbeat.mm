#import "../../WolFox.h"
#import "../../Runtime/Preferences.h"

BOOL WolFoxShouldBlockPlaybackHeartbeat(NSURL *URL) {
    if (!WolFoxFeatureEnabled(@"YTKACE.Preference.Playback.BlockHeartbeat")) return NO;
    if (![URL.scheme.lowercaseString isEqualToString:@"https"] ||
        ![URL.path isEqualToString:@"/youtubei/v1/player/heartbeat"]) return NO;

    NSString *host = URL.host.lowercaseString;
    return [host isEqualToString:@"youtube.com"] ||
        [host hasSuffix:@".youtube.com"] ||
        [host isEqualToString:@"youtubei.googleapis.com"];
}
