//
//  NGBPrefsRootListController.m
//  LockNotifyBG 偏好设置面板
//
//  提供：总开关、全局背景开关、视频开关、透明度、卡片背景开关、选择图片/视频文件
//  文件选择后拷贝到 /var/mobile/Library/LockNotifyBG/
//

#import <UIKit/UIKit.h>
#import <MobileCoreServices/MobileCoreServices.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <PhotosUI/PhotosUI.h>
#import <objc/runtime.h>
#import <notify.h>

#define kPrefsDomain       @"com.hchdjej.locknotifybg"
#define kReloadNotification @"com.hchdjej.locknotifybg/reload"
#define kBGDirectory       @"/var/mobile/Library/LockNotifyBG"
#define kBGGlobalImage     @"global.jpg"
#define kBGGlobalVideo     @"global.mp4"
#define kBGCardImage       @"card.jpg"

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
    if (![self ensureDirectory]) {
        if (error) *error = [NSError errorWithDomain:@"LockNotifyBG" code:1 userInfo:@{NSLocalizedDescriptionKey: @"无法创建资源目录"}];
        return NO;
    }

    // iCloud / 文件 App 的文件需要先申请安全访问权限
    BOOL needsScope = [url startAccessingSecurityScopedResource];

    // 通过 NSFileCoordinator 读取，兼容 iCloud Drive 未下载文件
    __block BOOL success = NO;
    __block NSError *innerError = nil;
    NSFileCoordinator *coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
    [coordinator coordinateReadingItemAtURL:url
                                    options:NSFileCoordinatorReadingWithoutChanges
                                      error:&innerError
                                 byAccessor:^(NSURL *newURL) {
        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *dest = [self pathForFile:name];

        // 覆盖前先删旧文件
        [fm removeItemAtPath:dest error:nil];

        NSError *copyError = nil;
        success = [fm copyItemAtPath:newURL.path toPath:dest error:&copyError];
        if (!success) innerError = copyError;

        if (success) {
            // 修正权限，保证 SpringBoard 可读
            [fm setAttributes:@{NSFilePosixPermissions: @(0644),
                                NSFileOwnerAccountName: @"mobile",
                                NSFileGroupOwnerAccountName: @"mobile"}
                 ofItemAtPath:dest error:nil];
        }
    }];

    if (needsScope) [url stopAccessingSecurityScopedResource];

    if (!success && error) *error = innerError;
    return success;
}

+ (BOOL)removeFileNamed:(NSString *)name {
    return [[NSFileManager defaultManager] removeItemAtPath:[self pathForFile:name] error:nil];
}

+ (BOOL)fileExistsNamed:(NSString *)name {
    NSString *path = [self pathForFile:name];
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
    return attrs && [attrs fileSize] > 0;
}

+ (void)postReload {
    // 通知 SpringBoard 里的 tweak 重新读取配置，免重启
    notify_post([kReloadNotification UTF8String]);
}

@end

#pragma mark - 主设置控制器

@interface NGBPrefsRootListController : UITableViewController <UIImagePickerControllerDelegate, UINavigationControllerDelegate>
@property (nonatomic, strong) NSMutableDictionary *prefs;
@end

@implementation NGBPrefsRootListController

#pragma mark 数据读写

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"锁屏通知背景";
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                                                          target:self
                                                                                          action:@selector(dismissSelf)];
    [LNBFileManager ensureDirectory];
    [self loadPrefs];
}

- (void)dismissSelf {
    [self.prefs writeToFile:[self prefsPath] atomically:YES];
    [LNBFileManager postReload];
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (NSString *)prefsPath {
    return [kBGDirectory stringByAppendingPathComponent:@"prefs.plist"];
}

- (void)loadPrefs {
    NSDictionary *saved = [NSDictionary dictionaryWithContentsOfFile:[self prefsPath]];
    NSDictionary *defaults = @{@"enabled": @YES,
                               @"globalEnabled": @YES,
                               @"globalUseVideo": @NO,
                               @"globalAlpha": @0.85,
                               @"cardEnabled": @NO,
                               @"cardAlpha": @0.9,
                               @"cardBlurOverlay": @YES,
                               @"videoMuted": @YES,
                               @"videoVolume": @0.6,
                               @"mixWithOthers": @YES};
    self.prefs = [NSMutableDictionary dictionaryWithDictionary:defaults];
    if (saved) [self.prefs addEntriesFromDictionary:saved];

    // 同步写入 NSUserDefaults，供 tweak 侧读取
    [self syncToUserDefaults];
}

- (void)syncToUserDefaults {
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:kPrefsDomain];
    for (NSString *key in self.prefs) {
        [defaults setObject:self.prefs[key] forKey:key];
    }
    [defaults synchronize];
}

#pragma mark 表格结构

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 5;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    switch (section) {
        case 0: return @"功能开关";
        case 1: return @"全局背景（通知列表整块）";
        case 2: return @"声音";
        case 3: return @"通知卡片背景（单条）";
        case 4: return @"其它";
        default: return nil;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    switch (section) {
        case 1: return @"全局背景作用于锁屏通知列表整体区域。视频模式会在系统刷新时重新挂载播放层，可能出现短暂闪烁。";
        case 2: return @"背景视频默认静音。打开声音后，若同时开着「与其他音频混音」，播放背景视频不会中断你正在听的音乐；关闭混音则背景视频独占音频通道。";
        case 3: return @"卡片背景作用于每一条通知。为保证系统稳定性，卡片仅支持静态图片（视频自动取其首帧）。";
        case 4: return @"修改后自动生效，无需注销。";
        default: return nil;
    }
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    switch (section) {
        case 0: return 1;
        case 1: return 5;   // 开关 / 图片 / 视频 / 用视频 / 透明度
        case 2: return 3;   // 静音开关 / 音量 / 混音
        case 3: return 4;   // 开关 / 选图 / 透明度 / 遮罩
        case 4: return 1;   // 清除全部
        default: return 0;
    }
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cellID = @"LNBActionCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellID];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:cellID];
    }
    cell.accessoryView = nil;
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.detailTextLabel.text = nil;
    cell.textLabel.textColor = [UIColor labelColor];

    UISwitch *toggle = [[UISwitch alloc] init];

    if (indexPath.section == 0) {
        cell.textLabel.text = @"启用插件";
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        toggle.on = [self.prefs[@"enabled"] boolValue];
        toggle.tag = 100;
        [toggle addTarget:self action:@selector(toggleChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = toggle;
        return cell;
    }

    if (indexPath.section == 1) {
        switch (indexPath.row) {
            case 0: {
                cell.textLabel.text = @"全局背景开关";
                cell.selectionStyle = UITableViewCellSelectionStyleNone;
                toggle.on = [self.prefs[@"globalEnabled"] boolValue];
                toggle.tag = 101;
                [toggle addTarget:self action:@selector(toggleChanged:) forControlEvents:UIControlEventValueChanged];
                cell.accessoryView = toggle;
                return cell;
            }
            case 1: {
                cell.textLabel.text = @"选择背景图片";
                BOOL exists = [LNBFileManager fileExistsNamed:kBGGlobalImage];
                cell.detailTextLabel.text = exists ? @"已设置" : @"未设置";
                cell.detailTextLabel.textColor = exists ? [UIColor systemGreenColor] : [UIColor secondaryLabelColor];
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
                return cell;
            }
            case 2: {
                cell.textLabel.text = @"选择背景视频";
                BOOL exists = [LNBFileManager fileExistsNamed:kBGGlobalVideo];
                cell.detailTextLabel.text = exists ? @"已设置" : @"未设置";
                cell.detailTextLabel.textColor = exists ? [UIColor systemGreenColor] : [UIColor secondaryLabelColor];
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
                return cell;
            }
            case 3: {
                cell.textLabel.text = @"使用视频作为背景";
                cell.selectionStyle = UITableViewCellSelectionStyleNone;
                toggle.on = [self.prefs[@"globalUseVideo"] boolValue];
                toggle.tag = 102;
                [toggle addTarget:self action:@selector(toggleChanged:) forControlEvents:UIControlEventValueChanged];
                cell.accessoryView = toggle;
                return cell;
            }
            case 4: {
                cell.textLabel.text = @"背景透明度";
                cell.selectionStyle = UITableViewCellSelectionStyleNone;
                UISlider *slider = [[UISlider alloc] initWithFrame:CGRectMake(0, 0, 160, 34)];
                slider.minimumValue = 0.2;
                slider.maximumValue = 1.0;
                slider.value = [self.prefs[@"globalAlpha"] floatValue];
                slider.tag = 200;
                [slider addTarget:self action:@selector(sliderChanged:) forControlEvents:UIControlEventValueChanged];
                cell.accessoryView = slider;
                return cell;
            }
            default: break;
        }
    }

    if (indexPath.section == 2) {
        switch (indexPath.row) {
            case 0: {
                cell.textLabel.text = @"静音";
                cell.selectionStyle = UITableViewCellSelectionStyleNone;
                toggle.on = [self.prefs[@"videoMuted"] boolValue];
                toggle.tag = 105;
                [toggle addTarget:self action:@selector(toggleChanged:) forControlEvents:UIControlEventValueChanged];
                cell.accessoryView = toggle;
                return cell;
            }
            case 1: {
                cell.textLabel.text = @"音量";
                cell.selectionStyle = UITableViewCellSelectionStyleNone;
                BOOL muted = [self.prefs[@"videoMuted"] boolValue];

                UISlider *slider = [[UISlider alloc] initWithFrame:CGRectMake(0, 0, 160, 34)];
                slider.minimumValue = 0.0;
                slider.maximumValue = 1.0;
                slider.value = [self.prefs[@"videoVolume"] floatValue];
                slider.tag = 202;
                slider.enabled = !muted;
                slider.alpha = muted ? 0.4 : 1.0;
                [slider addTarget:self action:@selector(sliderChanged:) forControlEvents:UIControlEventValueChanged];
                cell.accessoryView = slider;
                return cell;
            }
            case 2: {
                cell.textLabel.text = @"与其他音频混音";
                cell.selectionStyle = UITableViewCellSelectionStyleNone;
                toggle.on = [self.prefs[@"mixWithOthers"] boolValue];
                toggle.tag = 106;
                [toggle addTarget:self action:@selector(toggleChanged:) forControlEvents:UIControlEventValueChanged];
                cell.accessoryView = toggle;
                return cell;
            }
            default: break;
        }
    }

    if (indexPath.section == 3) {
        switch (indexPath.row) {
            case 0: {
                cell.textLabel.text = @"卡片背景开关";
                cell.selectionStyle = UITableViewCellSelectionStyleNone;
                toggle.on = [self.prefs[@"cardEnabled"] boolValue];
                toggle.tag = 103;
                [toggle addTarget:self action:@selector(toggleChanged:) forControlEvents:UIControlEventValueChanged];
                cell.accessoryView = toggle;
                return cell;
            }
            case 1: {
                cell.textLabel.text = @"选择卡片图片";
                BOOL exists = [LNBFileManager fileExistsNamed:kBGCardImage];
                cell.detailTextLabel.text = exists ? @"已设置" : @"未设置";
                cell.detailTextLabel.textColor = exists ? [UIColor systemGreenColor] : [UIColor secondaryLabelColor];
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
                return cell;
            }
            case 2: {
                cell.textLabel.text = @"卡片透明度";
                cell.selectionStyle = UITableViewCellSelectionStyleNone;
                UISlider *slider = [[UISlider alloc] initWithFrame:CGRectMake(0, 0, 160, 34)];
                slider.minimumValue = 0.2;
                slider.maximumValue = 1.0;
                slider.value = [self.prefs[@"cardAlpha"] floatValue];
                slider.tag = 201;
                [slider addTarget:self action:@selector(sliderChanged:) forControlEvents:UIControlEventValueChanged];
                cell.accessoryView = slider;
                return cell;
            }
            case 3: {
                cell.textLabel.text = @"暗色遮罩（提升可读性）";
                cell.selectionStyle = UITableViewCellSelectionStyleNone;
                toggle.on = [self.prefs[@"cardBlurOverlay"] boolValue];
                toggle.tag = 104;
                [toggle addTarget:self action:@selector(toggleChanged:) forControlEvents:UIControlEventValueChanged];
                cell.accessoryView = toggle;
                return cell;
            }
            default: break;
        }
    }

    if (indexPath.section == 4) {
        cell.textLabel.text = @"清除所有背景资源";
        cell.textLabel.textColor = [UIColor systemRedColor];
        cell.accessoryType = UITableViewCellAccessoryNone;
        return cell;
    }

    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    if (indexPath.section == 1 && indexPath.row == 1) {
        [self presentImagePickerForName:kBGGlobalImage];
    } else if (indexPath.section == 1 && indexPath.row == 2) {
        [self presentVideoPickerForName:kBGGlobalVideo];
    } else if (indexPath.section == 3 && indexPath.row == 1) {
        [self presentImagePickerForName:kBGCardImage];
    } else if (indexPath.section == 4 && indexPath.row == 0) {
        [self confirmClearAll];
    }
}

#pragma mark 控件回调

- (void)toggleChanged:(UISwitch *)sender {
    switch (sender.tag) {
        case 100: self.prefs[@"enabled"]         = @(sender.isOn); break;
        case 101: self.prefs[@"globalEnabled"]   = @(sender.isOn); break;
        case 102: self.prefs[@"globalUseVideo"]  = @(sender.isOn); break;
        case 103: self.prefs[@"cardEnabled"]     = @(sender.isOn); break;
        case 104: self.prefs[@"cardBlurOverlay"] = @(sender.isOn); break;
        case 105: self.prefs[@"videoMuted"]      = @(sender.isOn); break;
        case 106: self.prefs[@"mixWithOthers"]   = @(sender.isOn); break;
        default: break;
    }
    [self persistAndReload];

    // 静音开关会改变音量滑块的可用态，需要刷新该分区
    if (sender.tag == 105) {
        NSIndexSet *soundSection = [NSIndexSet indexSetWithIndex:2];
        [UIView performWithoutAnimation:^{
            [self.tableView reloadSections:soundSection withRowAnimation:UITableViewRowAnimationNone];
        }];
    }
}

- (void)sliderChanged:(UISlider *)sender {
    switch (sender.tag) {
        case 200: self.prefs[@"globalAlpha"] = @(sender.value); break;
        case 201: self.prefs[@"cardAlpha"]   = @(sender.value); break;
        case 202: self.prefs[@"videoVolume"] = @(sender.value); break;
        default: break;
    }
    [self persistAndReload];
}

- (void)persistAndReload {
    [self.prefs writeToFile:[self prefsPath] atomically:YES];
    [self syncToUserDefaults];
    [LNBFileManager postReload];
}

#pragma mark 文件选择

- (void)presentImagePickerForName:(NSString *)fileName {
    UIImagePickerController *picker = [[UIImagePickerController alloc] init];
    picker.sourceType = UIImagePickerControllerSourceTypePhotoLibrary;
    picker.mediaTypes = @[UTTypeImage.identifier];
    picker.delegate = self;
    picker.modalPresentationStyle = UIModalPresentationFullScreen;
    // 用 tag 传递目标文件名
    objc_setAssociatedObject(picker, @selector(presentImagePickerForName:), fileName, OBJC_ASSOCIATION_COPY_NONATOMIC);
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)presentVideoPickerForName:(NSString *)fileName {
    UIImagePickerController *picker = [[UIImagePickerController alloc] init];
    picker.sourceType = UIImagePickerControllerSourceTypePhotoLibrary;
    picker.mediaTypes = @[UTTypeMovie.identifier];
    picker.videoQuality = UIImagePickerControllerQualityTypeHigh;
    picker.delegate = self;
    picker.modalPresentationStyle = UIModalPresentationFullScreen;
    objc_setAssociatedObject(picker, @selector(presentVideoPickerForName:), fileName, OBJC_ASSOCIATION_COPY_NONATOMIC);
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)imagePickerController:(UIImagePickerController *)picker didFinishPickingMediaWithInfo:(NSDictionary<UIImagePickerControllerInfoKey,id> *)info {
    NSString *targetName = objc_getAssociatedObject(picker, @selector(presentImagePickerForName:));
    if (!targetName) {
        targetName = objc_getAssociatedObject(picker, @selector(presentVideoPickerForName:));
    }

    [picker dismissViewControllerAnimated:YES completion:^{
        if (!targetName) return;

        NSError *error = nil;
        BOOL ok = NO;

        if ([targetName isEqualToString:kBGGlobalVideo]) {
            NSURL *videoURL = info[UIImagePickerControllerMediaURL];
            if (videoURL) {
                ok = [LNBFileManager copyFileAtURL:videoURL toName:targetName error:&error];
            }
        } else {
            NSURL *imageURL = info[UIImagePickerControllerImageURL];
            UIImage *image = info[UIImagePickerControllerOriginalImage];
            if (imageURL) {
                ok = [LNBFileManager copyFileAtURL:imageURL toName:targetName error:&error];
            } else if (image) {
                // 无 URL 时（如某些相册资源）手动写 JPEG
                NSData *jpeg = UIImageJPEGRepresentation(image, 0.92);
                NSString *dest = [LNBFileManager pathForFile:targetName];
                ok = [jpeg writeToFile:dest atomically:YES];
            }
        }

        if (ok) {
            [self.prefs writeToFile:[self prefsPath] atomically:YES];
            [LNBFileManager postReload];
            [self.tableView reloadData];
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
        [self.tableView reloadData];
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
