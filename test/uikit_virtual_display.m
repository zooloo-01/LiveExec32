#import <UIKit/UIKit.h>
#import <QuartzCore/CAEAGLLayer.h>
#include "../include/LC32DisplayGeometry.h"
#include <stdio.h>
#include <stdlib.h>

static unsigned failures;
static void check(BOOL ok, const char *name) {
    if(!ok) { fprintf(stderr, "virtual display: FAIL %s\n", name); ++failures; }
}

/* Native UIKit contract test for the production canvas placement formula.
 * This deliberately does not manufacture UITouch objects with private APIs;
 * it checks UIKit's inverse point conversion and actual hitTest traversal. */
static void checkCanvas(CGSize viewport, CGSize logical, CGFloat angle) {
    UIView *host = [[UIView alloc] initWithFrame:(CGRect){CGPointZero, viewport}];
    UIView *canvas = [UIView new];
    canvas.bounds = (CGRect){CGPointZero, logical};
    canvas.center = CGPointMake(viewport.width/2, viewport.height/2);
    canvas.clipsToBounds = YES;
    [host addSubview:canvas];
    UIView *guest = [[UIView alloc] initWithFrame:canvas.bounds];
    [canvas addSubview:guest];
    UIButton *control = [[UIButton alloc] initWithFrame:CGRectMake(40, 60, 80, 40)];
    [guest addSubview:control];
    CAEAGLLayer *drawable = [CAEAGLLayer layer];
    drawable.bounds = guest.bounds;
    [guest.layer addSublayer:drawable];

    CGAffineTransform rotation = CGAffineTransformMakeRotation(angle);
    CGRect rotated = CGRectApplyAffineTransform(canvas.bounds, rotation);
    CGFloat scale = LC32DisplayAspectFitScale(viewport.width, viewport.height,
        fabs(rotated.size.width), fabs(rotated.size.height));
    for(NSNumber *density in @[@1, @2]) {
        drawable.contentsScale = density.doubleValue;
        for(unsigned pass = 0; pass < 5; ++pass) {
            canvas.transform = CGAffineTransformScale(rotation, scale, scale);
            CGPoint guestPoint = CGPointMake(80, 80);
            CGPoint visiblePoint = [guest convertPoint:guestPoint toView:host];
            CGPoint converted = [guest convertPoint:visiblePoint fromView:host];
            check(hypot(converted.x - guestPoint.x, converted.y - guestPoint.y)
                < 0.001, "control point round trip");
            check([host hitTest:visiblePoint withEvent:nil] == control,
                "transformed control hit test");
            check(CGRectEqualToRect(guest.bounds, (CGRect){CGPointZero, logical}),
                "guest bounds remain virtual");
            check(CGRectEqualToRect(drawable.bounds, guest.bounds) &&
                drawable.contentsScale == density.doubleValue,
                "presentation does not resize drawable or change density");
        }
    }
    CGRect visible = [canvas convertRect:canvas.bounds toView:host];
    check(fabs(CGRectGetMidX(visible) - viewport.width/2) < 0.001 &&
        fabs(CGRectGetMidY(visible) - viewport.height/2) < 0.001, "centering");
    if(visible.origin.x > 1)
        check([host hitTest:CGPointMake(0, viewport.height/2) withEvent:nil] == host,
            "pillarbox excludes guest");
    if(visible.origin.y > 1)
        check([host hitTest:CGPointMake(viewport.width/2, 0) withEvent:nil] == host,
            "letterbox excludes guest");
}

@interface DisplayTestDelegate : UIResponder <UIApplicationDelegate>
@end
@implementation DisplayTestDelegate
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)options {
    (void)app; (void)options;
    dispatch_async(dispatch_get_main_queue(), ^{
        checkCanvas(CGSizeMake(874, 402), CGSizeMake(480, 320), 0);
        checkCanvas(CGSizeMake(402, 874), CGSizeMake(320, 480), 0);
        checkCanvas(CGSizeMake(874, 402), CGSizeMake(320, 480), M_PI_2);
        checkCanvas(CGSizeMake(874, 402), CGSizeMake(320, 480), -M_PI_2);
        checkCanvas(CGSizeMake(402, 874), CGSizeMake(320, 480), M_PI);
        checkCanvas(CGSizeMake(240, 160), CGSizeMake(480, 320), 0);
        printf("virtual display UIKit: %s\n", failures ? "FAIL" : "PASS");
        fflush(stdout);
        exit(failures ? 1 : 0);
    });
    return YES;
}
@end

int main(int argc, char **argv) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(DisplayTestDelegate.class));
    }
}
