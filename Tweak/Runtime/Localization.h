#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString * const WolFoxLanguageKey;

FOUNDATION_EXPORT NSString *WolFoxLocalized(NSString *key);
FOUNDATION_EXPORT NSArray<NSString *> *WolFoxAvailableLanguages(void);
FOUNDATION_EXPORT NSString *WolFoxLanguageDisplayName(NSString *code);
FOUNDATION_EXPORT void WolFoxResetLocalizationCache(void);

NS_ASSUME_NONNULL_END
