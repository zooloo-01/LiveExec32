#ifndef LC32_DISPLAY_GEOMETRY_H
#define LC32_DISPLAY_GEOMETRY_H

#include <math.h>

/* Pixel density is intentionally absent: this fits logical UIKit points.
 * Zero means that scene geometry is provisional and should be retried later. */
static inline double LC32DisplayAspectFitScale(double viewportWidth,
        double viewportHeight, double contentWidth, double contentHeight) {
    if(!isfinite(viewportWidth) || !isfinite(viewportHeight) ||
            !isfinite(contentWidth) || !isfinite(contentHeight) ||
            viewportWidth <= 0 || viewportHeight <= 0 ||
            contentWidth <= 0 || contentHeight <= 0) return 0;
    const double scale = fmin(viewportWidth / contentWidth,
                              viewportHeight / contentHeight);
    return isfinite(scale) ? scale : 0;
}

#endif
