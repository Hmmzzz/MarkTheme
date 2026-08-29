#import "MTIconServiceRuntimeMode.h"

#if !defined(MARKTHEME_ICON_SERVICE_RUNTIME_MODE)
#define MARKTHEME_ICON_SERVICE_RUNTIME_MODE 0
#endif

_Static_assert(MARKTHEME_ICON_SERVICE_RUNTIME_MODE >= 0 &&
               MARKTHEME_ICON_SERVICE_RUNTIME_MODE <= 2,
    "MARKTHEME_ICON_SERVICE_RUNTIME_MODE must be disabled, observe, or source");

MTIconServiceRuntimeMode MTIconServiceConfiguredRuntimeMode(void) {
    return (MTIconServiceRuntimeMode)MARKTHEME_ICON_SERVICE_RUNTIME_MODE;
}

NSString *MTIconServiceRuntimeModeName(MTIconServiceRuntimeMode mode) {
    switch (mode) {
        case MTIconServiceRuntimeModeDisabled:
            return @"disabled";
        case MTIconServiceRuntimeModeObserve:
            return @"service-observe";
        case MTIconServiceRuntimeModeSource:
            return @"service-source";
    }
    return @"invalid";
}
