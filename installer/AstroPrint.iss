; AstroPrint-Setup.exe: copia los scripts a Program Files\AstroPrint y corre install.ps1
; -Unattended (sin consola). La impresora se elige despues en Astrobit, Configuracion > Impresora.
; La version llega en ASTROPRINT_VERSION, la de agent.ps1 (la pone el workflow).
#define AppVersion GetEnv("ASTROPRINT_VERSION")

[Setup]
AppId={{2F1C7E0B-6C4D-4B8E-9E52-7A1D3B8F0C61}
AppName=AstroPrint
AppVersion={#AppVersion}
AppVerName=AstroPrint {#AppVersion}
AppPublisher=Astrobit
AppPublisherURL=https://www.astrobit.cl
AppSupportURL=https://github.com/astrobitspa/astroprint
DefaultDirName={autopf}\AstroPrint
DisableDirPage=yes
DisableProgramGroupPage=yes
DisableWelcomePage=no
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir=..\dist
OutputBaseFilename=AstroPrint-Setup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
UninstallDisplayName=AstroPrint
CloseApplications=no

[Languages]
Name: "es"; MessagesFile: "compiler:Languages\Spanish.isl"

[Messages]
WelcomeLabel2=AstroPrint imprime las etiquetas de Astrobit en tu impresora de etiquetas: Zebra, Xprinter y otras que entienden ZPL.%n%nReemplaza a Zebra Browser Print en este computador; si está abierto, se cierra.
FinishedLabel=AstroPrint quedó funcionando.%n%nCierra y vuelve a abrir el navegador, y entra a Astrobit › Configuración › Impresora para elegir la impresora y probarla.

[Tasks]
Name: "keepawake"; Description: "Evitar que este computador se suspenda enchufado (en bodega: suspendido no imprime)"

[Files]
Source: "..\AstroPrint\*"; DestDir: "{app}"; Flags: ignoreversion

[UninstallRun]
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File ""{app}\uninstall.ps1"""; Flags: runhidden waituntilterminated; RunOnceId: "AstroPrintUninstall"

[UninstallDelete]
Type: filesandordirs; Name: "{commonappdata}\AstroPrint"

[Code]
// install.ps1 deja el agente andando y espera hasta 3 minutos a que responda. Si falla, el
// detalle queda en install.log: el asistente no termina diciendo que todo salió bien.
procedure CurStepChanged(CurStep: TSetupStep);
var
  Params: String;
  ResultCode: Integer;
begin
  if CurStep <> ssPostInstall then Exit;
  WizardForm.StatusLabel.Caption := 'Arrancando AstroPrint (puede tardar hasta 3 minutos)...';
  Params := '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' +
    ExpandConstant('{app}\install.ps1') + '" -Unattended -KeepAwake ';
  if WizardIsTaskSelected('keepawake') then Params := Params + 'S' else Params := Params + 'N';
  if not Exec(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'), Params, '',
    SW_HIDE, ewWaitUntilTerminated, ResultCode) or (ResultCode <> 0) then
    MsgBox('AstroPrint no quedó funcionando. El detalle está en ' +
      ExpandConstant('{commonappdata}\AstroPrint\install.log') + '.', mbError, MB_OK);
end;
