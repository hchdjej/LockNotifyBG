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
#import <stdarg.h>
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

#pragma mark - 诊断日志（tweak 侧）

// 写 /var/mobile/Library/LockNotifyBG/tweak.log，Filza 可直接查看。
// 用于定位真机上通知卡片的真实视图层级。
static void LNBTLog(NSString *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);

    NSString *dir = @"/var/mobile/Library/LockNotifyBG";
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *path = [dir stringByAppendingPathComponent:@"tweak.log"];
    static NSDateFormatter *df = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        df = [[NSDateFormatter alloc] init];
        df.dateFormat = @"HH:mm:ss.SSS";
    });
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [df stringFromDate:[NSDate date]], msg];

    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!fh) {
        [line writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    } else {
        [fh seekToEndOfFile];
        [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    }
}

// 递归 dump 视图树：类名 / frame / hidden / alpha / backgroundColor
static void LNBLogViewTree(UIView *v, NSInteger depth, NSMutableString *out) {
    if (!v || depth > 9) return;
    NSMutableString *indent = [NSMutableString string];
    for (NSInteger i = 0; i < depth; i++) [indent appendString:@"  "];

    NSString *bg = @"nil";
    if (v.backgroundColor) {
        CGFloat r, g, b, a;
        [v.backgroundColor getRed:&r green:&g blue:&b alpha:&a];
        bg = [NSString stringWithFormat:@"(%0.2f,%0.2f,%0.2f,%.2f)", r, g, b, a];
    }
    [out appendFormat:@"%@%@ frame=%@ hidden=%d alpha=%.2f tag=%ld bg=%@\n",
        indent, NSStringFromClass(v.class),
        NSStringFromCGRect(v.frame), (int)v.hidden, (double)v.alpha, (long)v.tag, bg];

    for (UIView *sub in v.subviews) LNBLogViewTree(sub, depth + 1, out);
}

// 每个 cell 只 dump 一次完整视图树（用关联对象标记）
static const void *kLNBDumpedTree = &kLNBDumpedTree;
static void LNBLogCardTreeOnce(UIView *cellView, NSString *reason) {
    if (objc_getAssociatedObject(cellView, kLNBDumpedTree)) return;
    objc_setAssociatedObject(cellView, kLNBDumpedTree, @YES, OBJC_ASSOCIATION_RETAIN);

    NSMutableString *out = [NSMutableString stringWithFormat:@"--- 卡片视图树 (%@) 根=%@ ---\n",
                            reason, NSStringFromClass(cellView.class)];
    LNBLogViewTree(cellView, 0, out);
    LNBTLog(@"%@", out);
}

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

    // v1.2.2 一次性迁移：1.1.x 时代 globalEnabled 默认 YES，从旧版升级的
    // 用户「整块列表背景」会残留开启 —— 铺满整块列表的大图正是
    // 「背景跑到模块外面」的另一个来源。这里与设置面板同逻辑：
    // 关整块背景、开卡片背景，写回 plist，用标记位保证只跑一次。
    if (saved[@"lnbMigrated122"] == nil) {
        NSMutableDictionary *m = [saved mutableCopy] ?: [NSMutableDictionary dictionary];
        m[@"globalEnabled"]   = @NO;
        m[@"cardEnabled"]     = @YES;
        m[@"lnbMigrated122"]  = @YES;
        [m writeToFile:@"/var/mobile/Library/LockNotifyBG/prefs.plist" atomically:YES];
        self.globalEnabled = NO;
        self.cardEnabled   = YES;
    }
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

// 判断一个视图是不是「毛玻璃白底」类。
// vibrancy（UIVibrancyEffect）是透明的文字强调效果容器，**不是**白底来源，
// 藏了会把文字一起变透明 —— 必须排除。
static BOOL LNBIsBlurMaterial(UIView *v) {
    if ([v isKindOfClass:[UIVisualEffectView class]]) {
        UIVisualEffectView *evv = (UIVisualEffectView *)v;
        return ![evv.effect isKindOfClass:[UIVibrancyEffect class]];
    }
    NSString *cls = NSStringFromClass(v.class).lowercaseString;
    return [cls containsString:@"blur"] ||
           [cls containsString:@"backdrop"] ||
           [cls containsString:@"material"];
}

// 关联对象 key：标记「这个材质视图是我们隐藏的」，恢复时只恢复自己藏的，
// 不碰系统本来就隐藏的视图。
static const void *kLNBHiddenByTweak = &kLNBHiddenByTweak;

// 隐藏 / 恢复 cell 子树内全部毛玻璃白底。
//
// 【v1.2.3 思路转变】v1.2.1 / v1.2.2 都在猜「哪个材质视图是卡片白底」，
// 猜中了尺寸就挂它里面 —— 实际设备上命中的是比单张卡片更大的材质层，
// 图铺到了模块外面；或者图被卡片自己的毛玻璃压在下面，只能透出模糊色块。
// 与其继续猜，不如反过来：**把毛玻璃全部隐藏，图挂在卡片本体最底层**。
// 卡片（cell）的边界就是用户看到的模块边界，图按 cell.bounds 铺，
// 位置一像素都不会错；白底藏掉后图清晰可见；实色文字浮在最上层不受影响。
static void LNBSetCardMaterialsHidden(UIView *root, BOOL hidden) {
    NSMutableArray *stack = [NSMutableArray arrayWithObject:root];
    NSInteger touched = 0;
    while (stack.count > 0) {
        UIView *v = stack.lastObject;
        [stack removeLastObject];
        if (v != root && LNBIsBlurMaterial(v)) {
            if (hidden) {
                if (!v.hidden) {
                    objc_setAssociatedObject(v, kLNBHiddenByTweak, @YES, OBJC_ASSOCIATION_RETAIN);
                    v.hidden = YES;
                    touched++;
                }
            } else if (objc_getAssociatedObject(v, kLNBHiddenByTweak)) {
                v.hidden = NO;
                objc_setAssociatedObject(v, kLNBHiddenByTweak, nil, OBJC_ASSOCIATION_RETAIN);
            }
        }
        for (UIView *sub in v.subviews) [stack addObject:sub];
    }
    if (hidden && touched > 0) {
        LNBTLog(@"[卡片] 已隐藏 %ld 个毛玻璃材质视图（root=%@）",
                (long)touched, NSStringFromClass(root.class));
    }
}

// 给「每一条通知」的宿主视图铺一张背景图。
//
// 版本沿革：
//   1.1.x colorWithPatternImage 设 backgroundColor —— 平铺且被毛玻璃盖住，失败；
//   1.2.0 图插 cell 最底层 —— 被系统毛玻璃压住，只见白框；
//   1.2.1/1.2.2 往「找到的材质视图」里挂 —— 设备上命中比卡片更大的材质层，
//          图溢出到模块外面，卡片内只剩透出来的模糊色块；
//   1.2.3 隐藏毛玻璃白底 + 图挂 cell 本体最底层、按 cell.bounds 铺：
//          图的边界 = 模块的边界，清晰、精确、绝不外溢。
static void LNBApplyCardBackground(UIView *cellView) {
    if (!cellView) return;

    // 【诊断】每次调用都记一条精简日志；视图树只在每个 cell 第一次时完整 dump
    LNBTLog(@"[卡片] 入口 root=%@ enabled=%d cardEnabled=%d",
            NSStringFromClass(cellView.class),
            (int)[LNBPrefs sharedInstance].enabled,
            (int)[LNBPrefs sharedInstance].cardEnabled);

    // 【防双份】NCNotificationListCell 和它内部的 NCNotificationShortLookView
    // 都挂了 hook。若祖先链上已经挂了背景图，说明更外层的入口已处理过，
    // 这里直接跳过，避免同一条通知叠两张图。
    for (UIView *p = cellView.superview; p; p = p.superview) {
        if ([p viewWithTag:kCardBGViewTag]) return;
    }

    LNBPrefs *prefs = [LNBPrefs sharedInstance];
    LNBLogCardTreeOnce(cellView, @"首次处理");

    UIView *existing = [cellView viewWithTag:kCardBGViewTag];
    UIView *existingDim = [cellView viewWithTag:kCardDimViewTag];

    // 关闭时：摘图 + 恢复被隐藏的毛玻璃，交还系统原始外观
    if (!prefs.enabled || !prefs.cardEnabled) {
        if (existing) [existing removeFromSuperview];
        if (existingDim) [existingDim removeFromSuperview];
        LNBSetCardMaterialsHidden(cellView, NO);
        LNBTLog(@"[卡片] 开关关闭，已还原");
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
        LNBSetCardMaterialsHidden(cellView, NO);
        LNBTLog(@"[卡片] 无可用图片（card.jpg/global.jpg 都不存在），跳过");
        return;
    }

    // 圆角跟随卡片本身，保证背景不会溢出圆角
    cellView.layer.cornerRadius = cellView.layer.cornerRadius > 0 ? cellView.layer.cornerRadius : 18.0;
    cellView.layer.masksToBounds = YES;

    // 1) 藏掉系统毛玻璃白底
    LNBSetCardMaterialsHidden(cellView, YES);

    // 2) 图挂在卡片本体最底层，边界 = 模块边界
    UIImageView *bg = (UIImageView *)[cellView viewWithTag:kCardBGViewTag];
    if (!bg) {
        bg = [[UIImageView alloc] initWithFrame:cellView.bounds];
        bg.tag = kCardBGViewTag;
        bg.userInteractionEnabled = NO;          // 绝不拦截通知的点击/滑动
        bg.contentMode = UIViewContentModeScaleAspectFill;  // 填充满 + 裁剪
        bg.clipsToBounds = YES;
    }
    if (bg.superview != cellView) {
        [bg removeFromSuperview];
        [cellView insertSubview:bg atIndex:0];
    }
    bg.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    bg.frame = cellView.bounds;
    bg.image = cardImage;
    bg.alpha = 1.0;
    LNBTLog(@"[卡片] 图已挂载 superview=%@ frame=%@ 尺寸=%0.0fx%0.0f",
            NSStringFromClass(bg.superview.class),
            NSStringFromCGRect(bg.frame),
            bg.frame.size.width, bg.frame.size.height);

    // 3) 可读性遮罩（图上、文字下）
    UIView *dim = [cellView viewWithTag:kCardDimViewTag];
    if (!dim) {
        dim = [[UIView alloc] initWithFrame:cellView.bounds];
        dim.tag = kCardDimViewTag;
        dim.userInteractionEnabled = NO;
    }
    if (dim.superview != cellView) {
        [dim removeFromSuperview];
        [cellView addSubview:dim];
    }
    [cellView insertSubview:dim aboveSubview:bg];
    dim.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    dim.frame = cellView.bounds;

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
