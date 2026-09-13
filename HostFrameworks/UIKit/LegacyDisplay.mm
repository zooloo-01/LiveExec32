#import "LegacyDisplay.h"
#import <objc/runtime.h>
#include "../../include/LC32DisplayGeometry.h"
#include <math.h>

@interface LC32LegacyDisplayLayerState : NSObject
@property(nonatomic) CATransform3D originalTransform;
@property(nonatomic) CATransform3D appliedTransform;
@property(nonatomic) BOOL yielded;
@end

@implementation LC32LegacyDisplayLayerState
@end

namespace {

const void *const stateKey = &stateKey;

/* The layer can belong to a synthesized guest UIView subclass. Calling the
 * typed CALayer implementation avoids entering guest property overrides from
 * a native scene-layout callback, while retaining the host aggregate ABI. */
CGRect boundsOf(CALayer *layer) {
    using Getter = CGRect (*)(id, SEL);
    static Getter getter = reinterpret_cast<Getter>(
        class_getMethodImplementation(CALayer.class, @selector(bounds)));
    return getter(layer, @selector(bounds));
}

CGPoint anchorOf(CALayer *layer) {
    using Getter = CGPoint (*)(id, SEL);
    static Getter getter = reinterpret_cast<Getter>(
        class_getMethodImplementation(CALayer.class, @selector(anchorPoint)));
    return getter(layer, @selector(anchorPoint));
}

CALayer *parentOf(CALayer *layer) {
    using Getter = CALayer *(*)(id, SEL);
    static Getter getter = reinterpret_cast<Getter>(
        class_getMethodImplementation(CALayer.class, @selector(superlayer)));
    return getter(layer, @selector(superlayer));
}

CATransform3D transformOf(CALayer *layer) {
    using Getter = CATransform3D (*)(id, SEL);
    static Getter getter = reinterpret_cast<Getter>(
        class_getMethodImplementation(CALayer.class,
                                      @selector(sublayerTransform)));
    return getter(layer, @selector(sublayerTransform));
}

void setTransform(CALayer *layer, CATransform3D transform) {
    using Setter = void (*)(id, SEL, CATransform3D);
    static Setter setter = reinterpret_cast<Setter>(
        class_getMethodImplementation(CALayer.class,
                                      @selector(setSublayerTransform:)));
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    setter(layer, @selector(setSublayerTransform:), transform);
    [CATransaction commit];
}

CGRect convertRect(CALayer *layer, CGRect rect, CALayer *target) {
    using Convert = CGRect (*)(id, SEL, CGRect, CALayer *);
    static Convert convert = reinterpret_cast<Convert>(
        class_getMethodImplementation(CALayer.class,
                                      @selector(convertRect:toLayer:)));
    return convert(layer, @selector(convertRect:toLayer:), rect, target);
}

bool validRect(CGRect rect) {
    return isfinite(rect.origin.x) && isfinite(rect.origin.y) &&
        isfinite(rect.size.width) && isfinite(rect.size.height) &&
        rect.size.width > 0 && rect.size.height > 0;
}

bool validAffine(CGAffineTransform transform) {
    const CGFloat determinant =
        transform.a * transform.d - transform.b * transform.c;
    return isfinite(transform.a) && isfinite(transform.b) &&
        isfinite(transform.c) && isfinite(transform.d) &&
        isfinite(transform.tx) && isfinite(transform.ty) &&
        isfinite(determinant) && determinant != 0;
}

bool isDescendant(CALayer *renderer, CALayer *parent) {
    unsigned remaining = 1024;
    for(CALayer *layer = parentOf(renderer); layer && remaining--;
            layer = parentOf(layer)) {
        if(layer == parent) return true;
    }
    return false;
}

bool rejectGeometry(CALayer *parent) {
    LC32RestoreLegacyDisplayLayer(parent);
    return false;
}

} // namespace

void LC32RestoreLegacyDisplayLayer(CALayer *parent) {
    if(!parent) return;
    LC32LegacyDisplayLayerState *state =
        objc_getAssociatedObject(parent, stateKey);
    if(!state) return;
    if(!state.yielded && CATransform3DEqualToTransform(
            transformOf(parent), state.appliedTransform)) {
        setTransform(parent, state.originalTransform);
    }
    objc_setAssociatedObject(parent, stateKey, nil,
        OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

bool LC32FitLegacyDisplayLayer(CALayer *parent, CALayer *renderer,
                               CGRect viewport) {
    if(!parent) return false;
    LC32LegacyDisplayLayerState *state =
        objc_getAssociatedObject(parent, stateKey);
    const CATransform3D current3D = transformOf(parent);
    if(state) {
        if(state.yielded) return false;
        if(!CATransform3DEqualToTransform(current3D, state.appliedTransform)) {
            /* A native/guest compositor explicitly replaced this property.
             * Preserve it, including during cleanup. Ordinary window bounds
             * or center changes do not relinquish this independent property. */
            state.yielded = YES;
            return false;
        }
    }
    if(!renderer || renderer == parent || !isDescendant(renderer, parent) ||
            !validRect(viewport) || !CATransform3DIsAffine(current3D)) {
        return rejectGeometry(parent);
    }
    const CGRect parentBounds = boundsOf(parent);
    const CGRect rendererBounds = boundsOf(renderer);
    const CGPoint anchorPoint = anchorOf(parent);
    const CGAffineTransform current = CATransform3DGetAffineTransform(current3D);
    if(!validRect(parentBounds) || !validRect(rendererBounds) ||
            !isfinite(anchorPoint.x) || !isfinite(anchorPoint.y) ||
            !validAffine(current)) return rejectGeometry(parent);

    /* Convert the real drawable, not UIWindow.bounds: modern UIWindow may
     * already be 402x874 while its pre-controller renderer is still 320x480.
     * Conversion includes existing native compositor rotation and our last
     * presentation fit, so the correction is identity on repeated layouts. */
    const CGRect source = convertRect(renderer, rendererBounds, parent);
    if(!validRect(source)) return rejectGeometry(parent);
    const CGFloat scale = LC32DisplayAspectFitScale(
        viewport.size.width, viewport.size.height,
        source.size.width, source.size.height);
    if(!(scale > 0) || !isfinite(scale)) return rejectGeometry(parent);
    const CGPoint anchor = CGPointMake(
        parentBounds.origin.x + anchorPoint.x * parentBounds.size.width,
        parentBounds.origin.y + anchorPoint.y * parentBounds.size.height);

    /* CALayer applies sublayerTransform about its own anchor. For the desired
     * parent-space fit F(x)=mid(viewport)+scale*(x-mid(source)), the stored
     * matrix is Translate(-anchor) * F * Translate(anchor) * current.
     * Explicit coefficients avoid ambiguity about CGAffineTransformConcat's
     * multiplication order and preserve the existing compositor orientation. */
    const CGAffineTransform desired = CGAffineTransformMake(
        scale * current.a, scale * current.b,
        scale * current.c, scale * current.d,
        scale * current.tx + CGRectGetMidX(viewport) - anchor.x +
            scale * (anchor.x - CGRectGetMidX(source)),
        scale * current.ty + CGRectGetMidY(viewport) - anchor.y +
            scale * (anchor.y - CGRectGetMidY(source)));
    if(!validAffine(desired)) return rejectGeometry(parent);
    const CATransform3D desired3D = CATransform3DMakeAffineTransform(desired);
    if(CATransform3DEqualToTransform(current3D, desired3D)) return true;
    if(!state) {
        state = [LC32LegacyDisplayLayerState new];
        state.originalTransform = current3D;
        objc_setAssociatedObject(parent, stateKey, state,
            OBJC_ASSOCIATION_RETAIN_NONATOMIC);
#if !__has_feature(objc_arc)
        [state release];
#endif
    }
    state.appliedTransform = desired3D;
    setTransform(parent, desired3D);
    return true;
}
