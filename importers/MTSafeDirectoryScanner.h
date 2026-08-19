#import <Foundation/Foundation.h>

#import "MTAuditedSource.h"
#import "MTImportLimits.h"

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const MTSafeDirectoryScannerErrorDomain;

typedef NS_ENUM(NSInteger, MTSafeDirectoryScannerErrorCode) {
    MTSafeDirectoryScannerErrorInvalidRoot = 1,
    MTSafeDirectoryScannerErrorUnsafePath = 2,
    MTSafeDirectoryScannerErrorUnsupportedNode = 3,
    MTSafeDirectoryScannerErrorLimitExceeded = 4,
    MTSafeDirectoryScannerErrorCanonicalCollision = 5,
    MTSafeDirectoryScannerErrorFileChanged = 6,
    MTSafeDirectoryScannerErrorIO = 7,
    MTSafeDirectoryScannerErrorCancelled = 8,
};

// Retains the audited directory identity and its normalized-to-raw path map.
// It exposes only inventory-gated, size-bounded reads through MTAuditedSource.
@interface MTSafeDirectoryScan : NSObject <MTAuditedSource>

@property(nonatomic, strong, readonly) MTSourceInventory *inventory;

@end

@interface MTSafeDirectoryScanner : NSObject

@property(nonatomic, strong, readonly) MTImportLimits *limits;

- (instancetype)initWithLimits:(MTImportLimits *)limits
    NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

// Read-only directory traversal. It rejects links, special nodes, hardlinks,
// privileged mode bits, canonical/case-folded collisions and limit excess.
- (nullable MTSafeDirectoryScan *)
    scanDirectorySourceAtURL:(NSURL *)directoryURL
                       error:(NSError **)error;

// Long directory audits must remain cancellable before and between every
// bounded digest read. The compatibility method above passes a nil token.
- (nullable MTSafeDirectoryScan *)
    scanDirectorySourceAtURL:(NSURL *)directoryURL
           cancellationToken:
               (nullable MTImportCancellationToken *)cancellationToken
                       error:(NSError **)error;

// Compatibility projection for callers that only need the immutable
// inventory. New metadata/resource readers should retain the audited source.
- (nullable MTSourceInventory *)scanDirectoryAtURL:(NSURL *)directoryURL
                                               error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
