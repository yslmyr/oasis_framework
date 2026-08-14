program ConsoleDemo;

{$APPTYPE CONSOLE}

{ Oasis MVP demo: three plugins in a deliberately wrong mount order.
  Config provides IConfig; Logger injects IConfig and provides ILogger; App
  injects ILogger and listens for host/started. The Host's dependency
  activation (pending queue + rescan-on-register) wires them up at runtime,
  regardless of mount order. }

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
  Oasis.Host in '..\..\src\Oasis.Hosting\Oasis.Host.pas';

type
  IConfig = interface
    ['{44444444-0000-0000-0000-000000000004}']
    function AppName: string;
  end;
  ILogger = interface
    ['{55555555-0000-0000-0000-000000000005}']
    procedure Info(const AMsg: string);
  end;

  TConfigImpl = class(TInterfacedObject, IConfig)
  public
    function AppName: string;
  end;
  TLoggerImpl = class(TInterfacedObject, ILogger)
  public
    procedure Info(const AMsg: string);
  end;

  TConfigPlugin = class(TOasisPlugin)
  public
    constructor Create;
    procedure Apply(const Ctx: IContext); override;
  end;
  TLoggerPlugin = class(TOasisPlugin)
  public
    constructor Create;
    procedure Apply(const Ctx: IContext); override;
  end;
  TAppPlugin = class(TOasisPlugin)
  public
    constructor Create;
    procedure Apply(const Ctx: IContext); override;
  end;

function TConfigImpl.AppName: string;
begin
  Result := 'OasisDemo';
end;

procedure TLoggerImpl.Info(const AMsg: string);
begin
  Writeln('[INFO] ', AMsg);
end;

constructor TConfigPlugin.Create;
begin
  inherited Create('config');
end;

procedure TConfigPlugin.Apply(const Ctx: IContext);
begin
  Ctx.Services.Register(IConfig, TConfigImpl.Create);
end;

constructor TLoggerPlugin.Create;
begin
  inherited Create('logger');
  AddInject(IConfig);
end;

procedure TLoggerPlugin.Apply(const Ctx: IContext);
begin
  Ctx.Services.Register(ILogger, TLoggerImpl.Create);
end;

constructor TAppPlugin.Create;
begin
  inherited Create('app');
  AddInject(ILogger);
end;

procedure TAppPlugin.Apply(const Ctx: IContext);
var
  LConfig: IConfig;
begin
  LConfig := Ctx.Services.Get(IConfig) as IConfig;
  Ctx.Events.On(EV_HOST_STARTED,
    procedure(const A: array of const)
    begin
      Writeln(LConfig.AppName, ' is running.');
    end);
end;

var
  Host: THost;
begin
  ReportMemoryLeaksOnShutdown := True;
  Host := THost.Create;
  try
    { Mount in deliberately wrong order: deps resolve at runtime. }
    Host.Mount(TAppPlugin.Create);
    Host.Mount(TLoggerPlugin.Create);
    Host.Mount(TConfigPlugin.Create);
    Host.Start;
    Writeln('Pending: ', Length(Host.PendingPlugins),
            '  Failed: ', Length(Host.FailedPlugins));
    Host.Shutdown;
    Writeln('Done.');
  finally
    Host.Free;
  end;
end.
