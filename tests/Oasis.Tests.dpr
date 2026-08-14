program Oasis.Tests;

{$APPTYPE CONSOLE}
{$STRONGLINKTYPES ON}

uses
  System.SysUtils,
  DUnitX.Loggers.Console,
  DUnitX.TestFramework,
  Oasis.Types in '..\src\Oasis.Core\Oasis.Types.pas',
  Oasis.Errors in '..\src\Oasis.Core\Oasis.Errors.pas',
  Oasis.Spin in '..\src\Oasis.Core\Oasis.Spin.pas',
  Oasis.TypedEvents in '..\src\Oasis.Core\Oasis.TypedEvents.pas',
  Oasis.Effects in '..\src\Oasis.Core\Oasis.Effects.pas',
  Oasis.Services in '..\src\Oasis.Core\Oasis.Services.pas',
  Oasis.Events in '..\src\Oasis.Core\Oasis.Events.pas',
  Oasis.Context in '..\src\Oasis.Core\Oasis.Context.pas',
  Oasis.Plugin in '..\src\Oasis.Core\Oasis.Plugin.pas',
  Oasis.Loader in '..\src\Oasis.Hosting\Oasis.Loader.pas',
  Oasis.Host in '..\src\Oasis.Hosting\Oasis.Host.pas',
  Oasis.Config in '..\src\Oasis.Hosting\Oasis.Config.pas',
  Oasis.Effects.Tests in 'Oasis.Effects.Tests.pas',
  Oasis.Services.Tests in 'Oasis.Services.Tests.pas',
  Oasis.Events.Tests in 'Oasis.Events.Tests.pas',
  Oasis.Context.Tests in 'Oasis.Context.Tests.pas',
  Oasis.Hosting.Tests in 'Oasis.Hosting.Tests.pas',
  Oasis.Config.Tests in 'Oasis.Config.Tests.pas',
  Oasis.UI in '..\src\Oasis.UI\Oasis.UI.pas',
  Oasis.UI.Tests in 'Oasis.UI.Tests.pas',
  Oasis.Parity.Tests in 'Oasis.Parity.Tests.pas';

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
    {$IFDEF DEBUG}
    ReadLn;
    {$ENDIF}
  except
    on E: Exception do
    begin
      Writeln(E.ClassName, ': ', E.Message);
      ExitCode := 1;
    end;
  end;
end.
