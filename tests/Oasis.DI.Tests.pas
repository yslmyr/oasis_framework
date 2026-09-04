unit Oasis.DI.Tests;

{ DI tests: [Inject] field primitives (Task 1), plugin declaration merge
  (Task 2), context hooks (Task 3), factory lifetimes (Tasks 4-5),
  host-level activation semantics (Task 6). All OTL-free / mormot-free. }

interface

uses
  DUnitX.TestFramework, System.SysUtils,
  Oasis.Types, Oasis.Errors, Oasis.Services, Oasis.Inject, Oasis.Context,
  Oasis.Plugin, Oasis.Effects;

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

  { Task 2: declaration-merge fixtures (manual AddInject ∪ [Inject] fields). }
  MergePlugin = class(TOasisPlugin)
  strict private
    [Inject] FGreet: IGreetService;
  public
    constructor Create;
  end;

  ManualOnlyPlugin = class(TOasisPlugin)
  public
    constructor Create;
  end;

  { Task 3: context-hook fixtures (populate-before-Apply, clear-on-teardown). }
  FieldConsumerPlugin = class(TOasisPlugin)
  strict private
    [Inject] FGreet: IGreetService;
  public
    constructor Create;
    procedure Apply(const Ctx: IContext); override;
    function GreetFromField: string;
    function FieldAssigned: Boolean;
  end;

  FailingApplyPlugin = class(TOasisPlugin)
  strict private
    [Inject] FGreet: IGreetService;
  public
    constructor Create;
    procedure Apply(const Ctx: IContext); override;
    function FieldAssigned: Boolean;
  end;

  { Closure-to-IPlugin adapter (Task 3 tests). }
  TAnonymousPlugin = class(TInterfacedObject, IPlugin)
  strict private
    FName: string;
    FApply: TProc<IContext>;
  public
    constructor Create(const AName: string; const AApply: TProc<IContext>);
    function PluginName: string;
    function Inject: TArray<TGUID>;
    procedure Apply(const Ctx: IContext);
  end;

  [TestFixture]
  TContextHookTests = class
  public
    [Test] procedure Mount_Fills_Field_Before_Apply;
    [Test] procedure Unload_Clears_Fields;
    [Test] procedure Apply_Failure_Clears_Fields_FsFailed;
    [Test] procedure Reload_Refills_Fields;
    [Test] procedure User_Cleanup_Still_Sees_Field;
    [Test] procedure Closure_Plugin_Unaffected;
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

  [TestFixture]
  TDeclarationMergeTests = class
  public
    [Test] procedure Inject_Merges_Manual_And_Field_Guids;
    [Test] procedure Inject_Result_Is_Cached_And_Stable;
  end;

  [TestFixture]
  TFactoryTests = class
  public
    [Test] procedure Lazy_Builds_Exactly_Once;
    [Test] procedure Factory_Has_True_Immediately_No_Build;
    [Test] procedure Factory_Raise_Not_Memoized_Retry_Works;
    [Test] procedure Overwrite_Latest_Wins_Old_Cleanup_Keeps_New;
    [Test] procedure Parent_Child_Shadowing_With_Factory;
    [Test] procedure Owner_Scope_Dispose_Releases_Factory_And_Memo;
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
  { 手造失配：实例挂在 IOtherService 的 GUID 下，Resolve 命中，
    但 TGreetServiceImpl 不实现 IOtherService，Supports 必然失败
    （spec 7.1-19：注册实例不实现字段接口的分支） }
  R.Register(IOtherService, TGreetServiceImpl.Create);   { 错配：GUID 有了，实例不实现该接口 }
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

{ MergePlugin / ManualOnlyPlugin }

constructor MergePlugin.Create;
begin
  inherited Create('merge');
  AddInject(IOtherService);   { 手动一个 + 字段一个 }
end;

constructor ManualOnlyPlugin.Create;
begin
  inherited Create('manual');
  AddInject(IGreetService);
end;

{ TDeclarationMergeTests }

procedure TDeclarationMergeTests.Inject_Merges_Manual_And_Field_Guids;
var
  P: MergePlugin;
  Guids: TArray<TGUID>;
  I: Integer;
  LOther, LGreet: Boolean;
begin
  P := MergePlugin.Create;
  try
    Guids := P.Inject;
    Assert.AreEqual(2, Length(Guids));
    LOther := False;
    LGreet := False;
    for I := 0 to High(Guids) do
    begin
      if IsEqualGUID(Guids[I], IOtherService) then LOther := True;
      if IsEqualGUID(Guids[I], IGreetService) then LGreet := True;
    end;
    Assert.IsTrue(LOther and LGreet);
  finally
    P.Free;
  end;
end;

procedure TDeclarationMergeTests.Inject_Result_Is_Cached_And_Stable;
var
  P: ManualOnlyPlugin;
begin
  P := ManualOnlyPlugin.Create;
  try
    { 两次调用返回同一缓存数组引用（动态数组指针比较） }
    Assert.IsTrue(Pointer(P.Inject) = Pointer(P.Inject));
  finally
    P.Free;
  end;
end;

{ FieldConsumerPlugin / FailingApplyPlugin / TAnonymousPlugin }

constructor FieldConsumerPlugin.Create;
begin
  inherited Create('field-consumer');
end;

procedure FieldConsumerPlugin.Apply(const Ctx: IContext);
begin
  { Apply 执行期间字段必须已填充 }
  if FGreet = nil then
    raise EOasisError.Create('field not populated during Apply');
end;

function FieldConsumerPlugin.GreetFromField: string;
begin
  Result := FGreet.Greet('ctx');
end;

function FieldConsumerPlugin.FieldAssigned: Boolean;
begin
  Result := FGreet <> nil;
end;

constructor FailingApplyPlugin.Create;
begin
  inherited Create('failing');
end;

procedure FailingApplyPlugin.Apply(const Ctx: IContext);
begin
  raise EOasisError.Create('boom');
end;

function FailingApplyPlugin.FieldAssigned: Boolean;
begin
  Result := FGreet <> nil;
end;

constructor TAnonymousPlugin.Create(const AName: string; const AApply: TProc<IContext>);
begin
  inherited Create;
  FName := AName;
  FApply := AApply;
end;

function TAnonymousPlugin.PluginName: string;
begin
  Result := FName;
end;

function TAnonymousPlugin.Inject: TArray<TGUID>;
begin
  Result := nil;
end;

procedure TAnonymousPlugin.Apply(const Ctx: IContext);
begin
  FApply(Ctx);
end;

{ TContextHookTests }

procedure TContextHookTests.Mount_Fills_Field_Before_Apply;
var
  Ctx: IContext;
  P: FieldConsumerPlugin;
begin
  Ctx := TContext.Create('t');
  P := FieldConsumerPlugin.Create;
  Ctx.Services.Register(IGreetService, TGreetServiceImpl.Create);
  Ctx.Plugin(P);
  Assert.IsTrue(P.FieldAssigned);
  Assert.AreEqual(fsActive, Ctx.PluginState('field-consumer'));
  Assert.AreEqual('Hello, ctx', P.GreetFromField);
  Ctx.Dispose;
end;

procedure TContextHookTests.Unload_Clears_Fields;
var
  Ctx: IContext;
  P: FieldConsumerPlugin;
  PI: IInterface;   { 锚：Unload 删 entry 释放闭包引用，防 use-after-free }
begin
  Ctx := TContext.Create('t');
  P := FieldConsumerPlugin.Create;
  PI := P;
  Ctx.Services.Register(IGreetService, TGreetServiceImpl.Create);
  Ctx.Plugin(P);
  Assert.IsTrue(Ctx.Unload('field-consumer'));
  Assert.IsFalse(P.FieldAssigned);
  Ctx.Dispose;
end;

procedure TContextHookTests.Apply_Failure_Clears_Fields_FsFailed;
var
  Ctx: IContext;
  P: FailingApplyPlugin;
begin
  Ctx := TContext.Create('t');
  P := FailingApplyPlugin.Create;
  Ctx.Services.Register(IGreetService, TGreetServiceImpl.Create);
  Ctx.Plugin(P);   { 失败被吞（fault isolation） }
  Assert.AreEqual(fsFailed, Ctx.PluginState('failing'));
  Assert.IsFalse(P.FieldAssigned);   { 回滚路径也清空 }
  Ctx.Dispose;
end;

procedure TContextHookTests.Reload_Refills_Fields;
var
  Ctx: IContext;
  P: FieldConsumerPlugin;
begin
  Ctx := TContext.Create('t');
  P := FieldConsumerPlugin.Create;
  Ctx.Services.Register(IGreetService, TGreetServiceImpl.Create);
  Ctx.Plugin(P);
  Ctx.Reload('field-consumer');
  Assert.IsTrue(P.FieldAssigned);
  Ctx.Dispose;
end;

procedure TContextHookTests.User_Cleanup_Still_Sees_Field;
var
  Ctx: IContext;
  P: FieldConsumerPlugin;
  SawFieldInCleanup: Boolean;
begin
  SawFieldInCleanup := False;
  Ctx := TContext.Create('t');
  P := FieldConsumerPlugin.Create;
  Ctx.Services.Register(IGreetService, TGreetServiceImpl.Create);
  { Brief deviation (see task-3 report): mount P so its field gets populated,
    and read the field in the RETURNED disposer - TEffectScope.Add runs the
    factory body at mount time and registers Result as the cleanup, so only
    the disposer observes teardown. 'order-check' is disposed first (LIFO),
    before P's fiber Clear runs: the user cleanup still sees the field. }
  Ctx.Plugin(P);
  Ctx.Plugin(
    TAnonymousPlugin.Create('order-check',
      procedure(C: IContext)
      begin
        C.Effect(
          function: TDisposer
          begin
            Result := procedure begin SawFieldInCleanup := P.FieldAssigned; end;
          end);
      end));
  Ctx.Dispose;   { 用户 cleanup 先于 Clear 执行（顺序契约） }
  Assert.IsTrue(SawFieldInCleanup);
end;

procedure TContextHookTests.Closure_Plugin_Unaffected;
var
  Ctx: IContext;
  LRan: Boolean;
begin
  LRan := False;
  Ctx := TContext.Create('t');
  Ctx.Plugin('plain-closure',
    procedure(C: IContext)
    begin
      LRan := C.Services <> nil;
    end);
  Assert.IsTrue(LRan);
  Ctx.Dispose;
end;
{ TFactoryTests }

procedure TFactoryTests.Lazy_Builds_Exactly_Once;
var
  R: IServiceRegistry;
  Builds: Integer;
  A, B: IInterface;
begin
  R := TServiceRegistry.Create(nil);
  Builds := 0;
  R.RegisterFactory(IGreetService,
    function: IInterface
    begin
      Inc(Builds);
      Result := TGreetServiceImpl.Create;
    end);
  A := R.Get(IGreetService);
  B := R.Get(IGreetService);
  Assert.AreEqual(1, Builds);
  Assert.IsTrue(A = B);
end;

procedure TFactoryTests.Factory_Has_True_Immediately_No_Build;
var
  R: IServiceRegistry;
  Builds: Integer;
begin
  R := TServiceRegistry.Create(nil);
  Builds := 0;
  R.RegisterFactory(IGreetService,
    function: IInterface
    begin
      Inc(Builds);
      Result := TGreetServiceImpl.Create;
    end);
  Assert.IsTrue(R.Has(IGreetService));   { Has 绝不触发构建 }
  Assert.AreEqual(0, Builds);
end;

procedure TFactoryTests.Factory_Raise_Not_Memoized_Retry_Works;
var
  R: IServiceRegistry;
  { Brief deviation (capture discipline, see task-4 report): the closures below
    must use the CLASS ref, not IServiceRegistry - all anonymous methods of a
    routine share one $ActRec, so capturing R there would make the stored
    factory closure transitively hold the registry (refcount cycle, leak). }
  Reg: TServiceRegistry;
  Builds: Integer;
begin
  Reg := TServiceRegistry.Create(nil);
  R := Reg;
  Builds := 0;
  R.RegisterFactory(IGreetService,
    function: IInterface
    begin
      Inc(Builds);
      if Builds = 1 then
        raise EOasisServiceFactoryError.Create('first build fails');
      Result := TGreetServiceImpl.Create;
    end);
  Assert.WillRaise(
    procedure var X: IInterface; begin X := Reg.Get(IGreetService); end,
    EOasisServiceFactoryError);
  Assert.WillNotRaise(
    procedure var X: IInterface; begin X := Reg.Get(IGreetService); end);
  Assert.AreEqual(2, Builds);
end;

procedure TFactoryTests.Overwrite_Latest_Wins_Old_Cleanup_Keeps_New;
var
  R: IServiceRegistry;
  Scope1, Scope2: IEffectScope;
  Second: IInterface;
begin
  { scope1 挂工厂 → scope2 以实例覆盖：scope1 的清理因 token 不匹配必须空转，
    新条目保留到 scope2 自己卸载（spec 用例 18 的精确语义） }
  R := TServiceRegistry.Create(nil);
  Scope1 := TEffectScope.Create;
  Scope2 := TEffectScope.Create;
  R.SetOwnerScope(Scope1);
  R.RegisterFactory(IGreetService, function: IInterface
    begin Result := TGreetServiceImpl.Create; end);
  R.SetOwnerScope(Scope2);
  Second := TGreetServiceImpl.Create;
  R.Register(IGreetService, Second);
  R.SetOwnerScope(nil);
  Scope1.Dispose;   { 旧工厂条目的清理不得删掉新条目 }
  Assert.IsTrue(R.Has(IGreetService));
  Assert.IsTrue(R.Get(IGreetService) = Second);
  Scope2.Dispose;   { 新条目自己的清理正常生效 }
  Assert.IsFalse(R.Has(IGreetService));
end;

procedure TFactoryTests.Parent_Child_Shadowing_With_Factory;
var
  RParent, RChild: IServiceRegistry;
begin
  RParent := TServiceRegistry.Create(nil);
  RChild := TServiceRegistry.Create(RParent);
  RParent.RegisterFactory(IGreetService, function: IInterface
    begin Result := TGreetServiceImpl.Create; end);
  RChild.Register(IGreetService, TGreetServiceImpl.Create);
  Assert.IsTrue(RChild.Has(IGreetService));
  Assert.IsTrue(RParent.Has(IGreetService));
  { 子层实例遮蔽父层工厂；父层仍走工厂 }
  Assert.IsFalse(RChild.Get(IGreetService) = RParent.Get(IGreetService));
end;

procedure TFactoryTests.Owner_Scope_Dispose_Releases_Factory_And_Memo;
var
  R: IServiceRegistry;
  Scope: IEffectScope;
begin
  R := TServiceRegistry.Create(nil);
  Scope := TEffectScope.Create;
  R.SetOwnerScope(Scope);
  R.RegisterFactory(IGreetService, function: IInterface
    begin Result := TGreetServiceImpl.Create; end);
  R.Get(IGreetService);   { 触发 memoize }
  Scope.Dispose;
  Assert.IsFalse(R.Has(IGreetService));   { fiber 卸载 → 注册消失 }
end;

initialization
  TDUnitX.RegisterTestFixture(TInjectorTests);
  TDUnitX.RegisterTestFixture(TDeclarationMergeTests);
  TDUnitX.RegisterTestFixture(TContextHookTests);
  TDUnitX.RegisterTestFixture(TFactoryTests);

end.
