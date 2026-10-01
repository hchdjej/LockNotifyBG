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
// v1.3.8：聚焦通知时右侧「选项 / 清除」按钮的独立圆角图。
// 参考同类插件效果：每个按钮各自铺一张图，文字浮在上面。
//   选项按钮 -> supp.jpg   清除按钮 -> supp2.jpg（缺省时回退 supp.jpg）
static NSString *const kBGSupp2Image     = @"supp2.jpg";
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
// 按钮铺图 tag（选项=1 / 清除=2）。
// 【v1.4.1】原先的 kSuppBGViewTag / kSuppDimViewTag（模块级补充视图）已随
// 那套误伤逻辑一并删除，按钮只用下面这两个 tag。
static const NSInteger kSuppBtn1Tag = 0x1F0BB;
static const NSInteger kSuppBtn2Tag = 0x1F0BC;

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
            if (v.tag == kCardBGViewTag || v.tag == kCardDimViewTag) {
                LNBDiagMarkView(v, [UIColor greenColor], 2.0);       // 我们的背景 / 遮罩
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

// ---- 选项 / 清除按钮背景（v1.3.8 起独立成模块）----
// 【v1.4.1】这里只保留真正还在用的两项：
//   suppModuleEnabled —— 按钮背景总开关（默认 YES，用户明确要求）
//   suppAlpha         —— 按钮背景不透明度
// 已删除的字段（suppUseVideo / suppBlurOverlay / suppVideoSound / suppForceMode）
// 都是为"模块级补充视图"服务的，而那套逻辑 1.4.1 已整体移除：
//   * suppForceMode  —— 放宽"模块级"类名匹配，正是 1.3.6 误伤的元凶
//   * suppUseVideo / suppVideoSound —— 按钮铺的是圆角小图，视频无意义
//   * suppBlurOverlay —— 按钮上再叠暗色遮罩只会把文字压得更暗
// 用户诉求很明确：按钮背景逻辑和 1.3.3 卡片背景一致 —— 贴图 + 透明度即可。
@property (nonatomic, assign) BOOL suppModuleEnabled; // 按钮背景总开关（默认开）
@property (nonatomic, assign) CGFloat suppAlpha;     // 按钮背景不透明度

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

    // v1.3.8 选项 / 清除按钮：默认【开启】。
    // 1.3.6 之所以翻车，是因为用「类名含 Supplementary 就认」去猜，误伤了
    // 通知列表里其他补充模块。v1.4.0 起识别改用精确类名 NCToggleControl
    //（1892 条设备探针确认），且【不铺整块背景、不藏任何白底】—— 只在按钮
    // 自己身上叠一张圆角图，误伤面为零，故保持默认开。
    self.suppModuleEnabled = saved[@"suppModuleEnabled"] ? [saved[@"suppModuleEnabled"] boolValue] : YES;
    self.suppAlpha        = saved[@"suppAlpha"]        ? [saved[@"suppAlpha"] doubleValue]      : 0.9;

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

    // 【v1.4.4】内部图层与容器对齐 —— 但容器自身在被 CA 动画（尺寸渐变）
    // 时不要硬对齐，否则中间帧尺寸会把图案压扁（与外部 bg.frame 冻结策略
    // 配套）。动画期间内部图层保持不动，交给 clipsToBounds 裁剪。
    BOOL animating = (self.layer.animationKeys.count > 0);
    if (!animating) {
        if (!CGRectEqualToRect(_imageView.frame, self.bounds)) {
            _imageView.frame = self.bounds;
        }
        if (!CGRectEqualToRect(_dimView.frame, self.bounds)) {
            _dimView.frame = self.bounds;
        }
    }
    // 播放层始终与容器同尺寸（视频层不参与图案定位，直接跟 bounds 走）
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

// ---- 【v1.3.7】诊断探针：把通知列表里所有候选模块的真实类名打出来 ----
//
// 1.3.6 的教训：没有真实类名就靠"类名含 Supplementary"猜，误伤了通知列表里
// 其他补充模块（分隔线 / 时间条），把卡片区域搞乱。这个探针在诊断模式下每
// 8 秒把窗口里所有有尺寸的 NCNotification* / *Supplementary* 视图按面积从
// 大到小打一遍（类名 / frame / 父链），用日志而非猜测定类名。
//
// 用法：设置里开「诊断模式」→ 锁屏出现通知 → 20 秒后回来把日志发开发者。

static NSTimer *sLNBProbeTimer = nil;

// 收集并打印当前所有候选模块
static void LNBLogVisibleModules(void) {
    if (![NSThread isMainThread]) return;
    LNBPrefs *prefs = [LNBPrefs sharedInstance];
    if (!prefs.enabled || !prefs.diagMode) return;

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

    NSMutableArray<NSString *> *hits = [NSMutableArray array];
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:window];
    while (stack.count > 0) {
        UIView *v = [stack lastObject];
        [stack removeLastObject];

        NSString *cls = NSStringFromClass(v.class);
        CGSize sz = v.bounds.size;
        BOOL interesting = ([cls containsString:@"NCNotification"] ||
                            [cls containsString:@"Supplementary"]);
        if (interesting && sz.width > 2.0 && sz.height > 2.0) {
            // 父链（最多 3 级，够定位了）
            NSMutableString *chain = [NSMutableString string];
            UIView *p = v.superview;
            for (int i = 0; p && i < 3; i++) {
                [chain appendFormat:@"%@ / ", NSStringFromClass(p.class)];
                p = p.superview;
            }
            [hits addObject:[NSString stringWithFormat:
                @"%0.0f\t%@ {%0.0f,%0.0f,%0.0f x %0.0f}\tin[%@…]",
                sz.width * sz.height, cls,
                v.frame.origin.x, v.frame.origin.y, sz.width, sz.height,
                chain]];
        }
        for (UIView *sub in v.subviews) [stack addObject:sub];
    }

    // 面积降序（行首是面积数字，doubleValue 正好可比较）
    [hits sortUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        double da = [a doubleValue], db = [b doubleValue];
        return da > db ? NSOrderedAscending : (da < db ? NSOrderedDescending : NSOrderedSame);
    }];

    LNBTLog(@"[探针] ===== 开始：当前候选模块 %lu 个 =====", (unsigned long)hits.count);
    for (NSString *line in hits) LNBTLog(@"[探针] %@", line);
    LNBTLog(@"[探针] ===== 结束 =====");
}

// 诊断开关变化 / reload 时启停探针（诊断开 = 每 8 秒 dump 一次）
static void LNBProbeUpdate(void) {
    BOOL wantOn = [LNBPrefs sharedInstance].diagMode;
    if (wantOn && !sLNBProbeTimer) {
        sLNBProbeTimer = [NSTimer timerWithTimeInterval:8.0
                                                 repeats:YES
                                                   block:^(NSTimer *t) { LNBLogVisibleModules(); }];
        [[NSRunLoop mainRunLoop] addTimer:sLNBProbeTimer forMode:NSRunLoopCommonModes];
        LNBTLog(@"[探针] 已启动：诊断模式下每 8 秒打印候选模块");
    } else if (!wantOn && sLNBProbeTimer) {
        [sLNBProbeTimer invalidate];
        sLNBProbeTimer = nil;
        LNBTLog(@"[探针] 已停止");
    }
}

// 【v1.4.1 已彻底删除 LNBIsSupplementaryModule】
//
// 这个"模块级"识别逻辑从 1.3.6 诞生起就一直在闯祸，回顾：
//   1.3.6  规则「类名含 Supplementary 就认」→ 误伤通知列表里的分隔线/时间条，
//          用户截图「红色 背景和模块大小都不一样」
//   1.3.7  改成默认关 + 探针，但用户一开开关立刻复发
//   1.4.0  suppModuleEnabled 默认 YES，配合"只要 >1pt"的极低门槛，把
//          NCNotificationShortLookView 这类布局早期是 {0,0} 的视图也挂上了背景；
//          等它长大后背景就显形 —— 用户截图里那块脱离卡片、停在屏幕下方的
//          「孤立背景块」正是这么来的（日志有 superview=NCNotificationShortLookView
//          尺寸=0x0 的挂载记录为证）。
//
// 【为什么可以删】用户真正要的「选项 / 清除各自一块圆角图」已经由
// LNBIsCandidateActionButton（精确类名 NCToggleControl）+ LNBApplyButtonBackground
// 完整实现，模块级这套只是历史包袱 + 误伤源，删掉不影响任何正确功能。
//
// 现在「哪个视图铺卡片背景」这件事只有唯一的判据：类名 == NCNotificationListCell。

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

    // 【v1.4.1】本函数现在只服务一个模块：通知卡片本身。
    // 历史包袱（同时服务"附属按钮模块"）已在 1.4.1 删除 —— 按钮走
    // LNBApplyButtonBackground，每个按钮铺自己的图，互不干扰。
    NSString *tagName = @"卡片";

    LNBPrefs *prefs0 = [LNBPrefs sharedInstance];

    NSString *imgName = kBGCardImage;
    NSString *vidName = kBGCardVideo;
    BOOL useVideo     = prefs0.cardUseVideo;
    BOOL overlayOn    = prefs0.cardBlurOverlay;
    CGFloat alphaVal  = prefs0.cardAlpha;
    BOOL moduleOn     = prefs0.enabled && prefs0.cardEnabled;
    NSInteger bgTag   = kCardBGViewTag;
    NSInteger dimTag  = kCardDimViewTag;

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
    // 布局早期 cell 的 bounds 是 {401,160}（未收敛），挂上去尺寸不对、后面还会脱节。
    // 零尺寸时直接返回，等下一次 layoutSubviews（此时已有真实卡片几何）。
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

    // 素材检查：卡片素材优先，全缺时再回退通用素材。
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
    // 卡片视频始终静音（锁屏上多条通知同时播，出声会叠成噪声）
    bg.muteAudio = YES;
    if (bg.superview != cellView) {
        [bg removeFromSuperview];
        [cellView insertSubview:bg atIndex:0];
    }
    // 【v1.4.0 修「滑动时背景不跟随」→ v1.4.4 推翻重写】
    //
    // 【1.4.0~1.4.3 的思路为什么是错的】
    //   1.4.0：「每次 layout 都把 bg.frame 强制写成 cellView.bounds」；
    //   1.4.3：再加 clipsToBounds + bg 内部图层每帧硬对齐。
    //   在 cell 尺寸【稳定】时这没问题；但用户视频（RPReplay）逐帧实证：
    //   折叠/展开动画中系统每帧都在改 cell.bounds，于是每帧都把【中间帧
    //   尺寸】写进了 bg —— 背景图案被反复拉伸压扁（f022 帧小人被水平
    //   压缩、出现压缩竖线），动画结束又跳回 —— 用户看到的正是
    //   「素材不跟着滑动定位」。
    //
    // 【v1.4.4 正确做法：动画期间冻结，稳定后对齐】
    //   cell.layer.animationKeys 非空 = 正在跑 CA 动画（折叠/展开/位移）。
    //   此时【不要碰 bg.frame】：bg 是 cell 的子视图，cell 平移它自然跟着
    //   平移（图案相对卡片纹丝不动），尺寸变化的中间帧交给 clipsToBounds
    //   裁剪，图案绝不会被压缩。
    //   动画结束（animationKeys 为空）后再一次性对齐最终 bounds。
    bg.autoresizingMask = UIViewAutoresizingNone;
    BOOL cellAnimating = (cellView.layer.animationKeys.count > 0);
    if (!cellAnimating) {
        // 稳定态对齐禁止隐式动画：否则动画结束后 bg 从冻结尺寸过渡到
        // 最终尺寸时又会自己播一段补间，图案"软着陆"反而多一次跳动。
        [UIView performWithoutAnimation:^{
            bg.frame = cellView.bounds;
        }];
    }
    // 给 cell 本体开裁剪：动画中间帧上 bg 可能比 cell 大或小，
    // 裁剪保证无论哪种情况都不会溢出卡片轮廓之外。
    cellView.clipsToBounds = YES;
    [bg setNeedsLayout];
    [bg layoutIfNeeded];
    [bg applyConfig:prefs];
    LNBTLog(@"[%@] 背景已挂载 superview=%@ 尺寸=%0.0fx%0.0f cellBounds=%0.0fx%0.0f 视频=%d 素材=%@",
            tagName,
            NSStringFromClass(bg.superview.class),
            bg.frame.size.width, bg.frame.size.height,
            cellView.bounds.size.width, cellView.bounds.size.height,
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
    // 【v1.4.4】与 bg 同一套策略：动画期间冻结、稳定后无动画对齐（见上）
    dim.autoresizingMask = UIViewAutoresizingNone;
    if (!cellAnimating) {
        [UIView performWithoutAnimation:^{
            dim.frame = cellView.bounds;
        }];
    }
    [dim setNeedsLayout];
    [dim layoutIfNeeded];

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

#pragma mark - 按钮（选项 / 清除）独立铺图 【v1.3.8】

// 取一个视图上所有可见文字（UIButton 的 title、UILabel、私有按钮的字符串属性），
// 用于判定它到底是「选项」还是「清除」。iOS 通知按钮未必是 UIButton，
// 所以这里不依赖类型，而是把子视图里的文字都收集起来做包含判断。
static NSString *LNBGatherText(UIView *v) {
    NSMutableString *acc = [NSMutableString string];
    NSMutableArray *stack = [NSMutableArray arrayWithObject:v];
    NSInteger guard = 0;
    while (stack.count > 0 && guard++ < 200) {
        UIView *cur = [stack lastObject];
        [stack removeLastObject];

        if ([cur isKindOfClass:[UILabel class]]) {
            NSString *t = ((UILabel *)cur).text;
            if (t.length) [acc appendFormat:@" %@", t];
        }
        if ([cur isKindOfClass:[UIButton class]]) {
            NSString *t = [((UIButton *)cur) titleForState:UIControlStateNormal];
            if (t.length) [acc appendFormat:@" %@", t];
        }
        // 私有类常见：直接响应 title / text / stringValue。
        // 【v1.3.9 修正】不能用 [cur performSelector:s] —— ARC 下会触发
        // -Warc-performSelector-leaks，Theos 把它当错误处理，直接编译失败。
        // 改用 KVC valueForKey:（本质同样是动态取值，但不产生 ARC 泄漏警告），
        // 找不到 key 时 KVC 会抛 NSUndefinedKeyException，用 @try 兜住即可。
        for (NSString *key in @[@"title", @"text", @"stringValue"]) {
            @try {
                id val = [cur valueForKey:key];
                if ([val isKindOfClass:[NSString class]] && [val length]) {
                    [acc appendFormat:@" %@", val];
                }
            } @catch (NSException *e) {
                (void)e;
            }
        }
        for (UIView *sub in cur.subviews) [stack addObject:sub];
    }
    return acc;
}

// 判断一个视图是否是「聚焦通知时右侧的选项 / 清除按钮」候选。
//
// 【v1.4.0 —— 依据设备日志实证，改用精确类名】
// 1892 条探针日志给出的事实：
//   ✅ 真按钮 = NCToggleControl      size=45x34   text="清除"   isUIButton=0
//      （另有 NCToggleControlPair  107x34，是「清除+折叠」并排的容器）
//   ❌ 误伤 = NCNotificationListCoalescingControlsView 108x34（外层容器，
//            在里面铺图会把两个子按钮整个盖住 —— 用户反馈"按钮被遮挡"）
//   ❌ 误伤 = NCNotificationListHeaderTitleView 85x30（「通知中心」标题）
//   ❌ 误伤 = NCToggleControl {0,0}（未布局态，无意义）
// 所以：只认 NCToggleControl（及其 Pair 容器，按子按钮分别铺），
// 明确排除 Coalescing/HeaderTitle 这类容器与标题视图。
static BOOL LNBIsCandidateActionButton(UIView *v) {
    if (!v) return NO;

    CGSize sz = v.bounds.size;
    // 未布局的 {0,0} 直接排除（日志里 NCToggleControl 有 {0,0} 形态）
    if (sz.width < 20.0 || sz.height < 20.0) return NO;
    if (sz.width > 260.0 || sz.height > 120.0) return NO;

    NSString *cls = NSStringFromClass(v.class);

    // ① 真按钮：NCToggleControl —— 「清除」/「折叠」这类开关式小按钮。
    //    【日志实证 v1.4.5】NCToggleControl 实际尺寸只有两种：
    //      size=45x34 text="清除"（197 次）
    //      size=66x34 text="清除"（42 次）
    //    注意 NCToggleControlPair（108x34）是并排容器，**不认**（见 ②）。
    if ([cls isEqualToString:@"NCToggleControl"]) return YES;

    // ①b 真按钮：PLPlatterActionButton —— 「选项」按钮的真身！
    //    【v1.4.5 新增，这是本轮最大的收获】
    //    用户在「选项」可见状态下抓到了日志：
    //      ✅ cls=PLPlatterActionButton size=77x66 text="选项"
    //      ✅ cls=PLPlatterActionButton size=73x66 text="清除"
    //    它的祖先链是：
    //      PLPlatterActionButton → PLActionButtonsPresentingView → ...
    //    之前一直认不到，是因为旧规则要求类名含 "Button" 且祖先链含
    //    "NCNotification" —— 而 PLPlatter* 是 SpringBoard 的 Platter 体系，
    //    祖先链里根本没有 NCNotification 前缀，所以被 ③ 拒之门外。
    if ([cls isEqualToString:@"PLPlatterActionButton"]) return YES;

    // ② 明确排除：容器与标题（日志实证的误伤源，逐个点名）
    //
    //    【v1.4.5 重点】PLActionButtonsPresentingView 是包住「选项+全部清除」
    //    的**容器**，尺寸 30x66 / 154x66 / 103x66...（随按钮数量变化）。
    //    旧规则靠 ③「类名含 Button」把它放行了（Presenting 里没有 Button，
    //    但它的意思是"承载按钮的视图"）—— 在容器上铺图会把真正的
    //    PLPlatterActionButton 子按钮整个盖住，就是用户说的"按钮被遮挡"。
    //    必须排除。
    if ([cls containsString:@"ActionButtonsPresenting"]) return NO;  // ← v1.4.5
    if ([cls containsString:@"Coalescing"])      return NO;   // 外层容器，铺了会盖住子按钮
    if ([cls containsString:@"HeaderTitle"])     return NO;   // 「通知中心」标题（85x30）
    if ([cls containsString:@"HeaderCell"])      return NO;   // v1.4.5 分组头容器
    if ([cls containsString:@"Pair"])            return NO;   // 并排容器（108x34），交给子控件各自铺
    if ([cls containsString:@"SectionHeader"])   return NO;
    if ([cls containsString:@"SectionView"])     return NO;
    // 图标/头像/文字这类小视图在探针里数量极大（UIImageView 1616、
    // NCAvatarView 985、NCBadgedIconView 992），明确挡掉避免任何误伤。
    if ([cls containsString:@"Avatar"])          return NO;
    if ([cls containsString:@"BadgedIcon"])      return NO;
    if ([cls containsString:@"Legibility"])      return NO;   // SBUILegibility* 文字层
    if ([cls isEqualToString:@"UIImageView"])    return NO;
    if ([cls isEqualToString:@"UILabel"])        return NO;

    // ③ 其它自定义按钮兜底：类名含 Button 且祖先链在通知体系内才算。
    //    【v1.4.5】不再放行"含 Presenting 的容器"（已由 ② 拦下）。
    if ([cls containsString:@"Button"]) {
        for (UIView *p = v.superview; p; p = p.superview) {
            if ([NSStringFromClass(p.class) containsString:@"NCNotification"]) return YES;
        }
    }
    return NO;
}

// 【v1.3.9 探针】诊断模式下，把一个视图的按钮画像记一条日志。
// 无论最后认不认，只要在通知区域内、尺寸像按钮，都记下来 ——
// 这样即使识别规则没命中，也能从日志里看出"它到底长什么样"。
static void LNBLogButtonCandidate(UIView *v, BOOL accepted) {
    LNBPrefs *prefs = [LNBPrefs sharedInstance];
    if (!prefs.enabled || !prefs.diagMode) return;

    CGSize sz = v.bounds.size;
    if (sz.width < 15.0 || sz.height < 15.0 || sz.width > 260.0 || sz.height > 260.0) return;

    NSString *cls = NSStringFromClass(v.class);
    NSString *txt = LNBGatherText(v);
    BOOL isBtn = [v isKindOfClass:[UIButton class]];

    LNBTLog(@"[按钮探针] %@ cls=%@ isUIButton=%d size=%0.0fx%0.0f text=\"%@\"",
            accepted ? @"✅已认" : @"❌未认", cls, (int)isBtn,
            sz.width, sz.height, txt);
}

// 给【单个按钮】铺自己的圆角图 —— 每个模块各自跟自己的框走。
//
// 【v1.4.2 对齐目标效果】（用户给的参照截图：选项=黑猫图、清除=橙恐龙图，
// 各自独立圆角方块，文字浮在图上；折叠按钮裸着不铺图）
// 归属判定：
//   文字含「清除」 → supp2.jpg
//   文字含「选项」 → supp.jpg
//   文字含「折叠」 → 【跳过不铺】—— 日志实证 NCToggleControlPair 是
//       「折叠+清除」并排容器，两个都是 NCToggleControl，旧代码会让
//       「折叠」落进默认分支误穿「选项」的图。
//   无文字（图标态） → 默认 supp.jpg 兜底（很可能是「选项」的图标形态）
// 素材回退：清除 -> supp2.jpg，选项 -> supp.jpg，缺图再退 supp -> card。
static void LNBApplyButtonBackground(UIView *view) {
    if (!view) return;
    LNBPrefs *prefs = [LNBPrefs sharedInstance];

    // 【v1.4.4】动画期间（折叠/展开/位移）不动按钮背景：
    // 本函数每次进入都会"删旧图、铺新图"，动画中每帧进来都会按【中间帧
    // 尺寸】重建图片视图 —— 图案被反复压缩。动画中直接返回，保留现状。
    if (view.layer.animationKeys.count > 0) return;

    BOOL wantOn = prefs.enabled && prefs.suppModuleEnabled;

    // 清掉本按钮上已铺的图（统一走这里，避免残留）
    for (UIView *sub in view.subviews) {
        if (sub.tag == kSuppBtn1Tag || sub.tag == kSuppBtn2Tag) [sub removeFromSuperview];
    }
    if (!wantOn) return;

    // 归属：文字里找「清除 / 选项 / 折叠」关键字
    NSString *label = LNBGatherText(view);
    NSString *lower = label.lowercaseString;

    // 【v1.4.2】折叠按钮：裸的，不铺图
    if ([label containsString:@"折叠"] ||
        [lower containsString:@"collapse"] || [lower containsString:@"fold"]) {
        LNBTLog(@"[按钮] ⏭ 跳过折叠按钮 cls=%@ text=\"%@\"", NSStringFromClass(view.class), label);
        return;
    }

    // 【v1.4.5】文字优先级：必须先判「选项」再判「清除」。
    //
    // 【为什么】日志实证：NCToggleControlPair 这类容器的 text 是
    //   「清除 清除 清除 折叠 折叠 折叠」（两个子按钮的文字拼接），
    // 而「全部清除」按钮的文字里同时含「清除」和「选项」的场景也存在
    //（PLActionButtonsPresentingView 的 text = "全部清除 ... 选项 ..."）。
    // 旧代码先判「清除」，于是「选项」按钮一旦有个含"清除"的兄弟就会
    // 被染成 supp2；反过来「选项」也可能被误判。
    // 改为：文字里【明确含「选项」且不含「清除」】→ 选项图；
    //       【明确含「清除」】→ 清除图；两者都有时按类名定夺。
    BOOL hasOption = ([label containsString:@"选项"] || [lower containsString:@"option"]);
    BOOL hasClear  = ([label containsString:@"清除"] || [lower containsString:@"clear"]);

    NSInteger tag = kSuppBtn1Tag;   // 默认「选项」
    if (hasOption && !hasClear) {
        tag = kSuppBtn1Tag;
    } else if (hasClear && !hasOption) {
        tag = kSuppBtn2Tag;
    } else if (hasOption && hasClear) {
        // 混合文字（容器特征）：PLPlatterActionButton 是真按钮，
        // 用类名兜底 —— 它的具体归属交给「选项」侧（默认），
        // 因为真按钮很少同时挂两种文字。
        tag = kSuppBtn1Tag;
    }

    // 素材回退链
    NSString *imgName = (tag == kSuppBtn2Tag) ? kBGSupp2Image : kBGSuppImage;
    if (!LNBFileExists(LNBPathForResource(imgName))) imgName = kBGSuppImage;
    if (!LNBFileExists(LNBPathForResource(imgName))) imgName = kBGCardImage;
    if (!LNBFileExists(LNBPathForResource(imgName))) return;

    // 铺图：插到最底层（index 0），系统自己的 label / imageView 天然浮在上面。
    // 【v1.3.9】不再假设它是 UIButton —— 用 view 本身即可（放宽后可能是任意视图）。
    UIImageView *iv = [[UIImageView alloc] initWithFrame:view.bounds];
    iv.tag = tag;
    iv.contentMode = UIViewContentModeScaleAspectFill;
    iv.clipsToBounds = YES;
    iv.userInteractionEnabled = NO;
    // 【v1.4.0】同卡片：不用 autoresizing，每次进来强制对齐尺寸
    iv.autoresizingMask = UIViewAutoresizingNone;
    iv.frame = view.bounds;
    iv.alpha = prefs.suppAlpha;

    UIImage *img = [UIImage imageWithContentsOfFile:LNBPathForResource(imgName)];
    iv.image = img;
    [view insertSubview:iv atIndex:0];

    // 圆角：优先沿用按钮本体已有的圆角，否则按「短边」取一个舒服的比例。
    //
    // 【v1.4.5 修正】旧代码写的是 height * 0.5（取半 = 胶囊形）。
    // 对 NCToggleControl（45x34 / 66x34）这种矮扁按钮没问题，
    // 但「选项」真身 PLPlatterActionButton 是 77x66 —— 一个接近正方形的大块，
    // 按高度取半会得到 33 半径的椭圆，和用户参照图里那种"圆角方块"完全不符。
    // 改为：按短边取 30%（66*0.3 ≈ 20），接近 iOS 控制中心的圆角观感。
    CGFloat cr = view.layer.cornerRadius;
    if (cr <= 0.5) {
        CGFloat shortSide = MIN(view.bounds.size.width, view.bounds.size.height);
        cr = shortSide * 0.3;
    }
    iv.layer.cornerRadius = cr;
    iv.layer.masksToBounds = YES;

    LNBLogButtonCandidate(view, YES);
    LNBTLog(@"[按钮] ✅ 已铺图 cls=%@ text=\"%@\" tag=0x%lX size=%0.0fx%0.0f 素材=%@",
            NSStringFromClass(view.class), label, (unsigned long)tag,
            view.bounds.size.width, view.bounds.size.height, imgName);
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

            // ① 通知卡片：铺卡片自己的背景（模块跟着自己的框走）
            if ([cls isEqualToString:@"NCNotificationListCell"]) {
                LNBApplyCardBackground(v);
                // 【v1.3.8 不再 continue】聚焦时「选项 / 清除」按钮就在卡片子树里，
                // 之前 continue 会整棵跳过，按钮永远找不到。这里改为继续向下展开，
                // 但下面会用 LNBIsCandidateActionButton 严格尺寸门限把 0x0 的
                // ShortLookView 等噪声挡掉。
            }

            // ② 选项 / 清除按钮：各自铺自己的圆角图（独立于卡片背景）
            if (LNBIsCandidateActionButton(v)) {
                LNBApplyButtonBackground(v);
                continue;   // 按钮内部只有 label/image，无需继续下探
            }

            // ②b【v1.3.9 探针】没被认成按钮、但尺寸像按钮的视图也记一条，
            // 这样即使识别规则没命中，日志里也能看出它长什么样、叫什么类名。
            LNBLogButtonCandidate(v, NO);
        }
        for (UIView *sub in v.subviews) [stack addObject:sub];
    }
}

#pragma mark - 重载通知

static void LNBReloadConfiguration(void) {
    [[LNBPrefs sharedInstance] reload];
    // 【v1.3.3】素材可能刚被选/删，文件存在性缓存必须失效
    LNBInvalidateFileCache();
    // 【v1.3.7】诊断开关变化时启停候选模块探针
    LNBProbeUpdate();
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
            } else if (LNBIsCandidateActionButton(view)) {
                // v1.3.8：改完设置让「选项 / 清除」按钮的图立即刷新
                LNBApplyButtonBackground(view);
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

// 【v1.4.1 已移除】NCNotificationListSupplementaryHostingView 的 hook。
// 它当年是为了给"附属按钮模块"铺背景才挂的，而这个"模块"本身就是 1.3.6 起
// 一连串误伤的根源（见上方 LNBIsSupplementaryModule 的删除说明）。
// 设备日志显示它的尺寸/子树内容与卡片内部包装层完全一致，挂上去只会得到
// 一块和卡片对不齐的错位背景。按钮的正确做法已由 NCToggleControl 覆盖。

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
