unit Oasis.Events.Tests;

interface

uses
  DUnitX.TestFramework, System.SysUtils, System.Generics.Collections,
  Oasis.Types, Oasis.Errors, Oasis.Effects, Oasis.Events;

type
  [TestFixture]
  TEventsTests = class
  public
    [Test]
    procedure Emit_Runs_Listeners_In_Registration_Order;

    [Test]
    procedure Listener_Failure_Does_Not_Stop_Others_And_Aggregates;

    [Test]
    procedure Waterfall_Calling_Next_Passes_Through;

    [Test]
    procedure Waterfall_Not_Calling_Next_Short_Circuits;

    [Test]
    procedure Auto_Unsubscribes_When_Owner_Scope_Disposes;

    [Test]
    procedure Emit_Bubbles_To_Parent_Bus;
  end;

implementation

{ Each On() registration creates a bus<->scope reference cycle that is broken by
  disposing the scope. These tests dispose their scopes explicitly. }

procedure TEventsTests.Emit_Runs_Listeners_In_Registration_Order;
var
  LScope: IEffectScope;
  LBus: IEventBus;
  LOrder: TList<string>;
begin
  LOrder := TList<string>.Create;
  try
    LScope := TEffectScope.Create;
    LBus := TEventBus.Create(LScope, nil);
    LBus.On('e', procedure(const A: array of const) begin LOrder.Add('a'); end);
    LBus.On('e', procedure(const A: array of const) begin LOrder.Add('b'); end);
    LBus.Emit('e', []);
    Assert.AreEqual(2, LOrder.Count);
    Assert.AreEqual('a', LOrder[0]);
    Assert.AreEqual('b', LOrder[1]);
    LScope.Dispose;
  finally
    LOrder.Free;
  end;
end;

procedure TEventsTests.Listener_Failure_Does_Not_Stop_Others_And_Aggregates;
var
  LScope: IEffectScope;
  LBus: IEventBus;
  LRanSecond: Boolean;
begin
  LRanSecond := False;
  LScope := TEffectScope.Create;
  LBus := TEventBus.Create(LScope, nil);
  LBus.On('e', procedure(const A: array of const) begin raise Exception.Create('x'); end);
  LBus.On('e', procedure(const A: array of const) begin LRanSecond := True; end);
  Assert.WillRaise(procedure begin LBus.Emit('e', []); end, EOasisEventError);
  Assert.IsTrue(LRanSecond);
  LScope.Dispose;
end;

procedure TEventsTests.Waterfall_Calling_Next_Passes_Through;
var
  LScope: IEffectScope;
  LBus: IEventBus;
  LTrace: Integer;
begin
  LTrace := 0;
  LScope := TEffectScope.Create;
  LBus := TEventBus.Create(LScope, nil);
  LBus.OnWaterfall('w',
    procedure(const A: array of const; const ANext: TWaterfallNext)
    begin
      Inc(LTrace, 10);
      ANext(A);
    end);
  LBus.OnWaterfall('w',
    procedure(const A: array of const; const ANext: TWaterfallNext)
    begin
      Inc(LTrace, 1);
      ANext(A);
    end);
  LBus.Waterfall('w', []);
  Assert.AreEqual(11, LTrace);
  LScope.Dispose;
end;

procedure TEventsTests.Waterfall_Not_Calling_Next_Short_Circuits;
var
  LScope: IEffectScope;
  LBus: IEventBus;
  LReachedDownstream: Boolean;
begin
  LReachedDownstream := False;
  LScope := TEffectScope.Create;
  LBus := TEventBus.Create(LScope, nil);
  LBus.OnWaterfall('w',
    procedure(const A: array of const; const ANext: TWaterfallNext)
    begin
      { deliberately veto: do not call ANext }
    end);
  LBus.OnWaterfall('w',
    procedure(const A: array of const; const ANext: TWaterfallNext)
    begin
      LReachedDownstream := True;
      ANext(A);
    end);
  LBus.Waterfall('w', []);
  Assert.IsFalse(LReachedDownstream, 'downstream must not run after a veto');
  LScope.Dispose;
end;

procedure TEventsTests.Auto_Unsubscribes_When_Owner_Scope_Disposes;
var
  LScope: IEffectScope;
  LBus: IEventBus;
  LCount: Integer;
begin
  LCount := 0;
  LScope := TEffectScope.Create;
  LBus := TEventBus.Create(LScope, nil);
  LBus.On('e', procedure(const A: array of const) begin Inc(LCount); end);
  LBus.Emit('e', []);
  Assert.AreEqual(1, LCount);
  LScope.Dispose;                         // auto-unsubscribes
  LBus.Emit('e', []);                     // no listener now
  Assert.AreEqual(1, LCount);
end;

procedure TEventsTests.Emit_Bubbles_To_Parent_Bus;
var
  LRootScope, LForkScope: IEffectScope;
  LRootBus, LForkBus: IEventBus;
  LRootHeard: Boolean;
begin
  LRootHeard := False;
  LRootScope := TEffectScope.Create;
  LForkScope := TEffectScope.Create;
  LRootBus := TEventBus.Create(LRootScope, nil);
  LForkBus := TEventBus.Create(LForkScope, LRootBus);
  LRootBus.On('e', procedure(const A: array of const) begin LRootHeard := True; end);
  LForkBus.Emit('e', []);                 // bubbles up
  Assert.IsTrue(LRootHeard);
  LForkScope.Dispose;
  LRootScope.Dispose;
end;

initialization
  TDUnitX.RegisterTestFixture(TEventsTests);

end.
