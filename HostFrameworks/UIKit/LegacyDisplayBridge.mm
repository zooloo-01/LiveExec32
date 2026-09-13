#import <UIKit/UIKit.h>
#import <QuartzCore/CAEAGLLayer.h>
#import <objc/runtime.h>
#include "bridge.h"
#include "LC32LegacyCanvas.h"
#include "LegacyDisplay.h"
#include <atomic>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>

extern "C" uint32_t LC32GetGuestExecutableSDKVersion(void);

namespace {
// UIKit geometry is inspected only on the native main thread. These atomics
// make a presentation from a dedicated GL thread a coalesced, nonblocking wakeup.
std::atomic<bool> hasDrawables{false};
std::atomic<bool> layoutPending{false};
NSHashTable<CALayer *> *drawables;
NSHashTable<CALayer *> *fittedParents;
const void *loggedDrawableKey = &loggedDrawableKey;

template<typename Result>
Result nativeGetter(id object, Class base, SEL selector) {
    using Getter = Result (*)(id, SEL);
    return reinterpret_cast<Getter>(class_getMethodImplementation(base, selector))(
        object, selector);
}

bool enabled(void) {
    const char *off = getenv("LC32_DISABLE_UIKIT_COMPATIBILITY");
    if(off && strcmp(off, "1") == 0) return false;
    const char *executable = getenv("LC32_GUEST_EXECUTABLE");
    if(!executable || !*executable) return false;
    static bool result;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSBundle *bundle = [NSBundle bundleWithPath:
            [[NSString stringWithUTF8String:executable] stringByDeletingLastPathComponent]];
        result = LC32BundleMayUseLegacyPhoneDrawable(
            bundle, LC32GetGuestExecutableSDKVersion());
    });
    // Scaling measured native geometry is separate from SDK-dependent legacy
    // rotation. Low-SDK UIKit may supply its own turn, but still leave a small
    // drawable inside a modern LiveContainer window. Do not add another turn.
    return result;
}

bool legacySize(CALayer *layer) {
    const CGSize size = nativeGetter<CGRect>(layer, CALayer.class, @selector(bounds)).size;
    return std::isfinite(size.width) && std::isfinite(size.height) &&
        fabs(MIN(size.width, size.height) - 320) < 0.5 &&
        fabs(MAX(size.width, size.height) - 480) < 0.5;
}

UIWindow *drawableWindow(CALayer *layer) {
    id owner = nativeGetter<id>(layer, CALayer.class, @selector(delegate));
    if(![owner isKindOfClass:UIView.class]) return nil;
    if(!layer.guest_selfOrNull && ![owner guest_selfOrNull]) return nil;
    return nativeGetter<UIWindow *>(owner, UIView.class, @selector(window));
}

bool visibleChain(CALayer *layer, CALayer *parent) {
    unsigned limit = 64;
    for(CALayer *cursor = layer; cursor && limit--; ) {
        if(nativeGetter<BOOL>(cursor, CALayer.class, @selector(isHidden)) ||
                nativeGetter<float>(cursor, CALayer.class, @selector(opacity)) <= 0) return false;
        if(cursor == parent) return true;
        cursor = nativeGetter<CALayer *>(cursor, CALayer.class, @selector(superlayer));
    }
    return false;
}

CGRect viewportInWindow(UIWindow *window) {
    UIWindowScene *scene = window.windowScene;
    id<UICoordinateSpace> source = scene.coordinateSpace;
    if(@available(iOS 26.0, *)) {
        // Some SDKs expose effectiveGeometry without declaring coordinateSpace.
        id geometry = scene.effectiveGeometry;
        SEL getter = sel_registerName("coordinateSpace");
        if([geometry respondsToSelector:getter]) {
            source = ((id (*)(id, SEL))objc_msgSend)(geometry, getter);
        }
    }
    if(!source) source = (window.screen ?: UIScreen.mainScreen).coordinateSpace;
    return [window convertRect:source.bounds fromCoordinateSpace:source];
}

void layoutDrawables(void) {
    // Group *all* visible registered surfaces first. Multiple renderers in one
    // window cannot justify stretching the whole guest hierarchy around one.
    NSMapTable<UIWindow *, NSMutableArray<CALayer *> *> *byWindow =
        [NSMapTable mapTableWithKeyOptions:NSPointerFunctionsObjectPointerPersonality
                             valueOptions:NSPointerFunctionsStrongMemory];
    for(CALayer *layer in drawables.allObjects) {
        UIWindow *window = drawableWindow(layer);
        if(!window || !window.guest_selfOrNull) continue;
        CALayer *parent = nativeGetter<CALayer *>(window, UIView.class, @selector(layer));
        if(!visibleChain(layer, parent)) continue;
        NSMutableArray *layers = [byWindow objectForKey:window];
        if(!layers) {
            layers = [NSMutableArray array];
            [byWindow setObject:layers forKey:window];
        }
        [layers addObject:layer];
    }
    NSHashTable<CALayer *> *activeParents = [NSHashTable weakObjectsHashTable];
    for(UIWindow *window in byWindow.keyEnumerator) {
        NSArray<CALayer *> *layers = [byWindow objectForKey:window];
        CALayer *parent = nativeGetter<CALayer *>(window, UIView.class, @selector(layer));
        if(layers.count != 1 || !legacySize(layers.firstObject)) continue;
        CALayer *renderer = layers.firstObject;
        const CGRect viewport = viewportInWindow(window);
        const CGRect bounds = nativeGetter<CGRect>(parent, CALayer.class, @selector(bounds));
        // A small legacy UIWindow has a small hit-test region. Its existing
        // window-placement path remains responsible; this path fixes a modern
        // scene-sized UIWindow containing a smaller, fixed guest drawable.
        if(!CGRectContainsRect(CGRectInset(bounds, -0.5, -0.5), viewport)) continue;
        // Keep the ownership record while eligible, including a helper that
        // yielded to a foreign compositor. Clearing it here would reclaim
        // that authored transform on the next presented frame.
        [activeParents addObject:parent];
        if(LC32FitLegacyDisplayLayer(parent, renderer, viewport)) {
            [fittedParents addObject:parent];
            if(!objc_getAssociatedObject(renderer, loggedDrawableKey)) {
                objc_setAssociatedObject(renderer, loggedDrawableKey, @YES,
                    OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                fprintf(stderr, "LC32 display: fit presented guest drawable; "
                    "window=%gx%g viewport={%g,%g,%g,%g} drawable=%gx%g "
                    "density=%g sdkRotationAdapter=%u\n",
                    bounds.size.width, bounds.size.height,
                    viewport.origin.x, viewport.origin.y,
                    viewport.size.width, viewport.size.height,
                    renderer.bounds.size.width, renderer.bounds.size.height,
                    renderer.contentsScale, LC32UIKitLegacyCompatibilityEnabled());
            }
        }
    }
    for(CALayer *parent in fittedParents.allObjects) {
        if(![activeParents containsObject:parent]) {
            LC32RestoreLegacyDisplayLayer(parent);
            [fittedParents removeObject:parent];
        }
    }
}
}

extern "C" void LC32UIKitScheduleLegacyDisplayLayout(void) {
    if(!hasDrawables.load(std::memory_order_acquire) ||
            layoutPending.exchange(true, std::memory_order_acq_rel)) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        layoutPending.store(false, std::memory_order_release);
        layoutDrawables();
    });
}

extern "C" void LC32UIKitDidAllocateLegacyDrawable(id drawable) {
    if(![drawable isKindOfClass:CAEAGLLayer.class]) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if(!enabled()) return;
        if(!drawables) {
            drawables = [[NSHashTable weakObjectsHashTable] retain];
            fittedParents = [[NSHashTable weakObjectsHashTable] retain];
        }
        [drawables addObject:drawable];
        hasDrawables.store(true, std::memory_order_release);
        LC32UIKitScheduleLegacyDisplayLayout();
    });
}
