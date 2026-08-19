#import <Foundation/Foundation.h>

#import "MTAuditedSource.h"
#import "MTImportLimits.h"

@class MTImportCancellationToken;

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const MTExpandedArchiveSessionErrorDomain;

typedef NS_ENUM(NSUInteger, MTExpandedArchiveFormat) {
    MTExpandedArchiveFormatTar = 1,
    MTExpandedArchiveFormatDebianPackage = 2,
};

typedef id<MTAuditedSource> _Nullable (^MTExpandedArchiveAuditor)(
    NSURL *directoryURL,
    NSError **error);

// Owns one private expansion directory. Paths from the container are
// normalized before materialization; links and packaging artifacts are not
// materialized. The audited directory remains alive through asset staging.
@interface MTExpandedArchiveSession : NSObject

@property(nonatomic, copy, readonly) NSString *sessionIdentifier;
@property(nonatomic, copy, readonly) NSURL *expandedDirectoryURL;
@property(nonatomic, strong, readonly) id<MTAuditedSource> auditedSource;
@property(nonatomic, assign, readonly) NSUInteger archiveEntryCount;
@property(nonatomic, assign, readonly) NSUInteger regularFileCount;
@property(nonatomic, assign, readonly) uint64_t expandedByteCount;
@property(nonatomic, assign, readonly, getter=isActive) BOOL active;

+ (nullable instancetype)sessionByExpandingArchiveAtURL:(NSURL *)archiveURL
                                                  format:
    (MTExpandedArchiveFormat)format
                                         sessionsRootURL:
    (NSURL *)sessionsRootURL
                                                  limits:(MTImportLimits *)limits
                                       cancellationToken:
    (nullable MTImportCancellationToken *)cancellationToken
                                                 auditor:
    (MTExpandedArchiveAuditor)auditor
                                                   error:(NSError **)error;

+ (BOOL)discardAbandonedSessionsAtRootURL:(NSURL *)sessionsRootURL
                                    error:(NSError **)error;

- (BOOL)discard:(NSError **)error;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
