# 开发回路（怎么把一次改动验完最快）

更新：2026-10-22。这份文档只解决一个问题：改一行字别再付出「重建 + 重打包 + 重装」的代价。

## 实测耗时（本机，2026-10-22，D:\DeepseekHarness）

| 步骤 | 命令 | 耗时 |
| --- | --- | --- |
| 静态检查 | `dev.ps1` 里的 `dart analyze` | 8–15 秒 |
| 单元/组件测试（65 项） | `flutter test --no-pub` | 15 秒 |
| 单个测试文件 | `flutter test --no-pub test/x_test.dart` | 6–10 秒 |
| Windows Release 构建 | `flutter build windows --release --no-pub` | 43–45 秒 |
| Android arm64 Release | `flutter build apk` | 55 秒（改过 Dart）/ 13 秒（无改动）/ 首次或清缓存后 3–4 分钟 |
| Inno Setup 安装包 | `compile-iss.ps1`（lzma2 压 110MB） | 61 秒 |
| 便携 zip + 源码包 + APK 拷贝 | `pack-portable.ps1` | 20–25 秒 |

结论：**迭代期最贵的是安装包（61 秒）与第一次 APK 构建**，而且这两样在改手势、改文案时根本不需要。一次「改点交互 → 构建 release → 跑本地验收」的往返约 60 秒；把 APK 和安装包也带上就变成 2–3 分钟，发版时才值得。

## 一次改动该跑什么

| 改动类型 | 必须跑 | 不要跑 |
| --- | --- | --- |
| 文案、样式、布局、控件 | `dev.ps1 check` | APK、安装包 |
| 手势、控制栏、播放页交互 | `check` + `test -Arg test/playback_gestures_test.dart` + `dev.ps1 win` + `dev.ps1 accept -Arg switch` | APK |
| 播放控制器、预取、倍速 | `check` + `accept -Arg switch` | 安装包 |
| 全屏 / 旋转 / 平台回调 | `check` + `accept -Arg fullscreen` | APK |
| 来源接口、签名、解密 | `check` + `flutter test test/live_protocol_test.dart` + `accept -Arg playback`（走真实网络，最慢） | 安装包 |
| 发现页、缓存、追剧列表 | `check` + `test -Arg test/discovery_widget_test.dart` | APK |
| 打包、安装器、版本号 | `dev.ps1 setup` + `dev.ps1 dist` | 单测（除非版本号写进代码） |
| 发版 | `dev.ps1 release` | — |

`dev.ps1 release` 会把 Windows 与 Android 两条不共享工具链的构建并行跑，再依次做安装包与打包，并在结束时自动还原 `pubspec.lock`。

## 四个已经踩过的坑（都在工具里堵住了）

1. **`pubspec.lock` 噪声**：镜像 `PUB_HOSTED_URL=https://pub.flutter-io.cn` 会把 lock 里每个包的 `url` 改写成镜像地址，看一眼像「变了 92 个依赖」，其实版本一个没动。`dev.ps1` 在每条任务前后快照并还原它，提交前不会再混进这种 diff。
2. **隐式 `pub get`**：lock 是 `pub.dev` 而环境变量是镜像，于是每条 `flutter` 命令都要重新解析依赖，白等 5–8 秒。工具里统一加 `--no-pub`，只在你真要改依赖时才手动 `flutter pub get`。
3. **`%TEMP%` 不可写就静默失败**：`media_kit` 截图走 `Directory.systemTemp`，不可写时报 `PathAccessException: Cannot create file ... errno = 5`。验收脚本把 `TEMP`/`TMP` 指到仓库内 `.local/tmp`；成品程序在 0.8.1 起会把失败原因和栈打印到 stderr（此前是静默 `exit(1)`）。
4. **PowerShell 5.1 的两个坑**：无 BOM 的 UTF-8 脚本里有中文会解析失败（脚本一律 ASCII）；`& exe *>` 抓不到这个程序的控制台输出，要用 `cmd /c "exe > log 2>&1"`。

## 常用命令

```powershell
# 快速闸门：静态检查 + 全量测试，约 30 秒
powershell -File D:\DeepseekHarness\.tools\dev.ps1 check

# 只跑一个测试文件
powershell -File D:\DeepseekHarness\.tools\dev.ps1 test -Arg test/playback_gestures_test.dart

# 构建 Windows 并跑本地验收（不碰 APK / 安装包）
powershell -File D:\DeepseekHarness\.tools\dev.ps1 win
powershell -File D:\DeepseekHarness\.tools\dev.ps1 accept -Arg switch

# 发版：并行构建 + 安装包 + 打包
powershell -File D:\DeepseekHarness\.tools\dev.ps1 release

# 看当前版本、产物时间与上次各阶段耗时
powershell -File D:\DeepseekHarness\.tools\dev.ps1 status
```

## 还能再快吗

- **APK**：已经只出 arm64，改一行 Dart 的增量重建是 55 秒，无改动 13 秒。真正的成本是 74MB 的 `libavcodec`/`libmpv` 重新打包；除非换自编译 FFmpeg（去掉 avfilter/x264），否则压不下去。
- **安装包 61 秒**：把 `Compression=lzma2` 换成 `lzma2/fast` 能降到 25 秒左右，代价是安装包大 3–5MB。只在本地自测值得，发版不要用。
- **Windows 构建 43 秒**基本是编译 + 资源拷贝的下限：只改 Dart 代码时可改用 `flutter build windows --debug`（约 18 秒），但 debug 版运行慢，验收必须用 release。
