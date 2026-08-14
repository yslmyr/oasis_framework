program ConfigDemo;

{$APPTYPE CONSOLE}

(* Oasis demo - config-driven assembly (cordis.yml semantics, JSON edition).

  Writes an app.json next to the EXE containing a base layer plus a
  "production" env layer, then mounts everything through the config:

    - a DISABLED plugin is skipped by Host.TryMount
    - an enabled server plugin reads TYPED values (Int/Bool/Float)
    - running the same file with the 'production' env layer changes the
      behavior (port + verbose) without touching the base layer

  Run:  ConfigDemo.exe            (base layer)
        ConfigDemo.exe production (env layer on top) *)

uses
  System.SysUtils, System.IOUtils,
  Oasis.Types in '..\..\src\Oasis.Core\Oasis.Types.pas',
  Oasis.Spin in '..\..\src\Oasis.Core\Oasis.Spin.pas',
  Oasis.Errors in '..\..\src\Oasis.Core\Oasis.Errors.pas',
  Oasis.Effects in '..\..\src\Oasis.Core\Oasis.Effects.pas',
  Oasis.Services in '..\..\src\Oasis.Core\Oasis.Services.pas',
  Oasis.Events in '..\..\src\Oasis.Core\Oasis.Events.pas',
  Oasis.Context in '..\..\src\Oasis.Core\Oasis.Context.pas',
  Oasis.Plugin in '..\..\src\Oasis.Core\Oasis.Plugin.pas',
  Oasis.Loader in '..\..\src\Oasis.Hosting\Oasis.Loader.pas',
  Oasis.Host in '..\..\src\Oasis.Hosting\Oasis.Host.pas',
  Oasis.Config in '..\..\src\Oasis.Hosting\Oasis.Config.pas';

type
  TServerPlugin = class(TOasisPlugin)
  public
    constructor Create;
    procedure Apply(const Ctx: IContext); override;
  end;

  TMetricsPlugin = class(TOasisPlugin)
  public
    constructor Create;
    procedure Apply(const Ctx: IContext); override;
  end;

  TDebugConsolePlugin = class(TOasisPlugin)
  public
    constructor Create;
    procedure Apply(const Ctx: IContext); override;
  end;

constructor TServerPlugin.Create;
begin
  inherited Create('server');
  AddInject(IOasisConfig);
end;

procedure TServerPlugin.Apply(const Ctx: IContext);
var
  LCfg: IOasisConfig;
begin
  LCfg := Ctx.Services.Get(IOasisConfig) as IOasisConfig;
  Writeln('  [server] listening on port ', LCfg.Int('server', 'port', 0),
    '  verbose=', LCfg.Bool('server', 'verbose', False),
    '  timeout=', LCfg.Float('server', 'timeout', 0):0:1, 's');
end;

constructor TMetricsPlugin.Create;
begin
  inherited Create('metrics');
  AddInject(IOasisConfig);
end;

procedure TMetricsPlugin.Apply(const Ctx: IContext);
var
  LCfg: IOasisConfig;
begin
  LCfg := Ctx.Services.Get(IOasisConfig) as IOasisConfig;
  Writeln('  [metrics] sampling ratio ', LCfg.Float('metrics', 'ratio', 0):0:2,
    ', retention ', LCfg.Int('metrics', 'retention', 0), ' days');
end;

const
  C_JSON =
    '{' +
    '"plugins":{' +
    '"server":{"config":{"port":"8080","verbose":"false","timeout":"3.5"}},' +
    '"metrics":{"config":{"ratio":"0.25","retention":"30"}},' +
    '"debug-console":{"disabled":true}},' +
    '"env":{' +
    '"production":{' +
    '"plugins":{' +
    '"server":{"config":{"port":"443","verbose":"true"}}}}}}';

procedure TDebugConsolePlugin.Apply(const Ctx: IContext);
begin
  Writeln('  [debug-console] mounted (should NOT happen - disabled in config)');
end;

constructor TDebugConsolePlugin.Create;
begin
  inherited Create('debug-console');
end;

var
  Host: THost;
  LPath, LEnv: string;
begin
  ReportMemoryLeaksOnShutdown := True;
  LPath := TPath.Combine(ExtractFilePath(ParamStr(0)), 'configdemo_app.json');
  TFile.WriteAllText(LPath, C_JSON);
  try
    if ParamStr(1) <> '' then
      LEnv := ParamStr(1)
    else
      LEnv := '(base)';
    Writeln('--- config layer: ', LEnv, ' ---');

    Host := THost.Create;
    try
      if ParamStr(1) <> '' then
        Host.Mount(TJsonConfigPlugin.Create(LPath, ParamStr(1)))
      else
        Host.Mount(TJsonConfigPlugin.Create(LPath));
      Host.Start;

      { config-driven mounting: 'debug-console' is disabled in the file }
      if Host.TryMount(TServerPlugin.Create) then
        Writeln('  server mounted')
      else
        Writeln('  server SKIPPED (disabled)');
      if Host.TryMount(TMetricsPlugin.Create) then
        Writeln('  metrics mounted');
      Host.TryMount(TDebugConsolePlugin.Create);   { never mounts }

      Writeln('  pending: ', Length(Host.PendingPlugins),
        '  failed: ', Length(Host.FailedPlugins));
      Host.Shutdown;
      Writeln('Done.');
    finally
      Host.Free;
    end;
  finally
    TFile.Delete(LPath);
  end;
end.
