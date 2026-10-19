#import "Tweak.h"
#import "./bp_ids_offset_utils.h"
#import "./bp_ids_hooking_utils.h"
#import "./bp_ids_fallback.h"
#import "./bp_spoof.h"
#import "./bp_nac_oracle.h"
#import "./Logging.h"
#import "../Shared/NSDistributedNotificationCenter.h"
#import "../Shared/BPTimer.h"
#import "Headers/IDSDAccount.h"
#import "Headers/IDSDAccountController.h"

@interface IDSRegistrationMessage : NSObject
- (NSData *)validationData;
- (void)setPushToken:(NSData *)token;
@end

bool bp_has_found_offsets = false;
bool bp_is_using_fallback_method = false;
bool bp_validation_request_pending = false;
static int bp_primary_mint_retries = 0;

// Timer that fires if validation data has not been retrieved via
// the newer method after a certain amount of time
// so we can try again using the fallback method
BPTimer* bp_validation_data_retrieval_using_newer_method_timer = nil;

void bp_handle_validation_data(NSData* validationData, bool isFallbackMethod) {
    if (bp_validation_data_retrieval_using_newer_method_timer) {
        [bp_validation_data_retrieval_using_newer_method_timer invalidate];
        bp_validation_data_retrieval_using_newer_method_timer = nil;
    }
    bp_primary_mint_retries = 0;
    bp_validation_request_pending = false;
    
    double validationDataExpiryTimestamp;
    
    if (isFallbackMethod) {
        // Validation data should expire after 10 minutes
        validationDataExpiryTimestamp = [NSDate.date timeIntervalSince1970] + (10 * 60);
    } else {
        // Let's get fresh data after 30 seconds because why not
        validationDataExpiryTimestamp = [NSDate.date timeIntervalSince1970] + 30;
    }
    
    // Send validation data to the Controller
    // which then sends it to the relay
    [NSDistributedNotificationCenter.defaultCenter
        postNotificationName: kNotificationValidationDataResponse
        object: nil
        userInfo: @{
            kValidationData: validationData,
            kValidationDataExpiryTimestamp: [NSNumber numberWithDouble: validationDataExpiryTimestamp]
        }
    ];
}

@interface IDSValidationQueue: NSObject
    - (void) buildValidationCredentialsIfNeededForSubsystem:(long long)arg1;
    - (void) _sendAbsintheValidationCertRequestIfNeededForSubsystem:(long long)arg1;
    - (void) queueBuildingValidationDataIfNecessaryForMessage:(id)message
                                                   subsystem:(long long)subsystem
                                         withQueueCompletion:(id)completion
                                                   sendBlock:(id)sendBlock;
    - (void) __queueValidationMessage:(id)message subsystem:(long long)subsystem sendBlock:(id)sendBlock;
@end

@interface IDSRegistrationCenter: NSObject
    + (instancetype) sharedInstance;
    - (void) _sendAbsintheValidationCertRequestIfNeeded;
    - (IDSValidationQueue*) validationQueue;
    - (id) _sendAuthenticateRegistration:(id)reg;
    - (void) __sendMessage:(id)message;
@end

// Jun 29 working mint: queue a registration message → IDS builds Absinthe session
// (DeviceIdentity + NACInit + initializeValidation via FTMessageDelivery with
// anisette/push) → KE inside the session → setValidationData: (~261B).
// Raw HTTP initializeValidation returns session-info only and KE returns -42553.
//
// IMPORTANT: `_sendAuthenticateRegistration:` only reaches Absinthe when the
// registration already has an auth cert. After account nuke / partial restore
// we see "Waiting for Authentication Response" + Auth Cert:0x0 and mint stalls.
// Prefer the validation-queue stub path (no Apple ID login required).

@interface IDSPushHandler : NSObject
+ (instancetype)sharedInstance;
- (NSData *)pushToken;
@end

@interface IDSRegistration : NSObject
- (id)authenticationCertificate;
- (NSInteger)registrationStatus;
@end

static NSData *bp_ids_push_token(void) {
    Class cls = %c(IDSPushHandler);
    if (![cls respondsToSelector:@selector(sharedInstance)]) return nil;
    id handler = [cls sharedInstance];
    if ([handler respondsToSelector:@selector(pushToken)]) {
        NSData *tok = [handler pushToken];
        if ([tok isKindOfClass:NSData.class] && tok.length > 0) return tok;
    }
    return nil;
}

static id bp_usable_madrid_registration(void) {
    IDSDAccountController *controller = [%c(IDSDAccountController) sharedInstance];
    for (IDSDAccount *account in controller.accounts) {
        if (![account.service.identifier isEqual:@"com.apple.madrid"]) continue;
        id reg = account.registration;
        if (!reg) continue;
        // Only usable if Apple already authenticated this registration.
        id authCert = nil;
        if ([reg respondsToSelector:@selector(authenticationCertificate)]) {
            authCert = [reg authenticationCertificate];
        }
        if (!authCert) {
            LOG(@"madrid registration present but AuthCert=nil (status=%ld) — skip authenticate",
                (long)([reg respondsToSelector:@selector(registrationStatus)]
                       ? [reg registrationStatus] : -1));
            continue;
        }
        return reg;
    }
    return nil;
}

static bool bp_queue_stub_validation_message(IDSValidationQueue *vq) {
    Class msgCls = %c(IDSRegistrationMessage);
    if (!msgCls) {
        LOG(@"IDSRegistrationMessage class missing");
        return false;
    }

    id msg = [[msgCls alloc] init];
    NSData *pushToken = bp_ids_push_token();
    if (pushToken && [msg respondsToSelector:@selector(setPushToken:)]) {
        [msg setPushToken:pushToken];
        LOG(@"stub message pushToken=%lu", (unsigned long)pushToken.length);
    } else {
        LOG(@"stub message — no pushToken available yet");
    }

    void (^sendBlock)(id) = ^(id readyMsg) {
        NSData *vd = [readyMsg respondsToSelector:@selector(validationData)]
            ? [readyMsg validationData] : nil;
        LOG(@"validation sendBlock swallowed msg=%@ vdLen=%lu",
            readyMsg, (unsigned long)vd.length);
        if (vd.length >= 32 && bp_validation_request_pending) {
            bp_handle_validation_data(vd, false);
        }
    };

    // Prefer the full queue+build entrypoint (Jun 29: "Queued registration for validation").
    if ([vq respondsToSelector:@selector(queueBuildingValidationDataIfNecessaryForMessage:subsystem:withQueueCompletion:sendBlock:)]) {
        LOG(@"queueBuildingValidationDataIfNecessaryForMessage stub");
        [vq queueBuildingValidationDataIfNecessaryForMessage:msg
                                                   subsystem:1
                                         withQueueCompletion:^(BOOL ok) {
            LOG(@"validation queueCompletion ok=%d", (int)ok);
        }
                                                   sendBlock:sendBlock];
        return true;
    }

    if ([vq respondsToSelector:@selector(__queueValidationMessage:subsystem:sendBlock:)]) {
        LOG(@"__queueValidationMessage + buildValidationCredentials");
        [vq __queueValidationMessage:msg subsystem:1 sendBlock:sendBlock];
        if ([vq respondsToSelector:@selector(buildValidationCredentialsIfNeededForSubsystem:)]) {
            [vq buildValidationCredentialsIfNeededForSubsystem:1];
        }
        return true;
    }

    LOG(@"no queue API — Absinthe cert + buildCredentials only");
    if ([vq respondsToSelector:@selector(_sendAbsintheValidationCertRequestIfNeededForSubsystem:)]) {
        [vq _sendAbsintheValidationCertRequestIfNeededForSubsystem:1];
    }
    if ([vq respondsToSelector:@selector(buildValidationCredentialsIfNeededForSubsystem:)]) {
        [vq buildValidationCredentialsIfNeededForSubsystem:1];
    }
    return true;
}

static bool bp_drive_ids_validation_mint(void) {
    IDSRegistrationCenter *rc = [%c(IDSRegistrationCenter) sharedInstance];
    if (!rc) {
        LOG(@"IDSRegistrationCenter missing");
        return false;
    }

    IDSValidationQueue *vq = [rc respondsToSelector:@selector(validationQueue)]
        ? [rc validationQueue] : nil;

    // Primary: queue stub → IDS Absinthe (works without Apple ID auth cert).
    if (vq) {
        if (bp_queue_stub_validation_message(vq)) return true;
    }

    // Secondary: only if registration is already authenticated.
    id reg = bp_usable_madrid_registration();
    if (reg && [rc respondsToSelector:@selector(_sendAuthenticateRegistration:)]) {
        LOG(@"Driving _sendAuthenticateRegistration:%@", reg);
        [rc _sendAuthenticateRegistration:reg];
        return true;
    }

    LOG(@"IDS mint: no validation queue and no usable registration");
    return false;
}

// Primary mint driver — IDS registration/validation queue only (no raw HTTP KE).
bool bp_send_cert_request_if_needed() {
    return bp_drive_ids_validation_mint();
}

static void bp_try_fallback_path(void) {
    bp_is_using_fallback_method = true;
    
    NSError* fallback_error = bp_start_fallback_validation_data_request();
    
    if (fallback_error) {
        [NSDistributedNotificationCenter.defaultCenter
            postNotificationName: kNotificationValidationDataResponse
            object: nil
            userInfo: @{
                kError: [NSError errorWithDomain: kSuiteName code: 0 userInfo: @{
                    @"Error Reason": @"No account found"
                }]
            }
        ];
    }
}

static void bp_schedule_primary_mint_timeout(void) {
    // Absinthe cert fetch can exceed 8–20s after a cold IDS start. Do NOT
    // invalidate on timeout — that deletes the cert mid-flight (we observed
    // mobileactivationd delItem->0 right as the first attempt was progressing).
    bp_validation_data_retrieval_using_newer_method_timer = [BPTimer
        scheduleTimerWithTimeInterval: 45
        completion: ^{
            if (bp_primary_mint_retries < 1) {
                bp_primary_mint_retries++;
                LOG(@"Primary mint timed out; retrying Absinthe once (no invalidate)");
                if (bp_send_cert_request_if_needed()) {
                    bp_schedule_primary_mint_timeout();
                    return;
                }
            }
            
            bp_primary_mint_retries = 0;
            LOG(@"Primary mint failed; trying fallback");
            bp_try_fallback_path();
        }
    ];
}

@interface IDSValidationSession : NSObject
+ (void)purgeCachedCertsForSubsystemMechanism:(long long)mechanism;
@end

void bp_start_validation_data_request() {
    if (bp_validation_data_retrieval_using_newer_method_timer) {
        [bp_validation_data_retrieval_using_newer_method_timer invalidate];
        bp_validation_data_retrieval_using_newer_method_timer = nil;
    }
    
    if (!bp_has_found_offsets) {
        bp_try_fallback_path();
        return;
    }

    // Primary: drive IDS Absinthe via authenticate/queue (Jun 29 path).
    // Direct NAC oracle KE stays broken (-42553) without IDS response handling.
    // Drop any in-memory Absinthe session so this mint reads the spoof plist
    // beepservd just wrote for this request.
    Class sessionCls = %c(IDSValidationSession);
    if ([sessionCls respondsToSelector:@selector(purgeCachedCertsForSubsystemMechanism:)]) {
        LOG(@"Purging Absinthe certs for new spoof identity");
        [sessionCls purgeCachedCertsForSubsystemMechanism:0];
        [sessionCls purgeCachedCertsForSubsystemMechanism:1];
    }
    bp_is_using_fallback_method = false;
    bp_schedule_primary_mint_timeout();
    LOG(@"IDS validation mint (authenticate/queue)");
    if (!bp_send_cert_request_if_needed()) {
        LOG(@"IDS mint kick failed immediately — fallback");
        bp_try_fallback_path();
    }
}

%ctor {
    LOG(@"Started");
    
    // Wait a bit to make sure we don't break things
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        LOG(@"Finding offsets");
        
        bp_has_found_offsets = bp_find_offsets();
        
        if (!bp_has_found_offsets) {
            LOG(@"Finding offsets failed");
            
            bp_is_using_fallback_method = true;
        } else {
            LOG(@"Found offsets");
            
            bp_setup_hooks();
        }
        
        // Listen for validation data requests from
        // the Controller (which listens for requests from the relay)
        [NSDistributedNotificationCenter.defaultCenter
            addObserverForName: (NSString*) kNotificationRequestValidationData
            object: nil
            queue: NSOperationQueue.mainQueue
            usingBlock: ^(NSNotification* notification)
        {
            LOG(@"Received request for validation data");
            bp_primary_mint_retries = 0;
            bp_is_using_fallback_method = false;
            bp_validation_request_pending = true;
            // Notify the Controller that we have received the request
            [NSDistributedNotificationCenter.defaultCenter
                postNotificationName: kNotificationRequestValidationDataAcknowledgement
                object: nil
                userInfo: nil
            ];
            
            bp_start_validation_data_request();
        }];
    });
}