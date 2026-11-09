#pragma once

#import <Foundation/Foundation.h>

@interface AxsHoldLaunchConfig : NSObject
+ (instancetype)axs_holdlaunch_shared;

// hold-launch (our own domain)
- (BOOL)axs_holdlaunch_isEnabled;
- (double)axs_holdlaunch_threshold;
- (BOOL)axs_holdlaunch_reverse;

// ScreenCore 原装域 (com.susudear.screencoreprefs) 快照：设置页的
// 美化行通过通用读取拿值（颜色圆圈等），写入走 specifier 自带的域
- (NSDictionary *)axs_holdlaunch_theirSnapshot;
- (id)axs_holdlaunch_theirValueForKey:(NSString *)key defaultValue:(id)defaultValue;
- (id)axs_holdlaunch_valueForKey:(NSString *)key defaultValue:(id)defaultValue;
- (void)axs_holdlaunch_reload;

// 美化 · 光圈外框（原装域）
- (BOOL)axs_holdlaunch_bfFrameEnabled;      // splitWindowRingFrameEnabled
- (BOOL)axs_holdlaunch_bfCustomEnabled;     // splitWindowRingFrameCustomEnabled
- (NSString *)axs_holdlaunch_bfFrameColor;  // splitWindowRingFrameColor
- (double)axs_holdlaunch_bfFrameWidth;      // splitWindowRingFrameWidth（边框粗细）
@end
