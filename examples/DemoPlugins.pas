unit DemoPlugins;

{ Sample plugins for the Oasis demo. They exercise services, inject/PENDING,
  all five event dispatch modes, effects, config validation, hot replacement
  and fork scoping. }

interface

uses
  System.SysUtils,
  System.Classes,
  System.Rtti,
  System.Generics.Collections,
  Oasis.Core,
  Oasis.Config,
  Oasis.Plugin;

var
  { Simple shared log so the demo can assert on plugin activity. }
  DemoLog: string;
  EffectOrderLog: string;

procedure DemoLogAdd(const AMessage: string);

type
  { Provided under the "greeter" service name. }
  TGreeterService = class(TOasisService)
  strict private
    FPrefix: string;
  public
    constructor Create(const AServiceName: string; const APrefix: string); reintroduce;
    function Greet(const AWho: string): string;
  end;

  { Injects "greeter"; logs on every activation and unload. }
  TGreeterConsumer = class(TOasisPlugin)
  strict private
    FGreets: Integer;
    FUnloads: Integer;
  protected
    procedure OnApply(const Ctx: IOasisContext); override;
    procedure OnUnload(const Ctx: IOasisContext); override;
  public
    constructor Create; reintroduce;
    property Greets: Integer read FGreets;
    property Unloads: Integer read FUnloads;
  end;

  { Optional dependency: probes ctx.Get without declaring inject. }
  TProbePlugin = class(TOasisPlugin)
  protected
    procedure OnApply(const Ctx: IOasisContext); override;
  public
    constructor Create; reintroduce;
  end;

  { Provided under "stats"; bumps counters and announces via emit. }
  TStatsService = class(TOasisService)
  strict private
    FCounts: TDictionary<string, Integer>;
  public
    constructor Create(const AServiceName: string); reintroduce;
    destructor Destroy; override;
    procedure Bump(const AName: string);
    function CountOf(const AName: string): Integer;
  end;

  { Injects "stats"; listens to "stats/report" and bumps the service. }
  TStatsReporter = class(TOasisPlugin)
  protected
    procedure OnApply(const Ctx: IOasisContext); override;
  public
    constructor Create; reintroduce;
  end;

  { Two bail listeners for "demo/decision": the first returns a value and the
    chain must stop. }
  TBailDemoPlugin = class(TOasisPlugin)
  protected
    procedure OnApply(const Ctx: IOasisContext); override;
  public
    constructor Create; reintroduce;
  end;

  { Two emit listeners for "demo/parallel" that sleep different amounts; the
    demo asserts they run concurrently. }
  TParallelDemoPlugin = class(TOasisPlugin)
  protected
    procedure OnApply(const Ctx: IOasisContext); override;
  public
    constructor Create; reintroduce;
  end;

  { Waterfall listeners for "demo/transform": one wraps the downstream result
    (upper-case), one vetoes when the input contains "blocked". }
  TWaterfallDemoPlugin = class(TOasisPlugin)
  protected
    procedure OnApply(const Ctx: IOasisContext); override;
  public
    constructor Create; reintroduce;
  end;

  { A background thread started inside ctx.Effect; the disposer stops it. }
  THeartbeatThread = class(TThread)
  protected
    procedure Execute; override;
  end;

  THeartbeatPlugin = class(TOasisPlugin)
  protected
    procedure OnApply(const Ctx: IOasisContext); override;
  public
    constructor Create; reintroduce;
  end;

  { Registers two disposers; the demo asserts LIFO order. }
  TEffectOrderPlugin = class(TOasisPlugin)
  protected
    procedure OnApply(const Ctx: IOasisContext); override;
  public
    constructor Create; reintroduce;
  end;

  { Config validation demo: port must be 1..65535. }
  TPortConfig = class(TOasisConfig)
  strict private
    FPort: Integer;
  published
    [OasisConfig('TCP port the server listens on', True, 1, 65535)]
    property Port: Integer read FPort write FPort;
  end;

  TServerPlugin = class(TOasisPlugin<TPortConfig>)
  protected
    procedure OnApply(const Ctx: IOasisContext); override;
  public
    constructor Create; reintroduce;
  end;

  { Fork demo plugins. }
  TBubbleCatcher = class(TOasisPlugin)
  protected
    procedure OnApply(const Ctx: IOasisContext); override;
  public
    constructor Create; reintroduce;
  end;

  TChildEmitter = class(TOasisPlugin)
  protected
    procedure OnApply(const Ctx: IOasisContext); override;
  public
    constructor Create; reintroduce;
  end;

  TInheritedGreeterUser = class(TOasisPlugin)
  protected
    procedure OnApply(const Ctx: IOasisContext); override;
  public
    constructor Create; reintroduce;
  end;

implementation

procedure DemoLogAdd(const AMessage: string);
begin
  DemoLog := DemoLog + AMessage + ';';
end;

{ TGreeterService }

constructor TGreeterService.Create(const AServiceName: string; const APrefix: string);
begin
  inherited Create(AServiceName);
  FPrefix := APrefix;
end;

function TGreeterService.Greet(const AWho: string): string;
begin
  Result := FPrefix + ', ' + AWho + '!';
end;

{ TGreeterConsumer }

constructor TGreeterConsumer.Create;
begin
  inherited Create('greeter-consumer');
  InjectServices(['greeter']);
end;

procedure TGreeterConsumer.OnApply(const Ctx: IOasisContext);
var
  Greeter: TGreeterService;
begin
  Greeter := Ctx.ServiceObject('greeter') as TGreeterService;
  Inc(FGreets);
  Writeln('  [consumer] loaded: ', Greeter.Greet('Delphi'));
  DemoLogAdd('consumer loaded');
end;

procedure TGreeterConsumer.OnUnload(const Ctx: IOasisContext);
begin
  Inc(FUnloads);
  Writeln('  [consumer] unloaded: greeter went away');
  DemoLogAdd('consumer unloaded');
end;

{ TProbePlugin }

constructor TProbePlugin.Create;
begin
  inherited Create('probe');
end;

procedure TProbePlugin.OnApply(const Ctx: IOasisContext);
var
  Greeter: TGreeterService;
begin
  // Optional dependency: no inject declaration, probe at the use site.
  if Ctx.Has('greeter') then
  begin
    Greeter := Ctx.Get('greeter').AsObject as TGreeterService;
    DemoLogAdd('probe: ' + Greeter.Greet('probe'));
  end
  else
    DemoLogAdd('probe: no greeter available');
end;

{ TStatsService }

constructor TStatsService.Create(const AServiceName: string);
begin
  inherited Create(AServiceName);
  FCounts := TDictionary<string, Integer>.Create;
end;

destructor TStatsService.Destroy;
begin
  FCounts.Free;
  inherited;
end;

procedure TStatsService.Bump(const AName: string);
var
  Next: Integer;
begin
  if not FCounts.TryGetValue(AName, Next) then
    Next := 0;
  Inc(Next);
  FCounts.AddOrSetValue(AName, Next);
  if Context <> nil then
    Context.Emit('stats/report', OasisArgs([AName, Next]));
end;

function TStatsService.CountOf(const AName: string): Integer;
begin
  if not FCounts.TryGetValue(AName, Result) then
    Result := 0;
end;

{ TStatsReporter }

constructor TStatsReporter.Create;
begin
  inherited Create('stats-reporter');
  InjectServices(['stats']);
end;

procedure TStatsReporter.OnApply(const Ctx: IOasisContext);
var
  Stats: TStatsService;
begin
  Ctx.On('stats/report',
    procedure(const Args: TOasisArgs)
    begin
      Writeln(Format('  [stats] %s -> %d', [Args[0].AsString, Args[1].AsInteger]));
    end);
  Stats := Ctx.ServiceObject('stats') as TStatsService;
  Stats.Bump('tool_call');
  Stats.Bump('tool_call');
  Stats.Bump('prompt');
end;

{ TBailDemoPlugin }

constructor TBailDemoPlugin.Create;
begin
  inherited Create('bail-demo');
end;

procedure TBailDemoPlugin.OnApply(const Ctx: IOasisContext);
begin
  Ctx.On('demo/decision',
    function(const Args: TOasisArgs): TValue
    begin
      Writeln('  [bail] first listener runs, owns the decision');
      Result := 'first';
    end);
  Ctx.On('demo/decision',
    function(const Args: TOasisArgs): TValue
    begin
      Writeln('  [bail] second listener runs (unexpected)');
      Result := 'second';
    end);
end;

{ TParallelDemoPlugin }

constructor TParallelDemoPlugin.Create;
begin
  inherited Create('parallel-demo');
end;

procedure TParallelDemoPlugin.OnApply(const Ctx: IOasisContext);
begin
  Ctx.On('demo/parallel',
    procedure(const Args: TOasisArgs)
    begin
      Writeln('  [parallel] listener A start');
      TThread.Sleep(300);
      Writeln('  [parallel] listener A done');
    end);
  Ctx.On('demo/parallel',
    procedure(const Args: TOasisArgs)
    begin
      Writeln('  [parallel] listener B start');
      TThread.Sleep(100);
      Writeln('  [parallel] listener B done');
    end);
end;

{ TWaterfallDemoPlugin }

constructor TWaterfallDemoPlugin.Create;
begin
  inherited Create('waterfall-demo');
end;

procedure TWaterfallDemoPlugin.OnApply(const Ctx: IOasisContext);
begin
  // Listener 1: wrap the downstream result.
  Ctx.On('demo/transform',
    function(const Args: TOasisArgs; const Next: TOasisNext): TValue
    begin
      Result := UpperCase(Next(Args).AsString);
    end);
  // Listener 2: veto when it owns the decision.
  Ctx.On('demo/transform',
    function(const Args: TOasisArgs; const Next: TOasisNext): TValue
    begin
      if Pos('blocked', Args[0].AsString) > 0 then
      begin
        Writeln('  [waterfall] veto: blocked input');
        Result := '** blocked **';
      end
      else
        Result := Next(Args);
    end);
end;

{ THeartbeatThread }

procedure THeartbeatThread.Execute;
begin
  while not Terminated do
  begin
    TThread.Sleep(250);
    Writeln('  [heartbeat] tick');
  end;
end;

{ THeartbeatPlugin }

constructor THeartbeatPlugin.Create;
begin
  inherited Create('heartbeat');
end;

procedure THeartbeatPlugin.OnApply(const Ctx: IOasisContext);
var
  Thread: THeartbeatThread;
begin
  Ctx.Effect(
    function: TOasisDisposer
    begin
      Thread := THeartbeatThread.Create(False);
      Writeln('  [heartbeat] thread started');
      Result := procedure
      begin
        Thread.Terminate;
        Thread.WaitFor;
        Thread.Free;
        Writeln('  [heartbeat] cleaned up');
        DemoLogAdd('heartbeat cleaned up');
      end;
    end);
end;

{ TEffectOrderPlugin }

constructor TEffectOrderPlugin.Create;
begin
  inherited Create('effect-order');
end;

procedure TEffectOrderPlugin.OnApply(const Ctx: IOasisContext);
begin
  Ctx.OnDispose(procedure begin EffectOrderLog := EffectOrderLog + '1'; end);
  Ctx.OnDispose(procedure begin EffectOrderLog := EffectOrderLog + '2'; end);
end;

{ TServerPlugin }

constructor TServerPlugin.Create;
begin
  inherited Create;
end;

procedure TServerPlugin.OnApply(const Ctx: IOasisContext);
begin
  Writeln('  [server] listening on port ', Config.Port);
end;

{ TBubbleCatcher }

constructor TBubbleCatcher.Create;
begin
  inherited Create('bubble-catcher');
end;

procedure TBubbleCatcher.OnApply(const Ctx: IOasisContext);
begin
  Ctx.On('fork/event',
    procedure(const Args: TOasisArgs)
    begin
      DemoLogAdd('parent:' + Args[0].AsString);
    end);
end;

{ TChildEmitter }

constructor TChildEmitter.Create;
begin
  inherited Create('child-emitter');
end;

procedure TChildEmitter.OnApply(const Ctx: IOasisContext);
begin
  Ctx.On('fork/event',
    procedure(const Args: TOasisArgs)
    begin
      DemoLogAdd('child:' + Args[0].AsString);
    end);
  Ctx.Emit('fork/event', OasisArgs(['ping']));
end;

{ TInheritedGreeterUser }

constructor TInheritedGreeterUser.Create;
begin
  inherited Create('inherited-greeter-user');
end;

procedure TInheritedGreeterUser.OnApply(const Ctx: IOasisContext);
var
  Greeter: TGreeterService;
begin
  Greeter := Ctx.ServiceObject('greeter') as TGreeterService;
  if Greeter <> nil then
    DemoLogAdd('fork-greet: ' + Greeter.Greet('fork'))
  else
    DemoLogAdd('fork-greet: missing');
end;

end.
