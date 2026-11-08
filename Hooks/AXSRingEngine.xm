#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "AxsHoldLaunchConfig.h"

// ---------------------------------------------------------------------------
// 浮窗光圈/光晕引擎
//
// 单个共享透明 overlay UIWindow，每个浮窗会话一组层:
//   - 光圈: CAShapeLayer 1pt 圆角矩形细描边 (fillColor = nil)，
//     圆角实时取 splitWindowCornerRadius 当前值
//   - 光晕: 同路径宽描边 (6pt) 低透明
// zPosition 跟随宿主窗口层级。显示链接逐帧只做 frame 比较、可见性比较、
// 缓存的排除判定读取；变化时在 CATransaction(禁用隐式动画) 里更新 path，
// 不重建 layer。连续空闲自动停掉显示链接，钩子事件再拉起。
// ---------------------------------------------------------------------------

static UIWindow *axs_ringWindow = nil;
static BOOL axs_ringWindowLoggedGone = NO;
static NSMutableDictionary<NSString *, NSMutableArray<CALayer *> *> *axs_ringLayers = nil;
static NSMutableDictionary<NSString *, NSString *> *axs_ringFrameSig = nil;
static NSMutableDictionary<NSString *, NSString *> *axs_ringExcludedCache = nil;
static NSMutableDictionary<NSString *, NSString *> *axs_containerBundle = nil;   // containerKey -> bundle
static NSMutableDictionary<NSString *, NSString *> *axs_sessionBundle = nil;     // sessionKey  -> bundle
static CADisplayLink *axs_ringLink = nil;
static int axs_ringIdleFrames = 0;

static void axs_ring_engine_log(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
static void axs_ring_engine_log(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSLog(@"[AxsHoldLaunch:Ring] %@", message);

    NSString *path = @"/var/mobile/Library/Caches/AxsHoldLaunch.log";
    @try {
        NSString *line = [NSString stringWithFormat:@"%.3f %@\n",
                          [[NSDate date] timeIntervalSince1970], message];
        NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
        if (handle == nil) {
            [line writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
        } else {
            [handle seekToEndOfFile];
            [handle writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
            [handle closeFile];
        }
    } @catch (NSException *exception) {
        // 日志异常不能拖垮 SpringBoard
    }
}

static UIColor *axs_ring_parseHex(NSString *hex, UIColor *fallback) {
    if (![hex isKindOfClass:[NSString class]] || hex.length == 0) return fallback;
    NSString *h = [[hex stringByReplacingOccurrencesOfString:@"#" withString:@""] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (h.length == 6 || h.length == 8) {
        unsigned int v = 0;
        NSScanner *scanner = [NSScanner scannerWithString:h];
        [scanner scanHexInt:&v];
        if (h.length == 6) v = (v << 8) | 0xFF;
        return [UIColor colorWithRed:((v >> 24) & 0xFF) / 255.0
                               green:((v >> 16) & 0xFF) / 255.0
                                blue:((v >> 8) & 0xFF) / 255.0
                               alpha:(v & 0xFF) / 255.0];
    }
    return fallback;
}

#pragma mark - C API (Main.xm 的钩子喂数据，全部签名安全)

void axs_ring_setSessionBundle(id session, NSString *bundle) {
    if (session == nil || ![bundle isKindOfClass:[NSString class]]) return;
    if (axs_sessionBundle == nil) axs_sessionBundle = [NSMutableDictionary new];
    NSString *key = [NSString stringWithFormat:@"%p", session];
    NSString *old = axs_sessionBundle[key];
    if ([old isEqualToString:bundle]) return;
    axs_sessionBundle[key] = bundle;
}

void axs_ring_noteContainerForSession(id container, id session) {
    if (container == nil || session == nil) return;
    if (axs_containerBundle == nil) axs_containerBundle = [NSMutableDictionary new];
    NSString *ck = [NSString stringWithFormat:@"%p", container];
    NSString *sk = [NSString stringWithFormat:@"%p", session];
    NSString *bundle = axs_sessionBundle[sk];
    if (bundle.length == 0) return;
    NSString *old = axs_containerBundle[ck];
    if ([old isEqualToString:bundle]) return;
    // App 切换: 会话承载的 App 变了，排除判定缓存立刻失效
    axs_containerBundle[ck] = bundle;
    if (axs_containerExcluded != nil) [axs_containerExcluded removeObjectForKey:ck];
}

void axs_ring_sessionClosed(id session) {
    if (session == nil) return;
    if (axs_sessionBundle == nil || axs_containerBundle == nil) return;
    NSString *sk = [NSString stringWithFormat:@"%p", session];
    NSString *bundle = axs_sessionBundle[sk];
    for (NSString *ck in axs_containerBundle.allKeys.copy) {
        if (bundle != nil && ![axs_containerBundle[ck] isEqualToString:bundle]) continue;
        NSMutableArray<CALayer *> *layers = axs_ringLayers[ck];
        if (layers.count > 0) {
            // 跟随关闭动画淡出，无残留
            [CATransaction begin];
            [CATransaction setAnimationDuration:0.25];
            for (CALayer *l in layers) { l.opacity = 0.0; }
            [CATransaction setCompletionBlock:^{
                for (CALayer *l in layers) { [l removeFromSuperlayer]; }
            }];
            [CATransaction commit];
        }
        [axs_ringLayers removeObjectForKey:ck];
        [axs_ringFrameSig removeObjectForKey:ck];
        [axs_ringExcludedCache removeObjectForKey:ck];
        [axs_containerBundle removeObjectForKey:ck];
    }
    [axs_sessionBundle removeObjectForKey:sk];
}

void axs_ring_sessionDocked(id session) {
    // 挂起: 主环隐藏交给显示链接的可见性检查 (容器被 ScreenCore 隐藏)；
    // 侧贴小窗的环由显示链接扫描 SCDockedFloatingItemView 按「小窗光圈」绘制。
}

void axs_ring_configChanged(void) {
    // 排除名单/颜色/开关变化: 排除判定缓存失效，下一帧重算
    if (axs_containerExcluded != nil) [axs_containerExcluded removeAllObjects];
}

void axs_ring_engine_wake(void) {
    // 钩子事件驱动: 有会话活动才保证显示链接在跑
    if (axs_ringLink != nil) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (axs_ringLink != nil) return;
        axs_ringLink = [CADisplayLink displayLinkWithTarget:[AXSRingEngineTarget shared]
                                                   selector:@selector(axsRingTick)];
        [axs_ringLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
        axs_ring_engine_log(@"ring engine display link started");
    });
}

#pragma mark - 引擎内部

static UIWindow *axs_ring_ensureOverlayWindow(CGFloat hostLevel) {
    if (axs_ringWindow != nil) {
        axs_ringWindow.windowLevel = hostLevel + 1;
        return axs_ringWindow;
    }
    axs_ringWindow = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    axs_ringWindow.windowLevel = hostLevel + 1;
    axs_ringWindow.userInteractionEnabled = NO;
    axs_ringWindow.opaque = NO;
    axs_ringWindow.backgroundColor = [UIColor clearColor];
    axs_ringWindow.rootViewController = [UIViewController new];
    axs_ringWindow.hidden = NO;
    axs_ring_engine_log(@"ring overlay window created, level=%.0f (above hosts, below status bar)",
                        axs_ringWindow.windowLevel);
    return axs_ringWindow;
}

static UIView *axs_ring_findContainer(UIView *root, int depth) {
    if (depth > 14) return nil;
    if ([NSStringFromClass(root.class) isEqualToString:@"SCFloatingContainerView"]) return root;
    for (UIView *sub in root.subviews) {
        UIView *found = axs_ring_findContainer(sub, depth + 1);
        if (found) return found;
    }
    return nil;
}

static UIView *axs_ring_findDockedItem(UIView *root, int depth) {
    if (depth > 14) return nil;
    if ([NSStringFromClass(root.class) isEqualToString:@"SCDockedFloatingItemView"]) return root;
    for (UIView *sub in root.subviews) {
        UIView *found = axs_ring_findDockedItem(sub, depth + 1);
        if (found) return found;
    }
    return nil;
}

static BOOL axs_ring_bundleExcluded(NSString *bundle, AxsHoldLaunchConfig *config) {
    if (bundle.length == 0) return NO;
    NSArray *list = [config axs_holdlaunch_ringExcludedApplications];
    for (NSString *b in list) {
        if ([b isEqualToString:bundle]) return YES;
    }
    return NO;
}

// 为一个浮窗容器创建/同步它的环 + 光晕 (挂在共享 overlay window 里)
static void axs_ring_syncContainer(UIView *container, UIWindow *hostWindow, AxsHoldLaunchConfig *config) {
    NSString *ck = [NSString stringWithFormat:@"%p", container];
    CGFloat level = hostWindow ? hostWindow.windowLevel : 1000.0;

    NSString *bundle = axs_containerBundle[ck] ?: @"";
    NSNumber *cachedExcluded = axs_containerExcluded[ck];
    BOOL excluded;
    if (cachedExcluded != nil) {
        excluded = [cachedExcluded boolValue];      // 每帧只读缓存
    } else {
        excluded = axs_ring_bundleExcluded(bundle, config);  // 判定一次并缓存
        axs_containerExcluded[ck] = @(excluded);
        axs_ring_engine_log(@"ring exclusion cached: bundle=%@ excluded=%d", bundle, excluded);
    }

    BOOL floatingOn = [config axs_holdlaunch_isTheirRingEnabled];
    BOOL wantRings = floatingOn && !excluded;

    NSMutableArray<CALayer *> *layers = axs_ringLayers[ck];
    if (!wantRings) {
        for (CALayer *l in layers) { [l removeFromSuperlayer]; }
        [axs_ringLayers removeObjectForKey:ck];
        [axs_ringFrameSig removeObjectForKey:ck];
        return;
    }

    BOOL custom = [config axs_holdlaunch_isTheirRingCustomEnabled];
    UIColor *ringColor = custom
        ? axs_ring_parseHex([config axs_holdlaunch_isTheirRingColor], [UIColor colorWithRed:0.2 green:0.63 blue:1.0 alpha:1.0])
        : [UIColor colorWithRed:0.2 green:0.63 blue:1.0 alpha:1.0];
    BOOL glowOn = [config axs_holdlaunch_isTheirGlowEnabled];
    BOOL glowCustom = [config axs_holdlaunch_isTheirGlowCustomEnabled];
    UIColor *glowColor = glowCustom
        ? axs_ring_parseHex([config axs_holdlaunch_isTheirGlowColor], [UIColor whiteColor])
        : [UIColor whiteColor];
    CGFloat radius = [config axs_holdlaunch_splitWindowCornerRadius];

    CGRect frame = container.frame;
    NSString *fsig = [NSString stringWithFormat:@"%.0f,%.0f,%.0f,%.0f,%.0f,%@,%d,%d,%@",
                      frame.origin.x, frame.origin.y, frame.size.width, frame.size.height,
                      radius, bundle, custom, glowOn, glowCustom, glowColor ?: @""];

    NSMutableArray<CALayer *> *layers = axs_ringLayers[ck];
    if (layers == nil || ![axs_ringStyleSig[ck] isEqualToString:fsig]) {
        // (重)建: 每会话一组层，复用已存在的层对象
        for (CALayer *l in layers) { [l removeFromSuperlayer]; }
        layers = [NSMutableArray array];

        UIWindow *overlay = axs_ring_ensureOverlayWindow(level);
        UIView *overlayRoot = overlay.rootViewController.view;
        CGRect screenFrame = [container convertRect:container.bounds toView:overlayRoot];

        // 光圈: 1pt 细描边
        CAShapeLayer *ring = [CAShapeLayer layer];
        UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:screenFrame
                                     byRoundingCorners:UIRectCornerAllCorners
                                           cornerRadii:CGSizeMake(radius, radius)];
        ring.path = path.CGPath;
        ring.strokeColor = ringColor.CGColor;
        ring.fillColor = nil;
        ring.lineWidth = 1.0;
        ring.zPosition = level;
        [overlayRoot.layer addSublayer:ring];
        [layers addObject:ring];

        // 光晕: 同路径宽描边低透明
        if (glowOn) {
            CAShapeLayer *glow = [CAShapeLayer layer];
            glow.path = path.CGPath;
            glow.strokeColor = glowColor.CGColor;
            glow.fillColor = nil;
            glow.lineWidth = 6.0;
            glow.opacity = 0.35;
            glow.zPosition = level;
            [overlayRoot.layer addSublayer:glow];
            [layers addObject:glow];
        }

        axs_ringLayers[ck] = layers;
        axs_ringStyleSig[ck] = fsig;
        axs_ringFrameSig[ck] = nil;
        return;
    }

    // 已存在: frame 变化时只在 CATransaction(禁用隐式动画) 里更新 path
    if (![axs_ringFrameSig[ck] isEqualToString:fsig]) {
        UIWindow *overlay = axs_ring_ensureOverlayWindow(level);
        UIView *overlayRoot = overlay.rootViewController.view;
        CGRect screenFrame = [container convertRect:container.bounds toView:overlayRoot];
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        for (CALayer *l in layers) {
            if (![l isKindOfClass:[CAShapeLayer class]]) continue;
            CAShapeLayer *shape = (CAShapeLayer *)l;
            UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:screenFrame
                                         byRoundingCorners:UIRectCornerAllCorners
                                               cornerRadii:CGSizeMake(radius, radius)];
            shape.path = path.CGPath;
            shape.zPosition = level;
        }
        [CATransaction commit];
        axs_ringFrameSig[ck] = fsig;
    }
}

static void axs_ring_syncMiniRing(UIView *docked, AxsHoldLaunchConfig *config) {
    NSString *dk = [NSString stringWithFormat:@"%p", docked];
    BOOL miniOn = [config axs_holdlaunch_isTheirMiniRingEnabled];
    NSMutableArray<CALayer *> *layers = axs_ringLayers[dk];
    if (!miniOn) {
        for (CALayer *l in layers) { [l removeFromSuperlayer]; }
        [axs_ringLayers removeObjectForKey:dk];
        [axs_ringFrameSig removeObjectForKey:dk];
        return;
    }

    BOOL custom = [config axs_holdlaunch_isTheirRingCustomEnabled];
    UIColor *ringColor = custom
        ? axs_ring_parseHex([config axs_holdlaunch_isTheirRingColor], [UIColor colorWithRed:0.2 green:0.63 blue:1.0 alpha:1.0])
        : [UIColor colorWithRed:0.2 green:0.63 blue:1.0 alpha:1.0];

    CGRect frame = docked.frame;
    CGFloat radius = docked.layer.cornerRadius;
    if (radius < 1) radius = 14.0;
    NSString *fsig = [NSString stringWithFormat:@"%.0f,%.0f,%.0f,%.0f,%.0f",
                      frame.origin.x, frame.origin.y, frame.size.width, frame.size.height, radius];
    if (layers != nil && [axs_ringFrameSig[dk] isEqualToString:fsig]) return;

    for (CALayer *l in layers) { [l removeFromSuperlayer]; }
    layers = [NSMutableArray array];
    UIWindow *overlay = axs_ring_ensureOverlayWindow(1000);
    UIView *overlayRoot = overlay.rootViewController.view;
    CGRect screenFrame = [docked convertRect:docked.bounds toView:overlayRoot];
    CAShapeLayer *ring = [CAShapeLayer layer];
    UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:screenFrame
                                 byRoundingCorners:UIRectCornerAllCorners
                                       cornerRadii:CGSizeMake(radius, radius)];
    ring.path = path.CGPath;
    ring.strokeColor = ringColor.CGColor;
    ring.fillColor = nil;
    ring.lineWidth = 1.0;
    [overlayRoot.layer addSublayer:ring];
    [layers addObject:ring];
    axs_ringLayers[dk] = layers;
    axs_ringFrameSig[dk] = fsig;
}

static void axs_ring_tick(void) {
    @try {
        AxsHoldLaunchConfig *config = [AxsHoldLaunchConfig axs_holdlaunch_shared];
        if (axs_ringLayers == nil) {
            axs_ringLayers = [NSMutableDictionary new];
            axs_ringFrameSig = [NSMutableDictionary new];
            axs_ringExcludedCache = [NSMutableDictionary new];
            axs_containerBundle = [NSMutableDictionary new];
            axs_sessionBundle = [NSMutableDictionary new];
        }

        BOOL floatingOn = [config axs_holdlaunch_isTheirRingEnabled];
        BOOL miniOn = [config axs_holdlaunch_isTheirMiniRingEnabled];

        NSMutableSet<NSString *> *seen = [NSMutableSet set];
        NSUInteger hostLevel = 1000;
        NSUInteger ringCount = 0;

        if (floatingOn || miniOn) {
            NSArray<UIScene *> *scenes = [UIApplication sharedApplication].connectedScenes.allObjects;
            for (UIScene *scene in scenes) {
                if (![scene isKindOfClass:[UIWindowScene class]]) continue;
                UIWindowScene *ws = (UIWindowScene *)scene;
                for (UIWindow *window in ws.windows) {
                    if (window.hidden || window == axs_ringWindow) continue;
                    if ((NSUInteger)window.windowLevel > hostLevel) hostLevel = (NSUInteger)window.windowLevel;

                    UIView *container = axs_ring_findContainer(window.rootViewController.view ?: window, 0);
                    if (container != nil && container.window != nil && !container.hidden
                        && container.alpha > 0.01 && container.frame.size.width > 60) {
                        NSString *ck = [NSString stringWithFormat:@"%p", container];
                        [seen addObject:ck];
                        if (floatingOn) {
                            ringCount++;
                            axs_ring_syncContainer(container, window, config);
                        } else {
                            for (CALayer *l in axs_ringLayers[ck]) { [l removeFromSuperlayer]; }
                            [axs_ringLayers removeObjectForKey:ck];
                        }
                    }

                    if (miniOn) {
                        UIView *docked = axs_ring_findDockedItem(window.rootViewController.view ?: window, 0);
                        if (docked != nil && docked.window != nil && !docked.hidden
                            && docked.frame.size.width > 20) {
                            NSString *dk = [NSString stringWithFormat:@"docked-%p", docked];
                            [seen addObject:dk];
                            ringCount++;
                            axs_ring_syncMiniRing(docked, config);
                        }
                    }
                }
            }
        }

        // 清理已消失容器的环
        for (NSString *ck in axs_ringLayers.allKeys.copy) {
            if (![seen containsObject:ck]) {
                for (CALayer *l in axs_ringLayers[ck]) { [l removeFromSuperlayer]; }
                [axs_ringLayers removeObjectForKey:ck];
                [axs_ringFrameSig removeObjectForKey:ck];
                [axs_ringExcludedCache removeObjectForKey:ck];
            }
        }

        // overlay window 生命周期: 有环才存在，全关时归零 (日志证明)
        if (ringCount > 0) {
            axs_ring_ensureOverlayWindow((CGFloat)hostLevel);
            axs_ringWindow.hidden = NO;
            axs_ringWindowLoggedGone = NO;
        } else if (axs_ringWindow != nil) {
            axs_ringWindow.hidden = YES;
            if (!axs_ringWindowLoggedGone) {
                axs_ringWindowLoggedGone = YES;
                axs_ring_engine_log(@"ring overlay window count = 0 (all ring features off or no windows)");
            }
        }

        // 需求 5.1: 没有任何窗口时不起定时器 —— 连续空闲帧后停掉显示链接，
        // 钩子事件 (axs_ring_engine_wake) 会在下次会话活动时重新拉起。
        if (ringCount == 0 && axs_ringLayers.count == 0) {
            axs_ringIdleFrames++;
            if (axs_ringIdleFrames >= 10) {
                axs_ring_engine_log(@"ring engine idle, display link stopped (window count 0)");
                [axs_ringLink invalidate];
                axs_ringLink = nil;
                axs_ringIdleFrames = 0;
            }
        } else {
            axs_ringIdleFrames = 0;
        }
    } @catch (NSException *exception) {
        // 引擎异常不能拖垮 SpringBoard
    }
}

@interface AXSRingEngineTarget : NSObject
+ (instancetype)shared;
- (void)axsRingTick;
@end

static void axs_ring_engine_start(void) {
    if (axs_ringLink) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (axs_ringLink) return;
        axs_ringLink = [CADisplayLink displayLinkWithTarget:[AXSRingEngineTarget shared]
                                                   selector:@selector(axsRingTick)];
        [axs_ringLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
        axs_ring_engine_log(@"ring engine display link started");
    });
}

@implementation AXSRingEngineTarget
+ (instancetype)shared {
    static AXSRingEngineTarget *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [self new]; });
    return shared;
}
- (void)axsRingTick { axs_ring_tick(); }
@end
