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
//  v2.1.1 滑动跟随（关键实测反馈驱动）：
//    用户实测：折叠状态滑动 = cell 本体动，挂 cell 的背景自动跟随 ✓；
//    展开后滑动 = cell 内部内容容器动，cell 不动，背景钉住 ✗ ——
//    且 v2.0.3 的 NCNotificationListCellScrollView hook 从未生效
//   （iOS 10 时代的类，iOS 16.5 上不存在）。
//    修法：背景直接挂进滑动容器（cell.contentView 体系，v2.1.1 起为
//    挂载点），目标 frame = cell.bounds 在容器坐标系的 convert 投影
//   （v2.0.2 的溢出问题由此彻底修正）。折叠/展开两种状态均结构保证跟随。
//    镜像机制（LNBMirrorSwipe / scrollview hook）随之移除。
//
//  v2.2.0 设置面板回归 + 模块化素材（新视频需求驱动）：
//    用户新视频实证：选项按钮（PLPlatterActionButton）、清除按钮、折叠按钮
//    （NCToggleControl，v1.4.5 日志实锤的类名）也透出整屏画面。
//    需求："通知、插件背景、通知背景、选项模块、清除模块都能自定义
//    背景素材（图片或视频），要有设置面板，效果和视频一样。"
//    本版交付：
//    ① 恢复设置面板（v1.4.16 的 prefs 子项目 + 相册选素材 + 改动即时生效）；
//    ② 整屏背景（global.*）、卡片（card.*）、选项按钮（supp.*）、
//       清除按钮（supp2.*）全部支持图片和视频，面板内独立选择；
//    ③ 按钮模块：没选素材时自动"透出化"（藏材质+清底色）—— 参考视频
//       效果；选了素材则铺自己的圆角图/视频（v1.4.16 铺图逻辑移植）；
//    ④ 共享播放器升级为【按素材路径分组的播放器池】—— 多种素材同时
//       播放（整屏+卡片+按钮）各自独立解码、同素材多卡片仍同帧；
//    ⑤ 声音按面板设置（静音/音量），改动即时生效。
//
//  v2.1.2 全屏视频层重构（最新实测对比驱动）：
//    用户两个视频对比结论：插件折叠滑动跟随已 ✓，但卡片外是静态壁纸、
//    滑开后露出白色「清除」按钮；参考效果是【整屏连续视频 + 卡片挖洞
//    透出对应位置画面 + 清除按钮浮在视频上】。
//    差距根源 = 缺一层可靠铺满全屏的视频背景。三处修正：
//    ① 素材自动全屏化：global.mp4 优先，缺失时 card.mp4 兜底 ——
//       只装一个素材也能得到参考效果（v2.1.1 必须装 global 才走透明模式）；
//    ② 全屏层挂"锁屏根"（anchor 的 window 直接子视图中包含 anchor 的
//       ≥0.9 屏大视图），插入位置 = 类名含 wallpaper 的直接子视图之上，
//       没有则 index 0 —— 视频位于壁纸之上、时钟/通知列表/清除按钮之下，
//       滑开空隙透视频、按钮浮视频上，全是结构保证；
//    ③ 卡片统一透明暗化模式（16% 暗化板），删除"卡片独立铺 card.mp4"
//       旧模式 —— 参考视频卡片根本没有独立视频层。
//    全屏层也改走共享播放器（进程内唯一解码器，卡片暗化板零解码）。
//
//  v2.2.5 按钮继承卡片素材（用户点题：要的就是朋友视频里
//    「消息通知/选项/删除」三个模块的模式 —— M8 逐帧实证）：
//    ① 消息通知卡：素材铺满+文字浮上（v2.2.3 已达成 ✓）
//    ② 左滑「选项/清除」按钮：各自铺素材，文字（红色"清除"）浮上；
//       朋友"清除"按钮铺的正是和卡片同款的橙色鸭子素材！
//    修法：按钮素材回退链末端从"透出化"改为"继承卡片素材"——
//    用户只选一个卡片素材 = 卡片+选项+清除全套统一，开箱即朋友效果；
//    面板里仍可给按钮单独选素材（supp/supp2 优先）。
//
//  v2.2.4 素材暗化（v2.2.3 实测 M6 vs M7 复盘）：
//    垫底生效：文字/头像已浮在素材上 ✓（与朋友结构对齐）。
//    剩余感知差距：用户的亮素材（人脸/写字视频）白字压上去几乎看不清，
//    朋友的素材本身均匀偏暗（暗橙鸭子），文字才天然清楚。
//    修法：LNBBGView 加 dimOverlay（黑色覆盖层，素材之上内容之下），
//    面板新增"素材暗化"滑块 cardDim（0~0.6，默认 0.20）——
//    亮素材调到 30~40% 即可达到朋友素材的文字可读性。
//
//  v2.2.3 素材垫底修正（v2.2.2 实测 M4 vs M5 对比复盘）：
//    挖洞/全屏已对齐朋友（红发壁纸全屏连续 ✓），但独立素材模式下
//    紫色素材把卡片标题/正文/头像全部盖死（朋友视频 M5 里文字清晰
//    浮在素材上）。根因：bg 固定挂 contentView atIndex:0，但 iOS 17
//    通知 cell 的内容不在常规子链上层。修法：LNBContentInsertIndex
//    收集 slide 内所有 UILabel/UIImageView，爬到直接子视图层取最靠前
//    的 index —— 素材/暗化板永远垫在内容之下；已挂载的层级漂移也补了
//    重垫逻辑。
//
//  v2.2.2 回归朋友效果的本源（v2.2.1 实测复盘）：
//    用户实测暴露两个问题：① 整屏层挂载仍不稳（紫色素材只铺了通知区域，
//    时钟/下半屏还是壁纸）；② card 素材被兜底拿去铺"半截屏幕"→ 视觉全乱。
//    想通的本质：朋友视频里的整屏画面 = 朋友自己的【视频壁纸】
//   （用户最早就澄清过"整个屏幕那是人家壁纸"，用户手机也装了视频壁纸 App）。
//    朋友插件要做的从来不是自己画整屏层，而是【把卡片挖成透明洞】——
//    壁纸在所有锁屏内容之下，卡片透明 = 透出壁纸对应区域，天然连续、
//    天然跟随、天然多卡对齐，零挂载风险。
//    本版结构：
//    ① 卡片挖洞不再依赖整屏层：只要"挖洞透出整屏"开着，卡片就是
//       一块 16% 暗化板，透出底下的一切（视频壁纸 / 静态壁纸 / 整屏层）；
//    ② global.* 与 card.* 职责彻底分离：整屏层只认 global.*（可选增强，
//       给没装视频壁纸 App 的场景），card.* 只做卡片独立素材；
//    ③ 按钮透出化不变（透出壁纸）。
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
#import <notify.h>
#import <objc/runtime.h>
#import <stdarg.h>

#pragma mark - 常量

static NSString *const kBGDirectory   = @"/var/mobile/Library/LockNotifyBG";
static NSString *const kCardVideo     = @"card.mp4";
static NSString *const kCardImage     = @"card.jpg";
static NSString *const kGlobalVideo   = @"global.mp4";
static NSString *const kGlobalImage   = @"global.jpg";
// 【v2.2.0】按钮模块素材：选项 = supp.*，清除 = supp2.*（清除缺省回退 supp.*）
static NSString *const kSuppVideo     = @"supp.mp4";
static NSString *const kSuppImage     = @"supp.jpg";
static NSString *const kSupp2Video    = @"supp2.mp4";
static NSString *const kSupp2Image    = @"supp2.jpg";

static const NSInteger kCardBGViewTag   = 0x4C4E4243;   // 'LNBC'
static const NSInteger kGlobalBGViewTag = 0x4C4E4247;   // 'LNBG'
static const NSInteger kActionBGViewTag = 0x4C4E4241;   // 'LNBA'（按钮独立素材层）

// 【v2.2.0】设置面板域与跨进程同步（与 prefs 面板代码一致）
static NSString *const kPrefsDomain        = @"com.hchdjej.locknotifybg";
static NSString *const kReloadNotification = @"com.hchdjej.locknotifybg/reload";
static NSString *const kPrefsFilePath      = @"/var/mobile/Library/LockNotifyBG/prefs.plist";

// 被本插件藏掉的毛玻璃视图，用关联对象记账，还原时不误伤别人藏的
static const void *kLNBHiddenByTweak = &kLNBHiddenByTweak;

// 背景视图自身的同步重入保护（关联对象，避免给 UIView 加类别属性）
static const void *kLNBSyncingKey = &kLNBSyncingKey;

// 背景的目标 frame（关联对象，NSValue 包装）。
// 【v2.1.1】背景挂进滑动容器后，目标 = cell.bounds 在容器坐标系里的投影；
// 挂 cell 时目标 = 铺满 cell。滑动期间 target 不变（结构保证跟随）。
static const void *kLNBTargetFrameKey = &kLNBTargetFrameKey;

// 【v2.2.0】按钮"透出化"记账：原底色快照（UIColor）+ 当前状态
static const void *kLNBBtnOrigBgKey  = &kLNBBtnOrigBgKey;
static const void *kLNBBtnSeeThrough = &kLNBBtnSeeThrough;

#pragma mark - 偏好（v2.2.0 设置面板）

// 面板把设置镜像落盘到 prefs.plist（跨进程最稳通道，v1.x 实证），
// 改动时面板发 Darwin 通知，这里监听后重读 —— 所有修改即时生效。
@interface LNBPrefs : NSObject
@property (nonatomic, assign) BOOL enabled;             // 总开关（默认 YES）
@property (nonatomic, assign) BOOL globalEnabled;       // 整屏背景（默认 YES）
@property (nonatomic, assign) BOOL cardTransparent;     // 卡片挖洞透整屏（默认 YES）
@property (nonatomic, assign) CGFloat dimAlpha;         // 卡片暗化强度（默认 0.16）
@property (nonatomic, assign) CGFloat cardDim;          // 卡片素材暗化（默认 0.20，v2.2.4）
@property (nonatomic, assign) BOOL suppModuleEnabled;   // 按钮背景（默认 YES）
@property (nonatomic, assign) CGFloat suppAlpha;        // 按钮素材不透明度（默认 1.0）
@property (nonatomic, assign) BOOL videoMuted;          // 静音（默认 YES）
@property (nonatomic, assign) double videoVolume;       // 音量（默认 0.6）
+ (instancetype)sharedInstance;
- (void)reload;
@end

@implementation LNBPrefs

+ (instancetype)sharedInstance {
    static LNBPrefs *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        s = [[LNBPrefs alloc] init];
        [s reload];
        int token = 0;
        notify_register_dispatch([kReloadNotification UTF8String], &token,
                                 dispatch_get_main_queue(), ^(int flag) {
            [[LNBPrefs sharedInstance] reload];
        });
    });
    return s;
}

- (void)reload {
    // 文件缺失（首次安装/没打开过面板）时用默认值
    NSDictionary *saved = [NSDictionary dictionaryWithContentsOfFile:kPrefsFilePath];
    self.enabled           = saved[@"enabled"]           ? [saved[@"enabled"] boolValue]           : YES;
    self.globalEnabled     = saved[@"globalEnabled"]     ? [saved[@"globalEnabled"] boolValue]     : YES;
    self.cardTransparent   = saved[@"cardTransparent"]   ? [saved[@"cardTransparent"] boolValue]   : YES;
    self.dimAlpha          = saved[@"dimAlpha"]          ? [saved[@"dimAlpha"] doubleValue]        : 0.16;
    self.cardDim           = saved[@"cardDim"]           ? [saved[@"cardDim"] doubleValue]         : 0.20;
    self.suppModuleEnabled = saved[@"suppModuleEnabled"] ? [saved[@"suppModuleEnabled"] boolValue] : YES;
    self.suppAlpha         = saved[@"suppAlpha"]         ? [saved[@"suppAlpha"] doubleValue]       : 1.0;
    self.videoMuted        = saved[@"videoMuted"]        ? [saved[@"videoMuted"] boolValue]        : YES;
    self.videoVolume       = saved[@"videoVolume"]       ? [saved[@"videoVolume"] doubleValue]     : 0.6;
}

@end

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

// 【v2.2.2】解析整屏素材：只认 global.*。
// card.* 是卡片独立素材，不再兜底铺全屏（v2.2.1 实测：卡片素材铺半截
// 屏幕导致整屏混乱）。用户要整屏视频：装视频壁纸 App（朋友的方式），
// 或放一个 global.mp4（插件可选增强）。
static void LNBResolveFullMedia(NSString **outVid, NSString **outImg) {
    *outVid = nil;
    *outImg = nil;
    if (LNBFileExists(LNBPathForResource(kGlobalVideo))) *outVid = kGlobalVideo;
    else if (LNBFileExists(LNBPathForResource(kGlobalImage))) *outImg = kGlobalImage;
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

#pragma mark - 播放器池（v2.2.0：按素材路径分组）

// v2.1.x 的单例共享播放器只支持一种素材；v2.2.0 整屏/卡片/按钮可能同时
// 使用不同素材 —— 升级为按路径分组的池：同一素材的多个 layer 共享一个
// AVPlayer（同帧是结构保证），不同素材各自独立解码互不干扰。
// 文件被更换（size/mtime 变化）时对应条目自动重建。
// 【判据纪律】（v1.4.12 教训）：只用指针/路径/字典直接比较，绝不做"设进去再读回"。
static NSMutableDictionary<NSString *, AVPlayer *>     *lnbPoolPlayer = nil;
static NSMutableDictionary<NSString *, NSNumber *>     *lnbPoolRefs   = nil;
static NSMutableDictionary<NSString *, NSNumber *>     *lnbPoolSize   = nil;
static NSMutableDictionary<NSString *, NSNumber *>     *lnbPoolMTime  = nil;
static NSMutableDictionary<NSString *, id>             *lnbPoolEndObs = nil;

static void LNBPoolInit(void) {
    if (!lnbPoolPlayer) {
        lnbPoolPlayer = [NSMutableDictionary dictionary];
        lnbPoolRefs   = [NSMutableDictionary dictionary];
        lnbPoolSize   = [NSMutableDictionary dictionary];
        lnbPoolMTime  = [NSMutableDictionary dictionary];
        lnbPoolEndObs = [NSMutableDictionary dictionary];
    }
}

static BOOL LNBPoolEntryMatches(NSString *path) {
    LNBPoolInit();
    if (!path || !lnbPoolPlayer[path]) return NO;
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
    if (!attrs) return NO;
    return ([attrs fileSize] == [lnbPoolSize[path] unsignedLongLongValue] &&
            fabs([[attrs fileModificationDate] timeIntervalSince1970] - [lnbPoolMTime[path] doubleValue]) < 0.5);
}

static AVPlayer *LNBPoolPlayerFor(NSString *path) {
    LNBPoolInit();
    return path ? lnbPoolPlayer[path] : nil;
}

static void LNBPoolDestroyEntry(NSString *path) {
    id obs = lnbPoolEndObs[path];
    if (obs) [[NSNotificationCenter defaultCenter] removeObserver:obs];
    [lnbPoolPlayer[path] pause];
    [lnbPoolPlayer removeObjectForKey:path];
    [lnbPoolSize removeObjectForKey:path];
    [lnbPoolMTime removeObjectForKey:path];
    [lnbPoolEndObs removeObjectForKey:path];
    [lnbPoolRefs removeObjectForKey:path];
}

static void LNBPoolApplyAudio(NSString *path, AVPlayer *p) {
    LNBPrefs *prefs = [LNBPrefs sharedInstance];
    p.muted  = prefs.videoMuted;
    p.volume = prefs.videoVolume;
}

// 领播放器（同素材引用计数 +1；从空闲恢复时回片头）
static AVPlayer *LNBPoolAcquire(NSString *path) {
    LNBPoolInit();
    if (!LNBPoolEntryMatches(path)) LNBPoolDestroyEntry(path);
    AVPlayer *p = lnbPoolPlayer[path];
    if (!p) {
        AVPlayerItem *item = [AVPlayerItem playerItemWithURL:[NSURL fileURLWithPath:path]];
        p = [AVPlayer playerWithPlayerItem:item];
        p.actionAtItemEnd = AVPlayerActionAtItemEndNone;
        NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
        lnbPoolSize[path]  = @([attrs fileSize]);
        lnbPoolMTime[path] = @([[attrs fileModificationDate] timeIntervalSince1970]);
        lnbPoolEndObs[path] = [[NSNotificationCenter defaultCenter]
            addObserverForName:AVPlayerItemDidPlayToEndTimeNotification
                        object:item queue:nil
                    usingBlock:^(NSNotification *note) {
                AVPlayer *pl = lnbPoolPlayer[path];
                if (!pl) return;
                [pl seekToTime:kCMTimeZero completionHandler:^(BOOL done) {
                    if (done && pl.rate == 0.0) [pl play];
                }];
            }];
        lnbPoolPlayer[path] = p;
    }
    BOOL wasIdle = ([lnbPoolRefs[path] integerValue] == 0);
    lnbPoolRefs[path] = @([lnbPoolRefs[path] integerValue] + 1);
    LNBPoolApplyAudio(path, p);
    if (wasIdle) {
        [p seekToTime:kCMTimeZero];
        [p play];
    } else if (p.rate == 0.0) {
        [p play];
    }
    return p;
}

// 还播放器（同素材引用计数 -1；归零即暂停回片头，省电）
static void LNBPoolDetach(NSString *path) {
    if (!path) return;
    LNBPoolInit();
    NSInteger refs = [lnbPoolRefs[path] integerValue];
    if (refs <= 1) {
        [lnbPoolPlayer[path] pause];
        [lnbPoolPlayer[path] seekToTime:kCMTimeZero];
        lnbPoolRefs[path] = @0;
    } else {
        lnbPoolRefs[path] = @(refs - 1);
    }
}

#pragma mark - 背景视图（图片/视频通用容器）

@interface LNBBGView : UIView
@property (nonatomic, strong) UIImageView *imageView;
@property (nonatomic, strong) AVPlayerLayer *playerLayer;
@property (nonatomic, strong) CALayer *dimOverlay;      // 素材暗化层（v2.2.4）
@property (nonatomic, copy) NSString *attachedPath;    // 池内关联的素材路径（v2.2.0）
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
        // 【v2.2.4】素材暗化层：压在素材（playerLayer/imageView）之上、
        // 卡片内容之下（bg 整体垫在内容下），黑素材变暗 → 白字浮出。
        _dimOverlay = [CALayer layer];
        _dimOverlay.backgroundColor = [UIColor blackColor].CGColor;
        _dimOverlay.opacity = 0.0;
        _dimOverlay.hidden = YES;
        _dimOverlay.frame = self.bounds;
        [self.layer addSublayer:_dimOverlay];
    }
    return self;
}

// 【v2.1.0 透明卡片模式】不放任何媒体，只做半透明暗化板。
// 全屏视频层（global.mp4）透过它显示 —— 卡片内外画面连续，
// 与参考视频一致（卡片内亮度 ≈ 卡片外 × 0.84，即压暗 ~16%）。
- (void)applyDimOnlyWithAlpha:(CGFloat)alpha {
    // 幂等早退：已是相同暗化状态就不再动（layout 每帧都会调）
    if (self.imageView.hidden && !self.playerLayer && !self.attachedPath &&
        self.backgroundColor && self.dimOverlay.hidden) {
        CGFloat r, g, b, a;
        if ([self.backgroundColor getRed:&r green:&g blue:&b alpha:&a] &&
            fabs(a - alpha) < 0.005) return;
    }
    [self teardownMedia];
    self.imageView.hidden = YES;
    self.dimOverlay.hidden = YES;   // 挖洞模式用底色暗化，不用素材暗化层
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
    // 【v2.2.4】素材暗化：panel cardDim 滑块（0~0.6），默认 0.20。
    // 亮素材压暗后白字自然浮出（朋友素材本身均匀偏暗，文字才清楚）。
    CGFloat dim = [LNBPrefs sharedInstance].cardDim;
    self.dimOverlay.opacity = dim;
    self.dimOverlay.hidden = (dim <= 0.005);
    self.dimOverlay.frame = self.bounds;
    [self setNeedsLayout];
}

- (void)setupVideoWith:(NSString *)videoPath {
    // 统一走播放器池：同素材多 layer 共享（同帧），不同素材各解码
    if (self.playerLayer && [self.attachedPath isEqualToString:videoPath] &&
        self.playerLayer.player == LNBPoolPlayerFor(videoPath)) {
        return;   // 已挂对，无事可做
    }
    [self teardownMedia];
    AVPlayer *p = LNBPoolAcquire(videoPath);
    self.attachedPath = [videoPath copy];
    self.playerLayer = [AVPlayerLayer playerLayerWithPlayer:p];
    self.playerLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
    self.playerLayer.frame = self.bounds;
    [self.layer insertSublayer:self.playerLayer atIndex:0];
}

- (void)teardownMedia {
    if (self.playerLayer) {
        [self.playerLayer removeFromSuperlayer];
        self.playerLayer = nil;
    }
    if (self.attachedPath) {
        LNBPoolDetach(self.attachedPath);
        self.attachedPath = nil;
    }
}

// 【v2.1.1】对齐"目标 frame"：
//   · 挂进滑动容器时，target = cell 在容器坐标系里的投影（存关联对象）；
//   · 挂 cell 时，target = 铺满宿主。
// 滑动期间 target 不变 —— 容器动则背景作为子视图随之动（结构保证跟随），
// 本函数只负责把 frame 收敛到 target。判据直接比较，必然收敛。
- (void)syncToHostIfNeeded {
    NSValue *tv = objc_getAssociatedObject(self, kLNBTargetFrameKey);
    CGRect target;
    if (tv) {
        target = tv.CGRectValue;
    } else {
        UIView *host = self.superview;
        if (!host) return;
        CGSize sz = host.bounds.size;
        if (sz.width < 1.0 || sz.height < 1.0) return;
        target = CGRectMake(0.0, 0.0, sz.width, sz.height);   // 挂 cell：铺满宿主
    }
    if (target.size.width < 1.0 || target.size.height < 1.0) return;

    BOOL frameOk = CGSizeEqualToSize(self.frame.size, target.size) &&
                   fabs(self.frame.origin.x - target.origin.x) < 0.01 &&
                   fabs(self.frame.origin.y - target.origin.y) < 0.01;
    BOOL tfOk = CGAffineTransformIsIdentity(self.transform);
    if (frameOk && tfOk) return;

    self.autoresizingMask = UIViewAutoresizingNone;
    [UIView performWithoutAnimation:^{
        if (!CGAffineTransformIsIdentity(self.transform)) self.transform = CGAffineTransformIdentity;
        self.frame = target;
    }];
}

// 列表宿主缓存（全屏背景层的挂载点，弱引用）。
// 弱引用：列表销毁后自动失效，下次 layout 重新查找。
static __weak UIView *lnbListHostCache = nil;
static UIView *LNBAnchorToLockRoot(UIView *anchor);       // 前向声明（定义在下方）
static UIView *LNBGlobalBackgroundHost(UIView *anchor, UIView **outAnchorView);

- (void)layoutSubviews {
    NSNumber *syncing = objc_getAssociatedObject(self, kLNBSyncingKey);
    if (!syncing.boolValue) {
        objc_setAssociatedObject(self, kLNBSyncingKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [self syncToHostIfNeeded];
        objc_setAssociatedObject(self, kLNBSyncingKey, @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    [super layoutSubviews];
    if (!CGRectEqualToRect(_imageView.frame, self.bounds)) _imageView.frame = self.bounds;
    if (!CGRectEqualToRect(_dimOverlay.frame, self.bounds)) _dimOverlay.frame = self.bounds;   // v2.2.4

    if (self.playerLayer) {
        // 背景铺满自身 bounds（自身=滑动容器里的卡片层）。
        // 左滑时随宿主内容一起平移，裁切交给滚动容器/屏幕边缘。
        self.playerLayer.frame = self.bounds;   // 无条件赋值，不做读回比较
    }
}

- (void)dealloc {
    if (_attachedPath) {
        LNBPoolDetach(_attachedPath);
        _attachedPath = nil;
    }
}

@end

#pragma mark - 卡片背景

// 【v2.1.1】找卡片的"滑动容器"。
// 实测结论（用户视频）：折叠状态滑动 = cell 本体动（挂 cell 自动跟随 ✓）；
// 展开状态滑动 = cell 内部内容容器动，cell 不动（挂 cell 不跟随 ✗），
// 且 NCNotificationListCellScrollView 是 iOS 10 时代的类、hook 从未生效。
// 所以把背景直接挂进内容容器 —— 容器动则背景作为子视图随之动，结构保证。
//
// 识别策略：
//   ① BFS 找 NCNotificationListCellScrollView（老系统兜底）；
//   ② 找不到 → cell.contentView（UICollectionViewCell 标准容器，
//      iOS 16 通知左滑平移的就是它）；
//   ③ 再失败 → cell 直接子视图中最大的合格者
//      （≥70% 宽高、非毛玻璃、非隐藏、非背景自身 —— 深度优先取最深）。
static UIView *LNBFindSlideContainer(UIView *cell) {
    CGSize cs = cell.bounds.size;
    if (cs.width < 1.0 || cs.height < 1.0) return nil;

    // ① 老系统的滚动容器
    NSMutableArray *queue = [NSMutableArray arrayWithObject:cell];
    NSInteger steps = 0;
    while (queue.count > 0 && steps < 512) {
        UIView *v = queue.firstObject;
        [queue removeObjectAtIndex:0];
        steps++;
        if (v != cell &&
            [NSStringFromClass(v.class) isEqualToString:@"NCNotificationListCellScrollView"]) {
            return v;
        }
        for (UIView *sub in v.subviews) [queue addObject:sub];
    }

    // ② 标准 contentView
    UIView *cv = nil;
    if ([cell isKindOfClass:[UICollectionViewCell class]]) {
        cv = [(UICollectionViewCell *)cell contentView];
    }
    if (cv && !cv.hidden && cv.alpha > 0.05 && !LNBIsBlurMaterial(cv)) return cv;

    // ③ 最大的合格直接子视图（DFS 取最深）
    UIView *best = nil;
    CGFloat bestArea = 0;
    NSInteger bestDepth = -1;
    NSMutableArray *stack  = [NSMutableArray arrayWithObject:cell];
    NSMutableArray *depths = [NSMutableArray arrayWithObject:@0];
    while (stack.count > 0) {
        UIView *v = stack.lastObject;
        NSInteger d = [depths.lastObject integerValue];
        [stack removeLastObject];
        [depths removeLastObject];
        if (v != cell && !v.hidden && v.alpha > 0.05 &&
            ![v isKindOfClass:[LNBBGView class]] && !LNBIsBlurMaterial(v)) {
            CGFloat w = v.frame.size.width, h = v.frame.size.height;
            if (w >= cs.width * 0.7 && h >= cs.height * 0.7) {
                CGFloat area = w * h;
                if (d > bestDepth || (d == bestDepth && area > bestArea)) {
                    best = v; bestArea = area; bestDepth = d;
                }
            }
        }
        for (UIView *sub in v.subviews) {
            [stack addObject:sub];
            [depths addObject:@(d + 1)];
        }
    }
    return best;
}

// 【v2.2.3】素材必须垫在内容之下（朋友视频 M5 实证：文字/头像浮在素材上）。
// 在 slide 子树里收集所有含 UILabel/UIImageView 的视图，沿 superview
// 爬到 slide 的直接子视图层，取其中最靠前的 index —— bg 插到这个
// index，标题/正文/时间/头像必然浮在素材之上。找不到内容 → 0 兜底。
static NSInteger LNBContentInsertIndex(UIView *slide) {
    NSMutableArray *stack = [NSMutableArray arrayWithObject:slide];
    NSInteger steps = 0, best = 0;
    BOOL has = NO;
    while (stack.count > 0 && steps < 768) {
        UIView *v = stack.lastObject;
        [stack removeLastObject];
        steps++;
        if (v != slide && !v.hidden &&
            ([v isKindOfClass:[UILabel class]] || [v isKindOfClass:[UIImageView class]])) {
            UIView *p = v;
            while (p.superview && p.superview != slide) p = p.superview;
            if (p.superview == slide) {
                NSInteger i = (NSInteger)[slide.subviews indexOfObject:p];
                if (i != NSNotFound && (!has || i < best)) { best = i; has = YES; }
            }
        }
        for (UIView *sub in v.subviews) [stack addObject:sub];
    }
    return has ? best : 0;
}

// 给一条通知卡片挂背景。
// 【v2.1.1】背景挂进滑动容器（cell.contentView 体系），目标 frame =
// cell.bounds 在容器坐标系里的投影 —— 尺寸精确锁定卡片可视区
//（v2.0.2 的"按宿主铺"导致溢出，convert 投影彻底修正）。
// 折叠状态：cell 本体动 → 背景随动 ✓；展开状态：容器动 → 背景随动 ✓。
static void LNBApplyCardBackground(UIView *cell) {
    if (!cell) return;
    NSString *cls = NSStringFromClass(cell.class);
    if (![cls isEqualToString:@"NCNotificationListCell"]) return;

    // 【v2.2.0】卡片行为由面板决定：
    //   A. 插件关闭 / 无任何素材 → 还原原生样式
    //   B. 挖洞透出整屏（cardTransparent，默认）→ 暗化板透出锁屏根上的整屏层
    //   C. 独立素材模式（关闭挖洞）→ 卡片铺 card.*，多卡共享同一播放器同帧
    LNBPrefs *prefs = [LNBPrefs sharedInstance];
    BOOL hasCardVideo = LNBFileExists(LNBPathForResource(kCardVideo));
    BOOL hasCardImage = LNBFileExists(LNBPathForResource(kCardImage));

    // 【v2.2.2】挖洞不再依赖整屏层：挖洞 = 藏白底 + 16% 暗化板，
    // 透出底下的一切（视频壁纸/静态壁纸/整屏层）—— 壁纸在所有卡片之下，
    // 天然连续、天然跟随，零挂载风险（朋友效果的本源）。
    BOOL hasCard = (hasCardVideo || hasCardImage);
    if (!prefs.enabled) {
        LNBSetCardMaterialsHidden(cell, NO);
        UIView *old = [cell viewWithTag:kCardBGViewTag];
        if (old) [old removeFromSuperview];
        return;
    }

    BOOL transparent = prefs.cardTransparent;              // 挖洞（默认）
    BOOL standalone  = !prefs.cardTransparent && hasCard;  // 独立素材
    if (!transparent && !standalone) {
        LNBSetCardMaterialsHidden(cell, NO);
        UIView *old = [cell viewWithTag:kCardBGViewTag];
        if (old) [old removeFromSuperview];
        return;
    }

    LNBSetCardMaterialsHidden(cell, YES);

    // cell 本体不裁切：滑动中背景要能滑出 cell 边界，由屏幕边缘完成裁切
    cell.layer.masksToBounds = NO;

    // 滑动容器与目标投影
    UIView *slide = LNBFindSlideContainer(cell);
    CGRect target;
    if (slide && slide != cell) {
        target = [cell convertRect:cell.bounds toView:slide];
    } else {
        slide = cell;
        target = cell.bounds;
    }

    LNBBGView *bg = (LNBBGView *)[cell viewWithTag:kCardBGViewTag];
    if (!bg) {
        bg = [[LNBBGView alloc] initWithFrame:target];
        bg.tag = kCardBGViewTag;
    }
    // 【v2.2.3】插入点 = 内容锚点之下：素材垫底，文字/头像浮在素材上
    //（v2.2.2 固定 atIndex:0 在真机上被实测打脸 —— 内容不在 contentView
    // 常规子链上层，紫色素材直接盖死了标题/正文/头像，M4 视频实证）。
    NSInteger wantIdx = LNBContentInsertIndex(slide);
    if (bg.superview != slide) {
        [bg removeFromSuperview];
        [slide insertSubview:bg atIndex:wantIdx];
    } else if ((NSInteger)[slide.subviews indexOfObject:bg] > wantIdx) {
        // 已挂载但层级漂移（内容容器重建后 bg 被顶到内容之上）→ 重新垫底
        [slide insertSubview:bg atIndex:wantIdx];
    }
    objc_setAssociatedObject(bg, kLNBTargetFrameKey, [NSValue valueWithCGRect:target],
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    // 圆角自补（保持原生卡片圆角观感）
    CGFloat radius = cell.layer.cornerRadius > 0 ? cell.layer.cornerRadius : 18.0;
    if (fabs(bg.layer.cornerRadius - radius) > 0.5) bg.layer.cornerRadius = radius;

    if (standalone) {
        // 独立素材模式：卡片铺 card.*（面板里关掉"挖洞透出整屏"）
        [bg applyMediaWithVideo:(hasCardVideo ? kCardVideo : nil)
                          image:(hasCardVideo ? nil : kCardImage)];
    } else {
        // 挖洞模式：半透明暗化板，透出锁屏根上的整屏视频层
        [bg applyDimOnlyWithAlpha:prefs.dimAlpha];
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

#pragma mark - 选项 / 清除 / 折叠按钮（v2.2.0）

// 收集一个视图子树里的所有文字（按钮归属判定用）
static NSString *LNBGatherText(UIView *root) {
    NSMutableString *acc = [NSMutableString string];
    NSMutableArray *stack = [NSMutableArray arrayWithObject:root];
    NSInteger steps = 0;
    while (stack.count > 0 && steps < 256) {
        UIView *v = stack.lastObject;
        [stack removeLastObject];
        steps++;
        if ([v isKindOfClass:[UILabel class]]) {
            if (acc.length) [acc appendString:@" "];
            [acc appendString:[(UILabel *)v text] ?: @""];
        }
        for (UIView *sub in v.subviews) [stack addObject:sub];
    }
    return acc;
}

// 按钮候选判定 —— 全部来自 v1.4.x 十几轮设备日志实证：
//   ✅ NCToggleControl         45x34 / 66x34 "清除"、折叠开关
//   ✅ PLPlatterActionButton   77x66 "选项" / 73x66 "清除"
//   ❌ PLActionButtonsPresentingView（容器，铺了会盖住子按钮）
//   ❌ Coalescing / Pair / Header*（容器与标题）
static BOOL LNBIsCandidateActionButton(UIView *v) {
    if (!v) return NO;
    CGSize sz = v.bounds.size;
    if (sz.width < 20.0 || sz.height < 20.0) return NO;   // 未布局的 {0,0}
    if (sz.width > 260.0 || sz.height > 120.0) return NO;

    NSString *cls = NSStringFromClass(v.class);
    if ([cls isEqualToString:@"NCToggleControl"]) return YES;
    if ([cls isEqualToString:@"PLPlatterActionButton"]) return YES;

    if ([cls containsString:@"ActionButtonsPresenting"]) return NO;
    if ([cls containsString:@"Coalescing"])      return NO;
    if ([cls containsString:@"HeaderTitle"])     return NO;
    if ([cls containsString:@"HeaderCell"])      return NO;
    if ([cls containsString:@"Pair"])            return NO;
    if ([cls containsString:@"SectionHeader"])   return NO;
    if ([cls containsString:@"SectionView"])     return NO;
    if ([cls containsString:@"Avatar"])          return NO;
    if ([cls containsString:@"BadgedIcon"])      return NO;
    if ([cls isEqualToString:@"UIImageView"])    return NO;
    if ([cls isEqualToString:@"UILabel"])        return NO;

    // 其它自定义按钮兜底：类名含 Button 且祖先在通知体系内
    if ([cls containsString:@"Button"]) {
        for (UIView *p = v.superview; p; p = p.superview) {
            if ([NSStringFromClass(p.class) containsString:@"NCNotification"]) return YES;
        }
    }
    return NO;
}

// 按钮"透出化"：藏材质 + 清底色 → 透出底下的整屏画面（参考视频效果）。
// 原底色用 UIColor 快照记账，开关关闭时还原。
static void LNBSetButtonSeeThrough(UIView *btn, BOOL on) {
    BOOL cur = [objc_getAssociatedObject(btn, kLNBBtnSeeThrough) boolValue];
    if (on == cur) return;
    if (on) {
        LNBSetCardMaterialsHidden(btn, YES);
        CGColorRef cg = btn.layer.backgroundColor;
        UIColor *snap = cg ? [UIColor colorWithCGColor:cg] : nil;
        objc_setAssociatedObject(btn, kLNBBtnOrigBgKey, snap, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        btn.layer.backgroundColor = [UIColor clearColor].CGColor;
        objc_setAssociatedObject(btn, kLNBBtnSeeThrough, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else {
        UIColor *snap = objc_getAssociatedObject(btn, kLNBBtnOrigBgKey);
        btn.layer.backgroundColor = snap.CGColor;
        LNBSetCardMaterialsHidden(btn, NO);
        objc_setAssociatedObject(btn, kLNBBtnSeeThrough, @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

// 给单个按钮挂背景：
//   归属（v1.4.5 定论，先判「选项」再判「清除」，折叠跳过独立素材）：
//     含「选项」不含「清除」 → supp.*；含「清除」 → supp2.*（缺省回退 supp.*）
//   有素材 → 铺圆角图/视频（文字天然浮在最上）；无素材 → 透出化
static void LNBApplyButtonBackground(UIView *btn) {
    if (!btn) return;
    LNBPrefs *prefs = [LNBPrefs sharedInstance];
    BOOL wantOn = prefs.enabled && prefs.suppModuleEnabled;

    // 先清掉本按钮上已铺的独立素材层
    UIView *oldMedia = [btn viewWithTag:kActionBGViewTag];
    if (oldMedia) [oldMedia removeFromSuperview];

    if (!wantOn) {
        LNBSetButtonSeeThrough(btn, NO);
        return;
    }

    NSString *label = LNBGatherText(btn);
    NSString *lower = label.lowercaseString;
    BOOL hasOption = ([label containsString:@"选项"] || [lower containsString:@"option"]);
    BOOL hasClear  = ([label containsString:@"清除"] || [lower containsString:@"clear"]);
    BOOL isClear   = hasClear && !hasOption;   // 「清除」用 supp2.*

    // 素材回退链：清除 supp2.* → supp.*；选项 supp.* → supp2.*（反向兜底）
    NSString *vidName = isClear ? kSupp2Video : kSuppVideo;
    NSString *imgName = isClear ? kSupp2Image : kSuppImage;
    if (!LNBFileExists(LNBPathForResource(vidName)) &&
        !LNBFileExists(LNBPathForResource(imgName))) {
        vidName = isClear ? kSuppVideo : kSupp2Video;
        imgName = isClear ? kSuppImage : kSupp2Image;
    }
    // 【v2.2.5】按钮没专设素材 → 直接继承卡片素材：
    // 只选一个卡片素材，卡片+选项+清除全套统一（朋友视频里"清除"
    // 按钮铺的正是和卡片同款的橙色鸭子素材，红字"清除"浮在上面）。
    if (!LNBFileExists(LNBPathForResource(vidName)) &&
        !LNBFileExists(LNBPathForResource(imgName))) {
        vidName = kCardVideo;
        imgName = kCardImage;
    }
    BOOL hasMedia = LNBFileExists(LNBPathForResource(vidName)) ||
                    LNBFileExists(LNBPathForResource(imgName));

    if (!hasMedia) {
        // 参考视频效果：按钮区域透出整屏画面，文字浮在上面
        LNBSetButtonSeeThrough(btn, YES);
        return;
    }

    // 有素材：铺圆角媒体层（插 index 0，按钮文字/图标天然浮上）
    LNBSetButtonSeeThrough(btn, NO);
    LNBBGView *bg = (LNBBGView *)[btn viewWithTag:kActionBGViewTag];
    if (!bg) {
        bg = [[LNBBGView alloc] initWithFrame:btn.bounds];
        bg.tag = kActionBGViewTag;
    }
    [bg removeFromSuperview];
    [btn insertSubview:bg atIndex:0];

    CGFloat cr = btn.layer.cornerRadius;
    if (cr <= 0.5) {
        CGFloat shortSide = MIN(btn.bounds.size.width, btn.bounds.size.height);
        cr = shortSide * 0.3;   // v1.4.5 定论：短边 30%，接近圆角方块而非胶囊
    }
    bg.layer.cornerRadius = cr;
    bg.layer.masksToBounds = YES;
    bg.alpha = prefs.suppAlpha;
    [bg applyMediaWithVideo:(LNBFileExists(LNBPathForResource(vidName)) ? vidName : nil)
                      image:(LNBFileExists(LNBPathForResource(vidName)) ? nil : imgName)];
}

// 按钮扫描（0.25s 节流）：在通知相关子树里找候选按钮逐个应用
static CFTimeInterval lnbBtnScanLast = 0;

static void LNBScanButtonsIfNeeded(UIView *root) {
    if (!root) return;
    CFTimeInterval now = CACurrentMediaTime();
    if (now - lnbBtnScanLast < 0.25) return;
    lnbBtnScanLast = now;

    NSMutableArray *stack = [NSMutableArray arrayWithObject:root];
    NSInteger steps = 0;
    while (stack.count > 0 && steps < 512) {
        UIView *v = stack.lastObject;
        [stack removeLastObject];
        steps++;
        if (LNBIsCandidateActionButton(v)) LNBApplyButtonBackground(v);
        for (UIView *sub in v.subviews) [stack addObject:sub];
    }
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
// 【v2.2.1 挂载点重构】v2.1.2/v2.2.0 实测：锁屏根查找经常落空或 z 位置
// 不对，整屏层回退到 NC 列表宿主 → 只覆盖列表区域 → 卡片外是静态壁纸。
// 新策略（按可靠度排序，找到即用）：
//   ① 在 anchor 所在窗口里 BFS 找类名含 "wallpaper" 的视图 W
//      （iOS 16 壁纸视图：CSModernWallpaperView / SBWallpaperView 一族），
//      宿主 = W 的父视图，插入 = 壁纸正上方 —— 结构上必然：铺满（壁纸全屏）、
//      可见（壁纸之上）、被内容盖住（时钟/通知 z 更高）、不在滚动容器内。
//   ② 锁屏根 R（anchor 向上第一个 ≥0.9 屏祖先）内找"不含 anchor 的最大
//      全屏子视图"B —— 大概率是壁纸分支，插入 = B 之上。
//   ③ 锁屏根 R，atIndex 0。
//   ④ 旧 NC 宿主兜底。
// outAnchorView 输出"插入锚点"：非空 → aboveSubview:它；空 → atIndex:0。
static UIView *LNBGlobalBackgroundHost(UIView *anchor, UIView **outAnchorView) {
    if (outAnchorView) *outAnchorView = nil;

    UIWindow *win = anchor.window;
    NSArray<UIWindow *> *windows = win ? @[win] : [UIApplication sharedApplication].windows;

    // ── 策略①：壁纸视图定位 ──
    for (UIWindow *window in windows) {
        if (window.isHidden || window.alpha < 0.01) continue;
        NSMutableArray *queue = [NSMutableArray arrayWithObject:window];
        NSInteger steps = 0;
        while (queue.count > 0 && steps < 1024) {
            UIView *view = queue.firstObject;
            [queue removeObjectAtIndex:0];
            steps++;
            if (![view isKindOfClass:[LNBBGView class]] &&
                [NSStringFromClass(view.class).lowercaseString containsString:@"wallpaper"] &&
                view.superview) {
                if (outAnchorView) *outAnchorView = view;
                return view.superview;
            }
            for (UIView *sub in view.subviews) [queue addObject:sub];
        }
    }

    // ── 策略②③：锁屏根 ──
    UIView *root = LNBAnchorToLockRoot(anchor);
    if (root) {
        CGSize screen = root.bounds.size;
        // ② 不含 anchor 的最大全屏子视图（疑似壁纸分支）
        UIView *best = nil;
        CGFloat bestArea = 0;
        for (UIView *v in root.subviews) {
            if (anchor && [anchor isDescendantOfView:v]) continue;
            CGSize bs = v.bounds.size;
            if (bs.width >= screen.width * 0.9 && bs.height >= screen.height * 0.9) {
                CGFloat area = bs.width * bs.height;
                if (area > bestArea) { best = v; bestArea = area; }
            }
        }
        if (best) {
            if (outAnchorView) *outAnchorView = best;
            return root;
        }
        // ③ 锁屏根最底层
        return root;
    }

    // ── 策略④：旧 NC 宿主兜底（v2.0.4 逻辑）──
    for (UIWindow *window in windows) {
        if (window.isHidden || window.alpha < 0.01) continue;
        NSMutableArray *queue = [NSMutableArray arrayWithObject:window];
        NSInteger steps = 0;
        while (queue.count > 0 && steps < 1024) {
            UIView *view = queue.firstObject;
            [queue removeObjectAtIndex:0];
            steps++;
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
    // anchor 向上爬大祖先（原兜底）
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

// 【v2.1.2】anchor 所在的"锁屏根"：window 的直接子视图中、包含 anchor 的
// 那个 ≥0.9 屏大视图。全屏视频层挂它 → 不在任何滚动/裁剪容器内，
// 折叠、展开、左滑全部天然不动；时钟/通知/清除按钮都是它的后代，
// 全部浮在视频上（z 顺序结构保证）。
static UIView *LNBAnchorToLockRoot(UIView *anchor) {
    if (!anchor) return nil;
    UIWindow *w = anchor.window;
    if (!w) return nil;
    CGSize screen = w.bounds.size;
    for (UIView *v in w.subviews) {
        if (v == anchor) continue;   // anchor 本身就是 window 直接子视图（罕见），跳过
        if ([anchor isDescendantOfView:v]) {
            CGSize bs = v.bounds.size;
            if (bs.width >= screen.width * 0.9 && bs.height >= screen.height * 0.9) return v;
        }
    }
    return nil;
}

// 【v2.1.2】host 的直接子视图中的壁纸视图（类名含 wallpaper，不区分大小写）。
// 找到 → 视频插它上面；找不到 → index 0（锁屏根的 index 0 通常是内容容器）。
static UIView *LNBFindWallpaperSubview(UIView *host) {
    for (UIView *v in host.subviews) {
        NSString *low = NSStringFromClass(v.class).lowercaseString;
        if ([low containsString:@"wallpaper"]) return v;
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

    // 【v2.2.0】面板开关：整屏层受 enabled + globalEnabled 双重控制
    LNBPrefs *prefs = [LNBPrefs sharedInstance];
    NSString *fullVid = nil, *fullImg = nil;
    LNBResolveFullMedia(&fullVid, &fullImg);
    BOOL wantGlobal = prefs.enabled && prefs.globalEnabled;
    if (!wantGlobal || (!fullVid && !fullImg)) {
        // 关闭 / 无素材：清理所有历史挂载
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

    // 【v2.2.1】宿主多级查找（壁纸定位优先），并拿到插入锚点
    UIView *anchorView = nil;
    UIView *host = LNBGlobalBackgroundHost(anchor, &anchorView);
    if (!host) return;

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
        // 【v2.2.1】挂载诊断日志：下次实测 syslog 里直接看挂到哪了
        LNBTLog(@"整屏层挂载：host=%@ bounds=%@ 插入=%@",
                NSStringFromClass(host.class),
                NSStringFromCGRect(host.bounds),
                anchorView ? [NSStringFromClass(anchorView.class) stringByAppendingString:@" 之上"] : @"index0");
    }

    // 每次复查都走一遍素材匹配（setupVideoWith 内部幂等：已挂对直接返回；
    // 文件被更换时 size/mtime 变化 → 自动重建播放器）
    [bg applyMediaWithVideo:fullVid image:fullImg];

    // 【v2.2.1】插入位置：锚点视图（壁纸）之上；无锚点 → 最底层
    if (bg.superview != host) {
        [bg removeFromSuperview];
        if (anchorView && anchorView.superview == host) [host insertSubview:bg aboveSubview:anchorView];
        else    [host insertSubview:bg atIndex:0];
    }

    // 铺满宿主（bounds+center 赋值，判据纪律）
    CGRect hb = host.bounds;
    bg.bounds = CGRectMake(0.0, 0.0, hb.size.width, hb.size.height);
    bg.center = CGPointMake(CGRectGetMidX(hb), CGRectGetMidY(hb));
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
    LNBScanButtonsIfNeeded((UIView *)self);
}
%end

%hook NCNotificationListSectionView
- (void)layoutSubviews {
    %orig;
    LNBEnsureListBackground((UIView *)self);
    LNBScanButtonsIfNeeded((UIView *)self);
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
    LNBScanButtonsIfNeeded((UIView *)self);
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
    [[LNBPrefs sharedInstance] reload];
    LNBTLog(@"v2.2.5 loaded — 素材目录 %@；三模块统一（卡片/选项/清除，按钮继承卡片素材）", kBGDirectory);
}
%end
