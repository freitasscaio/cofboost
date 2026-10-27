; Instalador do Overclutch (Inno Setup 6).
; Compile com:  powershell -ExecutionPolicy Bypass -File build.ps1
; A versão vem de src\Core.ps1 e é passada pelo build.ps1 via /DAppVersion=...

#ifndef AppVersion
  #define AppVersion "1.0.0"
#endif
#define AppName "Overclutch"
#define PsArgs "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File"

[Setup]
AppId={{6F3C2A1E-8B4D-4E7A-9C51-0D2E7B9A4F63}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher=Overclutch contributors
AppPublisherURL=https://github.com/SEU-USUARIO/overclutch
AppSupportURL=https://github.com/SEU-USUARIO/overclutch/issues
; Instala só para o usuário atual: não pede administrador para instalar.
; O próprio app pede permissão (UAC) quando vai otimizar.
PrivilegesRequired=lowest
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
LicenseFile=..\LICENSE
SetupIconFile=..\assets\overclutch.ico
UninstallDisplayIcon={app}\assets\overclutch.ico
UninstallDisplayName={#AppName}
OutputDir=..\dist
OutputBaseFilename=Overclutch-Setup
WizardStyle=modern
Compression=lzma2
SolidCompression=yes
MinVersion=10.0
ArchitecturesAllowed=x64compatible

[Languages]
Name: "pt"; MessagesFile: "compiler:Languages\BrazilianPortuguese.isl"
Name: "en"; MessagesFile: "compiler:Default.isl"

[CustomMessages]
pt.DesktopIcon=Criar atalho na Área de Trabalho
pt.SimShortcut=Overclutch (modo simulação)
pt.LaunchApp=Abrir o Overclutch agora
pt.AskUndo=Você quer reverter as otimizações do Overclutch antes de desinstalar?%n%nSim: o Windows volta às configurações originais (vai pedir permissão de administrador).%nNão: as otimizações continuam ativas no PC.
pt.UndoFailed=Algumas otimizações não puderam ser revertidas. O backup foi mantido em %1 para você tentar de novo.
en.DesktopIcon=Create a desktop shortcut
en.SimShortcut=Overclutch (simulation mode)
en.LaunchApp=Open Overclutch now
en.AskUndo=Do you want to revert Overclutch's optimizations before uninstalling?%n%nYes: Windows goes back to its original settings (asks for administrator permission).%nNo: the optimizations stay active.
en.UndoFailed=Some optimizations could not be reverted. The backup was kept in %1 so you can try again.

[Tasks]
Name: "desktopicon"; Description: "{cm:DesktopIcon}"

[Files]
Source: "..\Overclutch.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\Iniciar.bat"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\Simular.bat"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\LICENSE"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\src\*"; DestDir: "{app}\src"; Flags: ignoreversion recursesubdirs
Source: "..\assets\overclutch.ico"; DestDir: "{app}\assets"; Flags: ignoreversion

[Icons]
Name: "{autoprograms}\{#AppName}"; Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "{#PsArgs} ""{app}\Overclutch.ps1"""; WorkingDir: "{app}"; IconFilename: "{app}\assets\overclutch.ico"
Name: "{autoprograms}\{cm:SimShortcut}"; Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "{#PsArgs} ""{app}\Overclutch.ps1"" -DryRun"; WorkingDir: "{app}"; IconFilename: "{app}\assets\overclutch.ico"
Name: "{autodesktop}\{#AppName}"; Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "{#PsArgs} ""{app}\Overclutch.ps1"""; WorkingDir: "{app}"; IconFilename: "{app}\assets\overclutch.ico"; Tasks: desktopicon

[Run]
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "{#PsArgs} ""{app}\Overclutch.ps1"""; WorkingDir: "{app}"; Description: "{cm:LaunchApp}"; Flags: postinstall nowait skipifsilent

[Code]
function DataDir: String;
begin
  Result := ExpandConstant('{commonappdata}\Overclutch');
end;

// Antes de apagar os arquivos, oferece reverter as otimizações usando o próprio app.
procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  Code: Integer;
  Params: String;
begin
  if CurUninstallStep <> usUninstall then Exit;
  if not FileExists(DataDir + '\backup.json') then Exit;
  if UninstallSilent then Exit;
  if MsgBox(CustomMessage('AskUndo'), mbConfirmation, MB_YESNO) <> IDYES then Exit;

  Params := '{#PsArgs} "' + ExpandConstant('{app}\Overclutch.ps1') + '" -UndoAll';
  // runas: o Windows mostra o UAC; ewWaitUntilTerminated: espera reverter antes de remover os arquivos.
  if ShellExec('runas', ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'), Params, '', SW_HIDE, ewWaitUntilTerminated, Code) and (Code = 0) then
    DelTree(DataDir, True, True, True)
  else
    MsgBox(FmtMessage(CustomMessage('UndoFailed'), [DataDir]), mbError, MB_OK);
end;
