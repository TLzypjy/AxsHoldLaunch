#pragma once

#import <Foundation/Foundation.h>

@interface AxsHoldLaunchConfig : NSObject
+ (instancetype)axs_holdlaunch_shared;

// hold-launch (our own domain)
- (BOOL)axs_holdlaunch_isEnabled;
- (double)axs_holdlaunch_threshold;
- (BOOL)axs_holdlaunch_reverse;

// ScreenCore 原装域 (com.susudear.screencoreprefs) 快照
- (NSDictionary *)axs_holdlaunch_theirSnapshot;
- (id)axs_holdlaunch_theirValueForKey:(NSString *)key defaultValue:(id)defaultValue;
- (id)axs_holdlaunch_valueForKey:(NSString *)key defaultValue:(id)defaultValue;
- (void)axs_holdlaunch_reload;

// 应用组
- (BOOL)axs_holdlaunch_isTheirRingEnabled;      // splitWindowRingEnabled 浮窗光圈
- (BOOL)axs_holdlaunch_isTheirMiniRingEnabled;  // splitMiniWindowRingEnabled 小窗光圈
- (NSArray *)axs_holdlaunch_ringExcludedApplications;
- (double)axs_holdlaunch_splitWindowCornerRadius;

// 外框组
- (double)axs_holdlaunch_ringFrameWidth;        // splitWindowRingFrameWidth 0-30
- (double)axs_holdlaunch_ringFrameAlpha;        // splitWindowRingFrameAlpha 0-1
- (double)axs_holdlaunch_ringFrameCornerRadius; // splitWindowRingCornerRadius 0=auto, 1-60 manual
- (BOOL)axs_holdlaunch_ringFrameCustomEnabled;  // splitWindowRingFrameCustomEnabled
- (NSString *)axs_holdlaunch_ringFrameColor;    // splitWindowRingFrameColor
- (BOOL)axs_holdlaunch_ringFrameRandomColor;    // splitWindowRingFrameRandomColor

// 光晕组（光晕与外框同色，见引擎）
- (BOOL)axs_holdlaunch_ringGlowEnabled;         // splitWindowGlowEnabled
- (double)axs_holdlaunch_ringGlowRange;         // splitWindowGlowRange 0-50
- (double)axs_holdlaunch_ringGlowOffsetY;       // splitWindowGlowOffsetY -50..50
- (double)axs_holdlaunch_ringGlowOffsetX;       // splitWindowGlowOffsetX -50..50

// 内圈组
- (BOOL)axs_holdlaunch_ringInnerEnabled;        // splitWindowRingInnerEnabled
- (BOOL)axs_holdlaunch_ringInnerCustomEnabled;  // splitWindowRingInnerCustomEnabled
- (double)axs_holdlaunch_ringInnerWidth;        // splitWindowRingInnerWidth 1-30
- (NSString *)axs_holdlaunch_ringInnerColor;    // splitWindowRingInnerColor
- (BOOL)axs_holdlaunch_ringInnerRandomColor;    // splitWindowRingInnerRandomColor
@end
