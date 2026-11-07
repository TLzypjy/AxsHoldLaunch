#pragma once

#import <UIKit/UIKit.h>

// Declare only private interfaces confirmed on the target iOS version.

#ifdef __cplusplus
extern "C" {
#endif

// MobileSubstrate (linked via -lsubstrate).
void MSHookMessageEx(Class _class, SEL message, IMP hook, IMP *old);

#ifdef __cplusplus
}
#endif

// ScreenCore hook targets (classes are discovered at runtime in SpringBoard;
// only the selectors are known statically from the unstripped binary).
#define AxsHoldLaunchSelUpdateSelection     @"sc_updateSelectionAtPoint:"
#define AxsHoldLaunchSelSetSelectedBundle   @"setSelectedBundleIdentifier:"
#define AxsHoldLaunchSelHandleSelected      @"sc_handleSelectedBundleIdentifier:sourceFrame:"
#define AxsHoldLaunchSelOpenTarget          @"sc_openTargetIdentifier:transitionContext:presentationSourceRect:gestureProfile:launchFullscreen:"
#define AxsHoldLaunchSelFinishTracking      @"sc_finishTracking"

// PreferenceBuilder (Settings process only).
@interface PSSpecifier : NSObject
+ (instancetype)preferenceSpecifierNamed:(NSString *)name target:(id)target set:(SEL)set get:(SEL)get detail:(id)detail cell:(NSInteger)cell edit:(id)edit;
- (void)setProperty:(id)property forKey:(NSString *)key;
- (id)propertyForKey:(NSString *)key;
- (id)identifier;
- (void)setIdentifier:(id)identifier;
@end

@interface PSListController : UIViewController
@end
