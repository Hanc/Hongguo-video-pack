# 开发回路（怎么把一次改动验完最快）

更新：2026-10-22。这份文档只解决一个问题：改一行字别再付出「重建 + 重打包 + 重装」的代价。

## 实测耗时（本机，2026-10-22，D:\DeepseekHarness）

| 步骤 | 命令 | 耗时 |
| --- | --- | --- |
| 静态检查 | `dev.ps1` 里的 `dart analyze` | 8–15 秒 |
| 单元/组件测试（65 项） | `flutter test --no-pub` | 15 秒 |
| 单个测试文件 | `flutter test --no-pub test/x_test.dart` | 6–10 秒 |
| 本地验收（不联网） | `dev.ps1 accept -Arg switch` | 4.7 秒 |
| Windows Release 构建 | `flutter build windows --release --no-pub` | 43–45 秒（全量）/ 17 秒（无改动增量） |
| Android arm64 Release | `flutter build apk` | 55 秒（改过 Dart）/ 13 秒（无改动）/ 首次或清缓存后 3–4 分钟 |
| Inno Setup 安装包 | `compile-iss.ps1`（lzma2 压 110MB） | 61–63 秒 |
| 便携 zip + 源码包 + APK 拷贝 + 校验 | `pack-portable.ps1` | 24–29 秒 |

一次发版实测合计（`dev.ps1 release`，Windows 构建与 APK 并行）：17 + 28 + 63 + 29 ≈ **2 分 20 秒**。

结论：**迭代期最贵的是安装包（63 秒）与第一次 APK 构建**，而且这两样在改手势、改文案时根本不需要。一次「改点交互 → 构建 release → 跑本地验收」的往返约 65 秒；把 APK 和安装包也带上就变成 2 分多，发版时才值得。

## 一次会话的时间去了哪（2026-10-22 复盘）

0.8.0 → 0.8.1 那一轮（上下滑切集 + 长按不弹控制栏）实际耗时 29 分 38 秒。按上表累加，构建、测试、打包这些**机器在跑的**部分约 12.5 分钟，剩下约 17 分钟是交互往返与试错，具体浪费在这些地方：

1. `catch (_) { exit(1); }` 把验收失败的栈吞掉了，我先猜「沙箱限制」、再猜「ACL 损坏」，第三次改成打印栈才一眼看到 `TempFile.create → errno = 5`。**教训：出错先要栈，不猜。**
2. 为确认控制栏遮罩的触发点，逐个读了 `material.dart`、`video_texture.dart`、theme 等 5 个大文件，其中 3 次是全量读取。**教训：先 `grep` 定位，再定向读 30 行。**
3. 全量测试跑了 6 次，每次 15 秒，但每次前后各一次工具往返；真正需要全量的只有最后一次。**教训：改哪个模块就只跑那个测试文件。**
4. 构建完才第一次跑 `dist`，撞上 staging 残留与源码 zip 覆盖失败，又多跑 2 次打包。**教训：打包脚本只在发版时跑，并且当场跑通再提交。**
5. 130 多次工具调用本身有固定延迟。**教训：同类命令合并成一条，靠 `dev.ps1 verify` 把 4 个步骤压成 1 次调用。**

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
| 发布到对象存储 | `node scripts/publish-cos.mjs release`（两平台约 40 秒，含回读校验） | 重新构建（产物没变就不必重打） |

`dev.ps1 release` 会把 Windows 与 Android 两条不共享工具链的构建并行跑，再依次做安装包与打包，并在结束时自动还原 `pubspec.lock`。

## 四个已经踩过的坑（都在工具里堵住了）

1. **`pubspec.lock` 噪声**：镜像 `PUB_HOSTED_URL=https://pub.flutter-io.cn` 会把 lock 里每个包的 `url` 改写成镜像地址，看一眼像「变了 92 个依赖」，其实版本一个没动。`dev.ps1` 在每条任务前后快照并还原它，提交前不会再混进这种 diff。
2. **隐式 `pub get`**：lock 是 `pub.dev` 而环境变量是镜像，于是每条 `flutter` 命令都要重新解析依赖，白等 5–8 秒。工具里统一加 `--no-pub`，只在你真要改依赖时才手动 `flutter pub get`。
3. **`%TEMP%` 不可写就静默失败**：`media_kit` 截图走 `Directory.systemTemp`，不可写时报 `PathAccessException: Cannot create file ... errno = 5`。验收脚本把 `TEMP`/`TMP` 指到仓库内 `.local/tmp`；成品程序在 0.8.1 起会把失败原因和栈打印到 stderr（此前是静默 `exit(1)`）。
4. **PowerShell 5.1 的两个坑**：无 BOM 的 UTF-8 脚本里有中文会解析失败（脚本一律 ASCII）；`& exe *>` 抓不到这个程序的控制台输出，要用 `cmd /c "exe > log 2>&1"`。

## 常用命令

```powershell
# 一次交互的完整回路：静态检查 + 全量测试 + release 构建 + 本地验收，约 70 秒
powershell -File D:\DeepseekHarness\.tools\dev.ps1 verify

# 只跑静态检查 + 全量测试，约 25 秒
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
