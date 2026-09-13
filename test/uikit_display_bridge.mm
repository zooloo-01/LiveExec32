#import <UIKit/UIKit.h>
#import <QuartzCore/CAEAGLLayer.h>
#import <objc/runtime.h>
#import "../HostFrameworks/UIKit/LC32LegacyDisplayBridge.h"
#include <math.h>
#include <stdio.h>

// Only the emulator's object-identity and SDK queries are stubbed. Registration,
// policy, asynchronous scheduling, eligibility and fitting are production code.
static const void *peerKey = &peerKey;
@interface NSObject (DisplayTestPeer)
- (uint32_t)guest_selfOrNull;
@end
@implementation NSObject (DisplayTestPeer)
- (uint32_t)guest_selfOrNull {
    return objc_getAssociatedObject(self, peerKey) ? 1 : 0;
}
@end
extern "C" uint32_t LC32GetGuestExecutableSDKVersion(void) { return 0x40000; }
extern "C" uint32_t LC32UIKitLegacyCompatibilityEnabled(void) { return 0; }

@interface DisplayBridgeRenderer : UIView
@end
@implementation DisplayBridgeRenderer
+ (Class)layerClass { return CAEAGLLayer.class; }
@end

static void settle(dispatch_block_t block) {
    // Allocation enqueues registration, which enqueues fitting. Run assertions
    // after both jobs without pumping a nested run loop or timing-based sleep.
    dispatch_async(dispatch_get_main_queue(), ^{
        dispatch_async(dispatch_get_main_queue(), block);
    });
}

extern "C" void LC32RunDisplayBridgeTests(void (^completion)(int)) {
    setenv("LC32_GUEST_EXECUTABLE", NSBundle.mainBundle.executablePath.UTF8String, 1);
    UIWindow *window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    objc_setAssociatedObject(window, peerKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    UIViewController *bookkeeping = [UIViewController new];
    window.rootViewController = bookkeeping;
    [window makeKeyAndVisible];
    bookkeeping.view.hidden = YES;
    DisplayBridgeRenderer *renderer = [[DisplayBridgeRenderer alloc]
        initWithFrame:CGRectMake(0, 0, 320, 480)];
    objc_setAssociatedObject(renderer, peerKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [window addSubview:renderer];
    UIButton *button = [[UIButton alloc] initWithFrame:CGRectMake(40, 60, 80, 40)];
    [renderer addSubview:button];
    const CATransform3D original = window.layer.sublayerTransform;
    LC32UIKitDidAllocateLegacyDrawable(renderer.layer);
    settle(^{
        const CGRect visible = [renderer convertRect:renderer.bounds toView:window];
        const CGRect bounds = window.bounds;
        const CGFloat scale = MIN(bounds.size.width/320, bounds.size.height/480);
        int failed = fabs(visible.size.width - 320*scale) > 0.01 ||
            fabs(visible.size.height - 480*scale) > 0.01 ||
            fabs(CGRectGetMidX(visible) - CGRectGetMidX(bounds)) > 0.01 ||
            fabs(CGRectGetMidY(visible) - CGRectGetMidY(bounds)) > 0.01;
        const CGPoint tap = [button convertPoint:CGPointMake(40, 20) toView:window];
        failed |= [window hitTest:tap withEvent:nil] != button;
        printf("display bridge: window=%gx%g visible={%g,%g,%g,%g}\n",
            bounds.size.width, bounds.size.height, visible.origin.x,
            visible.origin.y, visible.size.width, visible.size.height);
        // An onscreen surface changing to native size must relinquish fitting.
        renderer.bounds = bounds;
        LC32UIKitScheduleLegacyDisplayLayout();
        settle(^{
            const int result = failed || !CATransform3DEqualToTransform(
                window.layer.sublayerTransform, original);
            window.hidden = YES;
            printf("legacy display production bridge: %s\n", result ? "FAIL" : "PASS");
            fflush(stdout);
            completion(result);
        });
    });
}
