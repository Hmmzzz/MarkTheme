#import "MTDiagnostic.h"

#import "MTIdentifier.h"
#import "MTResourceKey.h"

@implementation MTDiagnostic

- (instancetype)initWithSeverity:(MTDiagnosticSeverity)severity
                             code:(NSString *)code
                          summary:(NSString *)summary
                      resourceKey:(MTResourceKey *)resourceKey
                          details:(NSDictionary<NSString *, NSString *> *)details
                            error:(NSError **)error {
    NSString *normalizedCode = MTNormalizeIdentifier(code, error);
    if (normalizedCode == nil || summary.length == 0 ||
        severity > MTDiagnosticSeverityError ||
        ![details isKindOfClass:NSDictionary.class]) {
        if (error != NULL && *error == nil) {
            *error = [NSError errorWithDomain:@"com.hmmzzz.marktheme64e.diagnostic"
                                         code:1
                                     userInfo:@{
                NSLocalizedDescriptionKey : @"Diagnostic fields are invalid."
            }];
        }
        return nil;
    }
    for (id key in details) {
        if (![key isKindOfClass:NSString.class] ||
            ![details[key] isKindOfClass:NSString.class]) {
            if (error != NULL) {
                *error = [NSError errorWithDomain:@"com.hmmzzz.marktheme64e.diagnostic"
                                             code:1
                                         userInfo:@{
                    NSLocalizedDescriptionKey :
                        @"Diagnostic details must contain string pairs."
                }];
            }
            return nil;
        }
    }

    self = [super init];
    if (self == nil) return nil;
    _severity = severity;
    _code = [normalizedCode copy];
    _summary = [summary copy];
    _resourceKey = resourceKey;
    _details = [details copy];
    return self;
}

@end
