//
//  iphook.m - 专门适配 kfun.app (14-26系统版) - 修复闪退版
// 验证类: WWWActivation
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
#define kSavedCardKey @"com.kfun.auth.card"

// ============================================================
// 📦 全局状态
// ============================================================

static T3Verify *g_t3        = nil;
static NSString *g_cardNo    = nil;
static NSString *g_stateCode = nil;
static BOOL      g_verified  = NO;
static NSTimer  *g_heartTimer = nil;

// ============================================================
// 💾 卡密持久化
// ============================================================

static void saveCard(NSString *card) {
    if (!card) return;
    [[NSUserDefaults standardUserDefaults] setObject:card forKey:kSavedCardKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

static NSString *loadSavedCard() {
    return [[NSUserDefaults standardUserDefaults] stringForKey:kSavedCardKey];
}

// ============================================================
// 🚀 T3 SDK 初始化
// ============================================================

static void setupT3() {
    if (g_t3) return;
    
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
        NSLog(@"[AuthHook] T3 初始化错误: %@", err);
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
            [g_t3 heartbeatWithKami:g_cardNo statecode:g_stateCode];
        });
    }];
}

// ============================================================
// 🎯 执行 T3 验证
// ============================================================

static void runT3Verify(NSString *code, void (^completion)(BOOL success, NSError *error)) {
    
    if (!code || code.length == 0) {
        if (completion) completion(NO, [NSError errorWithDomain:@"auth" code:-1 userInfo:@{NSLocalizedDescriptionKey:@"卡密为空"}]);
        return;
    }
    
    setupT3();
    g_cardNo = code;
    
    // ⚠️ 如果你想用 DYO ID 替换设备码，改这里
    NSString *imei = [T3Verify getMachineCode];
    // NSString *imei = @"你的DYO_ID";  // ← 如果要注入 DYO ID，取消注释这行
    
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        
        T3LoginResult *result = [g_t3 loginWithKami:code imei:imei];
        
        dispatch_async(dispatch_get_main_queue(), ^{
            
            if (result && result.success) {
                g_verified  = YES;
                g_stateCode = result.statecode;
                
                saveCard(code);
                startHeartbeat();
                
                if (completion) completion(YES, nil);
            } else {
                g_verified  = NO;
                g_stateCode = nil;
                
                NSError *err = result.error ?: [NSError errorWithDomain:@"auth" code:-2 userInfo:@{NSLocalizedDescriptionKey:@"T3验证失败，请检查卡密"}];
                if (completion) completion(NO, err);
            }
        });
    });
}

// ============================================================
// 🛠️ 辅助：安全调用原生方法（避免签名问题）
// ============================================================

static void callShowError(id self, NSString *msg) {
    SEL sel = sel_registerName("showError:");
    if ([self respondsToSelector:sel]) {
        ((void (*)(id, SEL, NSString *))objc_msgSend)(self, sel, msg);
    }
}

static void callBuildSuccessView(id self, NSString *expire) {
    SEL sel = sel_registerName("buildSuccessViewWithExpire:");
    if ([self respondsToSelector:sel]) {
        ((void (*)(id, SEL, NSString *))objc_msgSend)(self, sel, expire);
    }
}

static void callSetupAfterActivation(id self) {
    SEL sel = sel_registerName("setupAfterActivation");
    if ([self respondsToSelector:sel]) {
        ((void (*)(id, SEL))objc_msgSend)(self, sel);
    }
}

static void hideAuthMaskView(id self) {
    SEL sel = sel_registerName("authMaskView");
    if ([self respondsToSelector:sel]) {
        UIView *mask = ((UIView * (*)(id, SEL))objc_msgSend)(self, sel);
        if (mask) {
            mask.hidden = YES;
            [mask removeFromSuperview];
            NSLog(@"[AuthHook] authMaskView 已隐藏");
        }
    }
}

static NSString *getCodeFieldText(id self) {
    SEL sel = sel_registerName("codeField");
    if ([self respondsToSelector:sel]) {
        UITextField *field = ((UITextField * (*)(id, SEL))objc_msgSend)(self, sel);
        return field.text ?: @"";
    }
    return @"";
}

// ============================================================
// 🎣 Hook 1: onTapVerify （拦截按钮点击，最高优先级）
// ============================================================

static void (*orig_onTapVerify)(id, SEL);

static void hook_onTapVerify(id self, SEL _cmd) {
    NSLog(@"[AuthHook] onTapVerify 被调用");
    
    NSString *code = getCodeFieldText(self);
    
    // 如果输入框为空，尝试用保存的卡密
    if (!code || code.length == 0) {
        code = loadSavedCard();
        if (code.length > 0) {
            NSLog(@"[AuthHook] 使用保存的卡密: %@", code);
        }
    }
    
    if (!code || code.length == 0) {
        callShowError(self, @"请输入卡密");
        return;
    }
    
    runT3Verify(code, ^(BOOL success, NSError *error) {
        if (success) {
            NSLog(@"[AuthHook] T3 验证成功，更新 UI");
            
            // 1. 构建成功视图（带过期时间）
            callBuildSuccessView(self, @"2099-12-31");
            
            // 2. 隐藏认证遮罩（关键：否则雷达界面被挡住）
            hideAuthMaskView(self);
            
            // 3. 调用激活后初始化
            callSetupAfterActivation(self);
            
        } else {
            NSLog(@"[AuthHook] T3 验证失败: %@", error.localizedDescription);
            callShowError(self, error.localizedDescription ?: @"验证失败");
        }
    });
}

// ============================================================
// 🎣 Hook 2: activateCode:completion: （备用入口）
// ⚠️ 注意：不调用原生的 completion，避免 block 签名不匹配闪退
// ============================================================

static void (*orig_activateCode)(id, SEL, NSString *, id);

static void hook_activateCode(id self, SEL _cmd, NSString *code, id completion) {
    NSLog(@"[AuthHook] activateCode:completion: 被调用: %@", code);
    
    if (!code || code.length == 0) {
        NSString *saved = loadSavedCard();
        if (saved.length > 0) code = saved;
    }
    
    runT3Verify(code, ^(BOOL success, NSError *error) {
        if (success) {
            callBuildSuccessView(self, @"2099-12-31");
            hideAuthMaskView(self);
            callSetupAfterActivation(self);
        }
        // ❌ 这里不调用原生的 completion(id) ！
        // 因为不知道它的真实签名，调用会导致闪退。
        // UI 更新已由上面三行手动完成。
    });
}

// ============================================================
// 🎣 Hook 3: verifyWithCompletion: （自动验证/状态检查）
// ============================================================

static void (*orig_verifyWithCompletion)(id, SEL, id);

static void hook_verifyWithCompletion(id self, SEL _cmd, id completion) {
    NSLog(@"[AuthHook] verifyWithCompletion 被调用");
    
    // 已经验证过了，直接更新 UI
    if (g_verified) {
        callBuildSuccessView(self, @"2099-12-31");
        hideAuthMaskView(self);
        callSetupAfterActivation(self);
        return;
    }
    
    // 没验证过但有保存的卡密，自动验证
    NSString *saved = loadSavedCard();
    if (saved.length > 0) {
        runT3Verify(saved, ^(BOOL success, NSError *error) {
            if (success) {
                callBuildSuccessView(self, @"2099-12-31");
                hideAuthMaskView(self);
                callSetupAfterActivation(self);
            }
        });
        return;
    }
    
    // 都没有，调用原方法显示输入界面
    orig_verifyWithCompletion(self, _cmd, completion);
}

// ============================================================
// 🎣 Hook 4: isActivated / isVerified
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
    NSLog(@"[AuthHook] 卡密验证替换已加载 (kfun专用修复版)");
    NSLog(@"========================================");
    
    // 延迟到主线程，等类加载完成
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        
        Class authClass = objc_getClass(kAuthClass);
        if (!authClass) {
            NSLog(@"[AuthHook] ❌ 找不到验证类: %s", kAuthClass);
            return;
        }
        
        NSLog(@"[AuthHook] 找到验证类: %s", kAuthClass);
        
        // 1. Hook onTapVerify（拦截按钮点击）
        Method mTap = class_getInstanceMethod(authClass, sel_registerName("onTapVerify"));
        if (mTap) {
            orig_onTapVerify = (void (*)(id, SEL))method_getImplementation(mTap);
            method_setImplementation(mTap, (IMP)hook_onTapVerify);
            NSLog(@"[AuthHook] ✅ onTapVerify");
        } else {
            NSLog(@"[AuthHook] ⚠️ 找不到 onTapVerify");
        }
        
        // 2. Hook activateCode:completion:（备用入口）
        Method mAct = class_getInstanceMethod(authClass, sel_registerName("activateCode:completion:"));
        if (mAct) {
            orig_activateCode = (void (*)(id, SEL, NSString *, id))method_getImplementation(mAct);
            method_setImplementation(mAct, (IMP)hook_activateCode);
            NSLog(@"[AuthHook] ✅ activateCode:completion:");
        } else {
            NSLog(@"[AuthHook] ⚠️ 找不到 activateCode:completion:");
        }
        
        // 3. Hook verifyWithCompletion:
        Method mVer = class_getInstanceMethod(authClass, sel_registerName("verifyWithCompletion:"));
        if (mVer) {
            orig_verifyWithCompletion = (void (*)(id, SEL, id))method_getImplementation(mVer);
            method_setImplementation(mVer, (IMP)hook_verifyWithCompletion);
            NSLog(@"[AuthHook] ✅ verifyWithCompletion:");
        } else {
            NSLog(@"[AuthHook] ⚠️ 找不到 verifyWithCompletion:");
        }
        
        // 4. Hook isActivated / isVerified
        SEL isActSel = sel_registerName("isActivated");
        Method mIsAct = class_getInstanceMethod(authClass, isActSel);
        if (!mIsAct) {
            isActSel = sel_registerName("isVerified");
            mIsAct = class_getInstanceMethod(authClass, isActSel);
        }
        if (mIsAct) {
            method_setImplementation(mIsAct, (IMP)hook_isActivated);
            NSLog(@"[AuthHook] ✅ %s", sel_getName(isActSel));
        } else {
            NSLog(@"[AuthHook] ⚠️ 找不到 isActivated/isVerified");
        }
        
        // 提前初始化 T3
        setupT3();
        
        NSLog(@"[AuthHook] 全部 Hook 安装完成");
    });
}
