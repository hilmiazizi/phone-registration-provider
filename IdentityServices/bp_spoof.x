// Self-contained device-identity spoof for beepserv, injected into identityservicesd.
// This folds the two former research tweaks (idsbaa + MGSpoof) into beepserv itself:
//
//   * MGCopyAnswer hook  -> the NAC / validation routine reads the SPOOFED
//                           SerialNumber / UniqueDeviceID / IMEI instead of the real
//                           fused-in gestalt values.
//   * baa:false forcing  -> drives validation onto the software Absinthe path so the
//                           (spoofable) gestalt serial is folded into the blob rather
//                           than the SEP-attested real one (which can't be spoofed).
//
// Source of truth is /var/mobile/.beepserv_spoof.plist, written by the Controller
// (BPDeviceIdentifiers). Keys: SerialNumber, UniqueDeviceID,
// InternationalMobileEquipmentIdentity, Enabled (optional bool, default YES). When the
// file is absent or Enabled=NO, every hook is a transparent passthrough (stock).
//
// Scope: this dylib is only injected into identityservicesd (see the .plist filter),
// so the MGCopyAnswer override never leaks to the rest of the system.

#import <Foundation/Foundation.h>
#import "./Logging.h"

CFPropertyListRef MGCopyAnswer(CFStringRef question);

// Read once per process; rotation happens by restarting identityservicesd, which
// reloads this dylib and re-reads the plist (matches the proven MGSpoof behavior).
static NSDictionary* bp_spoof_map(void) {
    static NSDictionary* map = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        map = [NSDictionary dictionaryWithContentsOfFile: @"/var/mobile/.beepserv_spoof.plist"] ?: @{};
    });
    return map;
}

static BOOL bp_spoof_enabled(void) {
    NSDictionary* m = bp_spoof_map();
    if (!m.count) return NO;
    id en = m[@"Enabled"];
    return (en == nil) || [en boolValue];
}

%hookf(CFPropertyListRef, MGCopyAnswer, CFStringRef question) {
    if (question && bp_spoof_enabled()) {
        NSString* key = (__bridge NSString*) question;
        id value = bp_spoof_map()[key];
        if ([value isKindOfClass: NSString.class]) {
            // caller owns the returned ref; CFBridgingRetain matches the +1 contract
            return (CFPropertyListRef) CFBridgingRetain(value);
        }
    }
    return %orig;
}

// IDSValidationQueue drives the BAA-vs-Absinthe decision. NOTE: the `subsystem`
// argument is a scalar enum (long long), NOT an object — never declare it `id`
// (ARC would retain the scalar and crash).
@interface IDSValidationQueue: NSObject
@end

@interface IDSValidationSession: NSObject
@end

%hook IDSValidationQueue
- (void)_sendBAAValidationRequestIfNeededForSubsystem:(long long)subsystem {
    if (bp_spoof_enabled()) {
        LOG(@"[spoof] suppressing BAA cert request (forcing baa:false)");
        return; // never fetch the SEP BAA cert -> software Absinthe path only
    }
    %orig;
}
%end

%hook IDSValidationSession
- (BOOL)isUsingBAA            { return bp_spoof_enabled() ? NO : %orig; }
- (BOOL)_shouldUseBAACertOption { return bp_spoof_enabled() ? NO : %orig; }
- (BOOL)_shouldUseBAAOnly     { return bp_spoof_enabled() ? NO : %orig; }
%end
