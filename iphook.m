#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// ====== 配置区域 - 改成你自己的服务器地址 ======
static NSString * const kOldServerIP = @"45.207.210.194";
static NSString * const kNewServerIP = @"123.123.123.123";
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

#pragma mark - Method Swizzling 辅助函数

static void swizzleMethod(Class class, SEL originalSelector, SEL swizzledSelector) {
    Method originalMethod = class_getInstanceMethod(class, originalSelector);
    Method swizzledMethod = class_getInstanceMethod(class, swizzledSelector);
    
    if (!originalMethod || !swizzledMethod) {
        NSLog(@"[IPHook] 方法不存在: %@ 或 %@", 
              NSStringFromSelector(originalSelector), 
              NSStringFromSelector(swizzledSelector));
        return;
    }
    
    method_exchangeImplementations(originalMethod, swizzledMethod);
}

#pragma mark - UILabel Swizzle

@interface UILabel (IPHook)
- (void)iphook_setText:(NSString *)text;
@end

@implementation UILabel (IPHook)

- (void)iphook_setText:(NSString *)text {
    [self iphook_setText:replaceIP(text)];
}

@end

#pragma mark - UIPasteboard Swizzle

@interface UIPasteboard (IPHook)
- (void)iphook_setString:(NSString *)string;
@end

@implementation UIPasteboard (IPHook)

- (void)iphook_setString:(NSString *)string {
    [self iphook_setString:replaceIP(string)];
}

@end

#pragma mark - 初始化

__attribute__((constructor))
static void iphook_initialize() {
    @autoreleasepool {
        NSLog(@"========================================");
        NSLog(@"[IPHook] 全局IP替换已加载");
        NSLog(@"[IPHook] 旧IP: %@", kOldServerIP);
        NSLog(@"[IPHook] 新IP: %@", kNewServerIP);
        NSLog(@"========================================");
        
        // UILabel
        swizzleMethod([UILabel class], 
                     @selector(setText:), 
                     @selector(iphook_setText:));
        NSLog(@"[IPHook] UILabel hook成功");
        
        // UIPasteboard
        swizzleMethod([UIPasteboard class], 
                     @selector(setString:), 
                     @selector(iphook_setString:));
        NSLog(@"[IPHook] UIPasteboard hook成功");
        
        // RadarRelayClient (动态获取类)
        Class radarClass = objc_getClass("RadarRelayClient");
        if (radarClass) {
            NSLog(@"[IPHook] 找到 RadarRelayClient 类");
            
            SEL originalSel = @selector(initWithServerURL:room:);
            Method originalMethod = class_getInstanceMethod(radarClass, originalSel);
            
            if (originalMethod) {
                IMP originalImp = method_getImplementation(originalMethod);
                id (*originalFunc)(id, SEL, NSString *, NSString *) = (void *)originalImp;
                
                IMP swizzledImp = imp_implementationWithBlock(^id(id self, NSString *url, NSString *room) {
                    NSLog(@"[IPHook] RadarRelayClient 原始: %@", url);
                    NSString *newUrl = replaceIP(url);
                    NSLog(@"[IPHook] RadarRelayClient 替换: %@", newUrl);
                    return originalFunc(self, originalSel, newUrl, room);
                });
                
                class_addMethod(radarClass,
                               @selector(iphook_initWithServerURL:room:),
                               swizzledImp,
                               method_getTypeEncoding(originalMethod));
                
                Method swizzledMethod = class_getInstanceMethod(radarClass, @selector(iphook_initWithServerURL:room:));
                method_exchangeImplementations(originalMethod, swizzledMethod);
                
                NSLog(@"[IPHook] RadarRelayClient hook成功");
            } else {
                NSLog(@"[IPHook] 警告: 找不到 initWithServerURL:room: 方法");
            }
        } else {
            NSLog(@"[IPHook] 警告: 找不到 RadarRelayClient 类");
        }
        
        NSLog(@"[IPHook] 所有hook已安装完成");
    }
}
