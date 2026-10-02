//
//  Tweak.xm
//  LockNotifyBG v2.0 —— 精简重写版
//
//  目标效果（对齐参考视频，零配置）：
//    ① 背景图层：global.mp4 / global.jpg 铺满整个通知列表，
//       卡片之间的间隙透出它 —— 视频里"卡片后面的人"；
//    ② 卡片动画层：card.mp4 / card.jpg 铺每一条通知卡片，
//       文字直接叠在上面 —— 视频里"卡片里的小黄鸭"。
//    多张卡片共用同一个播放器 → 所有卡片同一时刻同一帧（同步是结构保证）。
//
//  素材目录（与 v1.x 相同，老素材无缝沿用）：
//    /var/mobile/Library/LockNotifyBG/
//      global.mp4  global.jpg   （视频优先，缺失回退图片）
//      card.mp4    card.jpg
//    两个都没有 → 完全原生，插件不做任何事。
//
//  本版彻底移除：设置面板、诊断模式、按钮美化、透明度/音量开关。
//  只保留经过 v1.4.1~v1.4.16 验证的核心机制：
//    · bounds+center+恒等 transform 几何（v1.4.11 定论，v1.4.12 卡死教训）
//    · cell 四 setter hook + 时间闸门 + 重入保护（v1.4.13 安全版）
//    · 共享播放器（v1.4.14，多卡同帧 by construction）
//    · 毛玻璃白底隐藏与恢复（关联对象记账）
//    · 列表扫描兜底（iOS 16.5 上 NCNotificationListCell hook 可能不触发）
//
//  v2.0.2 左滑跟随（第一版，实机证伪）：
//    把背景挂进滚动容器内的"卡片层"想让它原生跟随 —— 实机发现该容器
//    比可视卡片大 → 背景铺出卡片外（素材画面下缘的小人溢出到卡片外）
//    且亮屏瞬间卡片错位贴边。
//
//  v2.1.0 架构修正（关键认知更新）：
//    用户澄清：参考视频里"整个屏幕的画面是朋友的视频壁纸"。
//    定量分析实锤：朋友卡片内亮度 = 卡片外 × 0.84、卡片边界上下
//    画面连续（差 28 远小于随机 44）—— 朋友的效果是
//    【视频壁纸 + 卡片半透明暗化（壁纸透过卡片连续显示）】，
//    卡片根本没有独立视频层！
//    因此本版改为两种模式：
//    A. 有 global.mp4（透明卡片模式，默认对齐朋友）：
//       全屏视频层铺列表底部（唯一视频源）+ 卡片只放 16% 暗化板。
//       卡片内外画面连续、多卡跨卡拼接连续 —— 物理保证，无需取景计算。
//    B. 无 global 有 card.mp4（旧模式）：卡片独立铺 card.mp4。
//
//  v2.0.3 左滑跟随：hook NCNotificationListCellScrollView（setBounds/
//      setContentOffset），偏移变化时把卡片背景层中心平移 -offset.x
//      （LNBMirrorSwipe）—— 透明模式的暗化板与旧模式的视频层都适用。
//  v2.0.4 全屏背景挂载修复：调用点加进 cell hook（实机证明只有它稳定
//      触发），宿主查找加"从 cell 向上爬最近的大容器"兜底。
//
#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <stdarg.h>

#pragma mark - 常量

static NSString *const kBGDirectory   = @"/var/mobile/Library/LockNotifyBG";
static NSString *const kCardVideo     = @"card.mp4";
static NSString *const kCardImage     = @"card.jpg";
static NSString *const kGlobalVideo   = @"global.mp4";
static NSString *const kGlobalImage   = @"global.jpg";

static const NSInteger kCardBGViewTag   = 0x4C4E4243;   // 'LNBC'
static const NSInteger kGlobalBGViewTag = 0x4C4E4247;   // 'LNBG'

// 被本插件藏掉的毛玻璃视图，用关联对象记账，还原时不误伤别人藏的
static const void *kLNBHiddenByTweak = &kLNBHiddenByTweak;

// 背景视图自身的同步重入保护（关联对象，避免给 UIView 加类别属性）
static const void *kLNBSyncingKey = &kLNBSyncingKey;

// 当前镜像的滑动偏移（关联对象挂在背景视图上；scrollview hook 写入，sync 读取）
static const void *kLNBSlideOffsetKey = &kLNBSlideOffsetKey;

static void LNBTLog(NSString *fmt, ...) {
    // 轻量日志：直接进 syslog，随时可用 Console 看；量很小，无性能负担
    va_list args;
    va_start(args, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    NSLog(@"[LockNotifyBG] %@", s);
}

static NSString *LNBPathForResource(NSString *name) {
    return [kBGDirectory stringByAppendingPathComponent:name];
}

static BOOL LNBFileExists(NSString *path) {
    return [[NSFileManager defaultManager] fileExistsAtPath:path];
}

#pragma mark - 毛玻璃白底隐藏

// 通知卡片的白底来源：MTMaterialView 系毛玻璃 + StackDimmingOverlayView。
// 判定规则来自 v1.3.x 十几轮设备日志实证。
static BOOL LNBIsBlurMaterial(UIView *v) {
    if ([v isKindOfClass:[UIVisualEffectView class]]) {
        UIVisualEffectView *ev = (UIVisualEffectView *)v;
        return ![ev.effect isKindOfClass:[UIVibrancyEffect class]];
    }
    NSString *cls = NSStringFromClass(v.class);
    if ([cls containsString:@"UIVibrancyEffect"]) return NO;
    if ([cls containsString:@"StackDimmingOverlay"]) return YES;
    NSString *low = cls.lowercaseString;
    return [low containsString:@"blur"] ||
           [low containsString:@"backdrop"] ||
           [low containsString:@"material"];
}

// 藏 / 还原整棵子树里的毛玻璃。用关联对象记"是我藏的"，还原不误伤。
static void LNBSetCardMaterialsHidden(UIView *root, BOOL hidden) {
    NSMutableArray *stack = [NSMutableArray arrayWithObject:root];
    while (stack.count > 0) {
        UIView *v = stack.lastObject;
        [stack removeLastObject];
        if (v != root && LNBIsBlurMaterial(v)) {
            if (hidden) {
                if (!v.hidden) {
                    objc_setAssociatedObject(v, kLNBHiddenByTweak, @YES, OBJC_ASSOCIATION_RETAIN);
                    v.hidden = YES;
                }
            } else if (objc_getAssociatedObject(v, kLNBHiddenByTweak)) {
                v.hidden = NO;
                objc_setAssociatedObject(v, kLNBHiddenByTweak, nil, OBJC_ASSOCIATION_RETAIN);
            }
        }
        for (UIView *sub in v.subviews) [stack addObject:sub];
    }
}

#pragma mark - 共享卡片播放器（多卡同帧的核心）

// 一个进程级共享 AVPlayer + 每卡一个 AVPlayerLayer。
// 同一 player 的所有 layer 渲染同一解码帧 —— 同步是结构保证，不靠追帧。
// 【判据纪律】（v1.4.12 卡死教训）：只用指针/路径直接比较，绝不做"设进去再读回"。
static AVPlayer     *lnbSharedPlayer  = nil;
static NSString     *lnbSharedPath    = nil;
static uint64_t      lnbSharedSize    = 0;
static NSTimeInterval lnbSharedMTime = 0;
static id            lnbSharedEndObs  = nil;
static NSInteger     lnbSharedAttachN = 0;

static BOOL LNBSharedPlayerMatches(NSString *videoPath) {
    if (!lnbSharedPlayer || !lnbSharedPath) return NO;
    if (![lnbSharedPath isEqualToString:videoPath]) return NO;
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:videoPath error:nil];
    if (!attrs) return NO;
    return ([attrs fileSize] == lnbSharedSize &&
            fabs([[attrs fileModificationDate] timeIntervalSince1970] - lnbSharedMTime) < 0.5);
}

static void LNBSharedPlayerTearDown(void) {
    if (lnbSharedEndObs) {
        [[NSNotificationCenter defaultCenter] removeObserver:lnbSharedEndObs];
        lnbSharedEndObs = nil;
    }
    [lnbSharedPlayer pause];
    lnbSharedPlayer = nil;
    lnbSharedPath = nil;
    lnbSharedSize = 0;
    lnbSharedMTime = 0;
}

// 领共享播放器（引用计数 +1；从空闲恢复时回片头）
static AVPlayer *LNBSharedPlayerAcquire(NSString *videoPath) {
    if (!LNBSharedPlayerMatches(videoPath)) {
        LNBSharedPlayerTearDown();
        AVPlayerItem *item = [AVPlayerItem playerItemWithURL:[NSURL fileURLWithPath:videoPath]];
        lnbSharedPlayer = [AVPlayer playerWithPlayerItem:item];
        lnbSharedPlayer.actionAtItemEnd = AVPlayerActionAtItemEndNone;
        lnbSharedPlayer.muted = YES;   // 锁屏多卡同播，恒静音
        lnbSharedPlayer.volume = 0.0;
        lnbSharedPath = [videoPath copy];
        NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:videoPath error:nil];
        lnbSharedSize = [attrs fileSize];
        lnbSharedMTime = [[attrs fileModificationDate] timeIntervalSince1970];
        lnbSharedEndObs = [[NSNotificationCenter defaultCenter]
            addObserverForName:AVPlayerItemDidPlayToEndTimeNotification
                        object:item queue:nil
                    usingBlock:^(NSNotification *note) {
            [lnbSharedPlayer seekToTime:kCMTimeZero
                      completionHandler:^(BOOL done) {
                if (done && lnbSharedPlayer) [lnbSharedPlayer play];
            }];
        }];
    }
    BOOL wasIdle = (lnbSharedAttachN == 0);
    lnbSharedAttachN++;
    if (wasIdle) {
        [lnbSharedPlayer seekToTime:kCMTimeZero];
        [lnbSharedPlayer play];
    } else if (lnbSharedPlayer.rate == 0.0) {
        [lnbSharedPlayer play];
    }
    return lnbSharedPlayer;
}

// 还共享播放器（引用计数 -1；归零即暂停回片头，省电）
static void LNBSharedPlayerDetach(void) {
    if (lnbSharedAttachN > 0) lnbSharedAttachN--;
    if (lnbSharedAttachN == 0 && lnbSharedPlayer) {
        [lnbSharedPlayer pause];
        [lnbSharedPlayer seekToTime:kCMTimeZero];
    }
}

#pragma mark - 背景视图（图片/视频通用容器）

@interface LNBBGView : UIView
@property (nonatomic, strong) UIImageView *imageView;
@property (nonatomic, strong) AVPlayer *player;        // 共享引用时恒为 nil
@property (nonatomic, strong) AVPlayerLayer *playerLayer;
@property (nonatomic, assign) BOOL attachedShared;     // 当前持有一个共享引用
@property (nonatomic, assign) BOOL useSharedPlayer;    // 卡片 YES / 全局 NO
- (void)applyMediaWithVideo:(NSString *)vidName image:(NSString *)imgName;
- (void)applyDimOnlyWithAlpha:(CGFloat)alpha;
- (void)teardownMedia;
- (void)syncToHostIfNeeded;
@end

@implementation LNBBGView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.userInteractionEnabled = NO;
        self.clipsToBounds = YES;
        self.backgroundColor = [UIColor clearColor];
        _imageView = [[UIImageView alloc] initWithFrame:self.bounds];
        _imageView.contentMode = UIViewContentModeScaleAspectFill;
        _imageView.clipsToBounds = YES;
        _imageView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [self addSubview:_imageView];
    }
    return self;
}

// 【v2.1.0 透明卡片模式】不放任何媒体，只做半透明暗化板。
// 全屏视频层（global.mp4）透过它显示 —— 卡片内外画面连续，
// 与参考视频一致（卡片内亮度 ≈ 卡片外 × 0.84，即压暗 ~16%）。
- (void)applyDimOnlyWithAlpha:(CGFloat)alpha {
    [self teardownMedia];
    self.imageView.hidden = YES;
    self.backgroundColor = [UIColor colorWithWhite:0.0 alpha:alpha];
    [self setNeedsLayout];
}

- (void)applyMediaWithVideo:(NSString *)vidName image:(NSString *)imgName {
    self.backgroundColor = [UIColor clearColor];   // 从暗化模式切回时恢复透明底
    NSString *videoPath = vidName ? LNBPathForResource(vidName) : nil;
    if (videoPath && LNBFileExists(videoPath)) {
        self.imageView.hidden = YES;
        [self setupVideoWith:videoPath];
    } else {
        [self teardownMedia];
        UIImage *img = imgName ? [UIImage imageWithContentsOfFile:LNBPathForResource(imgName)] : nil;
        self.imageView.image = img;
        self.imageView.hidden = (img == nil);
    }
    [self setNeedsLayout];
}

- (void)setupVideoWith:(NSString *)videoPath {
    if (self.useSharedPlayer) {
        // ── 共享模式（卡片）──
        if (self.playerLayer && self.attachedShared &&
            self.playerLayer.player == lnbSharedPlayer &&
            LNBSharedPlayerMatches(videoPath)) {
            return;   // 已挂对，无事可做
        }
        [self teardownMedia];
        AVPlayer *shared = LNBSharedPlayerAcquire(videoPath);
        self.attachedShared = YES;
        self.player = nil;   // 不持有共享实例，防止误停
        self.playerLayer = [AVPlayerLayer playerLayerWithPlayer:shared];
        self.playerLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
        self.playerLayer.frame = self.bounds;
        [self.layer insertSublayer:self.playerLayer atIndex:0];
        return;
    }
    // ── 私有模式（全局背景）──
    if (self.player && self.playerLayer) return;
    [self teardownMedia];
    AVPlayerItem *item = [AVPlayerItem playerItemWithURL:[NSURL fileURLWithPath:videoPath]];
    self.player = [AVPlayer playerWithPlayerItem:item];
    self.player.actionAtItemEnd = AVPlayerActionAtItemEndNone;
    self.player.muted = YES;
    self.player.volume = 0.0;
    __weak typeof(self) wself = self;
    [[NSNotificationCenter defaultCenter] addObserverForName:AVPlayerItemDidPlayToEndTimeNotification
                                                      object:item queue:nil
                                                 usingBlock:^(NSNotification *note) {
        __strong typeof(wself) sself = wself;
        [sself.player seekToTime:kCMTimeZero completionHandler:^(BOOL done) {
            if (done) [sself.player play];
        }];
    }];
    self.playerLayer = [AVPlayerLayer playerLayerWithPlayer:self.player];
    self.playerLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
    self.playerLayer.frame = self.bounds;
    [self.layer insertSublayer:self.playerLayer atIndex:0];
    [self.player play];
}

- (void)teardownMedia {
    if (self.playerLayer) {
        [self.playerLayer removeFromSuperlayer];
        self.playerLayer = nil;
    }
    if (self.attachedShared) {
        self.attachedShared = NO;
        LNBSharedPlayerDetach();
    }
    if (self.player) {
        [self.player pause];
        self.player = nil;
    }
}

// 自跟踪宿主：bounds 尺寸 + 宿主中心 + transform 恒等。
// 判据全部直接比较，必然收敛（v1.4.11 定论 / v1.4.12 血泪）。
// 【v2.0.3】宿主是 cell 本体；镜像的滑动偏移计入 wantCenter ——
// 左滑时 scrollview hook 把 bg 中心平移 -dx，这里的判据与它协同，
// 不会把跟随时机的偏移"拉回原位"。
- (void)syncToHostIfNeeded {
    UIView *host = self.superview;
    if (!host) return;
    CGSize target = host.bounds.size;
    if (target.width < 1.0 || target.height < 1.0) return;
    NSNumber *slide = objc_getAssociatedObject(self, kLNBSlideOffsetKey);
    CGFloat dx = slide ? slide.doubleValue : 0.0;
    CGPoint wantCenter = CGPointMake(CGRectGetMidX(host.bounds) - dx, CGRectGetMidY(host.bounds));

    BOOL sizeOk = CGSizeEqualToSize(self.bounds.size, target);
    BOOL tfOk = CGAffineTransformIsIdentity(self.transform);
    BOOL centerOk = (fabs(self.center.x - wantCenter.x) < 0.01 &&
                     fabs(self.center.y - wantCenter.y) < 0.01);
    if (sizeOk && tfOk && centerOk) return;

    self.autoresizingMask = UIViewAutoresizingNone;
    [UIView performWithoutAnimation:^{
        CGRect b = self.bounds;
        b.size = target;
        self.bounds = b;
        if (!CGAffineTransformIsIdentity(self.transform)) self.transform = CGAffineTransformIdentity;
        self.center = wantCenter;
    }];
}

// 列表宿主缓存（全屏背景层的挂载点，弱引用）。
// 弱引用：列表销毁后自动失效，下次 layout 重新查找。
static __weak UIView *lnbListHostCache = nil;
static UIView *LNBGlobalBackgroundHost(UIView *anchor);   // 前向声明（定义在下方）

- (void)layoutSubviews {
    NSNumber *syncing = objc_getAssociatedObject(self, kLNBSyncingKey);
    if (!syncing.boolValue) {
        objc_setAssociatedObject(self, kLNBSyncingKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [self syncToHostIfNeeded];
        objc_setAssociatedObject(self, kLNBSyncingKey, @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    [super layoutSubviews];
    if (!CGRectEqualToRect(_imageView.frame, self.bounds)) _imageView.frame = self.bounds;

    if (self.playerLayer) {
        // 背景铺满自身 bounds（自身=滑动容器里的卡片层）。
        // 左滑时随宿主内容一起平移，裁切交给滚动容器/屏幕边缘。
        self.playerLayer.frame = self.bounds;   // 无条件赋值，不做读回比较
    }
}

- (void)dealloc {
    if (_attachedShared) {
        _attachedShared = NO;
        LNBSharedPlayerDetach();
    }
}

@end

#pragma mark - 卡片背景

// 【v2.0.3】左滑跟随：镜像滚动容器的 contentOffset。
// 背景（挂 cell）中心 = 卡片中心 - offset.x —— 内容左滑多少，背景跟着左滑多少。
// 偏移记入关联对象，syncToHostIfNeeded 读取同一份，两边不打架。
// 判据直接比较读入值（非"设进去读回"），必然收敛。
static void LNBMirrorSwipe(UIView *scrollView, CGFloat offsetX) {
    UIView *p = scrollView.superview;
    NSInteger guard = 0;
    while (p && guard++ < 8) {
        if ([NSStringFromClass(p.class) isEqualToString:@"NCNotificationListCell"]) break;
        p = p.superview;
    }
    if (!p || guard > 8) return;
    LNBBGView *bg = (LNBBGView *)[p viewWithTag:kCardBGViewTag];
    if (![bg isKindOfClass:[LNBBGView class]]) return;
    objc_setAssociatedObject(bg, kLNBSlideOffsetKey, @(offsetX), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    CGFloat wantX = p.bounds.size.width / 2.0 - offsetX;
    if (fabs(bg.center.x - wantX) > 0.5 || fabs(bg.center.y - p.bounds.size.height / 2.0) > 0.5) {
        [UIView performWithoutAnimation:^{
            bg.center = CGPointMake(wantX, p.bounds.size.height / 2.0);
        }];
    }
}

// 给一条通知卡片挂背景。
// 【v2.1.0】两种模式：
//   A. 有 global 素材（透明卡片模式，对齐参考视频）——
//      卡片不放独立视频！只放半透明暗化层，让列表底部的全屏视频层
//      透过卡片显示。卡片内外画面连续（朋友效果的鸭嘴跨卡片边界
//      连续就是这个原理），多卡显示各自位置的同一画面，跨卡拼接连续。
//      定量依据：朋友卡片内亮度 = 卡片外 × 0.84（压暗 16%）。
//   B. 无 global 但有 card（旧模式）—— 卡片铺 card.mp4 独立视频。
static void LNBApplyCardBackground(UIView *cell) {
    if (!cell) return;
    NSString *cls = NSStringFromClass(cell.class);
    if (![cls isEqualToString:@"NCNotificationListCell"]) return;

    BOOL hasGlobalVideo = LNBFileExists(LNBPathForResource(kGlobalVideo));
    BOOL hasGlobalImage = LNBFileExists(LNBPathForResource(kGlobalImage));
    BOOL hasGlobal      = hasGlobalVideo || hasGlobalImage;
    BOOL hasCardVideo   = LNBFileExists(LNBPathForResource(kCardVideo));
    BOOL hasCardImage   = LNBFileExists(LNBPathForResource(kCardImage));
    if (!hasGlobal && !hasCardVideo && !hasCardImage) {
        // 没素材：还原并退出（原生样式）
        LNBSetCardMaterialsHidden(cell, NO);
        UIView *old = [cell viewWithTag:kCardBGViewTag];
        if (old) [old removeFromSuperview];
        return;
    }

    LNBSetCardMaterialsHidden(cell, YES);

    // cell 本体不裁切：左滑镜像时背景要能滑出 cell 边界，
    // 由屏幕边缘完成裁切（若 cell=卡片宽度，裁在 cell 上会形成"看不见的墙"）
    cell.layer.masksToBounds = NO;

    LNBBGView *bg = (LNBBGView *)[cell viewWithTag:kCardBGViewTag];
    if (!bg) {
        bg = [[LNBBGView alloc] initWithFrame:cell.bounds];
        bg.tag = kCardBGViewTag;
        bg.useSharedPlayer = YES;
    }
    if (bg.superview != cell) {
        [bg removeFromSuperview];
        [cell insertSubview:bg atIndex:0];
    }
    // 圆角自补（宿主不带圆角裁切时由背景自身保持原生卡片圆角观感）
    CGFloat radius = cell.layer.cornerRadius > 0 ? cell.layer.cornerRadius : 18.0;
    if (fabs(bg.layer.cornerRadius - radius) > 0.5) bg.layer.cornerRadius = radius;

    if (hasGlobal) {
        // 透明卡片模式：半透明暗化板，透出列表底部的全屏视频层
        [bg applyDimOnlyWithAlpha:0.16];
    } else {
        // 旧模式：卡片独立铺 card.mp4
        [bg applyMediaWithVideo:(hasCardVideo ? kCardVideo : nil)
                          image:(hasCardVideo ? nil : kCardImage)];
    }
}

// 几何同步（cell setter 调用；时间闸门：每帧最多放行一次）。
// 【v2.0.2】背景挂在滑动容器里的卡片层后，左滑不再需要任何逐帧同步
// （背景随内容原生移动）。这里只负责 cell 尺寸/位置变化（展开动画、
// 重新布局）时让背景重新对齐宿主 —— syncToHostIfNeeded 自己会收敛。
static void LNBSyncCardGeometry(UIView *cell) {
    static CFTimeInterval sLast = 0;
    CFTimeInterval now = CACurrentMediaTime();
    if (now - sLast < (1.0 / 120.0)) return;
    sLast = now;
    UIView *bg = [cell viewWithTag:kCardBGViewTag];
    if ([bg isKindOfClass:[LNBBGView class]]) [bg setNeedsLayout];
}

#pragma mark - 全屏背景图层

// 找全屏背景宿主。
// 【v2.0.4】两路查找：
//   ① BFS 全窗口找 NC 前缀列表视图并爬祖先（原逻辑，iOS 16.5 锁屏上可能落空）；
//   ② 兜底：从 anchor（触发 hook 的 cell/列表视图）向上爬，取第一个
//      "足够大"（≥0.85×屏宽 且 ≥0.5×屏高）的祖先 —— 即装着所有卡片的
//      列表容器。取"最近"不取"最大"：避免爬到含壁纸子视图的锁屏根
//      （插 index 0 会掉到壁纸下面）。列表容器的子视图全是通知内容，
//      index 0 必在所有卡片之下、背景之上 —— 安全。
static UIView *LNBGlobalBackgroundHost(UIView *anchor) {
    for (UIWindow *window in [UIApplication sharedApplication].windows) {
        if (window.isHidden || window.alpha < 0.01) continue;
        NSMutableArray *queue = [NSMutableArray arrayWithObject:window];
        while (queue.count > 0) {
            UIView *view = queue.firstObject;
            [queue removeObjectAtIndex:0];
            if ([NSStringFromClass(view.class) hasPrefix:@"NCNotificationList"]) {
                UIView *host = view;
                while (host.superview) {
                    NSString *name = NSStringFromClass(host.superview.class);
                    if ([name hasPrefix:@"NC"] || [name hasPrefix:@"UINotification"]) {
                        host = host.superview;
                    } else break;
                }
                return host;
            }
            for (UIView *sub in view.subviews) [queue addObject:sub];
        }
    }
    // ② 兜底：anchor 向上爬
    if (anchor) {
        CGSize screen = [UIScreen mainScreen].bounds.size;
        UIView *p = anchor;
        NSInteger guard = 0;
        while (p && guard++ < 12) {
            CGSize bs = p.bounds.size;
            if (bs.width >= screen.width * 0.85 && bs.height >= screen.height * 0.5) {
                return p;
            }
            if ([p isKindOfClass:[UIWindow class]]) break;
            p = p.superview;
        }
    }
    return nil;
}

// 全屏背景就绪节流：cell hook 每帧都会进来，宿主+bg 已就绪时 0.5s 才
// 复查一次（素材更换/宿主重建最迟半秒生效），避免高频 BFS 拖累滑动帧率。
static CFTimeInterval lnbGlobalBGLastCheck = 0;

static void LNBEnsureListBackground(UIView *anchor) {
    CFTimeInterval now = CACurrentMediaTime();
    if (now - lnbGlobalBGLastCheck < 0.5) return;
    lnbGlobalBGLastCheck = now;

    BOOL hasVideo = LNBFileExists(LNBPathForResource(kGlobalVideo));
    BOOL hasImage = LNBFileExists(LNBPathForResource(kGlobalImage));
    UIView *host = LNBGlobalBackgroundHost(anchor);
    if ((!hasVideo && !hasImage) || !host) {
        // 无素材：清理所有历史挂载
        for (UIWindow *window in [UIApplication sharedApplication].windows) {
            NSMutableArray *stack = [NSMutableArray arrayWithObject:window];
            while (stack.count > 0) {
                UIView *v = stack.lastObject;
                [stack removeLastObject];
                if (v.tag == kGlobalBGViewTag) [v removeFromSuperview];
                for (UIView *sub in v.subviews) [stack addObject:sub];
            }
        }
        return;
    }

    // 清理重复挂载（只保留宿主上这一份）
    for (UIWindow *window in [UIApplication sharedApplication].windows) {
        NSMutableArray *stack = [NSMutableArray arrayWithObject:window];
        while (stack.count > 0) {
            UIView *v = stack.lastObject;
            [stack removeLastObject];
            if (v.tag == kGlobalBGViewTag && v.superview != host) [v removeFromSuperview];
            for (UIView *sub in v.subviews) [stack addObject:sub];
        }
    }

    LNBBGView *bg = (LNBBGView *)[host viewWithTag:kGlobalBGViewTag];
    if (!bg) {
        bg = [[LNBBGView alloc] initWithFrame:host.bounds];
        bg.tag = kGlobalBGViewTag;
        bg.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        bg.useSharedPlayer = NO;
        [host insertSubview:bg atIndex:0];
    } else if (bg.superview != host) {
        [host insertSubview:bg atIndex:0];
    }
    CGRect gb = bg.bounds;
    gb.size = host.bounds.size;
    bg.bounds = gb;
    bg.center = CGPointMake(CGRectGetMidX(host.bounds), CGRectGetMidY(host.bounds));
    [bg applyMediaWithVideo:(hasVideo ? kGlobalVideo : nil)
                      image:(hasVideo ? nil : kGlobalImage)];
}

// 列表全树扫描：给每张卡片挂背景（iOS 16.5 cell hook 可能不触发的兜底）
static void LNBScanAndApplyCards(UIView *root) {
    NSMutableArray *stack = [NSMutableArray arrayWithObject:root];
    while (stack.count > 0) {
        UIView *v = stack.lastObject;
        [stack removeLastObject];
        if ([NSStringFromClass(v.class) isEqualToString:@"NCNotificationListCell"]) {
            LNBApplyCardBackground(v);
        }
        for (UIView *sub in v.subviews) [stack addObject:sub];
    }
}

# pragma mark - Hooks

%hook NCNotificationListView
- (void)layoutSubviews {
    %orig;
    LNBEnsureListBackground((UIView *)self);
    LNBScanAndApplyCards((UIView *)self);
}
%end

%hook NCNotificationListSectionView
- (void)layoutSubviews {
    %orig;
    LNBEnsureListBackground((UIView *)self);
}
%end

// 【v2.0.3】左滑跟随的关键 hook：卡片内横向滚动容器（iOS 16.5 通知左滑
// 就是滚动它，cell 本体不动）。contentOffset 变化有两种入口，
// setBounds（bounds.origin == contentOffset）和 setContentOffset，都拦。
// 每次偏移变化把背景中心平移 -offset.x —— 内容滑多少背景跟多少。
// 类名若在某系统版本不存在，hook 自然不触发，退化为 v2.0.0 行为（无害）。
%hook NCNotificationListCellScrollView
- (void)setBounds:(CGRect)bounds {
    %orig(bounds);
    LNBMirrorSwipe((UIView *)self, bounds.origin.x);
}
- (void)setContentOffset:(CGPoint)contentOffset {
    %orig;
    LNBMirrorSwipe((UIView *)self, contentOffset.x);
}
%end

%hook NCNotificationListCell
- (void)layoutSubviews {
    %orig;
    LNBApplyCardBackground((UIView *)self);
    // 【v2.0.4】全屏背景的调用点加到 cell hook —— 实机证明 iOS 16.5 锁屏上
    // 只有 cell 的 layout 稳定触发（ListView/SectionView 未必），
    // v2.0.0~v2.0.3 的全屏背景层因此一直没挂上（卡片后面是静态壁纸）。
    LNBEnsureListBackground((UIView *)self);
}
- (void)setFrame:(CGRect)frame {
    %orig(frame);
    LNBSyncCardGeometry((UIView *)self);
}
- (void)setBounds:(CGRect)bounds {
    %orig(bounds);
    LNBSyncCardGeometry((UIView *)self);
}
- (void)setCenter:(CGPoint)center {
    %orig(center);
    LNBSyncCardGeometry((UIView *)self);
}
- (void)setTransform:(CGAffineTransform)transform {
    %orig(transform);
    LNBSyncCardGeometry((UIView *)self);
}
%end

%hook SpringBoard
- (void)applicationDidFinishLaunching:(id)application {
    %orig;
    LNBTLog(@"v2.1.0 loaded — 素材目录 %@（有 global.mp4 走透明卡片模式，否则卡片铺 card.mp4）", kBGDirectory);
}
%end
