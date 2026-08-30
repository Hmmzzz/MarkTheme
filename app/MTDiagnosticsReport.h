#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Reads the ABI capability reports the Runtime writes from each host process
// and renders them as one plain-text summary the user can copy and send.
// Returns a human-readable placeholder when no report exists yet.
FOUNDATION_EXPORT NSString *MTDiagnosticsReportText(void);

// Shared with the collector so an untrusted local datagram cannot choose an
// arbitrary filename or escape the fixed generated Runtime profile set.
FOUNDATION_EXPORT NSArray<NSString *> *
    MTDiagnosticsExpectedProfileIdentifiers(void);

NS_ASSUME_NONNULL_END
