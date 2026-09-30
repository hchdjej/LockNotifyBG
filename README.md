# LockNotifyBG — 锁屏通知背景自定义

为 **iOS 16.5 / iPhone 14 Pro Max / 隐根越狱（Dopamine / palera1n rootless）** 编写的 Theos 插件。
把锁屏通知列表的背景替换为自定义图片或循环视频，支持透明度、音量、静音调节。

## 功能

| 功能 | 状态 | 说明 |
|---|---|---|
| 通知列表整体背景图 | ✅ | hook `NCNotificationListView` / `NCNotificationListSectionView` |
| 通知列表循环视频 | ✅ | `AVPlayerLayer` 循环播放 |
| 背景透明度 | ✅ | 设置面板滑块 0.2–1.0 |
| 音量调节 | ✅ | 滑块 0–1，静音时自动置灰 |
| 静音开关 | ✅ | 默认静音，可主动开启 |
| 与其他音频混音 | ✅ | 开启后背景视频不中断音乐播放 |
| 单条通知卡片背景图 | ✅ | `colorWithPatternImage`，抗视图重建 |
| 单条卡片视频 | ❌ | iOS 16 会重建 cell 层级，自动退化为首帧静态图 |
| 免注销生效 | ✅ | 通过 `notify_post` 通知 SpringBoard 重载配置 |

## 编译（GitHub Actions，无需 Mac）

仓库已配置自动编译：推送到 `main` 即触发。

```
Actions → Build LockNotifyBG → 运行完成 → Artifacts 下载 LockNotifyBG-rootless
或 Releases 页面直接下载 .deb
```

每次构建后会自动创建 Release（tag 形如 `v1.1.0-build.N`）。

## 本地编译（macOS）

前置：Theos + `iPhoneOS16.5.sdk` + `ldid`

```bash
export THEOS=~/theos
make clean && make package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootless
# 产物在 packages/
```

## 安装

```
Sileo / Zebra 直接安装 deb，或
dpkg -i com.hchdjej.locknotifybg_1.1.0_iphoneos-arm64.deb
```

依赖：`ellekit`、`preferenceloader`（Dopamine 默认源自带）

## 资源路径

```
/var/mobile/Library/LockNotifyBG/
├── global.jpg     # 全局背景图
├── global.mp4     # 全局背景视频
├── card.jpg       # 卡片背景图
└── prefs.plist    # 配置持久化
```

## 使用

设置 → 锁屏通知背景：

- **功能开关** — 总开关
- **全局背景** — 开关 / 选图 / 选视频 / 用视频 / 透明度
- **声音** — 静音 / 音量 / 与其他音频混音
- **通知卡片背景** — 开关 / 选图 / 透明度 / 暗色遮罩
- **其它** — 清除所有资源

## 已知限制

1. **必须 hook 私有类**。锁屏通知属于私有框架 `UserNotificationsUIKit` / `BulletinBoard`，无法回避。本插件只依赖类名与 `layoutSubviews`，不 hook 深层私有方法。
2. **类名可能随系统版本变化**。若背景不出现，用 `class-dump` 导出 `UserNotificationsUIKit.framework`，核对 `NCNotificationListView` / `NCNotificationListCell` 是否存在，并在 `Tweak.xm` 中补充 hook。
3. **视频模式可能短暂闪烁**。系统刷新重建视图时会重新挂载播放层。
4. **背景视频出声会与音乐播放器争抢音频通道**，因此默认静音；开启声音后建议同时开启「与其他音频混音」。

## 项目结构

```
LockNotifyBG/
├── Makefile                                     # 根 Makefile（tweak + aggregate prefs）
├── control                                      # Debian 包信息
├── LockNotifyBG.plist                           # Filter，仅注入 SpringBoard
├── Tweak.xm                                     # 核心 hook 逻辑
├── build.sh                                     # 本地一键构建
├── layout/Library/PreferenceLoader/Preferences/ # 设置入口 + 图标
├── prefs/
│   ├── Makefile                                 # PreferenceBundle 构建配置
│   └── NGBPrefsRootListController.m             # 设置界面
└── .github/workflows/build.yml                  # GitHub Actions 自动编译
```
