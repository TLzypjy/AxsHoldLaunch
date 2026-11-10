#import <UIKit/UIKit.h>
#import "AxsHoldLaunchConfig.h"

// ---------------------------------------------------------------------------
// 美化 · 光圈外框 (marquee border fused with the floating window)
//
// TrollOpen-style zero-lag mechanism: the border geometry is updated
// SYNCHRONOUSLY inside the floating container's own layout pass
// (-layoutSubviews hook). When ScreenCore resizes the window, UIKit runs the
// container's layout in the same update cycle, so the border path and the
// window frame land in the SAME Core Animation commit - physically no delay.
//
//   container.layer
//     └─ holder (static between layouts)
//          ├─ mask = CAShapeLayer (border band path, updated per layout)
//          └─ grad (CAGradientLayer conic rainbow, rotation animation)
//
// The gradient spin runs on the render server (CAAnimation) - zero CPU. No
// display link is needed: layouts drive everything.
// ---------------------------------------------------------------------------

static NSMapTable<NSString *, UIView *> *axs_bfViews = nil;       // key -> weak container
static NSMutableDictionary<NSString *, NSMutableArray<CALayer *> *> *axs_bfHolders = nil;
static NSMutableDictionary<NSString *, NSString *> *axs_bfStyleSig = nil;
static NSMutableDictionary<NSString *, NSString *> *axs_bfLayoutSig = nil;

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
        axs_bf_logCount();
    }
}

// drop entries whose container is gone (called on every note/config/layout)
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

// geometry from the container's CURRENT bounds; radius follows the window's
// own corner radius (ScreenCore's 圆角 preference), updated in the same layout
static void axs_bf_updateGeometry(CALayer *holder, UIView *view, AxsHoldLaunchConfig *config) {
    CGFloat w = view.bounds.size.width;
    CGFloat h = view.bounds.size.height;
    CGFloat lineWidth = [config axs_holdlaunch_bfFrameWidth];

    CGFloat radius = view.layer.cornerRadius;
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

static NSString *axs_bf_build(UIView *view, AxsHoldLaunchConfig *config) {
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

// called from the container's own -layoutSubviews: same layout pass as the
// window resize -> same CA commit -> zero lag
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
    } else {
        axs_bf_updateGeometry(holder, view, config);
    }
    axs_bfLayoutSig[key] = layoutSig;
}

// --- C API (Main.xm hooks + Config) ---

extern "C" {

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
    // the container's layoutSubviews fires right after this; the border is
    // built/updated there (same run loop turn)
}

// called from the hooked -layoutSubviews of SCFloatingContainerView
void axs_bf_layoutContainer(void *view) {
    if (view == NULL) return;
    id v = (__bridge id)view;
    if (![v isKindOfClass:[UIView class]]) return;
    axs_bf_layout(v);
}

void axs_bf_configChanged(void) {
    if (axs_bfStyleSig == nil) return;
    axs_bf_prune();
    // drop style + layout signatures so every live container re-lays out
    for (NSString *key in axs_bfViews) {
        UIView *v = [axs_bfViews objectForKey:key];
        if (v == nil) continue;
        [v setNeedsLayout]; // force the hooked -layoutSubviews to run
        axs_bf_log(@"frame config changed: %p", v);
    }
    [axs_bfStyleSig removeAllObjects];
    [axs_bfLayoutSig removeAllObjects];
}

} // extern "C"
