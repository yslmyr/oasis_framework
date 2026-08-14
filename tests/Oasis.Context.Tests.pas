unit Oasis.Context.Tests;

interface

uses
  DUnitX.TestFramework, System.SysUtils, System.Generics.Collections,
  Oasis.Types, Oasis.Errors, Oasis.Effects, Oasis.Services, Oasis.Events,
  Oasis.Context;

type
  ICounter = interface
    ['{22222222-0000-0000-0000-000000000002}']
    function Value: Integer;
  end;

  [TestFixture]
  TContextTests = class
  public
    [Test]
    procedure Plugin_Effects_Are_Isolated_Per_Plugin;

    [Test]
    procedure Closure_Plugin_Mounts_And_Unloads;

    [Test]
    procedure Dispose_Tears_Down_Fibers_In_Reverse_Order;

    [Test]
    procedure Fork_Creates_Isolated_Scope_But_Sees_Parent_Services;

    [Test]
    procedure Apply_Returned_Disposer_Runs_On_Dispose;

    [Test]
    procedure Failed_Plugin_Does_Not_Stop_Others;

    [Test]
    procedure Reload_Re_Runs_And_Tears_Down_Effects_And_Listeners;

    [Test]
    procedure Reload_By_Name_Re_Runs_Only_That_Plugin;

    [Test]
    procedure Reload_By_Name_Unknown_Returns_False;
  end;

implementation

type
  TCounterImpl = class(TInterfacedObject, ICounter)
  strict private
    FValue: Integer;
  public
    constructor Create(AValue: Integer);
    function Value: Integer;
  end;

  TRecordingPlugin = class(TInterfacedObject, IPlugin)
  strict private
    FName: string;
    FTrace: TList<string>;
  public
    constructor Create(const AName: string; ATrace: TList<string>);
    function PluginName: string;
    function Inject: TArray<TGUID>;
    procedure Apply(const Ctx: IContext);
  end;

{ TCounterImpl }

constructor TCounterImpl.Create(AValue: Integer);
begin
  inherited Create;
  FValue := AValue;
end;

function TCounterImpl.Value: Integer;
begin
  Result := FValue;
end;

{ TRecordingPlugin }

constructor TRecordingPlugin.Create(const AName: string; ATrace: TList<string>);
begin
  inherited Create;
  FName := AName;
  FTrace := ATrace;
end;

function TRecordingPlugin.PluginName: string;
begin
  Result := FName;
end;

function TRecordingPlugin.Inject: TArray<TGUID>;
begin
  Result := nil;
end;

procedure TRecordingPlugin.Apply(const Ctx: IContext);
begin
  FTrace.Add(FName + '.apply');
  Ctx.Effects.AddCleanup(procedure begin FTrace.Add(FName + '.unload'); end);
end;

{ TContextTests }

procedure TContextTests.Plugin_Effects_Are_Isolated_Per_Plugin;
var
  Ctx: IContext;
  LTrace: TList<string>;
begin
  LTrace := TList<string>.Create;
  try
    Ctx := TContext.Create('root');
    Ctx.Plugin(TRecordingPlugin.Create('a', LTrace));
    Ctx.Plugin(TRecordingPlugin.Create('b', LTrace));
    Ctx.Dispose;
    Assert.IsTrue(LTrace.Contains('a.apply'));
    Assert.IsTrue(LTrace.Contains('b.apply'));
    Assert.IsTrue(LTrace.Contains('a.unload'));
    Assert.IsTrue(LTrace.Contains('b.unload'));
  finally
    LTrace.Free;
  end;
end;

procedure TContextTests.Closure_Plugin_Mounts_And_Unloads;
var
  Ctx: IContext;
  LRan: Boolean;
begin
  LRan := False;
  Ctx := TContext.Create('root');
  Ctx.Plugin('closer',
    procedure(C: IContext)
    begin
      LRan := True;
      C.Effects.AddCleanup(procedure begin LRan := False; end);
    end);
  Assert.IsTrue(LRan);
  Ctx.Dispose;
  Assert.IsFalse(LRan);
end;

procedure TContextTests.Dispose_Tears_Down_Fibers_In_Reverse_Order;
var
  Ctx: IContext;
  LTrace: TList<string>;
begin
  LTrace := TList<string>.Create;
  try
    Ctx := TContext.Create('root');
    Ctx.Plugin(TRecordingPlugin.Create('a', LTrace));
    Ctx.Plugin(TRecordingPlugin.Create('b', LTrace));
    Ctx.Plugin(TRecordingPlugin.Create('c', LTrace));
    Ctx.Dispose;
    // fibers unload in reverse mount order: c, b, a (indices 3,4,5)
    Assert.AreEqual('c.unload', LTrace[3]);
    Assert.AreEqual('b.unload', LTrace[4]);
    Assert.AreEqual('a.unload', LTrace[5]);
  finally
    LTrace.Free;
  end;
end;

procedure TContextTests.Fork_Creates_Isolated_Scope_But_Sees_Parent_Services;
var
  Ctx, LFork: IContext;
begin
  Ctx := TContext.Create('root');
  Ctx.Services.Register(ICounter, TCounterImpl.Create(5));
  LFork := Ctx.Fork('child');
  Assert.AreEqual(5, (LFork.Services.Get(ICounter) as ICounter).Value);
  Ctx.Dispose;
end;

procedure TContextTests.Apply_Returned_Disposer_Runs_On_Dispose;
var
  Ctx: IContext;
  LRan: Boolean;
begin
  LRan := False;
  Ctx := TContext.Create('root');
  Ctx.Plugin('p',
    function(C: IContext): TDisposer
    begin
      Result := procedure begin LRan := True; end;
    end);
  Ctx.Dispose;
  Assert.IsTrue(LRan);
end;

procedure TContextTests.Failed_Plugin_Does_Not_Stop_Others;
var
  Ctx: IContext;
  LTrace: TList<string>;
begin
  LTrace := TList<string>.Create;
  try
    Ctx := TContext.Create('root');
    Ctx.Plugin('bad',
      procedure(C: IContext)
      begin
        LTrace.Add('bad.apply');
        raise Exception.Create('apply fails');
      end);
    Ctx.Plugin('good',
      procedure(C: IContext)
      begin
        LTrace.Add('good.apply');
      end);
    Ctx.Dispose;
    Assert.IsTrue(LTrace.Contains('bad.apply'));
    Assert.IsTrue(LTrace.Contains('good.apply'));
  finally
    LTrace.Free;
  end;
end;

procedure TContextTests.Reload_Re_Runs_And_Tears_Down_Effects_And_Listeners;
var
  Ctx: IContext;
  LApply, LTeardown, LHeard: Integer;
begin
  LApply := 0;
  LTeardown := 0;
  LHeard := 0;
  Ctx := TContext.Create('root');
  Ctx.Plugin('p',
    procedure(C: IContext)
    begin
      Inc(LApply);
      C.Effects.AddCleanup(procedure begin Inc(LTeardown); end);
      C.Events.On('ping', procedure(const A: array of const) begin Inc(LHeard); end);
    end);
  Ctx.Events.Emit('ping', []);
  Assert.AreEqual(1, LApply);
  Assert.AreEqual(1, LHeard);
  Assert.AreEqual(0, LTeardown);
  Ctx.Reload;
  Assert.AreEqual(2, LApply);      // Apply re-ran
  Assert.AreEqual(1, LTeardown);   // old effect cleaned up between runs
  Ctx.Events.Emit('ping', []);
  Assert.AreEqual(2, LHeard);      // old listener removed (not duplicated)
  Ctx.Dispose;
end;

procedure TContextTests.Reload_By_Name_Re_Runs_Only_That_Plugin;
var
  Ctx: IContext;
  LTargetApply, LOtherApply, LTargetHeard, LOtherHeard: Integer;
begin
  LTargetApply := 0;
  LOtherApply := 0;
  LTargetHeard := 0;
  LOtherHeard := 0;
  Ctx := TContext.Create('root');
  Ctx.Plugin('target',
    procedure(C: IContext)
    begin
      Inc(LTargetApply);
      C.Events.On('ping', procedure(const A: array of const) begin Inc(LTargetHeard); end);
    end);
  Ctx.Plugin('other',
    procedure(C: IContext)
    begin
      Inc(LOtherApply);
      C.Events.On('ping', procedure(const A: array of const) begin Inc(LOtherHeard); end);
    end);
  Ctx.Events.Emit('ping', []);
  Assert.AreEqual(1, LTargetApply);
  Assert.AreEqual(1, LOtherApply);
  Assert.AreEqual(1, LTargetHeard);
  Assert.AreEqual(1, LOtherHeard);

  Assert.IsTrue(Ctx.Reload('target'));
  Assert.AreEqual(2, LTargetApply);   // only target re-applied
  Assert.AreEqual(1, LOtherApply);    // other untouched
  Ctx.Events.Emit('ping', []);
  Assert.AreEqual(2, LTargetHeard);   // target listener reset, not duplicated
  Assert.AreEqual(2, LOtherHeard);    // other listener still attached
  Ctx.Dispose;
end;

procedure TContextTests.Reload_By_Name_Unknown_Returns_False;
var
  Ctx: IContext;
begin
  Ctx := TContext.Create('root');
  Assert.IsFalse(Ctx.Reload('no-such-plugin'));
  Ctx.Dispose;
end;

initialization
  TDUnitX.RegisterTestFixture(TContextTests);

end.
