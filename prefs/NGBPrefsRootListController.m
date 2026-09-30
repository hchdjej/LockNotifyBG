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

static void LNBLog(NSString *fmt, ...) {
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
}

#pragma mark - specifier 构造辅助

static PSSpecifier *LNBGroup(NSString *header, NSString *footer) {
    PSSpecifier *s = [PSSpecifier groupSpecifierWithName:header];
    if (footer) [s setProperty:footer forKey:@"footerText"];
    return s;
}

// 开关行：set/get 传 nil，值读写走 PSViewController 的
// readPreferenceValue: / setPreferenceValue:specifier: 钩子
static PSSpecifier *LNBSwitch(NSString *label, NSString *key) {
    PSSpecifier *s = [PSSpecifier preferenceSpecifierNamed:label
                                                    target:nil
                                                       set:nil
                                                       get:nil
                                                    detail:nil
                                                      cell:PSSwitchCell
                                                      edit:nil];
    [s setProperty:key forKey:@"key"];
    [s setProperty:kPrefsDomain forKey:@"defaults"];
    [s setProperty:@YES forKey:@"default"];
    return s;
}

static PSSpecifier *LNBSlider(NSString *label, NSString *key, double min, double max) {
    PSSpecifier *s = [PSSpecifier preferenceSpecifierNamed:label
                                                    target:nil
                                                       set:nil
                                                       get:nil
                                                    detail:nil
                                                      cell:PSSliderCell
                                                      edit:nil];
    [s setProperty:key forKey:@"key"];
    [s setProperty:kPrefsDomain forKey:@"defaults"];
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
        self.title = @"锁屏通知背景";
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
        if ([d objectForKey:key] == nil) [d setObject:defaults[key] forKey:key];
    }
    [d synchronize];
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

    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:kPrefsDomain];
    [d setObject:value forKey:key];
    [d synchronize];

    [LNBFileManager postReload];

    dispatch_async(dispatch_get_main_queue(), ^{
        [self.table reloadData];
    });
}

#pragma mark specifiers

- (NSArray *)specifiers {
    LNBLog(@"[S1] specifiers 被调用，当前 _specifiers=%@", _specifiers ? @"非空" : @"nil");
    if (_specifiers == nil) {
        NSMutableArray *specs = [NSMutableArray array];

        // ---- 0. 总开关 ----
        [specs addObject:LNBGroup(@"功能开关", @"关闭后所有背景设置立即失效，但资源文件会保留。")];
        [specs addObject:LNBSwitch(@"启用插件", @"enabled")];

        // ---- 1. 全局背景 ----
        [specs addObject:LNBGroup(@"全局背景（通知列表整块）",
                                  @"作用于锁屏通知列表整体区域。视频模式会在系统刷新时重新挂载播放层，可能出现短暂闪烁。")];
        [specs addObject:LNBSwitch(@"全局背景开关", @"globalEnabled")];
        [specs addObject:LNBButton(self, @"选择背景图片", @selector(lnbPickGlobalImage:), @"pickGlobalImage")];
        [specs addObject:LNBButton(self, @"选择背景视频", @selector(lnbPickGlobalVideo:), @"pickGlobalVideo")];
        [specs addObject:LNBSwitch(@"使用视频作为背景", @"globalUseVideo")];
        [specs addObject:LNBSlider(@"背景透明度", @"globalAlpha", 0.2, 1.0)];

        // ---- 2. 声音 ----
        [specs addObject:LNBGroup(@"声音",
                                  @"背景视频默认静音。打开声音后，若同时开启「与其他音频混音」，播放背景视频不会中断你正在听的音乐。")];
        [specs addObject:LNBSwitch(@"静音", @"videoMuted")];
        [specs addObject:LNBSlider(@"音量", @"videoVolume", 0.0, 1.0)];
        [specs addObject:LNBSwitch(@"与其他音频混音", @"mixWithOthers")];

        // ---- 3. 卡片背景 ----
        [specs addObject:LNBGroup(@"通知卡片背景（单条）",
                                  @"作用于每一条通知。卡片仅支持静态图片。")];
        [specs addObject:LNBSwitch(@"卡片背景开关", @"cardEnabled")];
        [specs addObject:LNBButton(self, @"选择卡片图片", @selector(lnbPickCardImage:), @"pickCardImage")];
        [specs addObject:LNBSlider(@"卡片透明度", @"cardAlpha", 0.2, 1.0)];
        [specs addObject:LNBSwitch(@"暗色遮罩（提升可读性）", @"cardBlurOverlay")];

        // ---- 4. 其它 ----
        [specs addObject:LNBGroup(@"其它", @"所有修改即时生效，无需注销。")];

        PSSpecifier *status = [PSSpecifier preferenceSpecifierNamed:@"资源状态"
                                                             target:nil
                                                                set:nil
                                                                get:@selector(lnbStatusDetail:)
                                                             detail:nil
                                                               cell:PSStaticTextCell
                                                               edit:nil];
        [status setProperty:@NO forKey:@"enabled"];
        [specs addObject:status];

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
    return parts.count ? [parts componentsJoinedByString:@" / "] : @"尚无资源";
}

#pragma mark 点击处理（buttonAction 主路径 + didSelect 兜底）

- (void)lnbPickGlobalImage:(PSSpecifier *)spec { [self presentPickerForName:kBGGlobalImage isVideo:NO]; }
- (void)lnbPickGlobalVideo:(PSSpecifier *)spec { [self presentPickerForName:kBGGlobalVideo isVideo:YES]; }
- (void)lnbPickCardImage:(PSSpecifier *)spec   { [self presentPickerForName:kBGCardImage   isVideo:NO]; }

- (void)lnbConfirmClearAll:(PSSpecifier *)spec {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"确认清除"
                                                                  message:@"将删除已设置的所有背景图片和视频。"
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"清除" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        [LNBFileManager removeFileNamed:kBGGlobalImage];
        [LNBFileManager removeFileNamed:kBGGlobalVideo];
        [LNBFileManager removeFileNamed:kBGCardImage];
        [LNBFileManager postReload];
        [self.table reloadData];
        [self lnbShowAlert:@"已清除" message:@"所有背景资源已删除。"];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
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

        if ([targetName isEqualToString:kBGGlobalVideo]) {
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
