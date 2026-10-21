---
status: active
kind: project-specification
updated_at: 2026-10-21
modules: [自动更新, GitHub Release, Gitee 镜像]
---

# 正式版更新与国内镜像

用户要求：

> 然后得加一下自动更新功能，拉取github release进行比较（只比较正式版版号 beta alpha rc等不管）
> 保留 GitHub 构建，增加国内镜像（推荐）
> https://gitee.com/adoin/Hongguo-video-pack 导入好了 我还需要给提供什么吗
> 建了 叫GITEE_ACCESS
> action里面代码自动同步gitee release自动同步gitee，能做到吗

- 启动自动检查，“关于”提供手动检查。版本来自已安装包的 PackageInfo，不使用容易遗漏的手写版本常量。
- GitHub 为构建来源，Gitee 为国内镜像。Gitee 有就绪正式版时使用国内检查结果，包含“无需更新”的情形，不强制依赖 GitHub 可达；国内无就绪版本/请求失败或下载失败时回退 GitHub。无登录、无内置私人令牌，不使用第三方公共代理。
- 只识别可选 v/V 前缀的三段正式版本号；跳过 draft / prerelease 标记及 beta、alpha、rc、构建元数据等后缀。按整数比较而非字符串，不降级。
- Windows 选 Setup.exe，Android 选 arm64 APK。下载中可取消；网络失败、尺寸异常、SHA256 不匹配都不执行；安装前再次校验。
- 安装需用户点击和系统安装向导确认。拼接任务或素材加载未完成时不安装。Windows 保存状态后启动安装器退出；Android 只共享应用 `data/updates/` 内 APK，包名须相同，未知来源授权交给系统。
- `.github/workflows/sync-gitee.yml` 在 main / v* Tag 更新后同步 main 与标签，不 force push；Gitee 分叉需显式处理。
- GitHub Release 成功后调用 `mirror-gitee.yml`，支持手动补同步旧正式版。GITEE_ACCESS 只在 Actions Secret 使用。镜像上传 Setup、APK、源码及 SHA256SUMS；便携 ZIP 留在 GitHub。
- 镜像先标记 prerelease，附件上传后必须验证无需登录可下载及 SHA256，全部通过才转正式版，避免客户端获取半成品。
- 用户验收前保持 active；构建、模拟更新、真实镜像同步和手机系统安装应分别报告。

## LA 镜像发布节点

- 用户已批准常驻 LA 节点，以及安装 `libicu78`。仓库专用 Runner 名称 / 标签为 `hongputao-gitee-publisher`，以独立普通账号运行，不开放入站发布端口。
- 节点只负责下载 GitHub 已构建的发布包、校验并上传 Gitee，不承担 Windows / Android 构建。其他仓库接入需要分别注册 Runner 和配置发布权限。
- Ubuntu 26.04 上启用 `RestrictSUIDSGID` 时，Runner 解压 checkout Action 报 `Function not implemented`；用户批准后仅关闭此项，同一任务解压及检出成功。保留 NoNewPrivileges、空 capabilities、ProtectSystem 和专用目录写入限制。
- Runner 会重建工具 PATH；工作流通过 GITHUB_PATH 加入专用工具目录。Python 优先使用节点现有 python3，不要求全局 python 别名。
- 正式版同步实际通过后，再将仓库变量 `GITEE_MIRROR_RUNNER` 设为 `publisher`；此前只手动验证已有 v0.3.0，不创建新 Tag。
- 节点已通过 Action 解压、源码检出和已有安装包下载；2026-10-21 验证仍受 Gitee Release API 响应阻塞，独立 20 秒探测未收到响应。不能据此宣称镜像上传已通过或更新源已就绪。
- 源码同步仅由 sync-gitee 工作流执行，附件镜像不再重复推 main，避免下载期间 main 已更新造成非快进冲突。

## 夸克发布包备份

- 用户明确备份对象为发布包。GitHub 正式版发布后可独立备份到用户指定夸克文件夹下的项目 / 版本目录，包含 Windows 安装包、便携 ZIP、APK、源码和校验文件。
- 用户已确认目标父目录为夸克根目录下的 `releases`；最终路径为 `releases/Hongguo-video-pack/v版本号/`，授权后定位其真实 FID，不将网盘根目录 FID 当作 releases 的 FID。
- 备份与 Gitee 镜像独立；失败单独报告，不撤销 GitHub 已发布版本。首次必须完成私下授权及目标文件夹确认，未就绪前保持关闭。
- 实施入口、变量与验收边界见 `docs/quark-release-backup.md`。当前只有流程代码和模拟验证，不宣称网盘已接通。
