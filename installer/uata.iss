; Inno Setup script — Universal AI Trading Assistant (Windows installer)
; Built by scripts/build_windows.ps1 -Installer. Per-user install: no administrator rights needed.
; Your data lives in %LOCALAPPDATA%\UniversalAITradingAssistant and is NOT removed on uninstall
; (delete it from Settings → "Delete all my data" before uninstalling if you want it gone).

#ifndef AppVersion
  #define AppVersion "0.1.0"
#endif
#ifndef SourceDir
  #define SourceDir "..\app\build\windows\x64\runner\Release"
#endif

[Setup]
AppId={{6C9B1D2E-4F3A-4E8B-9C21-7A5D3E2F1B90}
AppName=UATA - AI Trading Assistant
AppVersion={#AppVersion}
AppPublisher=UATA (local, private)
DefaultDirName={localappdata}\Programs\UATA
DefaultGroupName=UATA
PrivilegesRequired=lowest
OutputDir=..\dist
OutputBaseFilename=UATA-Setup-{#AppVersion}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
UninstallDisplayIcon={app}\uata_app.exe
DisableProgramGroupPage=yes

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
; the Flutter app, its DLLs and data/, the bundled engine (engine\uata-engine.exe) and Tesseract (tesseract\)
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\UATA - AI Trading Assistant"; Filename: "{app}\uata_app.exe"
Name: "{autodesktop}\UATA - AI Trading Assistant"; Filename: "{app}\uata_app.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\uata_app.exe"; Description: "{cm:LaunchProgram,UATA}"; Flags: nowait postinstall skipifsilent

[UninstallRun]
; stop a running engine so its files can be removed (data in %LOCALAPPDATA% is kept)
Filename: "{sys}\taskkill.exe"; Parameters: "/F /IM uata-engine.exe"; Flags: runhidden; RunOnceId: "StopEngine"
