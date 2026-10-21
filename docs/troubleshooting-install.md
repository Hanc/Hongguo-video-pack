# Windows 安装问题排查

适用版本 0.7.3 及以后。安装包为 Inno Setup 构建，`PrivilegesRequired=lowest`，默认安装到 `%LOCALAPPDATA%\Programs\Hongguo Studio`，不需要管理员权限。

## 一、SmartScreen 拦截（"Windows 已保护你的电脑"）

这是**未签名应用**在 Windows 上的必然提示，与安装包内容无关：

- 双击 `Setup.exe` 后出现蓝色窗口，只有"不运行"一个按钮
- 点**更多信息**，右下角会出现**仍要运行**，点击即可继续

彻底消除此提示需要给安装包做**代码签名**（EV 证书可立即生效，普通 OV 证书需要积累下载声誉）。在拿到证书之前，这个提示无法从构建侧绕过。

## 二、安装程序无法创建目录 `%TEMP%\is-XXXX.tmp`（错误 5：拒绝访问）

### 现象

Inno Setup 在解压自身时会创建 `%TEMP%\is-XXXX.tmp`。若失败会弹出：

```
安装程序无法创建目录
"C:\Users\<用户>~1\AppData\Local\Temp\is-XXXX.tmp"。
错误 5: 拒绝访问。
```

### 根因

Inno 建目录时会**复制父目录的 DACL**。如果 `%TEMP%` 或其父目录的 ACL 里存在**无法解析的 SID**（例如已删除账户或沙箱容器用户的授权），复制 DACL 就会失败并报 `ERROR_ACCESS_DENIED (5)`，即使当前用户实际有写权限。

本项目曾因验收脚本使用 `icacls ... /grant ... /T` **递归**授权、且**没有撤销**，在 `%TEMP%` 与 `%AppData%` 上留下孤儿 SID，从而触发该错误。

### 自查

```powershell
# 列出 TEMP 上的显式（非继承）规则
(Get-Acl $env:TEMP).Access | Where-Object { -not $_.IsInherited } |
  Select-Object IdentityReference, FileSystemRights

# 模拟安装器行为，确认子项 ACL 中没有无法解析的 SID
$p = Join-Path $env:TEMP 'is-probe.tmp'
New-Item -ItemType Directory $p -Force | Out-Null
(Get-Acl $p).Access | ForEach-Object { $_.IdentityReference }
Remove-Item $p -Recurse -Force
```

第二条命令列出的身份应当是 `NT AUTHORITY\SYSTEM`、`BUILTIN\Administrators`、`<机器>\<用户>` 这类可读名称。若出现 `S-1-5-21-...` 形式的裸 SID，即为孤儿授权。

### 修复

移除 TEMP 上的显式孤儿规则（保留继承规则即可，用户自身已有完全控制）：

```powershell
$temp = $env:TEMP
$acl = Get-Acl $temp
foreach ($rule in @($acl.Access)) {
  if ($rule.IsInherited) { continue }
  $sid = $rule.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value
  if ($sid -like 'S-1-5-21-*') { $acl.RemoveAccessRule($rule) | Out-Null }
}
Set-Acl -Path $temp -AclObject $acl
```

同时清理失败的残留目录：

```powershell
Get-ChildItem $env:TEMP -Directory -Filter 'is-*.tmp' | Remove-Item -Recurse -Force
```

### 构建侧已做的修正

`.tools/test-real-playback.ps1` 原先用 `icacls /grant "HANC23\CodexSandboxUsers:(OI)(CI)M" /T`：

- `/T` 会**递归**应用到已有子项，污染面很大
- 脚本注释写了 "revoke after"，但**没有实际撤销步骤**

现改为：只授权顶层（`(OI)(CI)` 已覆盖新建子项）、`try/finally` 保证撤销。

## 三、安装前被占用

若目标目录里已有正在运行的程序，覆盖安装会失败：

```powershell
Get-Process hongguo_studio -ErrorAction SilentlyContinue | Stop-Process -Force
```

## 四、免安装替代

`dist/Hongputao-Windows-<版本>.zip` 是**便携版**，完全不经过安装器：

1. 解压到任意目录（例如 `D:\红葡萄`）
2. 直接运行 `hongguo_studio.exe`

便携版与安装版功能一致，区别只是没有开始菜单与桌面快捷方式。若安装器持续失败，可先用它，不影响使用。
