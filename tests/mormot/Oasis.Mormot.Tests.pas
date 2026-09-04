unit Oasis.Mormot.Tests;

{ Task 7: mORMot2 forward-bridge tests (spec 5.2 / 7.2). Standalone runner
  (tests/mormot/) requiring a local mormot2 checkout on the compiler path -
  deliberately NOT part of the mormot-free core suite (tests/Oasis.Tests.dpr).
  Leak backstop: ReportMemoryLeaksOnShutdown in the .dpr. }

interface

uses
  DUnitX.TestFramework, System.SysUtils,
  Oasis.Types, Oasis.Errors, Oasis.Services, Oasis.Inject, Oasis.Context,
  Oasis.Plugin, Oasis.Loader, Oasis.Host, Oasis.Mormot,
  mormot.core.base, mormot.core.interfaces;

type
  IMormotCalc = interface
    ['{33333333-0000-0000-0000-000000000001}']
    function Add(A, B: Integer): Integer;
  end;

  TMormotCalcImpl = class(TInterfacedObject, IMormotCalc)
  public
    function Add(A, B: Integer): Integer;
  end;

  IMormotClock = interface
    ['{33333333-0000-0000-0000-000000000002}']
    function Tick: Integer;
  end;

  { 计数新建次数（transient 类注册用）。注意：mORMot 对普通 TInterfacedObject
    后代的类注册走 _New_Object → TClass.Create（静态绑定 TObject.Create），
    自定义 constructor 体不会执行——计数钩子必须放在 NewInstance（虚方法，
    经 VMT 分派，构造必经之路）。 }
  TMormotClockImpl = class(TInterfacedObject, IMormotClock)
  public
    class var Creates: Integer;
    class function NewInstance: TObject; override;
    function Tick: Integer;
  end;
  CalcConsumerPlugin = class(TOasisPlugin)
  strict private
    [Inject] FCalc: IMormotCalc;
  public
    constructor Create;
    procedure Apply(const Ctx: IContext); override;
    function SumViaField(A, B: Integer): Integer;
    function FieldAssigned: Boolean;
  end;

  [TestFixture]
  TMormotBridgeTests = class
  public
    [Test] procedure Shared_Instance_Mirror_Resolves;
    [Test] procedure Transient_Class_Mirror_New_Every_Resolve;
    [Test] procedure Unload_Bridge_Cascades_Consumer;
    [Test] procedure Resolve_Failure_Raises_FactoryError;
    [Test] procedure Repeated_Resolve_No_Refcount_Leak;
    [Test] procedure OwnsResolver_True_Frees_Container;
    [Test] procedure OwnsResolver_False_Keeps_Container;
  end;

implementation

function TMormotCalcImpl.Add(A, B: Integer): Integer;
begin
  Result := A + B;
end;

class function TMormotClockImpl.NewInstance: TObject;
begin
  Inc(Creates);
  Result := inherited NewInstance;
end;

function TMormotClockImpl.Tick: Integer;
begin
  Result := Creates;
end;

constructor CalcConsumerPlugin.Create;
begin
  inherited Create('calc-consumer');
end;

procedure CalcConsumerPlugin.Apply(const Ctx: IContext);
begin
  if FCalc = nil then
    raise EOasisError.Create('calc not injected');
end;

function CalcConsumerPlugin.SumViaField(A, B: Integer): Integer;
begin
  Result := FCalc.Add(A, B);
end;

function CalcConsumerPlugin.FieldAssigned: Boolean;
begin
  Result := FCalc <> nil;
end;

procedure TMormotBridgeTests.Shared_Instance_Mirror_Resolves;
var
  Host: THost;
  List: TInterfaceResolverList;
  P: CalcConsumerPlugin;
begin
  Host := THost.Create;
  try
    List := TInterfaceResolverList.Create;
    List.Add(TypeInfo(IMormotCalc), TMormotCalcImpl.Create);
    Host.Mount(TMormotServicesPlugin.Create(List,
      [TypeInfo(IMormotCalc)], {AOwnsResolver=}True));
    P := CalcConsumerPlugin.Create;
    Host.Mount(P);
    Host.Start;
    Assert.AreEqual(7, P.SumViaField(3, 4));
    Host.Shutdown;
  finally
    Host.Free;
  end;
end;

procedure TMormotBridgeTests.Transient_Class_Mirror_New_Every_Resolve;
var
  Ctx: IContext;
  List: TInterfaceResolverList;
  Bridge: TMormotServicesPlugin;
  A, B: IInterface;
begin
  TMormotClockImpl.Creates := 0;
  Ctx := TContext.Create('t');
  List := TInterfaceResolverList.Create;
  List.Add(TypeInfo(IMormotClock), TMormotClockImpl);
  { 桥对象保活到 Ctx.Dispose 之后：解析闭包捕获 resolver（对象引用），而
    AOwnsResolver=True 的析构会释放 List——注册条目随 Ctx.Dispose 先释放，
    再 Free 桥，顺序安全（brief 更正版，以此为准）。 }
  Bridge := TMormotServicesPlugin.Create(List, [TypeInfo(IMormotClock)], True);
  Bridge.Apply(Ctx);
  A := Ctx.Services.Get(IMormotClock);
  B := Ctx.Services.Get(IMormotClock);
  Assert.AreEqual(2, TMormotClockImpl.Creates);
  Assert.IsFalse(A = B);
  Ctx.Dispose;
  Bridge.Free;
end;

procedure TMormotBridgeTests.Unload_Bridge_Cascades_Consumer;
var
  Host: THost;
  List: TInterfaceResolverList;
  P: CalcConsumerPlugin;
begin
  Host := THost.Create;
  try
    List := TInterfaceResolverList.Create;
    List.Add(TypeInfo(IMormotCalc), TMormotCalcImpl.Create);
    Host.Mount(TMormotServicesPlugin.Create(List, [TypeInfo(IMormotCalc)], True));
    P := CalcConsumerPlugin.Create;
    Host.Mount(P);
    Host.Start;
    Assert.IsTrue(P.FieldAssigned);
    Host.Root.Unload('mormot-services');
    Assert.IsFalse(P.FieldAssigned);   { 级联去活 → 字段清空 }
    Host.Shutdown;
  finally
    Host.Free;
  end;
end;

procedure TMormotBridgeTests.Resolve_Failure_Raises_FactoryError;
var
  Ctx: IContext;
  List: TInterfaceResolverList;
  Bridge: TMormotServicesPlugin;
begin
  Ctx := TContext.Create('t');
  List := TInterfaceResolverList.Create;   { 空容器：什么都解析不到 }
  Bridge := TMormotServicesPlugin.Create(List, [TypeInfo(IMormotCalc)], True);
  Bridge.Apply(Ctx);
  Assert.WillRaise(
    procedure var X: IInterface; begin X := Ctx.Services.Get(IMormotCalc); end,
    EOasisServiceFactoryError);
  Ctx.Dispose;
  Bridge.Free;
end;

procedure TMormotBridgeTests.Repeated_Resolve_No_Refcount_Leak;
var
  Ctx: IContext;
  List: TInterfaceResolverList;
  Bridge: TMormotServicesPlugin;
  I: Integer;
  X: IInterface;
begin
  { 共享实例连续解析 N 次：接收即接管纪律下计数恒平衡（泄漏兜底靠
    ReportMemoryLeaksOnShutdown，本用例验证行为不炸） }
  Ctx := TContext.Create('t');
  List := TInterfaceResolverList.Create;
  List.Add(TypeInfo(IMormotCalc), TMormotCalcImpl.Create);
  Bridge := TMormotServicesPlugin.Create(List, [TypeInfo(IMormotCalc)], True);
  Bridge.Apply(Ctx);
  for I := 1 to 5 do
    X := Ctx.Services.Get(IMormotCalc);
  X := nil;
  Ctx.Dispose;
  Bridge.Free;
end;

procedure TMormotBridgeTests.OwnsResolver_True_Frees_Container;
var
  List: TInterfaceResolverList;
  Bridge: TMormotServicesPlugin;
begin
  List := TInterfaceResolverList.Create;
  Bridge := TMormotServicesPlugin.Create(List, [TypeInfo(IMormotCalc)], True);
  Bridge.Free;   { 若未释放 List，ReportMemoryLeaksOnShutdown 报 TInterfaceResolverList 泄漏 }
  Assert.Pass;
end;

procedure TMormotBridgeTests.OwnsResolver_False_Keeps_Container;
var
  List: TInterfaceResolverList;
  Bridge: TMormotServicesPlugin;
begin
  List := TInterfaceResolverList.Create;
  Bridge := TMormotServicesPlugin.Create(List, [TypeInfo(IMormotCalc)], False);
  Bridge.Free;
  List.Free;   { 调用方自己释放——若桥误释放，此处 double-free 炸 }
  Assert.Pass;
end;

initialization
  TDUnitX.RegisterTestFixture(TMormotBridgeTests);

end.
