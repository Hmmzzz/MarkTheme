#import <Foundation/Foundation.h>

#include <stdatomic.h>
#include <stdint.h>

NS_ASSUME_NONNULL_BEGIN

typedef BOOL (*MTDialerButtonResolver)(
    id button,
    NSString *normalSubject,
    NSString *highlightedSubject,
    BOOL highlighted);
typedef BOOL (*MTDialerButtonPreparation)(void);

typedef NS_ENUM(uint32_t, MTDialerButtonAdapterState) {
    MTDialerButtonAdapterStateDormant = 0,
    MTDialerButtonAdapterStateScheduled = 1,
    MTDialerButtonAdapterStateInstalled = 2,
    MTDialerButtonAdapterStateRejected = 10,
};

typedef struct MTDialerButtonAdapterObservation {
    uint32_t schemaVersion;
    _Atomic(uint32_t) state;
    _Atomic(uint64_t) installAttempts;
    _Atomic(uint64_t) numberPadCollections;
    _Atomic(uint64_t) numberReloadCalls;
    _Atomic(uint64_t) numberHighlightCalls;
    _Atomic(uint64_t) callButtonCreations;
    _Atomic(uint64_t) callHighlightCalls;
    _Atomic(uint64_t) resolverCalls;
    _Atomic(uint64_t) appliedResults;
    _Atomic(uint64_t) refreshRequests;
    _Atomic(uint64_t) refreshExecutions;
} MTDialerButtonAdapterObservation;

FOUNDATION_EXPORT MTDialerButtonAdapterObservation
    MTRuntimeDialerButtonAdapterObservation;

FOUNDATION_EXPORT BOOL MTDialerButtonAdapterSchedule(
    MTDialerButtonResolver resolver,
    MTDialerButtonPreparation preparation,
    NSError **error);
FOUNDATION_EXPORT void MTDialerButtonAdapterRefresh(void);

NS_ASSUME_NONNULL_END
