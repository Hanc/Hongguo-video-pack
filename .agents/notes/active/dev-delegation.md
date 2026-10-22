---
status: active
kind: working-agreement
updated_at: 2026-10-22
modules:
  - 开发流程
  - 验证
  - 打包
---

# 开发流程与验证分工

## 用户原始需求（逐字保留）

> 我不是加了个dsh-agent-teams插件了吗，以后17分钟的测试来分工给他们操作不就好了

> 这次耗时很久哇，能不能优化下这个流程方案呀

> 问一下，这个优化能不能这样，把测试的时间压缩下来，比如我们在开发功能的时候只需要测试部分相关的功能就好，最后再一次性测试剩下的

## 为什么分工：一次 29 分 38 秒的复盘

那次发的版本是 0.8.0，版本号 19。构成：

- 机器时间约 12.5 分钟：Windows Release 构建 45 秒、APK 55 秒、Setup 63 秒、发布包 29 秒、验收 5 次、`flutter test` 一共 1.5 分钟。
- 往返时间约 17 分钟：每条命令一次调用、出错就重来、我自己重新读文件、你确认的间隔。

机器时间掩盖不掉，往返时间可以。所以分工的目标不是"把 29 分钟变成 5 分钟"（不可能），而是：

1. 把"长、独立、结论能压成一行"的活移出主线程，让改代码和构建重叠；
2. 用一行结果替代整段日志，减少我重新读上下文的次数。

## 分工边界

| 角色 | 负责 | 明确不碰 |
| --- | --- | --- |
| **verifier** | `dev.ps1 check/verify/test/accept`，报每步耗时 + 验收 JSON + 第一个失败用例 | 不改源码、不提交、不打包 |
| **packager** | `dev.ps1 apk/setup/dist/release`，`aapt2`/`apksigner` 校验版本号、ABI、签名指纹、`SHA256SUMS.txt` 条目数 | 不改 Dart、不碰 `android/key.properties` 与 `.jks` |
| **主线程（我）** | 根因定位、方案决策、改代码、写文档、提交、与用户对话、评审 | — |

分界线：**长、独立、结论可压缩**的活交出去；**需要判断**的留主线程。跑一个 6 秒的测试文件不值得委派（委派开销更大）。

## 默认流程

**小改动（1 到 2 个文件）**
1. 我改代码 → `dev.ps1 check`（`dart analyze` + `flutter test`，约 25 秒）
2. 需要真实引擎验证时，交 verifier 跑 `dev.ps1 verify`（约 40 秒，含 Windows 增量构建与 `--switch-acceptance`）
3. 我提交

**肉眼可见的交互改动（控制层、手势、布局）**
1. 我改代码 → `dev.ps1 check`
2. verifier 跑 `verify`，同时我准备文档或下一步
3. 需要看画面时用 `dev.ps1 win` + 用户自己开程序，不靠截图硬判

**发版**
1. 我确认 `pubspec.yaml` 版本号、`lib/main.dart` 版本字符串、`README` 说明
2. packager 跑 `dev.ps1 release`（Windows 与 APK 并行构建，再 Setup 与 dist）
3. packager 回包：版本号、ABI、签名指纹、条目数、耗时
4. 我提交并汇报

## 委派时禁止的事

- 不让成员 `git commit`/`git checkout`/改源码，避免并行写坏工作区。
- 不让成员跑 `scripts/prepare-signing.ps1`（会生成新密钥，破坏 Android 覆盖升级）。
- 不并发跑两个会写 `build/` 的任务（资源竞争，且 Gradle 会锁目录）。

## 环境坑（必须写进成员提示）

- 没有 `pwsh.exe`，一律 `powershell.exe -NoProfile -ExecutionPolicy Bypass -File`。
- 脚本必须纯 ASCII：PowerShell 5.1 读 UTF-8 无 BOM 的中文字面量会报"字符串缺少终止符"。
- 通过 `ops_bash` 传 Windows 路径时反斜杠会被吃掉（`D:\a\b` 变成 `D:ab`），用正斜杠 `D:/a/b`。
- `dev.ps1` 内部已处理两件事：镜像会改写 `pubspec.lock` 的 hosted url（退出时自动还原），`media_kit` 需要可写的 `Directory.systemTemp`（任务运行时把 `TEMP`/`TMP` 指到 `.local/tmp`）。
- 报告格式固定，避免整段日志：`task / exit / timings / result / problems`。

## 不能省的部分（诚实边界）

- 同一台机器的 CPU 与磁盘竞争：两个 74MB 原生库同时链接，并行不是 1+1。
- 串行依赖：代码没改完，测试与构建无从谈起；发版必须等构建结束。
- 每次委派本身有开销（启动、读提示、跑命令、写报告），短任务不划算。
- 判断时间（读代码、定位根因、决定改哪一行）无法外包，这部分是主要成本。

## 相关文件

- `D:\DeepseekHarness\Hongguo-video-pack\docs\dev-loop.md` — 各步骤实测耗时、改动分类、陷阱。
- `D:\DeepseekHarness\.tools\dev.ps1` — 唯一入口，任务：`env status check verify test win accept apk setup dist release`。
- `D:\DeepseekHarness\Hongguo-video-pack\scripts\run-local-acceptance.ps1` — 直跑 exe 做验收（处理 `%TEMP%` 与 CWD 问题）。
