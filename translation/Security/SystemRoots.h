#pragma once
#import <Foundation/Foundation.h>
#import <Security/Security.h>
OSStatus AKOpenSystemKeychain(const char *path,CFTypeRef *keychain);
OSStatus AKCopySystemCertificates(CFDictionaryRef query,CFTypeRef *result,BOOL *handled);
BOOL AKLoadSystemCertificateCandidates(NSString *path);

// macOS ABI values: system trust domain 2, DER X.509 export format 9.
OSStatus AKCopyTrustSettingsCertificates(uint32_t domain,CFArrayRef *certificates);
OSStatus AKExportPublicCertificate(CFTypeRef item,uint32_t format,uint32_t flags,const void *parameters,CFDataRef *data);
