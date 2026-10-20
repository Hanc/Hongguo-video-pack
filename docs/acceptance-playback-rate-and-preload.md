# 播放倍速、连播预取与播放链路修复验收边界

核对日期：2026-10-20（Asia/Shanghai）。适用版本 0.4.3+10。规格见 [播放倍速与连播预取](../../.agents/notes/active/playback-rate-and-preload.md)。

## 一、方案取舍（重要）

0.4.0–0.4.2 曾用"双 Player 通道 + 交换"实现零等待切集，实测暴露两个问题：切全屏时画面暂停、暂停后仍有声音（另一条通道未被暂停）。这两点是双实例自造方案的固有代价。

调研后确认没有可直接复用的等价方案：

- **官方 playlist 方案不可用**：`media_kit` 的 `Media` 只接受 `uri` / `httpHeaders` / `extras`，没有 per-file 的 mpv 或 lavf 选项；而本项目每集使用**独立的 CENC 解密键**，playlist 无法为每条目单独设置 `decryption_key`。
- **playlist 本身也有已知音频问题**：社区已有"切换曲目瞬间播放错误音轨"的报告（`Wrong video/audio briefly plays on flutter media_kit player before correct track starts in playlist`）。

因此 0.4.3 回退为**单个 `Player`（media_kit 标准用法）**，连播加速改在控制器层完成：提前取好下一集的取流结果（签名 + 播放地址），切集时不再重新签名与请求，只由播放器完成开流与首帧。

## 二、真实来源播放

`hongguo_studio.exe --playback-acceptance` 在真实 release 程序内通过，使用来源实际返回的 1080P 资源：

```json
{"passed":true,"nativeEngineConcurrent":true,"seek":true,
 "samples":[{"episode":1,"quality":1080,"width":1080,"height":1920,"seconds":2,"frameBytes":1685041},
            {"episode":2,"quality":1080,"width":1080,"height":1920,"seconds":2,"frameBytes":1714384}]}
```

两集均实际解码出帧，`seek` 正常。

## 三、倍速、切集与暂停（本地样片）

`--switch-acceptance` 使用内置引擎生成的本地样片，不依赖网络与签名：

```json
{"passed":true,"rateApplied":1.5,"switchMs":143,"rateRetained":1.5,
 "width":180,"pausedPositionFrozen":true,"pausedDeltaMs":0,"playingAfterPause":false}
```

- `rateApplied 1.5` / `rateRetained 1.5`：倍速真正传入播放器，切集后保持。
- `switchMs 143`：切集到出画面 143 ms（单通道，含开流与首帧）。
- **`pausedPositionFrozen: true`、`pausedDeltaMs: 0`、`playingAfterPause: false`**：暂停后播放位置零位移、播放器状态确认为停止。这是对"暂停后仍有声音"的回归断言，双实例方案下该断言不成立。

## 四、来源链路独立复现

用 Node 复刻 `signRequest`（X-Gorgon）、`mediaAddress`（AES-CBC）、`contentKey`（CENC 密钥），绕开 Flutter 独立验证：详情 code 0（100 集）、签名取流 code 0、`key_seed` 存在、5 档画质地址全部解出、CENC 密钥全部解出、媒体 CDN 返回 206。确认接口侧无异常。

## 五、其它已修缺陷

1. **版本资源编码**：`Runner.rc` 原用 ANSI 1252 字符串块且无 BOM，中文 `ProductName` 被编译成乱码，导致程序读写错误的用户数据目录、签名 worker 落不了盘。已改为 Unicode 块并以 UTF-8 BOM 保存。
2. **签名 worker 单点失败**：`_prepare()` 改为「应用支持目录 → 临时目录 → 系统临时目录」逐级降级。
3. **发现页重复等待**：榜单/分类/搜索页增加 3 分钟页面缓存与并发合并，并在首屏成功后预热其余榜单；详情页不缓存，避免挡住封面修复。

## 六、自动化测试

`dart analyze` 无问题；`flutter test` 47 项全部通过，覆盖：预取下一集后切集不再重复取流、旧请求不覆盖新选择、自动连播只前进一步、关闭自动连播停在当前集、倍速归一与下发、控制栏倍速按钮提供全部档位、发现页缓存命中与换榜重新请求、错误文案不泄漏地址。

## 七、尚未验证

- Android 真实手机播放、系统保存与前台服务（本次仅构建 APK）。
- 切集时若预取的签名地址已过期，会回退为重新取流，其等待时长未在弱网下量化。
- 长时间连续自动连播的稳定性与资源占用。
- 安装包的端到端安装/卸载需在正常桌面环境复跑 `scripts/test-installer.ps1`（构建环境不允许写入用户目录与注册表）。
