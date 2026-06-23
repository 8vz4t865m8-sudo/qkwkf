#import <Foundation/Foundation.h>
#import <objc/runtime.h>

// ====== 配置区域 - 改成你自己的房间号 ======
static NSString * const kCustomRoomCode = @"E66666";  // 改成你自己想要的房间号
// ============================================

#pragma mark - 初始化

__attribute__((constructor))
static void roomhook_initialize() {
    @autoreleasepool {
        NSLog(@"========================================");
        NSLog(@"[RoomHook] 房间号修改已加载");
        NSLog(@"[RoomHook] 自定义房间号: %@", kCustomRoomCode);
        NSLog(@"========================================");
        
        // ========== Hook ViewController 的 roomCode getter ==========
        Class vcClass = objc_getClass("ViewController");
        if (vcClass) {
            SEL roomCodeSel = @selector(roomCode);
            Method roomCodeMethod = class_getInstanceMethod(vcClass, roomCodeSel);
            
            if (roomCodeMethod) {
                IMP originalImp = method_getImplementation(roomCodeMethod);
                NSString * (*originalFunc)(id, SEL) = (void *)originalImp;
                
                IMP swizzledImp = imp_implementationWithBlock(^NSString *(id self) {
                    // 直接返回我们自定义的房间号
                    NSLog(@"[RoomHook] 拦截roomCode请求，返回: %@", kCustomRoomCode);
                    return kCustomRoomCode;
                });
                
                class_addMethod(vcClass,
                               @selector(roomhook_roomCode),
                               swizzledImp,
                               method_getTypeEncoding(roomCodeMethod));
                
                Method swizzledMethod = class_getInstanceMethod(vcClass, @selector(roomhook_roomCode));
                method_exchangeImplementations(roomCodeMethod, swizzledMethod);
                
                NSLog(@"[RoomHook] ✅ ViewController roomCode hook成功");
            }
        }
        
        // ========== Hook RadarRelayClient 的 initWithServerURL:room: (双重保险) ==========
        Class radarClass = objc_getClass("RadarRelayClient");
        if (radarClass) {
            SEL originalSel = @selector(initWithServerURL:room:);
            Method originalMethod = class_getInstanceMethod(radarClass, originalSel);
            
            if (originalMethod) {
                IMP originalImp = method_getImplementation(originalMethod);
                id (*originalFunc)(id, SEL, id, NSString *) = (void *)originalImp;
                
                IMP swizzledImp = imp_implementationWithBlock(^id(id self, id serverURL, NSString *room) {
                    NSLog(@"[RoomHook] 原始房间号: %@", room);
                    NSLog(@"[RoomHook] 替换为: %@", kCustomRoomCode);
                    return originalFunc(self, originalSel, serverURL, kCustomRoomCode);
                });
                
                class_addMethod(radarClass,
                               @selector(roomhook_initWithServerURL:room:),
                               swizzledImp,
                               method_getTypeEncoding(originalMethod));
                
                Method swizzledMethod = class_getInstanceMethod(radarClass, @selector(roomhook_initWithServerURL:room:));
                method_exchangeImplementations(originalMethod, swizzledMethod);
                
                NSLog(@"[RoomHook] ✅ RadarRelayClient room hook成功");
            }
        }
        
        NSLog(@"[RoomHook] 🚀 全部hook完成");
    }
}
