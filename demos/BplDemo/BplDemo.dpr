program BplDemo;

{$APPTYPE CONSOLE}

{ Oasis phase-3 demo: load a real BPL plugin dynamically. Builds and uses a
  TBplPluginLoader (Kind='bpl'); Host.Mount('bpl:<path>') routes to it. The
  plugin (samples/BplPlugin/SamplePlugin.bpl) registers an IGreeting service via
  its factory; the host resolves it and prints the greeting.

  Notes:
  - The host EXE must be built with `-LUrtl` so it shares the Delphi RTL runtime
    package (rtl.bpl) with the BPL; RegisterClassAlias/FindClass rely on the
    shared global class list. (And rtl.bpl must be on PATH at run time.)
  - Under `-LUrtl` this console app's stdout can be silently dropped, so results
    are ALSO written to bpldemo_out.txt next to the EXE. }

uses
  System.SysUtils,
  Oasis.Types in '..\..\src\Oasis.Core\Oasis.Types.pas',
  Oasis.Errors in '..\..\src\Oasis.Core\Oasis.Errors.pas',
  Oasis.Effects in '..\..\src\Oasis.Core\Oasis.Effects.pas',
  Oasis.Services in '..\..\src\Oasis.Core\Oasis.Services.pas',
  Oasis.Events in '..\..\src\Oasis.Core\Oasis.Events.pas',
  Oasis.Context in '..\..\src\Oasis.Core\Oasis.Context.pas',
  Oasis.Plugin in '..\..\src\Oasis.Core\Oasis.Plugin.pas',
  Oasis.Loader in '..\..\src\Oasis.Hosting\Oasis.Loader.pas',
  Oasis.Host in '..\..\src\Oasis.Hosting\Oasis.Host.pas',
  Oasis.BplContract in '..\..\src\Oasis.Bpl\Oasis.BplContract.pas',
  Oasis.BplLoader in '..\..\src\Oasis.Bpl\Oasis.BplLoader.pas',
  SampleContract in '..\..\samples\BplPlugin\SampleContract.pas';

var
  Host: THost;
  Bpl: IPluginLoader;
  G: IGreeting;
  BplPath, OutPath: string;
  LOut: TextFile;
begin
  ReportMemoryLeaksOnShutdown := True;
  if ParamStr(1) <> '' then
    BplPath := ParamStr(1)
  else
    BplPath := ExpandFileName(ExtractFilePath(ParamStr(0)) +
      '..\..\samples\BplPlugin\SamplePlugin.bpl');
  OutPath := ExpandFileName(ExtractFilePath(ParamStr(0)) + 'bpldemo_out.txt');

  Host := THost.Create;
  try
    if not FileExists(BplPath) then
      raise EOasisLoaderError.Create('BPL not found: ' + BplPath);
    Bpl := TBplPluginLoader.Create;
    Host.Use(Bpl);
    Host.Mount('bpl:' + BplPath);
    Host.Start;
    G := Host.Root.Services.Get(IGreeting) as IGreeting;

    AssignFile(LOut, OutPath);
    Rewrite(LOut);
    try
      Writeln(LOut, G.Greet('world'));
      Writeln(LOut, 'Pending: ', Length(Host.PendingPlugins),
              '  Failed: ', Length(Host.FailedPlugins));
    finally
      CloseFile(LOut);
    end;
    Writeln(G.Greet('world'));   { also to console (may be dropped under -LUrtl) }
    Host.Shutdown;
  finally
    Host.Free;
  end;
end.
