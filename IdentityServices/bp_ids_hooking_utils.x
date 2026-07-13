#if __arm64e__
#import <ptrauth.h>
#endif

#import "bp_ids_hooking_utils.h"
#import "./Logging.h"
#import "./Tweak.h"

bp_nac_init_type *bp_nac_init_func = NULL;
bp_nac_sign_type *bp_authenticated_nac_sign = NULL;
bp_nac_key_establishment_type *bp_old_nac_key_establishment = NULL;
// Raw pre-hook KE address — preferred for direct oracle (avoids ElleKit trampoline).
bp_nac_key_establishment_type *bp_nac_key_establishment_raw = NULL;

// Last NACInit outputs — Absinthe hello must pair with THIS session-info-request.
static NSData *bp_last_nac_sir = nil;
static void *bp_last_nac_ctx = NULL;

NSData *bp_last_nac_session_info_request(void) {
    return bp_last_nac_sir;
}
void *bp_last_nac_context(void) {
    return bp_last_nac_ctx;
}

static bp_nac_init_type *bp_old_nac_init = NULL;

static int bp_new_nac_init(void *cert, int certLen, void **outCtx, void **outReq, int *outReqLen) {
    int rc = bp_old_nac_init ? bp_old_nac_init(cert, certLen, outCtx, outReq, outReqLen)
                             : bp_nac_init_func(cert, certLen, outCtx, outReq, outReqLen);
    if (rc == 0 && outReq && *outReq && outReqLen && *outReqLen > 0) {
        bp_last_nac_sir = [NSData dataWithBytes:*outReq length:*outReqLen];
        bp_last_nac_ctx = outCtx ? *outCtx : NULL;
        LOG(@"[nac-hook] NACInit captured sir=%d ctx=%p", *outReqLen, bp_last_nac_ctx);
        [bp_last_nac_sir writeToFile:@"/var/mobile/nac_hook_sir.bin" atomically:YES];
    } else {
        LOG(@"[nac-hook] NACInit rc=%d", rc);
    }
    return rc;
}

int bp_new_nac_key_establishment(void* arg1, void* arg2, int arg3) {
    LOG(@"nac_key_establishment was called");
    
    int result = bp_old_nac_key_establishment(arg1, arg2, arg3);
    
    LOG(@"Called the original nac_key_establishment rc=%d", result);

    if (result != 0) {
        LOG(@"nac_key_establishment failed — not signing");
        return result;
    }
    
    LOG(@"Calling nac_sign");
    
    void* validationDataBytes;
    int validationDataLength;
    
    bp_authenticated_nac_sign(arg1, nil, 0, &validationDataBytes, &validationDataLength);
    
    LOG(@"Call to nac_sign is done");
    
    if (!validationDataBytes || validationDataLength < 32) {
        LOG(@"nac_sign returned unusable data len=%d — ignoring", validationDataLength);
        return result;
    }

    NSData* validationData = [NSData dataWithBytes: validationDataBytes length: validationDataLength];
    
    LOG(@"nac_sign returned validation data: %@", validationData);
    
    bp_handle_validation_data(validationData, false);
    
    return result;
}

void bp_setup_hooks() {
    LOG(@"Hooking");
    
    intptr_t ref_addr = bp_get_ref_addr();
    
    bp_nac_init_type *nac_init_func = (bp_nac_init_type *)(ref_addr + bp_nac_init_func_offset);
    bp_nac_key_establishment_type* nac_key_establishment_func = (bp_nac_key_establishment_type*) (ref_addr + bp_nac_key_establishment_func_offset);
    bp_nac_sign_type* nac_sign_func = (bp_nac_sign_type*) (ref_addr + bp_nac_sign_func_offset);

    #if __arm64e__
    bp_nac_init_func = ptrauth_sign_unauthenticated(
        ptrauth_strip(nac_init_func, ptrauth_key_function_pointer),
        ptrauth_key_function_pointer,
        0
    );
    bp_authenticated_nac_sign = ptrauth_sign_unauthenticated(
        ptrauth_strip(nac_sign_func, ptrauth_key_function_pointer),
        ptrauth_key_function_pointer,
        0
    );
    #else
    bp_nac_init_func = nac_init_func;
    bp_authenticated_nac_sign = nac_sign_func;
    #endif

    // Capture the real KE entry BEFORE hooking — direct oracle calls this.
    bp_nac_key_establishment_raw = nac_key_establishment_func;
    MSHookFunction(nac_key_establishment_func, &bp_new_nac_key_establishment, (void**) &bp_old_nac_key_establishment);

    // Also hook NACInit so Absinthe path's SIR is captured alongside helloMessage.
    MSHookFunction(nac_init_func, &bp_new_nac_init, (void**) &bp_old_nac_init);
    // Keep bp_nac_init_func as the callable original after hook.
    if (bp_old_nac_init) bp_nac_init_func = bp_old_nac_init;
    
    LOG(@"Done hooking (nac_init=%p ke_raw=%p ke_tramp=%p sign=%p)", bp_nac_init_func, bp_nac_key_establishment_raw, bp_old_nac_key_establishment, bp_authenticated_nac_sign);
}
