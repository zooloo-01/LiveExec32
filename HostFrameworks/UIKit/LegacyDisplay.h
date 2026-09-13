#pragma once

#import <QuartzCore/QuartzCore.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Aspect-fit an identified guest drawable and all its siblings in the native
 * parent. The viewport is expressed in the parent's local coordinates.
 * This changes only the parent's sublayerTransform; renderer bounds, backing
 * density, view hierarchy, and UIWindow geometry remain untouched.
 *
 * An existing affine compositor transform is retained as the baseline. If
 * another owner replaces our last transform, fitting yields until an explicit
 * restore resets the ownership record. Invalid geometry restores only our
 * own changes. The caller identifies the unique eligible guest drawable and
 * calls restore when that hierarchy is no longer eligible. Use on main thread.
 */
bool LC32FitLegacyDisplayLayer(CALayer *parent, CALayer *renderer,
                               CGRect viewport);
void LC32RestoreLegacyDisplayLayer(CALayer *parent);

#ifdef __cplusplus
}
#endif
