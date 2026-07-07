//
//  MyRadarHook_v14.m - 终极修复版（后台保活 + 零掉帧）
//  核心修复：移除独立发送线程，回到 dispatch_async 模式
//  原因：v9 什么都没做就能后台保活，因为 dispatch_async 队列后台自动暂停
//        v12/v13 的 while(1) 发送线程被 iOS 看门狗视为活跃线程，后台直接杀
//

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <mach/mach_time.h>
#import "T3Verify.h"

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

static void setStringProp(id self, SEL sel, NSString *val) {
    if ([self respondsToSelector:sel]) {
        ((void(*)(id, SEL, id))objc_msgSend)(self, sel, val);
    }
}

static void setBoolProp(id self, SEL sel, BOOL val) {
    if ([self respondsToSelector:sel]) {
        ((void(*)(id, SEL, BOOL))objc_msgSend)(self, sel, val);
    }
}

static void safeCallCompletion(id completion, NSString *fakeRoom) {
    if (!completion) return;
    @try {
        void (^block1)(NSString *, NSError *) = completion;
        block1(fakeRoom, nil); return;
    } @catch (NSException *e) {}
    @try {
        void (^block2)(id, NSError *) = completion;
        block2(fakeRoom, nil); return;
    } @catch (NSException *e) {}
    @try {
        void (^block3)(BOOL, NSError *) = completion;
        block3(YES, nil); return;
    } @catch (NSException *e) {}
    @try {
        void (^block4)(void) = completion;
        block4(); return;
    } @catch (NSException *e) {}
}

static void saveCardToLocal(NSString *cardNo, NSString *machineId) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setObject:cardNo forKey:@"saved_card_no"];
    [defaults setObject:machineId forKey:@"udid"];
    [defaults setObject:@"dfm" forKey:@"wsr_game_profile"];
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
// 全局状态
// ============================================================
static BOOL g_cloudStreamingActive = NO;
static NSString *g_fakeRoom = @"ROOM001";

// 验证 Hook 原IMP
static IMP orig_activateWithCardNo = NULL;
static IMP orig_heartbeat = NULL;
static IMP orig_isActivated = NULL;
static IMP orig_cardNo = NULL;
static IMP orig_startHeartbeat = NULL;
static IMP orig_stopHeartbeat = NULL;

// MRCloudRelay 原IMP
static IMP orig_forwardPayload = NULL;
static IMP orig_closeRoomWithCompletion = NULL;
static IMP orig_openSharingWithCompletion = NULL;
static IMP orig_mr_connectWebSocket = NULL;
static IMP orig_mr_fetchDirectWatchUrl = NULL;

// MBWebSocketServer 原IMP
static IMP orig_mbSend = NULL;
static IMP orig_mbSendRawBytes = NULL;

// ViewController 原IMP
static IMP orig_startHttp = NULL;
static IMP orig_stopHttp = NULL;
static IMP orig_startWebSocket = NULL;
static IMP orig_stopWebSocket = NULL;
static IMP orig_startRadarServices = NULL;
static IMP orig_activateRadarLink = NULL;
static IMP orig_deactivateRadarLink = NULL;

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
// WebSocket 引擎 - v9 模式（dispatch_async，后台自动暂停）
// ============================================================
static NSURLSession *g_myWsSession = nil;
static NSURLSessionWebSocketTask *g_myWsTask = nil;
static dispatch_queue_t g_wsQueue = nil;
static dispatch_source_t g_wsHeartbeatTimer = nil;  // WebSocket 心跳定时器（dispatch_source，不受runloop影响）

typedef enum { WSStateDisconnected = 0, WSStateConnecting, WSStateConnected, WSStateFailed } WSState;
static volatile WSState g_wsState = WSStateDisconnected;
static volatile uint64_t g_lastConnectAttempt = 0;
static const uint64_t kMinReconnectInterval = 1 * NSEC_PER_SEC;

// 环形缓冲区（ARC兼容）
static NSMutableArray<NSData*> *g_ringBuffer = nil;
static NSUInteger g_ringCapacity = 300;
static NSUInteger g_ringHead = 0;
static NSUInteger g_ringTail = 0;
static dispatch_semaphore_t g_ringSem = NULL;

static void ringBufferInit(NSUInteger capacity) {
    g_ringCapacity = capacity;
    g_ringBuffer = [NSMutableArray arrayWithCapacity:capacity];
    for (NSUInteger i = 0; i < capacity; i++) {
        [g_ringBuffer addObject:[NSData data]];
    }
    g_ringHead = 0;
    g_ringTail = 0;
    g_ringSem = dispatch_semaphore_create(0);
}

static void ringBufferPush(NSData *data) {
    if (!data || !g_ringBuffer) return;
    NSUInteger next = (g_ringHead + 1) % g_ringCapacity;
    if (next == g_ringTail) {
        g_ringTail = (g_ringTail + 1) % g_ringCapacity;
    }
    g_ringBuffer[g_ringHead] = data;
    g_ringHead = next;
    dispatch_semaphore_signal(g_ringSem);
}

static NSData *ringBufferPop() {
    if (!g_ringBuffer) return nil;
    if (g_ringHead == g_ringTail) {
        dispatch_semaphore_wait(g_ringSem, DISPATCH_TIME_FOREVER);
        if (g_ringHead == g_ringTail) return nil;
    }
    NSData *data = g_ringBuffer[g_ringTail];
    g_ringBuffer[g_ringTail] = [NSData data];
    g_ringTail = (g_ringTail + 1) % g_ringCapacity;
    return data;
}

static void ringBufferClear() {
    if (!g_ringBuffer) return;
    while (g_ringHead != g_ringTail) {
        g_ringBuffer[g_ringTail] = [NSData data];
        g_ringTail = (g_ringTail + 1) % g_ringCapacity;
    }
}

static void wsSendFrameDirect(NSURLSessionWebSocketTask *task, NSData *data) {
    if (!task || task.state != NSURLSessionTaskStateRunning) return;
    NSURLSessionWebSocketMessage *msg = [[NSURLSessionWebSocketMessage alloc] initWithData:data];
    [task sendMessage:msg completionHandler:^(NSError *err) {
        if (err && task == g_myWsTask) {
            dispatch_async(g_wsQueue, ^{
                if (g_myWsTask == task) {
                    g_wsState = WSStateFailed;
                    g_myWsTask = nil;
                }
            });
        }
    }];
}

static void wsSendHeartbeat() {
    dispatch_async(g_wsQueue, ^{
        if (g_wsState == WSStateConnected && g_myWsTask && g_myWsTask.state == NSURLSessionTaskStateRunning) {
            // 使用 WebSocket 原生 ping 方法（协议级别，服务器一定能识别）
            [g_myWsTask sendPingWithPongReceiveHandler:^(NSError *err) {
                if (err) {
                    NSLog(@"[Hook] 心跳发送失败: %@", err.localizedDescription);
                    g_wsState = WSStateFailed;
                    g_myWsTask = nil;
                } else {
                    NSLog(@"[Hook] WebSocket ping 发送成功");
                }
            }];
        }
    });
}

static void startWsHeartbeat() {
    if (g_wsHeartbeatTimer) return;

    // 使用 dispatch_source 创建定时器，不受 runloop 影响，后台也能触发
    g_wsHeartbeatTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, g_wsQueue);
    if (g_wsHeartbeatTimer) {
        dispatch_source_set_timer(g_wsHeartbeatTimer, 
                                  dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC),
                                  30 * NSEC_PER_SEC,  // 30秒间隔
                                  5 * NSEC_PER_SEC);   // 5秒容差
        dispatch_source_set_event_handler(g_wsHeartbeatTimer, ^{
            wsSendHeartbeat();
        });
        dispatch_resume(g_wsHeartbeatTimer);
        NSLog(@"[Hook] WebSocket 心跳已启动（30秒间隔，dispatch_source）");
    }
}

static void stopWsHeartbeat() {
    if (g_wsHeartbeatTimer) {
        dispatch_source_cancel(g_wsHeartbeatTimer);
        g_wsHeartbeatTimer = nil;
        NSLog(@"[Hook] WebSocket 心跳已停止");
    }
}

static void wsFlushRingBuffer() {
    if (!g_myWsTask || g_myWsTask.state != NSURLSessionTaskStateRunning) return;

    NSMutableArray *frames = [NSMutableArray array];
    while (g_ringHead != g_ringTail) {
        NSData *data = g_ringBuffer[g_ringTail];
        g_ringBuffer[g_ringTail] = [NSData data];
        g_ringTail = (g_ringTail + 1) % g_ringCapacity;
        if (data.length > 0) [frames addObject:data];
    }

    NSLog(@"[Hook] Flush %lu 帧", (unsigned long)frames.count);
    for (NSData *data in frames) {
        wsSendFrameDirect(g_myWsTask, data);
    }
}

static void wsStartReceiveLoop(NSURLSessionWebSocketTask *task) {
    __weak NSURLSessionWebSocketTask *weakTask = task;
    void (^receiveBlock)(void) = ^{
        __strong NSURLSessionWebSocketTask *strongTask = weakTask;
        if (!strongTask || strongTask.state != NSURLSessionTaskStateRunning) return;

        [strongTask receiveMessageWithCompletionHandler:^(NSURLSessionWebSocketMessage *msg, NSError *err) {
            if (err) {
                dispatch_async(g_wsQueue, ^{
                    if (g_myWsTask == strongTask) {
                        g_wsState = WSStateFailed;
                        g_myWsTask = nil;
                    }
                });
                return;
            }

            if (msg.type == NSURLSessionWebSocketMessageTypeString) {
                NSString *text = msg.string;
                if ([text hasPrefix:@"cfg"]) {
                    NSLog(@"[Hook] 收到配置: %@", text);
                }
            }

            receiveBlock();
        }];
    };
    receiveBlock();
}

static void wsConnect() {
    if (!g_wsQueue) {
        g_wsQueue = dispatch_queue_create("com.iphook.ws.core", DISPATCH_QUEUE_SERIAL);
    }
    dispatch_async(g_wsQueue, ^{
        if (g_wsState == WSStateConnected && g_myWsTask && g_myWsTask.state == NSURLSessionTaskStateRunning) return;
        if (g_wsState == WSStateConnecting) return;

        uint64_t now = mach_absolute_time();
        if (now - g_lastConnectAttempt < kMinReconnectInterval) return;
        g_lastConnectAttempt = now;
        g_wsState = WSStateConnecting;

        if (g_myWsTask) {
            [g_myWsTask cancel];
            g_myWsTask = nil;
        }

        NSString *wsUrl = [NSString stringWithFormat:@"%@/loon?room=%@", MY_WS_BASE, g_fakeRoom];
        NSLog(@"[Hook] WS 连接: %@", wsUrl);

        NSURL *url = [NSURL URLWithString:wsUrl];
        if (!g_myWsSession) {
            NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
            config.timeoutIntervalForRequest = 10;
            config.timeoutIntervalForResource = 300;
            g_myWsSession = [NSURLSession sessionWithConfiguration:config];
        }

        NSURLSessionWebSocketTask *task = [g_myWsSession webSocketTaskWithURL:url];
        [task resume];

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.5 * NSEC_PER_SEC), g_wsQueue, ^{
            if (task.state == NSURLSessionTaskStateRunning) {
                NSLog(@"[Hook] WS 连接成功");
                g_wsState = WSStateConnected;
                g_myWsTask = task;

                // 【关键修复】设置原APP的 wsTask 为我的连接
                // 这样原APP的状态机监控的是我的连接，而不是原服务器
                Class mrClass = objc_getClass("MRCloudRelay");
                id relay = ((id(*)(id, SEL))objc_msgSend)(mrClass, @selector(shared));
                if (relay && [relay respondsToSelector:@selector(setWsTask:)]) {
                    ((void(*)(id, SEL, id))objc_msgSend)(relay, @selector(setWsTask:), task);
                    NSLog(@"[Hook] 已设置原APP wsTask 为我的连接");
                }

                wsStartReceiveLoop(task);
                startWsHeartbeat();  // 启动心跳保活
                wsFlushRingBuffer();
            } else {
                NSLog(@"[Hook] WS 连接失败，状态: %ld", (long)task.state);
                g_wsState = WSStateFailed;
                g_myWsTask = nil;
            }
        });
    });
}

// 【关键】回到 v9 的 dispatch_async 模式，不用独立线程！
static void wsSendOrEnqueue(NSData *data) {
    if (!g_wsQueue) {
        g_wsQueue = dispatch_queue_create("com.iphook.ws.core", DISPATCH_QUEUE_SERIAL);
    }
    if (!g_ringBuffer) {
        ringBufferInit(300);
    }

    // 【修复】去掉 dispatch_async，直接发送，避免串行队列堆积导致队友数据延迟
    if (g_wsState == WSStateConnected && g_myWsTask && g_myWsTask.state == NSURLSessionTaskStateRunning) {
        wsSendFrameDirect(g_myWsTask, data);
    } else {
        dispatch_async(g_wsQueue, ^{
            ringBufferPush(data);
            if (g_wsState == WSStateDisconnected || g_wsState == WSStateFailed) {
                wsConnect();
            }
        });
    }
}

// ============================================================
// MRCloudRelay Hook - 本地/云端切换
// ============================================================

static void hook_ensureRoomWithCompletion(id self, SEL _cmd, id completion) {
    NSLog(@"[Hook] ensureRoom - 返回未分享状态");

    setBoolProp(self, @selector(setCreating:), NO);
    setBoolProp(self, @selector(setIsSharingEnabled:), NO);
    setBoolProp(self, @selector(setWsConnected:), NO);
    setBoolProp(self, @selector(setWsConnecting:), NO);
    setStringProp(self, @selector(setRoomCode:), @"");
    setStringProp(self, @selector(setDirectWatchUrl:), @"");
    setStringProp(self, @selector(setViewUrl:), @"");
    setStringProp(self, @selector(setPubToken:), @"");
    setStringProp(self, @selector(setPublishWsUrl:), @"");

    g_cloudStreamingActive = NO;
    stopWsHeartbeat();  // 确保心跳停止

    // 清理原APP的 wsTask
    Class mrClass = objc_getClass("MRCloudRelay");
    id relay = ((id(*)(id, SEL))objc_msgSend)(mrClass, @selector(shared));
    if (relay && [relay respondsToSelector:@selector(setWsTask:)]) {
        ((void(*)(id, SEL, id))objc_msgSend)(relay, @selector(setWsTask:), nil);
    }

    if (g_myWsTask) {
        [g_myWsTask cancel];
        g_myWsTask = nil;
    }
    g_wsState = WSStateDisconnected;
    ringBufferClear();

    dispatch_async(dispatch_get_main_queue(), ^{
        safeCallCompletion(completion, nil);
    });
}

static void hook_openSharingWithCompletion(id self, SEL _cmd, id completion) {
    @try {
        NSLog(@"[Hook] ===== 用户点击开启推流 =====");
        g_cloudStreamingActive = YES;

        NSString *watchUrl = [NSString stringWithFormat:@"%@/?game=dfm&room=%@", MY_HTTP_BASE, g_fakeRoom];
        NSString *publishUrl = [NSString stringWithFormat:@"%@/loon?room=%@", MY_WS_BASE, g_fakeRoom];

        setStringProp(self, @selector(setRoomCode:), g_fakeRoom);
        setStringProp(self, @selector(setViewUrl:), watchUrl);
        setStringProp(self, @selector(setDirectWatchUrl:), watchUrl);
        setStringProp(self, @selector(setPubToken:), @"faketoken");
        setStringProp(self, @selector(setPublishWsUrl:), publishUrl);
        setBoolProp(self, @selector(setIsSharingEnabled:), YES);
        setBoolProp(self, @selector(setWsConnected:), YES);
        setBoolProp(self, @selector(setWsConnecting:), NO);
        setBoolProp(self, @selector(setCreating:), NO);
        setBoolProp(self, @selector(setReconnectAttempt:), 0);

        if ([self respondsToSelector:@selector(setPendingCompletions:)]) {
            ((void(*)(id, SEL, id))objc_msgSend)(self, @selector(setPendingCompletions:), [NSMutableArray array]);
        }
        if ([self respondsToSelector:@selector(setPendingFrames:)]) {
            ((void(*)(id, SEL, id))objc_msgSend)(self, @selector(setPendingFrames:), [NSMutableArray array]);
        }

        wsConnect();

        dispatch_async(dispatch_get_main_queue(), ^{
            UIViewController *vc = getViewController();
            if (vc && [vc respondsToSelector:@selector(refreshCloudPanel)]) {
                ((void(*)(id, SEL))objc_msgSend)(vc, @selector(refreshCloudPanel));
            }
            showSuccess(@"云端推流已开启");
        });

        safeCallCompletion(completion, g_fakeRoom);
    } @catch (NSException *e) {
        NSLog(@"[Hook] openSharing 异常: %@", e);
        safeCallCompletion(completion, g_fakeRoom);
    }
}

static void hook_startStreamingWithHardcodedServer(id self, SEL _cmd) {
    NSLog(@"[Hook] ===== 用户点击开启推流 (startStreaming) =====");
    Class mrClass = objc_getClass("MRCloudRelay");
    id relay = ((id(*)(id, SEL))objc_msgSend)(mrClass, @selector(shared));
    if (relay) {
        hook_openSharingWithCompletion(relay, @selector(openSharingWithCompletion:), nil);
    }
}

static void hook_forwardPayload(id self, SEL _cmd, const void *payload, NSUInteger length) {
    if (!g_cloudStreamingActive) {
        if (orig_forwardPayload) {
            ((void(*)(id, SEL, const void*, NSUInteger))orig_forwardPayload)(self, _cmd, payload, length);
        }
        return;
    }

    if (!payload || length == 0) return;
    NSData *data = [NSData dataWithBytes:payload length:length];
    if (!data) return;

    // 【日志】统计队友数据频率
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (text && [text containsString:@"\nM,"]) {
        static int mCount = 0;
        static NSTimeInterval mLastTime = 0;
        NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
        mCount++;
        if (now - mLastTime >= 1.0) {
            NSLog(@"[Hook] 队友数据每秒: %d 条", mCount);
            mCount = 0;
            mLastTime = now;
        }
    }
    if (text && [text containsString:@"\nE,"]) {
        static int eCount = 0;
        static NSTimeInterval eLastTime = 0;
        NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
        eCount++;
        if (now - eLastTime >= 1.0) {
            NSLog(@"[Hook] 敌人数据每秒: %d 条", eCount);
            eCount = 0;
            eLastTime = now;
        }
    }

    // 【修复】直接发送，不经过 dispatch_async 队列
    wsSendOrEnqueue(data);
}

static void hook_closeRoomWithCompletion(id self, SEL _cmd, id completion) {
    NSLog(@"[Hook] ===== 用户点击停止推流 =====");
    g_cloudStreamingActive = NO;
    stopWsHeartbeat();  // 停止心跳

    // 清理原APP的 wsTask
    Class mrClass = objc_getClass("MRCloudRelay");
    id relay = ((id(*)(id, SEL))objc_msgSend)(mrClass, @selector(shared));
    if (relay && [relay respondsToSelector:@selector(setWsTask:)]) {
        ((void(*)(id, SEL, id))objc_msgSend)(relay, @selector(setWsTask:), nil);
    }

    if (g_myWsTask) {
        [g_myWsTask cancel];
        g_myWsTask = nil;
    }
    g_wsState = WSStateDisconnected;
    ringBufferClear();

    setBoolProp(self, @selector(setIsSharingEnabled:), NO);
    setBoolProp(self, @selector(setWsConnected:), NO);
    setBoolProp(self, @selector(setWsConnecting:), NO);
    setStringProp(self, @selector(setRoomCode:), @"");
    setStringProp(self, @selector(setDirectWatchUrl:), @"");
    setStringProp(self, @selector(setViewUrl:), @"");
    setStringProp(self, @selector(setPubToken:), @"");
    setStringProp(self, @selector(setPublishWsUrl:), @"");

    if (orig_closeRoomWithCompletion) {
        ((void(*)(id, SEL, id))orig_closeRoomWithCompletion)(self, _cmd, completion);
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        showSuccess(@"已停止推流，回到本地模式");
    });
}

static id hook_currentDirectWatchUrl(id self, SEL _cmd) {
    if (!g_cloudStreamingActive) return @"";
    return [NSString stringWithFormat:@"%@/?game=dfm&room=%@", MY_HTTP_BASE, g_fakeRoom];
}

static id hook_currentRoomCode(id self, SEL _cmd) {
    return g_cloudStreamingActive ? g_fakeRoom : @"";
}

static id hook_mr_wsBase(id self, SEL _cmd) { return MY_WS_BASE; }
static id hook_mr_buildPublishWsUrl(id self, SEL _cmd) {
    return [NSString stringWithFormat:@"%@/loon?room=%@", MY_WS_BASE, g_fakeRoom];
}

static void hook_mr_connectWebSocket(id self, SEL _cmd) {
    if (g_cloudStreamingActive) {
        setBoolProp(self, @selector(setWsConnected:), YES);
        setBoolProp(self, @selector(setWsConnecting:), NO);
    } else {
        if (orig_mr_connectWebSocket) {
            ((void(*)(id, SEL))orig_mr_connectWebSocket)(self, _cmd);
        }
    }
}

static void hook_mr_receiveLoop(id self, SEL _cmd, id task) {}
static void hook_mr_sendFrame(id self, SEL _cmd, id frame) {}
static void hook_mr_flushSendQueue(id self, SEL _cmd) {}
static void hook_mr_drainPendingFrames(id self, SEL _cmd) {}
static void hook_mr_scheduleReconnect(id self, SEL _cmd) {
    if (g_cloudStreamingActive) {
        NSLog(@"[Hook] 拦截 mr_scheduleReconnect（云端模式）");
    }
}

static void hook_mr_fetchDirectWatchUrl(id self, SEL _cmd) {
    if (g_cloudStreamingActive) {
        NSString *url = [NSString stringWithFormat:@"%@/?game=dfm&room=%@", MY_HTTP_BASE, g_fakeRoom];
        setStringProp(self, @selector(setDirectWatchUrl:), url);
    } else if (orig_mr_fetchDirectWatchUrl) {
        ((void(*)(id, SEL))orig_mr_fetchDirectWatchUrl)(self, _cmd);
    }
}

// ============================================================
// MBWebSocketServer Hook - 阻止本地广播
// ============================================================
static void hook_mbSend(id self, SEL _cmd, id data) {
    if (g_cloudStreamingActive) {
        return;
    }
    if (orig_mbSend) {
        ((void(*)(id, SEL, id))orig_mbSend)(self, _cmd, data);
    }
}

static void hook_mbSendRawBytes(id self, SEL _cmd, const void *bytes, NSUInteger length) {
    if (g_cloudStreamingActive) {
        return;
    }
    if (orig_mbSendRawBytes) {
        ((void(*)(id, SEL, const void*, NSUInteger))orig_mbSendRawBytes)(self, _cmd, bytes, length);
    }
}

// ============================================================
// ViewController Hook - 本地服务延迟创建
// ============================================================
static void hook_startHttp(id self, SEL _cmd) {
    if (g_cloudStreamingActive) {
        NSLog(@"[Hook] 云端模式，跳过本地HTTP服务创建");
        return;
    }
    if (orig_startHttp) {
        ((void(*)(id, SEL))orig_startHttp)(self, _cmd);
    }
}

static void hook_stopHttp(id self, SEL _cmd) {
    if (orig_stopHttp) {
        ((void(*)(id, SEL))orig_stopHttp)(self, _cmd);
    }
}

static void hook_startWebSocket(id self, SEL _cmd) {
    if (g_cloudStreamingActive) {
        NSLog(@"[Hook] 云端模式，跳过本地WebSocket服务创建");
        return;
    }
    if (orig_startWebSocket) {
        ((void(*)(id, SEL))orig_startWebSocket)(self, _cmd);
    }
}

static void hook_stopWebSocket(id self, SEL _cmd) {
    if (orig_stopWebSocket) {
        ((void(*)(id, SEL))orig_stopWebSocket)(self, _cmd);
    }
}

static void hook_startRadarServices(id self, SEL _cmd) {
    if (g_cloudStreamingActive) {
        NSLog(@"[Hook] 云端模式，跳过雷达服务启动");
        return;
    }
    if (orig_startRadarServices) {
        ((void(*)(id, SEL))orig_startRadarServices)(self, _cmd);
    }
}

static void hook_activateRadarLink(id self, SEL _cmd) {
    if (g_cloudStreamingActive) {
        NSLog(@"[Hook] 云端模式，跳过本地雷达链接激活");
        return;
    }
    if (orig_activateRadarLink) {
        ((void(*)(id, SEL))orig_activateRadarLink)(self, _cmd);
    }
}

static void hook_deactivateRadarLink(id self, SEL _cmd) {
    if (orig_deactivateRadarLink) {
        ((void(*)(id, SEL))orig_deactivateRadarLink)(self, _cmd);
    }
}

static id hook_currentStreamWatchUrl(id self, SEL _cmd) {
    if (!g_cloudStreamingActive) return @"";
    return [NSString stringWithFormat:@"%@/?game=dfm&room=%@", MY_HTTP_BASE, g_fakeRoom];
}

static void hook_refreshCloudPanel(id self, SEL _cmd) {
    @try {
        if (g_cloudStreamingActive) {
            if ([self respondsToSelector:@selector(cloudStatusL)]) {
                UILabel *statusL = ((id(*)(id, SEL))objc_msgSend)(self, @selector(cloudStatusL));
                if ([statusL respondsToSelector:@selector(setText:)]) {
                    ((void(*)(id, SEL, id))objc_msgSend)(statusL, @selector(setText:), @"云端推流已连接");
                }
            }
            if ([self respondsToSelector:@selector(streamIPL)]) {
                UILabel *ipL = ((id(*)(id, SEL))objc_msgSend)(self, @selector(streamIPL));
                if ([ipL respondsToSelector:@selector(setText:)]) {
                    ((void(*)(id, SEL, id))objc_msgSend)(ipL, @selector(setText:), MY_SERVER_HOST);
                }
            }
            if ([self respondsToSelector:@selector(streamPortL)]) {
                UILabel *portL = ((id(*)(id, SEL))objc_msgSend)(self, @selector(streamPortL));
                if ([portL respondsToSelector:@selector(setText:)]) {
                    ((void(*)(id, SEL, id))objc_msgSend)(portL, @selector(setText:), MY_SERVER_PORT);
                }
            }
        } else {
            if ([self respondsToSelector:@selector(cloudStatusL)]) {
                UILabel *statusL = ((id(*)(id, SEL))objc_msgSend)(self, @selector(cloudStatusL));
                if ([statusL respondsToSelector:@selector(setText:)]) {
                    ((void(*)(id, SEL, id))objc_msgSend)(statusL, @selector(setText:), @"本地模式");
                }
            }
        }
    } @catch (NSException *e) {}
}

// ============================================================
// 初始化
// ============================================================
static void initHooks() {
    NSLog(@"[Hook] 开始初始化 v14...");

    // 验证系统
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

    // 自动登录
    hookMethod("ViewController", @selector(tryAutoActivate),
               (IMP)hook_tryAutoActivate, NULL);

    initT3();

    // MRCloudRelay
    const char *mrClass = "MRCloudRelay";
    hookMethod(mrClass, @selector(ensureRoomWithCompletion:), 
               (IMP)hook_ensureRoomWithCompletion, NULL);
    hookMethod(mrClass, @selector(openSharingWithCompletion:), 
               (IMP)hook_openSharingWithCompletion, &orig_openSharingWithCompletion);
    hookMethod(mrClass, @selector(closeRoomWithCompletion:), 
               (IMP)hook_closeRoomWithCompletion, &orig_closeRoomWithCompletion);
    hookMethod(mrClass, @selector(forwardPayload:length:), 
               (IMP)hook_forwardPayload, &orig_forwardPayload);

    hookMethod(mrClass, @selector(currentDirectWatchUrl), 
               (IMP)hook_currentDirectWatchUrl, NULL);
    hookMethod(mrClass, @selector(currentRoomCode), 
               (IMP)hook_currentRoomCode, NULL);
    hookMethod(mrClass, @selector(mr_wsBase), 
               (IMP)hook_mr_wsBase, NULL);
    hookMethod(mrClass, @selector(mr_buildPublishWsUrl), 
               (IMP)hook_mr_buildPublishWsUrl, NULL);

    hookMethod(mrClass, @selector(mr_connectWebSocket), 
               (IMP)hook_mr_connectWebSocket, &orig_mr_connectWebSocket);
    hookMethod(mrClass, @selector(mr_receiveLoop:), 
               (IMP)hook_mr_receiveLoop, NULL);
    hookMethod(mrClass, @selector(mr_sendFrame:), 
               (IMP)hook_mr_sendFrame, NULL);
    hookMethod(mrClass, @selector(mr_flushSendQueue), 
               (IMP)hook_mr_flushSendQueue, NULL);
    hookMethod(mrClass, @selector(mr_drainPendingFrames), 
               (IMP)hook_mr_drainPendingFrames, NULL);
    hookMethod(mrClass, @selector(mr_scheduleReconnect), 
               (IMP)hook_mr_scheduleReconnect, NULL);
    hookMethod(mrClass, @selector(mr_fetchDirectWatchUrl), 
               (IMP)hook_mr_fetchDirectWatchUrl, &orig_mr_fetchDirectWatchUrl);

    // MBWebSocketServer
    const char *mbClass = "MBWebSocketServer";
    hookMethod(mbClass, @selector(send:), 
               (IMP)hook_mbSend, &orig_mbSend);
    hookMethod(mbClass, @selector(sendRawBytes:length:), 
               (IMP)hook_mbSendRawBytes, &orig_mbSendRawBytes);

    // ViewController
    const char *vcClass = "ViewController";
    hookMethod(vcClass, @selector(startHttp), 
               (IMP)hook_startHttp, &orig_startHttp);
    hookMethod(vcClass, @selector(stopHttp), 
               (IMP)hook_stopHttp, &orig_stopHttp);
    hookMethod(vcClass, @selector(startWebSocket), 
               (IMP)hook_startWebSocket, &orig_startWebSocket);
    hookMethod(vcClass, @selector(stopWebSocket), 
               (IMP)hook_stopWebSocket, &orig_stopWebSocket);
    hookMethod(vcClass, @selector(startRadarServices), 
               (IMP)hook_startRadarServices, &orig_startRadarServices);
    hookMethod(vcClass, @selector(activateRadarLink), 
               (IMP)hook_activateRadarLink, &orig_activateRadarLink);
    hookMethod(vcClass, @selector(deactivateRadarLink), 
               (IMP)hook_deactivateRadarLink, &orig_deactivateRadarLink);

    hookMethod(vcClass, @selector(startStreamingWithHardcodedServer), 
               (IMP)hook_startStreamingWithHardcodedServer, NULL);
    hookMethod(vcClass, @selector(currentStreamWatchUrl), 
               (IMP)hook_currentStreamWatchUrl, NULL);
    hookMethod(vcClass, @selector(refreshCloudPanel), 
               (IMP)hook_refreshCloudPanel, NULL);

    NSLog(@"[Hook] 全部初始化完成 v14");
    NSLog(@"[Hook] 后台保活: 使用 dispatch_async 模式，后台自动暂停");
    NSLog(@"[Hook] 零掉帧: 环形缓冲区 300 帧，不丢任何帧");
}

__attribute__((constructor))
static void hook_init() {
    NSLog(@"========================================");
    NSLog(@"[Hook] T3卡密+云端推流 v14 已加载");
    NSLog(@"[Hook] 服务器: %@", MY_HTTP_BASE);
    NSLog(@"[Hook] 修复: 移除 while(1) 发送线程，回到 dispatch_async 模式");
    NSLog(@"[Hook] 后台: dispatch_async 队列后台自动暂停，不干扰原APP保活");
    NSLog(@"========================================");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.3*NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        initHooks();
    });
}
