unit Oasis.Context;

{ The runtime: TOasisContext implements IOasisContext.

  Cordis concepts ported to Delphi:
    - services: named capabilities provided via Provide and resolved via
      Get / Service<T> / ServiceObject<T>
    - inject: hard dependencies hold plugins PENDING until satisfied, unload
      them when a service disappears and reload them when it returns
    - events: emit / bail / serial / parallel / waterfall dispatch modes over
      a flat "namespace/action" event namespace
    - effects: ctx.Effect / ctx.OnDispose / ctx.On / ctx.Plugin / service
      registrations are all reversible; disposers run LIFO on unload
    - fibers: one state machine per mounted plugin instance
    - fork: child contexts inherit service visibility, bubble events upward,
      and keep their own plugins and effects }

interface

uses
  System.SysUtils,
  System.Classes,
  System.Rtti,
  System.TypInfo,
  System.Generics.Collections,
  System.Threading,
  Oasis.Core,
  Oasis.Plugin;

type
  TOasisServiceKind = (skObject, skInterface);

  TOasisServiceEntry = record
    Name: string;
    Kind: TOasisServiceKind;
    Value: TValue;      // TValue.From<TObject> or TValue.From<IInterface> (AddRef'd)
    Provider: TObject;  // TOasisFiber that registered it (bootstrap fiber when nil)
  end;

  TOasisListenerKind = (lkEmit, lkBail, lkWaterfall);

  TOasisListener = record
    Kind: TOasisListenerKind;
    Event: string;
    Emit: TOasisEmitCallback;
    Bail: TOasisBailCallback;
    Waterfall: TOasisWaterfallCallback;
    Owner: TObject;     // owning TOasisFiber, or the bootstrap fiber for context-level
  end;

  TOasisFunctionPlugin = class(TOasisPlugin)
  strict private
    FFn: TProc<IOasisContext>;
  protected
    procedure OnApply(const Ctx: IOasisContext); override;
  public
    constructor Create(const AName: string; const AFn: TProc<IOasisContext>);
  end;

  TOasisFiber = class(TInterfacedObject, IOasisFiber)
  private
    FContext: IOasisContext;
    FParent: TOasisFiber;
    FChildren: TList<TOasisFiber>;
    FPlugin: IOasisPlugin;
    FInject: TList<string>;
    FDisposers: TList<TOasisDisposer>;
    FState: TFiberState;
    FError: Exception;
    function DependenciesMet: Boolean;
    procedure AddInject(const ANames: array of string);
    procedure Load;
    procedure UnloadToPending;
    procedure Unload;
    procedure Detach;
    procedure RunDisposers;
    procedure DisposeChildren;
  public
    constructor Create(const AContext: IOasisContext; const APlugin: IOasisPlugin;
      const AParent: TOasisFiber);
    destructor Destroy; override;
    function GetName: string;
    function GetState: TFiberState;
    function GetError: Exception;
    procedure Dispose;
    property Name: string read GetName;
    property State: TFiberState read GetState;
    property Error: Exception read GetError;
  end;

  TOasisContext = class(TInterfacedObject, IOasisContext)
  private
    FName: string;
    FParent: TOasisContext;
    FChildren: TList<TOasisContext>;
    FChildRefs: TList<IOasisContext>;
    FServices: TList<TOasisServiceEntry>;
    FListeners: TList<TOasisListener>;
    FFibers: TList<TOasisFiber>;
    FFiberRefs: TList<IOasisFiber>;
    FBootstrap: TOasisFiber;
    FLoadingStack: TStack<TOasisFiber>;
    FDisposed: Boolean;
    function FindLocalServiceIndex(const AName: string): Integer;
    function CurrentOwnerFiber: TOasisFiber;
    function CurrentOwnerObj: TObject;
    procedure CheckNotDisposed;
    procedure ProvideService(const AName: string; const AKind: TOasisServiceKind;
      const AValue: TValue);
    procedure BindServiceRemoval(const AName: string);
    procedure RemoveService(const AName: string);
    procedure UnloadDependents(const AServiceName: string);
    procedure ResumePending;
    procedure RemoveListenersOf(const AOwner: TObject);
    procedure DispatchEmitLocal(const AEvent: string; const AArgs: TOasisArgs);
    function DispatchBail(const AEvent: string; const AArgs: TOasisArgs): TValue;
    procedure CollectWaterfall(const AEvent: string;
      const AList: TList<TOasisWaterfallCallback>);
    procedure PushLoading(const AFiber: TOasisFiber);
    procedure PopLoading;
    procedure RemoveFiber(const AFiber: TOasisFiber);
    procedure DoDispose;
    function MountPlugin(const APlugin: IOasisPlugin;
      const AInject: TArray<string>): TOasisFiber;
  public
    constructor Create(const AName: string = 'root'); overload;
    constructor Create(const AName: string; const AParent: TOasisContext); overload;
    destructor Destroy; override;
    function GetRoot: IOasisContext;
    function GetParent: IOasisContext;
    function GetName: string;
    function GetDisposed: Boolean;
    function GetActivePluginName: string;
    function Plugin(const APlugin: IOasisPlugin): IOasisFiber; overload;
    function Plugin(const AName: string; const AFn: TProc<IOasisContext>): IOasisFiber; overload;
    function Plugin(const AName: string; const AFn: TProc<IOasisContext>;
      const AInject: array of string): IOasisFiber; overload;
    procedure Provide(const AName: string; const AService: TObject); overload;
    procedure Provide(const AName: string; const AService: IInterface); overload;
    function Has(const AName: string): Boolean;
    function Get(const AName: string): TValue;
    function ServiceObject(const AName: string): TObject; overload;
    function ServiceInterface(const AName: string): IInterface;
    function Service<T: IInterface>(const AName: string): T; overload;
    function ServiceObject<T: class>(const AName: string): T; overload;
    procedure On(const AEvent: string; const ACallback: TOasisEmitCallback;
      APrepend: Boolean = False); overload;
    procedure On(const AEvent: string; const ACallback: TOasisBailCallback;
      APrepend: Boolean = False); overload;
    procedure On(const AEvent: string; const ACallback: TOasisWaterfallCallback;
      APrepend: Boolean = False); overload;
    procedure Emit(const AEvent: string; const AArgs: TOasisArgs); overload;
    procedure Emit(const AEvent: string; const AArgs: array of const); overload;
    function Bail(const AEvent: string; const AArgs: TOasisArgs): TValue;
    function Serial(const AEvent: string; const AArgs: TOasisArgs): TValue;
    procedure Parallel(const AEvent: string; const AArgs: TOasisArgs);
    function Waterfall(const AEvent: string; const AArgs: TOasisArgs;
      const ADefault: TOasisWaterfallDefault): TValue;
    function Effect(const ASetup: TFunc<TOasisDisposer>): TOasisDisposer;
    procedure OnDispose(const ADisposer: TOasisDisposer);
    function Fork(const AForkName: string = ''): IOasisContext;
    procedure Dispose;
    property Root: IOasisContext read GetRoot;
    property Parent: IOasisContext read GetParent;
    property Name: string read GetName;
    property Disposed: Boolean read GetDisposed;
    property ActivePluginName: string read GetActivePluginName;
  end;

implementation

type
  { Drives a waterfall chain. A real class (rather than a nested routine) so
    anonymous Next continuations can capture it on this compiler generation. }
  TOasisWaterfallRunner = class
  private
    FCallbacks: TList<TOasisWaterfallCallback>;
    FDefault: TOasisWaterfallDefault;
  public
    constructor Create(const AChain: TList<TOasisWaterfallCallback>;
      const ADefault: TOasisWaterfallDefault);
    destructor Destroy; override;
    function Invoke(const AIndex: Integer; const A: TOasisArgs): TValue;
  end;

function RunOne(const ACallback: TOasisEmitCallback; const AArgs: TOasisArgs): TProc;
begin
  // Value-parameter indirection so each task captures its own callback.
  Result := procedure
  begin
    ACallback(AArgs);
  end;
end;

{ TOasisWaterfallRunner }

constructor TOasisWaterfallRunner.Create(const AChain: TList<TOasisWaterfallCallback>;
  const ADefault: TOasisWaterfallDefault);
begin
  inherited Create;
  FCallbacks := AChain;
  FDefault := ADefault;
end;

destructor TOasisWaterfallRunner.Destroy;
begin
  FCallbacks.Free;
  inherited;
end;

function TOasisWaterfallRunner.Invoke(const AIndex: Integer; const A: TOasisArgs): TValue;
begin
  if AIndex > FCallbacks.Count then
    Result := FDefault(A)
  else
    Result := FCallbacks[AIndex - 1](A,
      function(const A2: TOasisArgs): TValue
      begin
        Result := Invoke(AIndex + 1, A2);
      end);
end;

{ TOasisFunctionPlugin }

constructor TOasisFunctionPlugin.Create(const AName: string; const AFn: TProc<IOasisContext>);
begin
  inherited Create(AName);
  FFn := AFn;
end;

procedure TOasisFunctionPlugin.OnApply(const Ctx: IOasisContext);
begin
  if Assigned(FFn) then
    FFn(Ctx);
end;

{ TOasisFiber }

constructor TOasisFiber.Create(const AContext: IOasisContext; const APlugin: IOasisPlugin;
  const AParent: TOasisFiber);
begin
  inherited Create;
  FContext := AContext;
  FPlugin := APlugin;
  FParent := AParent;
  FChildren := TList<TOasisFiber>.Create;
  FInject := TList<string>.Create;
  FDisposers := TList<TOasisDisposer>.Create;
  FState := fsPending;
end;

destructor TOasisFiber.Destroy;
begin
  FChildren.Free;
  FInject.Free;
  FDisposers.Free;
  FError.Free;
  inherited;
end;

function TOasisFiber.GetName: string;
begin
  if FPlugin <> nil then
    Result := FPlugin.PluginName
  else
    Result := '<bootstrap>';
end;

function TOasisFiber.GetState: TFiberState;
begin
  Result := FState;
end;

function TOasisFiber.GetError: Exception;
begin
  Result := FError;
end;

procedure TOasisFiber.AddInject(const ANames: array of string);
var
  S: string;
begin
  for S in ANames do
    if S <> '' then
      FInject.Add(S);
end;

function TOasisFiber.DependenciesMet: Boolean;
var
  S: string;
begin
  if FContext = nil then
    Exit(False);
  for S in FInject do
    if not FContext.Has(S) then
      Exit(False);
  Result := True;
end;

procedure TOasisFiber.Load;
var
  Ctx: IOasisContext;
  CtxObj: TOasisContext;
begin
  if FState <> fsPending then
    Exit;
  FState := fsLoading;
  Ctx := FContext;
  CtxObj := TOasisContext(TObject(Ctx));
  CtxObj.PushLoading(Self);
  try
    try
      FPlugin.Apply(Ctx);
      FState := fsActive;
    except
      on E: Exception do
      begin
        FError := AcquireExceptionObject;
        FState := fsFailed;
        try
          // Unwind whatever Apply managed to register before failing.
          DisposeChildren;
          RunDisposers;
        except
          // Teardown errors are secondary; keep the original failure.
        end;
      end;
    end;
  finally
    CtxObj.PopLoading;
  end;
end;

procedure TOasisFiber.DisposeChildren;
begin
  while FChildren.Count > 0 do
    FChildren[FChildren.Count - 1].Dispose;
end;

procedure TOasisFiber.RunDisposers;
var
  I: Integer;
  FirstError: Exception;
begin
  FirstError := nil;
  for I := FDisposers.Count - 1 downto 0 do
  begin
    try
      FDisposers[I]();
    except
      on E: Exception do
        if FirstError = nil then
          FirstError := AcquireExceptionObject;
    end;
  end;
  FDisposers.Clear;
  if FirstError <> nil then
    raise FirstError;
end;

procedure TOasisFiber.UnloadToPending;
begin
  if FState <> fsActive then
    Exit;
  FState := fsUnloading;
  try
    if FPlugin <> nil then
      FPlugin.OnUnload(FContext);
    DisposeChildren;
    RunDisposers;
    if FContext <> nil then
      TOasisContext(TObject(FContext)).RemoveListenersOf(Self);
  finally
    FState := fsPending;
  end;
end;

procedure TOasisFiber.Unload;
begin
  if FState in [fsUnloading, fsDisposed] then
    Exit;
  if FState = fsLoading then
    Exit; // disposing a fiber from inside its own Apply is not supported
  try
    if FState = fsActive then
    begin
      FState := fsUnloading;
      if FPlugin <> nil then
        FPlugin.OnUnload(FContext);
      DisposeChildren;
      RunDisposers;
      if FContext <> nil then
        TOasisContext(TObject(FContext)).RemoveListenersOf(Self);
    end;
  finally
    FState := fsDisposed;
    Detach;
  end;
end;

procedure TOasisFiber.Detach;
begin
  if FContext <> nil then
  begin
    TOasisContext(TObject(FContext)).RemoveFiber(Self);
    if FParent <> nil then
      FParent.FChildren.Remove(Self);
    FContext := nil;
    FParent := nil;
  end;
end;

procedure TOasisFiber.Dispose;
begin
  // Keep Self alive: Detach may drop the last owning reference.
  _AddRef;
  try
    Unload;
  finally
    _Release;
  end;
end;

{ TOasisContext }

constructor TOasisContext.Create(const AName: string);
begin
  inherited Create;
  FName := AName;
  FChildren := TList<TOasisContext>.Create;
  FChildRefs := TList<IOasisContext>.Create;
  FServices := TList<TOasisServiceEntry>.Create;
  FListeners := TList<TOasisListener>.Create;
  FFibers := TList<TOasisFiber>.Create;
  FFiberRefs := TList<IOasisFiber>.Create;
  FLoadingStack := TStack<TOasisFiber>.Create;
  FBootstrap := TOasisFiber.Create(nil, nil, nil);
  FBootstrap.FState := fsActive;
end;

constructor TOasisContext.Create(const AName: string; const AParent: TOasisContext);
begin
  Create(AName);
  FParent := AParent;
end;

destructor TOasisContext.Destroy;
begin
  if not FDisposed then
    DoDispose;
  FBootstrap.Free;
  FLoadingStack.Free;
  FFiberRefs.Free;
  FFibers.Free;
  FListeners.Free;
  FServices.Free;
  FChildRefs.Free;
  FChildren.Free;
  inherited;
end;

function TOasisContext.GetRoot: IOasisContext;
var
  C: TOasisContext;
begin
  C := Self;
  while C.FParent <> nil do
    C := C.FParent;
  Result := C;
end;

function TOasisContext.GetParent: IOasisContext;
begin
  Result := FParent;
end;

function TOasisContext.GetName: string;
begin
  Result := FName;
end;

function TOasisContext.GetDisposed: Boolean;
begin
  Result := FDisposed;
end;

function TOasisContext.GetActivePluginName: string;
begin
  if FLoadingStack.Count > 0 then
    Result := FLoadingStack.Peek.Name
  else
    Result := '';
end;

procedure TOasisContext.CheckNotDisposed;
begin
  if FDisposed then
    raise EOasisError.CreateFmt('Context "%s" is disposed', [FName]);
end;

function TOasisContext.CurrentOwnerFiber: TOasisFiber;
begin
  if FLoadingStack.Count > 0 then
    Result := FLoadingStack.Peek
  else
    Result := nil;
end;

function TOasisContext.CurrentOwnerObj: TObject;
var
  F: TOasisFiber;
begin
  F := CurrentOwnerFiber;
  if F <> nil then
    Result := F
  else
    Result := FBootstrap;
end;

procedure TOasisContext.PushLoading(const AFiber: TOasisFiber);
begin
  FLoadingStack.Push(AFiber);
end;

procedure TOasisContext.PopLoading;
begin
  FLoadingStack.Pop;
end;

function TOasisContext.MountPlugin(const APlugin: IOasisPlugin;
  const AInject: TArray<string>): TOasisFiber;
var
  Parent: TOasisFiber;
begin
  CheckNotDisposed;
  if APlugin = nil then
    raise EOasisError.Create('Cannot mount a nil plugin');
  Parent := CurrentOwnerFiber;
  Result := TOasisFiber.Create(Self, APlugin, Parent);
  Result.AddInject(APlugin.Inject);
  Result.AddInject(AInject);
  FFibers.Add(Result);
  FFiberRefs.Add(Result);
  if Parent <> nil then
    Parent.FChildren.Add(Result);
  if Result.DependenciesMet then
    Result.Load;
end;

function TOasisContext.Plugin(const APlugin: IOasisPlugin): IOasisFiber;
begin
  Result := MountPlugin(APlugin, APlugin.Inject);
end;

function TOasisContext.Plugin(const AName: string; const AFn: TProc<IOasisContext>): IOasisFiber;
begin
  Result := MountPlugin(TOasisFunctionPlugin.Create(AName, AFn), nil);
end;

function TOasisContext.Plugin(const AName: string; const AFn: TProc<IOasisContext>;
  const AInject: array of string): IOasisFiber;
var
  Names: TArray<string>;
  I: Integer;
begin
  SetLength(Names, Length(AInject));
  for I := 0 to High(AInject) do
    Names[I] := AInject[I];
  Result := MountPlugin(TOasisFunctionPlugin.Create(AName, AFn), Names);
end;

procedure TOasisContext.ProvideService(const AName: string;
  const AKind: TOasisServiceKind; const AValue: TValue);
var
  Entry: TOasisServiceEntry;
begin
  if AName = '' then
    raise EOasisError.Create('Service name must not be empty');
  if FindLocalServiceIndex(AName) >= 0 then
    raise EOasisError.CreateFmt('Service "%s" is already provided in context "%s"',
      [AName, FName]);
  Entry.Name := AName;
  Entry.Kind := AKind;
  Entry.Value := AValue;
  Entry.Provider := CurrentOwnerObj;
  FServices.Add(Entry);
  BindServiceRemoval(AName);
  ResumePending;
end;

procedure TOasisContext.Provide(const AName: string; const AService: TObject);
begin
  CheckNotDisposed;
  if AService = nil then
    raise EOasisError.CreateFmt('Cannot provide nil service "%s"', [AName]);
  ProvideService(AName, skObject, TValue.From<TObject>(AService));
end;

procedure TOasisContext.Provide(const AName: string; const AService: IInterface);
begin
  CheckNotDisposed;
  if AService = nil then
    raise EOasisError.CreateFmt('Cannot provide nil service "%s"', [AName]);
  // TValue does not manage interface references on this compiler generation.
  AService._AddRef;
  ProvideService(AName, skInterface, TValue.From<IInterface>(AService));
end;

procedure TOasisContext.BindServiceRemoval(const AName: string);
begin
  Effect(
    function: TOasisDisposer
    begin
      Result := procedure
      begin
        RemoveService(AName);
      end;
    end);
end;

procedure TOasisContext.RemoveService(const AName: string);
var
  Idx: Integer;
  Entry: TOasisServiceEntry;
  Disposable: IOasisDisposable;
  Intf: IInterface;
begin
  Idx := FindLocalServiceIndex(AName);
  if Idx < 0 then
    Exit;
  Entry := FServices[Idx];
  FServices.Delete(Idx);
  UnloadDependents(AName);
  case Entry.Kind of
    skObject:
      if Supports(Entry.Value.AsObject, IOasisDisposable, Disposable) then
        Disposable.Dispose;
    skInterface:
      begin
        Intf := Entry.Value.AsType<IInterface>;
        if Supports(Intf, IOasisDisposable, Disposable) then
          Disposable.Dispose;
        Intf._Release;
      end;
  end;
end;

procedure TOasisContext.UnloadDependents(const AServiceName: string);
var
  I: Integer;
begin
  for I := 0 to FFibers.Count - 1 do
    if (FFibers[I].State = fsActive) and FFibers[I].FInject.Contains(AServiceName) then
      FFibers[I].UnloadToPending;
end;

procedure TOasisContext.ResumePending;
var
  I: Integer;
begin
  I := 0;
  while I < FFibers.Count do
  begin
    if (FFibers[I].State = fsPending) and FFibers[I].DependenciesMet then
      FFibers[I].Load;
    Inc(I);
  end;
end;

function TOasisContext.FindLocalServiceIndex(const AName: string): Integer;
var
  I: Integer;
begin
  for I := 0 to FServices.Count - 1 do
    if FServices[I].Name = AName then
      Exit(I);
  Result := -1;
end;

function TOasisContext.Has(const AName: string): Boolean;
var
  C: TOasisContext;
begin
  C := Self;
  while C <> nil do
  begin
    if C.FindLocalServiceIndex(AName) >= 0 then
      Exit(True);
    C := C.FParent;
  end;
  Result := False;
end;

function TOasisContext.Get(const AName: string): TValue;
var
  C: TOasisContext;
  Idx: Integer;
begin
  C := Self;
  while C <> nil do
  begin
    Idx := C.FindLocalServiceIndex(AName);
    if Idx >= 0 then
      Exit(C.FServices[Idx].Value);
    C := C.FParent;
  end;
  Result := TValue.Empty;
end;

function TOasisContext.ServiceObject(const AName: string): TObject;
var
  V: TValue;
begin
  V := Get(AName);
  if V.IsEmpty then
    Result := nil
  else
    Result := V.AsObject;
end;

function TOasisContext.ServiceInterface(const AName: string): IInterface;
var
  V: TValue;
begin
  V := Get(AName);
  if V.IsEmpty then
    Result := nil
  else if V.IsObject then
  begin
    if not Supports(V.AsObject, IInterface, Result) then
      Result := nil;
  end
  else
    Result := V.AsType<IInterface>;
end;

function TOasisContext.Service<T>(const AName: string): T;
var
  Intf: IInterface;
begin
  Intf := ServiceInterface(AName);
  if Intf = nil then
    Result := nil
  else if Intf.QueryInterface(GetTypeData(TypeInfo(T)).Guid, Result) <> 0 then
    Result := nil;
end;

function TOasisContext.ServiceObject<T>(const AName: string): T;
var
  V: TValue;
begin
  V := Get(AName);
  if V.IsEmpty then
    Result := nil
  else
    Result := T(V.AsObject);
end;

procedure TOasisContext.On(const AEvent: string; const ACallback: TOasisEmitCallback;
  APrepend: Boolean);
var
  L: TOasisListener;
begin
  CheckNotDisposed;
  if AEvent = '' then
    raise EOasisError.Create('Event name must not be empty');
  L.Kind := lkEmit;
  L.Event := AEvent;
  L.Emit := ACallback;
  L.Bail := nil;
  L.Waterfall := nil;
  L.Owner := CurrentOwnerObj;
  if APrepend then
    FListeners.Insert(0, L)
  else
    FListeners.Add(L);
end;

procedure TOasisContext.On(const AEvent: string; const ACallback: TOasisBailCallback;
  APrepend: Boolean);
var
  L: TOasisListener;
begin
  CheckNotDisposed;
  if AEvent = '' then
    raise EOasisError.Create('Event name must not be empty');
  L.Kind := lkBail;
  L.Event := AEvent;
  L.Emit := nil;
  L.Bail := ACallback;
  L.Waterfall := nil;
  L.Owner := CurrentOwnerObj;
  if APrepend then
    FListeners.Insert(0, L)
  else
    FListeners.Add(L);
end;

procedure TOasisContext.On(const AEvent: string; const ACallback: TOasisWaterfallCallback;
  APrepend: Boolean);
var
  L: TOasisListener;
begin
  CheckNotDisposed;
  if AEvent = '' then
    raise EOasisError.Create('Event name must not be empty');
  L.Kind := lkWaterfall;
  L.Event := AEvent;
  L.Emit := nil;
  L.Bail := nil;
  L.Waterfall := ACallback;
  L.Owner := CurrentOwnerObj;
  if APrepend then
    FListeners.Insert(0, L)
  else
    FListeners.Add(L);
end;

procedure TOasisContext.RemoveListenersOf(const AOwner: TObject);
var
  I: Integer;
begin
  for I := FListeners.Count - 1 downto 0 do
    if FListeners[I].Owner = AOwner then
      FListeners.Delete(I);
end;

procedure TOasisContext.DispatchEmitLocal(const AEvent: string; const AArgs: TOasisArgs);
var
  I: Integer;
begin
  for I := 0 to FListeners.Count - 1 do
    if (FListeners[I].Event = AEvent) and (FListeners[I].Kind = lkEmit) then
      FListeners[I].Emit(AArgs);
end;

procedure TOasisContext.Emit(const AEvent: string; const AArgs: TOasisArgs);
var
  C: TOasisContext;
begin
  C := Self;
  while C <> nil do
  begin
    C.DispatchEmitLocal(AEvent, AArgs);
    C := C.FParent;
  end;
end;

procedure TOasisContext.Emit(const AEvent: string; const AArgs: array of const);
begin
  Emit(AEvent, OasisArgs(AArgs));
end;

function TOasisContext.DispatchBail(const AEvent: string; const AArgs: TOasisArgs): TValue;
var
  C: TOasisContext;
  I: Integer;
  V: TValue;
begin
  C := Self;
  while C <> nil do
  begin
    for I := 0 to C.FListeners.Count - 1 do
      if (C.FListeners[I].Event = AEvent) and (C.FListeners[I].Kind = lkBail) then
      begin
        V := C.FListeners[I].Bail(AArgs);
        if OasisIsTruthy(V) then
          Exit(V);
      end;
    C := C.FParent;
  end;
  Result := TValue.Empty;
end;

function TOasisContext.Bail(const AEvent: string; const AArgs: TOasisArgs): TValue;
begin
  Result := DispatchBail(AEvent, AArgs);
end;

function TOasisContext.Serial(const AEvent: string; const AArgs: TOasisArgs): TValue;
begin
  Result := DispatchBail(AEvent, AArgs);
end;

procedure TOasisContext.Parallel(const AEvent: string; const AArgs: TOasisArgs);
var
  Tasks: TArray<ITask>;
  Callbacks: TArray<TOasisEmitCallback>;
  I: Integer;
  N: Integer;
begin
  N := 0;
  for I := 0 to FListeners.Count - 1 do
    if (FListeners[I].Event = AEvent) and (FListeners[I].Kind = lkEmit) then
      Inc(N);
  SetLength(Tasks, N);
  SetLength(Callbacks, N);
  N := 0;
  for I := 0 to FListeners.Count - 1 do
    if (FListeners[I].Event = AEvent) and (FListeners[I].Kind = lkEmit) then
    begin
      Callbacks[N] := FListeners[I].Emit;
      Tasks[N] := TTask.Run(RunOne(Callbacks[N], AArgs));
      Inc(N);
    end;
  try
    TTask.WaitForAll(Tasks);
  except
    on E: EAggregateException do
      raise EOasisError.CreateFmt('Parallel dispatch of "%s" failed: %s',
        [AEvent, E.Message]);
  end;
end;

procedure TOasisContext.CollectWaterfall(const AEvent: string;
  const AList: TList<TOasisWaterfallCallback>);
var
  I: Integer;
begin
  for I := 0 to FListeners.Count - 1 do
    if (FListeners[I].Event = AEvent) and (FListeners[I].Kind = lkWaterfall) then
      AList.Add(FListeners[I].Waterfall);
end;

function TOasisContext.Waterfall(const AEvent: string; const AArgs: TOasisArgs;
  const ADefault: TOasisWaterfallDefault): TValue;
var
  Chain: TList<TOasisWaterfallCallback>;
  Runner: TOasisWaterfallRunner;
  C: TOasisContext;
begin
  if not Assigned(ADefault) then
    raise EOasisError.CreateFmt('Waterfall "%s" requires a default callback', [AEvent]);
  Chain := TList<TOasisWaterfallCallback>.Create;
  Runner := TOasisWaterfallRunner.Create(Chain, ADefault);
  try
    C := Self;
    while C <> nil do
    begin
      C.CollectWaterfall(AEvent, Chain);
      C := C.FParent;
    end;
    Result := Runner.Invoke(1, AArgs);
  finally
    Runner.Free; // frees Chain
  end;
end;

function TOasisContext.Effect(const ASetup: TFunc<TOasisDisposer>): TOasisDisposer;
var
  Owner: TOasisFiber;
  Disposer: TOasisDisposer;
begin
  CheckNotDisposed;
  if not Assigned(ASetup) then
    raise EOasisError.Create('ctx.Effect requires a setup callback');
  Owner := CurrentOwnerFiber;
  if Owner = nil then
    Owner := FBootstrap;
  Disposer := ASetup();
  if Assigned(Disposer) then
    Owner.FDisposers.Add(Disposer);
  Result := procedure
  begin
    if Owner.FDisposers.Remove(Disposer) >= 0 then
      Disposer();
  end;
end;

procedure TOasisContext.OnDispose(const ADisposer: TOasisDisposer);
begin
  Effect(
    function: TOasisDisposer
    begin
      Result := ADisposer;
    end);
end;

function TOasisContext.Fork(const AForkName: string): IOasisContext;
var
  Child: TOasisContext;
  ChildName: string;
begin
  CheckNotDisposed;
  ChildName := AForkName;
  if ChildName = '' then
    ChildName := FName + '/fork/' + IntToStr(FChildren.Count + 1);
  Child := TOasisContext.Create(ChildName, Self);
  FChildren.Add(Child);
  FChildRefs.Add(Child);
  Result := Child;
end;

procedure TOasisContext.Dispose;
begin
  DoDispose;
end;

procedure TOasisContext.DoDispose;
var
  I: Integer;
begin
  if FDisposed then
    Exit;
  FDisposed := True;
  for I := FChildren.Count - 1 downto 0 do
    FChildren[I].DoDispose;
  while FFibers.Count > 0 do
    FFibers[FFibers.Count - 1].Dispose;
  FBootstrap.RunDisposers;
  RemoveListenersOf(FBootstrap);
  FChildRefs.Clear;
  FChildren.Clear;
  FParent := nil;
end;

procedure TOasisContext.RemoveFiber(const AFiber: TOasisFiber);
begin
  FFibers.Remove(AFiber);
  FFiberRefs.Remove(AFiber);
end;

end.
