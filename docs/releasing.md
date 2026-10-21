# 自动构建与 GitHub Release

## Gitee 国内镜像

仓库变量 `GITEE_REPOSITORY=adoin/Hongguo-video-pack`，Secret 名称 `GITEE_ACCESS`（不要把令牌写入源码或聊天）。

- `sync-gitee.yml`：GitHub main 或 v* 标签推送后同步 main 与全部标签，不强制覆盖分叉。
- `release.yml`：GitHub 构建/安装验证/发布成功后调用 `mirror-gitee.yml`，同步相同安装包到 Gitee。也可手动运行镜像工作流，输入已存在的正式 Tag，补同步旧版。
- 镜像发布先标记预发布，依次上传 Windows 安装器、arm64 APK、源码和 SHA256SUMS，并以免登录下载验证 SHA256。全部通过才转正式版。便携 ZIP 保留在 GitHub，避免超过镜像附件预算。
- 应用内优先检查 Gitee 就绪正式版，国内源失败时回退 GitHub，不需要给终端用户配置任何令牌。

工作流：`.github/workflows/release.yml`。

- 推送与 pubspec 一致的版本标签，例如 `v0.3.0`：测试 → Android 正式签名构建 → Windows 构建/打包/安装卸载检查 → 创建 GitHub Release。
- 手动运行：默认只构建并保留 artifacts；仅在选择匹配的版本标签且显式勾选 `publish` 时发布 Release。分支运行不能发布，以免把不同提交的构建挂到旧标签上。
- 发包包含 Windows 安装器、备用便携 ZIP、arm64 APK、对应源码 ZIP、SHA256SUMS。测试或任一构建失败时不创建 Release。
- 只有发布 job 有 `contents: write`，其余 job 为只读。Release 已存在时创建失败，不静默覆盖既有正式版本。

## 首次配置

仓库需要四个 Actions secrets：`ANDROID_KEYSTORE_BASE64`、`ANDROID_STORE_PASSWORD`、`ANDROID_KEY_ALIAS`、`ANDROID_KEY_PASSWORD`。必须使用本项目原有发布签名，否则旧 APK 无法升级。

签名脚本只在 runner 临时目录还原 keystore，生成不提交的 `android/key.properties`，不会打印秘密，也不会打进源码包。缺少 Secrets 会明确失败，不改用调试签名伪装正式 APK。

源码首次提交和推送、签名 Secrets 配置完成后，才可在远端运行本工作流。当前本地打包成功不能代替 GitHub Actions 实际运行成功。用户确认安装包后，再提交代码和推版本标签；不为提前运行工作流而代替用户确认。
