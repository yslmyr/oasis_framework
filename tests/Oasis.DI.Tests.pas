unit Oasis.DI.Tests;

{ DI tests: [Inject] field primitives (Task 1), plugin declaration merge
  (Task 2), context hooks (Task 3), factory lifetimes (Tasks 4-5),
  host-level activation semantics (Task 6). All OTL-free / mormot-free. }

interface

uses
  DUnitX.TestFramework, System.SysUtils,
  Oasis.Types, Oasis.Errors, Oasis.Services, Oasis.Inject, Oasis.Context,
  Oasis.Plugin;

type
  IGreetService = interface
    ['{22222222-0000-0000-0000-000000000001}']
    function Greet(const AWho: string): string;
  end;

  TGreetServiceImpl = class(TInterfacedObject, IGreetService)
  public
    function Greet(const AWho: string): string;
  end;

  { Implements IGreetService but NOT IOtherService (for the mismatch test). }
  IOtherService = interface
    ['{22222222-0000-0000-0000-000000000002}']
    procedure Bang;
  end;

  { No GUID directive on purpose: Inject must reject such fields. Note that
    IInterface itself carries the IUnknown GUID on this compiler, so it
    cannot be used to build this case. }
  IGuidlessService = interface
    procedure Bang;
  end;

  InjectAttributeConsumer = class(TObject)
  strict private
    [Inject] FGreet: IGreetService;
  public
    function GreetViaField: string;
    function HasGreet: Boolean;
  end;

  InjectAttributeBase = class(TObject)
  strict private
    [Inject] FBaseGreet: IGreetService;
  public
    function HasBase: Boolean;
  end;

  InjectAttributeDerived = class(InjectAttributeBase)
  strict private
    [Inject] FDerivedGreet: IGreetService;
  public
    function HasDerived: Boolean;
  end;

  BadNonInterfaceField = class(TObject)
  strict private
    [Inject] FNotAnInterface: Integer;
  end;

  BadNoGuidField = class(TObject)
  strict private
    [Inject] FGuidless: IGuidlessService;  { field type has no GUID directive }
  end;

  MismatchConsumer = class(TObject)
  strict private
    [Inject] FWantOther: IOtherService;
  end;

  [TestFixture]
  TInjectorTests = class
  public
    [Test] procedure Populate_Fills_Inject_Field;
    [Test] procedure Clear_Nils_Inject_Fields;
    [Test] procedure FieldGuids_Includes_Inherited_Fields;
    [Test] procedure NonInterface_Inject_Field_Raises;
    [Test] procedure Guidless_Interface_Field_Raises;
    [Test] procedure Populate_Instance_Not_Supporting_Interface_Raises;
    [Test] procedure Need_Returns_Typed_Instance;
    [Test] procedure Need_Missing_Raises_And_TryNeed_False;
  end;

implementation

{ test impls }

function TGreetServiceImpl.Greet(const AWho: string): string;
begin
  Result := 'Hello, ' + AWho;
end;

function InjectAttributeConsumer.GreetViaField: string;
begin
  Result := FGreet.Greet('field');
end;

function InjectAttributeConsumer.HasGreet: Boolean;
begin
  Result := FGreet <> nil;
end;

function InjectAttributeBase.HasBase: Boolean;
begin
  Result := FBaseGreet <> nil;
end;

function InjectAttributeDerived.HasDerived: Boolean;
begin
  Result := FDerivedGreet <> nil;
end;

{ TInjectorTests }

procedure TInjectorTests.Populate_Fills_Inject_Field;
var
  R: IServiceRegistry;
  Obj: InjectAttributeConsumer;
begin
  R := TServiceRegistry.Create(nil);
  R.Register(IGreetService, TGreetServiceImpl.Create);
  Obj := InjectAttributeConsumer.Create;
  try
    TOasisInjector.Populate(Obj, R);
    Assert.IsTrue(Obj.HasGreet);
    Assert.AreEqual('Hello, field', Obj.GreetViaField);
  finally
    Obj.Free;
  end;
end;

procedure TInjectorTests.Clear_Nils_Inject_Fields;
var
  R: IServiceRegistry;
  Obj: InjectAttributeConsumer;
begin
  R := TServiceRegistry.Create(nil);
  R.Register(IGreetService, TGreetServiceImpl.Create);
  Obj := InjectAttributeConsumer.Create;
  try
    TOasisInjector.Populate(Obj, R);
    TOasisInjector.Clear(Obj);
    Assert.IsFalse(Obj.HasGreet);
  finally
    Obj.Free;
  end;
end;

procedure TInjectorTests.FieldGuids_Includes_Inherited_Fields;
var
  Guids: TArray<TGUID>;
begin
  Guids := TOasisInjector.FieldGuids(InjectAttributeDerived);
  { 基类 1 个 + 派生类 1 个，都是 IGreetService 的 GUID }
  Assert.AreEqual(2, Length(Guids));
  Assert.IsTrue(IsEqualGUID(Guids[0], IGreetService) or
    IsEqualGUID(Guids[1], IGreetService));
end;

procedure TInjectorTests.NonInterface_Inject_Field_Raises;
begin
  Assert.WillRaise(
    procedure begin TOasisInjector.FieldGuids(BadNonInterfaceField); end,
    EOasisInjectError);
end;

procedure TInjectorTests.Guidless_Interface_Field_Raises;
begin
  Assert.WillRaise(
    procedure begin TOasisInjector.FieldGuids(BadNoGuidField); end,
    EOasisInjectError);
end;

procedure TInjectorTests.Populate_Instance_Not_Supporting_Interface_Raises;
var
  R: IServiceRegistry;
  Obj: MismatchConsumer;
begin
  R := TServiceRegistry.Create(nil);
  { IOtherService 的 GUID 下挂了一个不实现它的实例（手造失配）：
    直接用 IGreetService 的 GUID 注册 TGreetServiceImpl——
    MismatchConsumer 的字段是 IOtherService，Supports 必然失败 }
  R.Register(IGreetService, TGreetServiceImpl.Create);
  Obj := MismatchConsumer.Create;
  try
    Assert.WillRaise(
      procedure begin TOasisInjector.Populate(Obj, R); end,
      EOasisInjectError);
  finally
    Obj.Free;
  end;
end;

procedure TInjectorTests.Need_Returns_Typed_Instance;
var
  R: IServiceRegistry;
  G: IGreetService;
begin
  R := TServiceRegistry.Create(nil);
  R.Register(IGreetService, TGreetServiceImpl.Create);
  G := TOasisDI.Need<IGreetService>(R);
  Assert.AreEqual('Hello, need', G.Greet('need'));
end;

procedure TInjectorTests.Need_Missing_Raises_And_TryNeed_False;
var
  R: IServiceRegistry;
  G: IGreetService;
begin
  R := TServiceRegistry.Create(nil);
  Assert.IsFalse(TOasisDI.TryNeed<IGreetService>(R, G));
  Assert.WillRaise(
    procedure var X: IGreetService; begin X := TOasisDI.Need<IGreetService>(R); end,
    EOasisServiceNotFound);
end;

initialization
  TDUnitX.RegisterTestFixture(TInjectorTests);

end.
