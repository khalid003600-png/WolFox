#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^WolFoxMediaImportCompletion)(NSUInteger importedCount,
                                            NSError * _Nullable error);

@interface WolFoxMediaImporter : NSObject

+ (void)importURLs:(NSArray<NSURL *> *)URLs
          category:(NSString *)category
        completion:(WolFoxMediaImportCompletion)completion;

@end

NS_ASSUME_NONNULL_END
