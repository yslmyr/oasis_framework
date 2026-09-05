program OasisMormotTestsRunner;
{$APPTYPE CONSOLE}
{$STRONGLINKTYPES ON}

{ Task 7: standalone mORMot-bridge test runner (spec 7.2) - program name must
  differ from the test unit's (Delphi: same program+unit name = recursive use;
  see tests/otl/Oasis.Otl.Tests.dpr). Requires a local mormot2 checkout
  (src/core [+ src/soa, static] on -U); not part of the mormot-free core suite. }

uses
  System.SysUtils,
  DUnitX.Loggers.Console,
  DUnitX.TestFramework,
  Oasis.Types in '..\..\src\Oasis.Core\Oasis.Types.pas',
  Oasis.Errors in '..\..\src\Oasis.Core\Oasis.Errors.pas',
  Oasis.Spin in '..\..\src\Oasis.Core\Oasis.Spin.pas',
  Oasis.Effects in '..\..\src\Oasis.Core\Oasis.Effects.pas',
  Oasis.Services in '..\..\src\Oasis.Core\Oasis.Services.pas',
  Oasis.Events in '..\..\src\Oasis.Core\Oasis.Events.pas',
  Oasis.Inject in '..\..\src\Oasis.Core\Oasis.Inject.pas',
  Oasis.Context in '..\..\src\Oasis.Core\Oasis.Context.pas',
  Oasis.Plugin in '..\..\src\Oasis.Core\Oasis.Plugin.pas',
  Oasis.Loader in '..\..\src\Oasis.Hosting\Oasis.Loader.pas',
  Oasis.Config in '..\..\src\Oasis.Hosting\Oasis.Config.pas',
  Oasis.Host in '..\..\src\Oasis.Hosting\Oasis.Host.pas',
  Oasis.Mormot in '..\..\src\Oasis.Mormot\Oasis.Mormot.pas',
  mormot.core.base,
  mormot.core.interfaces,
  Oasis.Mormot.Tests in 'Oasis.Mormot.Tests.pas';

var
  LRunner: ITestRunner;
  LResults: IRunResults;
  LLogger: ITestLogger;
begin
  ReportMemoryLeaksOnShutdown := True;
  try
    TDUnitX.CheckCommandLine;
    LRunner := TDUnitX.CreateRunner;
    LLogger := TDUnitXConsoleLogger.Create(True);
    LRunner.AddLogger(LLogger);
    LResults := LRunner.Execute;
    if not LResults.AllPassed then
      ExitCode := 1;
  except
    on E: Exception do
    begin
      Writeln(E.ClassName, ': ', E.Message);
      ExitCode := 1;
    end;
  end;
end.
