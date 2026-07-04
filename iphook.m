//
//  MyRadarHook_v9.m - 修复切换逻辑
//  关键修复：
//    1. 不禁用本地服务方法（startHttp/startWebSocket/activateRadarLink）
//    2. 不禁用 mr_requestCloseRoom（让它正常关闭）
//    3. 只改推流目标，不改切换逻辑
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

// 前置声明
static void hookMethod(const char *className, SEL sel, IMP newImp, IMP *oldImp);
static void setStringProp(id self, SEL sel, NSString *val);
static void setBoolProp(id self, SEL sel, BOOL val);
static void safeCallCompletion(id completion, NSString *fakeRoom);

// 验证状态
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
static const NSUInteger kMaxPendingFrames = 180;
static NSUInteger g_droppedFrames = 0;

// 工具函数
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

// 卡密保存
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

// T3
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

// 验证 Hook
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

// 自动登录
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

// WebSocket 引擎
static void initWsInfrastructure() {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        g_wsQueue = dispatch_queue_create("com.iphook.ws.core", DISPATCH_QUEUE_SERIAL);
        g_wsSendQueue = dispatch_queue_create("com.iphook.ws.send", DISPATCH_QUEUE_SERIAL);
        g_pendingQueue = [NSMutableArray arrayWithCapacity:kMaxPendingFrames];
    });
}

static void wsSendFrameInternal(NSURLSessionWebSocketTask *task, NSData *data) {
    if (!task || task.state != NSURLSessionTaskStateRunning) return;
    
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    NSURLSessionWebSocketMessage *msg;
    if (text) {
        msg = [[NSURLSessionWebSocketMessage alloc] initWithString:text];
    } else {
        msg = [[NSURLSessionWebSocketMessage alloc] initWithData:data];
    }
    
    [task sendMessage:msg completionHandler:^(NSError *err) {
        if (err) {
            dispatch_async(g_wsQueue, ^{
                if (g_myWsTask == task) {
                    g_wsState = WSStateFailed;
                    g_myWsTask = nil;
                }
            });
        }
    }];
}

static void wsFlushPendingQueue() {
    if (!g_myWsTask || g_myWsTask.state != NSURLSessionTaskStateRunning) return;
    if (g_pendingQueue.count == 0) return;
    
    NSArray *frames = nil;
    @synchronized(g_pendingQueue) {
        frames = [g_pendingQueue copy];
        [g_pendingQueue removeAllObjects];
        g_droppedFrames = 0;
    }
    
    NSLog(@"[Hook] Flush %lu 帧缓存", (unsigned long)frames.count);
    
    for (NSData *data in frames) {
        wsSendFrameInternal(g_myWsTask, data);
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
    dispatch_async(g_wsQueue, ^{
        if (g_wsState == WSStateConnected && g_myWsTask && g_myWsTask.state == NSURLSessionTaskStateRunning) {
            return;
        }
        if (g_wsState == WSStateConnecting) return;
        
        uint64_t now = mach_absolute_time();
        if (now - g_lastConnectAttempt < kMinReconnectInterval) {
            return;
        }
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

static void wsSendOrEnqueue(NSData *data) {
    initWsInfrastructure();
    
    dispatch_async(g_wsQueue, ^{
        BOOL isConnected = (g_wsState == WSStateConnected && 
                           g_myWsTask && 
                           g_myWsTask.state == NSURLSessionTaskStateRunning);
        
        if (isConnected) {
            dispatch_async(g_wsSendQueue, ^{
                wsSendFrameInternal(g_myWsTask, data);
            });
        } else {
            @synchronized(g_pendingQueue) {
                if (g_pendingQueue.count < kMaxPendingFrames) {
                    [g_pendingQueue addObject:data];
                } else {
                    [g_pendingQueue removeObjectAtIndex:0];
                    [g_pendingQueue addObject:data];
                    g_droppedFrames++;
                    if (g_droppedFrames % 60 == 0) {
                        NSLog(@"[Hook] 缓存溢出，已丢弃 %lu 帧", (unsigned long)g_droppedFrames);
                    }
                }
            }
            
            if (g_wsState == WSStateDisconnected || g_wsState == WSStateFailed) {
                wsConnect();
            }
        }
    });
}

// ============================================================
// MRCloudRelay Hook - 只改推流目标，不改切换逻辑
// ============================================================

// 开始推流：改目标为你的服务器
static void hook_ensureRoomWithCompletion(id self, SEL _cmd, id completion) {
    @try {
        NSString *watchUrl = [NSString stringWithFormat:@"%@/?game=dfm&room=%@", MY_HTTP_BASE, g_fakeRoom];
        NSString *publishUrl = [NSString stringWithFormat:@"%@/loon?room=%@", MY_WS_BASE, g_fakeRoom];

        setStringProp(self, @selector(setRoomCode:), g_fakeRoom);
        setStringProp(self, @selector(setViewUrl:), watchUrl);
        setStringProp(self, @selector(setDirectWatchUrl:), watchUrl);
        setStringProp(self, @selector(setPubToken:), @"faketoken");
        setStringProp(self, @selector(setPublishWsUrl:), publishUrl);
        setBoolProp(self, @selector(setCreating:), NO);
        setBoolProp(self, @selector(setIsSharingEnabled:), YES);
        setBoolProp(self, @selector(setWsConnected:), YES);
        setBoolProp(self, @selector(setWsConnecting:), NO);
        setBoolProp(self, @selector(setReconnectAttempt:), 0);

        if ([self respondsToSelector:@selector(setPendingCompletions:)]) {
            ((void(*)(id, SEL, id))objc_msgSend)(self, @selector(setPendingCompletions:), [NSMutableArray array]);
        }
        if ([self respondsToSelector:@selector(setPendingFrames:)]) {
            ((void(*)(id, SEL, id))objc_msgSend)(self, @selector(setPendingFrames:), [NSMutableArray array]);
        }

        initWsInfrastructure();
        wsConnect();

        NSLog(@"[Hook] 房间伪造成功: %@", g_fakeRoom);

        dispatch_async(dispatch_get_main_queue(), ^{
            safeCallCompletion(completion, g_fakeRoom);
        });
        
    } @catch (NSException *e) {
        NSLog(@"[Hook] ensureRoom 异常: %@", e);
        dispatch_async(dispatch_get_main_queue(), ^{
            safeCallCompletion(completion, g_fakeRoom);
        });
    }
}

// 停止推流：让原逻辑正常执行，只清理我们的 WS
static void hook_closeRoomWithCompletion(id self, SEL _cmd, id completion) {
    NSLog(@"[Hook] 关闭房间，清理WS连接");
    
    // 清理我们的 WS
    if (g_myWsTask) {
        [g_myWsTask cancel];
        g_myWsTask = nil;
    }
    g_wsState = WSStateDisconnected;
    @synchronized(g_pendingQueue) {
        [g_pendingQueue removeAllObjects];
    }
    
    // 调用原始方法（让原APP正常关闭）
    Class cls = [self class];
    Method m = class_getInstanceMethod(cls, _cmd);
    IMP origImp = method_getImplementation(m);
    ((void(*)(id, SEL, id))origImp)(self, _cmd, completion);
}

// 数据转发
static void hook_forwardPayload(id self, SEL _cmd, const void *payload, NSUInteger length) {
    @try {
        if (!payload || length == 0) return;
        NSData *data = [NSData dataWithBytes:payload length:length];
        if (!data) return;
        wsSendOrEnqueue(data);
    } @catch (NSException *e) {
        NSLog(@"[Hook] forwardPayload 异常: %@", e);
    }
}

// Getter 指向你的服务器
static id hook_currentDirectWatchUrl(id self, SEL _cmd) {
    return [NSString stringWithFormat:@"%@/?game=dfm&room=%@", MY_HTTP_BASE, g_fakeRoom];
}
static id hook_currentRoomCode(id self, SEL _cmd) { return g_fakeRoom; }
static id hook_mr_wsBase(id self, SEL _cmd) { return MY_WS_BASE; }
static id hook_mr_buildPublishWsUrl(id self, SEL _cmd) {
    return [NSString stringWithFormat:@"%@/loon?room=%@", MY_WS_BASE, g_fakeRoom];
}

// 禁用内部状态机（但不禁用关闭相关）
static void hook_mr_connectWebSocket(id self, SEL _cmd) {
    NSLog(@"[Hook] 拦截 mr_connectWebSocket");
    setBoolProp(self, @selector(setWsConnected:), YES);
    setBoolProp(self, @selector(setWsConnecting:), NO);
}
static void hook_mr_receiveLoop(id self, SEL _cmd, id task) { NSLog(@"[Hook] 拦截 mr_receiveLoop"); }
static void hook_mr_sendFrame(id self, SEL _cmd, id frame) { NSLog(@"[Hook] 拦截 mr_sendFrame"); }
static void hook_mr_flushSendQueue(id self, SEL _cmd) { NSLog(@"[Hook] 拦截 mr_flushSendQueue"); }
static void hook_mr_drainPendingFrames(id self, SEL _cmd) { NSLog(@"[Hook] 拦截 mr_drainPendingFrames"); }
static void hook_mr_scheduleReconnect(id self, SEL _cmd) { NSLog(@"[Hook] 拦截 mr_scheduleReconnect"); }
static void hook_mr_fetchDirectWatchUrl(id self, SEL _cmd) {
    NSString *url = [NSString stringWithFormat:@"%@/?game=dfm&room=%@", MY_HTTP_BASE, g_fakeRoom];
    setStringProp(self, @selector(setDirectWatchUrl:), url);
}

// 🔴 关键：不禁用 mr_requestCloseRoom，让它正常执行！

// ============================================================
// ViewController Hook - 只改云端相关，不改本地服务
// ============================================================
static id hook_currentStreamWatchUrl(id self, SEL _cmd) {
    return [NSString stringWithFormat:@"%@/?game=dfm&room=%@", MY_HTTP_BASE, g_fakeRoom];
}

static void hook_refreshCloudPanel(id self, SEL _cmd) {
    @try {
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
    } @catch (NSException *e) {}
}

static void hook_startStreamingWithHardcodedServer(id self, SEL _cmd) {
    NSLog(@"[Hook] 拦截 startStreamingWithHardcodedServer");
}

// ============================================================
// 初始化
// ============================================================
static void initHooks() {
    NSLog(@"[Hook] 开始初始化...");

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
    hookMethod(mrClass, @selector(ensureRoomWithCompletion:), (IMP)hook_ensureRoomWithCompletion, NULL);
    hookMethod(mrClass, @selector(closeRoomWithCompletion:), (IMP)hook_closeRoomWithCompletion, NULL); // 🔴 新增
    hookMethod(mrClass, @selector(forwardPayload:length:), (IMP)hook_forwardPayload, NULL);
    hookMethod(mrClass, @selector(currentDirectWatchUrl), (IMP)hook_currentDirectWatchUrl, NULL);
    hookMethod(mrClass, @selector(currentRoomCode), (IMP)hook_currentRoomCode, NULL);
    hookMethod(mrClass, @selector(mr_wsBase), (IMP)hook_mr_wsBase, NULL);
    hookMethod(mrClass, @selector(mr_buildPublishWsUrl), (IMP)hook_mr_buildPublishWsUrl, NULL);
    
    hookMethod(mrClass, @selector(mr_connectWebSocket), (IMP)hook_mr_connectWebSocket, NULL);
    hookMethod(mrClass, @selector(mr_receiveLoop:), (IMP)hook_mr_receiveLoop, NULL);
    hookMethod(mrClass, @selector(mr_sendFrame:), (IMP)hook_mr_sendFrame, NULL);
    hookMethod(mrClass, @selector(mr_flushSendQueue), (IMP)hook_mr_flushSendQueue, NULL);
    hookMethod(mrClass, @selector(mr_drainPendingFrames), (IMP)hook_mr_drainPendingFrames, NULL);
    hookMethod(mrClass, @selector(mr_scheduleReconnect), (IMP)hook_mr_scheduleReconnect, NULL);
    // 🔴 不禁用 mr_requestCloseRoom
    hookMethod(mrClass, @selector(mr_fetchDirectWatchUrl), (IMP)hook_mr_fetchDirectWatchUrl, NULL);

    // ViewController - 不改本地服务方法！
    const char *vcClass = "ViewController";
    hookMethod(vcClass, @selector(startStreamingWithHardcodedServer), (IMP)hook_startStreamingWithHardcodedServer, NULL);
    hookMethod(vcClass, @selector(currentStreamWatchUrl), (IMP)hook_currentStreamWatchUrl, NULL);
    hookMethod(vcClass, @selector(refreshCloudPanel), (IMP)hook_refreshCloudPanel, NULL);
    
    // 🔴 不 hook startHttp/stopHttp/startWebSocket/stopWebSocket/activateRadarLink/deactivateRadarLink

    NSLog(@"[Hook] 全部初始化完成");
}

__attribute__((constructor))
static void hook_init() {
    NSLog(@"========================================");
    NSLog(@"[Hook] T3卡密+云端推流 v9 已加载");
    NSLog(@"[Hook] 服务器: %@", MY_HTTP_BASE);
    NSLog(@"[Hook] 修复: 保留停止推流和恢复本地服务逻辑");
    NSLog(@"========================================");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.3*NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        initHooks();
    });
}
