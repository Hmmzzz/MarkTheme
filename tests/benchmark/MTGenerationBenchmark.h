#import <Foundation/Foundation.h>

@class MTThemeLibraryRevision;

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const MTGenerationBenchmarkErrorDomain;
FOUNDATION_EXPORT NSUInteger const MTGenerationBenchmarkLookupCount;

typedef BOOL (^MTGenerationBenchmarkOperation)(NSError **error);
typedef NSDictionary<NSString *, NSNumber *> *_Nullable
    (^MTGenerationBenchmarkMeasure)(
        MTGenerationBenchmarkOperation operation,
        NSError **error);

// Measures one full Library revision through pure compile, App-owned publish,
// an independent fresh-reader validation, and a deterministic mixed lookup
// workload. All files stay below runRootURL, which remains caller-owned.
FOUNDATION_EXPORT NSDictionary<NSString *, id> *_Nullable
MTGenerationBenchmarkMeasureRevision(
    MTThemeLibraryRevision *revision,
    NSURL *runRootURL,
    MTGenerationBenchmarkMeasure measure,
    NSError **error);

// Builds three deterministic Library identities from one synthetic static-icon
// revision, with both disjoint and overlapping Bundle IDs, then measures the
// production cross-theme fallback compiler path. Fixture construction is not
// included in the reported compile measurement.
FOUNDATION_EXPORT NSDictionary<NSString *, id> *_Nullable
MTGenerationBenchmarkMeasureThreeLayerMixCompilation(
    MTThemeLibraryRevision *revision,
    MTGenerationBenchmarkMeasure measure,
    NSError **error);

// Creates a test-only zero-record Generation to establish reader/index fixed
// overhead. It deliberately does not claim to be a valid theme compilation,
// because the product Theme manifest contract requires at least one resource.
FOUNDATION_EXPORT NSDictionary<NSString *, id> *_Nullable
MTGenerationBenchmarkMeasureZeroRecordBaseline(
    NSURL *runRootURL,
    MTGenerationBenchmarkMeasure measure,
    NSError **error);

NS_ASSUME_NONNULL_END
