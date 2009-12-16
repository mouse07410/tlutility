//
//  KeychainUtilities.m
//  TeX Live Manager
//
//  Created by Adam R. Maxwell on 12/10/09.
/*
 This software is Copyright (c) 2009
 Adam Maxwell. All rights reserved.
 
 Redistribution and use in source and binary forms, with or without
 modification, are permitted provided that the following conditions
 are met:
 
 - Redistributions of source code must retain the above copyright
 notice, this list of conditions and the following disclaimer.
 
 - Redistributions in binary form must reproduce the above copyright
 notice, this list of conditions and the following disclaimer in
 the documentation and/or other materials provided with the
 distribution.
 
 - Neither the name of Adam Maxwell nor the names of any
 contributors may be used to endorse or promote products derived
 from this software without specific prior written permission.
 
 THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
 "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
 LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
 A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
 OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
 SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
 LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
 DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
 THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#import "TLMProxyManager.h"
#import "TLMLogServer.h"
#import "TLMPreferenceController.h"
#import <SystemConfiguration/SystemConfiguration.h>
#import <CoreServices/CoreServices.h>
#import <Security/Security.h>
#import <pthread.h>

@interface TLMProxyManager()
@property (readwrite, copy) NSURL *targetURL;
@end

@implementation TLMProxyManager

@synthesize targetURL = _targetURL;

static bool __TLMGetUserAndPassForProxy(NSString *host, const uint16_t port, NSString **user, NSString **pass)
{
    NSCParameterAssert(user);
    NSCParameterAssert(pass);
    NSCParameterAssert(host);
    OSStatus err;
    
    const char *server = [host UTF8String];
    UInt32 len;
    void *pw;
    SecKeychainItemRef item;
    
    /*
     We're trying to get info on a proxy, so passing e.g. kSecProtocolTypeHTTPProxy seems to make sense.
     However, that doesn't work, so we go with the more general rule of being as vague as reasonably
     possible when finding the password.
     */
    err = SecKeychainFindInternetPassword(NULL, strlen(server), server, 0, NULL, 0, NULL, 0, NULL, port, kSecProtocolTypeAny, kSecAuthenticationTypeAny, &len, &pw, &item);
    
    /*
     Should return failure if the user's proxy doesn't have a password in the keychain.  Note that
     removing a proxy in Sys Prefs or unchecking the password box will remove the proxy password
     from the keychain.
     */
    if (errSecItemNotFound == err) {
        TLMLog(__func__, @"No username/password for proxy %@:%d", host, port);
        return false;
    }
    
    if (noErr != err) {
        TLMLog(__func__, @"unexpected error from SecKeychainFindInternetPassword: %s", GetMacOSStatusErrorString(err));
        return false;
    }
    
    *pass = nil;
    if (pw) *pass = [[[NSString alloc] initWithBytes:pw length:len encoding:NSUTF8StringEncoding] autorelease];
    
    
    /*
     The remaining code is required to read the account name from the keychain item.  Much of
     it was borrowed from
     
     http://www.opensource.apple.com/source/SecurityTool/SecurityTool-32482/keychain_utilities.c?f=text
     
     since this stuff is not really well documented.
     
     Asserts are used in place of error handling, since in most cases I'm not sure how to handle the
     errors in a useful way.
     */
    
    SecKeychainItemFreeContent(NULL, pw);
    
    // call this first to get the item class
    // http://lists.apple.com/archives/Apple-cdsa/2008/Nov/msg00046.html
    SecItemClass itemClass;
    err = SecKeychainItemCopyAttributesAndData(item, NULL, &itemClass, NULL, NULL, NULL);
    assert(noErr == err);
    
    UInt32 itemID;
    switch (itemClass) {
            
        case kSecInternetPasswordItemClass:
            itemID = CSSM_DL_DB_RECORD_INTERNET_PASSWORD;
            break;
        case kSecGenericPasswordItemClass:
            itemID = CSSM_DL_DB_RECORD_GENERIC_PASSWORD;
            break;
        case kSecAppleSharePasswordItemClass:
            itemID = CSSM_DL_DB_RECORD_APPLESHARE_PASSWORD;
            break;
        default:
            itemID = itemClass;
            break;
	}
    
    SecKeychainRef keychain = NULL;
    err = SecKeychainItemCopyKeychain(item, &keychain);
    assert(noErr == err);
    
    SecKeychainAttributeInfo *attrInfo = NULL;
    err = SecKeychainAttributeInfoForItemID(NULL, itemID, &attrInfo);
    assert(noErr == err);
    
    SecKeychainAttributeList *attrList = NULL;
    void *attrs;
    
    // finally, we can actually copy the attributes out of this thing (causes a 2nd authorization dialog to appear)
    err = SecKeychainItemCopyAttributesAndData(item, attrInfo, NULL, &attrList, &len, &attrs);
    assert(noErr == err);
    assert(attrInfo->count == attrList->count);
    
    UInt32 ix;
    *user = nil;
    
    // keychain items appear to have no introspection, so we just have to loop until we find the right tag
    for (ix = 0; ix < attrInfo->count; ix++) {
        
        UInt32 tag = attrInfo->tag[ix];
        UInt32 format = attrInfo->format[ix];
        SecKeychainAttribute *attribute = &attrList->attr[ix];
        assert(tag == attribute->tag);
        
        // CSSM_DB_ATTRIBUTE_FORMAT_BLOB determined by debugging
        if (CSSM_DB_ATTRIBUTE_FORMAT_BLOB != format && CSSM_DB_ATTRIBUTE_FORMAT_STRING != format) continue;
        
        if (0 == attribute->length && NULL == attribute->data) continue;
        
        if (attribute->tag == kSecAccountItemAttr) {
            *user = [[[NSString alloc] initWithBytes:attribute->data length:attribute->length encoding:NSUTF8StringEncoding] autorelease];
            break;
        }
    }
    
    if (keychain) CFRelease(keychain);
    (void) SecKeychainFreeAttributeInfo(attrInfo);
    (void) SecKeychainItemFreeAttributesAndData(attrList, attrs);
    
    return true;
}

static void __TLMSetProxyEnvironment(const char *var, NSString *proxy, const uint16_t port)
{
    NSCParameterAssert(var);
    NSCParameterAssert(proxy);
    
    NSMutableString *displayProxy = [[proxy mutableCopy] autorelease];
    NSString *scheme = [[NSURL URLWithString:proxy] scheme];
    
    /*
     There's no SystemConfiguration key to tell that a given proxy requires a username/password,
     but System Preferences will add a password to the keychain for this proxy if it's required,
     and will delete it from the keychain if the password field content is deleted.  Hence, this
     seems like a pretty reasonable check.
     
     Note that the proxy parameter may or may not have a scheme, depending on how the user entered
     the value in System Preferences.  Keychain lookup requires that we use the value exactly as
     provided, but we need to insert username/password/port at the correct location.  If a scheme
     is absent, we have to prepend it, or wget will fail mysteriously.
     */
    NSString *user, *pass;
    if (__TLMGetUserAndPassForProxy(proxy, port, &user, &pass)) {
        TLMLog(__func__, @"Found username and password from keychain for proxy %@:%d", proxy, port);
        
        // remove this so we insert user/pass at the right place (and we're going to prepend it later anyway)
        if (scheme)
            proxy = [proxy substringFromIndex:[scheme length]];
        if ([proxy hasPrefix:@"://"])
            proxy = [proxy substringFromIndex:3];
        
        proxy = [NSString stringWithFormat:@"%@:%@@%@", user, pass, proxy];
    }
    else {
        // set pass to nil; used as flag later
        user = nil;
        pass = nil;
    }
    
    // now safe to prepend the scheme, since we're done inserting
    if (nil == scheme) scheme = @"http";
    proxy = [NSString stringWithFormat:@"%@://%@", scheme, proxy];
    
    if (port) proxy = [proxy stringByAppendingFormat:@":%d", port];
    
    /*
     Hide password with bullets before logging it, in case this is being echoed to syslog.
     This log statement is critical for debugging, so we need it after all the munging is done.
     */
    [displayProxy setString:proxy];
    const NSRange r = pass ? [displayProxy rangeOfString:pass] : NSMakeRange(NSNotFound, 0);
    if (r.length) {
        NSMutableString *stars = [NSMutableString stringWithCapacity:[pass length]];
        for (NSUInteger idx = 0; idx < [pass length]; idx++)
            [stars appendFormat:@"%C", 0x2022];
        [displayProxy replaceCharactersInRange:r withString:stars];
    }
    else if (pass) {
        // non-nil password, but couldn't find it...could assert here
        [displayProxy setString:@"*** ERROR *** unable to find password string; not displaying anything"];
    }
    TLMLog(__func__, @"setting %s = %@", var, displayProxy);
    
    const char *value = [proxy UTF8String];
    if (value && strlen(value)) setenv(var, value, 1);
}

static void __TLMPacCallback(void *info, CFArrayRef proxyList, CFErrorRef error)
{
    bool *finished = info;
    *finished = true;
    TLMLog(__func__, @"Proxy list = %@", proxyList);
    if (NULL == proxyList)
        TLMLog(__func__, @"Error finding proxy: %@", error);
    NSDictionary *firstProxy = (proxyList && CFArrayGetCount(proxyList)) ? (id)CFArrayGetValueAtIndex(proxyList, 0) : nil;
    NSString *proxyType = [firstProxy objectForKey:(id)kCFProxyTypeKey];
    if (proxyType && [proxyType isEqualToString:(id)kCFProxyTypeNone] == NO) {
        
        NSString *proxy = [firstProxy objectForKey:(id)kCFProxyHostNameKey];
        NSString *port = [firstProxy objectForKey:(id)kCFProxyPortNumberKey];
        
        /*
         Should set individually, but that really requires getting a proxy for each 
         request before executing tlmgr so we know the actual host.  This will probably
         work in most common cases.
         */
        __TLMSetProxyEnvironment("http_proxy", proxy, [port intValue]);
        __TLMSetProxyEnvironment("ftp_proxy", proxy, [port intValue]);
    }
    else if (proxyType) {
        TLMLog(__func__, @"No proxy required for URL");
    }
    // nil proxyType is an error
}

static void __TLMProxySettingsChanged(SCDynamicStoreRef store, CFArrayRef changedKeys, void *info)
{
    /*
     Attempt to handle kSCPropNetProxiesExceptionsList?  Probably not worth it...
     */
    NSDictionary *proxies = [(id)SCDynamicStoreCopyProxies(store) autorelease];
    
    TLMProxyManager *self = info;
    
    // try to handle a PAC URL first
    if ([[proxies objectForKey:(id)kSCPropNetProxiesProxyAutoConfigEnable] intValue] != 0) {
        
        NSString *proxy = [proxies objectForKey:(id)kSCPropNetProxiesProxyAutoConfigURLString];
        NSURL *pacURL = nil;
        if (proxy) 
            pacURL = [NSURL URLWithString:proxy];
        
        if (pacURL) {
            
            // need to manually get the underlying proxy for this specific target URL
            NSURL *mirrorURL = [self targetURL];
            NSCParameterAssert(mirrorURL);
            
            TLMLog(__func__, @"Trying to find a proxy for %@ using PAC %@%C", [mirrorURL absoluteString], proxy, 0x2026);
            
            // NB: CFNetworkExecuteProxyAutoConfigurationURL crashes if you pass a NULL context
            bool finished = false;
            CFStreamClientContext ctxt = { 0, &finished, NULL, NULL, NULL };
            
            // 10.6 header says this follows the copy rule, but the docs and 10.5 header say nothing about ownership
            CFRunLoopSourceRef rls = CFNetworkExecuteProxyAutoConfigurationURL((CFURLRef)pacURL, (CFURLRef)mirrorURL, __TLMPacCallback, &ctxt);
            CFStringRef mode = CFSTR("__TLMProxyAutoConfigRunLoopMode");
            CFRunLoopAddSource(CFRunLoopGetCurrent(), rls, mode);
            if (rls) CFRelease(rls);
            
            // callout here will set the proxy environment variables, so we're done after this
            do {
                (void) CFRunLoopRunInMode(mode, 0.1, TRUE);
            } while (false == finished);
        }
        else {
            TLMLog(__func__, @"No PAC URL given");
        }
        
    }
    else {
        
        // manually specified proxies, or disabled PAC (in the latter case we unset proxies, which is what we want)
        
        if ([[proxies objectForKey:(id)kSCPropNetProxiesHTTPEnable] intValue] != 0) {
            
            NSString *proxy = [proxies objectForKey:(id)kSCPropNetProxiesHTTPProxy];
            NSNumber *port = [proxies objectForKey:(id)kSCPropNetProxiesHTTPPort];
            
            __TLMSetProxyEnvironment("http_proxy", proxy, [port shortValue]);
        }
        else if (getenv("http_proxy") != NULL) {
            unsetenv("http_proxy");
            TLMLog(__func__, @"Unset http_proxy");
        }
        
        if ([[proxies objectForKey:(id)kSCPropNetProxiesFTPEnable] intValue] != 0) {
            
            NSString *proxy = [proxies objectForKey:(id)kSCPropNetProxiesFTPProxy];
            NSNumber *port = [proxies objectForKey:(id)kSCPropNetProxiesFTPPort];
            
            __TLMSetProxyEnvironment("ftp_proxy", proxy, [port shortValue]);
        }
        else if (getenv("ftp_proxy") != NULL) {
            unsetenv("ftp_proxy");
            TLMLog(__func__, @"Unset ftp_proxy");
        }
    }
}

// Do not use directly!  File scope only because pthread_once doesn't take an argument.
static id _sharedManager = nil;
static void __TLMProxyManagerInit() { _sharedManager = [TLMProxyManager new]; }

+ (TLMProxyManager *)sharedManager
{
    static pthread_once_t once = PTHREAD_ONCE_INIT;
    (void) pthread_once(&once, __TLMProxyManagerInit);
    return _sharedManager;
}

- (id)init
{
    self = [super init];
    if (self) {
        _targetURL = [[[TLMPreferenceController sharedPreferenceController] defaultServerURL] copy];
        
        // NULL retain/release to avoid a retain cycle
        SCDynamicStoreContext ctxt = { 0, self, NULL, NULL, CFCopyDescription }; 
        _dynamicStore = (void *)SCDynamicStoreCreate(NULL, CFBundleGetIdentifier(CFBundleGetMainBundle()), __TLMProxySettingsChanged, &ctxt);
        _rls = SCDynamicStoreCreateRunLoopSource(kCFAllocatorDefault, _dynamicStore, 0);
        CFRunLoopAddSource(CFRunLoopGetMain(), _rls, kCFRunLoopCommonModes);
        
        NSMutableArray *keys = [NSMutableArray arrayWithObject:[(id)SCDynamicStoreKeyCreateProxies(NULL) autorelease]];
        
        // watch these also, since the default doesn't pick them up
        [keys addObject:(id)kSCPropNetProxiesProxyAutoConfigEnable];
        [keys addObject:(id)kSCPropNetProxiesProxyAutoConfigURLString];
        
        if(SCDynamicStoreSetNotificationKeys(_dynamicStore, (CFArrayRef)keys, NULL) == FALSE)
            TLMLog(__func__, @"unable to register for proxy change notifications");
    }
    return self;
}

- (void)dealloc
{
    if (_rls) CFRunLoopSourceInvalidate(_rls);
    if (_rls) CFRelease(_rls);
    if (_dynamicStore) CFRelease(_dynamicStore);
    [_targetURL release];
    [super dealloc];
}

- (void)updateProxyEnvironmentForURL:(NSURL *)aURL;
{
    [self setTargetURL:(aURL ? aURL : [[TLMPreferenceController sharedPreferenceController] defaultServerURL])];    
    __TLMProxySettingsChanged(_dynamicStore, NULL, self);
}

@end
