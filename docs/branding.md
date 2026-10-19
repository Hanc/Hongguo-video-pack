# 红葡萄图标

原始图案选自用户提供的方形 `logo1.png`。图案保持红色圆角底、白色葡萄/叶/梗；外部背景须透明。

透明母版：`assets/branding/logo-master.png`。运行 `python scripts/prepare-branding.py assets/branding/logo-master.png` 生成 Flutter 512 PNG、Windows 多尺寸 ICO 和 Android 启动图标。脚本拒绝完全不透明的母版，避免再次把白角带入任务栏。

2026-10-19 使用内置 image_gen 进行背景提取，之后仅做资源缩放/格式输出，未使用 CLI/API fallback。编辑提示：

> Edit target: the supplied existing app logo. Perform background extraction only. Make ONLY the white/off-white exterior pixels outside the red rounded-square badge transparent, including all four rounded corners. Preserve the entire existing red rounded-square badge, its exact shape, existing red color/shading, and ALL opaque white grape circles, white stem and white leaf inside it. Do not redesign, redraw, add text, add padding, change composition, or make the white grapes transparent. Output a square PNG with genuine RGBA transparency outside the rounded badge, badge tightly fit to canvas. This is an existing approved brand, not a logo variation.

各 ICO 尺寸均验证四角 Alpha 为 0，内部保留不透明白色像素；缩放时清理接近零 Alpha 的边缘噪点。Windows 升级时退出旧进程后再安装，以加载新的图标资源。

Windows 安装包通过 `installer/windows.iss` 的 `SetupIconFile` 复用同一个 `windows/runner/resources/app_icon.ico`，卸载列表通过 `UninstallDisplayIcon` 使用应用图标。自动发布在打包后检查安装程序 EXE 的实际图标透明度，检查通过后才继续交付。
