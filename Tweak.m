#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// 什么 hook 都不做，就只弹窗测试

static void show_test_alert() {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"✅ 测试成功" 
                                                                       message:@"dylib加载成功！"
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
        
        UIWindow *window = [[UIApplication sharedApplication] keyWindow];
        if (!window) {
            window = [[UIApplication sharedApplication].windows firstObject];
        }
        [window.rootViewController presentViewController:alert animated:YES completion:nil];
    });
}

static void app_did_finish(NSNotification *note) {
    show_test_alert();
}

__attribute__((constructor)) static void init() {
    // 什么都不做，就等 APP 启动完弹窗
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidFinishLaunchingNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *note) {
                                                      app_did_finish(note);
                                                  }];
}
