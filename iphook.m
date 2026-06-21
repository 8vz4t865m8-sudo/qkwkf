#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <stdarg.h>

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
    
    BOOL didAddMethod = class_addMethod(class,
                                        originalSelector,
                                        method_getImplementation(swizzledMethod),
                                        method_getTypeEncoding(swizzledMethod));
    
    if (didAddMethod) {
        class_replaceMethod(class,
                           swizzledSelector,
                           method_getImplementation(originalMethod),
                           method_getTypeEncoding(originalMethod));
    } else {
        method_exchangeImplementations(originalMethod, swizzledMethod);
    }
}

static void swizzleClassMethod(Class class, SEL originalSelector, SEL swizzledSelector) {
    Method originalMethod = class_getClassMethod(class, originalSelector);
    Method swizzledMethod = class_getClassMethod(class, swizzledSelector);
    
    if (!originalMethod || !swizzledMethod) {
        NSLog(@"[IPHook] 类方法不存在: %@ 或 %@", 
              NSStringFromSelector(originalSelector), 
              NSStringFromSelector(swizzledSelector));
        return;
    }
    
    Class metaClass = object_getClass(class);
    class_addMethod(metaClass,
                   originalSelector,
                   method_getImplementation(swizzledMethod),
                   method_getTypeEncoding(swizzledMethod));
    
    class_addMethod(metaClass,
                   swizzledSelector,
                   method_getImplementation(originalMethod),
                   method_getTypeEncoding(originalMethod));
    
    Method origMethod = class_getClassMethod(class, originalSelector);
    Method swizMethod = class_getClassMethod(class, swizzledSelector);
    method_exchangeImplementations(origMethod, swizMethod);
}

#pragma mark - NSString Swizzle (类方法)

@interface NSString (IPHook)
+ (instancetype)iphook_stringWithUTF8String:(const char *)nullTerminatedCString;
+ (instancetype)iphook_URLWithString:(NSString *)URLString;
+ (instancetype)iphook_stringWithFormat:(NSString *)format, ...;
@end

@implementation NSString (IPHook)

+ (instancetype)iphook_stringWithUTF8String:(const char *)nullTerminatedCString {
    NSString *result = [self iphook_stringWithUTF8String:nullTerminatedCString];
    return replaceIP(result);
}

+ (instancetype)iphook_URLWithString:(NSString *)URLString {
    return [self iphook_URLWithString:replaceIP(URLString)];
}

+ (instancetype)iphook_stringWithFormat:(NSString *)format, ... {
    va_list args;
    va_start(args, format);
    NSString *result = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    return replaceIP(result);
}

@end

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

#pragma mark - RadarRelayClient Swizzle

@interface RadarRelayClient : NSObject
- (instancetype)initWithServerURL:(NSString *)url room:(NSString *)room;
@end

@interface RadarRelayClient (IPHook)
- (instancetype)iphook_initWithServerURL:(NSString *)url room:(NSString *)room;
@end

@implementation RadarRelayClient (IPHook)

- (instancetype)iphook_initWithServerURL:(NSString *)url room:(NSString *)room {
    NSLog(@"[IPHook] RadarRelayClient 原始: %@", url);
    NSString *newUrl = replaceIP(url);
    NSLog(@"[IPHook] RadarRelayClient 替换: %@", newUrl);
    return [self iphook_initWithServerURL:newUrl room:room];
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
        
        // NSString 类方法
        swizzleClassMethod([NSString class], 
                          @selector(stringWithUTF8String:), 
                          @selector(iphook_stringWithUTF8String:));
        
        swizzleClassMethod([NSString class], 
                          @selector(URLWithString:), 
                          @selector(iphook_URLWithString:));
        
        swizzleClassMethod([NSString class], 
                          @selector(stringWithFormat:), 
                          @selector(iphook_stringWithFormat:));
        
        // UILabel
        swizzleMethod([UILabel class], 
                     @selector(setText:), 
                     @selector(iphook_setText:));
        
        // UIPasteboard
        swizzleMethod([UIPasteboard class], 
                     @selector(setString:), 
                     @selector(iphook_setString:));
        
        // RadarRelayClient
        Class radarClass = objc_getClass("RadarRelayClient");
        if (radarClass) {
            // 用另一种方式swizzle init方法
            Method original = class_getInstanceMethod(radarClass, @selector(initWithServerURL:room:));
            Method swizzled = class_getInstanceMethod(radarClass, @selector(iphook_initWithServerURL:room:));
            if (original && swizzled) {
                method_exchangeImplementations(original, swizzled);
                NSLog(@"[IPHook] RadarRelayClient hook成功");
            } else {
                NSLog(@"[IPHook] RadarRelayClient 方法不存在");
            }
        } else {
            NSLog(@"[IPHook] 警告: 找不到 RadarRelayClient 类");
        }
        
        NSLog(@"[IPHook] 所有hook已安装完成");
    }
}
