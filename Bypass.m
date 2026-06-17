#import <Foundation/Foundation.h>
#import <objc/runtime.h>

#pragma mark - 干掉ShadowTrackerExtra完整性校验
static void empty_method(id self, SEL _cmd) {}
static id empty_return_nil(id self, SEL _cmd) { return nil; }
static BOOL empty_return_yes(id self, SEL _cmd) { return YES; }

__attribute__((constructor)) static void disable_checks() {
    @autoreleasepool {
        // 1. 完全干掉ShadowTrackerExtra，所有方法都变成空函数，再也不会做任何校验
        Class Shadow = objc_getClass("ShadowTrackerExtra");
        if (Shadow) {
            unsigned int count;
            Method *methods = class_copyMethodList(Shadow, &count);
            for (int i=0; i<count; i++) {
                SEL sel = method_getName(methods[i]);
                const char *type = method_getTypeEncoding(methods[i]);
                if (strstr(type, "v@:")) {
                    class_replaceMethod(Shadow, sel, (IMP)empty_method, type);
                } else if (strstr(type, "B@:")) {
                    class_replaceMethod(Shadow, sel, (IMP)empty_return_yes, type);
                } else {
                    class_replaceMethod(Shadow, sel, (IMP)empty_return_nil, type);
                }
            }
            free(methods);
            NSLog(@"✅ 完整性校验已完全禁用");
        }
        
        // 2. 干掉T3卡密验证
        Class T3 = objc_getClass("T3Verify");
        if (T3) {
            // 登录永远成功
            class_replaceMethod(T3, @selector(loginWithKami:imei:), (IMP)imp_implementationWithBlock(^id(id self, id kami, id imei) {
                id res = [[objc_getClass("T3LoginResult") alloc] init];
                [res setValue:@(YES) forKey:@"success"];
                [res setValue:@(9999999999) forKey:@"endTime"];
                [res setValue:@(YES) forKey:@"available"];
                return res;
            }), "@@:@@");
            
            // 心跳永远成功
            class_replaceMethod(T3, @selector(heartbeatWithKami:statecode:), (IMP)imp_implementationWithBlock(^id(id self, id kami, id code) {
                id res = [[objc_getClass("T3Result") alloc] init];
                [res setValue:@(YES) forKey:@"success"];
                return res;
            }), "@@:@@");
            
            // 初始化永远成功
            class_replaceMethod(T3, @selector(checkInit:), (IMP)empty_return_yes, "B@:^@");
            
            // 拦截所有网络请求
            class_replaceMethod(T3, @selector(httpPost:body:error:), (IMP)empty_return_nil, "@@:@@^@");
            
            NSLog(@"✅ T3验证已完全绕过");
        }
    }
}
