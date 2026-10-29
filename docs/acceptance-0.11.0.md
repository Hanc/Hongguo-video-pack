# 0.11.0 验收边界（应用内更新）

本轮新增：`关于与许可` 里的「检查更新」——读取对象存储上的清单、下载安装包、校验 SHA-256、交给系统安装器。

## 线上清单约定

固定路径只有两份，其余文件名带内容哈希，无法枚举猜出：

```
https://hongputao-1308285894.cos.ap-guangzhou.myqcloud.com/updates/windows/latest.json
https://hongputao-1308285894.cos.ap-guangzhou.myqcloud.com/updates/android/latest.json
```

字段（`lib/services/update_service.dart` 的 `UpdateInfo`）：

| 字段 | 说明 |
|---|---|
| `platform` | `windows` / `android`，必须与本机一致，否则整份清单判为不可用 |
| `version` / `versionCode` | 只按 `versionCode` 比较新旧 |
| `url` | 必须是 `https` |
| `size` / `sha256` | 下载完成后逐字节计算并比对 |
| `kind` | `exe` 或 `apk` |
| `notes` | 展示在更新弹窗里的条目 |

## 已实测（本机真实网络，非模拟）

1. `hongguo_studio.exe --update-check` → 读取线上 0.10.0 清单，输出 `"status": "current"`，退出码 0。
2. `hongguo_studio.exe --update-check --current-code=1` → 输出 `"status": "available"`，并带出 `latestVersion 0.10.0`、`size 81123393`、`sha256 79132142…`、真实 COS 地址。
   `--current-code=` 只用于验收时压低「当前版本」，正常使用不带这个参数。
3. `scripts/publish-cos.mjs probe` → 写入探测对象后按公有读回读 200，证明「可写 + 公有读」同时成立。
4. 上传后脚本会自动回读 `latest.json` 并核对 `sha256` 与本地一致。

## 单元测试覆盖（`test/update_service_test.dart`）

- 新版本 → `available`，并解析出 notes / size。
- 同 `versionCode` → `current`。
- 404 / 非 JSON / 平台不匹配 / `http://` 地址 → 明确失败原因（不会伪装成「已是最新」）。
- 下载：sha256 正确 → 落盘内容与源一致；sha256 错误 → 抛 `StateError` 且不留 `.part` 残留。

## 没有验证到的部分（诚实边界）

- **真实下载 81 MB 安装包再执行安装**：未做。下载与校验逻辑由单元测试覆盖；真实链路上只验证到「清单可读、地址可解析」。理由：在本机跑一次会真的弹出安装程序并改变系统状态，不适合放进自动化验收。
- **Android 端 `installApk` 通道**：只做了代码与清单/权限配置，未在真机上跑过（需要一台允许安装未知应用的设备）。
- **Windows 安装程序静默退出**：`Process.start` 拉起 `Setup.exe` 后本应用不等待、不退出；用户手动完成安装。升级安装会覆盖同目录文件，未测试「安装过程中应用仍在运行」的边界情况。
- **CDN 与防盗链**：本轮未接入，直连 COS 默认域名。

## 安全与费用约束（沿用本轮对话的结论）

- 存储桶权限：公有读、私有写。
- 凭据只存在 `.local/cos.json`（已 gitignore），不进入仓库、不进安装包。
- 建议上线前在 CAM 轮换一次密钥，并把账户余额控制在较小额度——被盗刷时的损失上限由余额决定，而不是由链接难度决定。
