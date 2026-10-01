//
//  Tweak.xm
//  LockNotifyBG
//
//  锁屏通知背景自定义（图片 / 视频）— iOS 16.0+
//  适配无根越狱（Dopamine / palera1n rootless）
//
//  设计原则（稳定性优先）：
//   1. 通知卡片背景（主功能）—— 给每一条通知的宿主视图插一个 UIImageView 子视图，
//      contentMode = ScaleAspectFill，填充满卡片并裁剪。这是用户要的效果：
//      通知模块自己带背景，而不是整个锁屏铺底。
//   2. 整块列表背景（附加功能，默认关闭）—— 在通知列表容器上挂一个 bg 容器
//      （UIImageView 或 AVPlayerLayer）。每次 layoutSubviews 只做「检查是否存在」，
//      不存在才插入，避免无脑重建导致闪烁。
//   3. 只依赖最少的私有类名，不做方法级深度 hook，降低随系统更新失效的概率。
//

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <notify.h>

#pragma mark - 常量定义

// 多巴胺无根越狱下 /var 可写，把资源放这里供 SpringBoard 读取
static NSString *const kBGDirectory      = @"/var/mobile/Library/LockNotifyBG";
static NSString *const kBGGlobalImage    = @"global.jpg";
static NSString *const kBGGlobalVideo    = @"global.mp4";
static NSString *const kBGCardImage      = @"card.jpg";
static NSString *const kPrefsDomain      = @"com.hchdjej.locknotifybg";
static NSString *const kReloadNotification = @"com.hchdjej.locknotifybg/reload";

// 背景容器视图的复用 tag，用于存在性检查，避免重复插入
static const NSInteger kGlobalBGViewTag = 0x1F0B6;

#pragma mark - 配置管理

@interface LNBPrefs : NSObject
@property (nonatomic, assign) BOOL enabled;
@property (nonatomic, assign) BOOL globalEnabled;
@property (nonatomic, assign) BOOL globalUseVideo;
@property (nonatomic, assign) CGFloat globalAlpha;
@property (nonatomic, assign) BOOL cardEnabled;
@property (nonatomic, assign) CGFloat cardAlpha;
@property (nonatomic, assign) BOOL cardBlurOverlay; // 卡片上是否叠一层半透明色保证文字可读

// ---- 声音相关 ----
@property (nonatomic, assign) BOOL videoMuted;      // 背景视频是否静音
@property (nonatomic, assign) CGFloat videoVolume;  // 背景视频音量 0.0 - 1.0
@property (nonatomic, assign) BOOL mixWithOthers;   // 是否允许与其他音频混音（否则会抢占音乐播放）

+ (instancetype)sharedInstance;
- (void)reload;
@end

@implementation LNBPrefs

+ (instancetype)sharedInstance {
    static LNBPrefs *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[LNBPrefs alloc] init];
        [instance reload];
    });
    return instance;
}

- (void)reload {
    // 双通道读取：优先读设置面板写入的 plist 文件，回退到 NSUserDefaults。
    // plist 文件路径在 /var 下，SpringBoard 进程可直接读取，比跨进程 suite 更可靠。
    NSDictionary *saved = [NSDictionary dictionaryWithContentsOfFile:
                           @"/var/mobile/Library/LockNotifyBG/prefs.plist"];
    if (!saved) {
        NSUserDefaults *fallback = [[NSUserDefaults alloc] initWithSuiteName:kPrefsDomain];
        saved = [fallback dictionaryRepresentation];
    }

    // 默认值：主功能是「每条通知卡片各自带背景」，所以 cardEnabled 默认 YES。
    // globalEnabled 是「整个通知列表铺一张底图」的附加玩法，默认关闭——
    // 它会在锁屏上铺一大块，容易和壁纸打架。
    self.enabled          = saved[@"enabled"]          ? [saved[@"enabled"] boolValue]          : YES;
    self.globalEnabled    = saved[@"globalEnabled"]    ? [saved[@"globalEnabled"] boolValue]    : NO;
    self.globalUseVideo   = saved[@"globalUseVideo"]   ? [saved[@"globalUseVideo"] boolValue]   : NO;
    self.globalAlpha      = saved[@"globalAlpha"]      ? [saved[@"globalAlpha"] doubleValue]    : 0.85;
    self.cardEnabled      = saved[@"cardEnabled"]      ? [saved[@"cardEnabled"] boolValue]      : YES;
    self.cardAlpha        = saved[@"cardAlpha"]        ? [saved[@"cardAlpha"] doubleValue]      : 0.9;
    self.cardBlurOverlay  = saved[@"cardBlurOverlay"]  ? [saved[@"cardBlurOverlay"] boolValue]  : YES;

    // 视频默认静音：锁屏背景出声在系统层面容易抢占音乐播放通道，
    // 因此默认 muted=YES，用户可在设置面板主动打开声音。
    self.videoMuted       = saved[@"videoMuted"]       ? [saved[@"videoMuted"] boolValue]       : YES;
    self.videoVolume      = saved[@"videoVolume"]      ? [saved[@"videoVolume"] doubleValue]    : 0.6;
    self.mixWithOthers    = saved[@"mixWithOthers"]    ? [saved[@"mixWithOthers"] boolValue]    : YES;
}

@end

#pragma mark - 工具函数

// 拼接资源路径
static NSString *LNBPathForResource(NSString *fileName) {
    if (!fileName) return nil;
    return [kBGDirectory stringByAppendingPathComponent:fileName];
}

// 判断文件是否存在且非空
static BOOL LNBFileExists(NSString *path) {
    if (!path) return NO;
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:path isDirectory:&isDir] || isDir) return NO;
    NSDictionary *attrs = [fm attributesOfItemAtPath:path error:nil];
    return ([attrs fileSize] > 0);
}

// 从视频首帧生成一张静态图（用于卡片级背景，卡片不做视频）
static UIImage *LNBThumbnailForVideo(NSString *videoPath) {
    if (!LNBFileExists(videoPath)) return nil;
    NSURL *url = [NSURL fileURLWithPath:videoPath];
    AVAsset *asset = [AVAsset assetWithURL:url];
    AVAssetImageGenerator *generator = [AVAssetImageGenerator assetImageGeneratorWithAsset:asset];
    generator.appliesPreferredTrackTransform = YES;
    generator.maximumSize = CGSizeMake(600, 600);
    NSError *error = nil;
    CGImageRef cgImage = [generator copyCGImageAtTime:kCMTimeZero actualTime:NULL error:&error];
    if (!cgImage) return nil;
    UIImage *image = [UIImage imageWithCGImage:cgImage];
    CGImageRelease(cgImage);
    return image;
}

#pragma mark - 全局背景容器

// 这个视图承载全局底图或视频层，同时提供一个轻量遮罩保证通知文字可读
@interface LNBGlobalBackgroundView : UIView
@property (nonatomic, strong) UIImageView *imageView;
@property (nonatomic, strong) UIView *dimView;
@property (nonatomic, strong) AVPlayer *player;
@property (nonatomic, strong) AVPlayerLayer *playerLayer;
- (void)applyConfig:(LNBPrefs *)prefs;
- (void)applyAudioConfig:(LNBPrefs *)prefs;
- (void)teardownPlayerIfNeeded;
@end

@implementation LNBGlobalBackgroundView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.userInteractionEnabled = NO;   // 绝不拦截触摸，避免影响通知交互
        self.clipsToBounds = YES;
        self.backgroundColor = [UIColor clearColor];

        _imageView = [[UIImageView alloc] initWithFrame:self.bounds];
        _imageView.contentMode = UIViewContentModeScaleAspectFill;
        _imageView.clipsToBounds = YES;
        _imageView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [self addSubview:_imageView];

        _dimView = [[UIView alloc] initWithFrame:self.bounds];
        // 【踩坑】这里曾写成 [UIColor blackColor]，即 alpha=1.0 的纯黑。
        // 加上 applyConfig: 里又叠了 0.25~0.35 的黑，整张背景被压暗，
        // 用户看到的就是「一层黑色阴影」。默认必须全透明，且不参与布局遮挡。
        _dimView.backgroundColor = [UIColor clearColor];
        _dimView.hidden = YES;
        _dimView.userInteractionEnabled = NO;
        _dimView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [self addSubview:_dimView];
    }
    return self;
}

- (void)applyConfig:(LNBPrefs *)prefs {
    self.alpha = prefs.globalAlpha;

    if (prefs.globalUseVideo) {
        // 视频模式：隐藏图片，用 AVPlayerLayer 循环播放
        self.imageView.hidden = YES;
        self.dimView.hidden = YES;   // 不再额外压黑，可读性交给系统原生的模糊层
        [self setupPlayerIfNeeded];
    } else {
        // 图片模式：优先 global.jpg，若不存在则回退到视频首帧
        [self teardownPlayerIfNeeded];
        self.dimView.hidden = YES;

        UIImage *image = [UIImage imageWithContentsOfFile:LNBPathForResource(kBGGlobalImage)];
        if (!image) {
            image = LNBThumbnailForVideo(LNBPathForResource(kBGGlobalVideo));
        }
        self.imageView.image = image;
        self.imageView.hidden = (image == nil);
    }
}

- (void)setupPlayerIfNeeded {
    NSString *videoPath = LNBPathForResource(kBGGlobalVideo);
    if (!LNBFileExists(videoPath)) {
        // 视频文件缺失，直接退回静态模式，避免黑屏
        self.imageView.image = [UIImage imageWithContentsOfFile:LNBPathForResource(kBGGlobalImage)];
        self.imageView.hidden = (self.imageView.image == nil);
        return;
    }

    // 已在播放同一个视频则跳过（但仍需刷新音频配置）
    if (self.player && self.playerLayer) {
        [self applyAudioConfig:[LNBPrefs sharedInstance]];
        return;
    }

    NSURL *url = [NSURL fileURLWithPath:videoPath];
    AVPlayerItem *item = [AVPlayerItem playerItemWithURL:url];
    self.player = [AVPlayer playerWithPlayerItem:item];

    // 音频配置取自全局配置单例
    LNBPrefs *prefs = [LNBPrefs sharedInstance];
    [self applyAudioConfig:prefs];

    self.player.actionAtItemEnd = AVPlayerActionAtItemEndNone;

    self.playerLayer = [AVPlayerLayer playerLayerWithPlayer:self.player];
    self.playerLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
    self.playerLayer.frame = self.bounds;
    [self.layer insertSublayer:self.playerLayer atIndex:0];

    // 循环播放：播放结束时 seek 回起点
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(videoDidReachEnd:)
                                                 name:AVPlayerItemDidPlayToEndTimeNotification
                                               object:item];

    [self.player play];
}

// 按当前配置设置音量与音频会话
// 说明：背景视频出声会与系统音乐播放器争抢音频通道，
// 因此这里显式配置 AVAudioSession 为 Ambient + MixWithOthers，
// 保证播放背景视频时不会把用户正在听的音乐掐断。
- (void)applyAudioConfig:(LNBPrefs *)prefs {
    if (!self.player) return;

    self.player.muted = prefs.videoMuted;
    self.player.volume = prefs.videoVolume;

    if (prefs.videoMuted) return;

    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        AVAudioSession *session = [AVAudioSession sharedInstance];
        AVAudioSessionCategoryOptions options = prefs.mixWithOthers
            ? AVAudioSessionCategoryOptionMixWithOthers
            : 0;

        NSError *error = nil;
        [session setCategory:AVAudioSessionCategoryAmbient
                 withOptions:options
                       error:&error];
        if (error) {
            NSLog(@"[LockNotifyBG] 音频会话配置失败: %@", error);
        }
        [session setActive:YES error:nil];
    });
}

- (void)videoDidReachEnd:(NSNotification *)note {
    AVPlayerItem *item = note.object;
    if (!item || item != self.player.currentItem) return;
    [item seekToTime:kCMTimeZero completionHandler:^(BOOL finished) {
        if (finished) [self.player play];
    }];
}

- (void)teardownPlayerIfNeeded {
    if (self.playerLayer) {
        [self.playerLayer removeFromSuperlayer];
        self.playerLayer = nil;
    }
    if (self.player) {
        [[NSNotificationCenter defaultCenter] removeObserver:self name:AVPlayerItemDidPlayToEndTimeNotification object:self.player.currentItem];
        [self.player pause];
        self.player = nil;
    }
}

- (void)layoutSubviews {
    [super layoutSubviews];
    // 保持播放层始终与容器同尺寸
    if (self.playerLayer) {
        self.playerLayer.frame = self.bounds;
    }
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

@end

#pragma mark - 全局背景注入逻辑

// 背景容器的**唯一宿主**。这里不用「每个宿主各挂一份」的做法，原因见下：
//
// 【踩坑】早期实现是给每个调用 LNBEnsureGlobalBackground 的视图都插一份 bgView。
// 于是 NCNotificationListView（列表本体）和它内部的 NCNotificationListSectionView
//（每个通知分组）各自持有一份背景，且各自按自己的 bounds 做 ScaleAspectFill，
// 表现为：同一张图被重复显示多次、分块错位。
// 正确做法是全局只维护**一个**背景视图，并且把它挂在最外层的列表容器上。
static UIView *LNBGlobalBackgroundHost(void) {
    NSArray *windows = [UIApplication sharedApplication].windows;
    for (UIWindow *window in windows) {
        if (window.isHidden || window.alpha < 0.01) continue;

        // 由内向外广度遍历，命中第一个通知列表视图后立刻向上归一到
        // 不再属于通知体系的外层祖先，保证背景覆盖整块列表而不是某个分组。
        NSMutableArray *queue = [NSMutableArray arrayWithObject:window];
        while (queue.count > 0) {
            UIView *view = queue.firstObject;
            [queue removeObjectAtIndex:0];

            if ([NSStringFromClass(view.class) hasPrefix:@"NCNotificationList"]) {
                UIView *host = view;
                while (host.superview) {
                    NSString *name = NSStringFromClass(host.superview.class);
                    // 继续向上，直到父视图不再属于 NotificationCenter 体系
                    if ([name hasPrefix:@"NC"] || [name hasPrefix:@"UINotification"]) {
                        host = host.superview;
                    } else {
                        break;
                    }
                }
                return host;
            }

            for (UIView *sub in view.subviews) {
                [queue addObject:sub];
            }
        }
    }
    return nil;
}

// 在唯一宿主上确保背景容器存在，并刷新配置
static void LNBEnsureGlobalBackground(UIView *candidateHost) {
    LNBPrefs *prefs = [LNBPrefs sharedInstance];

    // 找到全局唯一的宿主；找不到就传进来的候选视图兜底
    UIView *hostView = LNBGlobalBackgroundHost() ?: candidateHost;
    if (!hostView) return;

    // 清理：任何不在 hostView 上的历史背景全部移除，杜绝「同一张图多处显示」
    for (UIWindow *window in [UIApplication sharedApplication].windows) {
        NSMutableArray *stack = [NSMutableArray arrayWithObject:window];
        while (stack.count > 0) {
            UIView *view = stack.lastObject;
            [stack removeLastObject];
            if (view.tag == kGlobalBGViewTag && view != hostView) {
                // 只有直接挂在 hostView 上的那一份才保留
                UIView *keeper = [hostView viewWithTag:kGlobalBGViewTag];
                if (view != keeper) [view removeFromSuperview];
            }
            for (UIView *sub in view.subviews) [stack addObject:sub];
        }
    }

    if (!prefs.enabled || !prefs.globalEnabled) {
        UIView *existing = [hostView viewWithTag:kGlobalBGViewTag];
        if (existing) [existing removeFromSuperview];
        return;
    }

    LNBGlobalBackgroundView *bgView = (LNBGlobalBackgroundView *)[hostView viewWithTag:kGlobalBGViewTag];
    if (!bgView) {
        bgView = [[LNBGlobalBackgroundView alloc] initWithFrame:hostView.bounds];
        bgView.tag = kGlobalBGViewTag;
        bgView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        // 插到最底层，绝不遮挡任何系统内容
        [hostView insertSubview:bgView atIndex:0];
    } else if (bgView.superview != hostView) {
        [hostView insertSubview:bgView atIndex:0];
    }
    bgView.frame = hostView.bounds;
    [bgView applyConfig:prefs];
}

#pragma mark - 卡片背景注入逻辑

// 卡片背景视图的复用 tag
static const NSInteger kCardBGViewTag = 0x1F0B7;
static const NSInteger kCardDimViewTag = 0x1F0B8;

// 在 cell 子树里找「卡片背景载体」——系统画白色毛玻璃底的那个视图。
//
// 【踩坑】iOS 16 锁屏通知卡片的白色底**不是** cell 自己的 backgroundColor，
// 而是内部的毛玻璃/材质视图（UIVisualEffectView 一族，或类名含
// Material / Blur / Effect 的私有材质视图）。把背景图插到 cell 的
// atIndex:0 最底层，会被这层白色完全盖住 —— 用户看到的就是
// 「一圈白框、图片没反应」。
// 解法：把自定义图片**盖在材质视图之上、文字之下**，毛玻璃自然被完全覆盖；
// 关闭时把图摘掉即可原样恢复，不破坏任何系统视图。
static UIView *LNBFindCardBackingView(UIView *root) {
    NSMutableArray *queue = [NSMutableArray arrayWithObject:root];
    while (queue.count > 0) {
        UIView *v = queue.firstObject;
        [queue removeObjectAtIndex:0];
        if (v != root) {
            NSString *cls = NSStringFromClass(v.class);
            if ([v isKindOfClass:[UIVisualEffectView class]] ||
                [cls containsString:@"Material"] ||
                [cls containsString:@"Blur"] ||
                [cls containsString:@"Effect"]) {
                return v;
            }
        }
        for (UIView *sub in v.subviews) [queue addObject:sub];
    }
    return nil;
}

// 给「每一条通知」的宿主视图铺一张背景图。
//
// 【设计说明】
// 这里是本插件的主功能：锁屏上每一条通知各自带背景，而不是整个通知列表铺底。
//
// 版本沿革：
//   1.1.x 用 [UIColor colorWithPatternImage:] 设 backgroundColor —— pattern 是
//      原尺寸平铺不是填充裁剪，且被系统毛玻璃盖住，双双失败；
//   1.2.0 改插 UIImageView 到 cell atIndex:0 最底层 —— 图还在毛玻璃下面，
//      用户看到「一圈白框、图片没反应」；
//   1.2.1 起定位系统材质视图，把图**盖到它上面**：毛玻璃被完全覆盖，
//      文字仍在图上，关闭时摘图即恢复原状。
static void LNBApplyCardBackground(UIView *cellView) {
    if (!cellView) return;

    // 【防双份】NCNotificationListCell 和它内部的 NCNotificationShortLookView
    // 都挂了 hook。若祖先链上已经挂了背景图，说明更外层的入口已处理过，
    // 这里直接跳过，避免同一条通知叠两张图。
    for (UIView *p = cellView.superview; p; p = p.superview) {
        if ([p viewWithTag:kCardBGViewTag]) return;
    }

    LNBPrefs *prefs = [LNBPrefs sharedInstance];
    UIView *existing = [cellView viewWithTag:kCardBGViewTag];
    UIView *existingDim = [cellView viewWithTag:kCardDimViewTag];

    // 关闭时把插进去的视图摘干净，交还系统原始外观
    if (!prefs.enabled || !prefs.cardEnabled) {
        if (existing) [existing removeFromSuperview];
        if (existingDim) [existingDim removeFromSuperview];
        return;
    }

    UIImage *cardImage = [UIImage imageWithContentsOfFile:LNBPathForResource(kBGCardImage)];
    if (!cardImage) {
        // 卡片图缺失时，回退用全局视频首帧，再不行就全局图片
        cardImage = LNBThumbnailForVideo(LNBPathForResource(kBGGlobalVideo));
        if (!cardImage) {
            cardImage = [UIImage imageWithContentsOfFile:LNBPathForResource(kBGGlobalImage)];
        }
    }
    if (!cardImage) {
        if (existing) [existing removeFromSuperview];
        if (existingDim) [existingDim removeFromSuperview];
        return;
    }

    // 圆角跟随卡片本身，保证背景不会溢出圆角
    cellView.layer.cornerRadius = cellView.layer.cornerRadius > 0 ? cellView.layer.cornerRadius : 18.0;
    cellView.layer.masksToBounds = YES;

    // ---- 定位白色底的来源，把图盖到它上面 ----
    UIView *backing = LNBFindCardBackingView(cellView);
    UIView *container = backing.superview ?: cellView;

    UIImageView *bg = (UIImageView *)[cellView viewWithTag:kCardBGViewTag];
    if (!bg) {
        bg = [[UIImageView alloc] initWithFrame:container.bounds];
        bg.tag = kCardBGViewTag;
        bg.userInteractionEnabled = NO;          // 绝不拦截通知的点击/滑动
        bg.contentMode = UIViewContentModeScaleAspectFill;  // 填充满 + 裁剪
        bg.clipsToBounds = YES;
    }
    if (bg.superview != container) {
        [bg removeFromSuperview];
        [container addSubview:bg];
    }
    if (backing) {
        // 保证图在材质视图之上（盖住白底）、文字之下
        [container insertSubview:bg aboveSubview:backing];
    }
    bg.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    bg.frame = container.bounds;
    bg.image = cardImage;
    bg.alpha = 1.0;

    // ---- 可读性遮罩（压在图上、文字下）----
    UIView *dim = [cellView viewWithTag:kCardDimViewTag];
    if (!dim) {
        dim = [[UIView alloc] initWithFrame:container.bounds];
        dim.tag = kCardDimViewTag;
        dim.userInteractionEnabled = NO;
    }
    if (dim.superview != container) {
        [dim removeFromSuperview];
        [container addSubview:dim];
    }
    [container insertSubview:dim aboveSubview:bg];
    dim.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    dim.frame = container.bounds;

    if (prefs.cardBlurOverlay) {
        // cardAlpha 越小 → 遮罩越重。0.9 → 10% 黑；0.2 → 80% 黑
        dim.hidden = NO;
        dim.backgroundColor = [UIColor colorWithWhite:0.0 alpha:(1.0 - prefs.cardAlpha)];
    } else {
        dim.hidden = YES;
        dim.backgroundColor = [UIColor clearColor];
    }
}

#pragma mark - 重载通知

static void LNBReloadConfiguration(void) {
    [[LNBPrefs sharedInstance] reload];
    // 让所有已存在的背景视图立即刷新
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *window = nil;
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]]) {
                for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                    if (w.isKeyWindow) { window = w; break; }
                }
            }
            if (window) break;
        }
        if (!window) return;

        // 遍历：全局背景容器刷新配置；通知卡片重新套用卡片背景。
        // 卡片这块必须一起刷，否则改完「卡片背景开关 / 透明度」要等下次
        // cell 重新 layout 才生效，体感就是「改了没用」。
        NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:window];
        while (stack.count > 0) {
            UIView *view = [stack lastObject];
            [stack removeLastObject];

            if ([view isKindOfClass:[LNBGlobalBackgroundView class]]) {
                [(LNBGlobalBackgroundView *)view applyConfig:[LNBPrefs sharedInstance]];
            }

            NSString *cls = NSStringFromClass(view.class);
            if ([cls isEqualToString:@"NCNotificationListCell"] ||
                [cls isEqualToString:@"NCNotificationShortLookView"]) {
                LNBApplyCardBackground(view);
            }

            for (UIView *sub in view.subviews) {
                [stack addObject:sub];
            }
        }
    });
}

#pragma mark - Hook 入口

%hook NCNotificationListSectionView

- (void)layoutSubviews {
    %orig;
    LNBEnsureGlobalBackground((UIView *)self);
}

%end

%hook NCNotificationListView

- (void)layoutSubviews {
    %orig;
    LNBEnsureGlobalBackground((UIView *)self);
}

%end

// 通知 cell 的通用 hook：NCNotificationListCell 是列表里每条通知的宿主视图
%hook NCNotificationListCell

- (void)layoutSubviews {
    %orig;
    LNBApplyCardBackground((UIView *)self);
}

%end

// 部分系统版本 cell 本体是 content view，额外兜一层
%hook NCNotificationShortLookView

- (void)layoutSubviews {
    %orig;
    LNBApplyCardBackground((UIView *)self);
}

%end

#pragma mark - 生命周期与配置热重载

%hook SpringBoard

- (void)applicationDidFinishLaunching:(id)application {
    %orig;
    // 监听设置面板发出的重载通知，实现免重启生效
    int token = 0;
    notify_register_dispatch([kReloadNotification UTF8String], &token, dispatch_get_main_queue(), ^(int t) {
        LNBReloadConfiguration();
    });
}

%end
