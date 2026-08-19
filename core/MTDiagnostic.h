#import <Foundation/Foundation.h>

@class MTResourceKey;

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSUInteger, MTDiagnosticSeverity) {
    MTDiagnosticSeverityInformation = 0,
    MTDiagnosticSeverityWarning = 1,
    MTDiagnosticSeverityError = 2,
};

@interface MTDiagnostic : NSObject

@property(nonatomic, assign, readonly) MTDiagnosticSeverity severity;
@property(nonatomic, copy, readonly) NSString *code;
@property(nonatomic, copy, readonly) NSString *summary;
@property(nonatomic, strong, readonly, nullable) MTResourceKey *resourceKey;
@property(nonatomic, copy, readonly) NSDictionary<NSString *, NSString *> *details;

- (nullable instancetype)initWithSeverity:(MTDiagnosticSeverity)severity
                                     code:(NSString *)code
                                  summary:(NSString *)summary
                              resourceKey:(nullable MTResourceKey *)resourceKey
                                  details:(NSDictionary<NSString *, NSString *> *)details
                                    error:(NSError **)error
    NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
