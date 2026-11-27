#define AppName "Simple Live"
#define ReleasePageURL "https://github.com/Otiosum-coder/dart_simple_live/releases"
#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#ifndef AppSourceDir
  #error "AppSourceDir must be defined"
#endif
#ifndef OutputDir
  #define OutputDir "."
#endif

[Setup]
AppId={{8A681623-AE38-4D59-B9A0-101A1FB3C820}}
AppName={#AppName}
AppVersion={#AppVersion}
VersionInfoVersion={#AppVersion}
AppPublisher=Otiosum-coder
DefaultDirName={autopf}\Simple Live
DisableDirPage=no
DefaultGroupName=Simple Live
DisableProgramGroupPage=yes
UsePreviousAppDir=yes
UsePreviousTasks=yes
CloseApplications=yes
CloseApplicationsFilter=*.exe,*.dll,*.so
RestartApplications=no
PrivilegesRequired=admin
ArchitecturesAllowed=x64
ArchitecturesInstallIn64BitMode=x64
UninstallDisplayIcon={app}\simple_live_app.exe
OutputDir={#OutputDir}
OutputBaseFilename=SimpleLive-{#AppVersion}-windows-x64-setup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
SetupIconFile=..\runner\resources\app_icon.ico

[Languages]
Name: "chinesesimplified"; MessagesFile: "ChineseSimplified.isl"

[Tasks]
Name: "startmenuicon"; Description: "创建开始菜单快捷方式"; GroupDescription: "快捷方式:"
Name: "desktopicon"; Description: "创建桌面快捷方式"; GroupDescription: "快捷方式:"

[Files]
Source: "{#AppSourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[InstallDelete]
; Apply deselected shortcut tasks when upgrading an existing installation.
Type: files; Name: "{autoprograms}\Simple Live.lnk"; Tasks: not startmenuicon
Type: files; Name: "{autodesktop}\Simple Live.lnk"; Tasks: not desktopicon

[Icons]
Name: "{autoprograms}\Simple Live"; Filename: "{app}\simple_live_app.exe"; Tasks: startmenuicon
Name: "{autodesktop}\Simple Live"; Filename: "{app}\simple_live_app.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\simple_live_app.exe"; Description: "启动 Simple Live"; Flags: postinstall nowait skipifsilent runasoriginaluser
Filename: "{#ReleasePageURL}"; Description: "查看更新说明"; Flags: shellexec postinstall nowait skipifsilent runasoriginaluser unchecked

[Code]
function GetDowngradeMessage: String;
var
  UninstallKey: String;
  InstalledVersionText: String;
  InstalledVersion: Int64;
  InstallerVersion: Int64;
begin
  Result := '';
  { Keep this key identical to the existing x64, all-users install identity. }
  UninstallKey := 'Software\Microsoft\Windows\CurrentVersion\Uninstall\' +
    ExpandConstant('{#SetupSetting("AppId")}') + '_is1';
  if not RegQueryStringValue(HKLM64, UninstallKey, 'DisplayVersion',
    InstalledVersionText) then
    Exit;

  Log(Format('Detected installed version %s; installer version %s.', [InstalledVersionText, '{#AppVersion}']));
  if not StrToVersion(InstalledVersionText, InstalledVersion) then
  begin
    Log('Installed version is not numeric; skipping the downgrade comparison.');
    Exit;
  end;
  if not StrToVersion('{#AppVersion}', InstallerVersion) then
  begin
    Result := '无法识别当前安装程序的版本，请使用正式发布的安装程序。';
    Exit;
  end;

  if ComparePackedVersion(InstalledVersion, InstallerVersion) > 0 then
  begin
    Result := Format('已安装 Simple Live %s，当前安装程序版本为 %s。' + #13#10 +
      '为避免覆盖较新的版本，本次安装已停止。请使用相同或更新版本的安装程序。', [InstalledVersionText, '{#AppVersion}']);
    Log(Result);
  end;
end;

function InitializeSetup: Boolean;
var
  DowngradeMessage: String;
begin
  DowngradeMessage := GetDowngradeMessage;
  Result := DowngradeMessage = '';
  if not Result then
    SuppressibleMsgBox(DowngradeMessage, mbError, MB_OK, IDOK);
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  { Recheck in case another installation finished while this wizard was open. }
  Result := GetDowngradeMessage;
end;
