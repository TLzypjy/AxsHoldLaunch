#pragma once

#import <Foundation/Foundation.h>

@interface AxsHoldLaunchConfig : NSObject
+ (instancetype)axs_holdlaunch_shared;
- (BOOL)axs_holdlaunch_isEnabled;
- (double)axs_holdlaunch_threshold;
- (BOOL)axs_holdlaunch_reverse;
- (BOOL)axs_holdlaunch_isAutoCloseEnabled;
- (id)axs_holdlaunch_valueForKey:(NSString *)key defaultValue:(id)defaultValue;
- (void)axs_holdlaunch_reload;
@end
