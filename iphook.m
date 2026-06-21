#import <Foundation/Foundation.h>
#import <objc/runtime.h>

// ====== 配置区域 - 改成你自己的服务器 ======
static NSString * const kOldServerIP = @"45.207.210.194";
static NSString * const kNewServerIP = @"123.123.123.123";
static int const kPort = 8080;
// ============================================

#pragma mark - 辅助函数

static NSString *replaceIP(NSString *str) {
    if (!str) return str;
    if ([str rangeOfString:kOldServerIP].location != NSNotFound) {
        NSString *newStr = [str stringByReplacingOccurrencesOfString:kOldServerIP 
                                                          withString:kNewServerIP];
        NSLog(@"[IPHook] 替换: %@ -> %@", str, newStr);
        return newStr;
    }
    return str;
}

#pragma mark - 初始化

__attribute__((constructor))
static void iphook_initialize() {
    @autoreleasepool {
        NSLog(@"========================================");
        NSLog(@"[IPHook] 雷达IP替换已加载");
        NSLog(@"[IPHook] 旧IP: %@", kOldServerIP);
        NSLog(@"[IPHook] 新IP: %@", kNewServerIP);
        NSLog(@"========================================");
        
        // ========== 1. Hook 实际连接 ==========
        Class radarClass = objc_getClass("RadarRelayClient");
        if (radarClass) {
            SEL originalSel = @selector(initWithServerURL:room:);
            Method originalMethod = class_getInstanceMethod(radarClass, originalSel);
            
            if (originalMethod) {
                IMP originalImp = method_getImplementation(originalMethod);
                id (*originalFunc)(id, SEL, NSString *, NSString *) = (void *)originalImp;
                
                IMP swizzledImp = imp_implementationWithBlock(^id(id self, NSString *url, NSString *room) {
                    NSString *newUrl = replaceIP(url);
                    return originalFunc(self, originalSel, newUrl, room);
                });
                
                class_addMethod(radarClass,
                               @selector(iphook_initWithServerURL:room:),
                               swizzledImp,
                               method_getTypeEncoding(originalMethod));
                
                Method swizzledMethod = class_getInstanceMethod(radarClass, @selector(iphook_initWithServerURL:room:));
                method_exchangeImplementations(originalMethod, swizzledMethod);
                
                NSLog(@"[IPHook] ✅ 连接hook成功");
            }
        }
        
        // ========== 2. Hook 显示+复制 ==========
        Class vcClass = objc_getClass("ViewController");
        if (vcClass) {
            SEL shareSel = @selector(shareURLString);
            Method shareMethod = class_getInstanceMethod(vcClass, shareSel);
            
            if (shareMethod) {
                IMP originalImp = method_getImplementation(shareMethod);
                NSString * (*originalFunc)(id, SEL) = (void *)originalImp;
                
                IMP swizzledImp = imp_implementationWithBlock(^NSString *(id self) {
                    NSString *original = originalFunc(self, shareSel);
                    return replaceIP(original);
                });
                
                class_addMethod(vcClass,
                               @selector(iphook_shareURLString),
                               swizzledImp,
                               method_getTypeEncoding(shareMethod));
                
                Method swizzledMethod = class_getInstanceMethod(vcClass, @selector(iphook_shareURLString));
                method_exchangeImplementations(shareMethod, swizzledMethod);
                
                NSLog(@"[IPHook] ✅ 显示+复制hook成功");
            }
        }
        
        NSLog(@"[IPHook] 🚀 全部hook完成");
    }
}
