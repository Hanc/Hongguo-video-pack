---
status: prohibited
kind: project-specification
updated_at: 2026-10-19
modules:
  - Windows 构建
  - 依赖管理
---

# 禁止未经审计恢复 Windows JVM 依赖

较新的文件选择 / Android 路径依赖曾引入 JNI 原生资产，Windows 的 `dartjni.dll` 依赖 `jvm.dll`，破坏目标电脑无需安装 Java 的独立运行要求。

当前稳定措施是固定 `file_picker: 10.3.10`，并覆盖 `path_provider_android: 2.2.22`。依据可在 `pubspec.yaml` 的依赖说明与 `scripts/package.ps1` 的 JNI 检查中核对。

- 不得为了消除版本提示而直接升级并恢复这条依赖链。
- 依赖升级必须检查 Windows 原生资产和 PE 依赖，并在无 Node / Flutter / FFmpeg / Java PATH 的环境验证安装后运行。
- 必须维持打包时对 `jni` 包的检查；历史增量产物可能残留 `dartjni.dll`，不得不经审计打入发行包。
- 不得要求最终用户安装完整开发环境来掩盖依赖回归。
