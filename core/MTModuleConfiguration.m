#import "MTModuleConfiguration.h"

#import "MTCanonicalJSON.h"
#import "MTIdentifier.h"

NSString *const MTModuleConfigurationErrorDomain =
    @"com.hmmzzz.marktheme.module-configuration";
NSUInteger const MTModuleConfigurationMaximumCount = 128;
NSUInteger const MTModuleConfigurationMaximumByteCount = 64 * 1024;

static void MTModuleConfigurationSetError(NSError **error,
                                          NSInteger code,
                                          NSString *description,
                                          NSError *_Nullable underlying) {
    if (error == NULL) return;
    NSMutableDictionary *userInfo = [NSMutableDictionary
        dictionaryWithObject:description forKey:NSLocalizedDescriptionKey];
    if (underlying != nil) userInfo[NSUnderlyingErrorKey] = underlying;
    *error = [NSError errorWithDomain:MTModuleConfigurationErrorDomain
                                 code:code
                             userInfo:userInfo];
}

NSDictionary<NSString *, NSDictionary<NSString *, id> *> *
MTNormalizeModuleConfigurations(
    NSDictionary<NSString *, NSDictionary<NSString *, id> *> *configurations,
    NSArray<NSString *> *declaredModuleIDs,
    NSError **error) {
    if (![configurations isKindOfClass:NSDictionary.class] ||
        ![declaredModuleIDs isKindOfClass:NSArray.class] ||
        configurations.count > MTModuleConfigurationMaximumCount) {
        MTModuleConfigurationSetError(error, 1,
            @"Module configurations exceed their collection limit.", nil);
        return nil;
    }

    NSMutableSet<NSString *> *allowed = [NSMutableSet set];
    for (id candidate in declaredModuleIDs) {
        NSString *moduleID = MTNormalizeIdentifier(candidate, NULL);
        if (moduleID == nil) {
            MTModuleConfigurationSetError(error, 1,
                @"A declared module identifier is invalid.", nil);
            return nil;
        }
        [allowed addObject:moduleID];
    }

    NSMutableDictionary<NSString *, NSDictionary<NSString *, id> *> *normalized =
        [NSMutableDictionary dictionaryWithCapacity:configurations.count];
    for (id rawKey in configurations) {
        NSString *moduleID = MTNormalizeIdentifier(rawKey, NULL);
        id value = configurations[rawKey];
        if (moduleID == nil || ![allowed containsObject:moduleID] ||
            normalized[moduleID] != nil ||
            ![value isKindOfClass:NSDictionary.class] ||
            ((NSDictionary *)value).count == 0) {
            MTModuleConfigurationSetError(error, 2,
                @"A module configuration is undeclared, duplicated, or malformed.",
                nil);
            return nil;
        }
        normalized[moduleID] = value;
    }

    NSError *canonicalError = nil;
    NSData *canonicalData = MTCanonicalJSONData(normalized, &canonicalError);
    if (canonicalData == nil ||
        canonicalData.length > MTModuleConfigurationMaximumByteCount) {
        MTModuleConfigurationSetError(error, 3,
            @"Module configurations are not canonical or exceed their byte limit.",
            canonicalError);
        return nil;
    }
    id immutable = [NSJSONSerialization JSONObjectWithData:canonicalData
                                                   options:0
                                                     error:&canonicalError];
    if (![immutable isKindOfClass:NSDictionary.class]) {
        MTModuleConfigurationSetError(error, 3,
            @"Module configurations could not be copied canonically.",
            canonicalError);
        return nil;
    }
    NSData *roundTrip = MTCanonicalJSONData(immutable, &canonicalError);
    if (![roundTrip isEqualToData:canonicalData]) {
        MTModuleConfigurationSetError(error, 3,
            @"Module configurations did not survive canonical round-trip.",
            canonicalError);
        return nil;
    }
    return immutable;
}
