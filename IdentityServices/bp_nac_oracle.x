#import "bp_nac_oracle.h"
#import "bp_ids_offset_utils.h"
#import "bp_ids_hooking_utils.h"
#import "./Logging.h"
#import <sys/sysctl.h>

static NSString *const kValidationCertURL =
    @"http://static.ess.apple.com/identity/validation/cert-1.0.plist";
static NSString *const kInitializeValidationURL =
    @"https://identity.ess.apple.com/WebObjects/TDIdentityService.woa/wa/initializeValidation";

static void bp_ess_versions(NSString **outVersion, NSString **outBuild, NSString **outModel) {
    NSString *softwareVersion = @"15.0";
    NSString *build = @"?";
    NSString *model = @"iPhone";

    CFPropertyListRef MGCopyAnswer(CFStringRef question);
    id ver = CFBridgingRelease(MGCopyAnswer(CFSTR("ProductVersion")));
    if ([ver isKindOfClass:NSString.class]) softwareVersion = ver;
    id prod = CFBridgingRelease(MGCopyAnswer(CFSTR("ProductType")));
    if ([prod isKindOfClass:NSString.class]) model = prod;

    char buildBuf[64] = {0};
    size_t buildLen = sizeof(buildBuf);
    if (sysctlbyname("kern.osversion", buildBuf, &buildLen, NULL, 0) == 0 && buildBuf[0]) {
        build = [NSString stringWithUTF8String:buildBuf];
    }
    if (outVersion) *outVersion = softwareVersion;
    if (outBuild) *outBuild = build;
    if (outModel) *outModel = model;
}

static NSString *bp_ess_user_agent(void) {
    NSString *ver = nil, *build = nil, *model = nil;
    bp_ess_versions(&ver, &build, &model);
    // Match identityservicesd registration UA (Jun 29 login_window.txt).
    return [NSString stringWithFormat:
        @"com.apple.invitation-registration [iPhone OS,%@,%@,%@]", ver, build, model];
}

static NSData *bp_http(NSString *urlString, NSData *body, NSError **outError) {
    NSURL *url = [NSURL URLWithString:urlString];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url
                                                       cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                   timeoutInterval:30.0];
    NSString *ua = bp_ess_user_agent();
    [req setValue:ua forHTTPHeaderField:@"User-Agent"];
    // IDS also sends these on initializeValidation / register.
    [req setValue:@"1550" forHTTPHeaderField:@"x-protocol-version"];
    [req setValue:@"com.apple.invitation-registration" forHTTPHeaderField:@"x-id-agent"];
    if (body) {
        req.HTTPMethod = @"POST";
        req.HTTPBody = body;
        [req setValue:@"application/x-apple-plist" forHTTPHeaderField:@"Content-Type"];
    } else {
        req.HTTPMethod = @"GET";
    }

    __block NSData *respData = nil;
    __block NSHTTPURLResponse *httpResp = nil;
    __block NSError *taskError = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);

    [[[NSURLSession sharedSession] dataTaskWithRequest:req
                                     completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        respData = data;
        httpResp = (NSHTTPURLResponse *)response;
        taskError = error;
        dispatch_semaphore_signal(sem);
    }] resume];

    if (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 35 * NSEC_PER_SEC)) != 0) {
        if (outError) {
            *outError = [NSError errorWithDomain:@"bp_nac_oracle" code:1
                                        userInfo:@{NSLocalizedDescriptionKey: @"HTTP timed out"}];
        }
        return nil;
    }
    if (taskError) {
        if (outError) *outError = taskError;
        return nil;
    }
    if (httpResp.statusCode != 200) {
        if (outError) {
            *outError = [NSError errorWithDomain:@"bp_nac_oracle" code:httpResp.statusCode
                                        userInfo:@{
                NSLocalizedDescriptionKey: [NSString stringWithFormat:@"HTTP %ld", (long)httpResp.statusCode]
            }];
        }
        return nil;
    }
    return respData;
}

static NSData *bp_fetch_validation_cert(NSError **outError) {
    NSData *plistData = bp_http(kValidationCertURL, nil, outError);
    if (!plistData) return nil;

    id parsed = [NSPropertyListSerialization propertyListWithData:plistData
                                                          options:0
                                                           format:NULL
                                                            error:outError];
    if (![parsed isKindOfClass:NSDictionary.class]) {
        if (outError && !*outError) {
            *outError = [NSError errorWithDomain:@"bp_nac_oracle" code:2
                                        userInfo:@{NSLocalizedDescriptionKey: @"cert plist not a dict"}];
        }
        return nil;
    }
    NSData *cert = parsed[@"cert"];
    if (![cert isKindOfClass:NSData.class] || cert.length == 0) {
        if (outError) {
            *outError = [NSError errorWithDomain:@"bp_nac_oracle" code:3
                                        userInfo:@{NSLocalizedDescriptionKey: @"missing cert in plist"}];
        }
        return nil;
    }
    LOG(@"[nac-oracle] fetched validation cert (%lu bytes)", (unsigned long)cert.length);
    return cert;
}

/// Full Absinthe-style initializeValidation: SIR + absinthe-hello + absinthe-udid.
NSDictionary *bp_initialize_validation_absinthe(NSData *sessionInfoRequest,
                                                NSData *helloMessage,
                                                NSString *udid,
                                                NSError **outError) {
    NSMutableDictionary *bodyDict = [@{
        @"session-info-request": sessionInfoRequest,
    } mutableCopy];
    if (helloMessage.length) bodyDict[@"absinthe-hello"] = helloMessage;
    if (udid.length) bodyDict[@"absinthe-udid"] = udid;

    NSData *body = [NSPropertyListSerialization dataWithPropertyList:bodyDict
                                                              format:NSPropertyListXMLFormat_v1_0
                                                             options:0
                                                               error:outError];
    if (!body) return nil;

    LOG(@"[nac-oracle] initializeValidation absinthe body keys=%@ sir=%lu hello=%lu udid=%@",
        bodyDict.allKeys, (unsigned long)sessionInfoRequest.length,
        (unsigned long)helloMessage.length, udid);

    NSData *respData = bp_http(kInitializeValidationURL, body, outError);
    if (!respData) return nil;

    [respData writeToFile:@"/var/mobile/nac_oracle_init_resp.plist" atomically:YES];

    id parsed = [NSPropertyListSerialization propertyListWithData:respData
                                                          options:0
                                                           format:NULL
                                                            error:outError];
    if (![parsed isKindOfClass:NSDictionary.class]) {
        if (outError && !*outError) {
            *outError = [NSError errorWithDomain:@"bp_nac_oracle" code:4
                                        userInfo:@{NSLocalizedDescriptionKey: @"initValidation response not a dict"}];
        }
        return nil;
    }
    LOG(@"[nac-oracle] initializeValidation absinthe response keys=%@", [parsed allKeys]);
    return parsed;
}

static NSData *bp_initialize_validation(NSData *sessionInfoRequest, NSError **outError) {
    // Legacy mac-reg style (no hello) — kept for direct oracle attempts.
    NSDictionary *bodyDict = @{ @"session-info-request": sessionInfoRequest };

    NSData *body = [NSPropertyListSerialization dataWithPropertyList:bodyDict
                                                              format:NSPropertyListXMLFormat_v1_0
                                                             options:0
                                                               error:outError];
    if (!body) return nil;

    NSData *respData = bp_http(kInitializeValidationURL, body, outError);
    if (!respData) return nil;

    [respData writeToFile:@"/var/mobile/nac_oracle_init_resp.plist" atomically:YES];

    id parsed = [NSPropertyListSerialization propertyListWithData:respData
                                                          options:0
                                                           format:NULL
                                                            error:outError];
    if (![parsed isKindOfClass:NSDictionary.class]) {
        if (outError && !*outError) {
            *outError = [NSError errorWithDomain:@"bp_nac_oracle" code:4
                                        userInfo:@{NSLocalizedDescriptionKey: @"initValidation response not a dict"}];
        }
        return nil;
    }
    LOG(@"[nac-oracle] initializeValidation response keys=%@", [parsed allKeys]);
    NSNumber *status = parsed[@"status"];
    if (status && status.intValue != 0) {
        LOG(@"[nac-oracle] initializeValidation status=%@", status);
    }
    NSData *sessionInfo = parsed[@"session-info"];
    if (![sessionInfo isKindOfClass:NSData.class] || sessionInfo.length == 0) {
        if (outError) {
            *outError = [NSError errorWithDomain:@"bp_nac_oracle" code:5
                                        userInfo:@{
                NSLocalizedDescriptionKey: [NSString stringWithFormat:
                    @"missing session-info; keys=%@ body=%@", [parsed allKeys], parsed]
            }];
        }
        return nil;
    }
    LOG(@"[nac-oracle] initializeValidation OK (session-info %lu bytes)",
        (unsigned long)sessionInfo.length);
    return sessionInfo;
}

NSData *bp_nac_init_session_info_request(void **outCtx, NSError **outError) {
    if (!bp_nac_init_func) {
        if (outError) {
            *outError = [NSError errorWithDomain:@"bp_nac_oracle" code:6
                                        userInfo:@{NSLocalizedDescriptionKey: @"NACInit not ready"}];
        }
        return nil;
    }
    NSError *err = nil;
    NSData *cert = bp_fetch_validation_cert(&err);
    if (!cert) {
        if (outError) *outError = err;
        return nil;
    }
    void *validationCtx = NULL;
    void *requestBytes = NULL;
    int requestLen = 0;
    int initRc = bp_nac_init_func((void *)cert.bytes, (int)cert.length,
                                  &validationCtx, &requestBytes, &requestLen);
    if (initRc != 0 || !validationCtx || !requestBytes || requestLen <= 0) {
        if (outError) {
            *outError = [NSError errorWithDomain:@"bp_nac_oracle" code:7
                                        userInfo:@{
                NSLocalizedDescriptionKey: [NSString stringWithFormat:@"NACInit rc=%d len=%d", initRc, requestLen]
            }];
        }
        return nil;
    }
    if (outCtx) *outCtx = validationCtx;
    NSData *sir = [NSData dataWithBytes:requestBytes length:requestLen];
    [sir writeToFile:@"/var/mobile/nac_oracle_sir.bin" atomically:YES];
    LOG(@"[nac-oracle] NACInit OK (sir=%d bytes)", requestLen);
    return sir;
}

NSData *bp_direct_nac_mint(NSError **outError) {
    if (!bp_nac_init_func || !bp_old_nac_key_establishment || !bp_authenticated_nac_sign) {
        if (outError) {
            *outError = [NSError errorWithDomain:@"bp_nac_oracle" code:6
                                        userInfo:@{NSLocalizedDescriptionKey: @"NAC function pointers not ready"}];
        }
        return nil;
    }

    @autoreleasepool {
        NSError *err = nil;
        void *validationCtx = NULL;
        NSData *sessionInfoRequest = bp_nac_init_session_info_request(&validationCtx, &err);
        if (!sessionInfoRequest) {
            if (outError) *outError = err;
            return nil;
        }

        NSData *sessionInfo = bp_initialize_validation(sessionInfoRequest, &err);
        if (!sessionInfo) {
            if (outError) *outError = err;
            LOG(@"[nac-oracle] InitializeValidation failed: %@", err);
            return nil;
        }
        [sessionInfo writeToFile:@"/var/mobile/nac_oracle_si.bin" atomically:YES];

        NSMutableData *siOwned = [sessionInfo mutableCopy];
        LOG(@"[nac-oracle] calling KE via trampoline-original (si=%lu)",
            (unsigned long)siOwned.length);
        int keRc = bp_old_nac_key_establishment(validationCtx,
                                                siOwned.mutableBytes,
                                                (int)siOwned.length);
        if (keRc != 0) {
            if (outError) {
                *outError = [NSError errorWithDomain:@"bp_nac_oracle" code:8
                                            userInfo:@{
                    NSLocalizedDescriptionKey: [NSString stringWithFormat:@"NACKeyEstablishment rc=%d", keRc]
                }];
            }
            LOG(@"[nac-oracle] NACKeyEstablishment failed rc=%d (si=%lu)", keRc, (unsigned long)sessionInfo.length);
            return nil;
        }
        LOG(@"[nac-oracle] NACKeyEstablishment OK");

        void *validationDataBytes = NULL;
        int validationDataLength = 0;
        int signRc = bp_authenticated_nac_sign(validationCtx, NULL, 0,
                                               &validationDataBytes, &validationDataLength);
        if (signRc != 0 || !validationDataBytes || validationDataLength <= 0) {
            if (outError) {
                *outError = [NSError errorWithDomain:@"bp_nac_oracle" code:9
                                            userInfo:@{
                    NSLocalizedDescriptionKey: [NSString stringWithFormat:
                        @"NACSign rc=%d len=%d", signRc, validationDataLength]
                }];
            }
            LOG(@"[nac-oracle] NACSign failed rc=%d len=%d", signRc, validationDataLength);
            return nil;
        }

        NSData *blob = [NSData dataWithBytes:validationDataBytes length:validationDataLength];
        LOG(@"[nac-oracle] NACSign OK — %lu byte validation-data", (unsigned long)blob.length);
        return blob;
    }
}
