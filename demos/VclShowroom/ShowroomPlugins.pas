unit ShowroomPlugins;

(* Oasis Showroom - the showcase plugins and services.

  Five built-in plugins, one Cordis advantage each:

    config   - provides IOasisConfig from a JSON file (cordis.yml semantics)
    appcfg   - adapts IOasisConfig -> IAppConfig (chained dependency: unloading
               'config' cascades TWO hops down to greeter)
    greeter  - Injects IAppConfig (mount-order independence: mounted first it
               parks in fsPending until the service appears)
    flaky    - Apply raises while GFlakyFaultOn is set (failure isolation +
               Reload(name) healing)
    preview  - gated by IOasisConfig.Disabled (Host.TryMount / disabled)

  Plus the Fork-scope session helpers and the background job thread used by
  the "worker thread -> event bus -> IUIInvoker" marshaling demo. *)

interface

uses
  System.SysUtils, System.Classes,
  Oasis.Types, Oasis.Context, Oasis.Plugin,
  Oasis.Config;

const
  EV_GREET_HELLO  : TEventKey = 'greet/hello';
  EV_SESSION_START: TEventKey = 'session/started';
  EV_JOB_PROGRESS : TEventKey = 'job/progress';
  EV_JOB_DONE     : TEventKey = 'job/done';
  EV_MARK         : TEventKey = 'showroom/mark';

type
  { Provided by 'appcfg' (adapted from IOasisConfig), injected by 'greeter'. }
  IAppConfig = interface
    ['{5C4A7B10-0001-4000-8000-3F2E1D0C9B01}']
    function Prefix: string;
  end;

  { Root provides a GLOBAL badge; every session fork shadows it with its own.
    Resolving ISessionBadge on a fork returns the session badge; on the root it
    still returns the global one. }
  ISessionBadge = interface
    ['{5C4A7B10-0002-4000-8000-3F2E1D0C9B02}']
    function Badge: string;
  end;

var
  { Fault switch for the 'flaky' plugin - toggled from the UI. }
  GFlakyFaultOn: Boolean = False;

type
  { config -> appcfg adapter. Demonstrates a dependency CHAIN: when the JSON
    provider unloads, this plugin loses IOasisConfig and unloads too, which in
    turn removes IAppConfig and unloads its dependents (two-hop cascade). }
  TAppCfgPlugin = class(TOasisPlugin)
  public
    constructor Create;
    procedure Apply(const Ctx: IContext); override;
  end;

  { Injects IAppConfig, emits greet/hello with the configured prefix. }
  TGreeterPlugin = class(TOasisPlugin)
  public
    constructor Create;
    procedure Apply(const Ctx: IContext); override;
  end;

  { Fails on purpose while GFlakyFaultOn is set. }
  TFlakyPlugin = class(TOasisPlugin)
  public
    constructor Create;
    procedure Apply(const Ctx: IContext); override;
  end;

  { Reads typed values back out of the JSON layer to prove the typed readers. }
  TPreviewPlugin = class(TOasisPlugin)
  public
    constructor Create;
    procedure Apply(const Ctx: IContext); override;
  end;

  { Background worker: emits job/progress five times off the main thread. The
    listener runs ON THE WORKER THREAD - the UI part must marshal through
    IUIInvoker (that is the whole point of the demo). }
  TJobThread = class(TThread)
  strict private
    FCtx: IContext;
    FTicks: Integer;
  protected
    procedure Execute; override;
  public
    constructor Create(const ACtx: IContext);
    property Ticks: Integer read FTicks;
  end;

{ Root-level GLOBAL badge (context-owned registration). }
procedure ProvideGlobalBadge(const ARoot: IContext);
{ Mount the per-session shadow plugin onto a fork (fiber-owned registration). }
procedure MountSessionCore(const AFork: IContext; const ASid: string);

implementation

uses
  System.SyncObjs;

type
  TAppCfgImpl = class(TInterfacedObject, IAppConfig)
  strict private
    FPrefix: string;
  public
    constructor Create(const APrefix: string);
    function Prefix: string;
  end;

  TBadgeImpl = class(TInterfacedObject, ISessionBadge)
  strict private
    FBadge: string;
  public
    constructor Create(const ABadge: string);
    function Badge: string;
  end;

{ impls }

constructor TAppCfgImpl.Create(const APrefix: string);
begin
  inherited Create;
  FPrefix := APrefix;
end;

function TAppCfgImpl.Prefix: string;
begin
  Result := FPrefix;
end;

constructor TBadgeImpl.Create(const ABadge: string);
begin
  inherited Create;
  FBadge := ABadge;
end;

function TBadgeImpl.Badge: string;
begin
  Result := FBadge;
end;

{ plugins }

constructor TAppCfgPlugin.Create;
begin
  inherited Create('appcfg');
  AddInject(IOasisConfig);
end;

procedure TAppCfgPlugin.Apply(const Ctx: IContext);
var
  LCfg: IOasisConfig;
begin
  if not Supports(Ctx.Services.Get(IOasisConfig), IOasisConfig, LCfg) then
    raise Exception.Create('appcfg: IOasisConfig missing');
  { Registered during Apply => fiber-owned: vanishes when THIS plugin unloads,
    firing OnServiceRemoved for whoever injects IAppConfig. }
  Ctx.Services.Register(IAppConfig, TAppCfgImpl.Create(LCfg.Value('greeter', 'prefix', 'Hello')));
end;

constructor TGreeterPlugin.Create;
begin
  inherited Create('greeter');
  AddInject(IAppConfig);
end;

procedure TGreeterPlugin.Apply(const Ctx: IContext);
var
  LSvc: IAppConfig;
begin
  if not Supports(Ctx.Services.Get(IAppConfig), IAppConfig, LSvc) then
    raise Exception.Create('greeter: IAppConfig missing');
  Ctx.Events.Emit(EV_GREET_HELLO, [LSvc.Prefix + ', greeting composed at activation time']);
end;

constructor TFlakyPlugin.Create;
begin
  inherited Create('flaky');
end;

procedure TFlakyPlugin.Apply(const Ctx: IContext);
begin
  if GFlakyFaultOn then
    raise Exception.Create('flaky: fault switch is ON - Apply raised');
  Ctx.Events.Emit(EV_MARK, ['flaky activated cleanly']);
end;

constructor TPreviewPlugin.Create;
begin
  inherited Create('preview');
  AddInject(IOasisConfig);
end;

procedure TPreviewPlugin.Apply(const Ctx: IContext);
var
  LCfg: IOasisConfig;
  LVerbose: string;
begin
  if not Supports(Ctx.Services.Get(IOasisConfig), IOasisConfig, LCfg) then
    raise Exception.Create('preview: IOasisConfig missing');
  if LCfg.Bool('preview', 'verbose', False) then LVerbose := 'true' else LVerbose := 'false';
  Ctx.Events.Emit(EV_MARK, [Format('preview read typed config: retries=%d verbose=%s',
    [LCfg.Int('preview', 'retries', 0), LVerbose])]);
end;

{ helpers }

procedure ProvideGlobalBadge(const ARoot: IContext);
begin
  { Outside any Apply: attaches to the context itself, so it survives until
    the context is disposed. }
  ARoot.Services.Register(ISessionBadge, TBadgeImpl.Create('GLOBAL-BADGE'));
end;

procedure MountSessionCore(const AFork: IContext; const ASid: string);
begin
  AFork.Plugin('session-core-' + ASid,
    procedure(C: IContext)
    begin
      C.Services.Register(ISessionBadge, TBadgeImpl.Create('BADGE#' + ASid));
      C.Events.Emit(EV_SESSION_START, ['session ' + ASid]);
    end);
end;

{ TJobThread }

constructor TJobThread.Create(const ACtx: IContext);
begin
  FCtx := ACtx;
  FTicks := 0;
  FreeOnTerminate := False;
  inherited Create(False);
end;

procedure TJobThread.Execute;
var
  I: Integer;
begin
  try
    for I := 1 to 5 do
    begin
      if Terminated then Exit;
      Sleep(230);
      FCtx.Events.Emit(EV_JOB_PROGRESS, [I, 5]);
      Inc(FTicks);
    end;
    FCtx.Events.Emit(EV_JOB_DONE, ['background job finished']);
  except
    ;   { never let the thread die silently-naked; the demo tolerates stops }
  end;
end;

end.
