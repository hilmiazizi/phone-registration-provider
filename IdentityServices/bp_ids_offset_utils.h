#import <Foundation/Foundation.h>
#import <mach-o/dyld.h>
#import <dlfcn.h>

extern intptr_t bp_nac_init_func_offset;
extern intptr_t bp_nac_key_establishment_func_offset;
extern intptr_t bp_nac_sign_func_offset;

bool bp_find_offsets();

intptr_t bp_get_ref_addr();

intptr_t bp_find_pattern_offset(const char* pattern, int pattern_length, int target_match_index, intptr_t start_offset, intptr_t max_offset_from_start_offset);

int bp_check_if_func_is_nac_sign_or_nac_key_establishment(intptr_t func_offset);