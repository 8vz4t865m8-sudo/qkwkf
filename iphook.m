
//  MyRadarHook_KamiOnly.m - 纯卡密验证版
//  贴合原 App：NetworkVerifyClient + ViewController
//

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "T3Verify.h"

#define T3_LOGIN_CODE      @"B9F97729EC64A6C9"
#define T3_NOTICE_CODE     @"9E37BB60E3AFFCEE"
#define T3_VERSION_CODE    @"2A78BD88E7376215"
#define T3_HEARTBEAT_CODE  @"168AA83248396F84"
#define T3_APPKEY          @"15cab0658474ff4a93ebd8ab8337dab0"
#define T3_RSA_PUBLIC_KEY  @"-----BEGIN PUBLIC KEY-----\n"                             "MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQCxj7u3l9DKEyaluMG11BVdfg5z\n"                             "/6ieD1iwGzl6txP5G6nAEPxU3BzdEvI4Z20AOAJoGdmflpDq947lgp+tG61G8DeK\n"                             "ZLsZWb9t18+L/ThZCCv1xWxb5Llr4mt9yUh5IPHwl5Zy8nxWL64onFJaRIrif+JR\n"                             "U0sEt6p3P7lCc3JkPwIDAQAB\n"                             "-----END PUBLIC KEY-----"

#define OLD_VERIFY_CLASS   "NetworkVerifyClient"

// ============================================================
// 工具函数
// ============================================================
static void hookMethod(const char *className, SEL sel, IMP newImp, IMP *oldImp) {
    Class cls = objc_getClass(className);
    if (!cls) { NSLog(@"[Hook] 找不到类: %s", className); return; }
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) { NSLog(@"[Hook] 找不到方法: %s", sel_getName(sel)); return; }
    if (oldImp) *oldImp = method_getImplementation(m);
    method_setImplementation(m, newImp);
    NSLog(@"[Hook] Hook: %s", sel_getName(sel));
}

static UIViewController *getViewController() {
    UIViewController *vc = [UIApplication sharedApplication].keyWindow.rootViewController;
    if (!vc) return nil;
    if ([vc isKindOfClass:[UINavigationController class]]) {
        vc = [(UINavigationController *)vc topViewController];
    }
    while (vc.presentedViewController) vc = vc.presentedViewController;
    return vc;
}

static void showSuccess(NSString *status) {
    Class hud = NSClassFromString(@"SVProgressHUD");
    if (hud) @try { [hud performSelector:@selector(showSuccessWithStatus:) withObject:status]; } @catch (NSException *e) {}
}

static void showError(NSString *status) {
    Class hud = NSClassFromString(@"SVProgressHUD");
    if (hud) @try { [hud performSelector:@selector(showErrorWithStatus:) withObject:status]; } @catch (NSException *e) {}
}

static void enterMainConsole() {
    UIViewController *vc = getViewController();
    if (!vc) return;
    if ([NSStringFromClass([vc class]) isEqualToString:@"ViewController"]) {
        if ([vc respondsToSelector:@selector(enterMainConsole)]) {
            ((void(*)(id, SEL))objc_msgSend)(vc, @selector(enterMainConsole));
            return;
        }
    }
    for (UIViewController *child in vc.childViewControllers) {
        if ([NSStringFromClass([child class]) isEqualToString:@"ViewController"]) {
            if ([child respondsToSelector:@selector(enterMainConsole)]) {
                ((void(*)(id, SEL))objc_msgSend)(child, @selector(enterMainConsole));
                return;
            }
        }
    }
}

static void saveCardToLocal(NSString *cardNo, NSString *machineId) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setObject:cardNo forKey:@"saved_card_no"];
    [defaults setObject:machineId forKey:@"udid"];
    [defaults synchronize];
    NSLog(@"[Hook] 卡密已保存: %@", cardNo);
}

static NSString *loadSavedCard() {
    return [[NSUserDefaults standardUserDefaults] objectForKey:@"saved_card_no"];
}

static NSString *loadSavedMachineId() {
    return [[NSUserDefaults standardUserDefaults] objectForKey:@"udid"];
}

// ============================================================
// T3 验证系统
// ============================================================
static T3Verify *g_t3Verify = nil;
static NSString *g_cardNo = nil;
static NSString *g_statecode = nil;
static BOOL g_t3Verified = NO;
static BOOL g_t3InitSuccess = NO;
static NSTimer *g_heartbeatTimer = nil;

static void initT3() {
    if (g_t3Verify) return;
    g_t3Verify = [[T3Verify alloc] init];
    NSError *error = nil;
    BOOL ok = [g_t3Verify initRsaWithLoginCode:T3_LOGIN_CODE noticeCode:T3_NOTICE_CODE
                                   versionCode:T3_VERSION_CODE heartbeatCode:T3_HEARTBEAT_CODE
                                        appkey:T3_APPKEY rsaPublicKey:T3_RSA_PUBLIC_KEY error:&error];
    g_t3InitSuccess = ok;
    if (ok) NSLog(@"[Hook] T3 初始化成功");
    else NSLog(@"[Hook] T3 初始化失败: %@", error.localizedDescription);
}

static void startT3Heartbeat() {
    if (g_heartbeatTimer) return;
    g_heartbeatTimer = [NSTimer scheduledTimerWithTimeInterval:30.0 repeats:YES block:^(NSTimer *timer) {
        if (!g_t3Verified || !g_cardNo || !g_statecode) return;
        dispatch_async(dispatch_get_global_queue(0,0), ^{
            T3Result *r = [g_t3Verify heartbeatWithKami:g_cardNo statecode:g_statecode];
            if (!r.success) { g_t3Verified = NO; NSLog(@"[Hook] T3心跳失败"); }
        });
    }];
    dispatch_async(dispatch_get_global_queue(0,0), ^{
        T3Result *r = [g_t3Verify heartbeatWithKami:g_cardNo statecode:g_statecode];
        if (!r.success) g_t3Verified = NO;
    });
}

static void stopT3Heartbeat() {
    if (g_heartbeatTimer) {
        [g_heartbeatTimer invalidate];
        g_heartbeatTimer = nil;
        NSLog(@"[Hook] T3心跳已停止");
    }
}

// ============================================================
// 验证 Hook 原IMP
// ============================================================
static IMP orig_activateWithCardNo = NULL;
static IMP orig_heartbeat = NULL;
static IMP orig_isActivated = NULL;
static IMP orig_cardNo = NULL;
static IMP orig_startHeartbeat = NULL;
static IMP orig_stopHeartbeat = NULL;

// ============================================================
// 验证 Hook 实现
// ============================================================
static void hook_activateWithCardNo(id self, SEL _cmd, NSString *cardNo, NSString *machineId, id completion) {
    if (!cardNo.length) return;
    if (!g_t3InitSuccess) { initT3(); if (!g_t3InitSuccess) return; }
    g_cardNo = cardNo;
    NSString *imei = machineId.length ? machineId : [T3Verify getMachineCode];

    dispatch_async(dispatch_get_global_queue(0,0), ^{
        T3LoginResult *r = [g_t3Verify loginWithKami:cardNo imei:imei];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (r.success) {
                g_t3Verified = YES; g_statecode = r.statecode;
                saveCardToLocal(cardNo, imei);

                if ([self respondsToSelector:@selector(setIsActivated:)]) {
                    ((void(*)(id, SEL, BOOL))objc_msgSend)(self, @selector(setIsActivated:), YES);
                }
                if ([self respondsToSelector:@selector(setCardNo:)]) {
                    ((void(*)(id, SEL, id))objc_msgSend)(self, @selector(setCardNo:), cardNo);
                }
                showSuccess(@"验证成功");
                startT3Heartbeat();
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.5*NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                    enterMainConsole();
                });
            } else {
                g_t3Verified = NO; g_statecode = nil;
                showError(r.error ?: @"验证失败");
            }
        });
    });
}

static void hook_heartbeatWithCompletion(id self, SEL _cmd, id completion) {
    if (!g_t3Verified) return;
    dispatch_async(dispatch_get_global_queue(0,0), ^{
        T3Result *r = [g_t3Verify heartbeatWithKami:g_cardNo statecode:g_statecode];
        if (!r.success) g_t3Verified = NO;
    });
}

static BOOL hook_isActivated(id self, SEL _cmd) { return g_t3Verified; }
static id hook_cardNo(id self, SEL _cmd) { return g_cardNo ?: @""; }

// 阻止原APP心跳，防止双心跳冲突
static void hook_startHeartbeat(id self, SEL _cmd) {
    NSLog(@"[Hook] 拦截原APP startHeartbeat，使用T3心跳替代");
}

static void hook_stopHeartbeat(id self, SEL _cmd) {
    NSLog(@"[Hook] 拦截原APP stopHeartbeat");
    stopT3Heartbeat();
}

// ============================================================
// 自动验证 Hook
// ============================================================
static void hook_tryAutoActivate(id self, SEL _cmd) {
    NSString *savedCard = loadSavedCard();
    NSString *savedMachineId = loadSavedMachineId();

    if (savedCard.length > 0) {
        NSLog(@"[Hook] 自动验证保存的卡密: %@", savedCard);
        if (!g_t3InitSuccess) initT3();

        g_cardNo = savedCard;
        NSString *imei = savedMachineId.length ? savedMachineId : [T3Verify getMachineCode];

        dispatch_async(dispatch_get_global_queue(0,0), ^{
            T3LoginResult *r = [g_t3Verify loginWithKami:savedCard imei:imei];
            dispatch_async(dispatch_get_main_queue(), ^{
                if (r.success) {
                    g_t3Verified = YES; g_statecode = r.statecode;
                    saveCardToLocal(savedCard, imei);

                    if ([self respondsToSelector:@selector(setIsActivated:)]) {
                        ((void(*)(id, SEL, BOOL))objc_msgSend)(self, @selector(setIsActivated:), YES);
                    }
                    if ([self respondsToSelector:@selector(setCardNo:)]) {
                        ((void(*)(id, SEL, id))objc_msgSend)(self, @selector(setCardNo:), savedCard);
                    }
                    NSLog(@"[Hook] 自动验证成功");
                    startT3Heartbeat();
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.5*NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                        enterMainConsole();
                    });
                } else {
                    g_t3Verified = NO;
                    NSLog(@"[Hook] 自动验证失败: %@", r.error);
                }
            });
        });
    } else {
        NSLog(@"[Hook] 无保存的卡密，跳过自动验证");
    }
}

// ============================================================
// 初始化
// ============================================================
static void initHooks() {
    NSLog(@"[Hook] 开始初始化纯卡密验证...");

    // 验证系统 Hook
    hookMethod(OLD_VERIFY_CLASS, @selector(activateWithCardNo:machineId:completion:),
               (IMP)hook_activateWithCardNo, &orig_activateWithCardNo);
    hookMethod(OLD_VERIFY_CLASS, @selector(heartbeatWithCompletion:),
               (IMP)hook_heartbeatWithCompletion, &orig_heartbeat);
    hookMethod(OLD_VERIFY_CLASS, @selector(isActivated),
               (IMP)hook_isActivated, &orig_isActivated);
    hookMethod(OLD_VERIFY_CLASS, @selector(cardNo),
               (IMP)hook_cardNo, &orig_cardNo);
    hookMethod(OLD_VERIFY_CLASS, @selector(startHeartbeat),
               (IMP)hook_startHeartbeat, &orig_startHeartbeat);
    hookMethod(OLD_VERIFY_CLASS, @selector(stopHeartbeat),
               (IMP)hook_stopHeartbeat, &orig_stopHeartbeat);

    // 自动登录 Hook
    hookMethod("ViewController", @selector(tryAutoActivate),
               (IMP)hook_tryAutoActivate, NULL);

    initT3();

    NSLog(@"[Hook] 纯卡密验证初始化完成");
}

__attribute__((constructor))
static void hook_init() {
    NSLog(@"========================================");
    NSLog(@"[Hook] 纯卡密验证版已加载");
    NSLog(@"========================================");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.3*NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        initHooks();
    });
}
