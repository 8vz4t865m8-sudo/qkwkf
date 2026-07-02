//
//  iphook.m - T3 验证替换 + 推流修复 + 自动保存卡密（修复编译错误版）
//

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
#define SAVED_CARD_KEY     @"com.myradar.savedT3Card"

// ============================================================
// 📦 全局状态
// ============================================================

static T3Verify *g_t3Verify = nil;
static NSString *g_cardNo = nil;
static NSString *g_statecode = nil;
static BOOL g_t3Verified = NO;
static BOOL g_t3InitSuccess = NO;
static NSTimer *g_heartbeatTimer = nil;
static BOOL g_autoLoginTried = NO;

// 保存原始方法（每个Hook对应一个）
static IMP orig_activateWithCardNo = NULL;
static IMP orig_isActivated = NULL;
static IMP orig_cardNo = NULL;
static IMP orig_heartbeat = NULL;

// ============================================================
// 🔧 工具函数
// ============================================================

// 安全的 Hook 宏（修复 NULL 不能赋值的问题）
#define SAFE_HOOK(className, sel, newImp, oldImpPtr) \
    do { \
        Class cls = objc_getClass(className); \
        if (cls) { \
            Method m = class_getInstanceMethod(cls, sel); \
            if (m) { \
                if (oldImpPtr) { \
                    *(oldImpPtr) = method_getImplementation(m); \
                } \
                method_setImplementation(m, (IMP)newImp); \
                NSLog(@"[IPHook] ✓ Hook: %s", sel_getName(sel)); \
            } else { \
                NSLog(@"[IPHook] ✗ 找不到方法: %s", sel_getName(sel)); \
            } \
        } else { \
            NSLog(@"[IPHook] ✗ 找不到类: %s", className); \
        } \
    } while(0)

// ============================================================
// 💾 卡密保存与读取
// ============================================================

static void saveCardToLocal(NSString *card) {
    if (!card || card.length == 0) return;
    
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setObject:card forKey:SAVED_CARD_KEY];
    [defaults synchronize];
    
    NSLog(@"[IPHook] 💾 卡密已保存: %@", card);
}

static NSString *loadCardFromLocal() {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSString *saved = [defaults stringForKey:SAVED_CARD_KEY];
    
    if (saved.length > 0) {
        NSLog(@"[IPHook] 📂 读取到保存的卡密: %@", saved);
        return saved;
    }
    
    NSLog(@"[IPHook] 📂 本地无保存的卡密");
    return nil;
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
        NSLog(@"[IPHook] ✓ T3 初始化成功");
    } else {
        NSLog(@"[IPHook] ✗ T3 初始化失败: %@", error.localizedDescription);
    }
}

// ============================================================
// 💓 心跳
// ============================================================

static void startHeartbeat() {
    if (g_heartbeatTimer) return;
    
    g_heartbeatTimer = [NSTimer scheduledTimerWithTimeInterval:30.0 repeats:YES block:^(NSTimer * _Nonnull timer) {
        if (!g_t3Verified || !g_cardNo || !g_statecode) return;
        
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            T3Result *result = [g_t3Verify heartbeatWithKami:g_cardNo statecode:g_statecode];
            if (result.success) {
                NSLog(@"[IPHook] ✓ 心跳成功");
            } else {
                NSLog(@"[IPHook] ✗ 心跳失败: %@", result.error);
                g_t3Verified = NO;
            }
        });
    }];
}

// ============================================================
// 🎯 执行验证
// ============================================================

static void doVerify(NSString *cardNo, UIViewController *vc) {
    if (!g_t3InitSuccess) {
        initT3();
        if (!g_t3InitSuccess) return;
    }
    
    if (!cardNo || cardNo.length == 0) return;
    
    g_cardNo = cardNo;
    NSString *imei = [T3Verify getMachineCode];
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        
        T3LoginResult *result = [g_t3Verify loginWithKami:cardNo imei:imei];
        
        dispatch_async(dispatch_get_main_queue(), ^{
            
            if (result.success) {
                NSLog(@"[IPHook] ✓ 验证成功");
                
                g_t3Verified = YES;
                g_statecode = result.statecode;
                
                saveCardToLocal(cardNo);
                
                startHeartbeat();
                
                Class hud = NSClassFromString(@"SVProgressHUD");
                if (hud) {
                    @try { [hud performSelector:@selector(showSuccessWithStatus:) withObject:@"验证成功"]; } @catch (id e) {}
                }
                
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), 
                               dispatch_get_main_queue(), ^{
                    if (vc && [vc respondsToSelector:@selector(enterMainConsole)]) {
                        ((void(*)(id, SEL))objc_msgSend)(vc, @selector(enterMainConsole));
                    }
                });
                
            } else {
                NSLog(@"[IPHook] ✗ 验证失败: %@", result.error);
                g_t3Verified = NO;
                g_statecode = nil;
                
                Class hud = NSClassFromString(@"SVProgressHUD");
                if (hud) {
                    @try { [hud performSelector:@selector(showErrorWithStatus:) withObject:result.error ?: @"验证失败"]; } @catch (id e) {}
                }
            }
        });
    });
}

// ============================================================
// 🎣 Hook: 卡密验证
// ============================================================

static void hook_activateWithCardNo(id self, SEL _cmd, 
                                     NSString *cardNo, 
                                     NSString *machineId, 
                                     id completion) {
    
    NSLog(@"[IPHook] 拦截验证请求，卡号: %@", cardNo);
    
    if (!cardNo || cardNo.length == 0 || cardNo.length < 4) {
        NSString *saved = loadCardFromLocal();
        if (saved.length > 0) {
            cardNo = saved;
            NSLog(@"[IPHook] 🔄 使用保存的卡密: %@", cardNo);
        }
    }
    
    if (!cardNo || cardNo.length == 0) {
        NSLog(@"[IPHook] ⚠️  卡密为空，跳过");
        return;
    }
    
    UIViewController *vc = [UIApplication sharedApplication].keyWindow.rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    
    doVerify(cardNo, vc);
}

// ============================================================
// 🎣 Hook: 其他验证方法
// ============================================================

static BOOL hook_isActivated(id self, SEL _cmd) {
    return g_t3Verified;
}

static id hook_cardNo(id self, SEL _cmd) {
    return g_cardNo ?: @"";
}

static void hook_heartbeat(id self, SEL _cmd, id completion) {
    // 用我们自己的心跳定时器，这里什么都不做
}

// ============================================================
// 🎣 自动填充 + 自动登录
// ============================================================

static void autoFillAndLogin(UIViewController *vc) {
    if (g_autoLoginTried) return;
    g_autoLoginTried = YES;
    
    NSString *savedCard = loadCardFromLocal();
    if (!savedCard || savedCard.length == 0) {
        NSLog(@"[IPHook] 无保存的卡密，不自动登录");
        return;
    }
    
    NSLog(@"[IPHook] 🔄 准备自动登录");
    
    // 自动填充输入框
    @try {
        for (UIView *subview in vc.view.subviews) {
            if ([subview isKindOfClass:[UITextField class]]) {
                UITextField *tf = (UITextField *)subview;
                if (tf.text.length == 0) {
                    tf.text = savedCard;
                    NSLog(@"[IPHook] ✏️  已自动填充卡密到输入框");
                    break;
                }
            }
            for (UIView *ssv in subview.subviews) {
                if ([ssv isKindOfClass:[UITextField class]]) {
                    UITextField *tf = (UITextField *)ssv;
                    if (tf.text.length == 0) {
                        tf.text = savedCard;
                        NSLog(@"[IPHook] ✏️  已自动填充卡密到输入框");
                        break;
                    }
                }
            }
        }
    } @catch (NSException *e) {
        NSLog(@"[IPHook] ⚠️  填充输入框失败: %@", e);
    }
    
    // 延迟自动验证
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), 
                   dispatch_get_main_queue(), ^{
        doVerify(savedCard, vc);
    });
}

static void hook_viewDidAppear(id self, SEL _cmd, BOOL animated) {
    // 调用原方法
    struct objc_super superInfo = {
        .receiver = self,
        .super_class = class_getSuperclass([self class])
    };
    ((void(*)(struct objc_super *, SEL, BOOL))objc_msgSendSuper)(&superInfo, _cmd, animated);
    
    NSString *clsName = NSStringFromClass([self class]);
    if ([clsName isEqualToString:@"ViewController"]) {
        NSLog(@"[IPHook] ViewController 显示了");
        autoFillAndLogin(self);
    }
}

// ============================================================
// 🎣 推流模块修复（card_no / machine_id）
// ============================================================

static NSString *fake_cardNo(id self, SEL _cmd) {
    return g_cardNo ?: @"CARD_000000000000";
}

static NSString *fake_machineId(id self, SEL _cmd) {
    return @"MACHINE_000000000000";
}

static void initPushStreamHooks() {
    NSLog(@"[IPHook] 初始化推流模块 Hook...");
    
    NSArray *classNames = @[
        @"MRCloudRelay",
        @"MRStreamer", 
        @"MRPushManager", 
        @"CloudRelay",
        @"MRRoomManager",
        @"MRApiClient"
    ];
    
    for (NSString *clsName in classNames) {
        Class cls = objc_getClass(clsName.UTF8String);
        if (!cls) continue;
        
        NSLog(@"[IPHook] 找到类: %@", clsName);
        
        unsigned int count;
        Method *methods = class_copyMethodList(cls, &count);
        
        for (int i = 0; i < count; i++) {
            SEL sel = method_getName(methods[i]);
            NSString *selName = NSStringFromSelector(sel);
            const char *type = method_getTypeEncoding(methods[i]);
            
            if (([selName containsString:@"cardNo"] || [selName containsString:@"card_no"] || [selName containsString:@"CardNo"])
                && type && strstr(type, "@")) {
                class_addMethod(cls, sel, (IMP)fake_cardNo, "@@:");
                NSLog(@"[IPHook] ✅ Hook 卡号: %@", selName);
            }
            
            if (([selName containsString:@"machineId"] || [selName containsString:@"machine_id"] || [selName containsString:@"MachineId"])
                && type && strstr(type, "@")) {
                class_addMethod(cls, sel, (IMP)fake_machineId, "@@:");
                NSLog(@"[IPHook] ✅ Hook 机器码: %@", selName);
            }
        }
        
        free(methods);
    }
    
    NSLog(@"[IPHook] ✓ 推流模块 Hook 完成");
}

// ============================================================
// 🔌 初始化所有 Hook
// ============================================================

static void initHooks() {
    NSLog(@"[IPHook] 开始初始化 Hook...");
    
    // 1. 卡密验证相关
    Class oldClass = objc_getClass(OLD_VERIFY_CLASS);
    if (oldClass) {
        NSLog(@"[IPHook] 找到验证类: %s", OLD_VERIFY_CLASS);
        
        SAFE_HOOK(OLD_VERIFY_CLASS, @selector(activateWithCardNo:machineId:completion:), 
                  (IMP)hook_activateWithCardNo, &orig_activateWithCardNo);
        
        SAFE_HOOK(OLD_VERIFY_CLASS, @selector(isActivated), 
                  (IMP)hook_isActivated, &orig_isActivated);
        
        SAFE_HOOK(OLD_VERIFY_CLASS, @selector(cardNo), 
                  (IMP)hook_cardNo, &orig_cardNo);
        
        SAFE_HOOK(OLD_VERIFY_CLASS, @selector(heartbeatWithCompletion:), 
                  (IMP)hook_heartbeat, &orig_heartbeat);
    }
    
    // 2. ViewController 自动登录
    Class vcClass = objc_getClass("ViewController");
    if (vcClass) {
        Method m = class_getInstanceMethod(vcClass, @selector(viewDidAppear:));
        if (m) {
            method_setImplementation(m, (IMP)hook_viewDidAppear);
            NSLog(@"[IPHook] ✓ Hook viewDidAppear (自动登录)");
        }
    }
    
    // 3. 初始化 T3
    initT3();
    
    // 4. 推流模块修复
    initPushStreamHooks();
    
    NSLog(@"[IPHook] ✓ 所有 Hook 初始化完成");
}

// ============================================================
// 🚪 入口
// ============================================================

__attribute__((constructor))
static void iphook_init() {
    NSLog(@"========================================");
    NSLog(@"[IPHook] MyRadar T3 验证替换 dylib 已加载");
    NSLog(@"[IPHook] 功能：T3验证 + 自动保存卡密 + 自动登录 + 推流修复");
    NSLog(@"========================================");
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), 
                   dispatch_get_main_queue(), ^{
        initHooks();
    });
}
