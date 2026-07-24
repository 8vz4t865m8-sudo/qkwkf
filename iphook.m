//
//  iphook.m - 适配14-26系统版 T3验证替换（安全版）
//
// 注意：去掉了自动填充输入框的功能，避免闪退
//

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "T3Verify.h"

// ============================================================
// ⚙️ T3 配置
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

// 可能的验证类名（挨个试）
#define AUTH_CLASS_1 "WWWActivation"
#define AUTH_CLASS_2 "NetworkVerifyClient"

#define SAVED_CARD_KEY @"com.kfun.savedCard"

// ============================================================
// 📦 全局状态
// ============================================================

static T3Verify *g_t3Verify = nil;
static NSString *g_cardNo = nil;
static NSString *g_statecode = nil;
static BOOL g_t3Verified = NO;
static BOOL g_t3InitSuccess = NO;
static NSTimer *g_heartbeatTimer = nil;

// ============================================================
// 💾 卡密保存
// ============================================================

static void saveCard(NSString *card) {
    if (!card) return;
    [[NSUserDefaults standardUserDefaults] setObject:card forKey:SAVED_CARD_KEY];
    [[NSUserDefaults standardUserDefaults] synchronize];
    NSLog(@"[IPHook] 卡密已保存");
}

static NSString *loadCard() {
    return [[NSUserDefaults standardUserDefaults] stringForKey:SAVED_CARD_KEY];
}

// ============================================================
// 🚀 T3 初始化
// ============================================================

static void initT3() {
    if (g_t3Verify) return;
    
    g_t3Verify = [[T3Verify alloc] init];
    NSError *error = nil;
    
    BOOL ok = [g_t3Verify initRsaWithLoginCode:T3_LOGIN_CODE
                                    noticeCode:T3_NOTICE_CODE
                                   versionCode:T3_VERSION_CODE
                                 heartbeatCode:T3_HEARTBEAT_CODE
                                        appkey:T3_APPKEY
                                  rsaPublicKey:T3_RSA_PUBLIC_KEY
                                         error:&error];
    
    g_t3InitSuccess = ok;
    NSLog(@"[IPHook] T3初始化: %@", ok ? @"成功" : @"失败");
}

// ============================================================
// 💓 心跳
// ============================================================

static void startHeartbeat() {
    if (g_heartbeatTimer) return;
    
    g_heartbeatTimer = [NSTimer scheduledTimerWithTimeInterval:30 repeats:YES block:^(NSTimer *t) {
        if (!g_t3Verified || !g_cardNo || !g_statecode) return;
        dispatch_async(dispatch_get_global_queue(0, 0), ^{
            [g_t3Verify heartbeatWithKami:g_cardNo statecode:g_statecode];
        });
    }];
}

// ============================================================
// 🎯 执行 T3 验证
// ============================================================

static void doVerify(NSString *code, id completion) {
    if (!code || code.length == 0) {
        NSLog(@"[IPHook] 卡密为空");
        return;
    }
    
    if (!g_t3InitSuccess) {
        initT3();
        if (!g_t3InitSuccess) return;
    }
    
    g_cardNo = code;
    NSString *imei = [T3Verify getMachineCode];
    
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        
        T3LoginResult *result = [g_t3Verify loginWithKami:code imei:imei];
        
        dispatch_async(dispatch_get_main_queue(), ^{
            
            if (result.success) {
                NSLog(@"[IPHook] ✓ 验证成功");
                g_t3Verified = YES;
                g_statecode = result.statecode;
                saveCard(code);
                startHeartbeat();
                
                // 调用成功回调
                if (completion) {
                    typedef void (*CompletionBlock)(BOOL success, id error);
                    CompletionBlock cb = (__bridge CompletionBlock)completion;
                    cb(YES, nil);
                }
                
            } else {
                NSLog(@"[IPHook] ✗ 验证失败: %@", result.error);
                g_t3Verified = NO;
                g_statecode = nil;
                
                if (completion) {
                    typedef void (*CompletionBlock)(BOOL success, id error);
                    CompletionBlock cb = (__bridge CompletionBlock)completion;
                    cb(NO, result.error);
                }
            }
        });
    });
}

// ============================================================
// 🎣 Hook: activateCode:completion: （核心验证方法）
// ============================================================

static void hook_activateCode(id self, SEL _cmd, NSString *code, id completion) {
    NSLog(@"[IPHook] 拦截 activateCode: %@", code);
    
    // 如果卡密为空，试试用保存的
    if (!code || code.length == 0) {
        NSString *saved = loadCard();
        if (saved.length > 0) {
            code = saved;
            NSLog(@"[IPHook] 使用保存的卡密");
        }
    }
    
    doVerify(code, completion);
}

// ============================================================
// 🎣 Hook: verifyWithCompletion:
// ============================================================

static void hook_verifyWithCompletion(id self, SEL _cmd, id completion) {
    NSLog(@"[IPHook] 拦截 verifyWithCompletion");
    
    NSString *saved = loadCard();
    if (saved.length > 0 && g_t3Verified) {
        // 已经验证过了，直接返回成功
        if (completion) {
            typedef void (*CompletionBlock)(BOOL success, id error);
            CompletionBlock cb = (__bridge CompletionBlock)completion;
            cb(YES, nil);
        }
        return;
    }
    
    if (saved.length > 0) {
        doVerify(saved, completion);
    }
}

// ============================================================
// 🎣 Hook: 是否已激活
// ============================================================

static BOOL hook_isActivated(id self, SEL _cmd) {
    return g_t3Verified;
}

// ============================================================
// 🎣 推流模块修复（card_no / machine_id）
// ============================================================

static NSString *fake_cardNo(id self, SEL _cmd) {
    return g_cardNo ?: @"CARD_000000000000";
}

static NSString *fake_machineId(id self, SEL _cmd) {
    return @"MACHINE_000000000000";
}

static void initPushStreamHooks() {
    NSArray *classes = @[@"MRCloudRelay", @"MRStreamer", @"MRPushManager", @"CloudRelay", @"MRRoomManager", @"MRApiClient"];
    
    for (NSString *name in classes) {
        Class cls = objc_getClass(name.UTF8String);
        if (!cls) continue;
        
        unsigned int count;
        Method *methods = class_copyMethodList(cls, &count);
        
        for (int i = 0; i < count; i++) {
            SEL sel = method_getName(methods[i]);
            NSString *selName = NSStringFromSelector(sel);
            const char *type = method_getTypeEncoding(methods[i]);
            
            if (([selName containsString:@"cardNo"] || [selName containsString:@"card_no"])
                && type && strstr(type, "@")) {
                class_addMethod(cls, sel, (IMP)fake_cardNo, "@@:");
            }
            
            if (([selName containsString:@"machineId"] || [selName containsString:@"machine_id"])
                && type && strstr(type, "@")) {
                class_addMethod(cls, sel, (IMP)fake_machineId, "@@:");
            }
        }
        
        free(methods);
    }
}

// ============================================================
// 🔌 初始化所有 Hook
// ============================================================

static void initHooks() {
    NSLog(@"[IPHook] 开始初始化...");
    
    initT3();
    
    // 尝试多个可能的验证类名
    const char *classNames[] = { AUTH_CLASS_1, AUTH_CLASS_2, NULL };
    
    for (int i = 0; classNames[i]; i++) {
        Class cls = objc_getClass(classNames[i]);
        if (!cls) {
            NSLog(@"[IPHook] 类不存在: %s", classNames[i]);
            continue;
        }
        
        NSLog(@"[IPHook] 找到验证类: %s", classNames[i]);
        
        // Hook activateCode:completion:
        Method m1 = class_getInstanceMethod(cls, @selector(activateCode:completion:));
        if (m1) {
            method_setImplementation(m1, (IMP)hook_activateCode);
            NSLog(@"[IPHook] ✓ Hook activateCode:completion:");
        }
        
        // Hook verifyWithCompletion:
        Method m2 = class_getInstanceMethod(cls, @selector(verifyWithCompletion:));
        if (m2) {
            method_setImplementation(m2, (IMP)hook_verifyWithCompletion);
            NSLog(@"[IPHook] ✓ Hook verifyWithCompletion:");
        }
        
        // Hook isActivated（如果有的话）
        Method m3 = class_getInstanceMethod(cls, @selector(isActivated));
        if (m3) {
            method_setImplementation(m3, (IMP)hook_isActivated);
            NSLog(@"[IPHook] ✓ Hook isActivated");
        }
        
        break; // 找到一个就够了
    }
    
    // 推流模块修复
    initPushStreamHooks();
    
    NSLog(@"[IPHook] 初始化完成");
}

// ============================================================
// 🚪 入口
// ============================================================

__attribute__((constructor))
static void iphook_init() {
    NSLog(@"========================================");
    NSLog(@"[IPHook] 已加载 (14-26系统适配版)");
    NSLog(@"========================================");
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), 
                   dispatch_get_main_queue(), ^{
        initHooks();
    });
}
