unit Oasis.Otl.Tests;

interface

uses
  DUnitX.TestFramework, System.SysUtils, System.SyncObjs,
  Oasis.Types, Oasis.Errors, Oasis.Effects, Oasis.Events, Oasis.Context, Oasis.OtlEvents;

type
  [TestFixture]
  TOtlEventsTests = class
  public
    [Test]
    procedure Parallel_Runs_All_Async_Listeners;

    [Test]
    procedure Parallel_Listener_Failure_Isolated_And_Aggregates;

    [Test]
    procedure SerialAsync_Runs_All_Sequentially;

    [Test]
    procedure Auto_Unsubscribes_On_Scope_Dispose;

    [Test]
    procedure Bus_Is_IAsyncEventBus_And_Inherits_Sync;

    [Test]
    procedure Context_Uses_AsyncEventBus_When_Registered;
  end;

implementation

procedure TOtlEventsTests.Parallel_Runs_All_Async_Listeners;
var
  LScope: IEffectScope;
  LBus: IAsyncEventBus;
  LLock: TCriticalSection;
  LCount: Integer;
begin
  LCount := 0;
  LLock := TCriticalSection.Create;
  try
    LScope := TEffectScope.Create;
    LBus := TAsyncEventBus.Create(LScope, nil);
    LBus.OnAsync('e', procedure(const A: array of const) begin LLock.Enter; Inc(LCount); LLock.Leave; end);
    LBus.OnAsync('e', procedure(const A: array of const) begin LLock.Enter; Inc(LCount); LLock.Leave; end);
    LBus.OnAsync('e', procedure(const A: array of const) begin LLock.Enter; Inc(LCount); LLock.Leave; end);
    Assert.AreEqual(3, LBus.Parallel('e', []));
    Assert.AreEqual(3, LCount);
    LScope.Dispose;
  finally
    LLock.Free;
  end;
end;

procedure TOtlEventsTests.Parallel_Listener_Failure_Isolated_And_Aggregates;
var
  LScope: IEffectScope;
  LBus: IAsyncEventBus;
  LLock: TCriticalSection;
  LCount: Integer;
begin
  LCount := 0;
  LLock := TCriticalSection.Create;
  try
    LScope := TEffectScope.Create;
    LBus := TAsyncEventBus.Create(LScope, nil);
    LBus.OnAsync('e', procedure(const A: array of const) begin raise Exception.Create('boom'); end);
    LBus.OnAsync('e', procedure(const A: array of const) begin LLock.Enter; Inc(LCount); LLock.Leave; end);
    Assert.WillRaise(procedure begin LBus.Parallel('e', []); end, EOasisEventError);
    Assert.AreEqual(1, LCount, 'second listener must run despite the first raising');
    LScope.Dispose;
  finally
    LLock.Free;
  end;
end;

procedure TOtlEventsTests.SerialAsync_Runs_All_Sequentially;
var
  LScope: IEffectScope;
  LBus: IAsyncEventBus;
  LLock: TCriticalSection;
  LCount: Integer;
begin
  LCount := 0;
  LLock := TCriticalSection.Create;
  try
    LScope := TEffectScope.Create;
    LBus := TAsyncEventBus.Create(LScope, nil);
    LBus.OnAsync('e', procedure(const A: array of const) begin LLock.Enter; Inc(LCount); LLock.Leave; end);
    LBus.OnAsync('e', procedure(const A: array of const) begin LLock.Enter; Inc(LCount); LLock.Leave; end);
    Assert.AreEqual(2, LBus.SerialAsync('e', []));
    Assert.AreEqual(2, LCount);
    LScope.Dispose;
  finally
    LLock.Free;
  end;
end;

procedure TOtlEventsTests.Auto_Unsubscribes_On_Scope_Dispose;
var
  LScope: IEffectScope;
  LBus: IAsyncEventBus;
  LLock: TCriticalSection;
  LCount: Integer;
begin
  LCount := 0;
  LLock := TCriticalSection.Create;
  try
    LScope := TEffectScope.Create;
    LBus := TAsyncEventBus.Create(LScope, nil);
    LBus.OnAsync('e', procedure(const A: array of const) begin LLock.Enter; Inc(LCount); LLock.Leave; end);
    Assert.AreEqual(1, LBus.Parallel('e', []));
    Assert.AreEqual(1, LCount);
    LScope.Dispose;                          // auto-unsubscribe
    Assert.AreEqual(0, LBus.Parallel('e', []), 'no async listeners after scope disposed');
    Assert.AreEqual(1, LCount);
  finally
    LLock.Free;
  end;
end;

procedure TOtlEventsTests.Bus_Is_IAsyncEventBus_And_Inherits_Sync;
var
  LScope: IEffectScope;
  LBus: IEventBus;
  LRan: Boolean;
begin
  LRan := False;
  LScope := TEffectScope.Create;
  LBus := TAsyncEventBus.Create(LScope, nil);   // viewed as the sync interface
  try
    Assert.IsTrue(Supports(LBus, IAsyncEventBus), 'async bus must be QI-able to IAsyncEventBus');
    LBus.On('sync', procedure(const A: array of const) begin LRan := True; end);
    LBus.Emit('sync', []);
    Assert.IsTrue(LRan, 'synchronous On/Emit must still work (inherited)');
    LScope.Dispose;
  finally
  end;
end;

procedure TOtlEventsTests.Context_Uses_AsyncEventBus_When_Registered;
var
  Ctx: IContext;
  LBus: IAsyncEventBus;
  LLock: TCriticalSection;
  LCount: Integer;
begin
  OasisRegisterAsyncEventBus;
  try
    LCount := 0;
    LLock := TCriticalSection.Create;
    try
      Ctx := TContext.Create('root');
      Assert.IsTrue(Supports(Ctx.Events, IAsyncEventBus),
        'context bus must be IAsyncEventBus after registration');
      LBus := Ctx.Events as IAsyncEventBus;
      LBus.OnAsync('e', procedure(const A: array of const) begin LLock.Enter; Inc(LCount); LLock.Leave; end);
      LBus.OnAsync('e', procedure(const A: array of const) begin LLock.Enter; Inc(LCount); LLock.Leave; end);
      Assert.AreEqual(2, LBus.Parallel('e', []));
      Assert.AreEqual(2, LCount);
      Ctx.Dispose;
    finally
      LLock.Free;
    end;
  finally
    TContext.SetEventBusFactory(nil);   { restore default so other tests are unaffected }
  end;
end;

initialization
  TDUnitX.RegisterTestFixture(TOtlEventsTests);

end.
