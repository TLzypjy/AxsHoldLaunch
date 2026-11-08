#pragma once

#import <Foundation/Foundation.h>

@interface AxsHoldLaunchConfig : NSObject
+ (instancetype)axs_holdlaunch_shared;
- (BOOL)axs_holdlaunch_isEnabled;
- (double)axs_holdlaunch_threshold;
- (BOOL)axs_holdlaunch_reverse;
- (BOOL)axs_holdlaunch_glowFrameEnabled;
- (BOOL)axs_holdlaunch_glowFrameCustom;
- (NSString *)axs_holdlaunch_glowFrameColor;
- (BOOL)axs_holdlaunch_glowHaloEnabled;
- (BOOL)axs_holdlaunch_glowHaloCustom;
- (NSString *)axs_holdlaunch_glowHaloColor;
- (id)axs_holdlaunch_valueForKey:(NSString *)key defaultValue:(id)defaultValue;
- (void)axs_holdlaunch_reload;
@end
