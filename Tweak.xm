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

// 递归 dump 视图树：类名 / frame / bounds / center / transform / hidden / alpha / bg / tag
//
// 【v1.4.10 增强】原来的 dump 只有 frame / hidden / alpha / bg，排查
// 「卡片背景和选项按钮糊成一块」这种层级问题远远不够 —— 至少还差：
//   bounds    view 自身坐标系的尺寸（判断尺寸对不对的依据）
//   center    view 在父坐标系里的中心（判断有没有被推到别处）
//   transform 有没有被缩放/位移（展开动画的关键）
//   序号      同级子视图的先后顺序 = 层级 z 序（判断谁盖谁）
// 全部补上，做到"看日志即可还原现场"。
//
// 【坐标系提示】打印时把 center 和 frame 都列出来，若两者对不上（例如
// center 落在父视图中心但 frame 在很远处），就说明有 transform 在捣鬼。
static void LNBLogViewTree(UIView *v, NSInteger depth, NSMutableString *out) {
    if (!v || depth > 12) return;
    NSMutableString *indent = [NSMutableString string];
    for (NSInteger i = 0; i < depth; i++) [indent appendString:@"  "];

    // transform：标出缩放/位移，恒等则简写 identity
    CGAffineTransform t = v.transform;
    NSString *tf = @"identity";
    if (!CGAffineTransformIsIdentity(t)) {
        tf = [NSString stringWithFormat:@"[a=%.3f b=%.3f c=%.3f d=%.3f tx=%.1f ty=%.1f]",
              t.a, t.b, t.c, t.d, t.tx, t.ty];
    }

    NSString *bg = @"nil";
    if (v.backgroundColor) {
        CGFloat r, g, b, a;
        if ([v.backgroundColor getRed:&r green:&g blue:&b alpha:&a]) {
            bg = [NSString stringWithFormat:@"(%0.2f,%0.2f,%0.2f,%.2f)", r, g, b, a];
        } else {
            bg = @"(non-rgb)";
        }
    }

    [out appendFormat:
        @"%@%@ frame=%@ bounds=%@ center=(%.1f,%.1f) tf=%@ z=%ld/%ld "
        @"hidden=%d alpha=%.2f clip=%d tag=%ld bg=%@\n",
        indent, NSStringFromClass(v.class),
        NSStringFromCGRect(v.frame), NSStringFromCGRect(v.bounds),
        v.center.x, v.center.y, tf,
        (long)(v.superview ? [v.superview.subviews indexOfObject:v] : 0),
        (long)(v.superview ? v.superview.subviews.count : 0),
        (int)v.hidden, (double)v.alpha, (int)v.clipsToBounds, (long)v.tag, bg];

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

// 【v1.4.10 ★★★ 新增：按需 dump（不限一次）】
// 「主卡片和选项糊成一块」这类问题需要在【展开动作发生时】看层级，
// 而 LNBLogCardTreeOnce 每个 cell 只 dump 第一次（挂背景时），
// 那时按钮还没出现。这里提供一个不限次数、可指定触发原因的 dump，
// 由 LNBDumpCellHierarchyIfNeeded / LNBApplyButtonBackground 调用。
//
// 【范围】会把 root 及其整棵子树打印出来（每层含 frame/bounds/center/
// transform/z序/hidden/alpha/clip/tag/bg）。调用方负责把 root 选在
// 合适的层级，避免打印整屏。
static void LNBLogTreeNow(UIView *root, NSString *reason) {
    if (!root) return;
    NSMutableString *out = [NSMutableString stringWithFormat:
        @"\n===== 视图树快照 (%@) 根=%@ =====\n",
        reason, NSStringFromClass(root.class)];
    LNBLogViewTree(root, 0, out);
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
// 【v1.4.13】重入保护标记：syncToHostIfNeeded 执行期间置 YES，
//   防止「设置几何 → 触发 layoutSubviews → 又调 sync」的无限递归。
//   这类保护是 v1.4.12 卡死事故的直接补救，必须保留。
@property (nonatomic, assign) BOOL lnbSyncing;
- (void)applyConfig:(LNBPrefs *)prefs;
- (void)applyAudioConfig:(LNBPrefs *)prefs;
- (void)teardownPlayerIfNeeded;
- (void)syncToHostIfNeeded;   // 【v1.4.12】自跟踪宿主【视觉】尺寸（frame），逐帧贴合卡片
- (void)notifyHostGeometryChanged;  // 【v1.4.12】宿主尺寸/形变一变就被叫醒，立刻重贴
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
    // 【v1.4.9】第一件事：自跟踪宿主尺寸（含抵消父层 transform）。
    [self syncToHostIfNeeded];

    [super layoutSubviews];

    if (!CGRectEqualToRect(_imageView.frame, self.bounds)) {
        _imageView.frame = self.bounds;
    }
    if (!CGRectEqualToRect(_dimView.frame, self.bounds)) {
        _dimView.frame = self.bounds;
    }
    // 播放层始终与容器同尺寸（视频层不参与图案定位，直接跟 bounds 走）
    if (self.playerLayer) {
        self.playerLayer.frame = self.bounds;
    }
}

// 【v1.4.11 ★★★ 第四次也是最后一次破案：背景天然跟随，不需要任何 transform 操作】
//
// ── 1.4.9/1.4.10 为什么错 ──
//   1.4.9 给背景加了逆矩阵：self.transform = CGAffineTransformInvert(host.transform)
//   我以为"背景是子视图会自动继承父层 transform，所以要抵消"。
//   这是对 UIKit 语义的误读：
//     · 父层 transform 作用于子视图，是渲染时的【继承】，子视图的 bounds
//       与父层 transform 无关；
//     · 子视图自己再设一个逆矩阵，等于在继承之外又叠加一层反向缩放，
//       结果是【反向放大】—— cell 缩到 0.1 时背景被放大 10 倍，撑爆到卡片
//       外面，把「选项」按钮整个盖住。
//   → 用户反馈的"主卡片和选项给删除搞一块了"就是这个。
//
// ── 1.4.8 为什么"看起来没生效" ──
//   1.4.8 的做法其实是对的（bounds + center），但代码里有一句致命 return：
//       if (CGSizeEqualToSize(self.bounds.size, target)) return;
//   而 target = host.bounds.size 恒为 308.77x66（不含 transform），
//   所以判断【永远为真】→ 每次进来都直接 return，同步代码从没执行过。
//   这就解释了日志里"bgFrame 一次都没动"：不是策略错，是这句 return 把整段
//   逻辑短路了。当时我误判成"bounds 策略不对"，才引出 1.4.9 的错误改法。
//
// ── v1.4.11 最终做法 ──
//   背景是 host 的子视图，父层 transform 会【自动】作用于它，无需干预。
//   只需保证两件事：
//     ① 尺寸 = host.bounds.size（真实尺寸，不含 transform）
//     ② center = host 中心
//   父层一缩放，背景跟着缩放，屏幕上的视觉尺寸与卡片永远一致。
//
//   【并修掉那句短路 return】：
//     不再只比尺寸，而是把"我自己的 transform 是否还是恒等"也纳入判断
//     （因为 1.4.9 残留的逆矩阵必须被清掉），两者都对才 return。
//
// ── v1.4.13 ★★★ 【紧急回退】frame + 逆矩阵方案导致手机卡死 ──
//
//   【v1.4.12 为什么卡死 —— 这是本插件史上最严重的一次事故，必须记清楚】
//     v1.4.12 我写了这套"看起来很美"的公式：
//         bg.transform = Invert(cell.transform)
//         bg.frame     = cell.frame
//     它有一个致命的自相矛盾：
//       · UIKit 里 frame 的 setter 会把传入矩形当作【变换后】的视觉矩形，
//         反算出 center 存起来；
//       · frame 的 getter 又用 center + bounds × transform 重新算回去。
//     设了逆矩阵之后，"设进去的 frame" 和 "读出来的 frame" 永远差一截
//     （实测 46.1 → 32.7，差 13 个点）。
//     于是判据 CGRectEqualToRect(self.frame, hostFrameVis) 永远为假 →
//     下面这段同步代码【每次调用都会真的执行】→ 而设置 frame/bounds/transform
//     又会让 UIKit 标记"需要重新布局" → layoutSubviews 再来一遍 → 无限递归。
//     叠加上 v1.4.12 新加的四个 setter hook，主线程被彻底锁死，
//     表现就是用户说的「一加素材手机就卡死」。
//
//   【教训】凡是"设置值 → 读回值 → 比较是否相等"的收敛判据，
//     绝对不能经过带变换的往返计算，否则浮点与语义双重不收敛。
//
// ── v1.4.13 回退方案：v1.4.11 的 bounds + center（transform 恒等）──
//   背景是 host 的子视图，父层 transform 会【自动】作用于它，无需干预。
//   只需保证两件事：
//     ① 尺寸 = host.bounds.size（真实尺寸，不含 transform）
//     ② center = host 中心
//   判据全是直接比较（不经变换往返），必然收敛，不可能死循环。
//
//   【与 1.4.8 的差别】1.4.8 那句 `if (sizeOk) return;` 单独用时会把整段
//   逻辑短路（因为 target 恒等于 host.bounds.size）。这里把 transform
//   是否恒等也纳入判据，残留的旧矩阵（1.4.9/1.4.12 留下的）能清干净。
//
//   【用户要的"展开时素材跟着放大"靠什么实现】
//   靠父层的自动继承：cell 缩放 → 背景跟着缩放 → 视觉尺寸一致。
//   再配合 cell 侧四个 setter hook 逐帧叫醒背景，中间帧也不会掉队。
//
// 【范围限定】只处理通知卡片（NCNotificationListCell）。
- (void)syncToHostIfNeeded {
    UIView *host = self.superview;
    if (!host) return;
    NSString *hostCls = NSStringFromClass(host.class);
    if (![hostCls isEqualToString:@"NCNotificationListCell"]) return;

    // 真实尺寸（不含 transform）—— 父层 transform 会自然作用于它
    CGSize target = host.bounds.size;
    if (target.width < 1.0 || target.height < 1.0) target = host.frame.size;
    if (target.width < 1.0 || target.height < 1.0) return;

    CGPoint wantCenter = CGPointMake(CGRectGetMidX(host.bounds),
                                     CGRectGetMidY(host.bounds));

    BOOL sizeOk = CGSizeEqualToSize(self.bounds.size, target);
    // 【关键】必须把"我的 transform 是否还是恒等"纳入判据 ——
    // 1.4.9 / 1.4.12 留下的逆矩阵必须被清掉，否则会一直反向缩放。
    BOOL tfOk = CGAffineTransformIsIdentity(self.transform);
    // center 用容差比较即可（这里是父坐标系里的直接值，不经变换往返）
    BOOL centerOk = (fabs(self.center.x - wantCenter.x) < 0.01 &&
                     fabs(self.center.y - wantCenter.y) < 0.01);
    if (sizeOk && tfOk && centerOk) return;   // 三项全对才跳过（必然收敛）

    self.autoresizingMask = UIViewAutoresizingNone;
    [UIView performWithoutAnimation:^{
        // ① 真实尺寸（不含 transform）
        CGRect b = self.bounds;
        b.size = target;
        self.bounds = b;
        // ② 确保没有残留的自我 transform
        //    ⚠️ 绝不能设 Invert(host.transform)：父层 transform 是渲染时的继承，
        //    子视图再叠一个逆矩阵 = 反向放大（1.4.9 的 bug）。
        if (!CGAffineTransformIsIdentity(self.transform)) {
            self.transform = CGAffineTransformIdentity;
        }
        // ③ center 对齐 host 中心（host.bounds.origin 恒为 0，844/844 实证）
        self.center = wantCenter;
    }];
    [self setNeedsLayout];
}

// 【v1.4.12 ★★★ 新增：宿主几何变化 → 立刻重贴】
//
// 【为什么光靠 layoutSubviews 不够】
//   展开/折叠/滑动时，是【cell 的 frame/transform 在变】，背景自己的
//   bounds/center 没变 → 系统认为背景"不需要重新布局" → 不调用它的
//   layoutSubviews。于是背景的尺寸和位置停在动画开始前那一帧，
//   屏幕上就表现为"卡片动、素材不动"。
//
// 【解法】从 cell 侧主动来敲门。cell 的 layoutSubviews、
//   setFrame:/setBounds:/setCenter:/setTransform: 一旦被调用，就通知背景：
//   "宿主几何变了，你再算一遍"。syncToHostIfNeeded 里带了三项判据，
//   真的没变化时会直接 return，不会产生多余开销。
// 【⚠️ v1.4.13 必加的重入保护 —— v1.4.12 卡死的第二重隐患】
//   syncToHostIfNeeded 内部会设置 self.bounds / self.center，
//   这会让 UIKit 标记"需要重新布局" → 稍后回调 self.layoutSubviews
//   → 而 layoutSubviews 第一件事又调 syncToHostIfNeeded。
//   正常情况判据会收敛（v1.4.13 的判据全是直接比较、不经变换往返），
//   但只要出现任何意料之外的抖动，就会变成【无限递归】把主线程锁死。
//   加一个"正在同步中"的内存标记：递归进来时直接返回。
//   这类保护在 hook 系统视图时是必须的 —— 别指望判据一定完美。
- (void)notifyHostGeometryChanged {
    if (self.lnbSyncing) return;   // 正在同步中，直接返回，物理杜绝递归
    self.lnbSyncing = YES;
    [self syncToHostIfNeeded];
    self.lnbSyncing = NO;
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
    // 【v1.4.6 同款修复】原来写 bgView.frame = hostView.bounds;
    // frame 属于父坐标系、bounds 属于自身坐标系，两者混用会在
    // hostView.bounds.origin 非零时把背景推到错误位置并钉死。
    // 改为设 bounds（继承尺寸）+ center（对齐可视区中心）。
    {
        CGRect gb = bgView.bounds;
        gb.size = hostView.bounds.size;
        bgView.bounds = gb;
        bgView.center = CGPointMake(CGRectGetMidX(hostView.bounds),
                                    CGRectGetMidY(hostView.bounds));
    }
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
    // 【v1.4.9】这里继续用 bounds：本判断的语义是"这条 cell 到底有没有
    //   完成布局"，而 bounds 才是布局的产物（frame 含 transform，
    //   展开动画起始帧会被缩到 10% → 30x6，用 frame 判断会误杀）。
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

    // 【v1.4.9 ★★★ 最终定论：跟 frame（视觉尺寸）+ 抵消父层 transform】
    //
    // ── 三轮排查的完整脉络 ──
    //
    // 1.4.6~1.4.7：以为是 bounds.origin 的问题，改用 bg.bounds = cell.bounds。
    //              → 折叠态看着没问题，展开态依旧错（见 1.4.8 日志）。
    //
    // 1.4.8：翻查 193175 行日志，发现 frame/bounds 比值是 0.77/0.88/0.94/1.00
    //        且每个比值宽高完全相同 → 判定为等比 transform 缩放，
    //        于是改回 bg.bounds.size = cell.bounds.size（真实尺寸）。
    //
    // 1.4.9（本轮，197414 行新日志）：用户反馈「折叠态能跟、展开态不能跟」，
    //        顺着这个提示做配对统计，真相浮出水面：
    //
    //          bgBounds == cellBounds : 1138/1138 (100%)   ← 代码确实写对了
    //          bgFrame  == cellBounds : 1138/1138 (100%)   ← 背景视觉尺寸 = cellBounds
    //          cellFrame/cellBounds 缩放比: 0.1 / 0.92 / 0.94 / 0.975 / 0.989 / 1.0
    //
    //        典型展开动画逐帧：
    //          cellFrame= 30.88x 6.60  scale=0.100 | bgFrame=308.77x66.00
    //          cellFrame=308.77x66.00  scale=1.000 | bgFrame=308.77x66.00
    //          cellFrame= 30.88x 6.60  scale=0.100 | bgFrame=308.77x66.00
    //        → 卡片在 10%↔100% 之间跳，背景【一次都没动】。
    //
    //        ✗ 跟 bounds：尺寸是"未缩放"的。折叠态卡片不缩放，
    //          cellBounds==cellFrame，背景【碰巧】对上了；
    //          展开态卡片被缩放，背景尺寸不变 → 大一圈、位置错 → 不跟。
    //        ✗ 跟 frame ：尺寸是"已缩放"的，但背景是子视图会自动继承
    //          父层 transform → 缩放算两遍（1.4.7 的错）。
    //
    // ── 1.4.9 的错：加逆矩阵抵消 → 引出「主卡片和选项糊成一块」 ──
    //   1.4.9 写了：bg.bounds.size = cellView.frame.size(视觉尺寸)
    //               bg.transform   = CGAffineTransformInvert(cellView.transform)
    //   看似"抵消父层缩放"，实则两头都错：
    //     ① 尺寸取 frame（已含缩放），父层又会再缩放一次 → 双重缩放；
    //     ② 逆矩阵让背景【反向放大】，cell 被缩到 0.1 时背景被放大 10 倍，
    //        直接撑爆到卡片外面，把「选项」按钮整个盖住 ——
    //        这正是用户说的"主卡片和选项给删除搞一块了"。
    //
    // ── v1.4.11 正解：什么都不用做，背景天然跟随 ──
    //   背景是 cell 的子视图，它【本来就自动继承父层的 transform】。
    //   父层缩放时，子视图跟着缩放，这是 UIKit 的内建行为，不需要也不该插手。
    //   唯一要做的只有一件事：
    //        bg.bounds.size = cellView.bounds.size   （真实尺寸，不含 transform）
    //        bg.center      = cell 中心
    //   然后父层的 transform 会自然把背景一起缩放 → 屏幕上的视觉尺寸
    //   恰好等于 cell 的视觉尺寸，位置也严丝合缝。
    //
    //   这就是 v1.4.8 的做法。回头看，1.4.6~1.4.8 的 bounds 路线一直是对的，
    //   1.4.9 那次"发现"（改用 frame + 逆矩阵）纯粹是我把 UIKit 的继承
    //   语义想复杂了，反而制造了 bug。
    //
    //   【为什么本轮日志会误判成"背景一次都没动"】
    //   因为 1.4.8 的 syncToHostIfNeeded 里有一句提前 return：
    //       if (CGSizeEqualToSize(self.bounds.size, target)) return;
    //   而 target 取的是 host.bounds.size，恒为 308.77x66（不含 transform），
    //   判断恒为"相等" → 每次都 return，自跟踪代码从没执行过。
    //   所以问题不在"跟 bounds 还是跟 frame"，而在那句 return 写错了。
    //
    // ── v1.4.13 【回退 v1.4.12 的 frame + 逆矩阵方案】──
    //   v1.4.12 的 `bg.transform = Invert(cell.transform); bg.frame = cell.frame`
    //   导致手机卡死（详见 syncToHostIfNeeded 上方的完整事故复盘）：
    //   设了逆矩阵后，"设进去的 frame" 与 "读出来的 frame" 永远不相等，
    //   判据不收敛 → 反复设置 → 触发 layoutSubviews → 无限递归。
    //
    //   正确做法（v1.4.11 已验证可用）：bounds 管尺寸、center 管位置、
    //   自己的 transform 保持恒等，父层 transform 自动继承。
    {
        CGSize target = cellView.bounds.size;
        if (target.width < 1.0 || target.height < 1.0) target = cellView.frame.size;
        if (target.width >= 1.0 && target.height >= 1.0) {
            CGPoint wantCenter = CGPointMake(CGRectGetMidX(cellView.bounds),
                                             CGRectGetMidY(cellView.bounds));
            bg.autoresizingMask = UIViewAutoresizingNone;
            [UIView performWithoutAnimation:^{
                CGRect b = bg.bounds;
                b.size = target;
                bg.bounds = b;
                if (!CGAffineTransformIsIdentity(bg.transform)) {
                    bg.transform = CGAffineTransformIdentity;
                }
                bg.center = wantCenter;
            }];
        }
    }

    // 【v1.4.12 ★★★ 把 cell 裁剪加回来 —— 用户给的参考视频就是这么做的】
    //
    //   ── v1.4.10 为什么删掉它 ──
    //     当时的背景带着 1.4.9 的逆矩阵，会反向放大 10 倍撑到卡片外面；
    //     而且「选项」按钮挂在 cell 子树的容器里，裁剪会把按钮切掉。
    //     于是我把 cellView.clipsToBounds 删了，想"用不裁剪的方式绕开"。
    //
    //   ── 为什么现在必须加回来 ──
    //     ① 溢出源已经不存在了：v1.4.12 的背景 bounds 恒等于 cell.bounds，
    //        视觉效果由逆变换精确对齐到 cell.frame，不会再有一寸溢出；
    //     ② 参考视频（用户指定要的那个效果）里，卡片就是【圆角裁剪】的 ——
    //        左滑拖动时素材不会超出卡片的圆角范围；
    //     ③ 万一系统动画中间帧出现亚像素级的边缘溢出，这一层裁剪能兜住，
    //        保证屏幕四周永远只有壁纸，不会闪出素材边缘。
    //
    //   【关于「按钮被裁掉」的担心】不再成立：
    //     PLActionButtonsPresentingView / NCToggleControl 在展开态本来就在
    //     cell 的 bounds 范围内（设备日志 30x66 ~ 154x66，均在 308.77x66 以内），
    //     masksToBounds 只裁掉【超出 bounds】的内容，框内的按钮完全不受影响。
    cellView.layer.masksToBounds = YES;

    // 【v1.4.12】日志加 bgVis 与【bg 屏幕投影】——
    //   bgVis 是背景的视觉尺寸，应恒等于 cellFrame.size；
    //   投影中心是背景在屏幕上的实际中心，应恒等于 cellFrame 的中心。
    //   两者一起看，才能同时抓住「尺寸没跟」和「位置没跟」两类问题。
    CGPoint projCenter = CGPointMake(CGRectGetMidX(bg.frame), CGRectGetMidY(bg.frame));
    projCenter = CGPointApplyAffineTransform(projCenter, cellView.transform);
    // 注意：bg.frame 已是父坐标系矩形，其中心再经父层 transform 才是屏幕位置
    CGPoint hostProjCenter = CGPointMake(CGRectGetMidX(cellView.frame),
                                         CGRectGetMidY(cellView.frame));
    hostProjCenter = CGPointApplyAffineTransform(hostProjCenter, cellView.transform);
    LNBTLog(@"[%@] 已同步 superview=%@ bgVis=%@ bgFrame=%@ bgTF=%d cellFrame=%@ cellBounds=%@ "
            @"bgProj=(%.1f,%.1f) hostProj=(%.1f,%.1f) 素材=%@",
            tagName,
            NSStringFromClass(bg.superview.class),
            [NSString stringWithFormat:@"%0.1fx%0.1f", bg.frame.size.width, bg.frame.size.height],
            NSStringFromCGRect(bg.frame),
            (int)!CGAffineTransformIsIdentity(bg.transform),
            NSStringFromCGRect(cellView.frame),
            NSStringFromCGRect(cellView.bounds),
            projCenter.x, projCenter.y, hostProjCenter.x, hostProjCenter.y,
            bg.preferVideo ? vidName : imgName);

    // 【v1.4.12】这里不再 layoutIfNeeded 强制同步 ——
    //   背景的几何在上面已经算好写进去了，强刷一次布局只会让展开动画多等
    //   一轮同步绘制（掉帧）。交给下一个 runloop 自然完成即可。
    [bg setNeedsLayout];
    [bg applyConfig:prefs];

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
    // 【v1.4.13】与 bg 完全同一套（回退到 bounds + center + transform 恒等）。
    {
        CGSize dtarget = cellView.bounds.size;
        if (dtarget.width < 1.0 || dtarget.height < 1.0) dtarget = cellView.frame.size;
        if (dtarget.width >= 1.0 && dtarget.height >= 1.0) {
            CGPoint dwantCenter = CGPointMake(CGRectGetMidX(cellView.bounds),
                                              CGRectGetMidY(cellView.bounds));
            dim.autoresizingMask = UIViewAutoresizingNone;
            [UIView performWithoutAnimation:^{
                CGRect db = dim.bounds;
                db.size = dtarget;
                dim.bounds = db;
                if (!CGAffineTransformIsIdentity(dim.transform)) {
                    dim.transform = CGAffineTransformIdentity;
                }
                dim.center = dwantCenter;
            }];
        }
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

// 【v1.4.8 ★★★】自动跟随宿主的图片视图。
//
// 【为什么需要这个子类】
//   1.4.7 及之前，按钮图是普通 UIImageView，尺寸只在 LNBApplyButtonBackground
//   被调用时同步一次。而按钮在「通知折叠 / 展开 / 列表滚动」时，其 layout
//   由系统驱动，中间若干帧不一定回调到我们的扫描逻辑 → 图就停在旧尺寸上，
//   表现为用户说的「不跟着按钮走」。
//
//   这里做成一个会自跟踪的子类：每次自己 layoutSubviews 时，先把自己
//   的尺寸重新对齐到 superview（按钮）的 bounds，再走正常渲染。
//   这样只要按钮动一帧，我们就在同一帧跟上，不依赖任何外部调度。
//
// 【为什么用 bounds 而不是 frame】
//   图片是按钮的子视图，渲染时自动继承按钮的 transform。用按钮的 frame
//   （已含 transform 缩放）当尺寸，会被再乘一次 → 双重缩放。
@interface LNBFollowImageView : UIImageView
@end

@implementation LNBFollowImageView

- (void)layoutSubviews {
    UIView *host = self.superview;
    if (host) {
        // 【v1.4.11】按钮图只在按钮自身坐标系里贴合：bounds 尺寸 + 居中。
        // 绝不设置 transform —— 按钮图是按钮的子视图，父层 transform 会
        // 自动作用于它，自己再叠一层就是 1.4.9 那种"反向放大"的 bug。
        CGSize target = host.bounds.size;
        if (target.width >= 1.0 && target.height >= 1.0) {
            BOOL sizeOk = CGSizeEqualToSize(self.bounds.size, target);
            BOOL tfOk   = CGAffineTransformIsIdentity(self.transform);
            if (!sizeOk || !tfOk) {
                self.autoresizingMask = UIViewAutoresizingNone;
                CGRect b = self.bounds;
                b.size = target;
                self.bounds = b;
                if (!CGAffineTransformIsIdentity(self.transform)) {
                    self.transform = CGAffineTransformIdentity;
                }
                self.center = CGPointMake(CGRectGetMidX(host.bounds),
                                          CGRectGetMidY(host.bounds));
            }
        }
    }
    [super layoutSubviews];
}

@end

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

    // 【v1.4.7】移除 animationKeys 判断（日志证明它恒为 0，从未生效）。
    // 【v1.4.8 ★★★】按钮尺寸取 view.bounds.size（不含 transform 的真实尺寸）。
    //   与卡片背景同一套定论：图片是按钮的子视图，渲染时自动继承按钮的
    //   transform。若用 frame.size（已含缩放），父层会再乘一次 → 双重缩放。
    //   按钮虽然通常不缩放，但保持一致才能避免用户在折叠/展开动画中看到抖动。

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
    //
    // 【v1.4.10 ★★★ 回退 1.4.9 的错误】按钮图【不做】任何 transform 抵消。
    //
    //   1.4.9 为了"和卡片统一"，给按钮图也加了
    //       iv.transform = CGAffineTransformInvert(view.transform);
    //   这是错的，而且破坏性很强：
    //     ① 按钮（PLPlatterActionButton / NCToggleControl）在正常状态下
    //        transform 是恒等 → 逆矩阵也是恒等 → 加了等于没加；
    //     ② 但一旦 view 有任何 transform，逆矩阵会把图片推到
    //        【远离按钮】的位置，视觉上就是"按钮背景和卡片背景糊成一块"；
    //     ③ 而且下面用的是 iv.center（父坐标系），和逆 transform 混在一起，
    //        坐标系不一致，必定错位。
    //
    //   正解：按钮图老老实实跟在按钮自身坐标系里 ——
    //   尺寸取 view.bounds.size（按钮自身坐标系的真实尺寸），
    //   居中在 view.bounds 中心。按钮不会被缩放，这就够了。
    LNBFollowImageView *iv = [[LNBFollowImageView alloc] initWithFrame:view.bounds];
    iv.contentMode = UIViewContentModeScaleAspectFill;
    iv.clipsToBounds = YES;
    iv.userInteractionEnabled = NO;
    iv.autoresizingMask = UIViewAutoresizingNone;
    iv.tag = tag;
    {
        // 尺寸：用按钮 bounds（自身坐标系的真实尺寸）。
        // 不用 frame —— frame 是父坐标系的，跨坐标系取值会错。
        CGSize ts = view.bounds.size;
        if (ts.width < 1.0 || ts.height < 1.0) ts = view.frame.size;
        CGRect ib = iv.bounds;
        ib.size = ts;
        iv.bounds = ib;
        // 居中在按钮自身坐标系中心
        iv.center = CGPointMake(CGRectGetMidX(view.bounds),
                                CGRectGetMidY(view.bounds));
    }
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

    // 【v1.4.10】诊断模式下，每次给按钮铺完图都 dump 一次按钮所在的那棵
    // 通知子树 —— 这是抓「主卡片背景和选项按钮糊成一块」的现场。
    // 只 dump 按钮的"通知体系祖先"这一层，避免整棵树太大刷爆日志。
    if (prefs.diagMode) {
        UIView *root = view;
        for (UIView *p = view.superview; p; p = p.superview) {
            NSString *c = NSStringFromClass(p.class);
            if ([c containsString:@"NCNotification"] || [c containsString:@"Platter"]) {
                root = p;
            } else {
                break;
            }
        }
        // 按钮自身的几何单独先打一行，方便和树里的记录对照
        LNBTLog(@"[按钮定位] %@ frame=%@ bounds=%@ center=(%.1f,%.1f)",
                NSStringFromClass(view.class),
                NSStringFromCGRect(view.frame), NSStringFromCGRect(view.bounds),
                view.center.x, view.center.y);
        LNBLogTreeNow(root, ([NSString stringWithFormat:@"按钮铺图后 \"%@\"",
                              label.length ? label : @"(无文字)"]));
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



// 【v1.4.12】cell 的几何同步助手：找出挂在它身上的背景 / 遮罩，叫它们重算。
//
// 【⚠️ 为什么是 C 函数而不是 UIView 分类方法】
//   Logos 展开后，%hook 块里的 self 类型是 `@class NCNotificationListCell`
//   —— 一个【前向声明】（iOS 16.5 公开 SDK 里没有这个私有类），
//   对前向声明的类型发自定义消息会直接编译报错：
//       error: receiver type 'NCNotificationListCell' for instance message
//              is a forward declaration
//   所以这里改成普通 C 函数，形参用 UIView*（完整类型），
//   hook 里传 (UIView *)self 即可，绕开 self 的类型问题。
//
// 【为什么用 setNeedsLayout 而不是直接同步算】
//   只是打标记，同一轮 runloop 内多次调用会被合并；
//   真正干活的是各视图自己的 layoutSubviews → syncToHostIfNeeded。
//
// 【v1.4.13 加时间闸门：每帧最多放行一次】
//   viewWithTag: 是递归遍历整棵子树的操作，展开动画每帧十几次调用
//   在锁屏上是可观的主线程负担（v1.4.12 卡死的一个诱因）。
//   这里用 CACurrentMediaTime 做闸门：间隔小于 1/120 秒的调用直接跳过。
//   代价最多是 8ms 的延迟（肉眼不可见），收益是主线程负载降一个量级。
//
//   【为什么跳过是安全的】cell 的 layoutSubviews 里还有一次兜底同步，
//   最坏也只错过动画中间的一帧，下一帧立刻补上，不会"永远停在旧位置"。
static void LNBSyncBGGeometry(UIView *cell) {
    if (!cell) return;

    // ── 时间闸门 ──
    static CFTimeInterval sLastSync = 0;
    CFTimeInterval now = CACurrentMediaTime();
    if (now - sLastSync < (1.0 / 120.0)) return;   // 同一帧内只放行一次
    sLastSync = now;

    UIView *bg = [cell viewWithTag:kCardBGViewTag];
    if ([bg isKindOfClass:[LNBGlobalBackgroundView class]]) {
        [(LNBGlobalBackgroundView *)bg notifyHostGeometryChanged];
    }
    UIView *dim = [cell viewWithTag:kCardDimViewTag];
    if (dim) [dim setNeedsLayout];
}

#pragma mark - Hook 入口

// 【v1.4.10】层级 dump 函数定义在下方（紧跟 NCNotificationListCell hook 之后），
// 但 hook 块里要先调用它 → 这里做前向声明，避免"未声明即使用"编译错误。
static void LNBDumpCellHierarchyIfNeeded(UIView *cell);

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
    // 【v1.4.10】层级快照 hook：展开/折叠状态切换时 dump 一次完整视图树，
    // 用来定位「主卡片背景和选项按钮糊成一块」到底是谁盖谁、在哪个坐标系。
    LNBDumpCellHierarchyIfNeeded((UIView *)self);
}

// 【v1.4.12 ★★★ 核心新增：几何变化即时同步】
//
// 【要解决什么】展开/折叠/左右滑卡片时，变的是 cell 自己的
//   frame / bounds / center / transform，背景的 bounds 并没有变 ——
//   系统因此判定背景"无需重新布局"，不调用它的 layoutSubviews。
//   结果就是：卡片在动，卡片里的素材停在原地（"展开态不跟随"的真正原因）。
//
// 【解法】在 cell 这四个 setter 里，改完之后主动把背景叫醒，
//   让它按新的 cell 几何重算一遍。动画由 Core Animation 驱动、每一帧
//   都会经过这些 setter（或至少 layoutSubviews），所以背景能逐帧跟上。
//
// 【为什么四个都要 hook】
//   frame setter 会连带改 center+bounds，但在 objc 消息转发下
//   【不会】再走一遍 setBounds:/setCenter:，所以只 hook 一个是不够的。
//   四个都 hook，用 setNeedsLayout 做合并去重，避免重复计算。

// 【⚠️ v1.4.13 性能约束 —— 这是 v1.4.12 卡死的诱因之一】
//   v1.4.12 把 LNBSyncBGGeometry 直接接在四个 setter 上，展开动画里
//   每帧会调用十几次，而它内部要做 viewWithTag:（递归遍历 cell 整棵子树，
//   几十个视图）。在锁屏这种主线程本就紧张的场景下是实打实的负担。
//   v1.4.13 的应对有两层：
//     ① LNBSyncBGGeometry 内部加"每帧只放行一次"的时间闸门；
//     ② 真正的几何写入具备收敛性（bounds + center，不经变换往返），
//        配合重入保护，从机制上不可能形成递归。
//   宁可少同步一帧，也绝不能让锁屏卡顿 —— 这是 v1.4.12 事故的教训。
- (void)setFrame:(CGRect)frame {
    %orig(frame);
    LNBSyncBGGeometry((UIView *)self);
}

- (void)setBounds:(CGRect)bounds {
    %orig(bounds);
    LNBSyncBGGeometry((UIView *)self);
}

- (void)setCenter:(CGPoint)center {
    %orig(center);
    LNBSyncBGGeometry((UIView *)self);
}

- (void)setTransform:(CGAffineTransform)transform {
    %orig(transform);
    LNBSyncBGGeometry((UIView *)self);
}

%end



// 【v1.4.10 ★★★ 新增：视图层级 dump hook】
//
// 【要解决什么】用户反馈「主卡片和选项被删到一块了」—— 典型的层级/坐标系问题：
//   ① 卡片背景（我们的子视图，atIndex:0）盖住了按钮？
//   ② 按钮背景的 transform 把它推到了卡片位置？
//   ③ 两者的 superview 其实是同一个，互相重叠？
//   光看尺寸日志看不出来，必须看【完整视图树】：每层的类名、frame、bounds、
//   center、transform、z 序（同级先后）、hidden、alpha、clip。
//
// 【什么时候 dump】每张 cell 都 dump 会刷爆日志（列表里几十条）。
//   只在"状态发生变化"时 dump：进入展开 或 从展开退出，各 dump 一次。
//   判定"展开"：cell.transform 非恒等（被缩放）→ 就是展开/折叠动画中。
//   状态没变就不重复输出。
static void LNBDumpCellHierarchyIfNeeded(UIView *cell) {
    if (!cell) return;
    LNBPrefs *prefs = [LNBPrefs sharedInstance];
    if (!prefs.diagMode) return;   // 只在诊断模式开着时刷，避免拖累正常使用

    static const void *kLNBLastExpandState = &kLNBLastExpandState;   // per-cell

    BOOL nowExpanded = !CGAffineTransformIsIdentity(cell.transform);
    NSNumber *last = objc_getAssociatedObject(cell, kLNBLastExpandState);
    if (last && last.boolValue == nowExpanded) return;   // 状态没变，跳过

    objc_setAssociatedObject(cell, kLNBLastExpandState, @(nowExpanded),
                             OBJC_ASSOCIATION_RETAIN);

    NSString *state = nowExpanded ? @"进入展开/缩放态" : @"退出展开→稳定态";
    // 从 cell 往上找到"最高的通知相关祖先"再 dump，这样能同时看到
    // 卡片、按钮、以及它们共同的外层容器 —— 只 dump cell 内部会漏掉
    // 「按钮其实挂在 cell 外面」这种情况。
    UIView *root = cell;
    for (UIView *p = cell.superview; p; p = p.superview) {
        NSString *c = NSStringFromClass(p.class);
        if ([c containsString:@"NCNotification"] || [c containsString:@"Platter"]) {
            root = p;
        } else {
            break;
        }
    }

    // 先用 LNBLogTreeNow 打完整层级（含每层 frame/bounds/center/transform/z序）
    LNBLogTreeNow(root, ([NSString stringWithFormat:@"%@ cell=%@",
                          state, NSStringFromClass(cell.class)]));

    // 再补一段「我方视图定位」小结：把我们挂的三个东西的几何单独列出来，
    // 直击「谁盖谁 / 谁跑偏了」这个问题，不用在长树里翻找。
    NSMutableString *out = [NSMutableString stringWithFormat:
        @"[我方视图定位] cell=%@\n", NSStringFromClass(cell.class)];
    UIView *myBG = [cell viewWithTag:kCardBGViewTag];
    if (myBG) {
        [out appendFormat:@"  卡片背景 tag=0x%lX frame=%@ bounds=%@ center=(%.1f,%.1f) tf=%d z=%ld\n",
            (long)kCardBGViewTag, NSStringFromCGRect(myBG.frame),
            NSStringFromCGRect(myBG.bounds), myBG.center.x, myBG.center.y,
            (int)!CGAffineTransformIsIdentity(myBG.transform),
            (long)[cell.subviews indexOfObject:myBG]];
    } else {
        [out appendString:@"  卡片背景: 未挂载\n"];
    }
    UIView *myDim = [cell viewWithTag:kCardDimViewTag];
    if (myDim) {
        [out appendFormat:@"  卡片遮罩 tag=0x%lX frame=%@ z=%ld\n",
            (long)kCardDimViewTag, NSStringFromCGRect(myDim.frame),
            (long)[cell.subviews indexOfObject:myDim]];
    }
    // 按钮图可能挂在 cell 直系，也可能挂在按钮自己身上（多数情况）。
    // 这里两种情况都扫一遍，便于确认它到底在哪一层。
    for (UIView *b1 in cell.subviews) {
        if (b1.tag == kSuppBtn1Tag || b1.tag == kSuppBtn2Tag) {
            [out appendFormat:@"  按钮图 tag=0x%lX 挂在【cell 直系】frame=%@ z=%ld\n",
                (long)b1.tag, NSStringFromCGRect(b1.frame),
                (long)[cell.subviews indexOfObject:b1]];
        }
    }
    {
        NSMutableArray *stack = [NSMutableArray arrayWithObject:cell];
        while (stack.count > 0) {
            UIView *v = stack.lastObject; [stack removeLastObject];
            for (UIView *sub in v.subviews) {
                if (sub.tag == kSuppBtn1Tag || sub.tag == kSuppBtn2Tag) {
                    [out appendFormat:@"  按钮图 tag=0x%lX 挂在【%@】frame=%@\n",
                        (long)sub.tag, NSStringFromClass(v.class),
                        NSStringFromCGRect(sub.frame)];
                }
                [stack addObject:sub];
            }
        }
    }
    LNBTLog(@"%@", out);
}

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
