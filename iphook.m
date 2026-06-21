#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
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

static void swizzleMethod(Class class, SEL originalSel, SEL swizzledSel) {
    Method originalMethod = class_getInstanceMethod(class, originalSel);
    Method swizzledMethod = class_getInstanceMethod(class, swizzledSel);
    
    if (!originalMethod || !swizzledMethod) {
        NSLog(@"[IPHook] 方法不存在: %@", NSStringFromSelector(originalSel));
        return;
    }
    
    method_exchangeImplementations(originalMethod, swizzledMethod);
}

#pragma mark - 1. UILabel (页面显示)

@interface UILabel (IPHook)
- (void)iphook_setText:(NSString *)text;
@end

@implementation UILabel (IPHook)

- (void)iphook_setText:(NSString *)text {
    [self iphook_setText:replaceIP(text)];
}

@end

#pragma mark - 初始化

__attribute__((constructor))
static void iphook_initialize() {
    @autoreleasepool {
        NSLog(@"========================================");
        NSLog(@"[IPHook] 雷达IP替换已加载");
        NSLog(@"[IPHook] 旧IP: %@", kOldServerIP);
        NSLog(@"[IPHook] 新IP: %@", kNewServerIP);
        NSLog(@"========================================");
        
        // ========== 1. UILabel (页面显示) ==========
        swizzleMethod([UILabel class], 
                     @selector(setText:), 
                     @selector(iphook_setText:));
        NSLog(@"[IPHook] ✅ 页面显示hook成功");
        
        // ========== 2. ViewController shareURLString (自动复制) ==========
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
                
                NSLog(@"[IPHook] ✅ 自动复制hook成功");
            }
        }
        
        NSLog(@"[IPHook] 🚀 全部hook完成");
    }
}
