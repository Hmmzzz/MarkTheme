#import <Foundation/Foundation.h>

#import "MTImportLimits.h"

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const MTImportSessionErrorDomain;

typedef NS_ENUM(NSInteger, MTImportSessionErrorCode) {
    MTImportSessionErrorInvalidSource = 1,
    MTImportSessionErrorCancelled = 2,
    MTImportSessionErrorLimitExceeded = 3,
    MTImportSessionErrorTemporaryStorage = 4,
    MTImportSessionErrorCoordination = 5,
    MTImportSessionErrorSourceChanged = 6,
    MTImportSessionErrorIO = 7,
    MTImportSessionErrorCleanup = 8,
};

@interface MTImportCancellationToken : NSObject

@property(atomic, assign, readonly, getter=isCancelled) BOOL cancelled;

- (void)cancel;

@end

// Immutable policy object. Production uses +defaultConfiguration; an explicit
// root keeps filesystem behavior deterministic and independently testable.
@interface MTImportSessionConfiguration : NSObject

@property(nonatomic, copy, readonly) NSURL *sessionsRootURL;
@property(nonatomic, strong, readonly) MTImportLimits *limits;

+ (instancetype)defaultConfiguration;
- (instancetype)initWithSessionsRootURL:(NSURL *)sessionsRootURL
                                  limits:(MTImportLimits *)limits
    NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@end

// Owns one app-controlled, fixed-name copy of a selected regular file. The
// source is coordinated and read-only; neither discard path can remove it.
@interface MTImportSession : NSObject

@property(nonatomic, copy, readonly) NSString *sessionIdentifier;
@property(nonatomic, copy, readonly) NSURL *sessionDirectoryURL;
@property(nonatomic, copy, readonly) NSURL *payloadURL;
@property(nonatomic, assign, readonly) uint64_t byteCount;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

+ (nullable instancetype)
    sessionByImportingFileAtURL:(NSURL *)sourceURL
                  configuration:(MTImportSessionConfiguration *)configuration
              cancellationToken:(nullable MTImportCancellationToken *)cancellationToken
                          error:(NSError **)error;

// Call at process startup or before opening a picker, while no session is in
// use. Only canonical session-<uuid> directories and their fixed payload names
// are eligible; unrelated entries are left untouched.
+ (BOOL)discardAbandonedSessionsWithConfiguration:
            (MTImportSessionConfiguration *)configuration
                                             error:(NSError **)error;

// Idempotently removes this exact session. It never follows links and never
// removes the user-selected source URL.
- (BOOL)discard:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
