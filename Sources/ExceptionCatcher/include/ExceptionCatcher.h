#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block` and converts any Objective-C exception it raises into an
/// NSError, returning nil on success.
///
/// Swift's `do/catch` only sees Swift `Error`s; it cannot catch an Obj-C
/// `NSException`. AVFAudio throws exactly that from `-installTapOnBus:...` when
/// the format doesn't match the live hardware, so without this shim such a
/// throw walks straight past our catch to `objc_terminate()` and abort()s the
/// whole app. Wrap those calls in `ex_catching` to keep them recoverable.
NSError *_Nullable ex_catching(NS_NOESCAPE void (^block)(void));

NS_ASSUME_NONNULL_END
