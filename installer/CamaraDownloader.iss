; Instalador de Cámara Downloader (Inno Setup 6). Se compila con build.ps1.
#define AppName "Cámara Downloader"
#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif

[Setup]
AppId={{6F2B9E4C-3D7A-4C1E-9B8F-2A5D7E0C4B91}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher=ChrisAlf27
AppPublisherURL=https://github.com/ChrisAlf27/CamaraDownloader
AppUpdatesURL=https://github.com/ChrisAlf27/CamaraDownloader/releases
DefaultDirName={localappdata}\Programs\CamaraDownloader
DisableDirPage=yes
DisableProgramGroupPage=yes
DisableReadyPage=yes
PrivilegesRequired=lowest
OutputDir=..\dist
OutputBaseFilename=CamaraDownloader-Setup
SetupIconFile=..\assets\app.ico
UninstallDisplayIcon={app}\CamaraDownloader.exe
UninstallDisplayName={#AppName}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
VersionInfoVersion={#AppVersion}
VersionInfoProductName={#AppName}

[Languages]
Name: "es"; MessagesFile: "compiler:Languages\Spanish.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
Source: "..\build\CamaraDownloader.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\src\CamaraDownloader.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\assets\app.ico"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{autoprograms}\{#AppName}"; Filename: "{app}\CamaraDownloader.exe"; IconFilename: "{app}\app.ico"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\CamaraDownloader.exe"; IconFilename: "{app}\app.ico"; Tasks: desktopicon

[Run]
; En la instalacion normal es una casilla "Abrir"; en las actualizaciones (silenciosas) abre la app sola.
Filename: "{app}\CamaraDownloader.exe"; Description: "{cm:LaunchProgram,{#AppName}}"; Flags: nowait postinstall
