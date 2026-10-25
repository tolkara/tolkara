#import "SystemRoots.h"
#import <TargetConditionals.h>
#include <dlfcn.h>

static NSArray *candidates;
static CFStringRef marker(void){return CFSTR("Tolkara public system certificate source");}
BOOL AKLoadSystemCertificateCandidates(NSString *path) {
    NSData *data=path?[NSData dataWithContentsOfFile:path]:nil;
    if(!data || data.length>4*1024*1024)return NO;
    id items=[NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:NULL error:NULL];
    if(![items isKindOfClass:NSArray.class] || ![items count] || [items count]>1024)return NO;
    NSMutableArray *certificates=[NSMutableArray array];
    for(id der in items){
        if(![der isKindOfClass:NSData.class] || [der length]>65536)return NO;
        SecCertificateRef certificate=SecCertificateCreateWithData(NULL,(__bridge CFDataRef)der);
        if(!certificate)return NO;
        [certificates addObject:CFBridgingRelease(certificate)];
    }
    @synchronized(NSProcessInfo.class){candidates=[certificates copy];}return YES;
}
OSStatus AKOpenSystemKeychain(const char *path,CFTypeRef *keychain) {
    if(!keychain)return errSecParam;*keychain=NULL;
    if(!path || strcmp(path,"/System/Library/Keychains/SystemRootCertificates.keychain"))return errSecUnimplemented;
    @synchronized(NSProcessInfo.class){
        if(!candidates && !AKLoadSystemCertificateCandidates([NSBundle.mainBundle pathForResource:@"CompatibilityRootCertificates" ofType:@"plist"]))return errSecNotAvailable;
        *keychain=CFRetain(marker());return errSecSuccess;
    }
}
OSStatus AKCopySystemCertificates(CFDictionaryRef raw,CFTypeRef *result,BOOL *handled) {
    if(handled)*handled=NO;
    if(!raw || CFGetTypeID(raw)!=CFDictionaryGetTypeID())return errSecParam;
    NSDictionary *query=(__bridge NSDictionary *)raw;
    id list=query[(__bridge id)kSecMatchSearchList];
    if(![list isKindOfClass:NSArray.class] || ![list containsObject:(__bridge id)marker()])return errSecParam;
    if(handled)*handled=YES;if(result)*result=NULL;
    if(!result || [list count]!=1 || ![query[(__bridge id)kSecClass] isEqual:(__bridge id)kSecClassCertificate] ||
       ![query[(__bridge id)kSecReturnRef] isEqual:@YES])return errSecParam;
    NSSet *keys=[NSSet setWithArray:@[(__bridge id)kSecClass,(__bridge id)kSecMatchLimit,(__bridge id)kSecMatchSearchList,
        (__bridge id)kSecReturnRef,(__bridge id)kSecMatchPolicy,(__bridge id)kSecMatchTrustedOnly]];
    for(id key in query)if(![keys containsObject:key])return errSecUnimplemented;
    id limit=query[(__bridge id)kSecMatchLimit];BOOL all=[limit isEqual:(__bridge id)kSecMatchLimitAll];
    if(limit && !all && ![limit isEqual:(__bridge id)kSecMatchLimitOne])return errSecUnimplemented;
    id requested=query[(__bridge id)kSecMatchPolicy];
    if(requested && CFGetTypeID((__bridge CFTypeRef)requested)!=SecPolicyGetTypeID())return errSecParam;
    if(requested) {
        SecPolicyRef ssl=SecPolicyCreateSSL(true,NULL),basic=SecPolicyCreateBasicX509();
        NSDictionary *properties=CFBridgingRelease(SecPolicyCopyProperties((__bridge SecPolicyRef)requested));
        BOOL supported=[properties isEqual:CFBridgingRelease(SecPolicyCopyProperties(ssl))] ||
            [properties isEqual:CFBridgingRelease(SecPolicyCopyProperties(basic))];
        CFRelease(ssl);CFRelease(basic);if(!supported)return errSecUnimplemented;
    }
    // The export already applies macOS's SSL certificate-selection policy.
    // Evaluating a root as an SSL server leaf incorrectly rejects most CAs:
    // native macOS selects 158 roots, while that leaf test accepts only three.
    // Check native root trust here; the original TLS stack validates the peer.
    SecPolicyRef policy=SecPolicyCreateBasicX509();
    NSArray *snapshot;@synchronized(NSProcessInfo.class){snapshot=candidates;}
    NSMutableArray *matching=[NSMutableArray array];
    for(id cert in snapshot){
        SecTrustRef trust=NULL;
        if(SecTrustCreateWithCertificates((__bridge CFTypeRef)cert,policy,&trust))continue;
        // Do not install anchors or bypass trust. The iPad's system trust store
        // must independently accept each root. The macOS SSL selection has
        // already been applied to the public candidate file during packaging.
        SecTrustSetNetworkFetchAllowed(trust,false);
        BOOL trusted=SecTrustEvaluateWithError(trust,NULL);CFRelease(trust);
        if(trusted){[matching addObject:cert];if(!all)break;}
    }
    CFRelease(policy);
    fprintf(stderr,"[security] native-trusted public roots matched=%lu candidates=%lu\n",(unsigned long)matching.count,(unsigned long)snapshot.count);
    if(!matching.count)return errSecItemNotFound;
    *result=CFRetain((__bridge CFTypeRef)(all?matching:matching.firstObject));return errSecSuccess;
}
// Wine enumerates roots through the macOS trust-settings API. Only the public
// system domain is available here; do not fabricate user/admin trust settings.
OSStatus AKCopyTrustSettingsCertificates(uint32_t domain,CFArrayRef *certificates) {
    if(!certificates)return errSecParam;
    *certificates=NULL;
    if(domain>2)return errSecParam;
    if(domain!=2)return errSecItemNotFound;
    CFTypeRef keychain=NULL;
    OSStatus status=AKOpenSystemKeychain("/System/Library/Keychains/SystemRootCertificates.keychain",&keychain);
    if(status)return status;
    NSDictionary *query=@{(__bridge id)kSecClass:(__bridge id)kSecClassCertificate,
        (__bridge id)kSecMatchLimit:(__bridge id)kSecMatchLimitAll,(__bridge id)kSecReturnRef:@YES,
        (__bridge id)kSecMatchTrustedOnly:@YES,(__bridge id)kSecMatchSearchList:@[(__bridge id)keychain]};
    CFTypeRef result=NULL;BOOL handled=NO;
    status=AKCopySystemCertificates((__bridge CFDictionaryRef)query,&result,&handled);
    CFRelease(keychain);
    if(status)return status;
    if(!handled || !result || CFGetTypeID(result)!=CFArrayGetTypeID()) {
        if(result)CFRelease(result);
        return errSecInternalComponent;
    }
    *certificates=(CFArrayRef)result;
    return errSecSuccess;
}

// Certificate DER only. Key export, PEM, aggregates and export options are not
// implemented; never treat a private-key object as a public certificate.
OSStatus AKExportPublicCertificate(CFTypeRef item,uint32_t format,uint32_t flags,const void *parameters,CFDataRef *data) {
    if(!data)return errSecParam;
    *data=NULL;
    if(!item || CFGetTypeID(item)!=SecCertificateGetTypeID())return errSecParam;
    if(format!=9 || flags || parameters)return errSecUnimplemented;
    *data=SecCertificateCopyData((SecCertificateRef)item);
    return *data?errSecSuccess:errSecDecode;
}

#if TARGET_OS_IPHONE
OSStatus SecTrustSettingsCopyCertificates(uint32_t domain,CFArrayRef *certificates){return AKCopyTrustSettingsCertificates(domain,certificates);}
OSStatus SecItemExport(CFTypeRef item,uint32_t format,uint32_t flags,const void *parameters,CFDataRef *data){return AKExportPublicCertificate(item,format,flags,parameters,data);}
OSStatus SecKeychainOpen(const char *path,CFTypeRef *keychain){return AKOpenSystemKeychain(path,keychain);}
OSStatus SecItemCopyMatching(CFDictionaryRef query,CFTypeRef *result){
    BOOL handled=NO;OSStatus status=AKCopySystemCertificates(query,result,&handled);if(handled)return status;
    static OSStatus (*native)(CFDictionaryRef,CFTypeRef *);static dispatch_once_t once;
    dispatch_once(&once,^{void *library=dlopen("/System/Library/Frameworks/Security.framework/Security",RTLD_NOW|RTLD_LOCAL);native=library?dlsym(library,"SecItemCopyMatching"):NULL;});
    return native?native(query,result):errSecUnimplemented;
}
#endif
