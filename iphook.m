//
//  iphook.m - 轻量版：仅 Hook 验证，直接返回成功
//

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// 验证类名
#define kAuthClass "WWWActivation"

// ============================================================
// 🎣 Hook 方法：直接返回成功，不执行任何网络或存储操作
// ============================================================

// 替换 activateCode:completion: —— 直接回调成功
static void hook_activateCode(id self, SEL _cmd, NSString *code, void (^completion)(BOOL, NSError *)) {
    NSLog(@"[AuthHook] activateCode 被调用，直接返回成功");
    if (completion) {
        completion(YES, nil);
    }
}

// 替换 verifyWithCompletion: —— 直接回调成功
static void hook_verifyWithCompletion(id self, SEL _cmd, void (^completion)(BOOL, NSError *)) {
    NSLog(@"[AuthHook] verifyWithCompletion 被调用，直接返回成功");
    if (completion) {
        completion(YES, nil);
    }
}

// 替换 isActivated / isVerified —— 返回 YES
static BOOL hook_isActivated(id self, SEL _cmd) {
    NSLog(@"[AuthHook] isActivated 被调用，返回 YES");
    return YES;
}

// ============================================================
// 🔌 安装 Hook
// ============================================================

__attribute__((constructor))
static void authHookEntry() {
    NSLog(@"========================================");
    NSLog(@"[AuthHook] 轻量卡密验证替换已加载 (无网络/无存储)");
    NSLog(@"========================================");
    
    // 延迟执行，确保目标类已加载
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        
        Class authClass = objc_getClass(kAuthClass);
        if (!authClass) {
            NSLog(@"[AuthHook] ❌ 找不到验证类: %s", kAuthClass);
            return;
        }
        
        NSLog(@"[AuthHook] 找到验证类: %s", kAuthClass);
        
        // 1. Hook activateCode:completion:
        Method m1 = class_getInstanceMethod(authClass, @selector(activateCode:completion:));
        if (m1) {
            method_setImplementation(m1, (IMP)hook_activateCode);
            NSLog(@"[AuthHook] ✅ activateCode:completion: 已替换");
        } else {
            NSLog(@"[AuthHook] ⚠️ 找不到 activateCode:completion:");
        }
        
        // 2. Hook verifyWithCompletion:
        Method m2 = class_getInstanceMethod(authClass, @selector(verifyWithCompletion:));
        if (m2) {
            method_setImplementation(m2, (IMP)hook_verifyWithCompletion);
            NSLog(@"[AuthHook] ✅ verifyWithCompletion: 已替换");
        } else {
            NSLog(@"[AuthHook] ⚠️ 找不到 verifyWithCompletion:");
        }
        
        // 3. Hook isActivated (或 isVerified)
        SEL isActSel = @selector(isActivated);
        Method m3 = class_getInstanceMethod(authClass, isActSel);
        if (m3) {
            method_setImplementation(m3, (IMP)hook_isActivated);
            NSLog(@"[AuthHook] ✅ isActivated 已替换");
        } else {
            // 尝试 isVerified
            isActSel = @selector(isVerified);
            m3 = class_getInstanceMethod(authClass, isActSel);
            if (m3) {
                method_setImplementation(m3, (IMP)hook_isActivated);
                NSLog(@"[AuthHook] ✅ isVerified 已替换");
            } else {
                NSLog(@"[AuthHook] ⚠️ 找不到 isActivated 或 isVerified");
            }
        }
        
        NSLog(@"[AuthHook] 全部 Hook 安装完成");
    });
}
