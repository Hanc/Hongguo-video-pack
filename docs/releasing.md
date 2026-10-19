# 自动构建与 GitHub Release

工作流：`.github/workflows/release.yml`。

- 推送与 pubspec 一致的版本标签，例如 `v0.3.0`：测试 → Android 正式签名构建 → Windows 构建/打包/安装卸载检查 → 创建 GitHub Release。
- 手动运行：默认只构建并保留 artifacts；仅在选择匹配的版本标签且显式勾选 `publish` 时发布 Release。分支运行不能发布，以免把不同提交的构建挂到旧标签上。
- 发包包含 Windows 安装器、备用便携 ZIP、arm64 APK、对应源码 ZIP、SHA256SUMS。测试或任一构建失败时不创建 Release。
- 只有发布 job 有 `contents: write`，其余 job 为只读。Release 已存在时创建失败，不静默覆盖既有正式版本。

## 首次配置

仓库需要四个 Actions secrets：`ANDROID_KEYSTORE_BASE64`、`ANDROID_STORE_PASSWORD`、`ANDROID_KEY_ALIAS`、`ANDROID_KEY_PASSWORD`。必须使用本项目原有发布签名，否则旧 APK 无法升级。

签名脚本只在 runner 临时目录还原 keystore，生成不提交的 `android/key.properties`，不会打印秘密，也不会打进源码包。缺少 Secrets 会明确失败，不改用调试签名伪装正式 APK。

源码首次提交和推送、签名 Secrets 配置完成后，才可在远端运行本工作流。当前本地打包成功不能代替 GitHub Actions 实际运行成功。用户确认安装包后，再提交代码和推版本标签；不为提前运行工作流而代替用户确认。
