#include "../include/LC32DisplayGeometry.h"
#include <assert.h>
#include <float.h>
#include <stdio.h>

static void fit(double w, double h, double cw, double ch, double expected) {
    const double scale = LC32DisplayAspectFitScale(w, h, cw, ch);
    assert(fabs(scale - expected) < 1e-9);
    const double left = (w - cw * scale) / 2;
    const double top = (h - ch * scale) / 2;
    assert(left >= -1e-9 && top >= -1e-9);
    assert(fabs(left) < 1e-9 || fabs(top) < 1e-9);
    /* Corners, center, and an interior UI control round-trip through the
     * centered virtual display. UIKit conversion gets its own native test. */
    const double points[][2] = {{0, 0}, {cw, ch}, {cw/2, ch/2}, {73, 91}};
    for(unsigned i = 0; i < sizeof(points)/sizeof(points[0]); ++i) {
        const double x = left + points[i][0] * scale;
        const double y = top + points[i][1] * scale;
        assert(fabs((x - left) / scale - points[i][0]) < 1e-9);
        assert(fabs((y - top) / scale - points[i][1]) < 1e-9);
    }
}

int main(void) {
    fit(874, 402, 480, 320, 402.0/320); /* modern landscape, upscale */
    fit(402, 874, 320, 480, 402.0/320); /* portrait, letterbox */
    fit(568, 320, 480, 320, 1);        /* classic/tall phone */
    fit(320, 480, 320, 480, 1);
    fit(1024, 768, 480, 320, 1024.0/480);
    fit(240, 160, 480, 320, 0.5);      /* small scene, downscale */
    assert(LC32DisplayAspectFitScale(0, 400, 320, 480) == 0);
    assert(LC32DisplayAspectFitScale(-1, 400, 320, 480) == 0);
    assert(LC32DisplayAspectFitScale(NAN, 400, 320, 480) == 0);
    assert(LC32DisplayAspectFitScale(400, INFINITY, 320, 480) == 0);
    assert(LC32DisplayAspectFitScale(400, 800, NAN, 480) == 0);
    assert(LC32DisplayAspectFitScale(400, 800, 320, 0) == 0);
    assert(LC32DisplayAspectFitScale(DBL_MAX, DBL_MAX, DBL_MIN, DBL_MIN) == 0);
    puts("display geometry: PASS");
    return 0;
}
