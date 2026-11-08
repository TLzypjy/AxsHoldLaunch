#pragma once

#import <Foundation/Foundation.h>

@interface AxsHoldLaunchConfig : NSObject
+ (instancetype)axs_holdlaunch_shared;
- (BOOL)axs_holdlaunch_isEnabled;
- (double)axs_holdlaunch_threshold;
- (BOOL)axs_holdlaunch_reverse;

// ScreenCore 原装域 (com.susudear.screencoreprefs) 的光圈设置快照
- (BOOL)axs_holdlaunch_isTheirRingEnabled;
- (BOOL)axs_holdlaunch_isTheirMiniRingEnabled;
- (BOOL)axs_holdlaunch_isTheirRingCustomEnabled;
- (NSString *)axs_holdlaunch_isTheirRingColor;
- (BOOL)axs_holdlaunch_isTheirGlowEnabled;
- (BOOL)axs_holdlaunch_isTheirGlowCustomEnabled;
- (NSString *)axs_holdlaunch_isTheirGlowColor;
- (NSArray *)axs_holdlaunch_ringExcludedApplications;
- (double)axs_holdlaunch_splitWindowCornerRadius;
- (NSDictionary *)axs_holdlaunch_theirSnapshot;
- (id)axs_holdlaunch_theirValueForKey:(NSString *)key defaultValue:(id)defaultValue;
- (id)axs_holdlaunch_valueForKey:(NSString *)key defaultValue:(id)defaultValue;
- (void)axs_holdlaunch_reload;
@end
