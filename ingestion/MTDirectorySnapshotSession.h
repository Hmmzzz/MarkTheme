#import <Foundation/Foundation.h>

#import "MTAuditedSource.h"
#import "MTImportLimits.h"

@class MTImportCancellationToken;

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const MTDirectorySnapshotSessionErrorDomain;

typedef NS_ENUM(NSInteger, MTDirectorySnapshotSessionErrorCode) {
    MTDirectorySnapshotSessionErrorInvalidRequest = 1,
    MTDirectorySnapshotSessionErrorCancelled = 2,
    MTDirectorySnapshotSessionErrorLimitExceeded = 3,
    MTDirectorySnapshotSessionErrorStorage = 4,
    MTDirectorySnapshotSessionErrorCoordination = 5,
    MTDirectorySnapshotSessionErrorSourceAudit = 6,
    MTDirectorySnapshotSessionErrorSourceRejected = 7,
    MTDirectorySnapshotSessionErrorDestinationVerification = 8,
    MTDirectorySnapshotSessionErrorIO = 9,
    MTDirectorySnapshotSessionErrorCleanup = 10,
};

// The concrete directory scanner is injected synchronously so this ingestion
// session depends only on the audited-source protocol, not on an importer.
typedef id<MTAuditedSource> _Nullable (^MTDirectorySnapshotAuditor)(
    NSURL *directoryURL,
    NSError **error);

@interface MTDirectorySnapshotConfiguration : NSObject

@property(nonatomic, copy, readonly) NSURL *sessionsRootURL;
@property(nonatomic, strong, readonly) MTImportLimits *limits;
@property(nonatomic, assign, readonly) uint64_t minimumFreeSpaceReserveBytes;

+ (instancetype)defaultConfiguration;
- (instancetype)initWithSessionsRootURL:(NSURL *)sessionsRootURL
                                  limits:(MTImportLimits *)limits
            minimumFreeSpaceReserveBytes:
                (uint64_t)minimumFreeSpaceReserveBytes
    NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@end

// Owns one complete App-private directory snapshot. The external directory URL
// is used only inside the synchronous security-scope/coordinator accessor and
// is never retained by the returned object.
@interface MTDirectorySnapshotSession : NSObject

@property(nonatomic, copy, readonly) NSString *sessionIdentifier;
@property(nonatomic, copy, readonly) NSURL *sessionDirectoryURL;
@property(nonatomic, copy, readonly) NSURL *snapshotDirectoryURL;
@property(nonatomic, strong, readonly) MTSourceInventory *sourceInventory;
@property(nonatomic, strong, readonly) id<MTAuditedSource> auditedSource;
@property(nonatomic, assign, readonly) NSUInteger fileCount;
@property(nonatomic, assign, readonly) uint64_t byteCount;
@property(nonatomic, assign, readonly, getter=isActive) BOOL active;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

+ (nullable instancetype)
    sessionBySnapshottingDirectoryAtURL:(NSURL *)sourceURL
                           configuration:
                               (MTDirectorySnapshotConfiguration *)configuration
                       cancellationToken:
                           (nullable MTImportCancellationToken *)cancellationToken
                                auditor:(MTDirectorySnapshotAuditor)auditor
                                  error:(NSError **)error;

// Startup-only. It recognizes only canonical directory-session UUIDs and the
// fixed unpublished/published tree names. Unrelated sessions are untouched.
+ (BOOL)discardAbandonedSessionsWithConfiguration:
            (MTDirectorySnapshotConfiguration *)configuration
                                             error:(NSError **)error;

// Idempotently removes this exact private session through descriptor-relative,
// no-follow, bounded cleanup. It never touches the user-selected directory.
- (BOOL)discard:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
