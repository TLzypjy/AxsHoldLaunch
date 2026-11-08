#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "AxsHoldLaunchConfig.h"

// ---------------------------------------------------------------------------
// 窗口光圈/光晕引擎 (port of TrollOpen's glow feature)
//
// 定时扫描 SpringBoard 的窗口，找到 ScreenCore 的浮窗宿主窗口
// (SCFloatingHostWindow*)，在窗口层上维护两圈渐变环:
//   - 光圈外框: 紧贴窗口边缘的渐变环 (彩虹或自定义色)
//   - 窗口光晕: 向外扩散的柔和光晕带
// 设置变化时下一次 tick 自动生效；窗口消失时自动摘除。
// ---------------------------------------------------------------------------

static NSTimer *axs_glowTimer = nil;
static NSMutableDictionary<NSString *, NSMutableArray<CALayer *> *> *axs_glowLayers = nil;
static NSMutableDictionary<NSString *, NSString *> *axs_glowSignature = nil;

@interface AXSGlowEngineTarget : NSObject
+ (instancetype)shared;
- (void)axsGlowTick;
@end

static UIColor *axs_glow_parseHex(NSString *hex, UIColor *fallback) {
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

static NSArray<UIColor *> *axs_glow_rainbow(void) {
    return @[ [UIColor redColor], [UIColor orangeColor], [UIColor yellowColor],
              [UIColor greenColor], [UIColor cyanColor], [UIColor blueColor],
              [UIColor purpleColor], [UIColor redColor] ];
}

static CGFloat axs_glow_contentRadius(UIWindow *window) {
    CGFloat radius = 47.0;
    UIView *root = window.rootViewController.view;
    if (root.layer.cornerRadius > 1) radius = root.layer.cornerRadius;
    for (UIView *sub in root.subviews) {
        if (sub.layer.cornerRadius > 1) { radius = sub.layer.cornerRadius; break; }
    }
    return radius;
}

static CALayer *axs_glow_ringLayer(CGRect bounds, CGFloat radius, CGFloat outerGrow,
                                   NSArray<UIColor *> *colors, BOOL fadeOut) {
    // 渐变环: 外扩 outerGrow 的圆角矩形 与 原圆角矩形 之间的环带 (奇偶填充遮罩)
    CGRect outerRect = CGRectInset(bounds, -outerGrow, -outerGrow);
    UIBezierPath *outerPath = [UIBezierPath bezierPathWithRoundedRect:outerRect
                                         byRoundingCorners:UIRectCornerAllCorners
                                               cornerRadii:CGSizeMake(radius + outerGrow, radius + outerGrow)];
    UIBezierPath *innerPath = [UIBezierPath bezierPathWithRoundedRect:bounds
                                         byRoundingCorners:UIRectCornerAllCorners
                                               cornerRadii:CGSizeMake(radius, radius)];
    [outerPath appendPath:innerPath];

    CAShapeLayer *mask = [CAShapeLayer layer];
    mask.path = outerPath.CGPath;
    mask.fillRule = kCAFillRuleEvenOdd;

    CAGradientLayer *ring = [CAGradientLayer layer];
    ring.frame = outerRect;
    ring.type = kCAGradientLayerConic;
    ring.startPoint = CGPointMake(0.5, 0.5);
    ring.endPoint = CGPointMake(0.5, 0.0);
    ring.mask = mask;

    NSMutableArray *c = [NSMutableArray array];
    NSMutableArray *loc = [NSMutableArray array];
    NSUInteger n = colors.count;
    for (NSUInteger i = 0; i <= n; i++) {
        UIColor *col = colors[i % n];
        CGFloat alpha = 1.0;
        if (fadeOut && n > 0) {
            // 光晕带: 从窗口边缘向外渐隐
            CGFloat t = (CGFloat)i / n;
            alpha = 0.55 * (1.0 - t * t);
        }
        CGFloat r = 0, g = 0, b = 0, a = 0;
        [col getRed:&r green:&g blue:&b alpha:&a];
        [c addObject:(id)[UIColor colorWithRed:r green:g blue:b alpha:alpha].CGColor];
        [loc addObject:@((CGFloat)i / n)];
    }
    ring.colors = c;
    ring.locations = loc;
    return ring;
}

static void axs_glow_applyToWindow(UIWindow *window, AxsHoldLaunchConfig *config) {
    NSString *key = [NSString stringWithFormat:@"%p", window];
    CGRect bounds = window.bounds;
    CGFloat radius = axs_glow_contentRadius(window);

    BOOL frameOn = [config axs_holdlaunch_glowFrameEnabled];
    BOOL haloOn = [config axs_holdlaunch_glowHaloEnabled];

    if (!frameOn && !haloOn) {
        for (CALayer *l in axs_glowLayers[key]) { [l removeFromSuperlayer]; }
        [axs_glowLayers removeObjectForKey:key];
        [axs_glowSignature removeObjectForKey:key];
        return;
    }

    // 生成签名: 帧圆角+颜色+开关 任一变化才重建
    UIColor *frameCol = [config axs_holdlaunch_glowFrameCustom]
        ? axs_glow_parseHex([config axs_holdlaunch_glowFrameColor], [UIColor colorWithRed:0.2 green:0.63 blue:1.0 alpha:1.0])
        : nil;
    UIColor *haloCol = [config axs_holdlaunch_glowHaloCustom]
        ? axs_glow_parseHex([config axs_holdlaunch_glowHaloColor], [UIColor whiteColor])
        : nil;
    NSString *sig = [NSString stringWithFormat:@"%.0f,%.0f,%.0f,%.0f,%.0f,%d,%d,%@,%d,%d,%@",
                     bounds.origin.x, bounds.origin.y, bounds.size.width, bounds.size.height,
                     radius, frameOn, [config axs_holdlaunch_glowFrameCustom],
                     frameCol ?: @"", haloOn && [config axs_holdlaunch_glowHaloCustom],
                     haloOn && [config axs_holdlaunch_glowHaloCustom], haloCol ?: @""];
    if ([axs_glowSignature[key] isEqualToString:sig]) return;
    axs_glowSignature[key] = sig;

    for (CALayer *l in axs_glowLayers[key]) { [l removeFromSuperlayer]; }
    NSMutableArray<CALayer *> *layers = [NSMutableArray array];

    if (haloOn) {
        NSArray<UIColor *> *haloColors = haloCol ? @[haloCol, haloCol] : @[[UIColor whiteColor], [UIColor whiteColor]];
        CALayer *halo = axs_glow_ringLayer(bounds, radius, 16.0, haloColors, YES);
        [window.layer addSublayer:halo];
        [layers addObject:halo];
    }
    if (frameOn) {
        NSArray<UIColor *> *frameColors = frameCol ? @[frameCol, frameCol]
                                                   : axs_glow_rainbow();
        CALayer *ring = axs_glow_ringLayer(bounds, radius, 3.0, frameColors, NO);
        [window.layer addSublayer:ring];
        [layers addObject:ring];
    }

    [axs_glowLayers setObject:layers forKey:key];
    objc_setAssociatedObject(window, @selector(axsGlowLayersKey), layers, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void axs_glow_tick(void) {
    @try {
        AxsHoldLaunchConfig *config = [AxsHoldLaunchConfig axs_holdlaunch_shared];
        if (axs_glowLayers == nil) {
            axs_glowLayers = [NSMutableDictionary new];
            axs_glowSignature = [NSMutableDictionary new];
        }

        NSMutableSet<NSString *> *seen = [NSMutableSet set];
        NSArray<UIScene *> *scenes = [UIApplication sharedApplication].connectedScenes.allObjects;
        for (UIScene *scene in scenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *window in ((UIWindowScene *)scene).windows) {
                NSString *cls = NSStringFromClass(window.class);
                if (![cls hasPrefix:@"SCFloating"]) continue;
                NSString *key = [NSString stringWithFormat:@"%p", window];
                [seen addObject:key];
                if (window.hidden) {
                    for (CALayer *l in axs_glowLayers[key]) { [l removeFromSuperlayer]; }
                    continue;
                }
                axs_glow_applyToWindow(window, config);
            }
        }

        // 清理已消失窗口的图层
        for (NSString *key in axs_glowLayers.allKeys.copy) {
            if (![seen containsObject:key]) {
                for (CALayer *l in axs_glowLayers[key]) { [l removeFromSuperlayer]; }
                [axs_glowLayers removeObjectForKey:key];
                [axs_glowSignature removeObjectForKey:key];
            }
        }
    } @catch (NSException *exception) {
        // 引擎异常不能拖垮 SpringBoard
    }
}

static void axs_glow_start(void) {
    if (axs_glowTimer) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (axs_glowTimer) return;
        axs_glowTimer = [NSTimer timerWithTimeInterval:0.5
                                                target:[AXSGlowEngineTarget shared]
                                              selector:@selector(axsGlowTick)
                                              userInfo:nil
                                               repeats:YES];
        [[NSRunLoop mainRunLoop] addTimer:axs_glowTimer forMode:NSRunLoopCommonModes];
    });
}

@implementation AXSGlowEngineTarget
+ (instancetype)shared {
    static AXSGlowEngineTarget *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [self new]; });
    return shared;
}
- (void)axsGlowTick { axs_glow_tick(); }
@end

// expose to Main.xm via C symbol
void axs_glow_engine_start(void) {
    axs_glow_start();
}
