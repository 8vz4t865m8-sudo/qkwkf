#import <Foundation/Foundation.h>
#import <objc/runtime.h>

static id (*original_login)(id self, SEL _cmd, id kami, id imei);
static id bypass_login(id self, SEL _cmd, id kami, id imei) {
    id res = [[objc_getClass("T3LoginResult") alloc] init];
    [res setValue:@(YES) forKey:@"success"];
    [res setValue:@(9999999999) forKey:@"endTime"];
    [res setValue:@(YES) forKey:@"available"];
    [res setValue:@"ok" forKey:@"core"];
    return res;
}

static id (*original_heartbeat)(id self, SEL _cmd, id kami, id statecode);
static id bypass_heartbeat(id self, SEL _cmd, id kami, id statecode) {
    id res = [[objc_getClass("T3Result") alloc] init];
    [res setValue:@(YES) forKey:@"success"];
    return res;
}

static BOOL (*original_checkInit)(id self, SEL _cmd, id error);
static BOOL bypass_checkInit(id self, SEL _cmd, id error) {
    return YES;
}

static id (*original_httpPost)(id self, SEL _cmd, id url, id body, id *error);
static id bypass_httpPost(id self, SEL _cmd, id url, id body, id *error) {
    return nil;
}

__attribute__((constructor)) static void bypass_init() {
    Class T3Verify = objc_getClass("T3Verify");
    
    // Hook登录
    Method login = class_getInstanceMethod(T3Verify, @selector(loginWithKami:imei:));
    original_login = (void *)method_getImplementation(login);
    method_setImplementation(login, (IMP)bypass_login);
    
    // Hook心跳
    Method heartbeat = class_getInstanceMethod(T3Verify, @selector(heartbeatWithKami:statecode:));
    original_heartbeat = (void *)method_getImplementation(heartbeat);
    method_setImplementation(heartbeat, (IMP)bypass_heartbeat);
    
    // Hook初始化
    Method checkInit = class_getInstanceMethod(T3Verify, @selector(checkInit:));
    original_checkInit = (void *)method_getImplementation(checkInit);
    method_setImplementation(checkInit, (IMP)bypass_checkInit);
    
    // Hook网络请求
    Method httpPost = class_getInstanceMethod(T3Verify, @selector(httpPost:body:error:));
    original_httpPost = (void *)method_getImplementation(httpPost);
    method_setImplementation(httpPost, (IMP)bypass_httpPost);
}
