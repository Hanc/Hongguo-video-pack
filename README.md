# 红葡萄 Hongputao

Flutter Windows / Android 选剧、播放与合集制作工具。0.4.x 增加播放倍速（0.5x–2x，入口在播放器控制栏内，含记忆）与连播预取（提前取好下一集地址；播放器仍是单个 media_kit Player，避免双实例造成的全屏暂停与暂停后仍有声音）；修正 Windows 版本资源字符串编码，`ProductName` 不再被编译成乱码（这曾导致新版把设置与访客身份读写到错误目录而无法取流）；签名 worker 在应用支持目录不可写时自动降级到临时目录，避免整条取流因单点写入失败而报“播放准备失败”。发现页对榜单/分类页做 3 分钟页面缓存并预热其余榜单：来源改版后单页涨到 339 KB、服务端首字节 1–27 秒，重复切换不再重复等待。0.3.0 更名为“红葡萄”，采用用户提供的方形葡萄 Logo；搜索/榜单卡片可直接播放或进入拼接，播放页支持切集、清晰度、连播、范围选集、发起拼接和任务管理。桌面侧栏、手机底部导航，继续使用无边框卡片、阴影和留白。

## 使用

- **Windows 10/11 x64**：运行 `Hongputao-Windows-0.5.0-Setup.exe` 安装，可选择目录与桌面快捷方式，开始菜单提供启动和卸载入口。默认安装目录和应用标识保留升级兼容，无需管理员权限或另装 Flutter、Node、FFmpeg、Java。升级前请结束任务并退出旧版；安装程序不会强制关闭任务。卸载保留用户设置和导出视频。便携包仅作为备用交付。
- **Android 8.0+ ARM64**：安装交付的 APK。下载和拼接使用前台服务，通知显示受系统设置影响；成品先写入应用内目录，完成后点击“保存到手机”，通过系统文件选择器另存。卸载前请另存需要保留的视频。
- 输入红果播放页链接或剧集 ID，点击“读取剧集”。默认选中前两集，可点选、全选或按范围选择。
- 清晰度列表只显示来源实际返回且可处理的档位；当前示例能返回原始 1080P。访客取流已经可用，不需要从其他播放器导入账号。本版没有官方账号登录功能；App 搜索的访客初始化边界见下文。
- 点击“下载并拼接”。同规格素材直接保留码流；开启“自动兼容素材”时，纯尺寸差异优先取最常见规格，仅对差异集数等比缩放、补黑，保留其他集数原流；混合拼接必须通过完整解码校验。不满足兼容条件或校验失败时才回退为最常见尺寸、30fps、H.264/AAC 全量统一。解码和编码最多 2 线程，滤镜 1 线程；这是线程预算，不是固定 CPU 百分比上限。
- 可另行导入已有本地视频，按列表顺序调整后拼接。
- 失败或取消后，已完成分集留在导出目录的 `.hongguo-cache`，重新执行会校验并复用。未完成的一集重新下载；不声称支持字节级断点续传。
- “最近导出”保留最近 20 条记录。清理缓存不会删除导出的 MP4。

默认 Windows 导出目录为系统文档目录下的 `Hongguo Studio/exports`，可以自行选择其他可写目录。工作区设置保存在应用支持目录，不在安装目录写入个人配置。

## 剧库与搜索

- 点击卡片或“播放”进入内置播放页；“拼接”进入工作台选择下载与拼接范围，长按卡片可看简介。
- 播放页支持 0.5x–2x 倍速（入口在播放器控制栏内），切集与切画质后保持，退出再进入沿用上次选择；支持记住每部剧的观看位置并在下次自动续播，桌面端提供快捷键（空格、方向键、F 全屏、M 静音、I 播放信息、`,` `.` 帧步进），移动端全屏下双击左右侧快退/快进 10 秒、双击中间播放暂停，控制栏内可打开播放信息浮层（分辨率、解码方式、像素格式、缓冲与轨道）。自动连播时，下一集在当前集播放期间完成取流和首帧解码，到点只切换播放通道，不再重新打开媒体流，因此不会出现等待网络的黑屏；预加载失败或关闭自动连播时回退为按需取流，不阻断当前播放。
- 播放页的“播放选集”用于切集，“选择拼接”用于勾选任务分集；“拼接所选”直接启动任务。已有任务进行时可继续播放，但不新建或覆盖正在进行的拼接任务。
- 播放页右上角“任务管理”可看进度、取消任务和查看导出记录；离开播放页停止播放器，已开始的拼接任务继续运行。
- 更名后，Windows 首次运行只复制旧应用支持目录中已知的设置、访客初始化和分类缓存；不覆盖新设置，不移动旧导出文件。

- 发现页支持总热播榜、真人剧榜、漫剧榜和 AI 剧榜；榜单和漫剧分类可以继续加载后页。
- 0.2.1 起，默认直接调用红果网页版搜索，单次请求返回即显示首批，**禁止在默认搜索前扫描全片库**。保持来源顺序；热度缺失时后台补充，不阻塞结果。
- 0.2.2 支持本机访客初始化后的 App 搜索与真实游标分页，不需要账号登录、Cookie 或常驻模拟器。已在程序内实测两页不同剧集、热度和返回上页缓存；不伪造未知总页数。
- 0.2.3 修复 App 搜索封面显示：对 HEIC/HEIF 或缺失封面，按剧集 ID 在后台读取详情页的兼容封面；最多 3 个并发、逐张显示、复用详情缓存，不阻塞搜索首批、不修改签名图片 URL 后缀。
- App 搜索目前需要有效的已注册访客身份。应用只从自己的支持目录读取 `search-visitor.json`（version 1，仅设备/安装标识），身份不内置、不随安装包分发。首次自动注册仍未完成，本机试用已单独配置；其他电脑/手机不能据此视作已经初始化。
- 未配置时继续显示官网首批及其限制。网页 `page=2` 仍重复首批；界面明确显示网页返回数和来源报告总数，不伪装成全站分页。
- 用户主动点击“补充检索分类片库（较慢）”才建立真人剧、漫剧、AI 剧本地索引，补充结果每页 20 部，支持上下页、30 分钟缓存。范围不是全站完整剧库，不在后台自动扫描。
- 搜索结果显示详情页实际返回的热度，存在明确播放次数字段才显示播放量；缺失时省略。不把评分、收藏数当播放量。
- 工作台的“查看关联作品 / 其他季”按去除季数后的同名标题检索；不声称是官方关联关系。
- 随机推荐从真人剧、漫剧或 AI 剧分类随机选页抽取，尽量避开本次会话已展示的结果，不代表官方个性化推荐。
- 剧库卡片只作选剧入口，进入工作台后重新读取完整分集，不能使用分类页预览片段代替全剧。

## 验证

本次播放与更名验证见 [docs/acceptance-0.3.0.md](docs/acceptance-0.3.0.md)，倍速与连播预加载的验证边界见 [docs/acceptance-playback-rate-and-preload.md](docs/acceptance-playback-rate-and-preload.md)，封面修复见 [docs/acceptance-0.2.3.md](docs/acceptance-0.2.3.md)，历史验证见 [docs/acceptance.md](docs/acceptance.md)。Windows 内置播放器已对两集 1080P 实际出帧并验证切集和拖动。Android APK 构建不等于真实手机播放、系统保存和后台任务验收，这些需在验收设备上确认。

## 开发与构建

使用 Flutter 3.47.7 / Dart 3.13.5、Node.js 24、Java 21、Android SDK/NDK、Windows Visual Studio C++ 和 Inno Setup 6.5+ 构建工具。依赖由 `pubspec.lock` 固定。Windows 构建时将发现的 Node 可执行文件一并打包，目标电脑不依赖 PATH。

```powershell
flutter pub get
flutter analyze
flutter test
flutter build windows --release
pwsh.exe -NoLogo -NoProfile -File scripts/prepare-signing.ps1
flutter build apk --release --target-platform android-arm64
pwsh.exe -NoLogo -NoProfile -File scripts/package.ps1
```

`prepare-signing.ps1` 仅在首次构建生成本地发布密钥，不覆盖现有密钥。**私下备份 `.local/signing/` 和 `android/key.properties`，不要提交或随安装包分发。** 后续 Android 升级需使用同一密钥。

联网协议检查（会实际请求示例剧集）：

```powershell
$env:HONGGUO_LIVE_TEST='1'
flutter test test/live_protocol_test.dart
./android/gradlew.bat -p android :app:testDebugUnitTest
```

Windows Release 整体检查：在项目根目录运行 `build/windows/x64/runner/Release/hongguo_studio.exe --acceptance`。结果写入 `.local/acceptance/result.json`，只记录画质、轨道、时长和任务事件，不记录媒体密钥或临时地址。

`--smoke` 用于验证打包的原生 FFmpeg 引擎。可选外部 FFmpeg 测试需要 PATH 中的 ffmpeg/ffprobe，或设置 `HONGGUO_FFMPEG` / `HONGGUO_FFPROBE`；普通应用使用内置引擎。

`--search-acceptance` 使用本机初始化信息验证成品运行时的两页搜索、去重与返回缓存，结果写入 `.local/search-acceptance/result.json`，不输出身份或签名值。来源 API 参考见 [.agents/api/README.md](.agents/api/README.md)。

`--playback-acceptance` 在真实 Flutter 原生窗口中播放来源视频，验证解密出帧、拖动和下一集，并在播放期间运行内置拼接引擎检查。脱敏报告及画面样本保存在 `.local/playback-acceptance/`。内置 libmpv 运行库随安装包分发，不依赖用户安装播放器。

`--switch-acceptance` 用内置引擎生成的本地样片验证连播双通道与倍速：预加载不打断当前播放、切换只交换通道、切换后保持倍速。不依赖来源网络与签名，结果写入 `.local/switch-acceptance/result.json`。

GitHub Actions 自动构建/Release 流程及首次签名 Secrets 配置见 [docs/releasing.md](docs/releasing.md)；透明图标母版及导出说明见 [docs/branding.md](docs/branding.md)。

桌面发布必须提供安装程序：Windows 为 Setup.exe；Linux / macOS 后续接入时也应提供对应系统安装格式。目前尚未交付 Linux / macOS 构建，不能把 Windows 包当作这些系统的安装包。

## 结构与许可

- `lib/`：共享界面、单剧数据、任务编排、缓存、媒体校验与导出。
- `assets/protocol/`：Windows 签名适配；`android/.../protocol/`：Android 原生签名适配。
- `android/.../MainActivity.kt`：签名桥接、系统文件导入/保存及文件预览。
- `scripts/`：本地签名准备、可重复打包、Inno Setup 安装包构建与安装 / 卸载验证。
- `installer/`：Windows 安装器与简体中文翻译（来自 jrsoftware/issrc 官方仓库，保留原文件声明）。

协议适配包含 GPL-3.0-only 来源代码，媒体引擎包含 GPL 组件；本交付随附完整应用源码、许可证和来源声明。见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) 及 `licenses/`。本程序不是红果官方客户端。使用的是来源接口实际返回的访问能力，未接入第三方收费解析服务。
