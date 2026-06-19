#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <sys/sysctl.h>
#import <dlfcn.h>
#import <string.h>
#import "fishhook.h"

// 自己声明 ptrace（iOS SDK 没这个头文件）
int ptrace(int request, int pid, void *addr, int data);
#define PT_DENY_ATTACH 31

#define BYPASS_KEYWORD "bypass"

// ============================================================
// 1. 崩溃函数 Hook
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
// 3. 注入检测 Hook（隐藏自己）
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
// 4. 验证方法 Hook
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
// 5. 等 APP 启动完再 Hook OC
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
// 6. 构造函数
// ============================================================
__attribute__((constructor)) static void init() {
    NSLog(@"[Bypass] ===== dylib 加载成功 =====");
    
    find_bypass_index();
    
    struct rebinding rebs[] = {
        {"abort", my_abort, (void *)&orig_abort},
        {"exit", my_exit, (void *)&orig_exit},
        {"kill", my_kill, (void *)&orig_kill},
        {"objc_exception_throw", my_objc_exception_throw, (void *)&orig_objc_exception_throw},
        {"ptrace", my_ptrace, (void *)&orig_ptrace},
        {"sysctl", my_sysctl, (void *)&orig_sysctl},
        {"sysctlbyname", my_sysctlbyname, (void *)&orig_sysctlbyname},
        {"_dyld_image_count", my_dyld_image_count, (void *)&orig_dyld_image_count},
        {"_dyld_get_image_name", my_dyld_get_image_name, (void *)&orig_dyld_get_image_name},
    };
    rebind_symbols(rebs, sizeof(rebs)/sizeof(rebs[0]));
    NSLog(@"[Bypass] C 函数 Hook 完成");
    
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidFinishLaunchingNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *note) {
                                                      app_did_finish(note);
                                                  }];
    
    NSLog(@"[Bypass] ===== 初始化完成 =====");
}
