#import <Foundation/Foundation.h>
#import <objc/runtime.h>

@interface T3LoginResult : NSObject
@property (nonatomic, strong) NSNumber *success;
@property (nonatomic, strong) NSNumber *endTime;
@property (nonatomic, strong) NSNumber *available;
@property (nonatomic, strong) NSString *core;
@end

@interface T3Result : NSObject
@property (nonatomic, strong) NSNumber *success;
@end

%hook T3Verify

// 卡密登录直接返回永久成功
- (id)loginWithKami:(id)kami imei:(id)imei {
    id res = [objc_getClass("T3LoginResult") new];
    [res setValue:@(YES) forKey:@"success"];
    [res setValue:@(9999999999) forKey:@"endTime"];
    [res setValue:@(YES) forKey:@"available"];
    [res setValue:@"permanent_bypass" forKey:@"core"];
    return res;
}

// 心跳验证永远成功
- (id)heartbeatWithKami:(id)kami statecode:(id)statecode {
    id res = [objc_getClass("T3Result") new];
    [res setValue:@(YES) forKey:@"success"];
    return res;
}

// SDK初始化永远通过
- (BOOL)checkInit:(NSError **)error {
    return YES;
}

// 拦截所有联网请求，断网也能用
- (id)httpPost:(NSString *)url body:(NSData *)body error:(NSError **)error {
    return nil;
}

%end

__attribute__((constructor)) static void bypass_load() {
    NSLog(@"[IBOX Bypass] 验证绕过已加载");
}
