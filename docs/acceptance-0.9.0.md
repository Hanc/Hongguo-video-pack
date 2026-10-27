# 红葡萄 0.9.0 验收

2026-10-27（Asia/Shanghai）。本版只解决「视频无法访问」，不新增功能、不改交付结构。

## 变更

- App 播放接口（`/novel/player/video_detail/v1/` 与 `multi_video_model`）在故障期间一律返回 **HTTP 200 + 空包**，`fetchVariants` 因此拿不到任何清晰度，界面显示「播放准备失败」。
- `lib/data/hongguo_client.dart` 现在按顺序取地址：App 接口（失败重试一次，间隔 400 ms）→ 网页公开画质兜底 → 两条都不通才报错。兜底取的是剧集 SEO 数据里的 `https://hongguoduanju.com/video/public/<vid>/360p.mp4`，先发 `HEAD` 校验状态码 200、`content-type` 为视频、`content-length` 非零，再交给播放器。
- 兜底画质只有 **360P（H.264）**，清晰度选择器此时只列一项；App 接口恢复后自动回到 720P/1080P，无需改配置。

## 已验证

- `dart analyze`：No issues found。
- `flutter test`：68 项通过、4 项跳过。新增「App 接口失败时退回网页公开画质」。
- `--playback-acceptance`（真实来源、Windows 成品，连续三次运行均 `passed:true`）：
  `{"passed":true,"nativeEngineConcurrent":true,"seek":true,"samples":[{"episode":1,"quality":360,"width":360,"height":640,"seconds":2,"frameBytes":244001,"openToPictureMs":2625},{"episode":2,"quality":360,"width":360,"height":640,"seconds":2,"frameBytes":245257,"openToPictureMs":2510}]}`。
  即两集都真正解码出帧（约 244 KB）、能 seek、双引擎并发加载、首帧 2.5–2.6 s。
- 三小时内的另一次运行为 `episode 1 → 360P、episode 2 → 1080P`，说明 App 接口是**时好时坏**，不是永久下线；重试即为此而加。
- 产物（`dist/`，SHA-256 见 `SHA256SUMS.txt`）：`Hongputao-Windows-0.9.0-Setup.exe` 77.4 MB、`Hongputao-Windows-0.9.0.zip` 110.2 MB、`Hongputao-Android-arm64-0.9.0.apk` 74.9 MB、`Hongputao-Source-0.9.0.zip` 0.8 MB。

## 边界与已知上游行为

- **这是上游故障，不是代码缺陷**：同一台机器、同一份签名代码，App 接口对详情与选集都回 200 空包（`content-length: 0`），网页播放器的受保护接口回 `{"code":1,"message":"protected_playback_unavailable"}`，只有 SEO 数据里的公开 mp4 还能取。详见 `docs/stream-investigation.md`。
- 兜底画质固定 360P，画面会比之前糊；这是「能看」与「高清」之间的取舍，接口恢复即自动恢复高清。
- 360P 公开文件是渐进式 mp4（无 CENC 加密），播放器不需要 `decryption_key`；App 接口的地址仍然是加密流，两条路径的加载参数不同。
- Android 未做真机验收：APK 已按同一包名与签名重新产出，逻辑与 Windows 共用 `fetchVariants`，但触屏播放与网络切换仍需真机确认。

## 下一轮建议顺序

1. 用 `Hongputao-Windows-0.9.0-Setup.exe` 覆盖安装（安装前建议退出旧版）。
2. 打开任意一部剧，确认能播放、能切集、能拖进度；此时清晰度显示 360P 属预期。
3. 过几小时再试，若清晰度回到 720P/1080P 说明上游已恢复。
4. Android 用同包名 APK 覆盖安装，重复第 2 步。
