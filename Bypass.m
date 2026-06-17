#import <Foundation/Foundation.h>
#import <objc/runtime.h>

static void empty_method(id self, SEL _cmd) {}
static id empty_return_nil(id self, SEL _cmd) { return nil; }
static BOOL empty_return_yes(id self, SEL _cmd) { return YES; }

// 优先级101！系统最高优先级，永远第一个执行，比ShadowTrackerExtra早100倍！
__attribute__((constructor(101))) static void disable_checks() {
    @autoreleasepool {
        // 第一个执行：直接废掉ShadowTrackerExtra，它还没醒就被我们干废了
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
        }
        
        // 然后废掉T3验证
        Class T3 = objc_getClass("T3Verify");
        if (T3) {
            class_replaceMethod(T3, @selector(loginWithKami:imei:), (IMP)imp_implementationWithBlock(^id(id self, id k, id i) {
                id res = [[objc_getClass("T3LoginResult") alloc] init];
                [res setValue:@(YES) forKey:@"success"];
                [res setValue:@(9999999999) forKey:@"endTime"];
                [res setValue:@(YES) forKey:@"available"];
                return res;
            }), "@@:@@");
            
            class_replaceMethod(T3, @selector(heartbeatWithKami:statecode:), (IMP)imp_implementationWithBlock(^id(id self, id k, id c) {
                id res = [[objc_getClass("T3Result") alloc] init];
                [res setValue:@(YES) forKey:@"success"];
                return res;
            }), "@@:@@");
            
            class_replaceMethod(T3, @selector(checkInit:), (IMP)empty_return_yes, "B@:^@");
            class_replaceMethod(T3, @selector(httpPost:body:error:), (IMP)empty_return_nil, "@@:@@^@");
        }
    }
}
