//
//  iphook.m - 旧验证系统 → T3 验证系统 适配层
//
// 功能：Hook NetworkVerifyClient，把验证请求转发到 T3 验证系统
// UI 保持不变，用户还是在原来的界面输卡密
//
// 编译：
// clang -arch arm64 \
//   -isysroot $(xcrun --sdk iphoneos --show-sdk-path) \
//   -framework UIKit \
//   -framework Foundation \
//   -framework Security \
//   -Wno-deprecated-declarations \
//   -miphoneos-version-min=15.0 \
//   -fobjc-arc \
//   -dynamiclib \
//   iphook.m T3Verify.m \
//   -o iphook.dylib
//

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "T3Verify.h"

// ============================================================
// ⚙️ 配置区域 - 请修改为你自己的 T3 验证参数
// ============================================================

// T3 验证配置
#define T3_LOGIN_CODE      @"B9F97729EC64A6C9"    // 单码登录调用码
#define T3_NOTICE_CODE     @"9E37BB60E3AFFCEE"    // 公告调用码
#define T3_VERSION_CODE    @"2A78BD88E7376215"    // 版本号调用码
#define T3_HEARTBEAT_CODE  @"168AA83248396F84"    // 心跳调用码
#define T3_APPKEY          @"15cab0658474ff4a93ebd8ab8337dab0"  // APPKEY
#define T3_RSA_PUBLIC_KEY  @"-----BEGIN PUBLIC KEY-----\n" \
                           "MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQCxj7u3l9DKEyaluMG11BVdfg5z\n" \
                           "/6ieD1iwGzl6txP5G6nAEPxU3BzdEvI4Z20AOAJoGdmflpDq947lgp+tG61G8DeK\n" \
                           "ZLsZWb9t18+L/ThZCCv1xWxb5Llr4mt9yUh5IPHwl5Zy8nxWL64onFJaRIrif+JR\n" \
                           "U0sEt6p3P7lCc3JkPwIDAQAB\n" \
                           "-----END PUBLIC KEY-----"

// 旧验证类名（一般不用改）
#define OLD_VERIFY_CLASS   "NetworkVerifyClient"

// ============================================================
// 📦 全局状态
// ============================================================

static T3Verify *g_t3Verify = nil;
static NSString *g_cardNo = nil;
static NSString *g_statecode = nil;
static BOOL g_isActivated = NO;
static BOOL g_t3InitSuccess = NO;

// 原始方法保存
static IMP orig_activateWithCardNo = NULL;
static IMP orig_heartbeatWithCompletion = NULL;
static IMP orig_startHeartbeat = NULL;
static IMP orig_stopHeartbeat = NULL;
static IMP orig_isActivated = NULL;
static IMP orig_cardNo = NULL;
static IMP orig_logout = NULL;

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

// 安全调用 completion block
static void callCompletion(id completion, BOOL success, NSString *error) {
    if (!completion) return;
    
    // 定义 block 类型
    typedef void (^CompletionBlock)(BOOL success, NSString *error);
    
    @try {
        CompletionBlock block = (__bridge CompletionBlock)completion;
        block(success, error);
    } @catch (NSException *e) {
        NSLog(@"[IPHook] ⚠️ completion 调用失败: %@", e);
    }
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
// 🎣 Hook: 卡密激活/验证
// ============================================================

static void hook_activateWithCardNo_machineId_completion(id self, SEL _cmd, 
                                                          NSString *cardNo, 
                                                          NSString *machineId, 
                                                          id completion) {
    NSLog(@"[IPHook] 拦截卡密验证: %@", cardNo);
    
    // 确保 T3 已初始化
    if (!g_t3InitSuccess) {
        initT3();
        if (!g_t3InitSuccess) {
            NSLog(@"[IPHook] ✗ T3 未初始化，调用原验证方法");
            if (orig_activateWithCardNo) {
                ((void(*)(id, SEL, NSString*, NSString*, id))orig_activateWithCardNo)
                    (self, _cmd, cardNo, machineId, completion);
            }
            return;
        }
    }
    
    // 保存卡密
    g_cardNo = cardNo;
    
    // 获取机器码（如果没传的话）
    NSString *imei = machineId;
    if (!imei || imei.length == 0) {
        imei = [T3Verify getMachineCode];
    }
    
    // 在后台线程执行网络请求
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        
        // 调用 T3 登录验证
        T3LoginResult *result = [g_t3Verify loginWithKami:cardNo imei:imei];
        
        dispatch_async(dispatch_get_main_queue(), ^{
            
            if (result.success) {
                NSLog(@"[IPHook] ✓ T3 验证成功");
                NSLog(@"[IPHook]   到期时间: %@", result.endTime);
                NSLog(@"[IPHook]   时长: %@", result.amount);
                NSLog(@"[IPHook]   剩余: %@秒", result.available);
                
                // 保存状态
                g_isActivated = YES;
                g_statecode = result.statecode;
                
                // 更新原对象的属性
                if ([self respondsToSelector:@selector(setIsActivated:)]) {
                    ((void(*)(id, SEL, BOOL))objc_msgSend)(self, @selector(setIsActivated:), YES);
                }
                if ([self respondsToSelector:@selector(setCardNo:)]) {
                    ((void(*)(id, SEL, id))objc_msgSend)(self, @selector(setCardNo:), cardNo);
                }
                
                // 调用 completion
                callCompletion(completion, YES, nil);
                
            } else {
                NSLog(@"[IPHook] ✗ T3 验证失败: %@", result.error);
                
                g_isActivated = NO;
                g_statecode = nil;
                
                // 更新原对象的属性
                if ([self respondsToSelector:@selector(setIsActivated:)]) {
                    ((void(*)(id, SEL, BOOL))objc_msgSend)(self, @selector(setIsActivated:), NO);
                }
                
                // 调用 completion
                callCompletion(completion, NO, result.error);
            }
        });
    });
}

// ============================================================
// 🎣 Hook: 心跳验证
// ============================================================

static void hook_heartbeatWithCompletion(id self, SEL _cmd, id completion) {
    NSLog(@"[IPHook] 拦截心跳验证");
    
    if (!g_isActivated || !g_t3InitSuccess) {
        NSLog(@"[IPHook] ⚠️ 未激活或 T3 未初始化，跳过心跳");
        callCompletion(completion, NO, @"未激活");
        return;
    }
    
    // 在后台线程执行
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        
        // 调用 T3 心跳
        T3Result *result = [g_t3Verify heartbeatWithKami:g_cardNo statecode:g_statecode];
        
        dispatch_async(dispatch_get_main_queue(), ^{
            
            if (result.success) {
                NSLog(@"[IPHook] ✓ 心跳成功");
                callCompletion(completion, YES, nil);
            } else {
                NSLog(@"[IPHook] ✗ 心跳失败: %@", result.error);
                callCompletion(completion, NO, result.error);
            }
        });
    });
}

// ============================================================
// 🎣 Hook: 开始心跳
// ============================================================

static void hook_startHeartbeat(id self, SEL _cmd) {
    NSLog(@"[IPHook] 拦截开始心跳");
    
    // 如果已经激活，正常开始心跳
    if (g_isActivated) {
        if (orig_startHeartbeat) {
            ((void(*)(id, SEL))orig_startHeartbeat)(self, _cmd);
        }
    } else {
        NSLog(@"[IPHook] ⚠️ 未激活，不开始心跳");
    }
}

// ============================================================
// 🎣 Hook: 停止心跳
// ============================================================

static void hook_stopHeartbeat(id self, SEL _cmd) {
    NSLog(@"[IPHook] 拦截停止心跳");
    
    if (orig_stopHeartbeat) {
        ((void(*)(id, SEL))orig_stopHeartbeat)(self, _cmd);
    }
}

// ============================================================
// 🎣 Hook: 是否已激活
// ============================================================

static BOOL hook_isActivated(id self, SEL _cmd) {
    // 返回我们自己维护的激活状态
    return g_isActivated;
}

// ============================================================
// 🎣 Hook: 获取卡号
// ============================================================

static id hook_cardNo(id self, SEL _cmd) {
    return g_cardNo ?: @"";
}

// ============================================================
// 🎣 Hook: 登出
// ============================================================

static void hook_logout(id self, SEL _cmd) {
    NSLog(@"[IPHook] 拦截登出");
    
    g_isActivated = NO;
    g_cardNo = nil;
    g_statecode = nil;
    
    if (orig_logout) {
        ((void(*)(id, SEL))orig_logout)(self, _cmd);
    }
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
    
    // Hook 卡密验证
    HOOK_METHOD(OLD_VERIFY_CLASS, @selector(activateWithCardNo:machineId:completion:), 
                hook_activateWithCardNo_machineId_completion, orig_activateWithCardNo);
    
    // Hook 心跳
    HOOK_METHOD(OLD_VERIFY_CLASS, @selector(heartbeatWithCompletion:), 
                hook_heartbeatWithCompletion, orig_heartbeatWithCompletion);
    
    // Hook 开始心跳
    HOOK_METHOD(OLD_VERIFY_CLASS, @selector(startHeartbeat), 
                hook_startHeartbeat, orig_startHeartbeat);
    
    // Hook 停止心跳
    HOOK_METHOD(OLD_VERIFY_CLASS, @selector(stopHeartbeat), 
                hook_stopHeartbeat, orig_stopHeartbeat);
    
    // Hook 激活状态
    HOOK_METHOD(OLD_VERIFY_CLASS, @selector(isActivated), 
                hook_isActivated, orig_isActivated);
    
    // Hook 卡号
    HOOK_METHOD(OLD_VERIFY_CLASS, @selector(cardNo), 
                hook_cardNo, orig_cardNo);
    
    // Hook 登出
    HOOK_METHOD(OLD_VERIFY_CLASS, @selector(logout), 
                hook_logout, orig_logout);
    
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
    NSLog(@"[IPHook] 验证系统替换 dylib 已加载");
    NSLog(@"[IPHook] 旧验证: %s", OLD_VERIFY_CLASS);
    NSLog(@"[IPHook] 新验证: T3 网络验证");
    NSLog(@"========================================");
    
    // 延迟一下再 Hook，确保类都加载完成
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), 
                   dispatch_get_main_queue(), ^{
        initHooks();
    });
}
