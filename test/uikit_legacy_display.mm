#import <UIKit/UIKit.h>
#import <QuartzCore/CAEAGLLayer.h>
#import "../HostFrameworks/UIKit/LegacyDisplay.h"
#include <math.h>
#include <stdio.h>
#include <stdlib.h>

/* This fixture links the actual LegacyDisplay.mm implementation used by the
 * host. No test copy of the fitting formula decides where to place a view.
 * It reproduces a modern parent containing a fixed pre-controller drawable,
 * including independently attached UIKit controls and nested renderers.
 */
static unsigned failures;

static void check(BOOL ok, const char *name) {
    if(!ok) {
        fprintf(stderr, "legacy display production: FAIL %s\n", name);
        ++failures;
    }
}

static BOOL near(CGFloat a, CGFloat b) {
    return isfinite(a) && isfinite(b) && fabs(a - b) < 0.001;
}

static BOOL nearPoint(CGPoint a, CGPoint b) {
    return near(a.x, b.x) && near(a.y, b.y);
}

static BOOL nearRect(CGRect a, CGRect b) {
    return nearPoint(a.origin, b.origin) &&
        near(a.size.width, b.size.width) && near(a.size.height, b.size.height);
}

@interface LC32DisplayRendererView : UIView
@end

@implementation LC32DisplayRendererView
+ (Class)layerClass { return CAEAGLLayer.class; }
@end

static void checkFit(UIView *parent, UIView *renderer,
                     NSArray<UIButton *> *controls, CGRect viewport,
                     BOOL landscape) {
    const CGRect oldBounds = renderer.bounds;
    const CGPoint oldCenter = renderer.center;
    const CGAffineTransform oldTransform = renderer.transform;
    const CGFloat oldDensity = renderer.layer.contentsScale;
    const CGRect parentBounds = parent.bounds;
    const CGPoint parentCenter = parent.center;
    const CGAffineTransform parentTransform = parent.transform;
    UIView *oldSuperview = renderer.superview;
    NSArray<UIView *> *oldChildren = [parent.subviews copy];
    check(LC32FitLegacyDisplayLayer(parent.layer, renderer.layer, viewport),
        "identified fixed drawable is fitted");

    const CGFloat width = landscape ? 480 : 320;
    const CGFloat height = landscape ? 320 : 480;
    const CGFloat expectedScale = MIN(
        viewport.size.width / width, viewport.size.height / height);
    const CGRect expected = CGRectMake(
        CGRectGetMidX(viewport) - width * expectedScale / 2,
        CGRectGetMidY(viewport) - height * expectedScale / 2,
        width * expectedScale, height * expectedScale);

    for(unsigned repeat = 0; repeat < 20; ++repeat) {
        check(LC32FitLegacyDisplayLayer(parent.layer, renderer.layer, viewport),
            "repeated production fit remains eligible");
        const CGRect actual = [renderer convertRect:renderer.bounds toView:parent];
        check(nearRect(actual, expected),
            "actual UIKit drawable rectangle maximizes and centers canvas");
        check(nearRect([renderer.layer convertRect:renderer.layer.bounds
                                          toLayer:parent.layer], expected),
            "view and layer coordinate spaces agree");
        check(CGRectEqualToRect(renderer.bounds, oldBounds) &&
            CGPointEqualToPoint(renderer.center, oldCenter) &&
            CGAffineTransformEqualToTransform(renderer.transform, oldTransform) &&
            renderer.layer.contentsScale == oldDensity,
            "drawable bounds placement transform and density are unchanged");
        check(CGRectEqualToRect(parent.bounds, parentBounds) &&
            CGPointEqualToPoint(parent.center, parentCenter) &&
            CGAffineTransformEqualToTransform(parent.transform, parentTransform),
            "native window geometry is untouched");
        check(renderer.superview == oldSuperview &&
            [parent.subviews isEqualToArray:oldChildren],
            "direct and nested guest hierarchy is untouched");
        for(UIButton *button in controls) {
            const CGPoint local = CGPointMake(
                CGRectGetMidX(button.bounds), CGRectGetMidY(button.bounds));
            const CGPoint visible = [button convertPoint:local toView:parent];
            check(nearPoint([button convertPoint:visible fromView:parent], local),
                "control coordinates round trip through UIKit");
            check([parent hitTest:visible withEvent:nil] == button,
                "actual UIKit hit test reaches each scaled corner control");
        }
    }
    const CGPoint bar = expected.origin.y > viewport.origin.y + 1
        ? CGPointMake(CGRectGetMidX(viewport), viewport.origin.y + 0.5)
        : CGPointMake(viewport.origin.x + 0.5, CGRectGetMidY(viewport));
    if(!CGRectContainsPoint(expected, bar)) {
        check([parent hitTest:bar withEvent:nil] == parent,
            "letterbox and pillarbox areas exclude guest controls");
    }
#if !__has_feature(objc_arc)
    [oldChildren release];
#endif
}

static void checkScenario(CGRect bounds, CGPoint anchor, CGFloat rotation,
                          BOOL nested) {
    UIView *parent = [[UIView alloc] initWithFrame:
        CGRectMake(0, 0, bounds.size.width, bounds.size.height)];
    parent.bounds = bounds;
    parent.layer.anchorPoint = anchor;
    const CATransform3D baseline = CATransform3DMakeAffineTransform(
        CGAffineTransformMakeRotation(rotation));
    parent.layer.sublayerTransform = baseline;
    UIView *canvas = parent;
    if(nested) {
        canvas = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 320, 480)];
        [parent addSubview:canvas];
    }
    LC32DisplayRendererView *renderer = [[LC32DisplayRendererView alloc]
        initWithFrame:CGRectMake(0, 0, 320, 480)];
    renderer.userInteractionEnabled = NO;
    [canvas addSubview:renderer];
    NSMutableArray<UIButton *> *controls = [NSMutableArray array];
    for(NSValue *value in @[
            [NSValue valueWithCGPoint:CGPointMake(8, 8)],
            [NSValue valueWithCGPoint:CGPointMake(280, 8)],
            [NSValue valueWithCGPoint:CGPointMake(8, 440)],
            [NSValue valueWithCGPoint:CGPointMake(280, 440)]]) {
        UIButton *button = [[UIButton alloc]
            initWithFrame:(CGRect){value.CGPointValue, {32, 32}}];
        [canvas addSubview:button];
        [controls addObject:button];
#if !__has_feature(objc_arc)
        [button release];
#endif
    }
    const BOOL landscape = fabs(sin(rotation)) > 0.5;
    for(NSNumber *density in @[@1, @2, @3]) {
        renderer.layer.contentsScale = density.doubleValue;
        checkFit(parent, renderer, controls, parent.bounds, landscape);
    }

    /* Ordinary scene resize/recenter must not be mistaken for guest ownership
     * of the independent parent compositor property. Do not force the native
     * window into the legacy renderer's size as the older fixtures did. */
    parent.bounds = CGRectMake(bounds.origin.x + 9, bounds.origin.y - 7,
        bounds.size.height, bounds.size.width);
    parent.center = CGPointMake(parent.center.x + 23, parent.center.y - 17);
    checkFit(parent, renderer, controls, parent.bounds, landscape);
    LC32RestoreLegacyDisplayLayer(parent.layer);
    check(CATransform3DEqualToTransform(parent.layer.sublayerTransform, baseline),
        "restore retains the original native compositor orientation");

    checkFit(parent, renderer, controls, parent.bounds, landscape);
    const CATransform3D authored = CATransform3DMakeTranslation(7, 9, 0);
    parent.layer.sublayerTransform = authored;
    check(!LC32FitLegacyDisplayLayer(parent.layer, renderer.layer, parent.bounds),
        "foreign compositor change yields ownership");
    check(!LC32FitLegacyDisplayLayer(parent.layer, renderer.layer, parent.bounds) &&
        CATransform3DEqualToTransform(parent.layer.sublayerTransform, authored),
        "repeated fitting preserves authored compositor");
    LC32RestoreLegacyDisplayLayer(parent.layer);
    check(CATransform3DEqualToTransform(parent.layer.sublayerTransform, authored),
        "cleanup never restores over an authored compositor");

    parent.layer.sublayerTransform = baseline;
    check(LC32FitLegacyDisplayLayer(parent.layer, renderer.layer, parent.bounds),
        "explicit restoration permits a new native baseline");
    check(!LC32FitLegacyDisplayLayer(parent.layer, renderer.layer,
        CGRectMake(0, 0, 0, 874)) && CATransform3DEqualToTransform(
            parent.layer.sublayerTransform, baseline),
        "invalid geometry restores only owned presentation");
    check(!LC32FitLegacyDisplayLayer(parent.layer, renderer.layer,
        CGRectMake(0, 0, INFINITY, 874)), "nonfinite viewport rejected");
    CALayer *unrelated = [CALayer layer];
    unrelated.bounds = CGRectMake(0, 0, 320, 480);
    check(!LC32FitLegacyDisplayLayer(parent.layer, unrelated, parent.bounds),
        "unrelated offscreen layer cannot become the display");
#if !__has_feature(objc_arc)
    [renderer release];
    if(nested) [canvas release];
    [parent release];
#endif
}

extern "C" int LC32RunLegacyDisplayTests(void) {
    failures = 0;
    checkScenario(CGRectMake(0, 0, 402, 874), CGPointMake(0.5, 0.5), 0, NO);
    checkScenario(CGRectMake(0, 0, 874, 402), CGPointMake(0.5, 0.5), M_PI_2, NO);
    checkScenario(CGRectMake(0, 0, 874, 402), CGPointMake(0.5, 0.5), -M_PI_2, YES);
    checkScenario(CGRectMake(19, -11, 402, 874), CGPointMake(0.2, 0.8), 0, YES);
    checkScenario(CGRectMake(-13, 17, 874, 402), CGPointMake(0.7, 0.1), M_PI_2, YES);
    checkScenario(CGRectMake(0, 0, 240, 160), CGPointMake(0.5, 0.5), -M_PI_2, NO);
    printf("legacy display production UIKit: %s\n", failures ? "FAIL" : "PASS");
    fflush(stdout);
    return failures ? 1 : 0;
}

#if LC32_LEGACY_DISPLAY_STANDALONE
@interface LC32LegacyDisplayTestDelegate : UIResponder <UIApplicationDelegate>
@end
@implementation LC32LegacyDisplayTestDelegate
- (BOOL)application:(UIApplication *)application
        didFinishLaunchingWithOptions:(NSDictionary *)options {
    (void)application;
    (void)options;
    dispatch_async(dispatch_get_main_queue(), ^{
        exit(LC32RunLegacyDisplayTests());
    });
    return YES;
}
@end

int main(int argc, char **argv) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil,
            NSStringFromClass(LC32LegacyDisplayTestDelegate.class));
    }
}
#endif
