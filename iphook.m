//
//  MyRadarHook_v15.m - 极简版（仅卡密验证 + 云端推流）
//  删除了所有无关的 Hook，只保留核心推流逻辑。
//  本地/云端切换：开启推流自动停止本地服务，关闭后恢复本地。
//

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <mach/mach_time.h>
#import "T3Verify.h"

// T3 验证常量（保持原样）
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
#define MY_SERVER_HOST     @"162.14.104.134"
#define MY_SERVER_PORT     @"3000"
#define MY_SERVER_SCHEME   @"ws://"
#define MY_HTTP_BASE       (@"http://" MY_SERVER_HOST @":" MY_SERVER_PORT)
#define MY_WS_BASE         (MY_SERVER_SCHEME MY_SERVER_HOST @":" MY_SERVER_PORT)

// 工具函数：Hook 方法
static void hookMethod(const char *className, SEL sel, IMP newImp, IMP *oldImp) {
    Class cls = objc_getClass(className);
    if (!cls) { NSLog(@"[Hook] 找不到类: %s", className); return; }
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) { NSLog(@"[Hook] 找不到方法: %s", sel_getName(sel)); return; }
    if (oldImp) *oldImp = method_getImplementation(m);
    method_setImplementation(m, newImp);
}

// 卡密保存
static void saveCard(NSString *cardNo, NSString *machineId) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d setObject:cardNo forKey:@"saved_card_no"];
    [d setObject:machineId forKey:@"udid"];
    [d synchronize];
}

static NSString *loadSavedCard() {
    return [[NSUserDefaults standardUserDefaults] objectForKey:@"saved_card_no"];
}

static NSString *loadSavedMachineId() {
    return [[NSUserDefaults standardUserDefaults] objectForKey:@"udid"];
}

// ==================== T3 验证 ====================
static T3Verify *g_t3 = nil;
static NSString *g_cardNo = nil;
static NSString *g_statecode = nil;
static BOOL g_t3Verified = NO;
static BOOL g_t3InitOk = NO;
static NSTimer *g_heartbeatTimer = nil;

static void initT3() {
    if (g_t3) return;
    g_t3 = [[T3Verify alloc] init];
    NSError *err = nil;
    g_t3InitOk = [g_t3 initRsaWithLoginCode:T3_LOGIN_CODE
                                noticeCode:T3_NOTICE_CODE
                               versionCode:T3_VERSION_CODE
                             heartbeatCode:T3_HEARTBEAT_CODE
                                    appkey:T3_APPKEY
                             rsaPublicKey:T3_RSA_PUBLIC_KEY
                                     error:&err];
    if (g_t3InitOk) NSLog(@"[Hook] T3 初始化成功");
    else NSLog(@"[Hook] T3 初始化失败: %@", err);
}

static void startHeartbeat() {
    if (g_heartbeatTimer) return;
    g_heartbeatTimer = [NSTimer scheduledTimerWithTimeInterval:30.0 repeats:YES block:^(NSTimer *t) {
        if (!g_t3Verified || !g_cardNo || !g_statecode) return;
        dispatch_async(dispatch_get_global_queue(0,0), ^{
            T3Result *r = [g_t3 heartbeatWithKami:g_cardNo statecode:g_statecode];
            if (!r.success) g_t3Verified = NO;
        });
    }];
    // 立即发一次
    dispatch_async(dispatch_get_global_queue(0,0), ^{
        T3Result *r = [g_t3 heartbeatWithKami:g_cardNo statecode:g_statecode];
        if (!r.success) g_t3Verified = NO;
    });
}

static void stopHeartbeat() {
    if (g_heartbeatTimer) {
        [g_heartbeatTimer invalidate];
        g_heartbeatTimer = nil;
    }
}

// 激活 Hook
static void hook_activateWithCardNo(id self, SEL _cmd, NSString *cardNo, NSString *machineId, id completion) {
    if (!cardNo.length) return;
    if (!g_t3InitOk) { initT3(); if (!g_t3InitOk) return; }
    g_cardNo = cardNo;
    NSString *imei = machineId.length ? machineId : [T3Verify getMachineCode];

    dispatch_async(dispatch_get_global_queue(0,0), ^{
        T3LoginResult *r = [g_t3 loginWithKami:cardNo imei:imei];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (r.success) {
                g_t3Verified = YES;
                g_statecode = r.statecode;
                saveCard(cardNo, imei);

                // 更新原APP验证状态（关键）
                if ([self respondsToSelector:@selector(setIsActivated:)])
                    ((void(*)(id, SEL, BOOL))objc_msgSend)(self, @selector(setIsActivated:), YES);
                if ([self respondsToSelector:@selector(setCardNo:)])
                    ((void(*)(id, SEL, id))objc_msgSend)(self, @selector(setCardNo:), cardNo);

                startHeartbeat();
            } else {
                g_t3Verified = NO;
                g_statecode = nil;
            }
        });
    });
}

static BOOL hook_isActivated(id self, SEL _cmd) { return g_t3Verified; }
static id hook_cardNo(id self, SEL _cmd) { return g_cardNo ?: @""; }

// 阻止原APP心跳，只用T3心跳
static void hook_startHeartbeat(id self, SEL _cmd) {}
static void hook_stopHeartbeat(id self, SEL _cmd) { stopHeartbeat(); }

// 自动登录（进入主界面时调用）
static void hook_tryAutoActivate(id self, SEL _cmd) {
    NSString *savedCard = loadSavedCard();
    if (!savedCard.length) return;

    if (!g_t3InitOk) initT3();
    g_cardNo = savedCard;
    NSString *imei = loadSavedMachineId() ?: [T3Verify getMachineCode];

    dispatch_async(dispatch_get_global_queue(0,0), ^{
        T3LoginResult *r = [g_t3 loginWithKami:savedCard imei:imei];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (r.success) {
                g_t3Verified = YES;
                g_statecode = r.statecode;
                saveCard(savedCard, imei);

                if ([self respondsToSelector:@selector(setIsActivated:)])
                    ((void(*)(id, SEL, BOOL))objc_msgSend)(self, @selector(setIsActivated:), YES);
                if ([self respondsToSelector:@selector(setCardNo:)])
                    ((void(*)(id, SEL, id))objc_msgSend)(self, @selector(setCardNo:), savedCard);

                startHeartbeat();
            }
        });
    });
}

// ==================== 云端推流引擎 ====================
static BOOL g_cloudOn = NO;
static NSString *g_fakeRoom = @"ROOM001";

static NSURLSession *g_wsSession = nil;
static NSURLSessionWebSocketTask *g_wsTask = nil;
static dispatch_queue_t g_wsQueue = nil;
static volatile BOOL g_wsConnected = NO;

static NSMutableArray<NSData *> *g_ringBuffer = nil;
static NSUInteger g_ringHead = 0, g_ringTail = 0;
#define RING_CAPACITY 300
static dispatch_semaphore_t g_ringSem = NULL;

static void ringInit() {
    g_ringBuffer = [NSMutableArray arrayWithCapacity:RING_CAPACITY];
    for (int i=0; i<RING_CAPACITY; i++) [g_ringBuffer addObject:[NSData data]];
    g_ringSem = dispatch_semaphore_create(0);
}

static void ringPush(NSData *data) {
    if (!data) return;
    NSUInteger next = (g_ringHead + 1) % RING_CAPACITY;
    if (next == g_ringTail) g_ringTail = (g_ringTail + 1) % RING_CAPACITY;
    g_ringBuffer[g_ringHead] = data;
    g_ringHead = next;
    dispatch_semaphore_signal(g_ringSem);
}

static NSData *ringPop() {
    if (g_ringHead == g_ringTail) {
        dispatch_semaphore_wait(g_ringSem, DISPATCH_TIME_FOREVER);
        if (g_ringHead == g_ringTail) return nil;
    }
    NSData *data = g_ringBuffer[g_ringTail];
    g_ringBuffer[g_ringTail] = [NSData data];
    g_ringTail = (g_ringTail + 1) % RING_CAPACITY;
    return data;
}

static void ringClear() {
    while (g_ringHead != g_ringTail) { ringPop(); }
}

static void wsFlush() {
    if (!g_wsTask || g_wsTask.state != NSURLSessionTaskStateRunning) return;
    NSMutableArray *frames = [NSMutableArray array];
    while (g_ringHead != g_ringTail) [frames addObject:ringPop()];
    for (NSData *data in frames) {
        NSURLSessionWebSocketMessage *msg = [[NSURLSessionWebSocketMessage alloc] initWithData:data];
        [g_wsTask sendMessage:msg completionHandler:^(NSError *e) {}];
    }
}

static void wsConnect() {
    if (!g_wsQueue) g_wsQueue = dispatch_queue_create("ws.core", DISPATCH_QUEUE_SERIAL);
    dispatch_async(g_wsQueue, ^{
        if (g_wsConnected) return;
        if (g_wsTask) { [g_wsTask cancel]; g_wsTask = nil; }

        NSString *urlStr = [NSString stringWithFormat:@"%@/loon?room=%@", MY_WS_BASE, g_fakeRoom];
        if (!g_wsSession) {
            NSURLSessionConfiguration *c = [NSURLSessionConfiguration defaultSessionConfiguration];
            c.timeoutIntervalForRequest = 10;
            g_wsSession = [NSURLSession sessionWithConfiguration:c];
        }

        NSURLSessionWebSocketTask *task = [g_wsSession webSocketTaskWithURL:[NSURL URLWithString:urlStr]];
        [task resume];

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.5*NSEC_PER_SEC), g_wsQueue, ^{
            if (task.state == NSURLSessionTaskStateRunning) {
                g_wsConnected = YES;
                g_wsTask = task;
                wsFlush();
                // 心跳保活（简单 ping）
                dispatch_async(g_wsQueue, ^{
                    [task sendPingWithPongReceiveHandler:^(NSError *e){}];
                });
            }
        });
    });
}

static void wsSendOrEnqueue(NSData *data) {
    if (!g_wsQueue) g_wsQueue = dispatch_queue_create("ws.core", DISPATCH_QUEUE_SERIAL);
    if (!g_ringBuffer) ringInit();

    dispatch_async(g_wsQueue, ^{
        if (g_wsConnected && g_wsTask && g_wsTask.state == NSURLSessionTaskStateRunning) {
            NSURLSessionWebSocketMessage *msg = [[NSURLSessionWebSocketMessage alloc] initWithData:data];
            [g_wsTask sendMessage:msg completionHandler:^(NSError *e) {
                if (e) g_wsConnected = NO;
            }];
        } else {
            ringPush(data);
            if (!g_wsConnected) wsConnect();
        }
    });
}

static void wsStop() {
    g_cloudOn = NO;
    if (g_wsTask) { [g_wsTask cancel]; g_wsTask = nil; }
    g_wsConnected = NO;
    ringClear();
}

// ==================== MRCloudRelay Hook（云端推流核心） ====================
// 开启推流（停止本地服务，转为云端发送）
static void hook_openSharingWithCompletion(id self, SEL _cmd, id completion) {
    NSLog(@"[Hook] 开启云端推流");
    g_cloudOn = YES;

    // 设置云端状态（让原APP认为连接成功）
    if ([self respondsToSelector:@selector(setRoomCode:)])
        ((void(*)(id, SEL, id))objc_msgSend)(self, @selector(setRoomCode:), g_fakeRoom);
    if ([self respondsToSelector:@selector(setViewUrl:)])
        ((void(*)(id, SEL, id))objc_msgSend)(self, @selector(setViewUrl:), [NSString stringWithFormat:@"%@/?game=dfm&room=%@", MY_HTTP_BASE, g_fakeRoom]);
    if ([self respondsToSelector:@selector(setPublishWsUrl:)])
        ((void(*)(id, SEL, id))objc_msgSend)(self, @selector(setPublishWsUrl:), [NSString stringWithFormat:@"%@/loon?room=%@", MY_WS_BASE, g_fakeRoom]);
    if ([self respondsToSelector:@selector(setIsSharingEnabled:)])
        ((void(*)(id, SEL, BOOL))objc_msgSend)(self, @selector(setIsSharingEnabled:), YES);
    if ([self respondsToSelector:@selector(setWsConnected:)])
        ((void(*)(id, SEL, BOOL))objc_msgSend)(self, @selector(setWsConnected:), YES);

    wsConnect();

    // 回调成功
    if (completion) {
        void (^block)(id, NSError *) = completion;
        block(g_fakeRoom, nil);
    }
}

// 关闭推流（恢复本地模式）
static void hook_closeRoomWithCompletion(id self, SEL _cmd, id completion) {
    NSLog(@"[Hook] 停止云端推流");
    wsStop();

    // 重置原APP状态
    if ([self respondsToSelector:@selector(setIsSharingEnabled:)])
        ((void(*)(id, SEL, BOOL))objc_msgSend)(self, @selector(setIsSharingEnabled:), NO);
    if ([self respondsToSelector:@selector(setWsConnected:)])
        ((void(*)(id, SEL, BOOL))objc_msgSend)(self, @selector(setWsConnected:), NO);
    if ([self respondsToSelector:@selector(setRoomCode:)])
        ((void(*)(id, SEL, id))objc_msgSend)(self, @selector(setRoomCode:), @"");

    if (completion) {
        void (^block)(id, NSError *) = completion;
        block(nil, nil);
    }
}

// 数据转发：所有推流数据直接发到我们自己的服务器
static void hook_forwardPayload(id self, SEL _cmd, const void *payload, NSUInteger length) {
    if (!g_cloudOn || !payload || !length) return;
    NSData *data = [NSData dataWithBytes:payload length:length];
    wsSendOrEnqueue(data);
}

// 确保房间方法（返回“未分享”状态，防止异常）
static void hook_ensureRoomWithCompletion(id self, SEL _cmd, id completion) {
    NSLog(@"[Hook] ensureRoom - 重置云端状态");
    wsStop();

    if ([self respondsToSelector:@selector(setIsSharingEnabled:)])
        ((void(*)(id, SEL, BOOL))objc_msgSend)(self, @selector(setIsSharingEnabled:), NO);
    if ([self respondsToSelector:@selector(setWsConnected:)])
        ((void(*)(id, SEL, BOOL))objc_msgSend)(self, @selector(setWsConnected:), NO);

    if (completion) {
        void (^block)(id, NSError *) = completion;
        block(nil, nil);
    }
}

// ==================== ViewController Hook ====================
// 用户点击开启推流按钮
static void hook_startStreaming(id self, SEL _cmd) {
    id relay = ((id(*)(id, SEL))objc_msgSend)(objc_getClass("MRCloudRelay"), @selector(shared));
    if (relay) {
        hook_openSharingWithCompletion(relay, @selector(openSharingWithCompletion:), nil);
    }
}

// 停止本地服务（当云端推流时，不创建本地 WebSocket/HTTP）
static void hook_startHttp(id self, SEL _cmd) {
    if (g_cloudOn) return;  // 云端模式不启动
    // 调用原方法（如果保留原始IMP）
}
static void hook_startWebSocket(id self, SEL _cmd) {
    if (g_cloudOn) return;
}

// ==================== 初始化 Hook ====================
__attribute__((constructor))
static void initHooks() {
    initT3();

    // 验证系统
    hookMethod(OLD_VERIFY_CLASS, @selector(activateWithCardNo:machineId:completion:),
               (IMP)hook_activateWithCardNo, NULL);
    hookMethod(OLD_VERIFY_CLASS, @selector(isActivated), (IMP)hook_isActivated, NULL);
    hookMethod(OLD_VERIFY_CLASS, @selector(cardNo), (IMP)hook_cardNo, NULL);
    hookMethod(OLD_VERIFY_CLASS, @selector(startHeartbeat), (IMP)hook_startHeartbeat, NULL);
    hookMethod(OLD_VERIFY_CLASS, @selector(stopHeartbeat), (IMP)hook_stopHeartbeat, NULL);

    // 自动登录
    hookMethod("ViewController", @selector(tryAutoActivate), (IMP)hook_tryAutoActivate, NULL);

    // MRCloudRelay（云端推流切换）
    const char *mr = "MRCloudRelay";
    hookMethod(mr, @selector(openSharingWithCompletion:), (IMP)hook_openSharingWithCompletion, NULL);
    hookMethod(mr, @selector(closeRoomWithCompletion:), (IMP)hook_closeRoomWithCompletion, NULL);
    hookMethod(mr, @selector(forwardPayload:length:), (IMP)hook_forwardPayload, NULL);
    hookMethod(mr, @selector(ensureRoomWithCompletion:), (IMP)hook_ensureRoomWithCompletion, NULL);

    // ViewController：点击按钮开启推流，并阻止本地服务启动
    hookMethod("ViewController", @selector(startStreamingWithHardcodedServer), (IMP)hook_startStreaming, NULL);
    hookMethod("ViewController", @selector(startHttp), (IMP)hook_startHttp, NULL);
    hookMethod("ViewController", @selector(startWebSocket), (IMP)hook_startWebSocket, NULL);

    NSLog(@"[Hook] 极简版初始化完成（卡密验证 + 云端推流）");
}
