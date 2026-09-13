#import "../include/LC32LegacyCanvas.h"
#include <assert.h>
#include <stdio.h>

@interface DisplayBundle : NSBundle
@property(nonatomic, copy) NSDictionary *testInfo;
@property(nonatomic, copy) NSSet *art;
@end
@implementation DisplayBundle
- (NSDictionary *)infoDictionary { return self.testInfo; }
- (NSString *)pathForResource:(NSString *)name ofType:(NSString *)type {
    (void)type;
    return [self.art containsObject:name] ? name : nil;
}
@end

int main(void) {
    @autoreleasepool {
        DisplayBundle *bundle = [DisplayBundle new];
        NSMutableDictionary *info = [@{
            @"UIDeviceFamily": @[@1],
            @"UIInterfaceOrientation": @"UIInterfaceOrientationLandscapeRight"
        } mutableCopy];
        bundle.testInfo = info;
        bundle.art = [NSSet setWithObject:@"Default"];
        assert(LC32BundleUsesFixedLandscapePhoneCanvas(bundle, 0x40000));
        assert(!LC32BundleUsesFixedLandscapePhoneCanvas(bundle, 0x90000));
        bundle.art = [NSSet setWithObjects:@"Default", @"Default-568h@2x", nil];
        assert(!LC32BundleUsesFixedLandscapePhoneCanvas(bundle, 0x60000));
        assert(LC32BundleMayRetainLegacyLandscapePhoneCanvas(bundle, 0x60000));
        info[@"LC32DisplayMode"] = @"native";
        bundle.testInfo = info;
        assert(!LC32BundleUsesFixedLandscapePhoneCanvas(bundle, 0x40000));
        assert(!LC32BundleMayRetainLegacyLandscapePhoneCanvas(bundle, 0x60000));
        info[@"LC32DisplayMode"] = @"legacy";
        info[@"UIDeviceFamily"] = @[@1, @2];
        info[@"UIInterfaceOrientation"] = @"UIInterfaceOrientationPortrait";
        bundle.testInfo = info;
        assert(LC32BundleUsesFixedLandscapePhoneCanvas(bundle, 0x90000));
        assert(!LC32BundleNeedsLegacyIPadCanvas(bundle, 0x40000));
        assert(!LC32BundleMayRetainLegacyLandscapePhoneCanvas(bundle, 0x60000));
        assert(LC32BundleLegacyDisplayScale(bundle) == 2);
        for(id value in @[@1, @2, @3, @0, @-1, @"1"]) {
            info[@"LC32LegacyDisplayScale"] = value;
            bundle.testInfo = info;
            assert(LC32BundleLegacyDisplayScale(bundle) ==
                ([value isEqual:@1] ? 1u : 2u));
        }
        [info removeObjectForKey:@"LC32DisplayMode"];
        info[@"UIStatusBarHidden"] = @YES;
        bundle.testInfo = info;
        bundle.art = [NSSet set];
        assert(LC32BundleMayUseLegacyPhoneDrawable(bundle, 0x40000));
        assert(!LC32BundleMayUseLegacyPhoneDrawable(bundle, 0x80000));
        info[@"LC32DisplayMode"] = @"native";
        bundle.testInfo = info;
        assert(!LC32BundleMayUseLegacyPhoneDrawable(bundle, 0x40000));
        [info removeObjectForKey:@"LC32DisplayMode"];
        info[@"UIStatusBarHidden"] = @NO;
        bundle.testInfo = info;
        assert(!LC32BundleMayUseLegacyPhoneDrawable(bundle, 0x40000));
        puts("legacy display policy: PASS");
    }
    return 0;
}
