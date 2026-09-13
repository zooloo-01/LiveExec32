# Legacy virtual display

## September 13 revision: presentation inside a modern window

The first IPA did not fix Spy Mouse on the reported LiveContainer/iPhone 16
Pro setup. Its screenshot shows a 320x480-point image at the origin of a
402x874-point display. The prior window-placement path only accepted windows
whose own bounds were 320x480/480x320; it returned without fitting a small
renderer inside a native-size window. Its tests never exercised that path.

The fork now includes upstream `3f0390e`, including the native legacy rotation
and portrait EAGL canvas fixes. New `LegacyDisplayBridge.mm` observes successful
EAGL drawable allocation and schedules coalesced main-thread fitting after
successful presentation. It measures the actual unique guest drawable inside
the window. `LegacyDisplay.mm` fits its projected rectangle by changing the
parent's sublayer transform, preserving the existing native rotation, all local
guest geometry, and the hierarchy shared by sibling controls. No additional
quarter-turn is inferred. A legacy SDK disabling rotation adapters no longer
disables this measured presentation fit.

Automatic presentation detection requires a fullscreen pre-iOS-8 phone-capable
guest and a unique visible 320x480/480x320 layer backed by successful EAGL
storage. It does not depend on launch image filenames. Native mode and the
global compatibility disable still opt out. Multiple visible GL surfaces or
a renderer resized to native dimensions relinquish this fit. Small legacy
windows retain their earlier window-placement path to keep their hit region
aligned. A changed foreign compositor transform yields ownership.

CI now links and executes the actual production compositor and registration /
scheduling bridge in Simulator. Only emulator peer identity and SDK queries
are stubbed. Cases include modern parent dimensions, nested renderers, sibling
corner controls, noncentral anchors, repeated fits, scene resize, existing
rotation, a hidden bookkeeping controller, and return to native drawable size.
The device log includes `LC32 display:` eligibility and measured fit details.
Passing these tests does not establish a successful Spy Mouse device run.

## Rendering and input path

The ARM32 UIKit shim forwards Objective-C calls through `bridge.mm` using
64-bit peer objects and typed aggregate conversion, as described in
`ObjCProxy.md`. Guest `UIScreen` accessors already supplied a virtual phone
canvas for a narrow class of old games. Host `UIKit.mm` already contained
native controller wrappers and a separate main-nib/rootless window path.

The guest's EAGLContext methods forward to the real host EAGLContext. Its
`renderbufferStorage:fromDrawable:` compatibility method normalizes drawable
properties, then allocates real layer-backed storage. `presentRenderbuffer:`
presents that storage through Core Animation. GL viewport and renderbuffer
dimension operations continue through the existing GL dispatcher unchanged.

The small landscape controller canvas had an explicit `MIN(1, scale)` cap.
Removing it permits enlargement to the available scene, while preserving
the same logical canvas and renderer. The main-nib path on devices now also
fits eligible native windows after leaving UIKit's compositor rotation intact.
Rootless portrait windows can use the same window placement as landscape ones.
Existing ownership checks yield to application-authored window transforms.

## Geometry contract

The common `LC32DisplayAspectFitScale` helper computes
`min(viewportWidth / rotatedWidth, viewportHeight / rotatedHeight)` and rejects
nonfinite, zero, or negative geometry. Controllers set a native wrapper's
bounds and center, then apply the existing rotation with a uniform scale.
Guest bounds and descendant transforms remain in logical points. Black,
clipped container backgrounds provide the unused bars. Window placement
accounts for its previous transform so refits do not multiply scales.

For example, a 480x320 canvas in an 874x402-point viewport uses scale 1.25625,
occupies 603x402 points, and has 135.5-point bars on either side. Drawable
pixel density is independent of that presentation scale.

UIKit's hit-testing and `convertPoint:` machinery invert the actual view
hierarchy transform. The existing UITouch bridge forwards `locationInView:`
and `previousLocationInView:` with the requested host view peer and converts
the resulting CGFloat aggregate back to ARM32. No manual touch multiplier or
global GL viewport hook is introduced. As in native UIKit, passing nil to a
touch location method requests window coordinates, not a child view's local
coordinates; callers using that convention still need device validation.

This follows Apple's [UIView transform contract](https://developer.apple.com/documentation/uikit/uiview/transform)
and [layer-backed renderbuffer allocation](https://developer.apple.com/documentation/opengles/eaglcontext/renderbufferstorage(_:from:)).

## Per-game configuration

The same shared bundle helpers run in the host and guest. Settings belong in
the selected game's Info.plist and take effect on a fresh launch:

```xml
<key>LC32DisplayMode</key><string>legacy</string>
<key>LC32LegacyDisplayScale</key><integer>1</integer>
```

`legacy` forces the phone canvas even for portrait, universal, or tall-launch-art
games that conservative detection cannot identify. Use density 1 for fixed
320x480/480x320 pixel renderers; density 2 permits 640x960/960x640 storage.
It is a ceiling, preserving an application's intentional lower density.
Invalid density values default to 2. Missing or unknown mode values behave
like `auto`, retaining the previous metadata and runtime dimension checks.

`native` bypasses all three virtual canvas classifiers, including inferred
iPad canvases and the fixed-landscape runtime probe. Resize-aware games can
then use the native screen and renderbuffer dimensions available to the host
process. It does not override OS/LiveContainer Classic Mode restrictions.
External UIScreen objects retain their native geometry and density.

Just before EAGL storage allocation, `LC32UIKitPrepareLegacyDrawable` caps
the density only for a guest-associated CAEAGLLayer with exact legacy logical
dimensions and an active fixed phone canvas policy. It leaves a 1x request
alone. It never changes a GL framebuffer binding, texture, viewport, scissor,
or an ordinary offscreen renderbuffer. The runtime-only tall-game probe keeps
its original density contract; use explicit legacy mode if that also needs
normalization. Existing global-disable and pre-iOS-8 host policy win.

## Validation

Portable production-helper regression:

```sh
gmake -C test check-display-geometry
```

The test covers aspect fit, centering, round-trip coordinates, up/downscaling,
and invalid geometry. It can also be compiled directly with a C11 compiler
on Windows (`clang test/display_geometry.c -o display_geometry.exe`).

macOS Foundation policy regression:

```sh
gmake -C test check-display-policy
```

Native UIKit contract regression, using an already booted Simulator:

```sh
sh test/uikit_virtual_display.sh --device UDID
```

This creates/removes its own test application, checks UIKit point conversion,
actual hit-test traversal to a control, exclusion of bars, rotation in both
landscape directions, upside-down portrait, retained logical drawable bounds,
and 1x/2x density. It uses the production aspect-fit helper and native wrapper
placement pattern. It is a contract test, not a full emulator integration test.
`--build-only` compiles without installing. CI runs the portable and Foundation
tests in the build job and runs this fixture on an iPhone Simulator in a
separate job, so Simulator startup does not hold the compilation runner.

Device acceptance remains necessary: run Spy Mouse/Veggie Ninja with the
appropriate density, tap controls at all corners, drag across the canvas,
rotate and resume, test rootless/main-nib launch timing, and verify a game with
offscreen passes. Compare a resize-aware game in native mode. No device/game
run should be inferred from the unit or Simulator contract tests.

## Packaging

The existing macOS workflow initializes submodules, installs pinned Theos/SDK
dependencies, generates the ARM32 shims, builds the guest frameworks, assembles
RootFS, and packages the host app with both embedded frameworks. Its normal
IPA recipe uses ldid's ad-hoc signing and requires no personal certificate.
Installation/provisioning is separate from successful compilation.

An isolated branch in a fork can run `Build LiveExec32` with workflow_dispatch;
the release job only runs on main/dev, so feature-branch builds produce workflow
artifacts without updating nightly releases. Both host and guest changes must
be included: replacing only the host framework is insufficient.
