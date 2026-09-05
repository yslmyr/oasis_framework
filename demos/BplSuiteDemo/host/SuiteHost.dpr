program SuiteHost;

(* BPL Suite demo host - Tangram-AdvancedDemo-style physical architecture:
  ONE host EXE + several feature BPL modules, all coupling through the shared
  SuiteContract interfaces only. The host itself mounts just one plugin of its
  own ('shell-host', providing IShellHost); every feature - services and UI -
  arrives by loading a BPL:
    modules/SuiteCore/SuiteCore.bpl        services (settings + lazy clock)
    modules/SuiteDashboard/SuiteDashboard.bpl  tab, [Inject]-ed deps
    modules/SuiteOrders/SuiteOrders.bpl    tab + transient service provider

  IMPORTANT build note: unlike demos/VclHostDemo (which compiles the Oasis
  units statically into the EXE), this host links Oasis.Core/.Hosting/.Bpl as
  RUNTIME PACKAGES (-LU). There must be exactly ONE copy of the Oasis classes
  in the process: [Inject] attribute matching is class-identity based, so a
  statically-duplicated Oasis.Inject in the host would not recognize the
  attribute instances the BPL modules' RTTI carries (they come from
  Oasis.Core.bpl) - injection would silently no-op. SuiteContract stays a
  static source copy (EXE-static + package is legal; BPL+BPL is not).

  Build: dcc32 -B -LUrtl -LUvcl -LUOasis.Core -LUOasis.Hosting -LUOasis.Bpl
         (plus -U paths, see build.cmd). Run-time PATH needs rtl.bpl, vcl.bpl,
  Oasis.Core/.Hosting/.Bpl.bpl - build.cmd sets this for the selftest.
  Run:   SuiteHost.exe            - interactive
         SuiteHost.exe /selftest - headless verification, writes
                                  bplsuite_selftest.txt; exit code 1 on any
                                  failed check. *)

uses
  Vcl.Forms,
  System.SysUtils, System.IOUtils,
  Oasis.Types, Oasis.Errors, Oasis.Spin, Oasis.Effects, Oasis.Services,
  Oasis.Events, Oasis.Inject, Oasis.Context, Oasis.Plugin,
  Oasis.BplContract, Oasis.BplLoader, Oasis.Loader, Oasis.Host, Oasis.Config,
  SuiteContract in '..\shared\SuiteContract.pas',
  SuiteMainForm in 'SuiteMainForm.pas';

begin
  Application.Initialize;
  Application.MainFormOnTaskbar := True;
  Application.CreateForm(TSuiteMainForm, GSuiteMainForm);
  Application.Run;
  if GSuiteMainForm.SelfTestFailed then
    ExitCode := 1;
end.
