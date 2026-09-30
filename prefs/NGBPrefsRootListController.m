//
//  NGBPrefsRootListController.m
//  LockNotifyBG 偏好设置面板
//
//  必须是 PSListController 子类 —— PreferenceLoader 以 specifier 机制驱动
//  设置界面，任何 UITableViewController 子类都会因缺失 specifiers 而闪退。
//
//  提供：总开关、全局背景开关、透明度、视频与音频控制、卡片背景、资源文件选择。
//  资源文件统一存放在 /var/mobile/Library/LockNotifyBG/
//

#import <UIKit/UIKit.h>
#import <MobileCoreServices/MobileCoreServices.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <PhotosUI/PhotosUI.h>
#import <objc/runtime.h>
#import <notify.h>

// ---------------------------------------------------------------------------
// Preferences 私有框架的最小声明
//
// PSListController / PSSpecifier 定义在私有框架 Preferences 中，其头文件不在
// 主流 iOS SDK 里（需要额外引入 theos/headers 仓库）。这里自带最小声明，
// 既避免额外依赖，又保证链接时符号能正确解析到 Preferences.framework。
// ---------------------------------------------------------------------------

// PSSpecifier 的 cell 类型：直接用字符串，Preferences 框架按名实例化对应 cell 类
// （不引用 PSControlTableCellType 等外部符号，避免链接期缺失）
#define kCellSwitch   @"PSSwitchCell"
#define kCellSlider   @"PSSliderCell"
#define kCellLink     @"PSLinkCell"
#define kCellStatic   @"PSStaticTextCell"
#define kCellButton   @"PSButtonCell"

@interface PSSpecifier : NSObject
@property (nonatomic, assign) SEL action;
@property (nonatomic, assign) SEL getter;
@property (nonatomic, assign) SEL setter;
@property (nonatomic, strong) id target;

+ (instancetype)preferenceSpecifierNamed:(NSString *)name
                                  target:(id)target
                                     set:(SEL)setter
                                     get:(SEL)getter
                                  detail:(Class)detail
                                    cell:(NSString *)cell
                                    edit:(Class)edit;
+ (instancetype)groupSpecifierWithName:(NSString *)name;

- (void)setProperty:(id)value forKey:(NSString *)key;
- (id)propertyForKey:(NSString *)key;
@end

@interface PSListController : UIViewController <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) NSMutableArray *specifiers;
- (void)reloadSpecifiers;
@end

#define kPrefsDomain        @"com.hchdjej.locknotifybg"
#define kReloadNotification @"com.hchdjej.locknotifybg/reload"
#define kBGDirectory        @"/var/mobile/Library/LockNotifyBG"
#define kBGGlobalImage      @"global.jpg"
#define kBGGlobalVideo      @"global.mp4"
#define kBGCardImage        @"card.jpg"

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
    if (!ok) {
        NSLog(@"[LockNotifyBG] 创建目录失败: %@", error);
        return NO;
    }

    // 目录创建后单独修正属主与权限（创建时 attributes 对属主项不完全生效）
    [fm setAttributes:@{NSFilePosixPermissions: @(0755),
                        NSFileOwnerAccountName: @"mobile",
                        NSFileGroupOwnerAccountName: @"mobile"}
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

    // 覆盖前先删除，避免 copyItemAtURL 因目标已存在而失败
    if ([fm fileExistsAtPath:dest]) {
        [fm removeItemAtPath:dest error:nil];
    }

    BOOL ok = [fm copyItemAtURL:url toURL:[NSURL fileURLWithPath:dest] error:error];
    if (ok) {
        [fm setAttributes:@{NSFilePosixPermissions: @(0644)}
             ofItemAtPath:dest error:nil];
    }
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

#pragma mark - PSSpecifier 便捷构造

static PSSpecifier *LNBGroup(NSString *header, NSString *footer) {
    PSSpecifier *s = [PSSpecifier groupSpecifierWithName:header];
    if (footer) [s setProperty:footer forKey:@"footerText"];
    return s;
}

static PSSpecifier *LNBSwitch(NSString *label, NSString *key, id target, SEL action) {
    PSSpecifier *s = [PSSpecifier preferenceSpecifierNamed:label
                                                    target:target
                                                       set:action
                                                       get:@selector(readPref:)
                                                    detail:nil
                                                      cell:kCellSwitch
                                                      edit:nil];
    [s setProperty:key forKey:@"key"];
    [s setProperty:kPrefsDomain forKey:@"defaults"];
    [s setProperty:@YES forKey:@"default"];
    return s;
}

static PSSpecifier *LNBSlider(NSString *label, NSString *key, id target, SEL action,
                              double min, double max) {
    PSSpecifier *s = [PSSpecifier preferenceSpecifierNamed:label
                                                    target:target
                                                       set:action
                                                       get:@selector(readPref:)
                                                    detail:nil
                                                      cell:kCellSlider
                                                      edit:nil];
    [s setProperty:key forKey:@"key"];
    [s setProperty:kPrefsDomain forKey:@"defaults"];
    [s setProperty:@(min) forKey:@"min"];
    [s setProperty:@(max) forKey:@"max"];
    [s setProperty:@YES forKey:@"showValue"];
    return s;
}

#pragma mark - 主设置控制器

@interface NGBPrefsRootListController : PSListController <UIImagePickerControllerDelegate, UINavigationControllerDelegate> {
    NSArray *_cachedSpecifiers;
}
@end

@implementation NGBPrefsRootListController

#pragma mark 生命周期

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"锁屏通知背景";
    [LNBFileManager ensureDirectory];
    [self seedDefaultsIfNeeded];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // 从文件选择器返回后刷新「已设置 / 未设置」状态
    [self reloadSpecifiers];
}

// 首次进入时把默认值写进 prefs domain，避免 tweak 侧读到 nil
- (void)seedDefaultsIfNeeded {
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:kPrefsDomain];
    NSDictionary *defaults = @{@"enabled":         @YES,
                               @"globalEnabled":   @YES,
                               @"globalUseVideo":  @NO,
                               @"globalAlpha":     @0.85,
                               @"cardEnabled":     @NO,
                               @"cardAlpha":       @0.9,
                               @"cardBlurOverlay": @YES,
                               @"videoMuted":      @YES,
                               @"videoVolume":     @0.6,
                               @"mixWithOthers":   @YES};
    for (NSString *key in defaults) {
        if ([d objectForKey:key] == nil) {
            [d setObject:defaults[key] forKey:key];
        }
    }
    [d synchronize];
}

#pragma mark 取值（供 PSSpecifier 的 get 使用）

- (id)readPref:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    if (!key) return @NO;
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:kPrefsDomain];
    id v = [d objectForKey:key];
    if (v == nil) v = [specifier propertyForKey:@"default"];
    return v ?: @NO;
}

#pragma mark specifiers

- (NSArray *)specifiers {
    if (_cachedSpecifiers == nil) {
        NSMutableArray *specs = [NSMutableArray array];

        // ---- 0. 总开关 ----
        [specs addObject:LNBGroup(@"功能开关", @"关闭后所有背景设置立即失效，但资源文件会保留。")];
        [specs addObject:LNBSwitch(@"启用插件", @"enabled", self, @selector(setPref:forSpecifier:))];

        // ---- 1. 全局背景 ----
        [specs addObject:LNBGroup(@"全局背景（通知列表整块）",
                                  @"作用于锁屏通知列表整体区域。视频模式会在系统刷新时重新挂载播放层，可能出现短暂闪烁。")];
        [specs addObject:LNBSwitch(@"全局背景开关", @"globalEnabled", self, @selector(setPref:forSpecifier:))];

        PSSpecifier *pickImage = [PSSpecifier preferenceSpecifierNamed:@"选择背景图片"
                                                                target:self
                                                                   set:nil
                                                                   get:@selector(readGlobalImageDetail:)
                                                                detail:nil
                                                                  cell:kCellLink
                                                                  edit:nil];
        pickImage->action = @selector(pickGlobalImage);
        [specs addObject:pickImage];

        PSSpecifier *pickVideo = [PSSpecifier preferenceSpecifierNamed:@"选择背景视频"
                                                                target:self
                                                                   set:nil
                                                                   get:@selector(readGlobalVideoDetail:)
                                                                detail:nil
                                                                  cell:kCellLink
                                                                  edit:nil];
        pickVideo->action = @selector(pickGlobalVideo);
        [specs addObject:pickVideo];

        [specs addObject:LNBSwitch(@"使用视频作为背景", @"globalUseVideo", self, @selector(setPref:forSpecifier:))];
        [specs addObject:LNBSlider(@"背景透明度", @"globalAlpha", self, @selector(setPref:forSpecifier:), 0.2, 1.0)];

        // ---- 2. 声音 ----
        [specs addObject:LNBGroup(@"声音",
                                  @"背景视频默认静音。打开声音后，若同时开启「与其他音频混音」，播放背景视频不会中断你正在听的音乐；关闭混音则背景视频独占音频通道。")];
        [specs addObject:LNBSwitch(@"静音", @"videoMuted", self, @selector(setPref:forSpecifier:))];

        PSSpecifier *volume = LNBSlider(@"音量", @"videoVolume", self, @selector(setPref:forSpecifier:), 0.0, 1.0);
        [specs addObject:volume];

        [specs addObject:LNBSwitch(@"与其他音频混音", @"mixWithOthers", self, @selector(setPref:forSpecifier:))];

        // ---- 3. 卡片背景 ----
        [specs addObject:LNBGroup(@"通知卡片背景（单条）",
                                  @"作用于每一条通知。为保证系统稳定性，卡片仅支持静态图片（视频自动取其首帧）。")];
        [specs addObject:LNBSwitch(@"卡片背景开关", @"cardEnabled", self, @selector(setPref:forSpecifier:))];

        PSSpecifier *pickCard = [PSSpecifier preferenceSpecifierNamed:@"选择卡片图片"
                                                               target:self
                                                                  set:nil
                                                                  get:@selector(readCardImageDetail:)
                                                               detail:nil
                                                                 cell:kCellLink
                                                                 edit:nil];
        pickCard->action = @selector(pickCardImage);
        [specs addObject:pickCard];

        [specs addObject:LNBSlider(@"卡片透明度", @"cardAlpha", self, @selector(setPref:forSpecifier:), 0.2, 1.0)];
        [specs addObject:LNBSwitch(@"暗色遮罩（提升可读性）", @"cardBlurOverlay", self, @selector(setPref:forSpecifier:))];

        // ---- 4. 其它 ----
        [specs addObject:LNBGroup(@"其它", @"所有修改即时生效，无需注销或重启。")];

        PSSpecifier *status = [PSSpecifier preferenceSpecifierNamed:@"资源状态"
                                                             target:self
                                                                set:nil
                                                                get:@selector(readStatusDetail:)
                                                             detail:nil
                                                               cell:kCellStatic
                                                               edit:nil];
        [status setProperty:@NO forKey:@"enabled"];
        [specs addObject:status];

        PSSpecifier *clearBtn = [PSSpecifier preferenceSpecifierNamed:@"清除所有背景资源"
                                                              target:self
                                                                 set:nil
                                                                 get:nil
                                                              detail:nil
                                                                cell:kCellButton
                                                                edit:nil];
        clearBtn->action = @selector(confirmClearAll);
        [clearBtn setProperty:@(YES) forKey:@"enabled"];
        [specs addObject:clearBtn];

        _cachedSpecifiers = specs;
    }
    return _cachedSpecifiers;
}

#pragma mark 详情文本（右侧灰字）

- (id)readGlobalImageDetail:(PSSpecifier *)specifier {
    return [LNBFileManager fileExistsNamed:kBGGlobalImage] ? @"已设置" : @"未设置";
}

- (id)readGlobalVideoDetail:(PSSpecifier *)specifier {
    return [LNBFileManager fileExistsNamed:kBGGlobalVideo] ? @"已设置" : @"未设置";
}

- (id)readCardImageDetail:(PSSpecifier *)specifier {
    return [LNBFileManager fileExistsNamed:kBGCardImage] ? @"已设置" : @"未设置";
}

- (id)readStatusDetail:(PSSpecifier *)specifier {
    NSMutableArray *parts = [NSMutableArray array];
    if ([LNBFileManager fileExistsNamed:kBGGlobalImage]) [parts addObject:@"全局图"];
    if ([LNBFileManager fileExistsNamed:kBGGlobalVideo]) [parts addObject:@"视频"];
    if ([LNBFileManager fileExistsNamed:kBGCardImage])   [parts addObject:@"卡片图"];
    return parts.count ? [parts componentsJoinedByString:@" / "] : @"尚无资源";
}

#pragma mark 写值

- (void)setPref:(id)value forSpecifier:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    if (!key) return;

    // 静音时把音量记成 0，避免静音状态下残留音量值让用户困惑
    id stored = value;
    if ([key isEqualToString:@"videoMuted"] && [value boolValue]) {
        // 仅切换静音标志，音量值保留，取消静音后恢复
        stored = value;
    }

    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:kPrefsDomain];
    [d setObject:stored forKey:key];
    [d synchronize];

    [LNBFileManager postReload];
}

#pragma mark 资源选择

- (void)pickGlobalImage { [self presentPickerForName:kBGGlobalImage isVideo:NO]; }
- (void)pickGlobalVideo { [self presentPickerForName:kBGGlobalVideo isVideo:YES]; }
- (void)pickCardImage   { [self presentPickerForName:kBGCardImage   isVideo:NO]; }

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

        if ([targetName isEqualToString:kBGGlobalVideo]) {
            NSURL *videoURL = info[UIImagePickerControllerMediaURL];
            if (videoURL) ok = [LNBFileManager copyFileAtURL:videoURL toName:targetName error:&error];
        } else {
            NSURL *imageURL = info[UIImagePickerControllerImageURL];
            UIImage *image = info[UIImagePickerControllerOriginalImage];
            if (imageURL) {
                ok = [LNBFileManager copyFileAtURL:imageURL toName:targetName error:&error];
            } else if (image) {
                // 部分相册资源拿不到 URL，直接编码写盘
                NSData *jpeg = UIImageJPEGRepresentation(image, 0.92);
                NSString *dest = [LNBFileManager pathForFile:targetName];
                ok = [jpeg writeToFile:dest atomically:YES];
            }
        }

        if (ok) {
            [LNBFileManager postReload];
            [self reloadSpecifiers];
            [self showAlertWithTitle:@"设置成功" message:[NSString stringWithFormat:@"已保存为 %@", targetName]];
        } else {
            [self showAlertWithTitle:@"设置失败" message:error.localizedDescription ?: @"无法写入文件"];
        }
    }];
}

- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker {
    [picker dismissViewControllerAnimated:YES completion:nil];
}

#pragma mark 清除资源

- (void)confirmClearAll {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"确认清除"
                                                                  message:@"将删除已设置的所有背景图片和视频。"
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"清除" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        [LNBFileManager removeFileNamed:kBGGlobalImage];
        [LNBFileManager removeFileNamed:kBGGlobalVideo];
        [LNBFileManager removeFileNamed:kBGCardImage];
        [LNBFileManager postReload];
        [self reloadSpecifiers];
        [self showAlertWithTitle:@"已清除" message:@"所有背景资源已删除。"];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark 提示

- (void)showAlertWithTitle:(NSString *)title message:(NSString *)message {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                      message:message
                                                               preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    });
}

@end
