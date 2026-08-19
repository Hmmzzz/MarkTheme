#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const MTStatusBarModuleID;
FOUNDATION_EXPORT NSString *const MTStatusBarSurface;

typedef NS_ENUM(NSUInteger, MTStatusBarSignalKind) {
    MTStatusBarSignalKindCellular = 0,
    MTStatusBarSignalKindWiFi = 1,
};

typedef NS_ENUM(NSUInteger, MTStatusBarArtworkStyle) {
    MTStatusBarArtworkStyleBlack = 0,
    MTStatusBarArtworkStyleLockScreen = 1,
};

// Returns NSNotFound for an unknown kind.
FOUNDATION_EXPORT NSUInteger MTStatusBarMaximumLevel(
    MTStatusBarSignalKind kind);
FOUNDATION_EXPORT NSString * _Nullable MTStatusBarResourceSubject(
    MTStatusBarSignalKind kind,
    MTStatusBarArtworkStyle style,
    NSUInteger level);
FOUNDATION_EXPORT BOOL MTStatusBarResourceSubjectIsSupported(
    NSString *subject);
FOUNDATION_EXPORT NSArray<NSString *> *MTStatusBarRuntimeSubjects(void);

NS_ASSUME_NONNULL_END
