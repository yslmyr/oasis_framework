program Oasis.Tests;

{$APPTYPE CONSOLE}
{$STRONGLINKTYPES ON}

uses
  System.SysUtils,
  DUnitX.Loggers.Console,
  DUnitX.TestFramework,
  Oasis.Types in '..\src\Oasis.Core\Oasis.Types.pas',
  Oasis.Errors in '..\src\Oasis.Core\Oasis.Errors.pas',
  Oasis.Effects in '..\src\Oasis.Core\Oasis.Effects.pas',
  Oasis.Services in '..\src\Oasis.Core\Oasis.Services.pas',
  Oasis.Effects.Tests in 'Oasis.Effects.Tests.pas',
  Oasis.Services.Tests in 'Oasis.Services.Tests.pas';

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
