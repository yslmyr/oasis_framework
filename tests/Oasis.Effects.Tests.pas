unit Oasis.Effects.Tests;

interface

uses
  DUnitX.TestFramework, System.SysUtils, System.Generics.Collections,
  Oasis.Types, Oasis.Errors, Oasis.Effects;

type
  [TestFixture]
  TEffectsTests = class
  public
    [Test]
    procedure Dispose_Runs_Cleanups_In_Reverse_Registration_Order;

    [Test]
    procedure Dispose_Continues_After_A_Cleanup_Raises_And_Aggregates;

    [Test]
    procedure Dispose_Is_Idempotent;

    [Test]
    procedure Manual_Dispose_Removes_And_Runs_Once;
  end;

implementation

procedure TEffectsTests.Dispose_Runs_Cleanups_In_Reverse_Registration_Order;
var
  LScope: IEffectScope;
  LOrder: TList<Integer>;
begin
  LOrder := TList<Integer>.Create;
  try
    LScope := TEffectScope.Create;
    LScope.AddCleanup(procedure begin LOrder.Add(1); end);
    LScope.AddCleanup(procedure begin LOrder.Add(2); end);
    LScope.AddCleanup(procedure begin LOrder.Add(3); end);
    LScope.Dispose;

    Assert.AreEqual(3, LOrder.Count);
    Assert.AreEqual(3, LOrder[0]);   // last registered runs first (LIFO)
    Assert.AreEqual(2, LOrder[1]);
    Assert.AreEqual(1, LOrder[2]);
  finally
    LOrder.Free;
  end;
end;

procedure TEffectsTests.Dispose_Continues_After_A_Cleanup_Raises_And_Aggregates;
var
  LScope: IEffectScope;
 LRanSecond: Boolean;
begin
  LRanSecond := False;
  LScope := TEffectScope.Create;
  LScope.AddCleanup(
    procedure
    begin
      raise Exception.Create('boom');
    end);
  LScope.AddCleanup(procedure begin LRanSecond := True; end);  // registered last -> runs first

  Assert.WillRaise(
    procedure begin LScope.Dispose; end,
    EOasisDisposeError);
  Assert.IsTrue(LRanSecond, 'second cleanup (LIFO) must run even though first raised');
end;

procedure TEffectsTests.Dispose_Is_Idempotent;
var
  LScope: IEffectScope;
  LCount: Integer;
begin
  LCount := 0;
  LScope := TEffectScope.Create;
  LScope.AddCleanup(procedure begin Inc(LCount); end);
  LScope.Dispose;
  LScope.Dispose;   // second call must be a no-op
  Assert.AreEqual(1, LCount);
end;

procedure TEffectsTests.Manual_Dispose_Removes_And_Runs_Once;
var
  LScope: IEffectScope;
  LCount: Integer;
  LDisposer: TDisposer;
begin
  LCount := 0;
  LScope := TEffectScope.Create;
  LDisposer := LScope.AddCleanup(procedure begin Inc(LCount); end);
  LDisposer();        // manual early dispose
  LDisposer();        // must NOT run again (idempotent)
  LScope.Dispose;     // must NOT run it again (already claimed)
  Assert.AreEqual(1, LCount);
end;

initialization
  TDUnitX.RegisterTestFixture(TEffectsTests);

end.
