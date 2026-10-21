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
- GitHub 为构建来源，Gitee 为国内镜像。Gitee 就绪正式版高于本地时优先使用，否则检查 GitHub；国内下载失败也回退 GitHub。无登录、无内置私人令牌，不使用第三方公共代理。
- 只识别可选 v/V 前缀的三段正式版本号；跳过 draft / prerelease 标记及 beta、alpha、rc、构建元数据等后缀。按整数比较而非字符串，不降级。
- Windows 选 Setup.exe，Android 选 arm64 APK。下载中可取消；网络失败、尺寸异常、SHA256 不匹配都不执行；安装前再次校验。
- 安装需用户点击和系统安装向导确认。拼接任务或素材加载未完成时不安装。Windows 保存状态后启动安装器退出；Android 只共享应用 `data/updates/` 内 APK，包名须相同，未知来源授权交给系统。
- `.github/workflows/sync-gitee.yml` 在 main / v* Tag 更新后同步 main 与标签，不 force push；Gitee 分叉需显式处理。
- GitHub Release 成功后调用 `mirror-gitee.yml`，支持手动补同步旧正式版。GITEE_ACCESS 只在 Actions Secret 使用。镜像上传 Setup、APK、源码及 SHA256SUMS；便携 ZIP 留在 GitHub。
- 镜像先标记 prerelease，附件上传后必须验证无需登录可下载及 SHA256，全部通过才转正式版，避免客户端获取半成品。
- 用户验收前保持 active；构建、模拟更新、真实镜像同步和手机系统安装应分别报告。
