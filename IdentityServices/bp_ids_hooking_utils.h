#import <Foundation/Foundation.h>
#import <substrate.h>
#import "bp_ids_offset_utils.h"

typedef int bp_nac_init_type(void *cert_bytes, int cert_len, void **out_validation_ctx, void **out_request_bytes, int *out_request_len);
typedef int bp_nac_key_establishment_type(void *, void *, int);
typedef int bp_nac_sign_type(void *, void *, int, void **, int *);

extern bp_nac_init_type *bp_nac_init_func;
extern bp_nac_key_establishment_type *bp_old_nac_key_establishment;
extern bp_nac_key_establishment_type *bp_nac_key_establishment_raw;
extern bp_nac_sign_type *bp_authenticated_nac_sign;

/// SIR/ctx captured by NACInit hook (Absinthe path). Prefer over a fresh orphan NACInit.
NSData *bp_last_nac_session_info_request(void);
void *bp_last_nac_context(void);

void bp_setup_hooks();
