//
//  iphook.m - T3 验证替换 + 推流修复（无自动保存/自动登录）
//

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "T3Verify.h"

// ============================================================
// ⚙️ 配置区域
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

#define OLD_VERIFY_CLASS   "NetworkVerifyClient"

// ============================================================
// 📦 全局状态
// ============================================================

static T3Verify *g_t3Verify = nil;
static NSString *g_cardNo = nil;
static NSString *g_statecode = nil;
static BOOL g_t3Verified = NO;
static BOOL g_t3InitSuccess = NO;
static NSTimer *g_heartbeatTimer = nil;

static IMP orig_activateWithCardNo = NULL;
static IMP orig_heartbeat = NULL;
static IMP orig_isActivated = NULL;
static IMP orig_cardNo = NULL;

// ============================================================
// 🔧 工具函数
// ============================================================

#define SAFE_HOOK(className, sel, newImp, oldImpPtr) \
    do { \
        Class cls = objc_getClass(className); \
        if (cls) { \
            Method m = class_getInstanceMethod(cls, sel); \
            if (m) { \
                if (oldImpPtr) { \
                    *(oldImpPtr) = method_getImplementation(m); \
                } \
                method_setImplementation(m, (IMP)newImp); \
                NSLog(@"[IPHook] ✓ Hook: %s", sel_getName(sel)); \
            } else { \
                NSLog(@"[IPHook] ✗ 找不到方法: %s", sel_getName(sel)); \
            } \
        } else { \
            NSLog(@"[IPHook] ✗ 找不到类: %s", className); \
        } \
    } while(0)

// ============================================================
// 🚀 T3 初始化
// ============================================================

static void initT3() {
    if (g_t3Verify) return;
    
    g_t3Verify = [[T3Verify alloc] init];
    NSError *error = nil;
    
    BOOL success = [g_t3Verify initRsaWithLoginCode:T3_LOGIN_CODE
                                          noticeCode:T3_NOTICE_CODE
                                         versionCode:T3_VERSION_CODE
                                       heartbeatCode:T3_HEARTBEAT_CODE
                                              appkey:T3_APPKEY
                                        rsaPublicKey:T3_RSA_PUBLIC_KEY
                                               error:&error];
    
    if (success) {
        g_t3InitSuccess = YES;
        NSLog(@"[IPHook] ✓ T3 初始化成功");
    } else {
        NSLog(@"[IPHook] ✗ T3 初始化失败: %@", error.localizedDescription);
    }
}

// ============================================================
// 💓 心跳
// ============================================================

static void startHeartbeat() {
    if (g_heartbeatTimer) return;
    
    g_heartbeatTimer = [NSTimer scheduledTimerWithTimeInterval:30.0 repeats:YES block:^(NSTimer * _Nonnull timer) {
        if (!g_t3Verified || !g_cardNo || !g_statecode) return;
        
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            T3Result *result = [g_t3Verify heartbeatWithKami:g_cardNo statecode:g_statecode];
            if (result.success) {
                NSLog(@"[IPHook] ✓ 心跳成功");
            } else {
                NSLog(@"[IPHook] ✗ 心跳失败: %@", result.error);
                g_t3Verified = NO;
            }
        });
    }];
}

// ============================================================
// 🎣 Hook: 卡密验证（核心）
// ============================================================

static void hook_activateWithCardNo(id self, SEL _cmd, 
                                     NSString *cardNo, 
                                     NSString *machineId, 
                                     id completion) {
    NSLog(@"[IPHook] 拦截验证请求，卡号: %@", cardNo);
    
    if (!g_t3InitSuccess) {
        initT3();
        if (!g_t3InitSuccess) return;
    }
    
    if (!cardNo || cardNo.length == 0) return;
    
    g_cardNo = cardNo;
    NSString *imei = machineId.length ? machineId : [T3Verify getMachineCode];
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        T3LoginResult *result = [g_t3Verify loginWithKami:cardNo imei:imei];
        
        dispatch_async(dispatch_get_main_queue(), ^{
            if (result.success) {
                NSLog(@"[IPHook] ✓ 验证成功");
                g_t3Verified = YES;
                g_statecode = result.statecode;
                
                if ([self respondsToSelector:@selector(setIsActivated:)]) {
                    ((void(*)(id, SEL, BOOL))objc_msgSend)(self, @selector(setIsActivated:), YES);
                }
                if ([self respondsToSelector:@selector(setCardNo:)]) {
                    ((void(*)(id, SEL, id))objc_msgSend)(self, @selector(setCardNo:), cardNo);
                }
                
                Class hud = NSClassFromString(@"SVProgressHUD");
                if (hud) {
                    @try { [hud performSelector:@selector(showSuccessWithStatus:) withObject:@"验证成功"]; } @catch (id e) {}
                }
                
                startHeartbeat();
                
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), 
                               dispatch_get_main_queue(), ^{
                    // 进入主界面
                    UIViewController *vc = [UIApplication sharedApplication].keyWindow.rootViewController;
                    while (vc.presentedViewController) vc = vc.presentedViewController;
                    if (vc && [vc respondsToSelector:@selector(enterMainConsole)]) {
                        ((void(*)(id, SEL))objc_msgSend)(vc, @selector(enterMainConsole));
                    }
                });
            } else {
                NSLog(@"[IPHook] ✗ 验证失败: %@", result.error);
                g_t3Verified = NO;
                g_statecode = nil;
                
                Class hud = NSClassFromString(@"SVProgressHUD");
                if (hud) {
                    @try { [hud performSelector:@selector(showErrorWithStatus:) withObject:result.error ?: @"验证失败"]; } @catch (id e) {}
                }
            }
        });
    });
}

// ============================================================
// 🎣 Hook: 心跳、激活状态、卡号
// ============================================================

static void hook_heartbeatWithCompletion(id self, SEL _cmd, id completion) {
    if (!g_t3Verified || !g_cardNo || !g_statecode) return;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        T3Result *result = [g_t3Verify heartbeatWithKami:g_cardNo statecode:g_statecode];
        if (!result.success) g_t3Verified = NO;
    });
}

static BOOL hook_isActivated(id self, SEL _cmd) {
    return g_t3Verified;
}

static id hook_cardNo(id self, SEL _cmd) {
    return g_cardNo ?: @"";
}

// ============================================================
// 🎣 推流模块修复
// ============================================================

static NSString *fake_cardNo(id self, SEL _cmd) {
    return g_cardNo ?: @"CARD_000000000000";
}

static NSString *fake_machineId(id self, SEL _cmd) {
    return @"MACHINE_000000000000";
}

static void initPushStreamHooks() {
    NSLog(@"[IPHook] 初始化推流模块 Hook...");
    
    NSArray *classNames = @[
        @"MRCloudRelay",
        @"MRStreamer", 
        @"MRPushManager", 
        @"CloudRelay",
        @"MRRoomManager",
        @"MRApiClient"
    ];
    
    for (NSString *clsName in classNames) {
        Class cls = objc_getClass(clsName.UTF8String);
        if (!cls) continue;
        
        NSLog(@"[IPHook] 找到类: %@", clsName);
        
        unsigned int count;
        Method *methods = class_copyMethodList(cls, &count);
        
        for (int i = 0; i < count; i++) {
            SEL sel = method_getName(methods[i]);
            NSString *selName = NSStringFromSelector(sel);
            const char *type = method_getTypeEncoding(methods[i]);
            
            if (([selName containsString:@"cardNo"] || [selName containsString:@"card_no"] || [selName containsString:@"CardNo"])
                && type && strstr(type, "@")) {
                class_addMethod(cls, sel, (IMP)fake_cardNo, "@@:");
                NSLog(@"[IPHook] ✅ Hook 卡号: %@", selName);
            }
            
            if (([selName containsString:@"machineId"] || [selName containsString:@"machine_id"] || [selName containsString:@"MachineId"])
                && type && strstr(type, "@")) {
                class_addMethod(cls, sel, (IMP)fake_machineId, "@@:");
                NSLog(@"[IPHook] ✅ Hook 机器码: %@", selName);
            }
        }
        
        free(methods);
    }
    
    NSLog(@"[IPHook] ✓ 推流模块 Hook 完成");
}

// ============================================================
// 🔌 初始化所有 Hook
// ============================================================

static void initHooks() {
    NSLog(@"[IPHook] 开始初始化 Hook...");
    
    Class oldClass = objc_getClass(OLD_VERIFY_CLASS);
    if (oldClass) {
        NSLog(@"[IPHook] 找到验证类: %s", OLD_VERIFY_CLASS);
        
        SAFE_HOOK(OLD_VERIFY_CLASS, @selector(activateWithCardNo:machineId:completion:), 
                  (IMP)hook_activateWithCardNo, &orig_activateWithCardNo);
        
        SAFE_HOOK(OLD_VERIFY_CLASS, @selector(heartbeatWithCompletion:), 
                  (IMP)hook_heartbeatWithCompletion, &orig_heartbeat);
        
        SAFE_HOOK(OLD_VERIFY_CLASS, @selector(isActivated), 
                  (IMP)hook_isActivated, &orig_isActivated);
        
        SAFE_HOOK(OLD_VERIFY_CLASS, @selector(cardNo), 
                  (IMP)hook_cardNo, &orig_cardNo);
    }
    
    initT3();
    
    // 推流模块修复
    initPushStreamHooks();
    
    NSLog(@"[IPHook] ✓ 所有 Hook 初始化完成");
}

// ============================================================
// 🚪 入口
// ============================================================

__attribute__((constructor))
static void iphook_init() {
    NSLog(@"========================================");
    NSLog(@"[IPHook] T3 验证替换 + 推流修复 dylib 已加载");
    NSLog(@"[IPHook] 无自动保存卡密，无自动登录");
    NSLog(@"========================================");
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), 
                   dispatch_get_main_queue(), ^{
        initHooks();
    });
}
