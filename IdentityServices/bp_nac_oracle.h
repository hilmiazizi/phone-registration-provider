#import <Foundation/Foundation.h>

/// Direct NAC mint (no Apple ID, no Absinthe session):
/// FetchCert → NACInit → initializeValidation → NACKeyEstablishment → NACSign.
NSData *bp_direct_nac_mint(NSError **outError);

/// NACInit only — returns session-info-request; optional outCtx for later KE.
NSData *bp_nac_init_session_info_request(void **outCtx, NSError **outError);

/// Absinthe-style initializeValidation (SIR + absinthe-hello + absinthe-udid).
NSDictionary *bp_initialize_validation_absinthe(NSData *sessionInfoRequest,
                                                NSData *helloMessage,
                                                NSString *udid,
                                                NSError **outError);
