; Instalador do Overclutch (Inno Setup 6).
; Compile com:  powershell -ExecutionPolicy Bypass -File build.ps1
; A versão vem de src\Core.ps1 e é passada pelo build.ps1 via /DAppVersion=...

#ifndef AppVersion
  #define AppVersion "1.0.0"
#endif
#define AppName "Overclutch"
#define AppId "Overclutch.App"

[Setup]
AppId={{6F3C2A1E-8B4D-4E7A-9C51-0D2E7B9A4F63}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher=Overclutch contributors
AppPublisherURL=https://github.com/freitasscaio/overclutch
AppSupportURL=https://github.com/freitasscaio/overclutch/issues
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
Source: "..\build\Overclutch.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\Overclutch.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\Iniciar.bat"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\Simular.bat"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\LICENSE"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\src\*"; DestDir: "{app}\src"; Flags: ignoreversion recursesubdirs
Source: "..\assets\overclutch.ico"; DestDir: "{app}\assets"; Flags: ignoreversion
Source: "..\assets\overclutch.png"; DestDir: "{app}\assets"; Flags: ignoreversion
Source: "..\assets\fonts\*"; DestDir: "{app}\assets\fonts"; Flags: ignoreversion

[InstallDelete]
Type: files; Name: "{app}\src\Games.ps1"

[Icons]
; AppUserModelID igual ao que o app define em src\UI.ps1: a barra de tarefas mostra o ícone do Overclutch.
Name: "{autoprograms}\{#AppName}"; Filename: "{app}\Overclutch.exe"; WorkingDir: "{app}"; AppUserModelID: "{#AppId}"
Name: "{autoprograms}\{cm:SimShortcut}"; Filename: "{app}\Overclutch.exe"; Parameters: "--simulate"; WorkingDir: "{app}"; AppUserModelID: "{#AppId}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\Overclutch.exe"; WorkingDir: "{app}"; AppUserModelID: "{#AppId}"; Tasks: desktopicon

[Run]
Filename: "{app}\Overclutch.exe"; WorkingDir: "{app}"; Description: "{cm:LaunchApp}"; Flags: postinstall nowait skipifsilent
; Atualização pelo próprio app (/SILENT /UPDATE=1): reabre o Overclutch no fim.
Filename: "{app}\Overclutch.exe"; WorkingDir: "{app}"; Flags: nowait; Check: IsUpdate

[Code]
function IsUpdate: Boolean;
begin
  Result := ExpandConstant('{param:UPDATE|0}') = '1';
end;

// Na atualização pelo app, dá tempo para a janela antiga fechar antes de copiar os arquivos.
function InitializeSetup: Boolean;
begin
  if IsUpdate then Sleep(3000);
  Result := True;
end;

function DataDir: String;
begin
  Result := ExpandConstant('{commonappdata}\Overclutch');
end;

// Antes de apagar os arquivos, oferece reverter as otimizações usando o próprio app.
procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  Code: Integer;
begin
  if CurUninstallStep <> usUninstall then Exit;
  if not FileExists(DataDir + '\backup.json') then Exit;
  if UninstallSilent then Exit;
  if MsgBox(CustomMessage('AskUndo'), mbConfirmation, MB_YESNO) <> IDYES then Exit;

  // O Overclutch.exe pede o UAC sozinho e espera o PowerShell terminar antes de devolver o código.
  if Exec(ExpandConstant('{app}\Overclutch.exe'), '--undo-all', ExpandConstant('{app}'), SW_HIDE, ewWaitUntilTerminated, Code) and (Code = 0) then
    DelTree(DataDir, True, True, True)
  else
    MsgBox(FmtMessage(CustomMessage('UndoFailed'), [DataDir]), mbError, MB_OK);
end;
