unit Oasis.Services.Tests;

interface

uses
  DUnitX.TestFramework, System.SysUtils,
  Oasis.Errors, Oasis.Services;

type
  ICounter = interface
    ['{11111111-0000-0000-0000-000000000001}']
    function Value: Integer;
  end;

  TCounter = class(TInterfacedObject, ICounter)
  strict private
    FValue: Integer;
  public
    constructor Create(AValue: Integer);
    function Value: Integer;
  end;

  [TestFixture]
  TServicesTests = class
  public
    [Test]
    procedure Register_Then_Get_Returns_The_Instance;

    [Test]
    procedure Get_Missing_Raises_EOasisServiceNotFound;

    [Test]
    procedure Resolve_Missing_Returns_False;

    [Test]
    procedure Lookup_Walks_Parent_Chain;

    [Test]
    procedure Child_Shadows_Parent;

    [Test]
    procedure Register_Fires_OnServiceAdded;
  end;

implementation

{ TCounter }

constructor TCounter.Create(AValue: Integer);
begin
  inherited Create;
  FValue := AValue;
end;

function TCounter.Value: Integer;
begin
  Result := FValue;
end;

{ TServicesTests }

procedure TServicesTests.Register_Then_Get_Returns_The_Instance;
var
  R: IServiceRegistry;
  C: ICounter;
begin
  R := TServiceRegistry.Create(nil);
  R.Register(ICounter, TCounter.Create(7));
  C := R.Get(ICounter) as ICounter;
  Assert.AreEqual(7, C.Value);
end;

procedure TServicesTests.Get_Missing_Raises_EOasisServiceNotFound;
var
  R: IServiceRegistry;
begin
  R := TServiceRegistry.Create(nil);
  Assert.WillRaise(
    procedure begin R.Get(ICounter); end,
    EOasisServiceNotFound);
end;

procedure TServicesTests.Resolve_Missing_Returns_False;
var
  R: IServiceRegistry;
  LInstance: IInterface;
begin
  R := TServiceRegistry.Create(nil);
  Assert.IsFalse(R.Resolve(ICounter, LInstance));
end;

procedure TServicesTests.Lookup_Walks_Parent_Chain;
var
  RParent, RChild: IServiceRegistry;
begin
  RParent := TServiceRegistry.Create(nil);
  RChild := TServiceRegistry.Create(RParent);
  RParent.Register(ICounter, TCounter.Create(9));
  Assert.AreEqual(9, (RChild.Get(ICounter) as ICounter).Value);
end;

procedure TServicesTests.Child_Shadows_Parent;
var
  RParent, RChild: IServiceRegistry;
begin
  RParent := TServiceRegistry.Create(nil);
  RChild := TServiceRegistry.Create(RParent);
  RParent.Register(ICounter, TCounter.Create(1));
  RChild.Register(ICounter, TCounter.Create(2));
  Assert.AreEqual(2, (RChild.Get(ICounter) as ICounter).Value);
  Assert.AreEqual(1, (RParent.Get(ICounter) as ICounter).Value);
end;

procedure TServicesTests.Register_Fires_OnServiceAdded;
var
  R: IServiceRegistry;
  LFired: Boolean;
begin
  LFired := False;
  R := TServiceRegistry.Create(nil);
  R.SetOnServiceAdded(
    procedure(const AGUID: TGUID) begin LFired := True; end);
  R.Register(ICounter, TCounter.Create(0));
  Assert.IsTrue(LFired);
end;

initialization
  TDUnitX.RegisterTestFixture(TServicesTests);

end.
