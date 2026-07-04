//
//  MyRadarHook_v11.m - 修复自动推流 + 本地/云端切换 + 延迟优化 + 可选停止本地广播
//  核心修复：
//    1. 启动时不自动推流（ensureRoom 返回未分享状态）
//    2. 点击开启推流才切换到云端（openSharing/startStreaming 实现真正开启）
//    3. 点击停止推流切回本地（closeRoom 清理云端 + 调用原方法）
//    4. forwardPayload 条件转发（本地走原方法，云端走你的服务器）
//    5. 修复 closeRoom 递归崩溃（保存原IMP）
//    6. 【新增】云端模式下可选阻止本地广播（避免双推）
//    7. 【新增】延迟优化：绕过 MRCloudRelay 异步队列，直接发送
//    8. 【新增】pendingQueue 只保留最新1帧，发送失败快速丢弃
//    9. 【新增】wsConnect 缩短确认时间到 0.1s
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
// 工具函数（前置声明）
// ============================================================
static void hookMethod(const char *className, SEL sel, IMP newImp, IMP *oldImp);
static void setStringProp(id self, SEL sel, NSString *val);
static void setBoolProp(id self, SEL sel, BOOL val);
static void safeCallCompletion(id completion, NSString *fakeRoom);
static UIViewController *getViewController(void);
static void showSuccess(NSString *status);
static void showError(NSString *status);
static void enterMainConsole(void);
static void saveCardToLocal(NSString *cardNo, NSString *machineId);
static NSString *loadSavedCard(void);
static NSString *loadSavedMachineId(void);
static void initT3(void);
static void startHeartbeat(void);

// WebSocket 引擎（前置声明）
static void initWsInfrastructure(void);
static void wsConnect(void);
static void wsSendOrEnqueueOptimized(NSData *data);

// ============================================================
// 全局状态
// ============================================================
static T3Verify *g_t3Verify = nil;
static NSString *g_cardNo = nil;
static NSString *g_statecode = nil;
static BOOL g_t3Verified = NO;
static BOOL g_t3InitSuccess = NO;
static NSTimer *g_heartbeatTimer = nil;

// 验证 Hook 原IMP
static IMP orig_activateWithCardNo = NULL;
static IMP orig_heartbeat = NULL;
static IMP orig_isActivated = NULL;
static IMP orig_cardNo = NULL;

// ===== 关键：云端推流状态标志 =====
static BOOL g_cloudStreamingActive = NO;

// ===== 可选：云端模式下是否阻止本地广播（避免双推）=====
static BOOL g_blockLocalBroadcast = YES;  // YES=开启云端时停止本地广播，NO=双推

// WebSocket 状态
static NSURLSession *g_myWsSession = nil;
static NSURLSessionWebSocketTask *g_myWsTask = nil;
static dispatch_queue_t g_wsSendQueue = nil;
static dispatch_queue_t g_wsQueue = nil;
static NSString *g_fakeRoom = @"ROOM001";

typedef enum { WSStateDisconnected = 0, WSStateConnecting, WSStateConnected, WSStateFailed } WSState;
static volatile WSState g_wsState = WSStateDisconnected;
static volatile uint64_t g_lastConnectAttempt = 0;
static const uint64_t kMinReconnectInterval = 2 * NSEC_PER_SEC;
static NSMutableArray<NSData*> *g_pendingQueue = nil;
static const NSUInteger kMaxPendingFrames = 1;  // 只保留最新1帧！
static NSUInteger g_droppedFrames = 0;

// 需要保存原IMP的方法
static IMP orig_forwardPayload = NULL;
static IMP orig_closeRoomWithCompletion = NULL;
static IMP orig_openSharingWithCompletion = NULL;
static IMP orig_mr_connectWebSocket = NULL;
static IMP orig_mr_fetchDirectWatchUrl = NULL;
static IMP orig_mbSend = NULL;
static IMP orig_mbSendRawBytes = NULL;

// ============================================================
// 工具函数实现
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
// T3 验证系统（保持不变）
// ============================================================
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

static void startHeartbeat() {
    if (g_heartbeatTimer) return;
    g_heartbeatTimer = [NSTimer scheduledTimerWithTimeInterval:30.0 repeats:YES block:^(NSTimer *timer) {
        if (!g_t3Verified || !g_cardNo || !g_statecode) return;
        dispatch_async(dispatch_get_global_queue(0,0), ^{
            T3Result *r = [g_t3Verify heartbeatWithKami:g_cardNo statecode:g_statecode];
            if (!r.success) { g_t3Verified = NO; NSLog(@"[Hook] 心跳失败"); }
        });
    }];
    dispatch_async(dispatch_get_global_queue(0,0), ^{
        T3Result *r = [g_t3Verify heartbeatWithKami:g_cardNo statecode:g_statecode];
        if (!r.success) g_t3Verified = NO;
    });
}

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
                    startHeartbeat();
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
// WebSocket 引擎（延迟优化版）
// ============================================================
static void initWsInfrastructure() {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        g_wsQueue = dispatch_queue_create("com.iphook.ws.core", DISPATCH_QUEUE_SERIAL);
        g_wsSendQueue = dispatch_queue_create("com.iphook.ws.send", DISPATCH_QUEUE_SERIAL);
        g_pendingQueue = [NSMutableArray arrayWithCapacity:kMaxPendingFrames];
    });
}

// 直接发送，无队列、无缓存、零拷贝
static void wsSendFrameDirect(NSURLSessionWebSocketTask *task, NSData *data) {
    if (!task || task.state != NSURLSessionTaskStateRunning) return;

    // 直接用NSData发送，避免NSString转换开销
    NSURLSessionWebSocketMessage *msg = [[NSURLSessionWebSocketMessage alloc] initWithData:data];

    [task sendMessage:msg completionHandler:^(NSError *err) {
        if (err && task == g_myWsTask) {
            // 只在出错时标记，成功时零开销
            dispatch_async(g_wsQueue, ^{
                if (g_myWsTask == task) {
                    NSLog(@"[Hook] WS发送失败: %@", err.localizedDescription);
                    g_wsState = WSStateFailed;
                    g_myWsTask = nil;
                }
            });
        }
    }];
}

static void wsFlushPendingQueue() {
    if (!g_myWsTask || g_myWsTask.state != NSURLSessionTaskStateRunning) return;

    NSData *latestFrame = nil;
    @synchronized(g_pendingQueue) {
        if (g_pendingQueue.count > 0) {
            latestFrame = [g_pendingQueue lastObject]; // 只取最新1帧
            [g_pendingQueue removeAllObjects];
            g_droppedFrames = 0;
        }
    }

    if (latestFrame) {
        wsSendFrameDirect(g_myWsTask, latestFrame);
    }
}

static void wsConnect() {
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

        // 缩短到0.1秒确认
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.1 * NSEC_PER_SEC), g_wsQueue, ^{
            if (task.state == NSURLSessionTaskStateRunning) {
                NSLog(@"[Hook] WS 连接成功");
                g_wsState = WSStateConnected;
                g_myWsTask = task;
                wsStartReceiveLoop(task);
                wsFlushPendingQueue();
            } else {
                NSLog(@"[Hook] WS 连接失败，状态: %ld", (long)task.state);
                g_wsState = WSStateFailed;
                g_myWsTask = nil;
            }
        });
    });
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

// 优化版：已连接直接发，未连接只留最新1帧
static void wsSendOrEnqueueOptimized(NSData *data) {
    initWsInfrastructure();

    // 快速路径：已连接直接发，不进任何队列
    if (g_wsState == WSStateConnected && g_myWsTask && g_myWsTask.state == NSURLSessionTaskStateRunning) {
        wsSendFrameDirect(g_myWsTask, data);
        return;
    }

    // 慢速路径：未连接，只保留最新1帧（丢弃旧帧，避免延迟累积）
    dispatch_async(g_wsQueue, ^{
        // 双重检查（进队列后可能刚连上）
        if (g_wsState == WSStateConnected && g_myWsTask && g_myWsTask.state == NSURLSessionTaskStateRunning) {
            wsSendFrameDirect(g_myWsTask, data);
            return;
        }

        @synchronized(g_pendingQueue) {
            [g_pendingQueue removeAllObjects]; // 丢弃旧帧
            [g_pendingQueue addObject:data];    // 只留最新
        }

        if (g_wsState == WSStateDisconnected || g_wsState == WSStateFailed) {
            wsConnect();
        }
    });
}

// ============================================================
// MRCloudRelay Hook - 本地/云端切换逻辑
// ============================================================

// 1. ensureRoomWithCompletion - 启动时不自动推流！
static void hook_ensureRoomWithCompletion(id self, SEL _cmd, id completion) {
    NSLog(@"[Hook] ensureRoom - 返回未分享状态（不自动推流）");

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
    if (g_myWsTask) {
        [g_myWsTask cancel];
        g_myWsTask = nil;
    }
    g_wsState = WSStateDisconnected;
    @synchronized(g_pendingQueue) {
        [g_pendingQueue removeAllObjects];
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        safeCallCompletion(completion, nil);
    });
}

// 2. openSharingWithCompletion - 用户点击"开启推流"（主要入口）
static void hook_openSharingWithCompletion(id self, SEL _cmd, id completion) {
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

    // 立即连接，不要等第一帧数据
    initWsInfrastructure();
    wsConnect();

    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *vc = getViewController();
        if (vc && [vc respondsToSelector:@selector(refreshCloudPanel)]) {
            ((void(*)(id, SEL))objc_msgSend)(vc, @selector(refreshCloudPanel));
        }
        showSuccess(@"云端推流已开启");
    });

    safeCallCompletion(completion, g_fakeRoom);
}

// 3. startStreamingWithHardcodedServer - 用户点击"开启推流"（备用入口）
static void hook_startStreamingWithHardcodedServer(id self, SEL _cmd) {
    NSLog(@"[Hook] ===== 用户点击开启推流 (startStreaming) =====");
    Class mrClass = objc_getClass("MRCloudRelay");
    id relay = ((id(*)(id, SEL))objc_msgSend)(mrClass, @selector(shared));
    if (relay) {
        hook_openSharingWithCompletion(relay, @selector(openSharingWithCompletion:), nil);
    }
}

// 4. forwardPayload - 条件转发：云端模式直接发，本地模式走原方法
static void hook_forwardPayload(id self, SEL _cmd, const void *payload, NSUInteger length) {
    if (!g_cloudStreamingActive) {
        // 本地模式：调用原方法
        if (orig_forwardPayload) {
            ((void(*)(id, SEL, const void*, NSUInteger))orig_forwardPayload)(self, _cmd, payload, length);
        }
        return;
    }

    // 云端模式：直接转发，绕过 MRCloudRelay 异步队列，零延迟
    if (!payload || length == 0) return;
    NSData *data = [NSData dataWithBytes:payload length:length];
    if (!data) return;

    wsSendOrEnqueueOptimized(data);
}

// 5. closeRoomWithCompletion - 用户点击"停止推流"
static void hook_closeRoomWithCompletion(id self, SEL _cmd, id completion) {
    NSLog(@"[Hook] ===== 用户点击停止推流 =====");
    g_cloudStreamingActive = NO;

    // 清理我们的WebSocket连接
    if (g_myWsTask) {
        [g_myWsTask cancel];
        g_myWsTask = nil;
    }
    g_wsState = WSStateDisconnected;
    @synchronized(g_pendingQueue) {
        [g_pendingQueue removeAllObjects];
    }

    // 重置MRCloudRelay云端状态
    setBoolProp(self, @selector(setIsSharingEnabled:), NO);
    setBoolProp(self, @selector(setWsConnected:), NO);
    setBoolProp(self, @selector(setWsConnecting:), NO);
    setStringProp(self, @selector(setRoomCode:), @"");
    setStringProp(self, @selector(setDirectWatchUrl:), @"");
    setStringProp(self, @selector(setViewUrl:), @"");
    setStringProp(self, @selector(setPubToken:), @"");
    setStringProp(self, @selector(setPublishWsUrl:), @"");

    // 调用原方法（让原APP正常清理本地状态）
    if (orig_closeRoomWithCompletion) {
        ((void(*)(id, SEL, id))orig_closeRoomWithCompletion)(self, _cmd, completion);
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        showSuccess(@"已停止推流，回到本地模式");
    });
}

// 6. Getter 指向你的服务器（只在云端模式时返回你的地址）
static id hook_currentDirectWatchUrl(id self, SEL _cmd) {
    if (!g_cloudStreamingActive) {
        // 本地模式：返回空，让原方法处理
        return @"";
    }
    return [NSString stringWithFormat:@"%@/?game=dfm&room=%@", MY_HTTP_BASE, g_fakeRoom];
}

static id hook_currentRoomCode(id self, SEL _cmd) {
    return g_cloudStreamingActive ? g_fakeRoom : @"";
}

static id hook_mr_wsBase(id self, SEL _cmd) {
    return MY_WS_BASE;
}

static id hook_mr_buildPublishWsUrl(id self, SEL _cmd) {
    return [NSString stringWithFormat:@"%@/loon?room=%@", MY_WS_BASE, g_fakeRoom];
}

// 7. 拦截内部状态机
static void hook_mr_connectWebSocket(id self, SEL _cmd) {
    if (g_cloudStreamingActive) {
        NSLog(@"[Hook] 拦截 mr_connectWebSocket（云端模式）");
        setBoolProp(self, @selector(setWsConnected:), YES);
        setBoolProp(self, @selector(setWsConnecting:), NO);
    } else {
        if (orig_mr_connectWebSocket) {
            ((void(*)(id, SEL))orig_mr_connectWebSocket)(self, _cmd);
        } else {
            setBoolProp(self, @selector(setWsConnected:), NO);
            setBoolProp(self, @selector(setWsConnecting:), NO);
        }
    }
}

static void hook_mr_receiveLoop(id self, SEL _cmd, id task) {
    if (!g_cloudStreamingActive) {
        // 本地模式不干预
    }
}

static void hook_mr_sendFrame(id self, SEL _cmd, id frame) {
    if (!g_cloudStreamingActive) {
        // 本地模式：不干预原APP发送帧
    }
}

static void hook_mr_flushSendQueue(id self, SEL _cmd) {
    if (!g_cloudStreamingActive) {
        // 本地模式：不干预
    }
}

static void hook_mr_drainPendingFrames(id self, SEL _cmd) {
    if (!g_cloudStreamingActive) {
        // 本地模式：不干预
    }
}

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
// MBWebSocketServer Hook - 阻止本地广播（避免双推）
// ============================================================

// 方案A：Hook send: 和 sendRawBytes:length:
// 在云端模式下，这些方法直接返回，不广播数据给本地浏览器
// 保持服务器和连接存活，ShadowTrackerExtra 不会停止

static void hook_mbSend(id self, SEL _cmd, id data) {
    if (g_cloudStreamingActive && g_blockLocalBroadcast) {
        // 云端模式 + 阻止本地广播：直接丢弃，不发送
        // NSLog(@"[Hook] 拦截本地广播 send:");
        return;
    }
    // 本地模式：调用原方法
    if (orig_mbSend) {
        ((void(*)(id, SEL, id))orig_mbSend)(self, _cmd, data);
    }
}

static void hook_mbSendRawBytes(id self, SEL _cmd, const void *bytes, NSUInteger length) {
    if (g_cloudStreamingActive && g_blockLocalBroadcast) {
        // 云端模式 + 阻止本地广播：直接丢弃
        // NSLog(@"[Hook] 拦截本地广播 sendRawBytes:");
        return;
    }
    // 本地模式：调用原方法
    if (orig_mbSendRawBytes) {
        ((void(*)(id, SEL, const void*, NSUInteger))orig_mbSendRawBytes)(self, _cmd, bytes, length);
    }
}

// ============================================================
// ViewController Hook - 只改云端相关，不改本地服务
// ============================================================
static id hook_currentStreamWatchUrl(id self, SEL _cmd) {
    if (!g_cloudStreamingActive) {
        return @"";
    }
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
    NSLog(@"[Hook] 开始初始化 v11...");

    // 验证系统
    hookMethod(OLD_VERIFY_CLASS, @selector(activateWithCardNo:machineId:completion:),
               (IMP)hook_activateWithCardNo, &orig_activateWithCardNo);
    hookMethod(OLD_VERIFY_CLASS, @selector(heartbeatWithCompletion:),
               (IMP)hook_heartbeatWithCompletion, &orig_heartbeat);
    hookMethod(OLD_VERIFY_CLASS, @selector(isActivated),
               (IMP)hook_isActivated, &orig_isActivated);
    hookMethod(OLD_VERIFY_CLASS, @selector(cardNo),
               (IMP)hook_cardNo, &orig_cardNo);

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

    // MBWebSocketServer - 阻止本地广播（避免双推）
    const char *mbClass = "MBWebSocketServer";
    hookMethod(mbClass, @selector(send:), 
               (IMP)hook_mbSend, &orig_mbSend);
    hookMethod(mbClass, @selector(sendRawBytes:length:), 
               (IMP)hook_mbSendRawBytes, &orig_mbSendRawBytes);

    // ViewController
    const char *vcClass = "ViewController";
    hookMethod(vcClass, @selector(startStreamingWithHardcodedServer), 
               (IMP)hook_startStreamingWithHardcodedServer, NULL);
    hookMethod(vcClass, @selector(currentStreamWatchUrl), 
               (IMP)hook_currentStreamWatchUrl, NULL);
    hookMethod(vcClass, @selector(refreshCloudPanel), 
               (IMP)hook_refreshCloudPanel, NULL);

    NSLog(@"[Hook] 全部初始化完成 v11");
    NSLog(@"[Hook] 逻辑：启动=本地模式 | 点击开启=切换云端 | 点击停止=切回本地");
    NSLog(@"[Hook] 延迟优化：绕过MRCloudRelay异步队列，pendingQueue只保留1帧");
    NSLog(@"[Hook] 双推控制：云端模式下阻止本地广播(g_blockLocalBroadcast=%@)", 
          g_blockLocalBroadcast ? @"YES" : @"NO");
}

__attribute__((constructor))
static void hook_init() {
    NSLog(@"========================================");
    NSLog(@"[Hook] T3卡密+云端推流 v11 已加载");
    NSLog(@"[Hook] 服务器: %@", MY_HTTP_BASE);
    NSLog(@"[Hook] 修复: 启动不自动推流，支持本地/云端切换");
    NSLog(@"[Hook] 优化: 零延迟直接发送，只保留最新1帧");
    NSLog(@"[Hook] 双推: 云端模式下阻止本地广播，节省CPU/网络");
    NSLog(@"========================================");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.3*NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        initHooks();
    });
}
