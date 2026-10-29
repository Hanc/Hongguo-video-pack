# 自建分发服务（安装包走自己的服务器）

目标：**一条命令发完**——构建产物直传你的服务器，校验通过后改写 `latest.json`，Android 点「检查更新」就能下到新包。

## 为什么安装包不能留在 COS

腾讯云对默认域名 `*.cos.<region>.myqcloud.com` 分发 **APK/IPA** 有硬限制：

```
HTTP 403  <Code>DownloadForbidden</Code>
The APK/IPA file is not allowed to be distributed in a public network using COS default domain
```

只堵 `GET`，`HEAD` 仍回 200——所以「上传成功 + HEAD 200」不代表能下载。实测 0.11.1 的安卓包就是这样被挡住的。

两条出路：

| 做法 | 需要 | 评价 |
|---|---|---|
| COS 绑自定义域名（备案） | 已备案域名 + 证书 + 备案审核 | 也能用，但多一道审核 |
| **自己的服务器出安装包**（本文） | 一台有 80/443 的机器 | 推荐：立刻可用，流量自己控 |

`latest.json` 继续放 COS：**已装好的 0.11.x 客户端只知道 COS 地址**，把清单搬走会让所有存量用户失联（要搬就得先发一版客户端）。

## 部署（Linux）

服务器要 Node 18+，不需要任何 npm 依赖。

```bash
# 1) 放文件
sudo mkdir -p /opt/hongguo /var/www/hongguo/dl
sudo cp dl-server.mjs /opt/hongguo/

# 2) 生成上传令牌（只给发布脚本用，不要写进客户端）
TOKEN=$(head -c 32 /dev/urandom | base64 | tr -d '/+=' | head -c 40)
echo "$TOKEN"    # 记下来，稍后填进本地环境变量
sudo tee /etc/hongguo.env >/dev/null <<EOF
DL_TOKEN=$TOKEN
EOF
sudo chmod 600 /etc/hongguo.env

# 3) systemd
sudo tee /etc/systemd/system/hongguo-dl.service >/dev/null <<'EOF'
[Unit]
Description=Hongputao artifact server
After=network.target

[Service]
EnvironmentFile=/etc/hongguo.env
ExecStart=/usr/bin/node /opt/hongguo/dl-server.mjs --root /var/www/hongguo/dl --port 8099 --host 127.0.0.1 --max-mb 400
Restart=always
RestartSec=3
User=www-data
Group=www-data

[Install]
WantedBy=multi-user.target
EOF

sudo mkdir -p /var/www/hongguo/dl && sudo chown -R www-data:www-data /var/www/hongguo/dl
sudo systemctl daemon-reload && sudo systemctl enable --now hongguo-dl
curl -s http://127.0.0.1:8099/health    # {"ok":true,"files":1}
```

`--host 127.0.0.1` 是有意的：服务只监听本机，对外只经 nginx，避免绕过 TLS。

## nginx 反向代理 + 证书

```nginx
server {
    listen 80;
    server_name dl.example.com;
    location /.well-known/acme-challenge/ { root /var/www/html; }
    location / { return 301 https://$host$request_uri; }
}

server {
    listen 443 ssl http2;
    server_name dl.example.com;

    ssl_certificate     /etc/letsencrypt/live/dl.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/dl.example.com/privkey.pem;

    # 安装包 75~80 MB，放宽请求体上限，否则上传会被 nginx 挡成 413
    client_max_body_size 500m;
    client_body_timeout  300s;

    location / {
        proxy_pass         http://127.0.0.1:8099;
        proxy_http_version 1.1;
        proxy_set_header   Host $host;
        proxy_set_header   X-Forwarded-For $remote_addr;
        proxy_request_buffering off;   # 大文件边收边写，不占内存
        proxy_read_timeout  600s;
        proxy_send_timeout  600s;
    }
}
```

```bash
sudo certbot --nginx -d dl.example.com    # 证书 + 自动续期
```

应用只接受 `https://` 下载地址（`lib/services/update_service.dart` 里显式校验），所以这一步不能省。若确实只有 http，需要改客户端校验——完整性仍由 SHA-256 保证，但传输是明文。

## 本地发布

一次性配置（只写在你自己的机器，别提交）：

```powershell
# 当前会话
$env:HONGGUO_SERVER_BASE  = 'https://dl.example.com'
$env:HONGGUO_UPLOAD_TOKEN = '<上面生成的 TOKEN>'

# 想长期生效
setx HONGGUO_SERVER_BASE  'https://dl.example.com'
setx HONGGUO_UPLOAD_TOKEN '<上面生成的 TOKEN>'
```

然后：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File D:\DeepseekHarness\.tools\dev.ps1 release -Notes "修好了什么"
```

`release` 顺序：`apk` ∥ `win` → `dist` → `setup` → 校验和 → `publish-cos.mjs release`。发布那步会：

1. 算本地 SHA-256，拼出远端名 `updates/<平台>/<包名>-<哈希前8位>.<ext>`；
2. `PUT https://dl.example.com/upload/updates/…`，服务端边写边算哈希并回传比对（不一致直接中止）；
3. 真实 `GET Range: bytes=0-0` 验证匿名可下载；
4. 写 `updates/<平台>/latest.json` 到 COS，回读比对；
5. 打印最终地址。

只发一端、或手动传了包只改清单：

```powershell
node scripts/publish-cos.mjs push-android dist\Hongputao-Android-arm64-0.11.1.apk --notes "手动传包"
node scripts/publish-cos.mjs push-android <apk> --skip-upload   # 包已自己传好
node scripts/publish-cos.mjs release --no-manifest               # 只演练上传与可达性
```

## 上线后自检（三条命令）

```bash
curl -sI https://dl.example.com/updates/android/latest.json | head -1          # 200
curl -s  https://dl.example.com/updates/android/latest.json | head -20         # 清单 JSON
curl -s -o /dev/null -w '%{http_code}\n' -r 0-99 https://dl.example.com/updates/android/<包名>.apk   # 206
```

Android 上打开应用 → 版本号/关于 → 检查更新，应显示新版本并能下载安装。

## Windows Server 备选

没有 Linux 时用 nssm 把同一个脚本注册成服务：

```powershell
nssm install HongguoTarget "C:\Program Files\nodejs\node.exe" `
  "C:\hongguo\dl-server.mjs --root D:\hongguo\dl --port 8099 --host 127.0.0.1 --max-mb 400"
nssm set HongguoTarget AppEnvironmentExtra DL_TOKEN=<你的令牌>
nssm start HongguoTarget
```

对外仍需 IIS/nginx 反代并配证书；Windows 防火墙只开 80/443，不要放 8099。

## 故障对照

| 现象 | 原因 |
|---|---|
| 上传 `401 令牌不正确` | `HONGGUO_UPLOAD_TOKEN` 与服务器 `--token`/`DL_TOKEN` 不一致 |
| 上传 `413` | nginx `client_max_body_size` 太小，或服务端 `--max-mb` 太小 |
| 上传被 nginx 回 `502/504` | `proxy_request_buffering on` + 大包超时；关掉缓冲并放宽 `proxy_*_timeout` |
| 清单写入成功但应用「无法连接」 | 清单在 COS，连接的是 `*.myqcloud.com`；查客户端网络/代理，不是服务器问题 |
| 应用提示「更新地址必须是 https」 | `HONGGUO_SERVER_BASE` 写成了 http |
| 应用提示「安装包校验失败」 | 服务器上的文件被替换/截断；重传，或核对清单里的 `sha256` |
| 下载很慢 | 单 AZ + 小带宽；换带宽更大的机器或加 CDN（安装包文件名带哈希，可长缓存） |

## 安全边界

- 上传接口必须带令牌，令牌只在服务端环境变量与发布机器上出现，**不进客户端**；
- 目录不可枚举（`/` 返回 403），文件名带内容哈希，猜不到；
- 只接受 `.apk/.exe/.zip/.json`，拒绝隐藏文件与 `..` 路径穿越；
- 应用下载后逐字节校验 SHA-256，且要求签名一致，改包即装不上；
- 装机量上来后建议给 COS 账单加预算告警、给服务器流量设月度阈值。
