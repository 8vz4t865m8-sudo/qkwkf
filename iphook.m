//
//  MyRadarHook.m
//  功能：T3卡密验证 + 云端推流修复
//  编译：clang -framework Foundation -framework UIKit -dynamiclib -o MyRadarHook.dylib MyRadarHook.m
//

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

// ==================== 配置区域 ====================
// 改成你的服务器地址
#define MY_SERVER_HOST      @"162.14.104.134"      // 你的服务器IP
#define MY_SERVER_PORT      @"3000"                 // 端口（宝塔用3000）
#define MY_SERVER_SCHEME    @"ws://"                // ws:// 或 wss://

// 构建完整地址
#define MY_HTTP_BASE        (@"http://" MY_SERVER_HOST @":" MY_SERVER_PORT)
#define MY_WS_BASE          (MY_SERVER_SCHEME MY_SERVER_HOST @":" MY_SERVER_PORT)

// T3 配置（你的卡密平台）
#define T3_LOGIN_CODE       @"B9F97729EC64A6C9"
#define T3_NOTICE_CODE      @"9E37BB60E3AFFCEE"
#define T3_VERSION_CODE     @"2A78BD88E7376215"
#define T3_HEARTBEAT_CODE   @"168AA83248396F84"
#define T3_APPKEY           @"15cab0658474ff4a93ebd8ab8337dab0"
#define T3_RSA_PUBLIC_KEY   @"-----BEGIN PUBLIC KEY-----\n"                             "MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQCxj7u3l9DKEyaluMG11BVdfg5z\n"                             "/6ieD1iwGzl6txP5G6nAEPxU3BzdEvI4Z20AOAJoGdmflpDq947lgp+tG61G8DeK\n"                             "ZLsZWb9t18+L/ThZCCv1xWxb5Llr4mt9yUh5IPHwl5Zy8nxWL64onFJaRIrif+JR\n"                             "U0sEt6p3P7lCc3JkPwIDAQAB\n"                             "-----END PUBLIC KEY-----"

#define OLD_VERIFY_CLASS    "NetworkVerifyClient"

// ==================== 全局变量 ====================
static id g_t3Verify = nil;
static NSString *g_cardNo = nil;
static NSString *g_statecode = nil;
static BOOL g_t3Verified = NO;
static BOOL g_t3InitSuccess = NO;
static NSTimer *g_heartbeatTimer = nil;

static IMP orig_activateWithCardNo = NULL;
static IMP orig_heartbeat = NULL;
static IMP orig_isActivated = NULL;
static IMP orig_cardNo = NULL;

// ==================== 工具宏 ====================
#define SAFE_HOOK(className, sel, newImp, oldImpPtr)     do {         Class cls = objc_getClass(className);         if (cls) {             Method m = class_getInstanceMethod(cls, sel);             if (m) {                 if (oldImpPtr) *(oldImpPtr) = method_getImplementation(m);                 method_setImplementation(m, (IMP)newImp);                 NSLog(@"[IPHook] Hook: %s", sel_getName(sel));             } else NSLog(@"[IPHook] 找不到方法: %s", sel_getName(sel));         } else NSLog(@"[IPHook] 找不到类: %s", className);     } while(0)

// ==================== 工具函数 ====================
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

// ==================== T3 初始化 ====================
static void initT3() {
    if (g_t3Verify) return;
    Class t3Class = NSClassFromString(@"T3Verify");
    if (!t3Class) {
        NSLog(@"[IPHook] 错误: T3Verify 类不存在");
        return;
    }
    g_t3Verify = [[t3Class alloc] init];

    // 调用 initRsaWithLoginCode:noticeCode:versionCode:heartbeatCode:appkey:rsaPublicKey:error:
    SEL initSel = NSSelectorFromString(@"initRsaWithLoginCode:noticeCode:versionCode:heartbeatCode:appkey:rsaPublicKey:error:");
    if ([g_t3Verify respondsToSelector:initSel]) {
        NSError *error = nil;
        BOOL ok = ((BOOL(*)(id, SEL, id, id, id, id, id, id, id *))objc_msgSend)
            (g_t3Verify, initSel,
             T3_LOGIN_CODE, T3_NOTICE_CODE, T3_VERSION_CODE,
             T3_HEARTBEAT_CODE, T3_APPKEY, T3_RSA_PUBLIC_KEY, &error);
        g_t3InitSuccess = ok;
        if (ok) NSLog(@"[IPHook] T3 初始化成功");
        else NSLog(@"[IPHook] T3 初始化失败: %@", error ? error.localizedDescription : @"未知错误");
    } else {
        NSLog(@"[IPHook] T3Verify 初始化方法不存在");
    }
}

// ==================== 心跳 ====================
static void startHeartbeat() {
    if (g_heartbeatTimer) return;
    g_heartbeatTimer = [NSTimer scheduledTimerWithTimeInterval:30 repeats:YES block:^(NSTimer *t) {
        if (!g_t3Verified || !g_cardNo || !g_statecode) return;
        dispatch_async(dispatch_get_global_queue(0,0), ^{
            SEL hbSel = NSSelectorFromString(@"heartbeatWithKami:statecode:");
            if ([g_t3Verify respondsToSelector:hbSel]) {
                id r = ((id(*)(id, SEL, id, id))objc_msgSend)(g_t3Verify, hbSel, g_cardNo, g_statecode);
                if (r && [r respondsToSelector:@selector(success)]) {
                    BOOL success = ((BOOL(*)(id, SEL))objc_msgSend)(r, @selector(success));
                    if (!success) { g_t3Verified = NO; NSLog(@"[IPHook] 心跳失败"); }
                }
            }
        });
    }];
}

// ==================== 注入卡号到单例 ====================
static void injectCardToAllSingletons(NSString *card) {
    NSArray *names = @[@"DeviceManager", @"AppConfig", @"UserManager", @"MRConfig", @"GlobalConfig"];
    for (NSString *name in names) {
        Class cls = objc_getClass(name.UTF8String);
        if (!cls) continue;
        id instance = nil;
        for (NSString *selName in @[@"sharedInstance", @"shared", @"defaultManager", @"currentManager"]) {
            SEL sel = NSSelectorFromString(selName);
            if ([cls respondsToSelector:sel]) {
                instance = ((id(*)(id,SEL))objc_msgSend)(cls, sel);
                break;
            }
        }
        if (!instance) continue;
        SEL setSel = NSSelectorFromString(@"setCardNo:");
        if ([instance respondsToSelector:setSel]) {
            ((void(*)(id,SEL,id))objc_msgSend)(instance, setSel, card);
        }
        @try { [instance setValue:card forKey:@"cardNo"]; } @catch (NSException *e) {}
    }

    // 注入到 MRCloudRelay
    Class mrCls = objc_getClass("MRCloudRelay");
    if (mrCls) {
        id mr = ((id(*)(id, SEL))objc_msgSend)(mrCls, @selector(shared));
        if (mr) {
            if ([mr respondsToSelector:@selector(setCardNo:)])
                ((void(*)(id, SEL, id))objc_msgSend)(mr, @selector(setCardNo:), card);
            if ([mr respondsToSelector:@selector(setMachineId:)]) {
                NSString *machineId = nil;
                Class t3Class = NSClassFromString(@"T3Verify");
                SEL machineSel = NSSelectorFromString(@"getMachineCode");
                if ([t3Class respondsToSelector:machineSel]) {
                    machineId = ((id(*)(id, SEL))objc_msgSend)(t3Class, machineSel);
                }
                ((void(*)(id, SEL, id))objc_msgSend)(mr, @selector(setMachineId:), machineId ?: @"default");
            }
            NSLog(@"[IPHook] 注入卡号到 MRCloudRelay");
        }
    }

    [[NSUserDefaults standardUserDefaults] setObject:card forKey:@"cardNo"];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

// ==================== 验证 Hook ====================
static void hook_activateWithCardNo(id self, SEL _cmd, NSString *cardNo, NSString *machineId, id completion) {
    if (!cardNo.length) return;
    if (!g_t3InitSuccess) { initT3(); if (!g_t3InitSuccess) return; }

    g_cardNo = cardNo;
    NSString *imei = machineId.length ? machineId : @"default";

    // 尝试获取机器码
    Class t3Class = NSClassFromString(@"T3Verify");
    SEL machineSel = NSSelectorFromString(@"getMachineCode");
    if ([t3Class respondsToSelector:machineSel]) {
        imei = ((id(*)(id, SEL))objc_msgSend)(t3Class, machineSel) ?: imei;
    }

    dispatch_async(dispatch_get_global_queue(0,0), ^{
        SEL loginSel = NSSelectorFromString(@"loginWithKami:imei:");
        id r = nil;
        if ([g_t3Verify respondsToSelector:loginSel]) {
            r = ((id(*)(id, SEL, id, id))objc_msgSend)(g_t3Verify, loginSel, cardNo, imei);
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            BOOL success = NO;
            NSString *errorMsg = @"验证失败";
            NSString *statecode = nil;

            if (r) {
                if ([r respondsToSelector:@selector(success)])
                    success = ((BOOL(*)(id, SEL))objc_msgSend)(r, @selector(success));
                if ([r respondsToSelector:@selector(error)])
                    errorMsg = ((id(*)(id, SEL))objc_msgSend)(r, @selector(error)) ?: errorMsg;
                if ([r respondsToSelector:@selector(statecode)])
                    statecode = ((id(*)(id, SEL))objc_msgSend)(r, @selector(statecode));
            }

            if (success) {
                g_t3Verified = YES;
                g_statecode = statecode;
                if ([self respondsToSelector:@selector(setIsActivated:)])
                    ((void(*)(id,SEL,BOOL))objc_msgSend)(self, @selector(setIsActivated:), YES);
                if ([self respondsToSelector:@selector(setCardNo:)])
                    ((void(*)(id,SEL,id))objc_msgSend)(self, @selector(setCardNo:), cardNo);
                injectCardToAllSingletons(cardNo);
                showHUD(YES, @"验证成功");
                startHeartbeat();
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.5*NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                    UIViewController *vc = topViewController();
                    if ([vc respondsToSelector:@selector(enterMainConsole)])
                        ((void(*)(id,SEL))objc_msgSend)(vc, @selector(enterMainConsole));
                });
            } else {
                g_t3Verified = NO; g_statecode = nil;
                showHUD(NO, errorMsg);
            }

            // 调用原 completion（可选）
            if (completion) {
                @try {
                    ((void(^)(BOOL, NSError*))completion)(success, nil);
                } @catch (NSException *e) {}
            }
        });
    });
}

static void hook_heartbeatWithCompletion(id self, SEL _cmd, id completion) {
    if (!g_t3Verified) {
        if (completion) {
            @try {
                ((void(^)(NSError*))completion)([NSError errorWithDomain:@"IPHook" code:401 userInfo:nil]);
            } @catch (NSException *e) {}
        }
        return;
    }
    dispatch_async(dispatch_get_global_queue(0,0), ^{
        SEL hbSel = NSSelectorFromString(@"heartbeatWithKami:statecode:");
        if ([g_t3Verify respondsToSelector:hbSel]) {
            id r = ((id(*)(id, SEL, id, id))objc_msgSend)(g_t3Verify, hbSel, g_cardNo, g_statecode);
            if (r && [r respondsToSelector:@selector(success)]) {
                BOOL success = ((BOOL(*)(id, SEL))objc_msgSend)(r, @selector(success));
                if (!success) g_t3Verified = NO;
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) {
                @try {
                    ((void(^)(NSError*))completion)(nil);
                } @catch (NSException *e) {}
            }
        });
    });
}

static BOOL hook_isActivated(id self, SEL _cmd) { return g_t3Verified; }
static id hook_cardNo(id self, SEL _cmd) { return g_cardNo ?: @""; }

// ==================== MRCloudRelay 云端修复 ====================

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

    // 设置内部属性
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

// ==================== 推流属性修复 ====================
static NSString *fake_cardNo(id self, SEL _cmd) { return g_cardNo ?: @"CARD_DEFAULT"; }
static NSString *fake_machineId(id self, SEL _cmd) { return @"MACHINE_DEFAULT"; }

static void safeReplaceMethod(Class cls, SEL sel, IMP imp) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;
    char ret[4] = {0};
    method_getReturnType(m, ret, sizeof(ret));
    if (ret[0] != '@') return;
    class_replaceMethod(cls, sel, imp, "@@:");
}

static void initPushStreamHooks() {
    NSArray *classes = @[@"MRCloudRelay", @"MRStreamer", @"MRPushManager", @"CloudRelay",
                         @"MRRoomManager", @"MRApiClient", @"LiveStreamManager", @"PushEngine"];
    for (NSString *name in classes) {
        Class cls = objc_getClass(name.UTF8String);
        if (!cls) continue;
        SEL cardSels[] = { @selector(cardNo), NSSelectorFromString(@"card_no"),
                           NSSelectorFromString(@"CardNo"), NSSelectorFromString(@"getCardNo") };
        for (int i=0; i<4; i++) safeReplaceMethod(cls, cardSels[i], (IMP)fake_cardNo);
        SEL machineSels[] = { @selector(machineId), NSSelectorFromString(@"machine_id"),
                              NSSelectorFromString(@"MachineId"), NSSelectorFromString(@"getMachineId") };
        for (int i=0; i<4; i++) safeReplaceMethod(cls, machineSels[i], (IMP)fake_machineId);
    }
    NSArray *singletons = @[@"DeviceManager", @"AppConfig", @"UserManager", @"MRConfig", @"GlobalConfig"];
    for (NSString *name in singletons) {
        Class cls = objc_getClass(name.UTF8String);
        if (!cls) continue;
        safeReplaceMethod(cls, @selector(cardNo), (IMP)fake_cardNo);
        safeReplaceMethod(cls, NSSelectorFromString(@"getCardNo"), (IMP)fake_cardNo);
        safeReplaceMethod(cls, @selector(machineId), (IMP)fake_machineId);
    }
    NSLog(@"[IPHook] 推流属性 Hook 完成");
}

static void initCloudRelayHooks() {
    const char *clsName = "MRCloudRelay";
    SAFE_HOOK(clsName, @selector(mr_wsBase), hook_mr_wsBase, NULL);
    SAFE_HOOK(clsName, @selector(mr_buildPublishWsUrl), hook_mr_buildPublishWsUrl, NULL);
    SAFE_HOOK(clsName, @selector(ensureRoomWithCompletion:), hook_ensureRoomWithCompletion, NULL);
    SAFE_HOOK(clsName, @selector(closeRoomWithCompletion:), hook_closeRoomWithCompletion, NULL);
    SAFE_HOOK(clsName, @selector(openSharingWithCompletion:), hook_openSharingWithCompletion, NULL);
    SAFE_HOOK(clsName, @selector(currentDirectWatchUrl), hook_currentDirectWatchUrl, NULL);
    SAFE_HOOK(clsName, @selector(currentRoomCode), hook_currentRoomCode, NULL);
    NSLog(@"[IPHook] MRCloudRelay 云端修复完成");
}

// ==================== 总初始化 ====================
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
    initCloudRelayHooks();
    NSLog(@"[IPHook] 全部初始化完成");
}

__attribute__((constructor))
static void iphook_init() {
    NSLog(@"[IPHook] T3验证+云端推流修复 加载");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.5*NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        initHooks();
    });
}
