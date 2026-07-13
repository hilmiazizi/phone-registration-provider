// dcrtforce — only in mobileactivationd.
// Captures the cert-issuance queue from any hooked entry, then issueDCRT on it.
// Arm: /var/mobile/.dcrt_force

#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>

@interface MobileActivationDaemon : NSObject
- (void)issueDCRT:(id)options withCompletionBlock:(void (^)(id error))block;
- (id)copyDCRT:(id *)err;
- (int)getDCRTState;
@end

static void dcrt_log(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void dcrt_log(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[dcrtforce] %@", msg);
    NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], msg];
    NSString *path = @"/var/mobile/dcrtforce.log";
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        [@"" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    [fh seekToEndOfFile];
    [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
    [fh closeFile];
}

static BOOL dcrt_armed(void) {
    return [[NSFileManager defaultManager] fileExistsAtPath:@"/var/mobile/.dcrt_force"];
}
static void dcrt_disarm(void) {
    [[NSFileManager defaultManager] removeItemAtPath:@"/var/mobile/.dcrt_force" error:nil];
}

static dispatch_queue_t g_cert_queue = nil;
static __weak id g_daemon = nil;
static BOOL g_inFlight = NO;

static void dcrt_note_queue(id daemon) {
    g_daemon = daemon;
    // Current queue is valid when we're inside MA's hooked methods.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    dispatch_queue_t q = dispatch_get_current_queue();
#pragma clang diagnostic pop
    if (q) g_cert_queue = q;
}

static void dcrt_check_file(void) {
    NSString *path = @"/private/var/containers/Data/System/"
        @"1598C2CD-DBDB-410C-8455-8BA776C14C49/Library/dcrt/dcrt.der";
    NSData *der = [NSData dataWithContentsOfFile:path];
    dcrt_log(@"dcrt.der present=%d len=%lu", der != nil, (unsigned long)der.length);
    if (der) [der writeToFile:@"/var/mobile/dcrt_after_force.der" atomically:YES];
}

static void dcrt_issue(id daemon) {
    if (g_inFlight || !dcrt_armed()) return;
    if (![daemon respondsToSelector:@selector(issueDCRT:withCompletionBlock:)]) {
        dcrt_log(@"daemon missing issueDCRT");
        return;
    }
    g_inFlight = YES;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    dispatch_queue_t cur = dispatch_get_current_queue();
#pragma clang diagnostic pop
    dcrt_log(@"issueDCRT begin main=%d queue=%@",
             (int)NSThread.isMainThread, cur);

    void (^tryOpts)(id) = ^(id opts) {
        dcrt_log(@"issueDCRT options=%@", opts);
        [daemon issueDCRT:opts withCompletionBlock:^(id error) {
            if (error) {
                dcrt_log(@"issueDCRT FAILED: %@", error);
            } else {
                dcrt_log(@"issueDCRT SUCCESS");
                dcrt_disarm();
            }
            dcrt_check_file();
            g_inFlight = NO;
        }];
    };

    // Prefer DeleteExisting so expired DCRT is replaced
    NSDictionary *opts = @{
        @"DeleteExistingDCRT": @YES,
        @"IgnoreExistingDCRT": @YES,
    };
    tryOpts(opts);
}

static void dcrt_try_from_captured(void) {
    if (!dcrt_armed() || g_inFlight) return;
    id daemon = g_daemon;
    if (!daemon) { dcrt_log(@"no daemon yet"); return; }
    dispatch_queue_t q = g_cert_queue;
    if (q) {
        dcrt_log(@"dispatching issueDCRT onto captured queue %@", q);
        dispatch_async(q, ^{ dcrt_issue(daemon); });
    } else {
        dcrt_log(@"no captured queue — issuing inline");
        dcrt_issue(daemon);
    }
}

%hook MobileActivationDaemon

- (void)issueClientCertificateWithReferenceKey:(id)rk options:(id)opts completion:(id)comp {
    dcrt_log(@"issueClientCertificate opts=%@", opts);
    dcrt_note_queue(self);
    if (dcrt_armed()) dcrt_issue(self);
    %orig;
}

- (void)issueClientCertificateLegacy:(id)arg withCompletionBlock:(id)block {
    dcrt_log(@"issueClientCertificateLegacy");
    dcrt_note_queue(self);
    if (dcrt_armed()) dcrt_issue(self);
    %orig;
}

- (void)issueDCRT:(id)options withCompletionBlock:(id)block {
    dcrt_log(@"issueDCRT ENTRY options=%@ main=%d", options, (int)NSThread.isMainThread);
    dcrt_note_queue(self);
    %orig;
}

- (id)copyDCRT:(id *)err {
    dcrt_note_queue(self);
    id r = %orig;
    dcrt_log(@"copyDCRT -> %@ err=%@", r, err ? *err : nil);
    if (dcrt_armed()) dcrt_try_from_captured();
    return r;
}

- (int)getDCRTState {
    dcrt_note_queue(self);
    int s = %orig;
    dcrt_log(@"getDCRTState -> %d", s);
    if (dcrt_armed()) dcrt_try_from_captured();
    return s;
}

%end

%ctor {
    dcrt_log(@"loaded armed=%d", dcrt_armed());
    // Poll: once something has noted the daemon/queue, fire.
    if (dcrt_armed()) {
        for (int i = 1; i <= 8; i++) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(i * 2 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                dcrt_try_from_captured();
            });
        }
    }
}
