//
//  iphook.m - 保留T3验证，去掉自动保存和自动登录（解决闪退）
//  适配 kfun.app (14-26系统版)
//  验证类: WWWActivation
//

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "T3Verify.h"

// ============================================================
// ⚙️ T3 参数（改成你自己的）
// ============================================================

#define T3_LOGIN_CODE      @"B9F97729EC64A6C9"
#define T3_NOTICE_CODE     @"9E37BB60E3AFFCEE"
#define T3_VERSION_CODE    @"2A78BD88E7376215"
#define T3_HEARTBEAT_CODE  @"168AA83248396F84"
#define T3_APPKEY          @"15cab0658474ff4a93ebd8ab8337dab0"
#define T3_RSA_PUBLIC_KEY  @"-----BEGIN PUBLIC KEY-----\n" \
                           "MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQCxj7u3l9DKEyaluMG11BVdfg5z\n" \
                           "/6ieD1iwGzl6txP5G6nAEPxU3BzdEvI4Z20AOAJoGdmflpDq947lgp+tG61G8DeK\n" \
                           "ZLsZWb9t18+L/ThZCCv1xWxb5Llr4mt9yUh5IPHwl5Zy8nxWL64onFJaRIrif+JR\n" \
                           "U0sEt6p3P7lCc3JkPwIDAQAB\n" \
                           "-----END PUBLIC KEY-----"

#define kAuthClass "WWWActivation"

// ============================================================
// 📦 全局状态
// ============================================================

static T3Verify *g_t3        = nil;
static NSString *g_cardNo    = nil;
static NSString *g_stateCode = nil;
static BOOL      g_verified  = NO;
static NSTimer  *g_heartTimer = nil;

// ============================================================
// 🚀 T3 SDK 初始化（带异常保护）
// ============================================================

static void setupT3() {
    if (g_t3) return;
    @try {
        g_t3 = [[T3Verify alloc] init];
        NSError *err = nil;
        [g_t3 initRsaWithLoginCode:T3_LOGIN_CODE
                        noticeCode:T3_NOTICE_CODE
                       versionCode:T3_VERSION_CODE
                     heartbeatCode:T3_HEARTBEAT_CODE
                            appkey:T3_APPKEY
                      rsaPublicKey:T3_RSA_PUBLIC_KEY
                             error:&err];
        if (err) {
            NSLog(@"[AuthHook] T3初始化错误: %@", err);
        }
    } @catch (NSException *e) {
        NSLog(@"[AuthHook] T3初始化异常: %@", e);
    }
}

// ============================================================
// 💓 心跳保活
// ============================================================

static void startHeartbeat() {
    if (g_heartTimer) return;
    g_heartTimer = [NSTimer scheduledTimerWithTimeInterval:30.0
                                                  repeats:YES
                                                    block:^(NSTimer * _Nonnull t) {
        if (!g_verified || !g_cardNo || !g_stateCode) return;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
            @try {
                [g_t3 heartbeatWithKami:g_cardNo statecode:g_stateCode];
            } @catch (NSException *e) {
                NSLog(@"[AuthHook] 心跳异常: %@", e);
            }
        });
    }];
}

// ============================================================
// 🎯 执行 T3 验证（不保存卡密）
// ============================================================

static void runT3Verify(NSString *code, void (^completion)(BOOL success, NSError *error)) {
    if (!code || code.length == 0) {
        if (completion) {
            NSError *err = [NSError errorWithDomain:@"auth" code:-1 userInfo:@{NSLocalizedDescriptionKey:@"卡密为空"}];
            completion(NO, err);
        }
        return;
    }
    
    setupT3();
    if (!g_t3) {
        if (completion) {
            NSError *err = [NSError errorWithDomain:@"auth" code:-2 userInfo:@{NSLocalizedDescriptionKey:@"T3未初始化"}];
            completion(NO, err);
        }
        return;
    }
    
    g_cardNo = code;
    NSString *imei = [T3Verify getMachineCode];
    
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        T3LoginResult *result = nil;
        @try {
            result = [g_t3 loginWithKami:code imei:imei];
        } @catch (NSException *e) {
            NSLog(@"[AuthHook] 验证异常: %@", e);
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) {
                    NSError *err = [NSError errorWithDomain:@"auth" code:-3 userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"验证异常: %@", e]}];
                    completion(NO, err);
                }
            });
            return;
        }
        
        dispatch_async(dispatch_get_main_queue(), ^{
            if (result.success) {
                g_verified  = YES;
                g_stateCode = result.statecode;
                // ❌ 不再保存卡密到本地
                startHeartbeat();
                if (completion) completion(YES, nil);
            } else {
                g_verified  = NO;
                g_stateCode = nil;
                if (completion) completion(NO, result.error);
            }
        });
    });
}

// ============================================================
// 🎣 Hook 1: activateCode:completion: （必须传入卡密，不自动读取）
// ============================================================

static void hook_activateCode(id self, SEL _cmd, NSString *code, void (^completion)(BOOL, NSError *)) {
    NSLog(@"[AuthHook] activateCode 被调用，卡密: %@", code);
    // 不再自动加载保存的卡密，直接使用传入的 code（若为空则验证失败）
    runT3Verify(code, completion);
}

// ============================================================
// 🎣 Hook 2: verifyWithCompletion: （只检查当前状态，不自动验证）
// ============================================================

static void hook_verifyWithCompletion(id self, SEL _cmd, void (^completion)(BOOL, NSError *)) {
    NSLog(@"[AuthHook] verifyWithCompletion 被调用，当前验证状态: %d", g_verified);
    if (g_verified) {
        if (completion) completion(YES, nil);
    } else {
        if (completion) {
            NSError *err = [NSError errorWithDomain:@"auth" code:-1 userInfo:@{NSLocalizedDescriptionKey:@"未验证"}];
            completion(NO, err);
        }
    }
}

// ============================================================
// 🎣 Hook 3: isActivated / isVerified 类方法
// ============================================================

static BOOL hook_isActivated(id self, SEL _cmd) {
    return g_verified;
}

// ============================================================
// 🔌 安装所有 Hook
// ============================================================

__attribute__((constructor))
static void authHookEntry() {
    NSLog(@"========================================");
    NSLog(@"[AuthHook] 卡密验证替换已加载 (kfun专用版 - 无自动保存/登录)");
    NSLog(@"========================================");
    
    // 延迟到主线程执行，等类加载完成
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        
        Class authClass = objc_getClass(kAuthClass);
        if (!authClass) {
            NSLog(@"[AuthHook] ❌ 找不到验证类: %s", kAuthClass);
            return;
        }
        
        NSLog(@"[AuthHook] 找到验证类: %s", kAuthClass);
        
        // 1. Hook 主验证方法
        Method m1 = class_getInstanceMethod(authClass, @selector(activateCode:completion:));
        if (m1) {
            method_setImplementation(m1, (IMP)hook_activateCode);
            NSLog(@"[AuthHook] ✅ activateCode:completion:");
        } else {
            NSLog(@"[AuthHook] ⚠️  找不到 activateCode:completion:");
        }
        
        // 2. Hook 状态验证方法
        Method m2 = class_getInstanceMethod(authClass, @selector(verifyWithCompletion:));
        if (m2) {
            method_setImplementation(m2, (IMP)hook_verifyWithCompletion);
            NSLog(@"[AuthHook] ✅ verifyWithCompletion:");
        } else {
            NSLog(@"[AuthHook] ⚠️  找不到 verifyWithCompletion:");
        }
        
        // 3. Hook 激活状态
        SEL isActSel = @selector(isActivated);
        Method m3 = class_getInstanceMethod(authClass, isActSel);
        if (m3) {
            method_setImplementation(m3, (IMP)hook_isActivated);
            NSLog(@"[AuthHook] ✅ isActivated");
        } else {
            // 尝试 isVerified
            isActSel = @selector(isVerified);
            m3 = class_getInstanceMethod(authClass, isActSel);
            if (m3) {
                method_setImplementation(m3, (IMP)hook_isActivated);
                NSLog(@"[AuthHook] ✅ isVerified");
            } else {
                NSLog(@"[AuthHook] ⚠️  找不到 isActivated 或 isVerified");
            }
        }
        
        // 提前初始化 T3（但不会自动验证）
        setupT3();
        
        NSLog(@"[AuthHook] 全部 Hook 安装完成");
    });
}
