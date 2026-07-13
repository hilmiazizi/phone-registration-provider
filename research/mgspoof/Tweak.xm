// MGSpoof - rotate the device identity that IDS/APNs/AuthKit see by overriding
// MobileGestalt answers inside the relevant daemons only (scoped, not global).
//
// It reads /var/mobile/.mgspoof.plist once at process start. The reset cycle
// kills the daemons, so they respawn and pick up the new tuple automatically.
//
// Only keys present in the plist are overridden; everything else falls through
// to the real value, so the device keeps working normally.

#import <Foundation/Foundation.h>

extern "C" CFPropertyListRef MGCopyAnswer(CFStringRef question);

static NSDictionary *spoofMap(void) {
    static NSDictionary *map = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        map = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/.mgspoof.plist"];
        if (!map) map = @{};
    });
    return map;
}

// Trace which gestalt keys this process queries (to /var/mobile/mgq.log) so we can
// see whether identityservicesd reads serial/UDID/ECID via MobileGestalt during
// registration. Only active when /var/mobile/.mgq flag exists.
static void mgq(NSString *key, BOOL spoofed) {
    static int on = -1;
    if (on < 0) on = [[NSFileManager defaultManager] fileExistsAtPath:@"/var/mobile/.mgq"] ? 1 : 0;
    if (!on) return;
    static dispatch_queue_t q; static dispatch_once_t o;
    dispatch_once(&o, ^{ q = dispatch_queue_create("mgq", DISPATCH_QUEUE_SERIAL); });
    NSString *line = [NSString stringWithFormat:@"%@ %@ %@\n", [NSDate date], spoofed?@"SPOOF":@"pass ", key];
    dispatch_async(q, ^{
        FILE *f = fopen("/var/mobile/mgq.log", "a"); if (f){ fputs(line.UTF8String, f); fclose(f);} 
    });
}

%hookf(CFPropertyListRef, MGCopyAnswer, CFStringRef question) {
    if (question) {
        NSString *key = (__bridge NSString *)question;
        id value = spoofMap()[key];
        mgq(key, value != nil);
        if (value) {
            // caller owns the returned ref; CFBridgingRetain matches the +1 contract
            return (CFPropertyListRef)CFBridgingRetain(value);
        }
    }
    return %orig;
}

%ctor {
    NSString *proc = [[NSProcessInfo processInfo] processName];
    NSUInteger n = spoofMap().count;
    NSLog(@"[MGSpoof] injected into %@ with %lu overrides", proc, (unsigned long)n);
}
