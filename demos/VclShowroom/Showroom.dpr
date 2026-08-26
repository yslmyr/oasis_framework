program Showroom;

(* Oasis Showroom - one VCL app showcasing every Cordis architecture advantage.
   Build like VclHostDemo: dcc32 -B -NSWinapi;System;System.Win;Vcl;System.Classes
   -LUrtl,vcl (see build.cmd).
   Run: Showroom.exe            interactive
        Showroom.exe /selftest  headless end-to-end verification, writes
                                vclshowroom_selftest.txt next to the EXE *)

uses
  Vcl.Forms,
  System.SysUtils, System.Classes, System.IOUtils,
  Oasis.Types in '..\..\src\Oasis.Core\Oasis.Types.pas',
  Oasis.Errors in '..\..\src\Oasis.Core\Oasis.Errors.pas',
  Oasis.Spin in '..\..\src\Oasis.Core\Oasis.Spin.pas',
  Oasis.Effects in '..\..\src\Oasis.Core\Oasis.Effects.pas',
  Oasis.Services in '..\..\src\Oasis.Core\Oasis.Services.pas',
  Oasis.Events in '..\..\src\Oasis.Core\Oasis.Events.pas',
  Oasis.Context in '..\..\src\Oasis.Core\Oasis.Context.pas',
  Oasis.Plugin in '..\..\src\Oasis.Core\Oasis.Plugin.pas',
  Oasis.UI in '..\..\src\Oasis.UI\Oasis.UI.pas',
  Oasis.Loader in '..\..\src\Oasis.Hosting\Oasis.Loader.pas',
  Oasis.Host in '..\..\src\Oasis.Hosting\Oasis.Host.pas',
  Oasis.Config in '..\..\src\Oasis.Hosting\Oasis.Config.pas',
  ShowroomPlugins in 'ShowroomPlugins.pas',
  ShowroomUi in 'ShowroomUi.pas';

var
  LForm: TShowroomForm;
  LReport: string;
begin
  Application.Initialize;
  Application.MainFormOnTaskbar := True;
  LReport := ExtractFilePath(Application.ExeName) + 'vclshowroom_selftest.txt';
  if FindCmdLineSwitch('selftest', True) then
  begin
    { headless: never allow a modal error dialog to hang the run }
    try
      Application.CreateForm(TShowroomForm, LForm);
      LForm.RunSelfTest(LReport);
      if GSelfTestFailures = 0 then Halt(0) else Halt(2);
    except
      on E: Exception do
      begin
        TFile.WriteAllText(LReport,
          'EXCEPTION during init/selftest: ' + E.ClassName + ': ' + E.Message + #13#10 +
          E.StackTrace);
        Halt(3);
      end;
    end;
  end;
  Application.CreateForm(TShowroomForm, LForm);
  Application.Run;
end.
