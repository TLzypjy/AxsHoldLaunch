#import <UIKit/UIKit.h>
#import "AxsHoldLaunchConfig.h"

// ---------------------------------------------------------------------------
// 美化 · 光圈外框 (marquee border fused with the floating window)
//
// Two complementary drivers:
//   1. -layoutSubviews hook on SCFloatingContainerView: the border geometry
//      is rebuilt SYNCHRONOUSLY inside the container's own layout pass, so a
//      UIKit resize and the border path land in the same CA commit.
//   2. A CADisplayLink fallback while containers are registered: ScreenCore
//      also drives resizes with spring animations directly on the container
//      LAYER (model jumps to the final value at animation start), and layer
//      changes don't run UIKit layout - the link samples the container's
//      PRESENTATION bounds per frame so animated resizes are followed too.
//
//   container.layer
//     └─ holder
//          ├─ mask = CAShapeLayer (border band path)
//          └─ grad (CAGradientLayer conic rainbow, rotation animation)
// ---------------------------------------------------------------------------

static CADisplayLink *axs_bfLink = nil;
static NSMapTable<NSString *, UIView *> *axs_bfViews = nil;       // key -> weak container
static NSMutableDictionary<NSString *, NSMutableArray<CALayer *> *> *axs_bfHolders = nil;
static NSMutableDictionary<NSString *, NSString *> *axs_bfStyleSig = nil;
static NSMutableDictionary<NSString *, NSString *> *axs_bfLayoutSig = nil;
static NSMutableDictionary<NSString *, NSString *> *axs_bfTickSig = nil;

static void axs_bf_log(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
static void axs_bf_log(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSLog(@"[AxsHoldLaunch:BF] %@", message);
    @try {
        NSString *path = @"/var/mobile/Library/Caches/AxsHoldLaunch.log";
        NSString *line = [NSString stringWithFormat:@"%@\n", message];
        NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
        if (handle == nil) {
            [line writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
        } else {
            [handle seekToEndOfFile];
            [handle writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
            [handle closeFile];
        }
    } @catch (NSException *exception) { }
}

static NSString *axs_bf_keyFor(id object) {
    return [NSString stringWithFormat:@"%p", object];
}

static UIColor *axs_bf_parseHex(NSString *hex, UIColor *fallback) {
    if (![hex isKindOfClass:[NSString class]] || hex.length == 0) return fallback;
    NSString *h = [[hex stringByReplacingOccurrencesOfString:@"#" withString:@""]
                   stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (h.length == 6 || h.length == 8) {
        unsigned int v = 0;
        NSScanner *scanner = [NSScanner scannerWithString:h];
        [scanner scanHexInt:&v];
        if (h.length == 6) v = (v << 8) | 0xFFu;
        return [UIColor colorWithRed:((v >> 24) & 0xFF) / 255.0
                               green:((v >> 16) & 0xFF) / 255.0
                                blue:((v >> 8) & 0xFF) / 255.0
                               alpha:(v & 0xFF) / 255.0];
    }
    return fallback;
}

static void axs_bf_ensureMaps(void) {
    if (axs_bfViews != nil) return;
    axs_bfViews = [NSMapTable mapTableWithKeyOptions:NSMapTableStrongMemory
                                        valueOptions:NSMapTableWeakMemory];
    axs_bfHolders = [NSMutableDictionary new];
    axs_bfStyleSig = [NSMutableDictionary new];
    axs_bfLayoutSig = [NSMutableDictionary new];
    axs_bfTickSig = [NSMutableDictionary new];
}

static void axs_bf_logCount(void) {
    axs_bf_log(@"frame layers attached: count=%lu", (unsigned long)axs_bfHolders.count);
}

static void axs_bf_detach(NSString *key) {
    NSMutableArray<CALayer *> *holders = axs_bfHolders[key];
    for (CALayer *l in holders) { [l removeFromSuperlayer]; }
    if (axs_bfHolders[key] != nil) {
        [axs_bfHolders removeObjectForKey:key];
        [axs_bfStyleSig removeObjectForKey:key];
        [axs_bfLayoutSig removeObjectForKey:key];
        [axs_bfTickSig removeObjectForKey:key];
        axs_bf_logCount();
    }
}

// drop entries whose container is gone
static void axs_bf_prune(void) {
    NSMutableArray<NSString *> *dead = [NSMutableArray array];
    for (NSString *key in axs_bfViews) {
        UIView *v = [axs_bfViews objectForKey:key];
        if (v == nil || v.window == nil) [dead addObject:key];
    }
    for (NSString *key in dead) {
        axs_bf_detach(key);
        [axs_bfViews removeObjectForKey:key];
    }
}

static NSArray<UIColor *> *axs_bf_rainbow(void) {
    return @[ [UIColor redColor], [UIColor orangeColor], [UIColor yellowColor],
              [UIColor greenColor], [UIColor cyanColor], [UIColor blueColor],
              [UIColor purpleColor], [UIColor redColor] ];
}

static NSString *axs_bf_styleSig(AxsHoldLaunchConfig *config) {
    BOOL custom = [config axs_holdlaunch_bfCustomEnabled];
    return [NSString stringWithFormat:@"custom=%d,color=%@,width=%.1f",
            (int)custom,
            custom ? [config axs_holdlaunch_bfFrameColor] : @"",
            [config axs_holdlaunch_bfFrameWidth]];
}

// geometry: prefer the container's PRESENTATION bounds (a spring resize
// animates container.layer's bounds.size directly; the model jumps to the
// final value at animation start)
static void axs_bf_updateGeometry(CALayer *holder, UIView *view, AxsHoldLaunchConfig *config) {
    CGFloat w = view.bounds.size.width;
    CGFloat h = view.bounds.size.height;
    CGFloat lineWidth = [config axs_holdlaunch_bfFrameWidth];

    CGFloat radius = 0;
    CALayer *presentation = view.layer.presentationLayer;
    if (presentation != nil) {
        CGRect pb = presentation.bounds;
        if (pb.size.width > 20 && pb.size.height > 20) { w = pb.size.width; h = pb.size.height; }
        radius = presentation.cornerRadius;
    }
    if (radius < 1) radius = view.layer.cornerRadius;
    if (radius < 1) radius = [config axs_holdlaunch_splitWindowCornerRadius];
    if (radius < 1) radius = 47.0;

    CGFloat diag = hypot(w, h) / 2.0;
    CGFloat holderW = w + diag * 2;
    CGFloat holderH = h + diag * 2;
    CGFloat dx = (holderW - w) / 2.0;
    CGFloat dy = (holderH - h) / 2.0;
    holder.frame = CGRectMake(-dx, -dy, holderW, holderH);

    CGRect band = CGRectInset(CGRectMake(0, 0, w, h), lineWidth / 2.0, lineWidth / 2.0);
    CGFloat bandRadius = radius - lineWidth / 2.0;
    if (bandRadius < 0) bandRadius = 0;
    if (bandRadius * 2 > band.size.width) bandRadius = band.size.width / 2;
    if (bandRadius * 2 > band.size.height) bandRadius = band.size.height / 2;
    UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:band
                                               byRoundingCorners:UIRectCornerAllCorners
                                                     cornerRadii:CGSizeMake(bandRadius, bandRadius)];
    CAShapeLayer *mask = (CAShapeLayer *)holder.mask;
    mask.path = path.CGPath;
    mask.lineWidth = lineWidth;

    for (CALayer *sub in holder.sublayers) {
        if ([sub isKindOfClass:[CAGradientLayer class]]) sub.frame = holder.bounds;
    }
}

static CALayer *axs_bf_build(UIView *view, AxsHoldLaunchConfig *config) {
    BOOL custom = [config axs_holdlaunch_bfCustomEnabled];
    UIColor *color = axs_bf_parseHex([config axs_holdlaunch_bfFrameColor], [UIColor cyanColor]);

    if (view.bounds.size.width < 40 || view.bounds.size.height < 40) return nil;

    CALayer *holder = [CALayer layer];
    holder.backgroundColor = [UIColor clearColor].CGColor;

    CAShapeLayer *mask = [CAShapeLayer layer];
    mask.strokeColor = [UIColor whiteColor].CGColor;
    mask.fillColor = nil;
    holder.mask = mask;

    CAGradientLayer *grad = [CAGradientLayer layer];
    grad.type = kCAGradientLayerConic;
    grad.startPoint = CGPointMake(0.5, 0.5);
    grad.endPoint = CGPointMake(0.5, 0.0);
    if (custom) {
        grad.colors = @[ (__bridge id)color.CGColor, (__bridge id)color.CGColor ];
    } else {
        NSArray<UIColor *> *rainbow = axs_bf_rainbow();
        NSMutableArray *colors = [NSMutableArray array];
        for (UIColor *c in rainbow) { [colors addObject:(__bridge id)c.CGColor]; }
        grad.colors = colors;
        NSMutableArray *locations = [NSMutableArray array];
        for (NSUInteger i = 0; i < rainbow.count; i++) {
            [locations addObject:@((double)i / (double)(rainbow.count - 1))];
        }
        grad.locations = locations;
    }
    [holder addSublayer:grad];

    if (!custom) {
        // 跑马灯: colors sweep around the border continuously (render server)
        CABasicAnimation *rot = [CABasicAnimation animationWithKeyPath:@"transform.rotation.z"];
        rot.fromValue = @(0.0);
        rot.toValue = @(2.0 * M_PI);
        rot.duration = 4.0;
        rot.repeatCount = HUGE_VALF;
        rot.removedOnCompletion = NO;
        [grad addAnimation:rot forKey:@"marquee"];
    }

    [view.layer addSublayer:holder];
    return holder;
}

// called from the container's own -layoutSubviews: same layout pass as a
// UIKit resize -> same CA commit
static void axs_bf_layout(UIView *view) {
    axs_bf_ensureMaps();
    axs_bf_prune();

    AxsHoldLaunchConfig *config = [AxsHoldLaunchConfig axs_holdlaunch_shared];
    BOOL enabled = [config axs_holdlaunch_bfFrameEnabled];

    NSString *key = axs_bf_keyFor(view);
    if (!enabled) {
        axs_bf_detach(key); // switch turned off: drop the border
        return;
    }

    NSString *styleSig = axs_bf_styleSig(config);
    NSString *layoutSig = [NSString stringWithFormat:@"%@|%@",
                           NSStringFromCGRect(view.bounds), styleSig];
    if ([axs_bfLayoutSig[key] isEqualToString:layoutSig]) return; // nothing changed

    NSMutableArray<CALayer *> *holders = axs_bfHolders[key];
    CALayer *holder = holders.firstObject;
    if (holder == nil || ![axs_bfStyleSig[key] isEqualToString:styleSig]) {
        axs_bf_detach(key);
        holder = axs_bf_build(view, config);
        if (holder == nil) return;
        axs_bfHolders[key] = [NSMutableArray arrayWithObject:holder];
        axs_bf_logCount();
        axs_bf_log(@"frame built: %@ bounds=%@ radius src=layout",
                   key, NSStringFromCGRect(view.bounds));
    } else {
        axs_bf_updateGeometry(holder, view, config);
    }
    axs_bfLayoutSig[key] = layoutSig;
    axs_bfTickSig[key] = @"";
}

// display link fallback: follows layer-driven spring resizes (which never
// reach UIKit layout) by sampling the container's presentation bounds
static void axs_bf_tick(void) {
    @try {
        axs_bf_ensureMaps();
        axs_bf_prune();

        AxsHoldLaunchConfig *config = [AxsHoldLaunchConfig axs_holdlaunch_shared];
        BOOL enabled = [config axs_holdlaunch_bfFrameEnabled];

        for (NSString *key in axs_bfViews) {
            UIView *view = [axs_bfViews objectForKey:key];
            if (view == nil) continue;

            if (!enabled) {
                axs_bf_detach(key);
                continue;
            }

            NSMutableArray<CALayer *> *holders = axs_bfHolders[key];
            CALayer *holder = holders.firstObject;
            if (holder == nil) continue; // layout hook builds first

            CALayer *pres = view.layer.presentationLayer;
            CGRect pb = pres != nil ? pres.bounds : view.bounds;
            CGFloat pr = pres != nil ? pres.cornerRadius : 0;
            NSString *tickSig = [NSString stringWithFormat:@"%@|r=%.1f",
                                 NSStringFromCGRect(pb), pr];
            if (![axs_bfTickSig[key] isEqualToString:tickSig]) {
                axs_bf_updateGeometry(holder, view, config);
                axs_bfTickSig[key] = tickSig;
                axs_bf_log(@"frame tick update: %@ bounds=%@ radius=%.1f",
                           key, NSStringFromCGRect(pb), pr);
            }
        }

        if (axs_bfLink != nil && axs_bfViews.count == 0) {
            axs_bf_log(@"frame tick idle, display link stopped");
            [axs_bfLink invalidate];
            axs_bfLink = nil;
        }
    } @catch (NSException *exception) {
        axs_bf_log(@"frame tick exception: %@", exception);
    }
}

@interface AxsBFTickTarget : NSObject
+ (instancetype)shared;
- (void)axsBFTick;
@end

@implementation AxsBFTickTarget
+ (instancetype)shared {
    static AxsBFTickTarget *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ shared = [self new]; });
    return shared;
}
- (void)axsBFTick { axs_bf_tick(); }
@end

// --- C API (Main.xm hooks + Config) ---

extern "C" {

void axs_bf_engine_wake(void) {
    if (axs_bfLink != nil) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (axs_bfLink != nil) return;
        axs_bf_ensureMaps();
        axs_bfLink = [CADisplayLink displayLinkWithTarget:[AxsBFTickTarget shared]
                                                 selector:@selector(axsBFTick)];
        [axs_bfLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
        axs_bf_log(@"frame display link started");
    });
}

// called from the hooked -layoutSubviews of SCFloatingContainerView
void axs_bf_layoutContainer(void *view) {
    if (view == NULL) return;
    id v = (__bridge id)view;
    if (![v isKindOfClass:[UIView class]]) return;
    axs_bf_layout(v);
}

void axs_bf_noteContainer(void *view) {
    if (view == NULL) return;
    id v = (__bridge id)view;
    if (![v isKindOfClass:[UIView class]]) return;
    axs_bf_ensureMaps();
    axs_bf_prune();
    NSString *key = axs_bf_keyFor(v);
    if ([axs_bfViews objectForKey:key] == v) return; // already tracked
    [axs_bfViews setObject:v forKey:key];
    axs_bf_log(@"frame container noted: %p bounds=%@",
               view, NSStringFromCGRect(((UIView *)v).bounds));
    axs_bf_engine_wake();
    // one-shot structure dump for diagnostics: what children does the
    // container actually have (which one is the visible window)?
    NSMutableArray *parts = [NSMutableArray array];
    for (UIView *sub in ((UIView *)v).subviews) {
        [parts addObject:[NSString stringWithFormat:@"%@%@", NSStringFromClass(sub.class), NSStringFromCGRect(sub.frame)]];
    }
    axs_bf_log(@"frame children: %@", [parts componentsJoinedByString:@" | "]);
}

void axs_bf_configChanged(void) {
    if (axs_bfStyleSig == nil) return;
    axs_bf_prune();
    for (NSString *key in axs_bfViews) {
        UIView *v = [axs_bfViews objectForKey:key];
        if (v == nil) continue;
        [v setNeedsLayout]; // force the hooked -layoutSubviews to run
    }
    [axs_bfStyleSig removeAllObjects];
    [axs_bfLayoutSig removeAllObjects];
    [axs_bfTickSig removeAllObjects];
    axs_bf_engine_wake();
}

} // extern "C"
