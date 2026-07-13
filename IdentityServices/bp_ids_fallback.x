#import "./bp_ids_fallback.h"
#import "./Tweak.h"
#import "./Logging.h"
#import "../Shared/NSDistributedNotificationCenter.h"
#import "Headers/IDSDAccount.h"
#import "Headers/IDSDAccountController.h"

%hook IDSRegistrationMessage
    - (void) setValidationData:(NSData*)data {
        LOG(@"IDSRegistrationMessage setValidationData was called with data: %@", data);
        
        // After a cold start / signed-in heal, Absinthe often delivers the blob
        // via registration (setValidationData) instead of nac_key_establishment.
        // Accept it whenever a mint is pending — not only on the explicit fallback path.
        if (data.length > 0 && (bp_is_using_fallback_method || bp_validation_request_pending)) {
            bp_handle_validation_data(data, bp_is_using_fallback_method);
        }

        %orig;
    }
%end

@interface IDSRegistrationCenter : NSObject
+ (instancetype)sharedInstance;
- (id)_sendAuthenticateRegistration:(id)reg;
@end

NSError* bp_start_fallback_validation_data_request() {
    LOG(@"Trying to generate validation data via fallback method");
    
    IDSDAccountController* controller = [%c(IDSDAccountController) sharedInstance];
    NSArray<IDSDAccount*>* accounts = controller.accounts;
    
    for (IDSDAccount* account in accounts) {
        // Make sure this is an iMessage account
        if (![account.service.identifier isEqual: @"com.apple.madrid"]) {
            continue;
        }
        
        if (!account.registration) {
            LOG(@"Account has no registration, activating registration");
            [account activateRegistration];
        } else {
            LOG(@"Account has registration");
        }

        id reg = account.registration;
        if (!reg) continue;

        // Prefer authenticate (same path that minted 261B on Jun 29) over bare reregister.
        IDSRegistrationCenter *rc = [%c(IDSRegistrationCenter) sharedInstance];
        if ([rc respondsToSelector:@selector(_sendAuthenticateRegistration:)]) {
            LOG(@"Fallback _sendAuthenticateRegistration:%@", reg);
            [rc _sendAuthenticateRegistration:reg];
        } else {
            LOG(@"Re-registering account");
            [account reregister];
        }
        
        return nil;
    }
    
    return [NSError errorWithDomain: kSuiteName code: 0 userInfo: @{
        @"Error Reason": @"No account found"
    }];
}