//
//  Tweak.xm
//  LockNotifyBG
//
//  锁屏通知背景自定义（图片 / 视频）— iOS 16.0+
//  适配无根越狱（Dopamine / palera1n rootless）
//
//  设计原则（稳定性优先）：
//   1. 全局背景 —— 在通知列表容器视图上挂一个 bg 容器（UIImageView 或 AVPlayerLayer）。
//      每次 layoutSubviews 只做「检查是否存在」，不存在才插入，避免无脑重建导致闪烁。
//   2. 卡片背景 —— 不使用子视图，改用 colorWithPatternImage 直接设置 backgroundColor。
//      UIColor 是值对象，系统重建 view 层级时不会丢失，这是 iOS 16 上最稳的卡片方案。
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

    // 默认值：安装后开箱即可用「静态图片」模式，视频需用户在设置里选文件
    self.enabled          = saved[@"enabled"]          ? [saved[@"enabled"] boolValue]          : YES;
    self.globalEnabled    = saved[@"globalEnabled"]    ? [saved[@"globalEnabled"] boolValue]    : YES;
    self.globalUseVideo   = saved[@"globalUseVideo"]   ? [saved[@"globalUseVideo"] boolValue]   : NO;
    self.globalAlpha      = saved[@"globalAlpha"]      ? [saved[@"globalAlpha"] doubleValue]    : 0.85;
    self.cardEnabled      = saved[@"cardEnabled"]      ? [saved[@"cardEnabled"] boolValue]      : NO;
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
        _dimView.backgroundColor = [UIColor blackColor];
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
        self.dimView.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.35];
        [self setupPlayerIfNeeded];
    } else {
        // 图片模式：优先 global.jpg，若不存在则回退到视频首帧
        [self teardownPlayerIfNeeded];
        self.dimView.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.25];

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

// 在给定的宿主视图上确保背景容器存在，并刷新配置
static void LNBEnsureGlobalBackground(UIView *hostView) {
    if (!hostView) return;

    LNBPrefs *prefs = [LNBPrefs sharedInstance];
    if (!prefs.enabled || !prefs.globalEnabled) {
        // 配置关闭时移除已有背景
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
    [bgView applyConfig:prefs];
}

#pragma mark - 卡片背景注入逻辑

// 为通知 cell 应用背景图：使用 pattern color 而非子视图，天然抵抗层级重建
static void LNBApplyCardBackground(UIView *cellView) {
    if (!cellView) return;

    LNBPrefs *prefs = [LNBPrefs sharedInstance];
    if (!prefs.enabled || !prefs.cardEnabled) {
        // 不干预，交还系统
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
    if (!cardImage) return;

    // colorWithPatternImage + alpha：不插子视图，系统重建后 UIColor 语义仍然生效
    UIColor *patternColor = [UIColor colorWithPatternImage:cardImage];

    // 保留圆角观感
    cellView.layer.cornerRadius = 18.0;
    cellView.layer.masksToBounds = YES;

    // 如果宿主本身是带毛玻璃的容器，pattern color 可能被覆盖，
    // 因此这里同时设置 backgroundColor，双保险
    if (prefs.cardBlurOverlay) {
        // 叠一层半透明黑，保证通知文字可读
        UIView *dim = [cellView viewWithTag:kGlobalBGViewTag + 1];
        if (!dim) {
            dim = [[UIView alloc] initWithFrame:cellView.bounds];
            dim.tag = kGlobalBGViewTag + 1;
            dim.userInteractionEnabled = NO;
            dim.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            [cellView insertSubview:dim atIndex:0];
        }
        dim.backgroundColor = [UIColor colorWithWhite:0.0 alpha:(1.0 - prefs.cardAlpha)];
        dim.frame = cellView.bounds;
    }

    cellView.backgroundColor = patternColor;
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

        // 遍历寻找背景容器并刷新
        NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:window];
        while (stack.count > 0) {
            UIView *view = [stack lastObject];
            [stack removeLastObject];
            if ([view isKindOfClass:[LNBGlobalBackgroundView class]]) {
                [(LNBGlobalBackgroundView *)view applyConfig:[LNBPrefs sharedInstance]];
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
