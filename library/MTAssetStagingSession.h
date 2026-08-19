#import <Foundation/Foundation.h>

#import "MTImportLimits.h"

@class MTImportCancellationToken;
@protocol MTAuditedSource;

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const MTAssetStagingSessionErrorDomain;

typedef NS_ENUM(NSInteger, MTAssetStagingSessionErrorCode) {
    MTAssetStagingSessionErrorInvalidRequest = 1,
    MTAssetStagingSessionErrorInactive = 2,
    MTAssetStagingSessionErrorNotInventoried = 3,
    MTAssetStagingSessionErrorLimitExceeded = 4,
    MTAssetStagingSessionErrorCancelled = 5,
    MTAssetStagingSessionErrorSourceRejected = 6,
    MTAssetStagingSessionErrorStorage = 7,
    MTAssetStagingSessionErrorVerification = 8,
    MTAssetStagingSessionErrorCleanup = 9,
};

// Immutable policy. The default root is private temporary App storage; tests
// and future Library transactions can provide a different App-owned root.
@interface MTAssetStagingConfiguration : NSObject

@property(nonatomic, copy, readonly) NSURL *sessionsRootURL;
@property(nonatomic, strong, readonly) MTImportLimits *limits;

+ (instancetype)defaultConfiguration;
- (instancetype)initWithSessionsRootURL:(NSURL *)sessionsRootURL
                                  limits:(MTImportLimits *)limits
    NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@end

// One independently re-opened and verified object owned by its session. The
// URL is derived only from the lowercase content digest, never a source path.
@interface MTStagedAsset : NSObject

@property(nonatomic, copy, readonly) NSString *contentSHA256;
@property(nonatomic, assign, readonly) uint64_t byteCount;
@property(nonatomic, copy, readonly) NSURL *ownedFileURL;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@end

// A single-process transaction that owns content-addressed provisional files.
// It does not update Library current state. Any staging failure invalidates and
// discards the complete session, including objects staged by earlier calls.
@interface MTAssetStagingSession : NSObject

@property(nonatomic, copy, readonly) NSString *sessionIdentifier;
@property(nonatomic, copy, readonly) NSURL *sessionDirectoryURL;
@property(nonatomic, copy, readonly) NSURL *objectsDirectoryURL;
@property(nonatomic, assign, readonly) NSUInteger stagedObjectCount;
@property(nonatomic, assign, readonly) uint64_t stagedByteCount;
@property(nonatomic, assign, readonly, getter=isActive) BOOL active;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

+ (nullable instancetype)
    sessionWithConfiguration:(MTAssetStagingConfiguration *)configuration
                        error:(NSError **)error;

// The source must contain the exact inventoried relative path. New content
// streams into a random 0600 partial file, is independently re-opened and
// SHA-256 verified, then published without overwrite under its digest. A
// digest already verified by this session is source-revalidated without a
// duplicate partial write or destination read.
- (nullable MTStagedAsset *)
    stageAssetAtRelativePath:(NSString *)relativePath
                  fromSource:(id<MTAuditedSource>)source
            maximumByteCount:(uint64_t)maximumByteCount
           cancellationToken:
               (nullable MTImportCancellationToken *)cancellationToken
                       error:(NSError **)error;

// Startup-only sweep. It recognizes only canonical asset-session UUID names,
// the fixed objects directory, digest files, and canonical partial names.
+ (BOOL)discardAbandonedSessionsWithConfiguration:
            (MTAssetStagingConfiguration *)configuration
                                             error:(NSError **)error;

// Idempotently removes this exact session without following links. It never
// touches an audited source or any path outside the configured staging root.
- (BOOL)discard:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
