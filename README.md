# LockNotifyBG — 锁屏通知背景自定义（iOS 16.0+）

为多巴胺（Dopamine）/ palera1n rootless 越狱环境编写的 Theos 插件，支持把**锁屏通知列表**的背景替换为自定义图片或循环视频，也可为**单条通知卡片**设置背景图。

---

## 一、目录结构

```
LockNotifyBG/
├── Makefile                                    # 根 Makefile（tweak + 聚合 prefs）
├── control                                     # Debian 包信息
├── LockNotifyBG.plist                          # Filter，限制只注入 SpringBoard
├── Tweak.xm                                    # 核心 hook 逻辑
├── build.sh                                    # 一键构建脚本
├── layout/
│   └── Library/PreferenceLoader/Preferences/
│       └── LockNotifyBG.plist                  # 设置入口
└── prefs/
    ├── Makefile                                # PreferenceBundle 构建配置
    └── NGBPrefsRootListController.m            # 设置界面
```

---

## 二、编译

前置条件：

- 已安装 [Theos](https://theos.dev)（`export THEOS=~/theos`）
- 已安装 iOS 16 SDK（`$THEOS/sdks/iPhoneOS16.5.sdk`）
- 安装 `ldid` 用于签名：`brew install ldid`（macOS）

```bash
export THEOS=~/theos
cd LockNotifyBG
./build.sh                 # 仅编译，产物在 packages/

# 或编译并安装到设备
export THEOS_DEVICE_IP=192.168.1.100
export THEOS_DEVICE_PORT=22
./build.sh install
```

手动编译等价于：

```bash
make clean && make package
```

---

## 三、功能与限制（务必先读）

| 功能 | 状态 | 说明 |
|---|---|---|
| 通知列表整体铺背景图 | ✅ 可用 | 通过 hook `NCNotificationListView` / `NCNotificationListSectionView` 的 `layoutSubviews`，在底层插入背景容器 |
| 通知列表播放循环视频 | ⚠️ 有限可用 | 使用 `AVPlayerLayer`，静音循环。系统刷新重建视图时会重新挂载，可能短暂闪烁 |
| 单条通知卡片背景图 | ✅ 可用 | 使用 `colorWithPatternImage` 设置 `backgroundColor`，不用子视图，抗层级重建 |
| 单条通知卡片视频 | ❌ 已放弃 | iOS 16 会重建 cell 层级，`AVPlayerLayer` 无法稳定存活，代码中自动退化为首帧静态图 |
| 免注销生效 | ✅ | 设置面板通过 `notify_post` 通知 SpringBoard 重载配置 |

### 关于 iOS 16 的重要事实

1. **必须 hook 私有类**。锁屏通知属于私有框架 `UserNotificationsUIKit` / `BulletinBoard`，所有通知类插件的 hook 目标都在私有框架里，这一点无法回避。本插件只依赖类名和 `layoutSubviews`，不 hook 深层私有方法，因此相对耐得住系统小版本更新。
2. **视图会被系统重建**。iOS 16 在收到新通知、展开分组、滚动时都会重建通知视图层级。因此代码采用「存在性检查 + 按需重挂载」而不是无脑重建，并把卡片背景做成 `UIColor` 而非子视图。
3. **类名可能随版本变化**。若某个系统版本上背景不出现，请用 `class-dump` 导出 `UserNotificationsUIKit.framework` 的类名，核对 `NCNotificationListView` / `NCNotificationListCell` 是否仍存在，并在 `Tweak.xm` 中补充 `%hook`。

---

## 四、资源文件位置

所有资源存放在：

```
/var/mobile/Library/LockNotifyBG/
├── global.jpg     # 全局背景图片
├── global.mp4     # 全局背景视频
├── card.jpg       # 卡片背景图片
└── prefs.plist    # 配置持久化
```

目录会被设置面板自动创建（权限 `0755`，属主 `mobile`），文件权限 `0644`。这是 rootless 越狱下 SpringBoard 可读且可写的位置。

---

## 五、配置项说明

| 键名 | 类型 | 默认值 | 含义 |
|---|---|---|---|
| `enabled` | BOOL | YES | 插件总开关 |
| `globalEnabled` | BOOL | YES | 全局背景开关 |
| `globalUseVideo` | BOOL | NO | 使用视频而非图片 |
| `globalAlpha` | float | 0.85 | 全局背景透明度 |
| `cardEnabled` | BOOL | NO | 卡片背景开关 |
| `cardAlpha` | float | 0.9 | 卡片背景不透明度 |
| `cardBlurOverlay` | BOOL | YES | 卡片叠暗色遮罩，保证文字可读 |

---

## 六、已知问题与调试

**背景不显示？**

1. 确认 `THEOS_PACKAGE_SCHEME` 与你的越狱方案一致。Dopamine 用 `rootless`；若你的版本是 roothide 系（如 dopamine-roothide / Bootstrap），改成 `roothide`。
2. 检查资源文件是否正确写入：
   ```bash
   ssh root@<设备IP> "ls -l /var/mobile/Library/LockNotifyBG/"
   ```
   若目录不存在，说明设置面板未正常创建目录，可手动创建：
   ```bash
   ssh root@<设备IP> "mkdir -p /var/mobile/Library/LockNotifyBG && chown mobile:mobile /var/mobile/Library/LockNotifyBG"
   ```
3. 查看日志定位问题：
   ```bash
   ssh root@<设备IP> "tail -f /var/log/syslog | grep LockNotifyBG"
   ```
4. 确认插件已加载：
   ```bash
   ssh root@<设备IP> "ps aux | grep SpringBoard"
   ssh root@<设备IP> "ls /var/jb/Library/MobileSubstrate/DynamicLibraries/ | grep LockNotify"
   ```

**视频卡顿或耗电？**

背景视频在锁屏常驻播放会持续耗电。建议使用较短视频（10 秒内、720p 以内）并保持静音。若追求省电，请关闭 `globalUseVideo` 改用静态图片。

---

## 七、卸载

```bash
ssh root@<设备IP> "rm -rf /var/mobile/Library/LockNotifyBG"
```
随后通过 Sileo / Zebra 卸载 LockNotifyBG 包即可。
