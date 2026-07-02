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
// 🔧 工具函数（消除 performSelector 警告）
// ============================================================

#define SAFE_HOOK(className, sel, newImp, oldImpPtr) \
    do { \
        Class cls = objc_getClass(className); \
        if (cls) { \
            Method m = class_getInstanceMethod(cls, sel); \
            if (m) { \
                if (oldImpPtr) *(oldImpPtr) = method_getImplementation(m); \
                method_setImplementation(m, (IMP)newImp); \
                NSLog(@"[IPHook] ✓ Hook: %s", sel_getName(sel)); \
            } else NSLog(@"[IPHook] ✗ 找不到方法: %s", sel_getName(sel)); \
        } else NSLog(@"[IPHook] ✗ 找不到类: %s", className); \
    } while(0)

static UIViewController *topViewController() {
    UIViewController *vc = [UIApplication sharedApplication].keyWindow.rootViewController;
    if ([vc isKindOfClass:[UINavigationController class]])
        vc = [(UINavigationController *)vc topViewController];
    while (vc.presentedViewController) vc = vc.presentedViewController;
    return vc;
}

static void showHUD(BOOL success, NSString *msg) {
    Class hud = NSClassFromString(@"SVProgressHUD");
    if (!hud) return;
    SEL sel = success ? @selector(showSuccessWithStatus:) : @selector(showErrorWithStatus:);
    if ([hud respondsToSelector:sel]) {
        ((void(*)(id, SEL, id))objc_msgSend)(hud, sel, msg);
    }
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
    if (ok) NSLog(@"[IPHook] ✓ T3 初始化成功");
    else NSLog(@"[IPHook] ✗ T3 初始化失败: %@", error.localizedDescription);
}

// ============================================================
// 💓 心跳
// ============================================================

static void startHeartbeat() {
    if (g_heartbeatTimer) return;
    g_heartbeatTimer = [NSTimer scheduledTimerWithTimeInterval:30.0 repeats:YES block:^(NSTimer *timer) {
        if (!g_t3Verified || !g_cardNo || !g_statecode) return;
        dispatch_async(dispatch_get_global_queue(0, 0), ^{
            T3Result *r = [g_t3Verify heartbeatWithKami:g_cardNo statecode:g_statecode];
            if (!r.success) { g_t3Verified = NO; NSLog(@"[IPHook] 心跳失败"); }
        });
    }];
}

// ============================================================
// 🎣 Hook: 验证
// ============================================================

static void hook_activateWithCardNo(id self, SEL _cmd, NSString *cardNo, NSString *machineId, id completion) {
    if (!cardNo.length) return;
    if (!g_t3InitSuccess) { initT3(); if (!g_t3InitSuccess) return; }

    g_cardNo = cardNo;
    NSString *imei = machineId.length ? machineId : [T3Verify getMachineCode];

    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        T3LoginResult *r = [g_t3Verify loginWithKami:cardNo imei:imei];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (r.success) {
                g_t3Verified = YES;
                g_statecode = r.statecode;
                if ([self respondsToSelector:@selector(setIsActivated:)])
                    ((void(*)(id, SEL, BOOL))objc_msgSend)(self, @selector(setIsActivated:), YES);
                if ([self respondsToSelector:@selector(setCardNo:)])
                    ((void(*)(id, SEL, id))objc_msgSend)(self, @selector(setCardNo:), cardNo);

                // 主动注入卡号到可能的单例
                injectCardToAllSingletons(cardNo);

                showHUD(YES, @"验证成功");
                startHeartbeat();
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.5*NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                    UIViewController *vc = topViewController();
                    if ([vc respondsToSelector:@selector(enterMainConsole)])
                        ((void(*)(id, SEL))objc_msgSend)(vc, @selector(enterMainConsole));
                });
            } else {
                g_t3Verified = NO; g_statecode = nil;
                showHUD(NO, r.error ?: @"验证失败");
            }
        });
    });
}

static void hook_heartbeatWithCompletion(id self, SEL _cmd, id completion) {
    if (!g_t3Verified) return;
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        T3Result *r = [g_t3Verify heartbeatWithKami:g_cardNo statecode:g_statecode];
        if (!r.success) g_t3Verified = NO;
    });
}

static BOOL hook_isActivated(id self, SEL _cmd) { return g_t3Verified; }
static id hook_cardNo(id self, SEL _cmd) { return g_cardNo ?: @""; }

// ============================================================
// 🎣 推流修复
// ============================================================

static NSString *fake_cardNo(id self, SEL _cmd) { return g_cardNo ?: @"CARD_DEFAULT"; }
static NSString *fake_machineId(id self, SEL _cmd) { return @"MACHINE_DEFAULT"; }

static void safeReplaceMethod(Class cls, SEL sel, IMP imp) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;
    char ret[4] = {0};
    method_getReturnType(m, ret, sizeof(ret));
    if (ret[0] != '@') return; // 只替换返回对象的方法
    class_replaceMethod(cls, sel, imp, "@@:");
    NSLog(@"[IPHook] ✅ 推流修复: %@ %@", NSStringFromClass(cls), NSStringFromSelector(sel));
}

static void injectCardToAllSingletons(NSString *card) {
    // 常用单例类名
    NSArray *clsNames = @[@"DeviceManager", @"AppConfig", @"UserManager", @"MRConfig", @"GlobalConfig"];
    for (NSString *name in clsNames) {
        Class cls = objc_getClass(name.UTF8String);
        if (!cls) continue;
        id instance = nil;
        for (NSString *selName in @[@"sharedInstance", @"shared", @"defaultManager", @"currentManager"]) {
            SEL sel = NSSelectorFromString(selName);
            if ([cls respondsToSelector:sel]) {
                instance = ((id(*)(id, SEL))objc_msgSend)(cls, sel);
                break;
            }
        }
        if (!instance) continue;
        // 尝试 setCardNo:
        SEL setSel = NSSelectorFromString(@"setCardNo:");
        if ([instance respondsToSelector:setSel]) {
            ((void(*)(id, SEL, id))objc_msgSend)(instance, setSel, card);
            NSLog(@"[IPHook] ✅ 注入卡号到 %@", name);
        }
        // KVC 尝试
        @try { [instance setValue:card forKey:@"cardNo"]; } @catch (NSException *e) {}
    }
    // 写入偏好设置
    [[NSUserDefaults standardUserDefaults] setObject:card forKey:@"cardNo"];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

static void initPushStreamHooks() {
    NSArray *classes = @[@"MRCloudRelay", @"MRStreamer", @"MRPushManager", @"CloudRelay",
                         @"MRRoomManager", @"MRApiClient", @"LiveStreamManager", @"PushEngine"];
    for (NSString *name in classes) {
        Class cls = objc_getClass(name.UTF8String);
        if (!cls) continue;
        
        SEL cardSels[] = { @selector(cardNo), NSSelectorFromString(@"card_no"),
                           NSSelectorFromString(@"CardNo"), NSSelectorFromString(@"getCardNo") };
        for (int i = 0; i < 4; i++) safeReplaceMethod(cls, cardSels[i], (IMP)fake_cardNo);
        
        SEL machineSels[] = { @selector(machineId), NSSelectorFromString(@"machine_id"),
                              NSSelectorFromString(@"MachineId"), NSSelectorFromString(@"getMachineId") };
        for (int i = 0; i < 4; i++) safeReplaceMethod(cls, machineSels[i], (IMP)fake_machineId);
    }
    
    NSArray *singletons = @[@"DeviceManager", @"AppConfig", @"UserManager", @"MRConfig", @"GlobalConfig"];
    for (NSString *name in singletons) {
        Class cls = objc_getClass(name.UTF8String);
        if (!cls) continue;
        safeReplaceMethod(cls, @selector(cardNo), (IMP)fake_cardNo);
        safeReplaceMethod(cls, NSSelectorFromString(@"getCardNo"), (IMP)fake_cardNo);
        safeReplaceMethod(cls, @selector(machineId), (IMP)fake_machineId);
    }
    NSLog(@"[IPHook] 推流 Hook 完成");
}

// ============================================================
// 🔌 总初始化
// ============================================================

static void initHooks() {
    Class verifyCls = objc_getClass(OLD_VERIFY_CLASS);
    if (verifyCls) {
        SAFE_HOOK(OLD_VERIFY_CLASS, @selector(activateWithCardNo:machineId:completion:),
                  hook_activateWithCardNo, &orig_activateWithCardNo);
        SAFE_HOOK(OLD_VERIFY_CLASS, @selector(heartbeatWithCompletion:),
                  hook_heartbeatWithCompletion, &orig_heartbeat);
        SAFE_HOOK(OLD_VERIFY_CLASS, @selector(isActivated), hook_isActivated, &orig_isActivated);
        SAFE_HOOK(OLD_VERIFY_CLASS, @selector(cardNo), hook_cardNo, &orig_cardNo);
    }
    initT3();
    initPushStreamHooks();
    NSLog(@"[IPHook] 全部初始化完成");
}

__attribute__((constructor))
static void iphook_init() {
    NSLog(@"[IPHook] T3验证+推流修复加载");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.5*NSEC_PER_SEC), dispatch_get_main_queue(), initHooks);
}
