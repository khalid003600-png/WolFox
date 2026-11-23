#import <Foundation/Foundation.h>
#import <objc/runtime.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT BOOL WolFoxInstallInstanceHook(
    NSString *className,
    NSString *selectorName,
    IMP replacement,
    IMP _Nullable * _Nullable originalStorage
);

FOUNDATION_EXPORT BOOL WolFoxInstallClassHook(
    NSString *className,
    NSString *selectorName,
    IMP replacement,
    IMP _Nullable * _Nullable originalStorage
);

FOUNDATION_EXPORT BOOL WolFoxAddInstanceMethod(
    NSString *className,
    NSString *selectorName,
    IMP implementation,
    const char *typeEncoding
);

FOUNDATION_EXPORT NSUInteger WolFoxInstalledHookCount(void);

FOUNDATION_EXPORT NSArray<NSString *> *WolFoxAppClassNames(void);

NS_ASSUME_NONNULL_END
