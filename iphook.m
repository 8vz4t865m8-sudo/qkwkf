//
//  MyRadarHook.m - T3验证替换 + 云端推流修复（完整版）
//
// 功能：
// 1. 拦截原卡密验证，替换为T3验证
// 2. 心跳走T3
// 3. 云端推流指向自己的服务器（绕过原服务端"卡密不存在"）
//

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "T3Verify.h"

// ============================================================
// ⚙️ 配置区域
// ============================================================

// T3 验证参数
#define T3_LOGIN_CODE      @"B9F97729EC64A6C9"
#define T3_NOTICE_CODE     @"9E37BB60E3AFFCEE"
#define T3_VERSION_CODE    @"2A78BD88E7376215"
#define T3_HEARTBEAT_CODE  @"168AA83248396F84"
#define T3_APPKEY          @"15cab0658474ff4a93ebd8ab8337dab0"
#define T3_RSA_PUBLIC_KEY  @"-----BEGIN PUBLIC KEY-----\n"                             "MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQCxj7u3l9DKEyaluMG11BVdfg5z\n"                             "/6ieD1iwGzl6txP5G6nAEPxU3BzdEvI4Z20AOAJoGdmflpDq947lgp+tG61G8DeK\n"                             "ZLsZWb9t18+L/ThZCCv1xWxb5Llr4mt9yUh5IPHwl5Zy8nxWL64onFJaRIrif+JR\n"                             "U0sEt6p3P7lCc3JkPwIDAQAB\n"                             "-----END PUBLIC KEY-----"

// 原验证类名
#define OLD_VERIFY_CLASS   "NetworkVerifyClient"

// 你的服务器配置
#define MY_SERVER_HOST      @"162.14.104.134"
#define MY_SERVER_PORT      @"3000"
#define MY_SERVER_SCHEME    @"ws://"
#define MY_HTTP_BASE        (@"http://" MY_SERVER_HOST @":" MY_SERVER_PORT)
#define MY_WS_BASE          (MY_SERVER_SCHEME MY_SERVER_HOST @":" MY_SERVER_PORT)

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
// 🔧 工具宏和函数
// ============================================================

#define HOOK_METHOD(className, sel, newImp, oldImp)     do {         Class cls = objc_getClass(className);         if (cls) {             Method m = class_getInstanceMethod(cls, sel);             if (m) {                 oldImp = method_getImplementation(m);                 method_setImplementation(m, (IMP)newImp);                 NSLog(@"[IPHook] Hook: %s", sel_getName(sel));             } else {                 NSLog(@"[IPHook] 找不到方法: %s", sel_getName(sel));             }         } else {             NSLog(@"[IPHook] 找不到类: %s", className);         }     } while(0)

static UIViewController *getViewController() {
    UIViewController *vc = [UIApplication sharedApplication].keyWindow.rootViewController;
    if (!vc) return nil;
    if ([vc isKindOfClass:[UINavigationController class]]) {
        vc = [(UINavigationController *)vc topViewController];
    }
    while (vc.presentedViewController) {
        vc = vc.presentedViewController;
    }
    return vc;
}

static void showSuccess(NSString *status) {
    Class hudClass = NSClassFromString(@"SVProgressHUD");
    if (hudClass) {
        @try {
            [hudClass performSelector:@selector(showSuccessWithStatus:) withObject:status];
        } @catch (NSException *e) {}
    }
}

static void showError(NSString *status) {
    Class hudClass = NSClassFromString(@"SVProgressHUD");
    if (hudClass) {
        @try {
            [hudClass performSelector:@selector(showErrorWithStatus:) withObject:status];
        } @catch (NSException *e) {}
    }
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
        NSLog(@"[IPHook] T3 初始化成功");
    } else {
        NSLog(@"[IPHook] T3 初始化失败: %@", error.localizedDescription);
    }
}

// ============================================================
// 💓 心跳
// ============================================================

static void startHeartbeat() {
    if (g_heartbeatTimer) return;

    g_heartbeatTimer = [NSTimer scheduledTimerWithTimeInterval:30.0 repeats:YES block:^(NSTimer *timer) {
        if (!g_t3Verified || !g_cardNo || !g_statecode) return;

        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            T3Result *result = [g_t3Verify heartbeatWithKami:g_cardNo statecode:g_statecode];
            if (!result.success) {
                NSLog(@"[IPHook] 心跳失败: %@", result.error);
                g_t3Verified = NO;
            }
        });
    }];

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        T3Result *result = [g_t3Verify heartbeatWithKami:g_cardNo statecode:g_statecode];
        if (!result.success) g_t3Verified = NO;
    });
}

// ============================================================
// 🎣 Hook: 卡密验证（核心）
// ============================================================

static void hook_activateWithCardNo(id self, SEL _cmd,
                                     NSString *cardNo,
                                     NSString *machineId,
                                     id completion) {
    NSLog(@"[IPHook] 拦截卡密验证: %@", cardNo);

    if (!g_t3InitSuccess) {
        initT3();
        if (!g_t3InitSuccess) {
            showError(@"验证初始化失败");
            return;
        }
    }

    g_cardNo = cardNo;
    NSString *imei = machineId;
    if (!imei || imei.length == 0) {
        imei = [T3Verify getMachineCode];
    }

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        T3LoginResult *result = [g_t3Verify loginWithKami:cardNo imei:imei];

        dispatch_async(dispatch_get_main_queue(), ^{
            if (result.success) {
                g_t3Verified = YES;
                g_statecode = result.statecode;

                if ([self respondsToSelector:@selector(setIsActivated:)]) {
                    ((void(*)(id, SEL, BOOL))objc_msgSend)(self, @selector(setIsActivated:), YES);
                }
                if ([self respondsToSelector:@selector(setCardNo:)]) {
                    ((void(*)(id, SEL, id))objc_msgSend)(self, @selector(setCardNo:), cardNo);
                }

                showSuccess(@"验证成功");
                startHeartbeat();

                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    enterMainConsole();
                });

            } else {
                g_t3Verified = NO;
                g_statecode = nil;
                showError(result.error ?: @"验证失败");
            }
        });
    });
}

// ============================================================
// 🎣 Hook: 心跳
// ============================================================

static void hook_heartbeatWithCompletion(id self, SEL _cmd, id completion) {
    if (!g_t3Verified || !g_cardNo || !g_statecode) return;

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        T3Result *result = [g_t3Verify heartbeatWithKami:g_cardNo statecode:g_statecode];
        if (!result.success) g_t3Verified = NO;
    });
}

// ============================================================
// 🎣 Hook: 激活状态
// ============================================================

static BOOL hook_isActivated(id self, SEL _cmd) {
    return g_t3Verified;
}

// ============================================================
// 🎣 Hook: 卡号
// ============================================================

static id hook_cardNo(id self, SEL _cmd) {
    return g_cardNo ?: @"";
}

// ============================================================
// ☁️ 云端推流修复 - MRCloudRelay
// ============================================================

static id hook_mr_wsBase(id self, SEL _cmd) {
    return MY_WS_BASE;
}

static id hook_mr_buildPublishWsUrl(id self, SEL _cmd) {
    NSString *room = ((id(*)(id, SEL))objc_msgSend)(self, @selector(roomCode)) ?: @"ROOM001";
    return [NSString stringWithFormat:@"%@/loon?room=%@", MY_WS_BASE, room];
}

static void hook_ensureRoomWithCompletion(id self, SEL _cmd, id completion) {
    NSString *fakeRoom = @"ROOM001";
    NSString *watchUrl = [NSString stringWithFormat:@"%@/?game=dfm&room=%@", MY_HTTP_BASE, fakeRoom];

    ((void(*)(id, SEL, id))objc_msgSend)(self, @selector(setRoomCode:), fakeRoom);
    ((void(*)(id, SEL, id))objc_msgSend)(self, @selector(setViewUrl:), watchUrl);
    ((void(*)(id, SEL, id))objc_msgSend)(self, @selector(setDirectWatchUrl:), watchUrl);
    ((void(*)(id, SEL, id))objc_msgSend)(self, @selector(setPubToken:), @"faketoken");
    ((void(*)(id, SEL, id))objc_msgSend)(self, @selector(setPublishWsUrl:),
        [NSString stringWithFormat:@"%@/loon?room=%@", MY_WS_BASE, fakeRoom]);
    ((void(*)(id, SEL, BOOL))objc_msgSend)(self, @selector(setCreating:), NO);
    ((void(*)(id, SEL, BOOL))objc_msgSend)(self, @selector(setIsSharingEnabled:), YES);

    NSLog(@"[IPHook] 云端房间伪造: %@ | %@", fakeRoom, watchUrl);

    if (completion) {
        dispatch_async(dispatch_get_main_queue(), ^{
            @try {
                ((void(^)(NSString*, NSError*))completion)(fakeRoom, nil);
            } @catch (NSException *e) {
                @try {
                    ((void(^)(NSError*))completion)(nil);
                } @catch (NSException *e2) {}
            }
        });
    }
}

static void hook_closeRoomWithCompletion(id self, SEL _cmd, id completion) {
    ((void(*)(id, SEL, BOOL))objc_msgSend)(self, @selector(setIsSharingEnabled:), NO);
    if (completion) {
        @try { ((void(^)(NSError*))completion)(nil); } @catch (NSException *e) {}
    }
}

static void hook_openSharingWithCompletion(id self, SEL _cmd, id completion) {
    ((void(*)(id, SEL, id))objc_msgSend)(self, @selector(ensureRoomWithCompletion:), completion);
}

static id hook_currentDirectWatchUrl(id self, SEL _cmd) {
    NSString *room = ((id(*)(id, SEL))objc_msgSend)(self, @selector(roomCode)) ?: @"ROOM001";
    return [NSString stringWithFormat:@"%@/?game=dfm&room=%@", MY_HTTP_BASE, room];
}

static id hook_currentRoomCode(id self, SEL _cmd) {
    id room = ((id(*)(id, SEL))objc_msgSend)(self, @selector(roomCode));
    return room ?: @"ROOM001";
}

// ============================================================
// 🔌 初始化所有 Hook
// ============================================================

static void initHooks() {
    NSLog(@"[IPHook] 开始初始化 Hook...");

    // 1. 验证 Hook
    Class oldClass = objc_getClass(OLD_VERIFY_CLASS);
    if (oldClass) {
        HOOK_METHOD(OLD_VERIFY_CLASS, @selector(activateWithCardNo:machineId:completion:),
                    (IMP)hook_activateWithCardNo, orig_activateWithCardNo);
        HOOK_METHOD(OLD_VERIFY_CLASS, @selector(heartbeatWithCompletion:),
                    (IMP)hook_heartbeatWithCompletion, orig_heartbeat);
        HOOK_METHOD(OLD_VERIFY_CLASS, @selector(isActivated),
                    (IMP)hook_isActivated, orig_isActivated);
        HOOK_METHOD(OLD_VERIFY_CLASS, @selector(cardNo),
                    (IMP)hook_cardNo, orig_cardNo);
    }

    // 2. T3 初始化
    initT3();

    // 3. 云端推流 Hook
    const char *mrClass = "MRCloudRelay";
    HOOK_METHOD(mrClass, @selector(mr_wsBase), (IMP)hook_mr_wsBase, NULL);
    HOOK_METHOD(mrClass, @selector(mr_buildPublishWsUrl), (IMP)hook_mr_buildPublishWsUrl, NULL);
    HOOK_METHOD(mrClass, @selector(ensureRoomWithCompletion:), (IMP)hook_ensureRoomWithCompletion, NULL);
    HOOK_METHOD(mrClass, @selector(closeRoomWithCompletion:), (IMP)hook_closeRoomWithCompletion, NULL);
    HOOK_METHOD(mrClass, @selector(openSharingWithCompletion:), (IMP)hook_openSharingWithCompletion, NULL);
    HOOK_METHOD(mrClass, @selector(currentDirectWatchUrl), (IMP)hook_currentDirectWatchUrl, NULL);
    HOOK_METHOD(mrClass, @selector(currentRoomCode), (IMP)hook_currentRoomCode, NULL);

    NSLog(@"[IPHook] 全部 Hook 初始化完成");
}

// ============================================================
// 🚪 入口函数
// ============================================================

__attribute__((constructor))
static void iphook_init() {
    NSLog(@"========================================");
    NSLog(@"[IPHook] T3验证+云端推流修复 已加载");
    NSLog(@"[IPHook] 服务器: %@", MY_HTTP_BASE);
    NSLog(@"========================================");

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        initHooks();
    });
}
