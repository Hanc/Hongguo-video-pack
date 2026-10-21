# 夸克发布包备份

仅备份已经在 GitHub 发布的正式版，不上传应用运行数据、签名材料或视频。

目录：夸克根目录的 `releases/Hongguo-video-pack/v版本号/`（用户已确认父目录为根目录下的 releases）。每版五个文件：Windows Setup、Windows 便携 ZIP、Android arm64 APK、对应源码 ZIP、SHA256SUMS.txt。

## 首次接入

1. 在 LA 专用发布账号的私有目录安装并审核夸克官方 CLI，需要 Node.js；安装远程软件前取得用户确认。不要在公开工作流中执行登录或输出授权配置。
2. 由用户完成账号 OAuth 授权并选择目标文件夹；凭据只由官方 CLI 在节点私有目录维护，不进入 Git 仓库、Release 或 Actions 日志。
3. 配置 GitHub 仓库变量 QUARK_CLI_PATH（官方 quark-drive.cjs 绝对路径）与 QUARK_PARENT_FID（用户选定文件夹 FID）。先确认专用服务账号能够访问 CLI 与授权状态。
4. 配置 QUARK_BACKUP_ENABLED=true，手动运行 backup-quark.yml，先验证已有 v0.3.0。当前已在 LA 发布账号目录安装官方 CLI 1.0.25，复用 Runner 自带 Node.js，等待用户授权；未配置目标文件夹或启用自动备份。

工具参考：https://github.com/quark-clouddrive/quarkclouddrive_offical

## 执行及失败处理

- Release 创建成功后，夸克备份与 Gitee 镜像各自执行，不互相依赖。夸克失败时 GitHub 已发布文件保持可用，备份任务显示失败及警告；完整 workflow 可能因此呈失败状态。
- 备份前检查正式版标记、精确文件白名单和全部安装包 / 源码 SHA256；不扫描或上传整个项目目录。
- 只向用户指定父目录下创建项目 / 版本目录；版本目录确认空后才上传。已有任何文件则停止，避免覆盖或重复。部分成功后由用户核对网盘再决定修复，不自动删除云端文件。
- 成功条件为 CLI 确认五个文件上传成功，且完整目录清单数量为五。当前不把文件数量确认表述为云端字节 SHA256 校验；SHA256SUMS 留在网盘供恢复时核验。
- 授权过期时任务失败，私下重新授权后再处理；没有后台自动登录、Cookie 抓取或自动清理旧版本。
- 实际账号上传、授权续期、跨境吞吐和远程恢复校验均须首次接入后验收，当前仅代码及模拟测试。
- CLI 使用 Codex 集成身份识别授权配置；SSH 不会自动携带该标记，由调用进程显式传入 AI_AGENT=codex，不修改官方工具或跳过 OAuth。
- 发布包临时落盘，任务成功或失败后通过 always 清理下载目录；不长期保留版本包。进程强杀、主机宕机时 finally/always 无法保证执行，恢复后须定向检查清理。授权配置和运行工具保留。
- 首次配置已清理约 431 MB 旧工具安装缓存及失败镜像任务下载包；Runner 本身约 691 MB 常驻，夸克工具不足 1 MB，不把工具常驻占用说成零。
