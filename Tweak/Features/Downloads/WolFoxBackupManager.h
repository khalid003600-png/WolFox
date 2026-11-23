#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^WolFoxBackupCreationCompletion)(NSURL * _Nullable URL,
                                                NSError * _Nullable error);
typedef void (^WolFoxBackupRestoreCompletion)(NSError * _Nullable error);

@interface WolFoxBackupManager : NSObject

+ (void)createBackupWithCompletion:(WolFoxBackupCreationCompletion)completion;
+ (void)restoreBackupFromURL:(NSURL *)URL
                  completion:(WolFoxBackupRestoreCompletion)completion;

@end

NS_ASSUME_NONNULL_END
