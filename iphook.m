//
//  MyRadarHook_v17.m - 终极精简版
//  只做5件事：T3验证、云端推流、299秒刷新、零掉帧、自动保存
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

#define MY_SERVER_HOST     @"162.14.104.134"
#define MY_SERVER_PORT     @"3000"
#define MY_SERVER_SCHEME   @"ws://"
#define MY_HTTP_BASE       (@"http://" MY_SERVER_HOST @":" MY_SERVER_PORT)
#define MY_WS_BASE         (MY_SERVER_SCHEME MY_SERVER_HOST @":" MY_SERVER_PORT)

// ========== 全局状态（放最前面）==========
static BOOL g_cloud = NO;

// ========== 工具 ==========
static void hookMethod(const char *cn, SEL sel, IMP newImp, IMP *oldImp) {
    Class cls = objc_getClass(cn);
    if (!cls) return;
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;
    if (oldImp) *oldImp = method_getImplementation(m);
    method_setImplementation(m, newImp);
}

static void setString(id self, SEL sel, NSString *v) {
    if ([self respondsToSelector:sel]) ((void(*)(id, SEL, id))objc_msgSend)(self, sel, v);
}

static void setBool(id self, SEL sel, BOOL v) {
    if ([self respondsToSelector:sel]) ((void(*)(id, SEL, BOOL))objc_msgSend)(self, sel, v);
}

static void setInt(id self, SEL sel, NSInteger v) {
    if ([self respondsToSelector:sel]) ((void(*)(id, SEL, NSInteger))objc_msgSend)(self, sel, v);
}

static void setObject(id self, SEL sel, id v) {
    if ([self respondsToSelector:sel]) ((void(*)(id, SEL, id))objc_msgSend)(self, sel, v);
}

// ========== T3验证 ==========
static T3Verify *g_t3 = nil;
static NSString *g_card = nil;
static NSString *g_state = nil;
static BOOL g_ok = NO;

static void initT3() {
    if (g_t3) return;
    g_t3 = [[T3Verify alloc] init];
    g_ok = [g_t3 initRsaWithLoginCode:T3_LOGIN_CODE noticeCode:T3_NOTICE_CODE
                          versionCode:T3_VERSION_CODE heartbeatCode:T3_HEARTBEAT_CODE
                               appkey:T3_APPKEY rsaPublicKey:T3_RSA_PUBLIC_KEY error:nil];
}

static void saveCard(NSString *card, NSString *mid) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d setObject:card forKey:@"saved_card"];
    [d setObject:mid forKey:@"saved_mid"];
    [d setObject:@"dfm" forKey:@"wsr_game_profile"];
    [d synchronize];
}

static NSString *loadCard() { return [[NSUserDefaults standardUserDefaults] objectForKey:@"saved_card"]; }
static NSString *loadMid() { return [[NSUserDefaults standardUserDefaults] objectForKey:@"saved_mid"]; }

// ========== WebSocket ==========
static NSURLSession *g_sess = nil;
static NSURLSessionWebSocketTask *g_task = nil;
static dispatch_queue_t g_q = nil;
static dispatch_source_t g_hb = nil;
static NSMutableArray<NSData*> *g_buf = nil;
static NSUInteger g_h = 0, g_t = 0;
static const NSUInteger MAX_BUF = 300;
static volatile int g_ws = 0;

static void wsConnect();

static void bufInit() {
    g_buf = [NSMutableArray arrayWithCapacity:MAX_BUF];
    for (NSUInteger i = 0; i < MAX_BUF; i++) [g_buf addObject:[NSData data]];
    g_h = g_t = 0;
}

static void bufPush(NSData *d) {
    if (!d || !g_buf) return;
    NSUInteger n = (g_h + 1) % MAX_BUF;
    if (n == g_t) g_t = (g_t + 1) % MAX_BUF;
    g_buf[g_h] = d;
    g_h = n;
}

static void bufFlush() {
    if (!g_task || g_task.state != NSURLSessionTaskStateRunning) return;
    while (g_h != g_t) {
        NSData *d = g_buf[g_t];
        g_buf[g_t] = [NSData data];
        g_t = (g_t + 1) % MAX_BUF;
        if (d.length > 0) {
            NSURLSessionWebSocketMessage *m = [[NSURLSessionWebSocketMessage alloc] initWithData:d];
            [g_task sendMessage:m completionHandler:^(NSError * _Nullable error) {}];
        }
    }
}

static void wsHb() {
    dispatch_async(g_q, ^{
        if (g_ws == 2 && g_task && g_task.state == NSURLSessionTaskStateRunning) {
            NSData *ping = [@"{\"t\":\"hb\"}" dataUsingEncoding:NSUTF8StringEncoding];
            NSURLSessionWebSocketMessage *m = [[NSURLSessionWebSocketMessage alloc] initWithData:ping];
            [g_task sendMessage:m completionHandler:^(NSError * _Nullable error) {}];
            [g_task sendPingWithPongReceiveHandler:^(NSError * _Nullable error) {
                if (error) { g_ws = 3; g_task = nil; wsConnect(); }
            }];
        } else if (g_ws == 0 || g_ws == 3) {
            wsConnect();
        }
    });
}

static void wsRecv(NSURLSessionWebSocketTask *task) {
    [task receiveMessageWithCompletionHandler:^(NSURLSessionWebSocketMessage * _Nullable msg, NSError * _Nullable err) {
        if (err) { if (g_task == task) { g_ws = 3; g_task = nil; wsConnect(); } return; }
        wsRecv(task);
    }];
}

static void wsConnect() {
    if (!g_q) g_q = dispatch_queue_create("ws", DISPATCH_QUEUE_SERIAL);
    dispatch_async(g_q, ^{
        if ((g_ws == 2 && g_task && g_task.state == NSURLSessionTaskStateRunning) || g_ws == 1) return;
        g_ws = 1;
        if (g_task) { [g_task cancel]; g_task = nil; }

        NSString *url = [NSString stringWithFormat:@"%@/loon?room=ROOM001", MY_WS_BASE];
        if (!g_sess) {
            NSURLSessionConfiguration *c = [NSURLSessionConfiguration defaultSessionConfiguration];
            c.timeoutIntervalForRequest = 10;
            c.timeoutIntervalForResource = 0;
            c.shouldUseExtendedBackgroundIdleMode = YES;
            g_sess = [NSURLSession sessionWithConfiguration:c];
        }
        g_task = [g_sess webSocketTaskWithURL:[NSURL URLWithString:url]];
        [g_task resume];

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.5 * NSEC_PER_SEC), g_q, ^{
            if (g_task.state == NSURLSessionTaskStateRunning) {
                g_ws = 2;
                Class cls = objc_getClass(@"MRCloudRelay");
                id r = ((id(*)(id, SEL))objc_msgSend)(cls, @selector(shared));
                if (r) setObject(r, @selector(setWsTask:), g_task);
                wsRecv(g_task);
                if (!g_hb) {
                    g_hb = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, g_q);
                    dispatch_source_set_timer(g_hb, dispatch_time(DISPATCH_TIME_NOW, 30*NSEC_PER_SEC), 30*NSEC_PER_SEC, 5*NSEC_PER_SEC);
                    dispatch_source_set_event_handler(g_hb, ^{ wsHb(); });
                    dispatch_resume(g_hb);
                }
                bufFlush();
            } else {
                g_ws = 3; g_task = nil;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2*NSEC_PER_SEC), g_q, ^{ wsConnect(); });
            }
        });
    });
}

static void wsSend(NSData *d) {
    if (!g_q) g_q = dispatch_queue_create("ws", DISPATCH_QUEUE_SERIAL);
    if (!g_buf) bufInit();
    dispatch_async(g_q, ^{
        if (g_ws == 2 && g_task && g_task.state == NSURLSessionTaskStateRunning) {
            NSURLSessionWebSocketMessage *m = [[NSURLSessionWebSocketMessage alloc] initWithData:d];
            [g_task sendMessage:m completionHandler:^(NSError * _Nullable error) {}];
        } else {
            bufPush(d);
            if (g_ws == 0 || g_ws == 3) wsConnect();
        }
    });
}

static void wsStop() {
    if (g_hb) { dispatch_source_cancel(g_hb); g_hb = nil; }
    if (g_task) { [g_task cancel]; g_task = nil; }
    g_ws = 0;
}

// ========== 299秒刷新 ==========
static dispatch_source_t g_refresh = NULL;

static void refreshTimerStart();

static void doRefresh() {
    if (!g_cloud) return;
    NSLog(@"[Hook] 299秒刷新触发");

    Class cls = objc_getClass(@"MRCloudRelay");
    id relay = ((id(*)(id, SEL))objc_msgSend)(cls, @selector(shared));
    if (!relay) { refreshTimerStart(); return; }

    setBool(relay, @selector(setWsConnected:), YES);
    setBool(relay, @selector(setWsConnecting:), NO);
    setInt(relay, @selector(setReconnectAttempt:), 0);

    if (g_ws != 2) wsConnect();

    refreshTimerStart();
}

static void refreshTimerStart() {
    if (g_refresh) { dispatch_source_cancel(g_refresh); g_refresh = nil; }
    dispatch_queue_t q = dispatch_get_global_queue(0, 0);
    g_refresh = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
    dispatch_source_set_timer(g_refresh, dispatch_time(DISPATCH_TIME_NOW, 299*NSEC_PER_SEC), DISPATCH_TIME_FOREVER, 5*NSEC_PER_SEC);
    dispatch_source_set_event_handler(g_refresh, ^{ doRefresh(); });
    dispatch_resume(g_refresh);
}

static void refreshTimerStop() {
    if (g_refresh) { dispatch_source_cancel(g_refresh); g_refresh = nil; }
}

// ========== Hook ==========

// 1. 验证
static IMP orig_act = NULL;
static void hk_act(id self, SEL _cmd, NSString *card, NSString *mid, id completion) {
    if (!card.length) return;
    initT3();
    g_card = card;
    NSString *imei = mid.length ? mid : [T3Verify getMachineCode];
    dispatch_async(dispatch_get_global_queue(0,0), ^{
        T3LoginResult *r = [g_t3 loginWithKami:card imei:imei];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (r.success) {
                g_ok = YES; g_state = r.statecode;
                saveCard(card, imei);
                setBool(self, @selector(setIsActivated:), YES);
                setString(self, @selector(setCardNo:), card);
                UIViewController *vc = [UIApplication sharedApplication].keyWindow.rootViewController;
                if ([vc isKindOfClass:[UINavigationController class]]) vc = [(UINavigationController*)vc topViewController];
                while (vc.presentedViewController) vc = vc.presentedViewController;
                if ([vc respondsToSelector:@selector(enterMainConsole)]) {
                    ((void(*)(id, SEL))objc_msgSend)(vc, @selector(enterMainConsole));
                }
            } else {
                g_ok = NO;
            }
            if (completion) { void(^b)(NSString*,NSError*) = completion; b(r.success ? card : nil, nil); }
        });
    });
}

static BOOL hk_isAct(id self, SEL _cmd) { return g_ok; }
static id hk_card(id self, SEL _cmd) { return g_card ?: @""; }
static void hk_startHb(id self, SEL _cmd) {}
static void hk_stopHb(id self, SEL _cmd) {}

// 2. 推流
static IMP orig_fp = NULL;
static void hk_fp(id self, SEL _cmd, const void *p, NSUInteger len) {
    if (!g_cloud) { if (orig_fp) ((void(*)(id,SEL,const void*,NSUInteger))orig_fp)(self,_cmd,p,len); return; }
    if (!p || !len) return;
    wsSend([NSData dataWithBytes:p length:len]);
}

static IMP orig_open = NULL;
static void hk_open(id self, SEL _cmd, id completion) {
    g_cloud = YES;
    setString(self, @selector(setRoomCode:), @"ROOM001");
    setString(self, @selector(setViewUrl:), [NSString stringWithFormat:@"%@/?game=dfm&room=ROOM001", MY_HTTP_BASE]);
    setString(self, @selector(setDirectWatchUrl:), [NSString stringWithFormat:@"%@/?game=dfm&room=ROOM001", MY_HTTP_BASE]);
    setString(self, @selector(setPubToken:), @"faketoken");
    setString(self, @selector(setPublishWsUrl:), [NSString stringWithFormat:@"%@/loon?room=ROOM001", MY_WS_BASE]);
    setBool(self, @selector(setIsSharingEnabled:), YES);
    setBool(self, @selector(setWsConnected:), YES);
    setBool(self, @selector(setWsConnecting:), NO);
    setInt(self, @selector(setReconnectAttempt:), 0);
    wsConnect();
    if (completion) { void(^b)(NSString*,NSError*) = completion; b(@"ROOM001", nil); }
    refreshTimerStart();
}

static IMP orig_close = NULL;
static void hk_close(id self, SEL _cmd, id completion) {
    g_cloud = NO;
    wsStop();
    refreshTimerStop();
    setBool(self, @selector(setIsSharingEnabled:), NO);
    setBool(self, @selector(setWsConnected:), NO);
    setBool(self, @selector(setWsConnecting:), NO);
    setString(self, @selector(setRoomCode:), @"");
    setString(self, @selector(setDirectWatchUrl:), @"");
    setString(self, @selector(setViewUrl:), @"");
    setString(self, @selector(setPubToken:), @"");
    setString(self, @selector(setPublishWsUrl:), @"");
    if (orig_close) ((void(*)(id,SEL,id))orig_close)(self,_cmd,completion);
}

static void hk_ensure(id self, SEL _cmd, id completion) {
    g_cloud = NO;
    wsStop();
    refreshTimerStop();
    setBool(self, @selector(setCreating:), NO);
    setBool(self, @selector(setIsSharingEnabled:), NO);
    setBool(self, @selector(setWsConnected:), NO);
    setBool(self, @selector(setWsConnecting:), NO);
    setString(self, @selector(setRoomCode:), @"");
    setString(self, @selector(setDirectWatchUrl:), @"");
    setString(self, @selector(setViewUrl:), @"");
    setString(self, @selector(setPubToken:), @"");
    setString(self, @selector(setPublishWsUrl:), @"");
    if (completion) { void(^b)(NSString*,NSError*) = completion; b(nil, nil); }
}

static id hk_url(id self, SEL _cmd) { return g_cloud ? [NSString stringWithFormat:@"%@/?game=dfm&room=ROOM001", MY_HTTP_BASE] : @""; }
static id hk_room(id self, SEL _cmd) { return g_cloud ? @"ROOM001" : @""; }
static id hk_wsBase(id self, SEL _cmd) { return MY_WS_BASE; }
static id hk_pubUrl(id self, SEL _cmd) { return [NSString stringWithFormat:@"%@/loon?room=ROOM001", MY_WS_BASE]; }

static IMP orig_mrc = NULL;
static void hk_mrc(id self, SEL _cmd) {
    if (g_cloud) { setBool(self, @selector(setWsConnected:), YES); setBool(self, @selector(setWsConnecting:), NO); }
    else if (orig_mrc) ((void(*)(id,SEL))orig_mrc)(self,_cmd);
}

static void hk_mrr(id self, SEL _cmd, id t) {}
static void hk_mrs(id self, SEL _cmd, id f) {}
static void hk_mrf(id self, SEL _cmd) {}
static void hk_mrd(id self, SEL _cmd) {}
static void hk_mrsch(id self, SEL _cmd) { if (g_cloud) wsConnect(); }

static IMP orig_mrfetch = NULL;
static void hk_mrfetch(id self, SEL _cmd) {
    if (g_cloud) setString(self, @selector(setDirectWatchUrl:), [NSString stringWithFormat:@"%@/?game=dfm&room=ROOM001", MY_HTTP_BASE]);
    else if (orig_mrfetch) ((void(*)(id,SEL))orig_mrfetch)(self,_cmd);
}

static id hk_check(id self, SEL _cmd) { return @YES; }
static void hk_setDisc(id self, SEL _cmd, id t) {}
static void hk_setHb(id self, SEL _cmd, id t) {}
static void hk_lost(id self, SEL _cmd) { if (g_cloud) wsConnect(); }
static IMP orig_reqClose = NULL;
static void hk_reqClose(id self, SEL _cmd, id room, id completion) {
    if (g_cloud) { if (completion) { void(^b)(NSString*,NSError*) = completion; b(@"ROOM001", nil); } }
    else if (orig_reqClose) ((void(*)(id,SEL,id,id))orig_reqClose)(self,_cmd,room,completion);
}

// 3. 本地服务
static IMP orig_mbs = NULL, orig_mbr = NULL;
static void hk_mbs(id self, SEL _cmd, id d) { if (!g_cloud && orig_mbs) ((void(*)(id,SEL,id))orig_mbs)(self,_cmd,d); }
static void hk_mbr(id self, SEL _cmd, const void *b, NSUInteger l) { if (!g_cloud && orig_mbr) ((void(*)(id,SEL,const void*,NSUInteger))orig_mbr)(self,_cmd,b,l); }

static IMP orig_sh = NULL, orig_sws = NULL, orig_srs = NULL, orig_arl = NULL;
static void hk_sh(id self, SEL _cmd) { if (!g_cloud && orig_sh) ((void(*)(id,SEL))orig_sh)(self,_cmd); }
static void hk_sws(id self, SEL _cmd) { if (!g_cloud && orig_sws) ((void(*)(id,SEL))orig_sws)(self,_cmd); }
static void hk_srs(id self, SEL _cmd) { if (!g_cloud && orig_srs) ((void(*)(id,SEL))orig_srs)(self,_cmd); }
static void hk_arl(id self, SEL _cmd) { if (!g_cloud && orig_arl) ((void(*)(id,SEL))orig_arl)(self,_cmd); }

static void hk_startStream(id self, SEL _cmd) {
    Class cls = objc_getClass(@"MRCloudRelay");
    id r = ((id(*)(id, SEL))objc_msgSend)(cls, @selector(shared));
    if (r) hk_open(r, @selector(openSharingWithCompletion:), nil);
}

static id hk_curl(id self, SEL _cmd) { return g_cloud ? [NSString stringWithFormat:@"%@/?game=dfm&room=ROOM001", MY_HTTP_BASE] : @""; }

// ========== 初始化 ==========
static void initHooks() {
    hookMethod("NetworkVerifyClient", @selector(activateWithCardNo:machineId:completion:), (IMP)hk_act, &orig_act);
    hookMethod("NetworkVerifyClient", @selector(isActivated), (IMP)hk_isAct, NULL);
    hookMethod("NetworkVerifyClient", @selector(cardNo), (IMP)hk_card, NULL);
    hookMethod("NetworkVerifyClient", @selector(startHeartbeat), (IMP)hk_startHb, NULL);
    hookMethod("NetworkVerifyClient", @selector(stopHeartbeat), (IMP)hk_stopHb, NULL);

    hookMethod("MRCloudRelay", @selector(forwardPayload:length:), (IMP)hk_fp, &orig_fp);
    hookMethod("MRCloudRelay", @selector(openSharingWithCompletion:), (IMP)hk_open, &orig_open);
    hookMethod("MRCloudRelay", @selector(closeRoomWithCompletion:), (IMP)hk_close, &orig_close);
    hookMethod("MRCloudRelay", @selector(ensureRoomWithCompletion:), (IMP)hk_ensure, NULL);
    hookMethod("MRCloudRelay", @selector(currentDirectWatchUrl), (IMP)hk_url, NULL);
    hookMethod("MRCloudRelay", @selector(currentRoomCode), (IMP)hk_room, NULL);
    hookMethod("MRCloudRelay", @selector(mr_wsBase), (IMP)hk_wsBase, NULL);
    hookMethod("MRCloudRelay", @selector(mr_buildPublishWsUrl), (IMP)hk_pubUrl, NULL);
    hookMethod("MRCloudRelay", @selector(mr_connectWebSocket), (IMP)hk_mrc, &orig_mrc);
    hookMethod("MRCloudRelay", @selector(mr_receiveLoop:), (IMP)hk_mrr, NULL);
    hookMethod("MRCloudRelay", @selector(mr_sendFrame:), (IMP)hk_mrs, NULL);
    hookMethod("MRCloudRelay", @selector(mr_flushSendQueue), (IMP)hk_mrf, NULL);
    hookMethod("MRCloudRelay", @selector(mr_drainPendingFrames), (IMP)hk_mrd, NULL);
    hookMethod("MRCloudRelay", @selector(mr_scheduleReconnect), (IMP)hk_mrsch, NULL);
    hookMethod("MRCloudRelay", @selector(mr_fetchDirectWatchUrl), (IMP)hk_mrfetch, &orig_mrfetch);
    hookMethod("MRCloudRelay", @selector(checkServerStatus), (IMP)hk_check, NULL);
    hookMethod("MRCloudRelay", @selector(setDisconnectTimer:), (IMP)hk_setDisc, NULL);
    hookMethod("MRCloudRelay", @selector(setHeartbeatTimer:), (IMP)hk_setHb, NULL);
    hookMethod("MRCloudRelay", @selector(mr_onWebSocketLost), (IMP)hk_lost, NULL);
    hookMethod("MRCloudRelay", @selector(mr_requestCloseRoom:completion:), (IMP)hk_reqClose, &orig_reqClose);

    hookMethod("MBWebSocketServer", @selector(send:), (IMP)hk_mbs, &orig_mbs);
    hookMethod("MBWebSocketServer", @selector(sendRawBytes:length:), (IMP)hk_mbr, &orig_mbr);

    hookMethod("ViewController", @selector(startHttp), (IMP)hk_sh, &orig_sh);
    hookMethod("ViewController", @selector(startWebSocket), (IMP)hk_sws, &orig_sws);
    hookMethod("ViewController", @selector(startRadarServices), (IMP)hk_srs, &orig_srs);
    hookMethod("ViewController", @selector(activateRadarLink), (IMP)hk_arl, &orig_arl);
    hookMethod("ViewController", @selector(startStreamingWithHardcodedServer), (IMP)hk_startStream, NULL);
    hookMethod("ViewController", @selector(currentStreamWatchUrl), (IMP)hk_curl, NULL);

    NSLog(@"[Hook] v17 初始化完成");
}

__attribute__((constructor))
static void hook_init() {
    NSLog(@"[Hook] v17 加载 | %@", MY_HTTP_BASE);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.3*NSEC_PER_SEC), dispatch_get_main_queue(), ^{ initHooks(); });
}
