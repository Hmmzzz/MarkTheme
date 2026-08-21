#import "MTRuntimeInvalidation.h"

#import <dispatch/dispatch.h>
#import <notify.h>

#if !defined(MARKTHEME64E_RUNTIME_BUILD_NUMBER)
#error "MARKTHEME64E_RUNTIME_BUILD_NUMBER must identify the exact Runtime build"
#endif

NSString *const MTRuntimeInvalidationNotificationName =
    @"com.hmmzzz.marktheme64e.runtime-store-changed";

BOOL MTRuntimePostInvalidation(void) {
    return notify_post(MTRuntimeInvalidationNotificationName.UTF8String) ==
        NOTIFY_STATUS_OK;
}

NSString *MTRuntimeAcknowledgementNotificationName(uint64_t sequence) {
    return [NSString stringWithFormat:
        @"com.hmmzzz.marktheme64e.runtime-applied.b%llu.s%llu",
        (unsigned long long)MARKTHEME64E_RUNTIME_BUILD_NUMBER,
        (unsigned long long)sequence];
}

BOOL MTRuntimePostInvalidationAndWaitForAcknowledgement(uint64_t sequence) {
    NSString *acknowledgementName =
        MTRuntimeAcknowledgementNotificationName(sequence);
    dispatch_semaphore_t acknowledgement = dispatch_semaphore_create(0);
    int token = NOTIFY_TOKEN_INVALID;
    int registration = notify_register_dispatch(
        acknowledgementName.UTF8String,
        &token,
        dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0),
        ^(__unused int callbackToken) {
            dispatch_semaphore_signal(acknowledgement);
        });
    BOOL posted = MTRuntimePostInvalidation();
    if (registration != NOTIFY_STATUS_OK) return NO;
    BOOL received = posted && dispatch_semaphore_wait(
        acknowledgement,
        dispatch_time(DISPATCH_TIME_NOW, 1500LL * NSEC_PER_MSEC)) == 0;
    notify_cancel(token);
    return received;
}

BOOL MTRuntimePostAcknowledgement(uint64_t sequence) {
    NSString *name = MTRuntimeAcknowledgementNotificationName(sequence);
    return notify_post(name.UTF8String) == NOTIFY_STATUS_OK;
}
