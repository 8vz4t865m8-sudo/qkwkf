#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <sys/sysctl.h>
#import <dlfcn.h>
#import <string.h>
#import "fishhook.h"
#import <CommonCrypto/CommonDigest.h>

// 自己声明缺失的函数
int ptrace(int request, int pid, void *addr, int data);
#define PT_DENY_ATTACH 31

uint32_t _dyld_image_count(void);
const char* _dyld_get_image_name(uint32_t image_index);

#define BYPASS_KEYWORD "bypass"

// ============================================================
// 1. 崩溃函数 Hook（防止自杀）
// ============================================================
static void (*orig_abort)(void);
static void (*orig_exit)(int);
static int (*orig_kill)(int, int);
static void (*orig_objc_exception_throw)(NSException *);

void my_abort(void) {
    NSLog(@"[Bypass] 拦截 abort");
    while(1) sleep(999);
}
void my_exit(int status) {
    NSLog(@"[Bypass] 拦截 exit: %d", status);
    while(1) sleep(999);
}
int my_kill(int pid, int sig) {
    NSLog(@"[Bypass] 拦截 kill: %d %d", pid, sig);
    return 0;
}
void my_objc_exception_throw(NSException *e) {
    NSLog(@"[Bypass] 拦截异常: %@", e);
}

// ============================================================
// 2. 反调试 Hook
// ============================================================
static int (*orig_ptrace)(int, int, void *, int);
static int (*orig_sysctl)(int *, u_int, void *, size_t *, void *, size_t);
static int (*orig_sysctlbyname)(const char *, void *, size_t *, void *, size_t);

int my_ptrace(int req, int pid, void *addr, int data) {
    NSLog(@"[Bypass] 拦截 ptrace: %d", req);
    return 0;
}

int my_sysctl(int *name, u_int namelen, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
    int ret = orig_sysctl(name, namelen, oldp, oldlenp, newp, newlen);
    return ret;
}

int my_sysctlbyname(const char *name, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
    if (strcmp(name, "sysctl.proc_trced") == 0) {
        if (oldp && oldlenp) {
            *(int *)oldp = 0;
            *oldlenp = sizeof(int);
        }
        return 0;
    }
    return orig_sysctlbyname(name, oldp, oldlenp, newp, newlen);
}

// ============================================================
// 3. 哈希校验 Hook（关键！防止完整性校验闪退）
// ============================================================
static unsigned char *(*orig_CC_MD5)(const void *data, CC_LONG len, unsigned char *md);
static unsigned char *(*orig_CC_SHA1)(const void *data, CC_LONG len, unsigned char *md);
static unsigned char *(*orig_CC_SHA256)(const void *data, CC_LONG len, unsigned char *md);

// 固定的假哈希值（全0）
unsigned char *my_CC_MD5(const void *data, CC_LONG len, unsigned char *md) {
    NSLog(@"[Bypass] 拦截 CC_MD5，len=%lu", (unsigned long)len);
    if (md) {
        memset(md, 0, CC_MD5_DIGEST_LENGTH);
    }
    return md;
}

unsigned char *my_CC_SHA1(const void *data, CC_LONG len, unsigned char *md) {
    NSLog(@"[Bypass] 拦截 CC_SHA1，len=%lu", (unsigned long)len);
    if (md) {
        memset(md, 0, CC_SHA1_DIGEST_LENGTH);
    }
    return md;
}

unsigned char *my_CC_SHA256(const void *data, CC_LONG len, unsigned char *md) {
    NSLog(@"[Bypass] 拦截 CC_SHA256，len=%lu", (unsigned long)len);
    if (md) {
        memset(md, 0, CC_SHA256_DIGEST_LENGTH);
    }
    return md;
}

// ============================================================
// 4. 注入检测 Hook（隐藏自己）
// ============================================================
static uint32_t (*orig_dyld_image_count)(void);
static const char *(*orig_dyld_get_image_name)(uint32_t);
static int s_bypassIndex = -1;

static void find_bypass_index(void) {
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *path = _dyld_get_image_name(i);
        if (path && strstr(path, BYPASS_KEYWORD)) {
            s_bypassIndex = (int)i;
            NSLog(@"[Bypass] 找到自身索引: %d", i);
            break;
        }
    }
}

uint32_t my_dyld_image_count(void) {
    uint32_t c = orig_dyld_image_count();
    return s_bypassIndex >= 0 ? c - 1 : c;
}

const char *my_dyld_get_image_name(uint32_t index) {
    if (s_bypassIndex < 0) return orig_dyld_get_image_name(index);
    if (index < (uint32_t)s_bypassIndex) return orig_dyld_get_image_name(index);
    return orig_dyld_get_image_name(index + 1);
}

// ============================================================
// 5. 验证方法 Hook（核心）
// ============================================================
static void (*orig_buildAuthView)(id, SEL);
static void (*orig_onVerify)(id, SEL);
static void (*orig_tryAutoLogin)(id, SEL, id);
static void (*orig_doHeartbeat)(id, SEL);

void my_buildAuthView(id self, SEL _cmd) {
    NSLog(@"[Bypass] Hook buildAuthView，直接进主界面");
    SEL buildSel = NSSelectorFromString(@"buildMainView");
    SEL enterSel = NSSelectorFromString(@"enterMainConsole");
    if ([self respondsToSelector:buildSel]) {
        IMP imp = [self methodForSelector:buildSel];
        ((void (*)(id, SEL))imp)(self, buildSel);
    }
    if ([self respondsToSelector:enterSel]) {
        IMP imp = [self methodForSelector:enterSel];
        ((void (*)(id, SEL))imp)(self, enterSel);
    }
}

void my_onVerify(id self, SEL _cmd) {
    NSLog(@"[Bypass] Hook onVerify，直接进主界面");
    SEL enterSel = NSSelectorFromString(@"enterMainConsole");
    if ([self respondsToSelector:enterSel]) {
        IMP imp = [self methodForSelector:enterSel];
        ((void (*)(id, SEL))imp)(self, enterSel);
    }
}

void my_tryAutoLogin(id self, SEL _cmd, id sender) {
    NSLog(@"[Bypass] Hook tryAutoLogin，直接进主界面");
    SEL enterSel = NSSelectorFromString(@"enterMainConsole");
    if ([self respondsToSelector:enterSel]) {
        IMP imp = [self methodForSelector:enterSel];
        ((void (*)(id, SEL))imp)(self, enterSel);
    }
}

void my_doHeartbeat(id self, SEL _cmd) {
    NSLog(@"[Bypass] Hook doHeartbeat，空实现");
}

// ============================================================
// 6. 等 APP 启动完再 Hook OC
// ============================================================
static void hook_oc_methods(void) {
    Class cls = objc_getClass("ViewController");
    if (!cls) {
        NSLog(@"[Bypass] 未找到 ViewController 类");
        return;
    }
    
    Method m;
    
    m = class_getInstanceMethod(cls, NSSelectorFromString(@"buildAuthView"));
    if (m) { orig_buildAuthView = (void *)method_getImplementation(m); method_setImplementation(m, (IMP)my_buildAuthView); }
    
    m = class_getInstanceMethod(cls, NSSelectorFromString(@"onVerify"));
    if (m) { orig_onVerify = (void *)method_getImplementation(m); method_setImplementation(m, (IMP)my_onVerify); }
    
    m = class_getInstanceMethod(cls, NSSelectorFromString(@"tryAutoLogin:"));
    if (m) { orig_tryAutoLogin = (void *)method_getImplementation(m); method_setImplementation(m, (IMP)my_tryAutoLogin); }
    
    m = class_getInstanceMethod(cls, NSSelectorFromString(@"doHeartbeat"));
    if (m) { orig_doHeartbeat = (void *)method_getImplementation(m); method_setImplementation(m, (IMP)my_doHeartbeat); }
    
    NSLog(@"[Bypass] OC 方法 Hook 完成");
}

static void app_did_finish(NSNotification *note) {
    NSLog(@"[Bypass] APP 启动完成，开始 Hook");
    hook_oc_methods();
}

// ============================================================
// 7. 构造函数（最早执行）
// ============================================================
__attribute__((constructor)) static void init() {
    NSLog(@"[Bypass] ===== dylib 加载成功 =====");
    
    find_bypass_index();
    
    // 所有 C 函数 Hook（越早越好）
    struct rebinding rebs[] = {
        // 崩溃
        {"abort", my_abort, (void *)&orig_abort},
        {"exit", my_exit, (void *)&orig_exit},
        {"kill", my_kill, (void *)&orig_kill},
        {"objc_exception_throw", my_objc_exception_throw, (void *)&orig_objc_exception_throw},
        // 反调试
        {"ptrace", my_ptrace, (void *)&orig_ptrace},
        {"sysctl", my_sysctl, (void *)&orig_sysctl},
        {"sysctlbyname", my_sysctlbyname, (void *)&orig_sysctlbyname},
        // 哈希校验（关键！）
        {"CC_MD5", my_CC_MD5, (void *)&orig_CC_MD5},
        {"CC_SHA1", my_CC_SHA1, (void *)&orig_CC_SHA1},
        {"CC_SHA256", my_CC_SHA256, (void *)&orig_CC_SHA256},
        // 注入检测
        {"_dyld_image_count", my_dyld_image_count, (void *)&orig_dyld_image_count},
        {"_dyld_get_image_name", my_dyld_get_image_name, (void *)&orig_dyld_get_image_name},
    };
    rebind_symbols(rebs, sizeof(rebs)/sizeof(rebs[0]));
    NSLog(@"[Bypass] C 函数 Hook 完成");
    
    // 等 APP 启动完再 Hook OC 方法
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidFinishLaunchingNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *note) {
                                                      app_did_finish(note);
                                                  }];
    
    NSLog(@"[Bypass] ===== 初始化完成 =====");
}
