# 红葡萄 0.10.0 验收

2026-10-29（Asia/Shanghai）。本版修复「视频无法访问」的**真实原因**：App 播放接口需要一台来源认可的匿名设备身份。

## 根因

0.9.0 把故障判断为「上游接口整体空包」，于是加了一条 360P 网页公开画质兜底。这次对照开源项目 `jackotom/hongguo-drama`（GPL-3.0，带完整源码）后定位到差别：它的播放请求里带着**注册得到的** `device_id` / `iid`，而本项目的这两个值是本地随机生成的，服务端不认。

- 随机身份 → `multi_video_model` 返回 `HTTP 200` 空包，或 `code: 101000 服务异常`。
- 注册后的身份 → 正常返回全部 5 档画质（360/480/576/720/1080）。

注册走 `https://log5-applog-lf.fqnovel.com/service/2/device_register/`：设备信息 JSON → gzip → SHA-512 摘要前置 → AES-128-CBC（密钥由固定盐派生）→ 带 `x-ss-stub` 提交，返回 `device_id` 与 `install_id`。全过程匿名，不需要账号、验证码或 cookie。

## 变更

- 新增 `lib/data/device_registrar.dart`：纯 Dart 实现匿名注册，成功结果写入应用支持目录 `device-identity.json`，下次启动直接复用；注册失败只记一次、不重试，也不抛错。
- `lib/data/hongguo_client.dart`：首次请求前 `await _ensureIdentity()`，把 `device_id` / `iid` / `cdid` 换成注册值（查询参数与签名参数同步使用）。注册不可用时继续用随机值，此时自动退回 0.9.0 的网页公开画质路径。
- 版本 `0.9.0+22` → `0.10.0+23`；`THIRD_PARTY_NOTICES.md` 增加注册算法的上游署名。

## 已验证

- `dart analyze`：No issues found。
- `flutter test`：71 项通过、4 项跳过。新增 `test/device_registrar_test.dart` 三项（身份解析与校验、磁盘复用、注册被拒时不抛错）。
- `--playback-acceptance`（真实来源、Windows 成品）：
  `{"passed":true,"nativeEngineConcurrent":true,"seek":true,"samples":[{"episode":1,"quality":1080,"width":1080,"height":1920,"seconds":2,"frameBytes":1685041,"openToPictureMs":2619},{"episode":2,"quality":1080,"width":1080,"height":1920,"seconds":2,"frameBytes":1714384,"openToPictureMs":2972}]}`
  即两集都真正解码出 **1080×1920** 的帧（约 1.68–1.71 MB/帧），能 seek、双引擎并发加载、首帧 2.6–3.0 s。

## 边界与已知上游行为

- **不是每一集都能播**：同一身份下，被封禁/下架的分集仍然返回 `code: 101000`，界面上报「播放准备失败」。这类失败来自上游对具体分集的限制，换设备身份无用。
- 注册是**匿名**的：不涉及登录，也不保存任何 cookie 或 token；`device-identity.json` 只含 `device_id` / `iid` / `cdid` 三个数字/字符串，删掉即等于换一台新设备。
- 若注册接口被下线，应用会自动回退到 360P 网页公开画质（0.9.0 行为），不会白屏或崩溃。
- 本次没有引入 720P 网页 DASH 路线：那条流是 CENC 加密的，缺少内容密钥，硬接只能得到黑屏；详见 `docs/stream-investigation.md`。
