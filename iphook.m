//
//  MyRadarHook_v5.m - T3验证替换 + 云端推流修复（v5）
//
// 核心修复：
// forwardPayload 可能使用 MRCloudRelay 内部的 wsTask 发送数据
// 需要在 ensureRoomWithCompletion: 里把内部 wsTask 替换成我们的
//

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "T3Verify.h"

// ============================================================
// ⚙️ 配置
// ============================================================
#define T3_LOGIN_CODE      @"B9F97729EC64A6C9"
#define T3_NOTICE_CODE     @"9E37BB60E3AFFCEE"
#define T3_VERSION_CODE    @"2A78BD88E7376215"
#define T3_HEARTBEAT_CODE  @"168AA83248396F84"
#define T3_APPKEY          @"15cab0658474ff4a93ebd8ab8337dab0"
#define T3_RSA_PUBLIC_KEY  @"-----BEGIN PUBLIC KEY-----\n"                             "MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQCxj7u3l9DKEyaluMG11BVdfg5z\n"                             "/6ieD1iwGzl6txP5G6nAEPxU3BzdEvI4Z20AOAJoGdmflpDq947lgp+tG61G8DeK\n"                             "ZLsZWb9t18+L/ThZCCv1xWxb5Llr4mt9yUh5IPHwl5Zy8nxWL64onFJaRIrif+JR\n"                             "U0sEt6p3P7lCc3JkPwIDAQAB\n"                             "-----END PUBLIC KEY-----"

#define OLD_VERIFY_CLASS   "NetworkVerifyClient"
#define MY_SERVER_HOST     @"162.14.104.134"
#define MY_SERVER_PORT     @"3000"
#define MY_SERVER_SCHEME   @"ws://"
#define MY_HTTP_BASE       (@"http://" MY_SERVER_HOST @":" MY_SERVER_PORT)
#define MY_WS_BASE         (MY_SERVER_SCHEME MY_SERVER_HOST @":" MY_SERVER_PORT)

// ============================================================
// 全局状态
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
// 工具函数
// ============================================================
static void hookMethod(const char *className, SEL sel, IMP newImp, IMP *oldImp) {
    Class cls = objc_getClass(className);
    if (!cls) { NSLog(@"[IPHook] 找不到类: %s", className); return; }
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) { NSLog(@"[IPHook] 找不到方法: %s", sel_getName(sel)); return; }
    if (oldImp) *oldImp = method_getImplementation(m);
    method_setImplementation(m, newImp);
    NSLog(@"[IPHook] Hook: %s", sel_getName(sel));
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

// ============================================================
// T3 初始化
// ============================================================
static void initT3() {
    if (g_t3Verify) return;
    g_t3Verify = [[T3Verify alloc] init];
    NSError *error = nil;
    BOOL ok = [g_t3Verify initRsaWithLoginCode:T3_LOGIN_CODE noticeCode:T3_NOTICE_CODE
                                   versionCode:T3_VERSION_CODE heartbeatCode:T3_HEARTBEAT_CODE
                                        appkey:T3_APPKEY rsaPublicKey:T3_RSA_PUBLIC_KEY error:&error];
    g_t3InitSuccess = ok;
    if (ok) NSLog(@"[IPHook] T3 初始化成功");
    else NSLog(@"[IPHook] T3 初始化失败: %@", error.localizedDescription);
}

// ============================================================
// 心跳
// ============================================================
static void startHeartbeat() {
    if (g_heartbeatTimer) return;
    g_heartbeatTimer = [NSTimer scheduledTimerWithTimeInterval:30.0 repeats:YES block:^(NSTimer *timer) {
        if (!g_t3Verified || !g_cardNo || !g_statecode) return;
        dispatch_async(dispatch_get_global_queue(0,0), ^{
            T3Result *r = [g_t3Verify heartbeatWithKami:g_cardNo statecode:g_statecode];
            if (!r.success) { g_t3Verified = NO; NSLog(@"[IPHook] 心跳失败"); }
        });
    }];
    dispatch_async(dispatch_get_global_queue(0,0), ^{
        T3Result *r = [g_t3Verify heartbeatWithKami:g_cardNo statecode:g_statecode];
        if (!r.success) g_t3Verified = NO;
    });
}

// ============================================================
// 验证 Hook
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
                if ([self respondsToSelector:@selector(setIsActivated:)]) {
                    ((void(*)(id, SEL, BOOL))objc_msgSend)(self, @selector(setIsActivated:), YES);
                }
                if ([self respondsToSelector:@selector(setCardNo:)]) {
                    ((void(*)(id, SEL, id))objc_msgSend)(self, @selector(setCardNo:), cardNo);
                }
                showSuccess(@"验证成功");
                startHeartbeat();
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

// ============================================================
// ☁️ 云端推流修复 - v5
// ============================================================

// 【关键】创建 WebSocket 连接到你的服务器，并设置到 MRCloudRelay 的 wsTask
static NSURLSessionWebSocketTask* createMyWebSocketTask(NSString *room) {
    NSString *wsUrl = [NSString stringWithFormat:@"%@/loon?room=%@", MY_WS_BASE, room ?: @"ROOM001"];
    NSLog(@"[IPHook] 创建 WS: %@", wsUrl);

    NSURL *url = [NSURL URLWithString:wsUrl];
    NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
    NSURLSession *session = [NSURLSession sessionWithConfiguration:config];
    NSURLSessionWebSocketTask *task = [session webSocketTaskWithURL:url];

    // 设置接收回调
    [task receiveMessageWithCompletionHandler:^(NSURLSessionWebSocketMessage *msg, NSError *err) {
        if (err) NSLog(@"[IPHook] WS 接收错误: %@", err);
        else NSLog(@"[IPHook] WS 收到消息");
    }];

    [task resume];
    NSLog(@"[IPHook] WS 已启动");
    return task;
}

// 1. 伪造房间创建成功，并替换内部的 wsTask
static void hook_ensureRoomWithCompletion(id self, SEL _cmd, id completion) {
    NSString *fakeRoom = @"ROOM001";
    NSString *watchUrl = [NSString stringWithFormat:@"%@/?game=dfm&room=%@", MY_HTTP_BASE, fakeRoom];

    // 设置属性
    if ([self respondsToSelector:@selector(setRoomCode:)]) {
        ((void(*)(id, SEL, id))objc_msgSend)(self, @selector(setRoomCode:), fakeRoom);
    }
    if ([self respondsToSelector:@selector(setViewUrl:)]) {
        ((void(*)(id, SEL, id))objc_msgSend)(self, @selector(setViewUrl:), watchUrl);
    }
    if ([self respondsToSelector:@selector(setDirectWatchUrl:)]) {
        ((void(*)(id, SEL, id))objc_msgSend)(self, @selector(setDirectWatchUrl:), watchUrl);
    }
    if ([self respondsToSelector:@selector(setPubToken:)]) {
        ((void(*)(id, SEL, id))objc_msgSend)(self, @selector(setPubToken:), @"faketoken");
    }
    if ([self respondsToSelector:@selector(setPublishWsUrl:)]) {
        ((void(*)(id, SEL, id))objc_msgSend)(self, @selector(setPublishWsUrl:),
            [NSString stringWithFormat:@"%@/loon?room=%@", MY_WS_BASE, fakeRoom]);
    }
    if ([self respondsToSelector:@selector(setCreating:)]) {
        ((void(*)(id, SEL, BOOL))objc_msgSend)(self, @selector(setCreating:), NO);
    }
    if ([self respondsToSelector:@selector(setIsSharingEnabled:)]) {
        ((void(*)(id, SEL, BOOL))objc_msgSend)(self, @selector(setIsSharingEnabled:), YES);
    }
    if ([self respondsToSelector:@selector(setWsConnected:)]) {
        ((void(*)(id, SEL, BOOL))objc_msgSend)(self, @selector(setWsConnected:), YES);
    }
    if ([self respondsToSelector:@selector(setWsConnecting:)]) {
        ((void(*)(id, SEL, BOOL))objc_msgSend)(self, @selector(setWsConnecting:), NO);
    }

    // 【关键】创建自己的 WS 并替换 MRCloudRelay 内部的 wsTask
    NSURLSessionWebSocketTask *myTask = createMyWebSocketTask(fakeRoom);
    if ([self respondsToSelector:@selector(setWsTask:)]) {
        ((void(*)(id, SEL, id))objc_msgSend)(self, @selector(setWsTask:), myTask);
        NSLog(@"[IPHook] 已替换 wsTask");
    }

    NSLog(@"[IPHook] 房间伪造成功: %@", fakeRoom);

    // 回调
    if (completion) {
        dispatch_async(dispatch_get_main_queue(), ^{
            @try {
                ((void(^)(NSString*, NSError*))completion)(fakeRoom, nil);
            } @catch (NSException *e) {
                @try { ((void(^)(NSError*))completion)(nil); } @catch (NSException *e2) {}
            }
        });
    }
}

// 2. 拦截数据转发，通过替换后的 wsTask 发送
static void hook_forwardPayload(id self, SEL _cmd, const void *payload, NSUInteger length) {
    // 获取 MRCloudRelay 内部的 wsTask（已经被替换为我们的）
    NSURLSessionWebSocketTask *task = nil;
    if ([self respondsToSelector:@selector(wsTask)]) {
        task = ((id(*)(id, SEL))objc_msgSend)(self, @selector(wsTask));
    }

    if (task && task.readyState == NSURLSessionWebSocketTaskStateRunning) {
        NSData *data = [NSData dataWithBytes:payload length:length];
        NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if (text) {
            NSURLSessionWebSocketMessage *msg = [[NSURLSessionWebSocketMessage alloc] initWithString:text];
            [task sendMessage:msg completionHandler:^(NSError *err) {
                if (err) NSLog(@"[IPHook] 发送失败: %@", err);
                else NSLog(@"[IPHook] 发送成功: %lu bytes", length);
            }];
        }
    } else {
        NSLog(@"[IPHook] wsTask 不可用，尝试直接发送");
        // 如果 wsTask 不可用，创建新的连接发送
        NSString *room = nil;
        if ([self respondsToSelector:@selector(roomCode)]) {
            room = ((id(*)(id, SEL))objc_msgSend)(self, @selector(roomCode));
        }
        NSURLSessionWebSocketTask *newTask = createMyWebSocketTask(room ?: @"ROOM001");
        NSData *data = [NSData dataWithBytes:payload length:length];
        NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if (text) {
            NSURLSessionWebSocketMessage *msg = [[NSURLSessionWebSocketMessage alloc] initWithString:text];
            [newTask sendMessage:msg completionHandler:^(NSError *err) {
                if (err) NSLog(@"[IPHook] 发送失败: %@", err);
            }];
        }
    }
}

// 3. 返回观看链接
static id hook_currentDirectWatchUrl(id self, SEL _cmd) {
    NSString *room = nil;
    if ([self respondsToSelector:@selector(roomCode)]) {
        room = ((id(*)(id, SEL))objc_msgSend)(self, @selector(roomCode));
    }
    if (!room) room = @"ROOM001";
    return [NSString stringWithFormat:@"%@/?game=dfm&room=%@", MY_HTTP_BASE, room];
}

// 4. 返回房间码
static id hook_currentRoomCode(id self, SEL _cmd) {
    NSString *room = nil;
    if ([self respondsToSelector:@selector(roomCode)]) {
        room = ((id(*)(id, SEL))objc_msgSend)(self, @selector(roomCode));
    }
    return room ?: @"ROOM001";
}

// 5. 返回 WS 基础地址
static id hook_mr_wsBase(id self, SEL _cmd) { return MY_WS_BASE; }

// 6. 构建发布 URL
static id hook_mr_buildPublishWsUrl(id self, SEL _cmd) {
    NSString *room = nil;
    if ([self respondsToSelector:@selector(roomCode)]) {
        room = ((id(*)(id, SEL))objc_msgSend)(self, @selector(roomCode));
    }
    if (!room) room = @"ROOM001";
    return [NSString stringWithFormat:@"%@/loon?room=%@", MY_WS_BASE, room];
}

// ============================================================
// 初始化
// ============================================================
static void initHooks() {
    NSLog(@"[IPHook] 开始初始化...");

    hookMethod(OLD_VERIFY_CLASS, @selector(activateWithCardNo:machineId:completion:),
               (IMP)hook_activateWithCardNo, &orig_activateWithCardNo);
    hookMethod(OLD_VERIFY_CLASS, @selector(heartbeatWithCompletion:),
               (IMP)hook_heartbeatWithCompletion, &orig_heartbeat);
    hookMethod(OLD_VERIFY_CLASS, @selector(isActivated),
               (IMP)hook_isActivated, &orig_isActivated);
    hookMethod(OLD_VERIFY_CLASS, @selector(cardNo),
               (IMP)hook_cardNo, &orig_cardNo);

    initT3();

    const char *mrClass = "MRCloudRelay";
    hookMethod(mrClass, @selector(ensureRoomWithCompletion:), (IMP)hook_ensureRoomWithCompletion, NULL);
    hookMethod(mrClass, @selector(forwardPayload:length:), (IMP)hook_forwardPayload, NULL);
    hookMethod(mrClass, @selector(currentDirectWatchUrl), (IMP)hook_currentDirectWatchUrl, NULL);
    hookMethod(mrClass, @selector(currentRoomCode), (IMP)hook_currentRoomCode, NULL);
    hookMethod(mrClass, @selector(mr_wsBase), (IMP)hook_mr_wsBase, NULL);
    hookMethod(mrClass, @selector(mr_buildPublishWsUrl), (IMP)hook_mr_buildPublishWsUrl, NULL);

    NSLog(@"[IPHook] 全部初始化完成");
}

__attribute__((constructor))
static void iphook_init() {
    NSLog(@"========================================");
    NSLog(@"[IPHook] T3验证+云端推流修复 v5 已加载");
    NSLog(@"[IPHook] 服务器: %@", MY_HTTP_BASE);
    NSLog(@"========================================");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.3*NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        initHooks();
    });
}
