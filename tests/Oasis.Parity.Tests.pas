unit Oasis.Parity.Tests;

interface

uses
  DUnitX.TestFramework, System.SysUtils, System.Types, System.Rtti,
  Oasis.Types, Oasis.Errors, Oasis.Effects, Oasis.Services, Oasis.Events,
  Oasis.Context, Oasis.Plugin, Oasis.TypedEvents,
  Oasis.Loader, Oasis.Host;

type
  IGreetCfg = interface
    ['{3A21D001-0000-0000-0000-000000000001}']
    function Prefix: string;
  end;

  [TestFixture]
  TParityTests = class
  public
    { #1 bail }
    [Test]
    procedure Bail_FirstTruthyWinsAndStops;

    [Test]
    procedure Bail_AllFalsyReturnsEmpty;

    [Test]
    procedure Bail_BubblesToParent;

    { #2 strongly-typed events }
    [Test]
    procedure TypedEvent_RecordPayloadRoundtrip;

    [Test]
    procedure TypedEvent_AutoUnsubOnScopeDispose;

    { #3 fiber state machine }
    [Test]
    procedure PluginState_Lifecycle_Active_Failed_Disposed;

    [Test]
    procedure PluginState_HostPending_WhenDependencyMissing;

    [Test]
    procedure PluginState_ReloadReturnsToActive;
  end;

implementation

type
  TNeedCfg = class(TOasisPlugin)
  public
    constructor Create;
  end;

  TSteady = class(TOasisPlugin)
  public
    constructor Create;
    procedure Apply(const Ctx: IContext); override;
  end;

{ TNeedCfg }

constructor TNeedCfg.Create;
begin
  inherited Create('needs-cfg');
  AddInject(IGreetCfg);
end;

{ TSteady }
constructor TSteady.Create;
begin
  inherited Create('steady');
end;

procedure TSteady.Apply(const Ctx: IContext);
begin
  { no-op plugin - only its state matters }
end;

{ TParityTests - bail }

procedure TParityTests.Bail_FirstTruthyWinsAndStops;
var
  LScope: IEffectScope;
  LBus: IEventBus;
  LCalls: Integer;
  LResult: TValue;
begin
  LCalls := 0;
  LScope := TEffectScope.Create;
  LBus := TEventBus.Create(LScope, nil);
  LBus.OnBail('q',
    function(const A: array of const): TValue
    begin
      Inc(LCalls);
      Result := TValue.Empty;   { falsy - chain continues }
    end);
  LBus.OnBail('q',
    function(const A: array of const): TValue
    begin
      Inc(LCalls);
      Result := 'winner';       { first truthy wins }
    end);
  LBus.OnBail('q',
    function(const A: array of const): TValue
    begin
      Inc(LCalls);              { must NOT run - chain stopped }
      Result := 'never';
    end);
  LResult := LBus.Bail('q', []);
  Assert.AreEqual(2, LCalls, 'downstream bail listener must not run');
  Assert.IsTrue(LResult.IsType<string>);
  Assert.AreEqual('winner', LResult.AsString);
  LScope.Dispose;
end;

procedure TParityTests.Bail_AllFalsyReturnsEmpty;
var
  LScope: IEffectScope;
  LBus: IEventBus;
begin
  LScope := TEffectScope.Create;
  LBus := TEventBus.Create(LScope, nil);
  LBus.OnBail('q',
    function(const A: array of const): TValue
    begin
      Result := False;          { falsy boolean }
    end);
  LBus.OnBail('q',
    function(const A: array of const): TValue
    begin
      Result := TValue.Empty;   { empty }
    end);
  Assert.IsTrue(LBus.Bail('q', []).IsEmpty,
    'no truthy result -> TValue.Empty');
  LScope.Dispose;
end;

procedure TParityTests.Bail_BubblesToParent;
var
  LRootScope, LForkScope: IEffectScope;
  LRootBus, LForkBus: IEventBus;
begin
  LRootScope := TEffectScope.Create;
  LForkScope := TEffectScope.Create;
  LRootBus := TEventBus.Create(LRootScope, nil);
  LForkBus := TEventBus.Create(LForkScope, LRootBus);
  LRootBus.OnBail('q',
    function(const A: array of const): TValue
    begin
      Result := 'from-root';
    end);
  Assert.AreEqual('from-root', LForkBus.Bail('q', []).AsString,
    'fork bail falls through to the parent chain');
  LForkScope.Dispose;
  LRootScope.Dispose;
end;

{ TParityTests - strongly-typed events }

procedure TParityTests.TypedEvent_RecordPayloadRoundtrip;
var
  LScope: IEffectScope;
  LBus: IEventBus;
  LMove: TOasisEvent<TPoint>;
  LGot: TPoint;
begin
  LGot.X := 0;
  LGot.Y := 0;
  LScope := TEffectScope.Create;
  LBus := TEventBus.Create(LScope, nil);
  LMove := TOasisEvent<TPoint>.Create('mouse/move');
  LMove.Subscribe(LBus,
    procedure(P: TPoint)
    begin
      LGot := P;   { fully typed - field access at compile time }
    end);
  LMove.Emit(LBus, Point(3, 4));
  Assert.AreEqual(3, LGot.X);
  Assert.AreEqual(4, LGot.Y);
  LScope.Dispose;
end;

procedure TParityTests.TypedEvent_AutoUnsubOnScopeDispose;
var
  LScope: IEffectScope;
  LBus: IEventBus;
  LMove: TOasisEvent<Integer>;
  LCount: Integer;
begin
  LCount := 0;
  LScope := TEffectScope.Create;
  LBus := TEventBus.Create(LScope, nil);
  LMove := TOasisEvent<Integer>.Create('tick');
  LMove.Subscribe(LBus,
    procedure(N: Integer)
    begin
      Inc(LCount);
    end);
  LMove.Emit(LBus, 1);
  LScope.Dispose;               { auto-unsubscribe via the underlying bus }
  LMove.Emit(LBus, 2);          { nobody listening }
  Assert.AreEqual(1, LCount);
end;

{ TParityTests - fiber state machine }

procedure TParityTests.PluginState_Lifecycle_Active_Failed_Disposed;
var
  Ctx: IContext;
begin
  Ctx := TContext.Create('root');
  Assert.AreEqual(fsDisposed, Ctx.PluginState('never-mounted'));

  Ctx.Plugin('ok', procedure(C: IContext) begin end);
  Assert.AreEqual(fsActive, Ctx.PluginState('ok'));

  Ctx.Plugin('bad', procedure(C: IContext) begin raise Exception.Create('x'); end);
  Assert.AreEqual(fsFailed, Ctx.PluginState('bad'),
    'failed entry is KEPT so its state is queryable');

  Ctx.Unload('ok');
  Assert.AreEqual(fsDisposed, Ctx.PluginState('ok'));

  Ctx.Dispose;
end;

procedure TParityTests.PluginState_HostPending_WhenDependencyMissing;
var
  Host: THost;
begin
  Host := THost.Create;
  try
    Host.Mount(TNeedCfg.Create);   { injects IGreetCfg, which nobody provides }
    Host.Mount(TSteady.Create);
    Host.Start;
    Assert.AreEqual(fsPending, Host.PluginState('needs-cfg'),
      'dependency-starved plugin is Host-level fsPending');
    Assert.AreEqual(fsActive, Host.PluginState('steady'));
    Assert.AreEqual(fsDisposed, Host.PluginState('nobody'));
  finally
    Host.Free;
  end;
end;

procedure TParityTests.PluginState_ReloadReturnsToActive;
var
  Ctx: IContext;
  LRuns: Integer;
begin
  LRuns := 0;
  Ctx := TContext.Create('root');
  Ctx.Plugin('p',
    procedure(C: IContext)
    begin
      Inc(LRuns);
    end);
  Assert.AreEqual(fsActive, Ctx.PluginState('p'));
  Ctx.Reload('p');
  Assert.AreEqual(fsActive, Ctx.PluginState('p'),
    'reload remounts under a fresh entry');
  Assert.AreEqual(2, LRuns);
  Ctx.Dispose;
end;

initialization
  TDUnitX.RegisterTestFixture(TParityTests);

end.
