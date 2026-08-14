program HostApp;

(* Oasis VCL host demo - a Windows app as a plugin system.

  Build: dcc32 -B -LUrtl,vcl (plus -U paths, see build.cmd / README).
  Run:   HostApp.exe            - interactive plugin manager
         HostApp.exe /selftest - automated end-to-end verification (writes
                                vclhost_selftest.txt next to the EXE).
  Loading the BPL plugin at run time additionally needs rtl.bpl, vcl.bpl and
  Oasis.Core.bpl on PATH (see build.cmd notes). *)

uses
  Vcl.Forms,
  System.SysUtils, System.IOUtils,
  Oasis.Types in '..\..\src\Oasis.Core\Oasis.Types.pas',
  Oasis.Errors in '..\..\src\Oasis.Core\Oasis.Errors.pas',
  Oasis.Spin in '..\..\src\Oasis.Core\Oasis.Spin.pas',
  Oasis.Effects in '..\..\src\Oasis.Core\Oasis.Effects.pas',
  Oasis.Services in '..\..\src\Oasis.Core\Oasis.Services.pas',
  Oasis.Events in '..\..\src\Oasis.Core\Oasis.Events.pas',
  Oasis.Context in '..\..\src\Oasis.Core\Oasis.Context.pas',
  Oasis.Plugin in '..\..\src\Oasis.Core\Oasis.Plugin.pas',
  Oasis.UI in '..\..\src\Oasis.UI\Oasis.UI.pas',
  Oasis.BplContract in '..\..\src\Oasis.Bpl\Oasis.BplContract.pas',
  Oasis.BplLoader in '..\..\src\Oasis.Bpl\Oasis.BplLoader.pas',
  Oasis.Loader in '..\..\src\Oasis.Hosting\Oasis.Loader.pas',
  Oasis.Host in '..\..\src\Oasis.Hosting\Oasis.Host.pas',
  Oasis.Config in '..\..\src\Oasis.Hosting\Oasis.Config.pas',
  VclPluginContract in '..\..\samples\VclBplPlugin\VclPluginContract.pas',
  InProcPlugins in 'InProcPlugins.pas',
  MainForm in 'MainForm.pas';

begin
  Application.Initialize;
  Application.MainFormOnTaskbar := True;
  Application.CreateForm(TMainForm, GMainForm);
  Application.Run;
end.
