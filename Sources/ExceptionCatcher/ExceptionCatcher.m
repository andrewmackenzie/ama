#import "ExceptionCatcher.h"

NSError *ex_catching(NS_NOESCAPE void (^block)(void)) {
    @try {
        block();
        return nil;
    } @catch (NSException *e) {
        NSMutableDictionary *info = [NSMutableDictionary dictionary];
        if (e.reason) { info[NSLocalizedDescriptionKey] = e.reason; }
        if (e.name) { info[@"ExceptionName"] = e.name; }
        return [NSError errorWithDomain:@"AmaObjCException" code:0 userInfo:info];
    }
}
