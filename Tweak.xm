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
static NSString *const kBGCardVideo      = @"card.mp4";
// v1.3.6：附属按钮模块（删除 / 选项）独立素材。
// 逻辑与卡片完全一致，只是换一套文件名，便于用户给按钮配不同的图/视频。
static NSString *const kBGSuppImage      = @"supp.jpg";
static NSString *const kBGSuppVideo      = @"supp.mp4";
static NSString *const kPrefsDomain      = @"com.hchdjej.locknotifybg";
static NSString *const kReloadNotification = @"com.hchdjej.locknotifybg/reload";

// 背景容器视图的复用 tag，用于存在性检查，避免重复插入
static const NSInteger kGlobalBGViewTag = 0x1F0B6;
// 卡片背景 / 卡片遮罩的 tag。
// 【注意】这三个 tag 必须定义在文件最上面：诊断标记函数 LNBDiagMarkCard（约 142 行）
// 会引用 kCardBGViewTag / kCardDimViewTag，C 语言要求「先声明后使用」，
// 常量定义如果放在它们后面就是编译错误（不是警告）。
static const NSInteger kCardBGViewTag = 0x1F0B7;
static const NSInteger kCardDimViewTag = 0x1F0B8;
// 附属按钮模块用独立 tag，避免和卡片的背景视图互相干扰
static const NSInteger kSuppBGViewTag  = 0x1F0B9;
static const NSInteger kSuppDimViewTag = 0x1F0BA;

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

#pragma mark - 视图层级彩色诊断（调试模式）

// 前向声明：LNBIsBlurMaterial 定义在卡片逻辑区（下方），
// 但诊断标记函数在上面就要用它，必须先声明。
static BOOL LNBIsBlurMaterial(UIView *v);

// 【用途】当素材「看不见」时，靠日志猜层级效率太低。这里给不同角色的视图
// 描上不同颜色的边框，锁屏上一眼就能看出：
//   红 = 卡片容器（背景该铺满这里）
//   绿 = 我们挂的背景视图（它的边框就是素材实际覆盖范围）
//   黄 = 被我们隐藏的白底（MTMaterialView / StackDimmingOverlayView）
//   蓝 = 文字内容视图（背景不该盖住它）
//   橙 = 整块列表背景宿主
// 边框画在视图自身上，不影响功能；关掉「诊断模式」开关即全部移除。
static const void *kLNBDiagBorder = &kLNBDiagBorder;
static const void *kLNBDiagBorderColor = &kLNBDiagBorderColor;

static void LNBDiagMarkView(UIView *v, UIColor *color, CGFloat width) {
    if (!v || !color) return;
    // 先记下原始状态，便于恢复
    objc_setAssociatedObject(v, kLNBDiagBorder, @(v.layer.borderWidth), OBJC_ASSOCIATION_RETAIN);
    objc_setAssociatedObject(v, kLNBDiagBorderColor,
                             (__bridge id)v.layer.borderColor, OBJC_ASSOCIATION_RETAIN);
    v.layer.borderColor = color.CGColor;
    v.layer.borderWidth = width;
}

static void LNBDiagClearView(UIView *v) {
    if (!v) return;
    NSNumber *w = objc_getAssociatedObject(v, kLNBDiagBorder);
    if (!w) return;
    v.layer.borderWidth = [w doubleValue];
    CGColorRef c = (__bridge CGColorRef)objc_getAssociatedObject(v, kLNBDiagBorderColor);
    v.layer.borderColor = c;   // 可能为 NULL，即无边框，正确
    objc_setAssociatedObject(v, kLNBDiagBorder, nil, OBJC_ASSOCIATION_RETAIN);
    objc_setAssociatedObject(v, kLNBDiagBorderColor, nil, OBJC_ASSOCIATION_RETAIN);
}

// 标记一个卡片及其关键子视图
static void LNBDiagMarkCard(UIView *cell) {
    if (!cell) return;
    // v1.3.6：同一个函数也服务附属按钮模块，tag 按需匹配两套
    LNBDiagMarkView(cell, [UIColor redColor], 2.0);   // 容器

    NSMutableArray *stack = [NSMutableArray arrayWithObject:cell];
    while (stack.count > 0) {
        UIView *v = stack.lastObject;
        [stack removeLastObject];
        if (v == cell) {
            // 跳过自己不重复描
        } else {
            NSString *cls = NSStringFromClass(v.class);
            if (v.tag == kCardBGViewTag || v.tag == kSuppBGViewTag) {
                LNBDiagMarkView(v, [UIColor greenColor], 2.0);       // 我们的背景
            } else if (v.tag == kCardDimViewTag || v.tag == kSuppDimViewTag) {
                LNBDiagMarkView(v, [UIColor purpleColor], 1.0);      // 遮罩层
            } else if (LNBIsBlurMaterial(v)) {
                LNBDiagMarkView(v, [UIColor yellowColor], 2.0);      // 被藏的白底
            } else if ([cls containsString:@"ContentView"] ||
                       [cls containsString:@"SeamlessContent"]) {
                LNBDiagMarkView(v, [UIColor blueColor], 1.0);        // 文字内容层
            }
        }
        for (UIView *sub in v.subviews) [stack addObject:sub];
    }
}

// 递归清除整棵子树里所有被诊断标记过的边框。
// 【为什么必须做】诊断边框只画在 layer 上、不参与布局，但一旦 diagMode 关掉，
// 没有人会主动去「走一遍刚才标记过的地方」——卡片复用、列表滚动都可能让带框的
// 视图留在屏幕上。所以关掉开关时对整个通知列表做一次全树清扫。
static void LNBDiagClearTree(UIView *root) {
    if (!root) return;
    LNBDiagClearView(root);
    for (UIView *sub in root.subviews) LNBDiagClearTree(sub);
}

#pragma mark - 配置管理

@interface LNBPrefs : NSObject
@property (nonatomic, assign) BOOL enabled;
@property (nonatomic, assign) BOOL globalEnabled;
@property (nonatomic, assign) BOOL globalUseVideo;
@property (nonatomic, assign) CGFloat globalAlpha;
@property (nonatomic, assign) BOOL cardEnabled;
@property (nonatomic, assign) BOOL cardUseVideo;    // 卡片背景用视频（card.mp4）而不是图片
@property (nonatomic, assign) BOOL diagMode;        // 诊断模式：给视图层级上彩色边框
@property (nonatomic, assign) CGFloat cardAlpha;
@property (nonatomic, assign) BOOL cardBlurOverlay; // 卡片上是否叠一层半透明色保证文字可读

// ---- v1.3.6 附属按钮模块（删除 / 选项）----
// 逻辑与卡片完全一致，字段独立，便于单独开关与调参。
@property (nonatomic, assign) BOOL suppEnabled;      // 按钮模块背景总开关
@property (nonatomic, assign) BOOL suppUseVideo;     // 按钮背景用视频（supp.mp4）
@property (nonatomic, assign) CGFloat suppAlpha;     // 按钮背景不透明度
@property (nonatomic, assign) BOOL suppBlurOverlay;  // 按钮背景暗色遮罩
@property (nonatomic, assign) BOOL suppVideoSound;   // 按钮视频是否出声（默认静音）
@property (nonatomic, assign) BOOL suppForceMode;    // 强制模式：放宽按钮模块类名匹配

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
    self.cardUseVideo     = saved[@"cardUseVideo"]     ? [saved[@"cardUseVideo"] boolValue]     : NO;
    self.diagMode         = saved[@"diagMode"]         ? [saved[@"diagMode"] boolValue]         : NO;
    self.cardAlpha        = saved[@"cardAlpha"]        ? [saved[@"cardAlpha"] doubleValue]      : 0.9;
    self.cardBlurOverlay  = saved[@"cardBlurOverlay"]  ? [saved[@"cardBlurOverlay"] boolValue]  : YES;

    // v1.3.6 附属按钮模块：默认开启，参数与卡片一致（0.9 / 遮罩开），
    // 这样默认体验就是「按钮和卡片同款背景」，用户不必额外配置。
    self.suppEnabled      = saved[@"suppEnabled"]      ? [saved[@"suppEnabled"] boolValue]      : YES;
    self.suppUseVideo     = saved[@"suppUseVideo"]     ? [saved[@"suppUseVideo"] boolValue]     : NO;
    self.suppAlpha        = saved[@"suppAlpha"]        ? [saved[@"suppAlpha"] doubleValue]      : 0.9;
    self.suppBlurOverlay  = saved[@"suppBlurOverlay"]  ? [saved[@"suppBlurOverlay"] boolValue]  : YES;
    self.suppVideoSound   = saved[@"suppVideoSound"]   ? [saved[@"suppVideoSound"] boolValue]   : NO;
    self.suppForceMode    = saved[@"suppForceMode"]    ? [saved[@"suppForceMode"] boolValue]    : NO;

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

// 判断文件是否存在且非空。
// 【v1.3.3 加缓存】每轮 layout 每张卡片要查 4 个文件，设备日志实测入口被调
// 上万次 —— 不加缓存就是几万次磁盘 IO，锁屏动画掉帧。缓存随配置 reload 清空，
// 所以「刚选完图 → postReload → 缓存失效重查」的时效性不受影响。
static NSMutableDictionary *sLNBFileExistsCache = nil;

static BOOL LNBFileExists(NSString *path) {
    if (!path) return NO;
    if (!sLNBFileExistsCache) sLNBFileExistsCache = [NSMutableDictionary dictionary];
    NSNumber *cached = sLNBFileExistsCache[path];
    if (cached) return cached.boolValue;

    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    BOOL result = NO;
    if ([fm fileExistsAtPath:path isDirectory:&isDir] && !isDir) {
        NSDictionary *attrs = [fm attributesOfItemAtPath:path error:nil];
        result = ([attrs fileSize] > 0);
    }
    sLNBFileExistsCache[path] = @(result);
    return result;
}

// 配置重载时清空文件存在性缓存（选完图/清完资源后调用）
static void LNBInvalidateFileCache(void) {
    [sLNBFileExistsCache removeAllObjects];
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

// 这个视图承载背景图或视频层（全局列表背景与通知卡片背景共用），
// 同时提供一个轻量遮罩保证通知文字可读。
// imageName / videoName / preferVideo / alphaOverride / muteAudio 由使用方设置，
// 同一个类既能当「整块列表背景」也能当「单条卡片背景」。
@interface LNBGlobalBackgroundView : UIView
@property (nonatomic, copy) NSString *imageName;    // 背景图文件名（kBGDirectory 下）
@property (nonatomic, copy) NSString *videoName;    // 背景视频文件名
@property (nonatomic, assign) BOOL preferVideo;     // YES=视频模式
@property (nonatomic, assign) CGFloat alphaOverride;// >=0 时覆盖全局 globalAlpha（卡片用 1.0）
@property (nonatomic, assign) BOOL muteAudio;       // YES=强制静音（卡片视频多路叠加必须静音）
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
    // alpha：卡片背景传 alphaOverride=1.0（整体不透明，可读性交给遮罩）；
    // 整块列表背景沿用 globalAlpha
    self.alpha = (self.alphaOverride >= 0) ? self.alphaOverride : prefs.globalAlpha;

    BOOL useVideo = self.preferVideo;
    NSString *imgName = self.imageName ?: kBGGlobalImage;
    NSString *vidName = self.videoName ?: kBGGlobalVideo;

    if (useVideo) {
        // 视频模式：隐藏图片，用 AVPlayerLayer 循环播放
        self.imageView.hidden = YES;
        self.dimView.hidden = YES;
        [self setupPlayerIfNeeded];
    } else {
        // 图片模式：优先指定图片，若不存在则回退到视频首帧
        [self teardownPlayerIfNeeded];
        self.dimView.hidden = YES;

        UIImage *image = [UIImage imageWithContentsOfFile:LNBPathForResource(imgName)];
        if (!image) {
            image = LNBThumbnailForVideo(LNBPathForResource(vidName));
        }
        self.imageView.image = image;
        self.imageView.hidden = (image == nil);
    }
}

- (void)setupPlayerIfNeeded {
    NSString *vidName = self.videoName ?: kBGGlobalVideo;
    NSString *imgName = self.imageName ?: kBGGlobalImage;
    NSString *videoPath = LNBPathForResource(vidName);
    if (!LNBFileExists(videoPath)) {
        // 视频文件缺失，直接退回静态模式，避免黑屏
        self.imageView.image = [UIImage imageWithContentsOfFile:LNBPathForResource(imgName)];
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

    // 卡片视频多路叠加必须静音；整块背景视频跟随用户设置
    self.player.muted = self.muteAudio ? YES : prefs.videoMuted;
    self.player.volume = self.muteAudio ? 0.0 : prefs.videoVolume;

    if (self.player.muted) return;

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
        // 【v1.3.3】整块背景关闭后清掉残留的橙色诊断框 —— 之前不清，
        // 橙框永远挂在列表容器上，看起来像"有东西把通知区域框住了"。
        LNBDiagClearView(hostView);
        return;
    }

    LNBGlobalBackgroundView *bgView = (LNBGlobalBackgroundView *)[hostView viewWithTag:kGlobalBGViewTag];
    if (!bgView) {
        bgView = [[LNBGlobalBackgroundView alloc] initWithFrame:hostView.bounds];
        bgView.tag = kGlobalBGViewTag;
        bgView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        // 【回归修复 v1.3.2】v1.3.0 把本类参数化后，applyConfig: 改为读
        // self.imageName / self.videoName，而这条「整块列表背景」路径从没给它们
        // 赋过值 —— 属性默认 nil，于是去找 (null) 文件，整块背景整个失效。
        // 这里显式指定全局素材。
        bgView.alphaOverride = -1.0;   // 用 prefs.globalAlpha
        bgView.muteAudio = NO;         // 整块背景视频跟随用户声音设置
        [hostView insertSubview:bgView atIndex:0];
    } else if (bgView.superview != hostView) {
        [hostView insertSubview:bgView atIndex:0];
    }
    bgView.imageName = kBGGlobalImage;
    bgView.videoName = kBGGlobalVideo;
    bgView.preferVideo = prefs.globalUseVideo;
    bgView.frame = hostView.bounds;
    [bgView applyConfig:prefs];

    // 诊断模式：橙色边框标出「整块列表背景」的宿主范围
    if (prefs.diagMode) {
        LNBDiagMarkView(hostView, [UIColor orangeColor], 2.0);
        LNBDiagMarkView(bgView, [UIColor greenColor], 2.0);
        LNBTLog(@"[诊断] 整块背景 host=%@ frame=%@",
                NSStringFromClass(hostView.class), NSStringFromCGRect(hostView.frame));
    }
}

#pragma mark - 卡片背景注入逻辑

// 判断一个视图是不是「卡片白底」类。
//
// 【设备日志实证】iOS 16.5 通知卡片的层级是：
//   NCNotificationListCell → UIView → PLPlatterView
//     ├ MTMaterialView                          ← 毛玻璃白底（要藏）
//     ├ NCNotificationListStackDimmingOverlayView ← 纯白 alpha=0.90 遮罩（要藏）
//     └ PLPlatterCustomContentView → 文字/图标
// 所以白底来源有两处：MTMaterialView 与 StackDimmingOverlayView。
// vibrancy（UIVibrancyEffect）是透明文字效果容器，**不是**白底，藏了文字会消失。
static BOOL LNBIsBlurMaterial(UIView *v) {
    if ([v isKindOfClass:[UIVisualEffectView class]]) {
        UIVisualEffectView *evv = (UIVisualEffectView *)v;
        return ![evv.effect isKindOfClass:[UIVibrancyEffect class]];
    }
    NSString *cls = NSStringFromClass(v.class);
    if ([cls containsString:@"UIVibrancyEffect"]) return NO;
    // 通知列表的白色堆叠遮罩：日志实测 bg=(1,1,1,1) alpha=0.90，是白底来源之一
    if ([cls containsString:@"StackDimmingOverlay"]) return YES;

    NSString *low = cls.lowercaseString;
    return [low containsString:@"blur"] ||
           [low containsString:@"backdrop"] ||
           [low containsString:@"material"];
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

#pragma mark - 附属按钮模块识别（删除 / 选项）

// 【v1.3.6】判断一个视图是不是「删除 / 选项」按钮模块。
//
// 【背景】1.3.4 我用日志里一个 401x160 的 NCNotificationListSupplementaryHostingView
// 当成了按钮模块，但它的尺寸和「通知卡片内部包装层」完全相同、子树里装的还是
// 通知内容而不是按钮，很可能认错。所以这里不把赌注押在单一类名上。
//
// 识别规则（按优先级）：
//   A. 类名含 "Supplementary" —— 苹果对"卡片附加控件"的惯用命名，命中即认；
//   B. 强制模式（设置里可开）：放宽为「NCNotification 开头、不是 ListView/Cell」。
// 共同前置条件：有真实尺寸（>1pt）、且不在 NCNotificationListCell 内部
// （那是通知卡片的活儿，避免两个模块抢同一个视图）。
static BOOL LNBIsSupplementaryModule(UIView *v) {
    if (!v) return NO;
    if (v.bounds.size.width < 1.0 || v.bounds.size.height < 1.0) return NO;

    // 不能在通知卡片内部
    for (UIView *p = v.superview; p; p = p.superview) {
        if ([NSStringFromClass(p.class) isEqualToString:@"NCNotificationListCell"]) return NO;
    }

    NSString *cls = NSStringFromClass(v.class);

    // 规则 A：类名特征
    if ([cls containsString:@"Supplementary"]) return YES;

    // 规则 B：强制模式
    LNBPrefs *prefs = [LNBPrefs sharedInstance];
    if (prefs.suppForceMode &&
        [cls hasPrefix:@"NCNotification"] &&
        ![cls isEqualToString:@"NCNotificationListView"] &&
        ![cls isEqualToString:@"NCNotificationListCell"] &&
        ![cls isEqualToString:@"NCNotificationListSectionView"]) {
        return YES;
    }
    return NO;
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

    // 【v1.3.6】同一个函数服务两个模块：通知卡片、附属按钮（删除 / 选项）。
    // 判断依据是调用方传进来的视图自身的类名特征，逻辑与卡片 1:1 相同，
    // 只是素材名、tag、开关字段不同 —— 这样两边的视觉效果天然一致。
    BOOL isSupp = LNBIsSupplementaryModule(cellView);
    NSString *tagName   = isSupp ? @"按钮模块" : @"卡片";

    LNBPrefs *prefs0 = [LNBPrefs sharedInstance];

    // 本模块该用的素材与参数
    //   卡片：card.jpg / card.mp4，开关 cardEnabled，透明 cardAlpha
    //   按钮：supp.jpg / supp.mp4，开关 suppEnabled，透明 suppAlpha
    // 按钮没选专属素材时回退卡片素材（用户开了开关就不该什么都不显示）。
    NSString *imgName = isSupp ? kBGSuppImage : kBGCardImage;
    NSString *vidName = isSupp ? kBGSuppVideo : kBGCardVideo;
    BOOL useVideo     = isSupp ? prefs0.suppUseVideo   : prefs0.cardUseVideo;
    BOOL overlayOn    = isSupp ? prefs0.suppBlurOverlay : prefs0.cardBlurOverlay;
    CGFloat alphaVal  = isSupp ? prefs0.suppAlpha      : prefs0.cardAlpha;
    BOOL moduleOn     = prefs0.enabled && (isSupp ? prefs0.suppEnabled : prefs0.cardEnabled);
    NSInteger bgTag   = isSupp ? kSuppBGViewTag  : kCardBGViewTag;
    NSInteger dimTag  = isSupp ? kSuppDimViewTag : kCardDimViewTag;

    if (isSupp) {
        BOOL suppHasAny = LNBFileExists(LNBPathForResource(kBGSuppImage)) ||
                          LNBFileExists(LNBPathForResource(kBGSuppVideo));
        if (!suppHasAny) {
            BOOL cardHasAny = LNBFileExists(LNBPathForResource(kBGCardImage)) ||
                              LNBFileExists(LNBPathForResource(kBGCardVideo));
            if (cardHasAny) {
                LNBTLog(@"[按钮模块] 无 supp.* 专属素材，回退卡片素材");
                imgName = kBGCardImage;
                vidName = kBGCardVideo;
                useVideo = prefs0.cardUseVideo;
            }
        }
    }

    // 【诊断】每次调用都记一条精简日志；视图树只在每个 cell 第一次时完整 dump
    LNBTLog(@"[%@] 入口 root=%@ enabled=%d moduleOn=%d",
            tagName, NSStringFromClass(cellView.class),
            (int)prefs0.enabled, (int)moduleOn);

    // 【防双份 v1.3.3 修复】扫描入口与 hook 入口可能同时触发，需要防重复挂载。
    //
    // 【重大 bug】旧写法 [p viewWithTag:] 是递归搜索整棵子树！第一张卡片挂上
    // 背景后，第二张卡片做检查时，通过共同祖先的子树能"看到"兄弟卡片的背景
    // —— 于是第二张及以后的所有通知全部被误跳过，永远挂不上背景。
    // 这就是"只有一张卡有背景 / 其余全是灰底"的直接原因。
    // 修复：只检查祖先的【直接子视图】，语义精确为"这条通知的宿主链上已挂"。
    for (UIView *p = cellView.superview; p; p = p.superview) {
        for (UIView *sub in p.subviews) {
            if (sub.tag == bgTag) {
                LNBTLog(@"[%@] 防双份跳过 root=%@ 祖先=%@ 直接子视图中已有背景",
                        tagName, NSStringFromClass(cellView.class), NSStringFromClass(p.class));
                return;
            }
        }
    }

    LNBPrefs *prefs = prefs0;
    LNBLogCardTreeOnce(cellView, tagName);

    // 【设备日志实证】必须等卡片完成布局再挂。
    // ShortLookView 在 layout 早期是 {0,0}，把背景挂上去 = 挂在零面积视图上，
    // 永远看不见。零尺寸时直接返回，等下一次 layoutSubviews（此时已有真实尺寸）。
    if (cellView.bounds.size.width < 1.0 || cellView.bounds.size.height < 1.0) {
        LNBDiagClearView(cellView);
        return;
    }

    UIView *existing = [cellView viewWithTag:bgTag];
    UIView *existingDim = [cellView viewWithTag:dimTag];

    // 关闭时：摘背景 + 恢复被隐藏的毛玻璃，交还系统原始外观
    if (!moduleOn) {
        if (existing) {
            LNBDiagClearView(existing);
            [existing removeFromSuperview];
        }
        if (existingDim) {
            LNBDiagClearView(existingDim);
            [existingDim removeFromSuperview];
        }
        LNBSetCardMaterialsHidden(cellView, NO);
        LNBDiagClearView(cellView);
        LNBTLog(@"[%@] 开关关闭，已还原", tagName);
        return;
    }

    // 素材检查：本模块专属素材优先，回退顺序见上。
    BOOL hasImage = LNBFileExists(LNBPathForResource(imgName));
    BOOL hasVideo = LNBFileExists(LNBPathForResource(vidName));
    BOOL hasAnyFallback = LNBFileExists(LNBPathForResource(kBGGlobalImage)) ||
                          LNBFileExists(LNBPathForResource(kBGGlobalVideo));
    if (!hasImage && !hasVideo && !hasAnyFallback) {
        if (existing) [existing removeFromSuperview];
        if (existingDim) [existingDim removeFromSuperview];
        LNBSetCardMaterialsHidden(cellView, NO);
        // 【v1.3.3】这个分支必须清诊断框：之前不清，红框会残留在卡片上，
        // 看起来像"卡片被标红了但没背景"，误导排查方向。
        LNBDiagClearTree(cellView);
        // 【v1.3.3】打印每个素材的存在性，一眼看出缺什么
        LNBTLog(@"[%@] 无任何可用素材！图=%@(%d) 视频=%@(%d) ——— 请到设置里选图",
                tagName, imgName, (int)hasImage, vidName, (int)hasVideo);
        return;
    }

    // 圆角跟随卡片本身，保证背景不会溢出圆角
    cellView.layer.cornerRadius = cellView.layer.cornerRadius > 0 ? cellView.layer.cornerRadius : 18.0;
    cellView.layer.masksToBounds = YES;

    // 1) 藏掉卡片白底（MTMaterialView + StackDimmingOverlayView）
    LNBSetCardMaterialsHidden(cellView, YES);

    // 2) 背景容器：与整块列表背景同一个类，参数化为卡片素材。
    //    支持图片或视频；卡片视频强制静音（锁屏上多条通知同时播，出声会叠成噪声）。
    //
    //    【挂载位置】直接挂到 NCNotificationListCell 上、atIndex:0。
    //    设备日志确认 cell 的 frame 就是卡片实际几何
    //   {{46.1,18.4},{308.8,123.2}}，背景按 cell.bounds 铺即精确覆盖卡片。
    //    白底已藏，图不会被盖住；文字在更内层的子视图里，浮在图之上。
    LNBGlobalBackgroundView *bg = (LNBGlobalBackgroundView *)[cellView viewWithTag:bgTag];
    if (!bg) {
        bg = [[LNBGlobalBackgroundView alloc] initWithFrame:cellView.bounds];
        bg.tag = bgTag;
        bg.alphaOverride = 1.0;
        bg.muteAudio = YES;
    }
    bg.imageName = imgName;
    bg.videoName = vidName;
    bg.preferVideo = useVideo && hasVideo;
    // 按钮模块的视频允许出声（用户明确要求）；卡片视频始终静音
    bg.muteAudio = isSupp ? !prefs0.suppVideoSound : YES;
    if (bg.superview != cellView) {
        [bg removeFromSuperview];
        [cellView insertSubview:bg atIndex:0];
    }
    bg.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    bg.frame = cellView.bounds;
    [bg applyConfig:prefs];
    LNBTLog(@"[%@] 背景已挂载 superview=%@ 尺寸=%0.0fx%0.0f 视频=%d 素材=%@",
            tagName,
            NSStringFromClass(bg.superview.class),
            bg.frame.size.width, bg.frame.size.height,
            (int)bg.preferVideo,
            bg.preferVideo ? vidName : imgName);

    // 3) 可读性遮罩（背景上、文字下）
    UIView *dim = [cellView viewWithTag:dimTag];
    if (!dim) {
        dim = [[UIView alloc] initWithFrame:cellView.bounds];
        dim.tag = dimTag;
        dim.userInteractionEnabled = NO;
    }
    if (dim.superview != cellView) {
        [dim removeFromSuperview];
        [cellView addSubview:dim];
    }
    [cellView insertSubview:dim aboveSubview:bg];
    dim.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    dim.frame = cellView.bounds;

    if (overlayOn) {
        // alpha 越小 → 遮罩越重。0.9 → 10% 黑；0.2 → 80% 黑
        dim.hidden = NO;
        dim.backgroundColor = [UIColor colorWithWhite:0.0 alpha:(1.0 - alphaVal)];
    } else {
        dim.hidden = YES;
        dim.backgroundColor = [UIColor clearColor];
    }

    // 4) 诊断模式：给卡片与关键子视图上彩色边框，方便肉眼确认层级
    if (prefs.diagMode) {
        LNBDiagMarkCard(cellView);
        LNBTLog(@"[诊断] 已标记 %@ org=%@", tagName, NSStringFromCGRect(cellView.frame));
    }
}

// 【v1.3.1 核心修复】在通知列表子树里扫描每一条通知并应用卡片背景。
//
// 【为什么只认 NCNotificationListCell】v1.3.0 用「类名含 LookView」扫描，
// 结果命中的 NCNotificationShortLookView 在 layout 早期尺寸是 {0,0}
//（设备日志实证：26 次视图树 dump 里尺寸全是 0x0），背景挂上去 = 零面积，
// 用户永远看不到；而 NCNotificationListCell 的 frame 是
// {{46.1, 18.4}, {308.8, 123.2}} —— 正好是屏幕上那张卡片的实际位置和大小。
// 所以：只认 NCNotificationListCell（有真实几何的卡片容器），
// ShortLookView 交给它内部防双份逻辑忽略。
static void LNBScanAndApplyCards(UIView *root) {
    // 【诊断关闭时的全树清扫】diagMode 一关，必须把上一轮画上去的彩框全部擦掉。
    // 放在扫描入口做，因为这里每次列表 layout 都会走到，覆盖最全。
    LNBPrefs *prefs = [LNBPrefs sharedInstance];
    if (!prefs.diagMode) {
        LNBDiagClearTree(root);
    }

    NSMutableArray *stack = [NSMutableArray arrayWithObject:root];
    while (stack.count > 0) {
        UIView *v = stack.lastObject;
        [stack removeLastObject];
        if (v != root) {
            NSString *cls = NSStringFromClass(v.class);
            if ([cls isEqualToString:@"NCNotificationListCell"]) {
                LNBApplyCardBackground(v);
                continue;   // 卡片内部不再展开，避免命中 0x0 的 ShortLookView
            }
            if (LNBIsSupplementaryModule(v)) {
                // 「删除 / 选项」按钮模块：走【和卡片完全相同】的注入逻辑，
                // 只是把素材换成 supp.* 那一套、tag 换成独立的一套，
                // 这样两个模块的视觉行为和卡片 100% 一致。
                LNBApplyCardBackground(v);   // 内部按 isSupp 自动切换参数
                continue;                    // 同样不再向下展开
            }
        }
        for (UIView *sub in v.subviews) [stack addObject:sub];
    }
}

#pragma mark - 重载通知

static void LNBReloadConfiguration(void) {
    [[LNBPrefs sharedInstance] reload];
    // 【v1.3.3】素材可能刚被选/删，文件存在性缓存必须失效
    LNBInvalidateFileCache();
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
            if ([cls isEqualToString:@"NCNotificationListCell"]) {
                LNBApplyCardBackground(view);
            } else if (LNBIsSupplementaryModule(view)) {
                // v1.3.6：按钮模块改完设置也要即时生效
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
    // 整块列表背景（附加功能，默认关闭）
    LNBEnsureGlobalBackground((UIView *)self);
    // 【v1.3.0 核心修复】主动扫描子树给每条通知挂卡片背景——
    // 不依赖 NCNotificationListCell 这个在 iOS 16.5 上可能不存在的类名
    LNBScanAndApplyCards((UIView *)self);
}

%end

// 通知 cell hook：NCNotificationListCell 是列表里每条通知的宿主视图，
// 设备日志确认它的 frame 就是卡片实际几何。
%hook NCNotificationListCell

- (void)layoutSubviews {
    %orig;
    LNBApplyCardBackground((UIView *)self);
}

%end

// 【v1.3.6】附属按钮模块（删除 / 选项）也有自己的 layout 时机。
// 不写死类名 —— 挂到它自己声明的类上，由 LNBIsSupplementaryModule
// 在运行时复核；如果这个类名在本机型不存在，hook 会自动失效，
// 但列表级扫描（LNBScanAndApplyCards）仍能兜住。
%hook NCNotificationListSupplementaryHostingView

- (void)layoutSubviews {
    %orig;
    if (LNBIsSupplementaryModule((UIView *)self)) {
        LNBApplyCardBackground((UIView *)self);
    }
}

%end

// 【已移除】NCNotificationShortLookView 的 hook。
// 设备日志显示它在 layout 早期尺寸恒为 {0,0}，挂背景等于挂零面积视图，
// 不但看不见，还会抢先占掉 tag 让外层正确的 cell 被跳过。
// 现在只在 NCNotificationListCell 上处理。

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
