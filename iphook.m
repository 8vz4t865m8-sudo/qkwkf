//
//  iphook.m - T3 验证替换（直接进主界面版）
//
// 思路：
// 1. 直接调用 enterMainConsole 跳过验证界面
// 2. 弹我们自己的 T3 卡密验证窗
// 3. 验证通过后用心跳维持
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
// 📦 全局状态
// ============================================================

static T3Verify *g_t3Verify = nil;
static NSString *g_cardNo = nil;
static NSString *g_statecode = nil;
static BOOL g_t3Verified = NO;
static BOOL g_t3InitSuccess = NO;
static NSTimer *g_heartbeatTimer = nil;
static BOOL g_hasEnteredMain = NO;  // 是否已经进入主界面

// 原始方法保存
static IMP orig_isActivated = NULL;
static IMP orig_tryAutoActivate = NULL;
static IMP orig_heartbeat = NULL;
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

// 获取当前最顶层的 ViewController
static UIViewController *topViewController() {
    UIViewController *topVC = [UIApplication sharedApplication].keyWindow.rootViewController;
    while (topVC.presentedViewController) {
        topVC = topVC.presentedViewController;
    }
    return topVC;
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
    
    // 马上跳一次
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
// 📝 验证卡密（前置声明）
// ============================================================

static void verifyKami(NSString *kami, UIViewController *fromVC);
static void showVerifyAlert();

// ============================================================
// 🎣 Hook: tryAutoActivate - 直接进入主界面
// ============================================================

static void hook_tryAutoActivate(id self, SEL _cmd) {
    NSLog(@"[IPHook] 拦截 tryAutoActivate，直接进入主界面");
    
    // 直接调用 enterMainConsole 进入主界面
    if ([self respondsToSelector:@selector(enterMainConsole)]) {
        ((void(*)(id, SEL))objc_msgSend)(self, @selector(enterMainConsole));
        NSLog(@"[IPHook] ✓ 已调用 enterMainConsole");
        g_hasEnteredMain = YES;
        
        // 延迟 1 秒弹出我们的验证窗
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), 
                       dispatch_get_main_queue(), ^{
            showVerifyAlert();
        });
    } else {
        NSLog(@"[IPHook] ❌ 找不到 enterMainConsole 方法");
        // 找不到的话，还是调用原方法
        if (orig_tryAutoActivate) {
            ((void(*)(id, SEL))orig_tryAutoActivate)(self, _cmd);
        }
    }
}

// ============================================================
// 🎣 Hook: isActivated
// ============================================================

static BOOL hook_isActivated(id self, SEL _cmd) {
    // 返回 YES，保险起见
    return YES;
}

// ============================================================
// 🎣 Hook: 心跳
// ============================================================

static void hook_heartbeatWithCompletion(id self, SEL _cmd, id completion) {
    // 我们自己维护心跳，这里直接返回成功
    if (completion) {
        @try {
            void (*func)(id, BOOL, NSString *) = (__bridge void *)completion;
            if (func) {
                func(completion, YES, nil);
            }
        } @catch (NSException *e) {
            NSLog(@"[IPHook] ⚠️ 心跳 completion 调用失败: %@", e);
        }
    }
}

// ============================================================
// 🎣 Hook: 卡号
// ============================================================

static id hook_cardNo(id self, SEL _cmd) {
    return g_cardNo ?: @"T3-Verified";
}

// ============================================================
// 📝 弹出验证窗口
// ============================================================

static void showVerifyAlert() {
    dispatch_async(dispatch_get_main_queue(), ^{
        
        UIViewController *topVC = topViewController();
        if (!topVC) {
            NSLog(@"[IPHook] ⚠️ 找不到顶层 VC，稍后再试");
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), 
                           dispatch_get_main_queue(), ^{
                showVerifyAlert();
            });
            return;
        }
        
        // 如果已经验证过了，就不弹了
        if (g_t3Verified) {
            NSLog(@"[IPHook] 已验证，不弹窗");
            return;
        }
        
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"卡密验证"
                                                                       message:@"请输入 T3 卡密"
                                                                preferredStyle:UIAlertControllerStyleAlert];
        
        [alert addTextFieldWithConfigurationHandler:^(UITextField * _Nonnull textField) {
            textField.placeholder = @"请输入卡密";
            textField.secureTextEntry = NO;
        }];
        
        UIAlertAction *verifyAction = [UIAlertAction actionWithTitle:@"验证"
                                                               style:UIAlertActionStyleDefault
                                                             handler:^(UIAlertAction * _Nonnull action) {
            NSString *kami = alert.textFields.firstObject.text;
            if (kami.length == 0) {
                showVerifyAlert();
                return;
            }
            verifyKami(kami, topVC);
        }];
        [alert addAction:verifyAction];
        
        UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:@"稍后验证"
                                                               style:UIAlertActionStyleCancel
                                                             handler:^(UIAlertAction * _Nonnull action) {
            NSLog(@"[IPHook] 用户选择稍后验证");
        }];
        [alert addAction:cancelAction];
        
        [topVC presentViewController:alert animated:YES completion:nil];
    });
}

// ============================================================
// 📝 验证卡密实现
// ============================================================

static void verifyKami(NSString *kami, UIViewController *fromVC) {
    NSLog(@"[IPHook] 开始验证卡密: %@", kami);
    
    UIAlertController *loading = [UIAlertController alertControllerWithTitle:@"验证中..."
                                                                      message:nil
                                                               preferredStyle:UIAlertControllerStyleAlert];
    [fromVC presentViewController:loading animated:YES completion:nil];
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        
        if (!g_t3InitSuccess) {
            initT3();
        }
        
        if (!g_t3InitSuccess) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [loading dismissViewControllerAnimated:YES completion:^{
                    UIAlertController *error = [UIAlertController alertControllerWithTitle:@"验证初始化失败"
                                                                                    message:@"T3 SDK 初始化失败，请检查配置"
                                                                             preferredStyle:UIAlertControllerStyleAlert];
                    [error addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
                        showVerifyAlert();
                    }]];
                    [fromVC presentViewController:error animated:YES completion:nil];
                }];
            });
            return;
        }
        
        NSString *imei = [T3Verify getMachineCode];
        T3LoginResult *result = [g_t3Verify loginWithKami:kami imei:imei];
        
        dispatch_async(dispatch_get_main_queue(), ^{
            [loading dismissViewControllerAnimated:YES completion:^{
                
                if (result.success) {
                    NSLog(@"[IPHook] ✓ 验证成功");
                    NSLog(@"[IPHook]   到期时间: %@", result.endTime);
                    
                    g_t3Verified = YES;
                    g_cardNo = kami;
                    g_statecode = result.statecode;
                    
                    startHeartbeat();
                    
                    UIAlertController *success = [UIAlertController alertControllerWithTitle:@"验证成功"
                                                                                     message:[NSString stringWithFormat:@"到期时间：%@", result.endTime]
                                                                              preferredStyle:UIAlertControllerStyleAlert];
                    [success addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
                    [fromVC presentViewController:success animated:YES completion:nil];
                    
                } else {
                    NSLog(@"[IPHook] ✗ 验证失败: %@", result.error);
                    
                    UIAlertController *error = [UIAlertController alertControllerWithTitle:@"验证失败"
                                                                                    message:result.error
                                                                             preferredStyle:UIAlertControllerStyleAlert];
                    [error addAction:[UIAlertAction actionWithTitle:@"重新输入" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
                        showVerifyAlert();
                    }]];
                    [fromVC presentViewController:error animated:YES completion:nil];
                }
            }];
        });
    });
}

// ============================================================
// 🔌 初始化所有 Hook
// ============================================================

static void initHooks() {
    NSLog(@"[IPHook] 开始初始化 Hook...");
    
    // Hook ViewController 的 tryAutoActivate - 这是关键！
    Class vcClass = objc_getClass(VIEW_CONTROLLER_CLASS);
    if (vcClass) {
        SEL trySel = @selector(tryAutoActivate);
        Method m = class_getInstanceMethod(vcClass, trySel);
        if (m) {
            orig_tryAutoActivate = method_getImplementation(m);
            method_setImplementation(m, (IMP)hook_tryAutoActivate);
            NSLog(@"[IPHook] ✓ Hook: tryAutoActivate");
        } else {
            NSLog(@"[IPHook] ✗ 找不到 tryAutoActivate 方法");
        }
    } else {
        NSLog(@"[IPHook] ✗ 找不到 ViewController 类");
    }
    
    // Hook NetworkVerifyClient
    Class oldClass = objc_getClass(OLD_VERIFY_CLASS);
    if (oldClass) {
        NSLog(@"[IPHook] 找到旧验证类: %s", OLD_VERIFY_CLASS);
        
        HOOK_METHOD(OLD_VERIFY_CLASS, @selector(isActivated), 
                    (IMP)hook_isActivated, orig_isActivated);
        
        HOOK_METHOD(OLD_VERIFY_CLASS, @selector(heartbeatWithCompletion:), 
                    (IMP)hook_heartbeatWithCompletion, orig_heartbeat);
        
        HOOK_METHOD(OLD_VERIFY_CLASS, @selector(cardNo), 
                    (IMP)hook_cardNo, orig_cardNo);
    }
    
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
    NSLog(@"[IPHook] 模式：直接进入主界面 + 自定义验证弹窗");
    NSLog(@"========================================");
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), 
                   dispatch_get_main_queue(), ^{
        initHooks();
    });
}
