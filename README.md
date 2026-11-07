# ARC 长按全屏启动 (AxsHoldLaunch)

ScreenCore 的配套插件：在 ARC 菜单上增加"长按松手触发"。手指在菜单图标上停留达到设定时长就**全屏**打开该应用，不满时长则按**分屏**打开；两个动作可以通过"反转长按动作"对调。

## 设置入口

系统设置 → screencore-窗口调度版 → 分屏设置 → **启动** 分组（插在"ARC 打开方式 / 侧边打开方式"之后）：

| 设置项 | 类型 | 默认 | 说明 |
|---|---|---|---|
| 长按松手触发 | 开关 | 关 | 开启后由停留时长决定全屏/分屏，覆盖"ARC 打开方式" |
| 长按触发时间 | 滑条 0.10–3.00s | 1.00 | 在图标上的停留时长阈值 |
| 反转长按动作 | 开关 | 关 | 开启后：停留≥时长 → 分屏；<时长 → 全屏 |

"停留时长"按手指**落在当前图标上**（高亮选中该应用）到**松手**的时间计算，点按和拖动选择两种操作方式都适用。

## 说明

- 原版 ScreenCore 的二进制没有任何改动；本插件通过 hook 它未混淆的 ObjC 方法（`sc_handleSelectedBundleIdentifier:sourceFrame:` → `sc_openTargetIdentifier:…launchFullscreen:` 等，运行时自动发现归属类）工作。
- 若某次打开不是来自 ARC 菜单（通知、URL、收藏栏等），不受影响；侧边手势菜单若走同一选择通道，也会同样生效。
- 设置写入 `com.axs.holdlaunch`，与 ScreenCore 自身配置互不干扰；SpringBoard 侧每次触发时实时读取，改设置即时生效，无需注销。
- 依赖：mobilesubstrate。最低 iOS 15（跟随 ScreenCore）。架构 arm64 + arm64e。

## 构建

GitHub Actions 已配置 rootless + roothide 两种变体（macOS 14 / Xcode 15.4 / iPhoneOS 16.5 SDK / roothide-theos）。推送到 main 或手动触发 workflow，即在上传 Artifact 并创建 Release。本地构建：

```sh
sh build.sh rootless      # 或 roothide / all
```

安装哪个 deb 取决于设备引导环境：roothide Bootstrap 装 `roothide` 变体，Dopamine 等 rootless 装 `rootless` 变体。安装后注销一次（或重启 SpringBoard）生效。

## 排错

- 触发无效果：确认开关已打开，并查看 SpringBoard 日志中 `[AxsHoldLaunch]` 前缀。`springboard hooks: update=N handle=M openTarget=K` 若某项为 0，说明对应入口在该版本 ScreenCore 中不存在，功能对相应路径不生效（不会崩溃）。
- 全屏/分屏方向反了：打开"反转长按动作"。
