//
//  iphook.m - T3 验证替换（完全替换版 + 自动保存卡密）
//
// 思路：
// 1. 用户还是在原来的界面输卡密
// 2. Hook 住验证方法，拦截卡密
// 3. 调用 T3 验证接口
// 4. 验证成功 → 直接调用 enterMainConsole 进主界面
// 5. 心跳也走 T3 的
// 6. ✅ 新增：验证成功后自动保存卡密，下次启动自动填充
//

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "T3Verify.h"

// ============================================================
// ⚙️ 配置区域 - 请修改为你自己的 T3 验证参数
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
#define VIEW_CONTROLLER_CLASS "ViewController"

// ============================================================
// 💾 卡密持久化（自动保存）
// ============================================================
#define SAVED_CARD_KEY  @"com.yourapp.savedT3CardNo"

// ============================================================
// 📦 全局状态
// ============================================================

static T3Verify *g_t3Verify = nil;
static NSString *g_cardNo = nil;
static NSString *g_statecode = nil;
static BOOL g_t3Verified = NO;
static BOOL g_t3InitSuccess = NO;
static NSTimer *g_heartbeatTimer = nil;

// 原始方法保存
static IMP orig_activateWithCardNo = NULL;
static IMP orig_heartbeat = NULL;
static IMP orig_isActivated = NULL;
static IMP orig_cardNo = NULL;

// ============================================================
// 🔧 工具函数
// ============================================================

#define HOOK_METHOD(className, sel, newImp, oldImp) \
    do { \
        Class cls = objc_getClass(className); \
        if (cls) { \
            Method m = class_getInstanceMethod(cls, sel); \
            if (m) { \
                oldImp = method_getImplementation(m); \
                method_setImplementation(m, (IMP)newImp); \
                NSLog(@"[IPHook] ✓ Hook: %s", sel_getName(sel)); \
            } else { \
                NSLog(@"[IPHook] ✗ 找不到方法: %s", sel_getName(sel)); \
            } \
        } else { \
            NSLog(@"[IPHook] ✗ 找不到类: %s", className); \
        } \
    } while(0)

// 获取当前的 ViewController
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

// 显示成功提示（用应用自带的 SVProgressHUD）
static void showSuccess(NSString *status) {
    Class hudClass = NSClassFromString(@"SVProgressHUD");
    if (hudClass) {
        @try {
            [hudClass performSelector:@selector(showSuccessWithStatus:) withObject:status];
        } @catch (NSException *e) {
            NSLog(@"[IPHook] ⚠️ showSuccess 失败: %@", e);
        }
    }
}

// 显示错误提示
static void showError(NSString *status) {
    Class hudClass = NSClassFromString(@"SVProgressHUD");
    if (hudClass) {
        @try {
            [hudClass performSelector:@selector(showErrorWithStatus:) withObject:status];
        } @catch (NSException *e) {
            NSLog(@"[IPHook] ⚠️ showError 失败: %@", e);
        }
    }
}

// 进入主界面
static void enterMainConsole() {
    UIViewController *vc = getViewController();
    if (!vc) {
        NSLog(@"[IPHook] ❌ 找不到 ViewController");
        return;
    }
    
    if ([NSStringFromClass([vc class]) isEqualToString:@"ViewController"]) {
        if ([vc respondsToSelector:@selector(enterMainConsole)]) {
            ((void(*)(id, SEL))objc_msgSend)(vc, @selector(enterMainConsole));
            NSLog(@"[IPHook] ✓ 已调用 enterMainConsole");
            return;
        }
    }
    
    for (UIViewController *child in vc.childViewControllers) {
        if ([NSStringFromClass([child class]) isEqualToString:@"ViewController"]) {
            if ([child respondsToSelector:@selector(enterMainConsole)]) {
                ((void(*)(id, SEL))objc_msgSend)(child, @selector(enterMainConsole));
                NSLog(@"[IPHook] ✓ 已调用 enterMainConsole (child)");
                return;
            }
        }
    }
    
    NSLog(@"[IPHook] ❌ 找不到 enterMainConsole 方法");
}

// ============================================================
// 🚀 T3 初始化
// ============================================================

static void initT3() {
    if (g_t3Verify) return;
    
    NSLog(@"[IPHook] 初始化 T3 验证 SDK...");
    
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
        NSLog(@"[IPHook] ✓ T3 验证 SDK 初始化成功");
    } else {
        NSLog(@"[IPHook] ✗ T3 验证 SDK 初始化失败: %@", error.localizedDescription);
    }
}

// ============================================================
// 💓 心跳
// ============================================================

static void startHeartbeat() {
    if (g_heartbeatTimer) return;
    
    NSLog(@"[IPHook] 启动心跳");
    
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
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        T3Result *result = [g_t3Verify heartbeatWithKami:g_cardNo statecode:g_statecode];
        if (result.success) {
            NSLog(@"[IPHook] ✓ 首次心跳成功");
        } else {
            NSLog(@"[IPHook] ✗ 首次心跳失败: %@", result.error);
        }
    });
}

// ============================================================
// 🎣 Hook: 卡密验证（核心！）
// ============================================================

static void hook_activateWithCardNo(id self, SEL _cmd, 
                                     NSString *cardNo, 
                                     NSString *machineId, 
                                     id completion) {
    // ==========================================================
    // 1️⃣ 自动填充保存的卡密（如果传入的卡密为空）
    // ==========================================================
    if (!cardNo || cardNo.length == 0) {
        NSString *saved = [[NSUserDefaults standardUserDefaults] stringForKey:SAVED_CARD_KEY];
        if (saved.length > 0) {
            cardNo = saved;
            NSLog(@"[IPHook] 🔄 自动填充保存的卡密: %@", cardNo);
        } else {
            NSLog(@"[IPHook] ⚠️ 无保存的卡密，等待用户输入");
        }
    }
    
    NSLog(@"[IPHook] 拦截卡密验证: %@", cardNo);
    NSLog(@"[IPHook] machineId: %@", machineId);
    
    // 确保 T3 已初始化
    if (!g_t3InitSuccess) {
        initT3();
        if (!g_t3InitSuccess) {
            NSLog(@"[IPHook] ✗ T3 初始化失败");
            showError(@"验证初始化失败");
            return;
        }
    }
    
    // 保存卡密（内存）
    g_cardNo = cardNo;
    
    // 获取机器码
    NSString *imei = machineId;
    if (!imei || imei.length == 0) {
        imei = [T3Verify getMachineCode];
    }
    
    // 在后台线程执行 T3 验证
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        
        T3LoginResult *result = [g_t3Verify loginWithKami:cardNo imei:imei];
        
        dispatch_async(dispatch_get_main_queue(), ^{
            
            if (result.success) {
                NSLog(@"[IPHook] ✓ T3 验证成功");
                NSLog(@"[IPHook]   到期时间: %@", result.endTime);
                NSLog(@"[IPHook]   时长: %@", result.amount);
                
                // 保存状态
                g_t3Verified = YES;
                g_statecode = result.statecode;
                
                // ==========================================================
                // 2️⃣ 验证成功 → 自动保存卡密到本地
                // ==========================================================
                if (cardNo.length > 0) {
                    [[NSUserDefaults standardUserDefaults] setObject:cardNo forKey:SAVED_CARD_KEY];
                    [[NSUserDefaults standardUserDefaults] synchronize];
                    NSLog(@"[IPHook] 💾 卡密已保存到本地: %@", cardNo);
                }
                
                // 更新原对象的属性（保险起见）
                if ([self respondsToSelector:@selector(setIsActivated:)]) {
                    ((void(*)(id, SEL, BOOL))objc_msgSend)(self, @selector(setIsActivated:), YES);
                }
                if ([self respondsToSelector:@selector(setCardNo:)]) {
                    ((void(*)(id, SEL, id))objc_msgSend)(self, @selector(setCardNo:), cardNo);
                }
                
                // 显示成功提示
                showSuccess(@"验证成功");
                
                // 启动心跳
                startHeartbeat();
                
                // 延迟 0.5 秒进入主界面（等 HUD 显示一下）
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), 
                               dispatch_get_main_queue(), ^{
                    enterMainConsole();
                });
                
            } else {
                NSLog(@"[IPHook] ✗ T3 验证失败: %@", result.error);
                
                g_t3Verified = NO;
                g_statecode = nil;
                
                // 显示错误提示
                showError(result.error ?: @"验证失败");
            }
        });
    });
}

// ============================================================
// 🎣 Hook: 心跳验证
// ============================================================

static void hook_heartbeatWithCompletion(id self, SEL _cmd, id completion) {
    NSLog(@"[IPHook] 拦截心跳验证");
    
    if (!g_t3Verified || !g_cardNo || !g_statecode) {
        NSLog(@"[IPHook] ⚠️ 未验证，跳过心跳");
        return;
    }
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        T3Result *result = [g_t3Verify heartbeatWithKami:g_cardNo statecode:g_statecode];
        
        if (result.success) {
            NSLog(@"[IPHook] ✓ 心跳成功");
        } else {
            NSLog(@"[IPHook] ✗ 心跳失败: %@", result.error);
            g_t3Verified = NO;
        }
    });
}

// ============================================================
// 🎣 Hook: 是否已激活
// ============================================================

static BOOL hook_isActivated(id self, SEL _cmd) {
    return g_t3Verified;
}

// ============================================================
// 🎣 Hook: 获取卡号
// ============================================================

static id hook_cardNo(id self, SEL _cmd) {
    return g_cardNo ?: @"";
}

// ============================================================
// 🔌 初始化所有 Hook
// ============================================================

static void initHooks() {
    NSLog(@"[IPHook] 开始初始化 Hook...");
    
    Class oldClass = objc_getClass(OLD_VERIFY_CLASS);
    if (!oldClass) {
        NSLog(@"[IPHook] ⚠️ 未找到旧验证类: %s", OLD_VERIFY_CLASS);
        return;
    }
    
    NSLog(@"[IPHook] 找到旧验证类: %s", OLD_VERIFY_CLASS);
    
    // Hook 卡密验证（核心！）
    HOOK_METHOD(OLD_VERIFY_CLASS, @selector(activateWithCardNo:machineId:completion:), 
                (IMP)hook_activateWithCardNo, orig_activateWithCardNo);
    
    // Hook 心跳
    HOOK_METHOD(OLD_VERIFY_CLASS, @selector(heartbeatWithCompletion:), 
                (IMP)hook_heartbeatWithCompletion, orig_heartbeat);
    
    // Hook 激活状态
    HOOK_METHOD(OLD_VERIFY_CLASS, @selector(isActivated), 
                (IMP)hook_isActivated, orig_isActivated);
    
    // Hook 卡号
    HOOK_METHOD(OLD_VERIFY_CLASS, @selector(cardNo), 
                (IMP)hook_cardNo, orig_cardNo);
    
    // 初始化 T3 SDK
    initT3();
    
    NSLog(@"[IPHook] ✓ Hook 初始化完成");
}

// ============================================================
// 🚪 入口函数
// ============================================================

__attribute__((constructor))
static void iphook_init() {
    NSLog(@"========================================");
    NSLog(@"[IPHook] T3 验证替换 dylib 已加载");
    NSLog(@"[IPHook] 模式：完全替换验证逻辑 + 自动保存卡密");
    NSLog(@"========================================");
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), 
                   dispatch_get_main_queue(), ^{
        initHooks();
    });
}
