# 自建分发服务（安装包出站）

状态：落地中（服务端与发布脚本已在本机验证，等待用户真实服务器域名/令牌）。

## 约束（实测）

腾讯云对 COS 默认域名分发 APK/IPA 只堵 `GET`：

```
HTTP 403 <Code>DownloadForbidden</Code>
The APK/IPA file is not allowed to be distributed in a public network using COS default domain
```

`HEAD` 仍回 200，所以「上传 OK + HEAD 200」不能作为可下载的凭据。0.11.1 安卓包就是这样被挡住的（用户实测 `HttpException:下载失败:HTTP 403`）。

## 决定

- 安装包（`.apk` / `Setup.exe`）走用户自有服务器，`https://<域名>/updates/<平台>/<包名>-<sha 前 8 位>.<ext>`。
- `latest.json` **继续放 COS**：已装好的 0.11.x 客户端硬编码只能读 COS 清单，搬走会让存量用户失联；要搬必须先发一版双源客户端。
- 上传走服务端 `PUT /upload/<相对路径>` + Bearer 令牌；服务端边收边算 sha256 回传，发布脚本比对后才继续。

## 文件

- `server/dl-server.mjs`：零依赖（Node 18+）。静态 GET/HEAD（含 Range 206/416）+ 令牌上传 + 原子落盘（`.part` → rename）+ 路径守卫（拒 `..`、隐藏段、非 `.apk/.exe/.zip/.json`）+ `/health`。带哈希后缀的文件回 `immutable` 长缓存，清单 `no-cache`。
- `scripts/publish-cos.mjs`：新增 `--server-base` / `--skip-upload` / `--no-manifest` / `stage`，令牌从 `HONGGUO_UPLOAD_TOKEN` 读，地址从 `HONGGUO_SERVER_BASE` 读。上传前算 sha256，上传后比对服务端回值，再用 `GET Range: bytes=0-0` 验证匿名可达，最后才写清单。
- `docs/self-hosted-dist.md`：部署（systemd / nginx + certbot / Windows nssm）、自检三条命令、故障对照。

## 本机验证（已做）

`node server/dl-server.mjs --root .local/dltest --token testtoken123 --port 8099 --host 127.0.0.1` 后：

| 检查 | 结果 |
|---|---|
| 无令牌 PUT | 401 |
| 非白名单后缀（`.txt`） | 403 不接受的文件类型 |
| 编码穿越 `/upload/..%2F..%2Fevil.apk` | 403 路径不合法 |
| 隐藏文件 `/.env` | 403 路径不合法 |
| 根目录 `/` | 403（不可枚举） |
| 上传 75.0 MB APK | 201，服务端回算 sha256 与本地一致 |
| HEAD | 200 + `accept-ranges` |
| `Range: bytes=0-99` | 206，`content-range: bytes 0-99/78642682` |
| 完整下载 | 78642682 字节，sha256 与源文件一致 |
| 缺失文件 | 404 |
| `publish-cos.mjs push-android --server-base … --no-manifest` | 上传 → 校验 → 可达性检查全通过 |

未验证：用户真实服务器（TLS、nginx 缓冲、带宽）、Android 端从自建域名下载安装全链路。

## 陷阱

- 客户端只接受 `https` 下载地址（`lib/services/update_service.dart` 显式校验）；只有 http 需改代码，完整性靠 SHA-256 兜底。
- nginx 必须 `client_max_body_size 500m` 且 `proxy_request_buffering off`，否则 75–80 MB 的包会被 413 或超时打断。
- 服务端只监听 `127.0.0.1`，对外仅经 nginx，避免绕过 TLS。
- `[IO.File]` 在 PowerShell 里按进程 CWD 解析相对路径，改文件要么用绝对路径要么用编辑器工具。
