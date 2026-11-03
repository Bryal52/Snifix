; Windows installer for Snifix (built by .github/workflows/windows.yml)
#define AppVersion GetEnv("SNIFIX_VERSION")

[Setup]
AppId={{5B6E2A4C-7F1D-4E8B-9A3C-51F0D2C8B7A9}
AppName=Snifix
AppVersion={#AppVersion}
AppPublisher=Bryal52
DefaultDirName={autopf}\Snifix
DefaultGroupName=Snifix
DisableProgramGroupPage=yes
OutputDir=..\..\dist
OutputBaseFilename=Snifix-{#AppVersion}-Setup
SetupIconFile=..\Snifix.Windows\Assets\snifix.ico
UninstallDisplayIcon={app}\Snifix.exe
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
PrivilegesRequiredOverridesAllowed=dialog

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; Flags: unchecked

[Files]
Source: "..\..\dist\win\Snifix.exe"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{group}\Snifix"; Filename: "{app}\Snifix.exe"
Name: "{autodesktop}\Snifix"; Filename: "{app}\Snifix.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\Snifix.exe"; Description: "Launch Snifix"; Flags: nowait postinstall skipifsilent
