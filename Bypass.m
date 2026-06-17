#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

@interface BypassEntry : UIResponder <UIApplicationDelegate>
@property (strong, nonatomic) UIWindow *window;
@end

@implementation BypassEntry

+ (void)load {
    // 启动就执行Hook，完全不碰原可执行文件
    Class T3Verify = objc_getClass("T3Verify");
    
    Method login = class_getInstanceMethod(T3Verify, @selector(loginWithKami:imei:));
    IMP original = method_getImplementation(login);
    method_setImplementation(login, imp_implementationWithBlock(^id(id self, id kami, id imei) {
        id res = [[objc_getClass("T3LoginResult") alloc] init];
        [res setValue:@(YES) forKey:@"success"];
        [res setValue:@(9999999999) forKey:@"endTime"];
        [res setValue:@(YES) forKey:@"available"];
        return res;
    }));
    
    Method heartbeat = class_getInstanceMethod(T3Verify, @selector(heartbeatWithKami:statecode:));
    method_setImplementation(heartbeat, imp_implementationWithBlock(^id(id self, id kami, id statecode) {
        id res = [[objc_getClass("T3Result") alloc] init];
        [res setValue:@(YES) forKey:@"success"];
        return res;
    }));
}

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    // 调用原APP的启动方法
    Class originalDelegate = objc_getClass("AppDelegate");
    id original = [[originalDelegate alloc] init];
    [original application:application didFinishLaunchingWithOptions:launchOptions];
    return YES;
}

@end
