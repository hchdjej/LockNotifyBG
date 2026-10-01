//
//  NGBPrefsRootListController.m
//  LockNotifyBG 偏好设置面板
//
//  PSListController 子类。声明部分逐行对照 theos/headers/Preferences 官方头文件：
//  PSSpecifier.h / PSListController.h / PSViewController.h / PSTableCell.h
//
//  关键教训（由设备端日志定位）：
//   1. PSSpecifier 的 action 是 @public ivar，没有 setAction: 方法 —— 用 .action
//      会编译成 setAction: 消息导致 unrecognized selector 闪退；正确写法是 ->action。
//      按钮行则优先用 buttonAction 属性（iOS 9+）。
//   2. preferenceSpecifierNamed: 的 cell: 参数是 PSCellType 枚举，不是字符串。
//   3. PSListController 依赖 _specifiers ivar 生成分组索引，getter 必须写入它。
//

#import <UIKit/UIKit.h>
#import <MobileCoreServices/MobileCoreServices.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <PhotosUI/PhotosUI.h>
#import <objc/runtime.h>
#import <notify.h>

#pragma mark - Preferences 私有框架最小声明（照抄 theos/headers）

typedef NS_ENUM(NSInteger, PSCellType) {
	PSGroupCell,
	PSLinkCell,
	PSLinkListCell,
	PSListItemCell,
	PSTitleValueCell,
	PSSliderCell,
	PSSwitchCell,
	PSStaticTextCell,
	PSEditTextCell,
	PSSegmentCell,
	PSGiantIconCell,
	PSGiantCell,
	PSSecureEditTextCell,
	PSButtonCell,
	PSEditTextViewCell,
	PSSpinnerCell
};

@interface PSSpecifier : NSObject {
@public
	SEL action;
}
+ (instancetype)preferenceSpecifierNamed:(NSString *)identifier target:(id)target set:(SEL)set get:(SEL)get detail:(Class)detail cell:(PSCellType)cellType edit:(Class)edit;
+ (instancetype)groupSpecifierWithName:(NSString *)name;

@property (nonatomic, retain) id target;
@property (nonatomic, retain) NSString *name;
@property (nonatomic) PSCellType cellType;
@property (nonatomic) SEL buttonAction;
@property (nonatomic, retain) NSMutableDictionary *properties;

- (id)propertyForKey:(NSString *)key;
- (void)setProperty:(id)property forKey:(NSString *)key;
- (id)performGetter;
- (void)performSetterWithValue:(id)value;
@end

@interface PSViewController : UIViewController
- (id)readPreferenceValue:(PSSpecifier *)specifier;
- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier;
@end

@interface PSListController : PSViewController <UITableViewDelegate, UITableViewDataSource> {
	NSMutableArray *_specifiers;
}
@property (nonatomic, retain) UITableView *table;
@property (nonatomic, retain) NSMutableArray *specifiers;
- (PSSpecifier *)specifierAtIndexPath:(NSIndexPath *)indexPath;
- (void)reloadSpecifiers;
- (void)reloadSpecifier:(PSSpecifier *)specifier animated:(BOOL)animated;
@end

#define kPrefsDomain        @"com.hchdjej.locknotifybg"
#define kReloadNotification @"com.hchdjej.locknotifybg/reload"
#define kBGDirectory        @"/var/mobile/Library/LockNotifyBG"
#define kBGGlobalImage      @"global.jpg"
#define kBGGlobalVideo      @"global.mp4"
#define kBGCardImage        @"card.jpg"
#define kBGCardVideo        @"card.mp4"
// v1.3.6：附属按钮模块（删除 / 选项）独立素材
#define kBGSuppImage        @"supp.jpg"
#define kBGSuppVideo        @"supp.mp4"

#pragma mark - 资源管理工具

@interface LNBFileManager : NSObject
+ (BOOL)ensureDirectory;
+ (NSString *)pathForFile:(NSString *)name;
+ (BOOL)copyFileAtURL:(NSURL *)url toName:(NSString *)name error:(NSError **)error;
+ (BOOL)removeFileNamed:(NSString *)name;
+ (BOOL)fileExistsNamed:(NSString *)name;
+ (void)postReload;
@end

@implementation LNBFileManager

+ (BOOL)ensureDirectory {
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:kBGDirectory]) return YES;

    NSError *error = nil;
    BOOL ok = [fm createDirectoryAtPath:kBGDirectory
            withIntermediateDirectories:YES
                             attributes:@{NSFilePosixPermissions: @(0755)}
                                  error:&error];
    if (!ok) return NO;

    [fm setAttributes:@{NSFilePosixPermissions: @(0755)}
         ofItemAtPath:kBGDirectory error:nil];
    return YES;
}

+ (NSString *)pathForFile:(NSString *)name {
    return [kBGDirectory stringByAppendingPathComponent:name];
}

+ (BOOL)copyFileAtURL:(NSURL *)url toName:(NSString *)name error:(NSError **)error {
    if (!url) {
        if (error) *error = [NSError errorWithDomain:@"LockNotifyBG" code:1
                                           userInfo:@{NSLocalizedDescriptionKey: @"无效的文件地址"}];
        return NO;
    }
    [self ensureDirectory];

    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *dest = [self pathForFile:name];

    if ([fm fileExistsAtPath:dest]) [fm removeItemAtPath:dest error:nil];

    BOOL ok = [fm copyItemAtURL:url toURL:[NSURL fileURLWithPath:dest] error:error];
    if (ok) [fm setAttributes:@{NSFilePosixPermissions: @(0644)} ofItemAtPath:dest error:nil];
    return ok;
}

+ (BOOL)removeFileNamed:(NSString *)name {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *path = [self pathForFile:name];
    if (![fm fileExistsAtPath:path]) return YES;
    return [fm removeItemAtPath:path error:nil];
}

+ (BOOL)fileExistsNamed:(NSString *)name {
    return [[NSFileManager defaultManager] fileExistsAtPath:[self pathForFile:name]];
}

+ (void)postReload {
    notify_post([kReloadNotification UTF8String]);
}

@end

#pragma mark - 诊断日志

// 采集开关：设置为 0 即可出无日志的正式版
#define LNB_DEBUG_LOG 0

static void LNBLog(NSString *fmt, ...) {
#if LNB_DEBUG_LOG
    va_list args;
    va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);

    NSString *dir = @"/var/mobile/Library/LockNotifyBG";
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *path = [dir stringByAppendingPathComponent:@"prefs.log"];
    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    df.dateFormat = @"HH:mm:ss.SSS";
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [df stringFromDate:[NSDate date]], msg];

    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!fh) {
        [line writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    } else {
        [fh seekToEndOfFile];
        [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    }
#endif
}

#pragma mark - specifier 构造辅助

static PSSpecifier *LNBGroup(NSString *header, NSString *footer) {
    PSSpecifier *s = [PSSpecifier groupSpecifierWithName:header];
    if (footer) [s setProperty:footer forKey:@"footerText"];
    return s;
}

// 开关行。
//
// 【踩坑】set/get 传 nil 时，偏好设置框架自己去找取值路径：
// 它只认 `defaults` + `key` 这套「框架内建 plist 托管」，并**不会**回头调用
// 控制器的 setPreferenceValue:specifier: —— 结果就是开关能拨但值不落盘，
// 表现为「点了没反应」。必须显式把 target/set/get 绑到控制器上。
// set: 的签名固定为 setPreferenceValue:specifier:（PSSpecifier 作为第二参数传入）。
static PSSpecifier *LNBSwitch(id target, NSString *label, NSString *key) {
    PSSpecifier *s = [PSSpecifier preferenceSpecifierNamed:label
                                                    target:target
                                                       set:@selector(setPreferenceValue:specifier:)
                                                       get:@selector(readPreferenceValue:)
                                                    detail:nil
                                                      cell:PSSwitchCell
                                                      edit:nil];
    [s setProperty:key forKey:@"key"];
    [s setProperty:@YES forKey:@"default"];
    return s;
}

static PSSpecifier *LNBSlider(id target, NSString *label, NSString *key, double min, double max) {
    PSSpecifier *s = [PSSpecifier preferenceSpecifierNamed:label
                                                    target:target
                                                       set:@selector(setPreferenceValue:specifier:)
                                                       get:@selector(readPreferenceValue:)
                                                    detail:nil
                                                      cell:PSSliderCell
                                                      edit:nil];
    [s setProperty:key forKey:@"key"];
    [s setProperty:@(min) forKey:@"min"];
    [s setProperty:@(max) forKey:@"max"];
    [s setProperty:@YES forKey:@"showValue"];
    return s;
}

// 按钮行：buttonAction 属性 + ->action ivar 双保险，再用 lnbAction 兜底
static PSSpecifier *LNBButton(id target, NSString *label, SEL sel, NSString *actionKey) {
    PSSpecifier *s = [PSSpecifier preferenceSpecifierNamed:label
                                                    target:target
                                                       set:nil
                                                       get:nil
                                                    detail:nil
                                                      cell:PSButtonCell
                                                      edit:nil];
    s.buttonAction = sel;
    s->action = sel;
    [s setProperty:actionKey forKey:@"lnbAction"];
    return s;
}

#pragma mark - 主设置控制器

@interface NGBPrefsRootListController : PSListController <UIImagePickerControllerDelegate, UINavigationControllerDelegate>
- (void)mirrorPreferencesToFile;
// 按钮动作统一在此声明：LNBButton 用的是 SEL，@selector() 本身不要求方法
// 已声明，但显式声明能让编译器帮忙校验签名，也便于阅读。
- (void)lnbPickGlobalImage:(PSSpecifier *)spec;
- (void)lnbPickGlobalVideo:(PSSpecifier *)spec;
- (void)lnbPickCardImage:(PSSpecifier *)spec;
- (void)lnbPickCardVideo:(PSSpecifier *)spec;
- (void)lnbPickSuppImage:(PSSpecifier *)spec;
- (void)lnbPickSuppVideo:(PSSpecifier *)spec;
- (void)lnbConfirmClearAll:(PSSpecifier *)spec;
- (void)lnbClearDiagBorders:(PSSpecifier *)spec;
@end

@implementation NGBPrefsRootListController

+ (void)load {
    LNBLog(@"=== [1] 类已加载（load）===");
}

- (instancetype)init {
    LNBLog(@"[2] init 进入，super=%@", NSStringFromClass([self superclass]));
    self = [super init];
    LNBLog(@"[3] init 返回 self=%@", self ? @"OK" : @"nil");
    return self;
}

- (void)viewDidLoad {
    LNBLog(@"[4] viewDidLoad 进入");
    @try {
        [super viewDidLoad];
        LNBLog(@"[5] super viewDidLoad 完成");
        self.title = @"坏叔叔 — 通知卡片背景";
        [LNBFileManager ensureDirectory];
        LNBLog(@"[6] 目录就绪");
        [self seedDefaultsIfNeeded];
        LNBLog(@"[7] 默认值写入完成");
    } @catch (NSException *e) {
        LNBLog(@"[!] viewDidLoad 抛异常: %@ — %@", e.name, e.reason);
        @throw;
    }
}

- (void)viewWillAppear:(BOOL)animated {
    LNBLog(@"[8] viewWillAppear 进入");
    [super viewWillAppear:animated];
    [self.table reloadData];
    LNBLog(@"[10] reloadData 完成");
}

- (void)seedDefaultsIfNeeded {
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:kPrefsDomain];
    NSDictionary *defaults = @{@"enabled":         @YES,
                               @"cardEnabled":     @YES,
                               @"cardUseVideo":    @NO,
                               @"cardAlpha":       @0.9,
                               @"cardBlurOverlay": @YES,
                               @"suppEnabled":     @YES,
                               @"suppUseVideo":    @NO,
                               @"suppAlpha":       @0.9,
                               @"suppBlurOverlay": @YES,
                               @"suppVideoSound":  @NO,
                               @"suppForceMode":   @NO,
                               @"globalEnabled":   @NO,
                               @"globalUseVideo":  @NO,
                               @"globalAlpha":     @0.85,
                               @"videoMuted":      @YES,
                               @"videoVolume":     @0.6,
                               @"mixWithOthers":   @YES,
                               @"diagMode":        @NO};
    for (NSString *key in defaults) {
        if ([d objectForKey:key] == nil) [d setObject:defaults[key] forKey:key];
    }

    // v1.2.2 一次性迁移：1.1.x 时代 globalEnabled 默认 YES，老用户升级后
    // 「整块列表背景」会残留开启 —— 用户要的是卡片背景，不是整块铺底。
    // 用标记位保证只跑一次，之后用户手动开整块背景不会被这里改掉。
    if ([d objectForKey:@"lnbMigrated122"] == nil) {
        [d setObject:@NO  forKey:@"globalEnabled"];
        [d setObject:@YES forKey:@"cardEnabled"];
        [d setObject:@YES forKey:@"lnbMigrated122"];
    }

    [d synchronize];
    [self mirrorPreferencesToFile];
}

#pragma mark 值读写（PSViewController 标准钩子）

- (id)readPreferenceValue:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    if (!key) return @NO;
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:kPrefsDomain];
    id v = [d objectForKey:key];
    if (v == nil) v = [specifier propertyForKey:@"default"];
    return v ?: @NO;
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    if (!key) return;

    LNBLog(@"[SET] %@ = %@", key, value);

    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:kPrefsDomain];
    [d setObject:value forKey:key];
    [d synchronize];

    // 同步一份 plist 到 /var/mobile/Library/LockNotifyBG/。
    // SpringBoard 与设置面板是两个进程，走 NSUserDefaults suite 需要 entitlement 与
    // cfprefsd 缓存配合，隐根环境偶发读不到；直接落 plist 是最稳的跨进程通道，
    // tweak 侧 LNBPrefs 也是优先读这个文件。
    [self mirrorPreferencesToFile];

    [LNBFileManager postReload];

    // 只刷新当前 cell 的显示值，避免整表 reload 打断滑动
    dispatch_async(dispatch_get_main_queue(), ^{
        [self reloadSpecifier:specifier animated:NO];
    });
}

// 把当前 defaults 全量落盘为 plist
- (void)mirrorPreferencesToFile {
    [LNBFileManager ensureDirectory];
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:kPrefsDomain];
    NSDictionary *all = [d dictionaryRepresentation];
    if (!all) return;
    [all writeToFile:[LNBFileManager pathForFile:@"prefs.plist"] atomically:YES];
}

#pragma mark specifiers

- (NSArray *)specifiers {
    LNBLog(@"[S1] specifiers 被调用，当前 _specifiers=%@", _specifiers ? @"非空" : @"nil");
    if (_specifiers == nil) {
        NSMutableArray *specs = [NSMutableArray array];

        // ---- 0. 总开关 ----
        [specs addObject:LNBGroup(@"功能开关", @"关闭后所有背景设置立即失效，但资源文件会保留。")];
        [specs addObject:LNBSwitch(self, @"启用插件", @"enabled")];

        // ---- 1. 通知卡片背景（主功能）----
        [specs addObject:LNBGroup(@"通知卡片背景",
                                  @"给锁屏上的每一条通知单独加背景，支持图片或视频（二选一，用「使用视频」开关切换）。图片/视频按「填充满整块卡片并裁剪」显示；卡片视频会强制静音。")];
        [specs addObject:LNBSwitch(self, @"卡片背景开关", @"cardEnabled")];
        [specs addObject:LNBButton(self, @"选择卡片图片", @selector(lnbPickCardImage:), @"pickCardImage")];
        [specs addObject:LNBButton(self, @"选择卡片视频", @selector(lnbPickCardVideo:), @"pickCardVideo")];
        [specs addObject:LNBSwitch(self, @"使用视频作为卡片背景", @"cardUseVideo")];
        [specs addObject:LNBSlider(self, @"卡片背景不透明度", @"cardAlpha", 0.2, 1.0)];
        [specs addObject:LNBSwitch(self, @"暗色遮罩（提升文字可读性）", @"cardBlurOverlay")];

        // ---- 2. 附属按钮模块背景（删除 / 选项）----
        // 用户要求：这两个模块的背景逻辑与通知卡片完全一致，
        // 所以这里的设置项也和卡片分组一一对应。
        [specs addObject:LNBGroup(@"附属按钮背景（删除 / 选项）",
                                  @"锁屏通知底部的「删除」「选项」按钮模块，背景逻辑与通知卡片完全一致。\n默认开启并自动沿用卡片素材；也可以在这里单独选图/视频。")];
        [specs addObject:LNBSwitch(self, @"按钮背景开关", @"suppEnabled")];
        [specs addObject:LNBButton(self, @"选择按钮图片", @selector(lnbPickSuppImage:), @"pickSuppImage")];
        [specs addObject:LNBButton(self, @"选择按钮视频", @selector(lnbPickSuppVideo:), @"pickSuppVideo")];
        [specs addObject:LNBSwitch(self, @"使用视频作为按钮背景", @"suppUseVideo")];
        [specs addObject:LNBSwitch(self, @"按钮视频播放声音", @"suppVideoSound")];
        [specs addObject:LNBSlider(self, @"按钮背景不透明度", @"suppAlpha", 0.2, 1.0)];
        [specs addObject:LNBSwitch(self, @"暗色遮罩（提升文字可读性）", @"suppBlurOverlay")];
        [specs addObject:LNBSwitch(self, @"强制模式（放宽按钮模块识别）", @"suppForceMode")];

        // ---- 3. 全局背景（附加玩法，默认关闭）----
        [specs addObject:LNBGroup(@"整块列表背景（附加功能）",
                                  @"把锁屏上聚在一起的通知当成一整块区域，铺一张底图或视频。默认关闭，需要时再开。")];
        [specs addObject:LNBSwitch(self, @"整块背景开关", @"globalEnabled")];
        [specs addObject:LNBButton(self, @"选择背景图片", @selector(lnbPickGlobalImage:), @"pickGlobalImage")];
        [specs addObject:LNBButton(self, @"选择背景视频", @selector(lnbPickGlobalVideo:), @"pickGlobalVideo")];
        [specs addObject:LNBSwitch(self, @"使用视频作为背景", @"globalUseVideo")];
        [specs addObject:LNBSlider(self, @"整块背景不透明度", @"globalAlpha", 0.2, 1.0)];

        // ---- 3. 声音 ----
        [specs addObject:LNBGroup(@"声音",
                                  @"仅对「整块背景」的视频模式有效。背景视频默认静音；打开声音后若同时开启「与其他音频混音」，播放背景视频不会中断你正在听的音乐。")];
        [specs addObject:LNBSwitch(self, @"静音", @"videoMuted")];
        [specs addObject:LNBSlider(self, @"音量", @"videoVolume", 0.0, 1.0)];
        [specs addObject:LNBSwitch(self, @"与其他音频混音", @"mixWithOthers")];

        // ---- 4. 诊断 ----
        [specs addObject:LNBGroup(@"诊断（排查用）",
                                  @"开启后会给锁屏通知的各层视图描上彩色边框，用于确认背景图挂在哪一层、被谁挡住。\n红=通知卡片容器　绿=我们的背景视图　紫=遮罩层　黄=被隐藏的系统白底　蓝=文字内容层　橙=整块背景宿主\n排查完请务必关闭，否则会一直显示彩色边框。")];
        [specs addObject:LNBSwitch(self, @"诊断模式（彩色边框）", @"diagMode")];
        [specs addObject:LNBButton(self, @"清除诊断彩框", @selector(lnbClearDiagBorders:), @"clearDiag")];

        // ---- 5. 其它 ----
        [specs addObject:LNBGroup(@"其它", @"所有修改即时生效，无需注销。")];

        PSSpecifier *status = [PSSpecifier preferenceSpecifierNamed:@"资源状态"
                                                             target:self
                                                                set:nil
                                                                get:@selector(lnbStatusDetail:)
                                                             detail:nil
                                                               cell:PSStaticTextCell
                                                               edit:nil];
        [status setProperty:@NO forKey:@"enabled"];
        [specs addObject:status];

        PSSpecifier *ver = [PSSpecifier preferenceSpecifierNamed:@"插件版本"
                                                          target:self
                                                             set:nil
                                                             get:@selector(lnbVersionDetail:)
                                                          detail:nil
                                                            cell:PSStaticTextCell
                                                            edit:nil];
        [ver setProperty:@NO forKey:@"enabled"];
        [specs addObject:ver];

        [specs addObject:LNBButton(self, @"清除所有背景资源", @selector(lnbConfirmClearAll:), @"clearAll")];

        _specifiers = specs;
        LNBLog(@"[S3] 构建完成，共 %lu 项", (unsigned long)specs.count);
    }
    LNBLog(@"[S4] 返回 %lu 项", (unsigned long)_specifiers.count);
    return _specifiers;
}

#pragma mark 详情与状态文本

- (id)lnbStatusDetail:(PSSpecifier *)specifier {
    NSMutableArray *parts = [NSMutableArray array];
    if ([LNBFileManager fileExistsNamed:kBGGlobalImage]) [parts addObject:@"全局图"];
    if ([LNBFileManager fileExistsNamed:kBGGlobalVideo]) [parts addObject:@"视频"];
    if ([LNBFileManager fileExistsNamed:kBGCardImage])   [parts addObject:@"卡片图"];
    if ([LNBFileManager fileExistsNamed:kBGCardVideo])   [parts addObject:@"卡片视频"];
    if ([LNBFileManager fileExistsNamed:kBGSuppImage])   [parts addObject:@"按钮图"];
    if ([LNBFileManager fileExistsNamed:kBGSuppVideo])   [parts addObject:@"按钮视频"];
    return parts.count ? [parts componentsJoinedByString:@" / "] : @"尚无资源";
}

- (id)lnbVersionDetail:(PSSpecifier *)specifier {
    NSString *v = [[NSBundle bundleForClass:[self class]]
                   objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    return [NSString stringWithFormat:@"当前安装 v%@ — 卡片图务必用「选择卡片图片」选", v ?: @"?"];
}

#pragma mark 点击处理（buttonAction 主路径 + didSelect 兜底）

- (void)lnbPickGlobalImage:(PSSpecifier *)spec { [self presentPickerForName:kBGGlobalImage isVideo:NO]; }
- (void)lnbPickGlobalVideo:(PSSpecifier *)spec { [self presentPickerForName:kBGGlobalVideo isVideo:YES]; }
- (void)lnbPickCardImage:(PSSpecifier *)spec   { [self presentPickerForName:kBGCardImage   isVideo:NO]; }
- (void)lnbPickCardVideo:(PSSpecifier *)spec   { [self presentPickerForName:kBGCardVideo   isVideo:YES]; }
- (void)lnbPickSuppImage:(PSSpecifier *)spec   { [self presentPickerForName:kBGSuppImage   isVideo:NO]; }
- (void)lnbPickSuppVideo:(PSSpecifier *)spec   { [self presentPickerForName:kBGSuppVideo   isVideo:YES]; }

- (void)lnbConfirmClearAll:(PSSpecifier *)spec {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"确认清除"
                                                                  message:@"将删除已设置的所有背景图片和视频。"
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"清除" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        [LNBFileManager removeFileNamed:kBGGlobalImage];
        [LNBFileManager removeFileNamed:kBGGlobalVideo];
        [LNBFileManager removeFileNamed:kBGCardImage];
        [LNBFileManager removeFileNamed:kBGCardVideo];
        [LNBFileManager removeFileNamed:kBGSuppImage];
        [LNBFileManager removeFileNamed:kBGSuppVideo];
        [LNBFileManager postReload];
        [self.table reloadData];
        [self lnbShowAlert:@"已清除" message:@"所有背景资源已删除。"];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

// 关闭诊断模式并让 tweak 立刻清掉已画上的彩色边框。
// 这里必须先把 diagMode 写 NO 再 postReload —— tweak 收到 reload 后会带着
// 「当前未开启诊断」的状态重扫一遍视图树，把所有被标记过的视图恢复原样。
- (void)lnbClearDiagBorders:(PSSpecifier *)spec {
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:kPrefsDomain];
    [d setObject:@NO forKey:@"diagMode"];
    [d synchronize];
    [self mirrorPreferencesToFile];
    [LNBFileManager postReload];
    [self.table reloadData];
    [self lnbShowAlert:@"已清除" message:@"诊断模式已关闭，彩色边框会在锁屏通知下一次刷新时消失。"];
}

// 兜底：若框架未触发 buttonAction，在 didSelectRowAtIndexPath 里按 lnbAction 分发
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    PSSpecifier *spec = [self specifierAtIndexPath:indexPath];
    if (spec) {
        NSString *k = [spec propertyForKey:@"lnbAction"];
        LNBLog(@"[D] 点击行 %@ — lnbAction=%@", [indexPath description], k);
        if ([k isEqualToString:@"pickGlobalImage"]) { [self lnbPickGlobalImage:spec]; return; }
        if ([k isEqualToString:@"pickGlobalVideo"]) { [self lnbPickGlobalVideo:spec]; return; }
        if ([k isEqualToString:@"pickCardImage"])   { [self lnbPickCardImage:spec];   return; }
        if ([k isEqualToString:@"pickCardVideo"])   { [self lnbPickCardVideo:spec];   return; }
        if ([k isEqualToString:@"pickSuppImage"])   { [self lnbPickSuppImage:spec];   return; }
        if ([k isEqualToString:@"pickSuppVideo"])   { [self lnbPickSuppVideo:spec];   return; }
        if ([k isEqualToString:@"clearDiag"])       { [self lnbClearDiagBorders:spec]; return; }
        if ([k isEqualToString:@"clearAll"])        { [self lnbConfirmClearAll:spec]; return; }
    }
    [super tableView:tableView didSelectRowAtIndexPath:indexPath];
}

#pragma mark 资源选择

- (void)presentPickerForName:(NSString *)fileName isVideo:(BOOL)isVideo {
    UIImagePickerController *picker = [[UIImagePickerController alloc] init];
    picker.sourceType = UIImagePickerControllerSourceTypePhotoLibrary;
    picker.mediaTypes = isVideo ? @[UTTypeMovie.identifier] : @[UTTypeImage.identifier];
    if (isVideo) picker.videoQuality = UIImagePickerControllerQualityTypeHigh;
    picker.delegate = self;
    picker.modalPresentationStyle = UIModalPresentationFullScreen;
    objc_setAssociatedObject(picker, @selector(presentPickerForName:isVideo:),
                             fileName, OBJC_ASSOCIATION_COPY_NONATOMIC);
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)imagePickerController:(UIImagePickerController *)picker
        didFinishPickingMediaWithInfo:(NSDictionary<UIImagePickerControllerInfoKey,id> *)info {
    NSString *targetName = objc_getAssociatedObject(picker, @selector(presentPickerForName:isVideo:));

    [picker dismissViewControllerAnimated:YES completion:^{
        if (!targetName) return;

        NSError *error = nil;
        BOOL ok = NO;

        BOOL isVideoPick = [targetName isEqualToString:kBGGlobalVideo]
                        || [targetName isEqualToString:kBGCardVideo]
                        || [targetName isEqualToString:kBGSuppVideo];
        if (isVideoPick) {
            NSURL *videoURL = info[UIImagePickerControllerMediaURL];
            if (videoURL) ok = [LNBFileManager copyFileAtURL:videoURL toName:targetName error:&error];
        } else {
            NSURL *imageURL = info[UIImagePickerControllerImageURL];
            UIImage *image = info[UIImagePickerControllerOriginalImage];
            if (imageURL) {
                ok = [LNBFileManager copyFileAtURL:imageURL toName:targetName error:&error];
            } else if (image) {
                NSData *jpeg = UIImageJPEGRepresentation(image, 0.92);
                ok = [jpeg writeToFile:[LNBFileManager pathForFile:targetName] atomically:YES];
            }
        }

        if (ok) {
            [LNBFileManager postReload];
            [self.table reloadData];
            [self mirrorPreferencesToFile];
            [self lnbShowAlert:@"设置成功" message:[NSString stringWithFormat:@"已保存为 %@", targetName]];
        } else {
            [self lnbShowAlert:@"设置失败" message:error.localizedDescription ?: @"无法写入文件"];
        }
    }];
}

- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker {
    [picker dismissViewControllerAnimated:YES completion:nil];
}

#pragma mark 提示

- (void)lnbShowAlert:(NSString *)title message:(NSString *)message {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                      message:message
                                                               preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    });
}

@end
