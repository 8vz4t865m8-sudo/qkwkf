//
//  iphook.m - 卡密验证替换精简版
// 只做验证替换，无其他功能，最稳定
//

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "T3Verify.h"

// ============================================================
// ⚙️ T3 验证参数（改成你自己的）
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

// 验证类名（这个软件是 WWWActivation）
#define AUTH_CLASS_NAME    "WWWActivation"

// 保存卡密的key
#define SAVED_CARD_KEY     @"com.kfun.savedCardNo"

// ============================================================
// 📦 全局变量
// ============================================================

static T3Verify *g_t3 = nil;
static NSString *g_card = nil;
static NSString *g_state = nil;
static BOOL g_verified = NO;
static NSTimer *g_timer = nil;

// ============================================================
// 💾 卡密保存读取
// ============================================================

static void saveCard(NSString *c) {
    if (!c) return;
    [[NSUserDefaults standardUserDefaults] setObject:c forKey:SAVED_CARD_KEY];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

static NSString *loadCard() {
    return [[NSUserDefaults standardUserDefaults] stringForKey:SAVED_CARD_KEY];
}

// ============================================================
// 🚀 初始化 T3
// ============================================================

static void initT3() {
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
}

// ============================================================
// 💓 心跳
// ============================================================

static void startHeart() {
    if (g_timer) return;
    
    g_timer = [NSTimer scheduledTimerWithTimeInterval:30 repeats:YES block:^(NSTimer *t) {
        if (!g_verified || !g_card || !g_state) return;
        dispatch_async(dispatch_get_global_queue(0, 0), ^{
            [g_t3 heartbeatWithKami:g_card statecode:g_state];
        });
    }];
}

// ============================================================
// 🎯 执行验证
// ============================================================

static void doVerify(NSString *code, void (^completion)(BOOL, NSError *)) {
    if (!code || code.length == 0) return;
    
    initT3();
    
    g_card = code;
    NSString *imei = [T3Verify getMachineCode];
    
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        
        T3LoginResult *r = [g_t3 loginWithKami:code imei:imei];
        
        dispatch_async(dispatch_get_main_queue(), ^{
            
            if (r.success) {
                g_verified = YES;
                g_state = r.statecode;
                saveCard(code);
                startHeart();
                
                if (completion) completion(YES, nil);
            } else {
                g_verified = NO;
                g_state = nil;
                
                if (completion) completion(NO, r.error);
            }
        });
    });
}

// ============================================================
// 🎣 Hook 1: activateCode:completion: （点验证按钮时调用）
// ============================================================

static void hook_activateCode(id self, SEL _cmd, NSString *code, void (^completion)(BOOL, NSError *)) {
    NSLog(@"[Hook] 拦截验证: %@", code);
    
    // 如果输入为空，试试用保存的卡密
    if (!code || code.length == 0) {
        NSString *saved = loadCard();
        if (saved) code = saved;
    }
    
    doVerify(code, completion);
}

// ============================================================
// 🎣 Hook 2: verifyWithCompletion: （其他地方调用验证）
// ============================================================

static void hook_verify(id self, SEL _cmd, void (^completion)(BOOL, NSError *)) {
    if (g_verified) {
        if (completion) completion(YES, nil);
        return;
    }
    
    NSString *saved = loadCard();
    if (saved) {
        doVerify(saved, completion);
    }
}

// ============================================================
// 🎣 Hook 3: 是否已激活
// ============================================================

static BOOL hook_isActivated(id self, SEL _cmd) {
    return g_verified;
}

// ============================================================
// 🔌 安装 Hook
// ============================================================

__attribute__((constructor))
static void entry() {
    NSLog(@"[Hook] 卡密验证替换已加载");
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), 
                   dispatch_get_main_queue(), ^{
        
        Class cls = objc_getClass(AUTH_CLASS_NAME);
        if (!cls) {
            NSLog(@"[Hook] 找不到类: %s", AUTH_CLASS_NAME);
            return;
        }
        
        // Hook 激活方法
        Method m1 = class_getInstanceMethod(cls, @selector(activateCode:completion:));
        if (m1) {
            method_setImplementation(m1, (IMP)hook_activateCode);
            NSLog(@"[Hook] ✓ activateCode:completion:");
        }
        
        // Hook 验证方法
        Method m2 = class_getInstanceMethod(cls, @selector(verifyWithCompletion:));
        if (m2) {
            method_setImplementation(m2, (IMP)hook_verify);
            NSLog(@"[Hook] ✓ verifyWithCompletion:");
        }
        
        // Hook 激活状态
        Method m3 = class_getInstanceMethod(cls, @selector(isActivated));
        if (m3) {
            method_setImplementation(m3, (IMP)hook_isActivated);
            NSLog(@"[Hook] ✓ isActivated");
        }
        
        NSLog(@"[Hook] 完成");
    });
}
