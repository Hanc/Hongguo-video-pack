# 自建分发服务对接说明（dl-server）

面向发布机的接口协议、参数与实测记录。分发服务零依赖，Node 18+ 直接跑，**不需要 npm install**。

## 1. 为什么安装包不走 COS 了

腾讯云 COS 的**默认域名禁止分发 APK/IPA**：

```
GET  https://<bucket>.cos.<region>.myqcloud.com/updates/android/x.apk
     → 403  <Code>DownloadForbidden</Code>
            The APK/IPA file is not allowed to be distributed in a public network
            using COS default domain, please use custom domain instead.
HEAD 同上  → 200（所以「HEAD 通了」不能当作可下载的凭据）
```

Windows 的 `.exe` 不受这条限制，仍可直连 COS。

因此分工是：

| 内容 | 存放 | 理由 |
|---|---|---|
| 安装包（`.apk` / `.exe`） | 自建服务器 | COS 默认域名下不了 APK |
| `updates/<platform>/latest.json` 清单 | 继续放 COS | 存量客户端只认 COS 地址，搬走会让老用户失联 |

## 2. 文件清单

| 文件 | 运行位置 | 作用 |
|---|---|---|
| `tooling/release/dl-server.mjs` | 服务器 | 分发服务：分片上传/续传、Range 下载、保留策略、限流 |
| `tooling/release/deploy-ubuntu.sh` | 服务器 | 一键部署（生成令牌、systemd、健康检查） |
| `tooling/release/nginx-dl.conf.example` | 服务器 | nginx 反代示例（宝塔用面板代替） |
| `tooling/release/selfcheck.sh` | 任意 | 上线自检 7 项 |
| `tooling/release/push-artifact.mjs` | 发布机 | 分片上传 + 续传 + 可达性验证 + JSON 输出 |
| `tooling/release/UPGRADE-NOTES.md` | 仓库 | 本文件 |

## 3. 服务端

```bash
DL_TOKEN=<令牌> node dl-server.mjs --root /var/www/hongguo/dl --port 8099 --host 127.0.0.1
```

| 参数 | 默认 | 说明 |
|---|---|---|
| `--root` | `./dl` | 静态根目录；下载 URL 与磁盘路径一一对应 |
| `--port` | `8099`（或 `DL_PORT`） | 监听端口 |
| `--host` | `0.0.0.0` | 反向代理场景建议 `127.0.0.1` |
| `--token` | （或 `DL_TOKEN`，**必填**） | 上传令牌；没配就拒绝启动 |
| `--max-mb` | `400` | 单包上限，超出直接 413 且不落盘 |
| `--keep` | `5` | 每个目录保留最近 N 个包 |
| `--rate` | `20` | 每分钟允许新建的会话数（续传不计入） |

### 3.1 接口

**`GET /health`** → `200 {"ok":true,"root":…,"sessions":…,"keep":…,"rate":…}`

**`POST /upload/session`**（需 `Authorization: Bearer <令牌>`）

```json
{"key":"updates/android/Hongputao-Android-arm64-0.11.1-2022760d.apk","size":78643200,"sha256":"<64 hex>"}
```

| 状态 | 含义 |
|---|---|
| `201` | 新会话：`{"ok":true,"sessionId":"…","offset":0,"resumed":false}`；磁盘上已有同 `key`+`size`+`sha256` 的 `.part` 时，`offset` 为已落盘字节数、`resumed:true`（**服务重启后依然有效**，元数据在同一目录的 `.part.meta` 里） |
| `200` | 该包已完整存在（或会话已在内存中），直接返回 `offset` |
| `401` | 令牌缺失/不匹配 |
| `413` | `size` 超过 `--max-mb`，不落盘 |
| `429` | 一分钟内新建会话过多，带 `retry-after: 60` |

响应顺序是 **413 先于令牌校验之后、限流之前**；续传（命中已有会话）不消耗限流额度。

**`PUT /upload/session/<sessionId>`**（需令牌）

必带 `Content-Range: bytes <start>-<end>/<total>` 与匹配的 `Content-Length`。

| 状态 | 含义 |
|---|---|
| `202` | 中间态：`{"ok":true,"offset":<下一个应传字节>}` |
| `200` | 完成：`{"ok":true,"key":…,"url":"/updates/android/x.apk","size":…,"sha256":…,"pruned":[…]}` |
| `400` | 头不合法 / `Content-Range` 总长与会话不符 / 拼装后的 sha256 与声明不一致（此时丢弃 `.part`） |
| `409` | 续传偏移不符：`{"ok":false,"error":"续传偏移不符","offset":<服务器已落盘字节>}`，客户端要按 `offset` 重新对齐 |
| `413` | 分片超出文件范围 |

分片语义只有一条：**从服务器当前 `offset` 开始按顺序追加**。乱序或跳传一律 409。服务端边收边算 sha256，完成时再与声明值比对，不一致就把半成品删掉。

**`GET /<key>`**（下载，无需令牌）

`206` Range、`304` ETag 复验、`403` 目录/根、`400` 点文件与异常路径、`415` 非法后缀（只放行 `.apk/.exe/.zip/.json`）。
`.json` 强制 `Cache-Control: no-store`；文件名里带 8 位以上哈希的包给 `immutable` 长缓存。

### 3.2 保留策略

按 mtime 从新到旧保留 `--keep` 个**安装包**，`latest.json` 等 `.json`、`.part`、`.part.meta` 永不参与清理。启动时及每 30 分钟清理一次 24 小时前的残留分片。

> 发布顺序必须是「先传包 → 再写清单」。若手工把清单指回更旧的包，那个包可能已经被 `--keep` 删掉；`selfcheck.sh` 第 7 项会当场发现。

## 4. 发布机：push-artifact.mjs

```bash
HONGGUO_UPLOAD_TOKEN=<令牌> node tooling/release/push-artifact.mjs <本地包> \
  --base https://dl.example.com --key updates/android/<文件名> [--dry-run] [--json]
```

| 参数 | 默认 | 说明 |
|---|---|---|
| `--key` | 必填 | 必须是 `updates/<平台>/<文件名>` |
| `--base` | 或 `HONGGUO_SERVER_BASE` | 服务器地址，**只接受 https** |
| `--token` | 或 `HONGGUO_UPLOAD_TOKEN` | 上传令牌 |
| `--chunk-mb` | `8` | 分片大小 |
| `--retries` | `3` | 网络错误/5xx 重试次数（409 不重试，按返回的 `offset` 重新对齐） |
| `--timeout-ms` | `600000` | 单次请求超时 |
| `--dry-run` | — | 只打印计划：文件、字节、sha256、分片数、目标地址；**不联网、不写清单** |
| `--json` | — | 末尾输出一行 JSON，供 `dev.ps1` / `publish-cos.mjs` 解析 |

`--json` 的字段（写进 COS 清单用）：

```json
{"ok":true,"url":"https://dl.example.com/updates/android/x.apk","key":"updates/android/x.apk",
 "size":78643200,"sha256":"<64 hex>","chunks":10,"uploadedChunks":10,"resumes":0,
 "elapsedMs":19876,"reachable":206}
```

上传完成后会自己发一次 `Range: bytes=0-0` 做**可达性验证**，必须回 `206`（或 `200`），否则报错退出——这一步才能抓到「清单写了但下不动」。

进度条只在终端（TTY）里画；重定向/CI 时 stderr 一个字节都不写，避免 PowerShell 5.1 把任意 stderr 输出包装成 `NativeCommandError` 看起来像失败。

## 5. 上线自检：selfcheck.sh

```bash
bash tooling/release/selfcheck.sh https://dl.example.com [安装包文件名]
SELFCHECK_LOCAL=1 bash tooling/release/selfcheck.sh http://127.0.0.1:8100   # 本机自测豁免第 1 项
```

7 项：HTTPS、`/health`、匿名下载、Range、ETag/304、防护（根目录/点文件/后缀）、清单与包一致。全绿退出 0，否则 1。

## 6. 实测记录（2026-10-29，Windows 11 + Node 24.15，本机回环）

| 项 | 结果 |
|---|---|
| `push-artifact.mjs --dry-run` | 300 KB / 1 分片 / `sha256 7db0323f…53fc` / 目标 `http://127.0.0.1:8100/updates/android/Probe-app-deadbeef.apk` |
| 真实上传 300 KB | 1 片，`elapsedMs=12`，可达性 `HTTP 206` |
| `selfcheck.sh`（`SELFCHECK_LOCAL=1`） | **7 项全绿**，退出 0（`content-range: bytes 0-99/307200`、`304（"4b000-1a18687fcab"）`） |
| 保留策略 | 连续传 7 个包（`--keep 5`）→ 只剩 `Package-0.0.3…07`，`latest.json` 保留 |
| 跨重启续传 | 3 MB / 1 MB 分片：阶段 a 落盘 `1048576` → **重启服务** → 阶段 b 建会话返回 `offset=1048576` → 续传完成，服务器回算 sha256 与本地一致（`9aeaa93…7695`） |
| 语法检查 | `bash -n` 三个脚本、`node --check` 两个客户端脚本均退出 0 |

未验证（需要真机域名/公网）：

- nginx 反代下的 `client_max_body_size`、`proxy_request_buffering off` 是否生效
- 真实 78 MB APK 经公网 SSL 的耗时与断点续传（本机只验到 3 MB / 300 KB）
- 手机端点击 http 服务 `latest.json` 里的 http 地址会被客户端拒绝（预期行为）

## 7. 发布机环境变量

| 变量 | 用途 |
|---|---|
| `HONGGUO_SERVER_BASE` | 分发服务器基址，必须 `https://` |
| `HONGGUO_UPLOAD_TOKEN` | 上传令牌（与服务器 `DL_TOKEN` 一致），只放发布机环境变量，**不进仓库、不进客户端** |

## 8. 故障对照

| 现象 | 原因 |
|---|---|
| 上传 401 | 令牌与服务器 `DL_TOKEN` 不一致 |
| 上传 413 | nginx `client_max_body_size` 或 `--max-mb` 太小 |
| 上传 502/504 | nginx 开了 `proxy_request_buffering`，或 `proxy_*_timeout` 太短 |
| 上传 429 | 触发 `--rate` 限流，等 60s；续传分片不计入 |
| 续传 409 | `.part` 长度与请求偏移不符，按响应里的 `nextOffset`/`offset` 对齐 |
| 清单能下但客户端说连不上 | 清单在 COS，`*.myqcloud.com` 被网络/代理拦了 |
| 客户端提示「必须是 https」 | `HONGGUO_SERVER_BASE` 写成了 http |
| 安装包校验失败 | 服务器文件被替换或截断，重传并核对清单 `sha256` |
