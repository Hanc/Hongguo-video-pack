; Compile with scripts/build-installer.ps1 after scripts/package.ps1.
#ifndef AppVersion
  #error AppVersion must be supplied by the build script
#endif
#ifndef PackageDir
  #error PackageDir must point to the verified Windows release folder
#endif
#ifndef OutputPath
  #error OutputPath must be supplied by the build script
#endif

[Setup]
AppId={{D728C724-5418-4D48-A1B9-EE87CFE48DB5}
AppName=红葡萄
AppVersion={#AppVersion}
AppVerName=红葡萄 {#AppVersion}
AppPublisher=Hongguo Studio
DefaultDirName={localappdata}\Programs\Hongguo Studio
DefaultGroupName=红葡萄
UsePreviousGroup=no
DisableProgramGroupPage=yes
DisableDirPage=no
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
OutputDir={#OutputPath}
OutputBaseFilename=Hongputao-Windows-{#AppVersion}-Setup
SetupIconFile=..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\hongguo_studio.exe
LicenseFile=..\LICENSE
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
CloseApplications=no
RestartApplications=no
SetupLogging=yes
UsePreviousAppDir=yes

[Languages]
Name: "chinesesimplified"; MessagesFile: "ChineseSimplified.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "创建桌面快捷方式"; Flags: unchecked

[Files]
Source: "{#PackageDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "InnoSetup-License.txt"; DestDir: "{app}\licenses"; DestName: "InnoSetup-LICENSE.txt"; Flags: ignoreversion

[InstallDelete]
Type: files; Name: "{userprograms}\红果工坊\红果工坊.lnk"
Type: files; Name: "{userprograms}\红果工坊\卸载红果工坊.lnk"
Type: files; Name: "{autodesktop}\红果工坊.lnk"

[Icons]
Name: "{group}\红葡萄"; Filename: "{app}\hongguo_studio.exe"; WorkingDir: "{app}"
Name: "{group}\卸载红葡萄"; Filename: "{uninstallexe}"
Name: "{autodesktop}\红葡萄"; Filename: "{app}\hongguo_studio.exe"; WorkingDir: "{app}"; Tasks: desktopicon

[Run]
Filename: "{app}\hongguo_studio.exe"; Description: "启动红葡萄"; Flags: nowait postinstall skipifsilent

; No UninstallDelete rule: settings, download caches and exported videos remain
; in the user's own data directories and are never removed by the uninstaller.
