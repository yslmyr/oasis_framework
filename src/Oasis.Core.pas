unit Oasis.Core;

{ Oasis framework - core contracts (Cordis concepts ported to Delphi).

  This unit holds the contracts every other unit builds on:
    - IOasisContext / IOasisFiber / IOasisPlugin interfaces
    - event callback types and the loosely-typed TOasisArgs payload
    - the fiber state machine (PENDING -> LOADING -> ACTIVE -> UNLOADING -> DISPOSED, + FAILED)
    - disposal helpers

  Design reference: Cordis (https://github.com/cordiverse/cordis)
  "A plugin is an object that implements a service", "a context is a repository
  of services", "typed events for communication", "registrations are reversible
  effects". }

interface

uses
  System.SysUtils,
  System.Rtti,
  System.Generics.Collections;

type
  { Raised for framework contract violations: duplicate service names, mounting
    into a disposed context, empty names, and so on. }
  EOasisError = class(Exception);

  { Raised when a plugin configuration fails schema validation. }
  EOasisConfigError = class(EOasisError);

  { Implemented by resources the runtime should tear down when their provider
    is unloaded (a provided service implementing this is disposed on removal). }
  IOasisDisposable = interface
    ['{8A3E2B1C-5D4F-4E6A-9B7C-1D2E3F4A5B6C}']
    procedure Dispose;
  end;

  { Cleanup callback registered through ctx.Effect / ctx.OnDispose. Runs when
    the owning plugin unloads (LIFO), when it is called manually, or when the
    owning context is disposed. }
  TOasisDisposer = reference to procedure;

  { Lifecycle of one mounted plugin instance - the Cordis "fiber" state machine. }
  TFiberState = (
    fsPending,    // mounted, but a required service is not available yet
    fsLoading,    // Apply is running
    fsActive,     // Apply completed
    fsUnloading,  // teardown (children, disposers, listeners) in progress
    fsFailed,     // Apply or config validation raised
    fsDisposed);  // torn down / removed

  { Event payload: positional arguments, loosely typed (like Cordis args). }
  TOasisArgs = TArray<TValue>;

  { emit: observe in registration order, no return value. }
  TOasisEmitCallback = reference to procedure(const Args: TOasisArgs);

  { bail / serial: return a value; the first truthy result wins and stops the chain. }
  TOasisBailCallback = reference to function(const Args: TOasisArgs): TValue;

  { waterfall continuation: delegate to the next listener (or the emitter's default). }
  TOasisNext = reference to function(const Args: TOasisArgs): TValue;

  { waterfall: around-middleware. Return without calling Next to short-circuit
    (veto); call Next(...) - optionally with modified arguments - to delegate. }
  TOasisWaterfallCallback = reference to function(const Args: TOasisArgs;
    const Next: TOasisNext): TValue;

  { waterfall innermost default supplied by the emitter; runs when no listener
    short-circuits. }
  TOasisWaterfallDefault = reference to function(const Args: TOasisArgs): TValue;

  IOasisPlugin = interface;
  IOasisFiber = interface;

  { The central runtime object (Cordis "Context"): a repository of services, an
    event bus with five dispatch modes, and the plugin lifecycle manager. }
  IOasisContext = interface
    ['{3F6A1B2C-9D4E-4F5A-8B6C-7D1E2F3A4B5C}']
    function GetRoot: IOasisContext;
    function GetParent: IOasisContext;
    function GetName: string;
    function GetDisposed: Boolean;
    function GetActivePluginName: string;

    { Mount a plugin instance. Returns its fiber. If the plugin declares
      required services (Inject) that are missing, it stays PENDING until they
      are provided - load order never matters. The context takes ownership of
      the mounted plugin instance. }
    function Plugin(const APlugin: IOasisPlugin): IOasisFiber; overload;
    { Function form (Cordis function plugin): an anonymous method is the Apply
      body. }
    function Plugin(const AName: string; const AFn: TProc<IOasisContext>): IOasisFiber; overload;
    function Plugin(const AName: string; const AFn: TProc<IOasisContext>;
      const AInject: array of string): IOasisFiber; overload;

    { Register a service under a stable name. Registration is an effect: when
      the providing plugin unloads, the service is removed and every plugin
      that injects it is unloaded (they reload when it returns). Providing
      outside a plugin lifetime attaches to the context itself. }
    procedure Provide(const AName: string; const AService: TObject); overload;
    procedure Provide(const AName: string; const AService: IInterface); overload;

    { Service lookup. Has/Get walk up the fork chain to the root. }
    function Has(const AName: string): Boolean;
    function Get(const AName: string): TValue;
    { Lookups. Return nil when the service is absent (optional dependency
      probe). Cast the result at the use site:
        Greeter := Ctx.ServiceObject('greeter') as TGreeterService;
      (Generic typed lookups Service<T> / ServiceObject<T> live on the
      TOasisContext class; Delphi XE forbids parameterized interface methods.) }
    function ServiceObject(const AName: string): TObject;
    function ServiceInterface(const AName: string): IInterface;

    { Event listeners. The callback kind selects the dispatch mode contract:
      EmitCallback for emit/parallel, BailCallback for bail/serial,
      WaterfallCallback for waterfall. Registrations are effects: they are
      removed automatically when the owning plugin unloads. APrepend runs the
      listener before ordinary registrations. }
    procedure On(const AEvent: string; const ACallback: TOasisEmitCallback;
      APrepend: Boolean = False); overload;
    procedure On(const AEvent: string; const ACallback: TOasisBailCallback;
      APrepend: Boolean = False); overload;
    procedure On(const AEvent: string; const ACallback: TOasisWaterfallCallback;
      APrepend: Boolean = False); overload;

    { emit: synchronous broadcast, listeners run in registration order, return
      values ignored. Events bubble up the fork chain (child -> root). }
    procedure Emit(const AEvent: string; const AArgs: TOasisArgs); overload;
    procedure Emit(const AEvent: string; const AArgs: array of const); overload;

    { bail: synchronous, first truthy return value wins and stops the chain. }
    function Bail(const AEvent: string; const AArgs: TOasisArgs): TValue;
    { serial: awaited in-order variant of bail (synchronous in Delphi). }
    function Serial(const AEvent: string; const AArgs: TOasisArgs): TValue;
    { parallel: every listener runs on a worker thread and the call waits for
      all of them. Listeners must be thread-safe (no VCL UI access). }
    procedure Parallel(const AEvent: string; const AArgs: TOasisArgs);
    { waterfall: around-middleware; see TOasisWaterfallCallback. ADefault is the
      innermost fallback. Returns the outermost listener's result. }
    function Waterfall(const AEvent: string; const AArgs: TOasisArgs;
      const ADefault: TOasisWaterfallDefault): TValue;

    { Wrap an unmanaged resource: ASetup acquires it and returns the disposer
      that releases it. The disposer is registered on the current loading
      plugin (LIFO) and also returned, so the caller may release early by
      invoking it manually. }
    function Effect(const ASetup: TFunc<TOasisDisposer>): TOasisDisposer;
    { Register a disposer directly (no setup step). }
    procedure OnDispose(const ADisposer: TOasisDisposer);

    { Create a child scope. Services resolve up the chain, events bubble up,
      plugins and effects stay local; disposing a parent disposes its children. }
    function Fork(const AForkName: string = ''): IOasisContext;
    { Tear the context down: children first, then plugins (reverse mount
      order), then context-level effects. Idempotent. }
    procedure Dispose;

    property Root: IOasisContext read GetRoot;
    property Parent: IOasisContext read GetParent;
    property Name: string read GetName;
    property Disposed: Boolean read GetDisposed;
    property ActivePluginName: string read GetActivePluginName;
  end;

  { Runtime handle of one mounted plugin instance - the Cordis "fiber". }
  IOasisFiber = interface
    ['{4E7B2C3D-1A5E-4F6B-9C8D-2E3F4A5B6C7D}']
    function GetName: string;
    function GetState: TFiberState;
    function GetError: Exception;
    { Unload the plugin: OnUnload, children, disposers (LIFO), listeners. }
    procedure Dispose;
    property Name: string read GetName;
    property State: TFiberState read GetState;
    { Non-nil when the fiber is fsFailed: the exception from Apply or config validation. }
    property Error: Exception read GetError;
  end;

  { The plugin contract. A plugin declares hard service dependencies with
    InjectServices (or via the Inject array) and implements its lifecycle in
    Apply. }
  IOasisPlugin = interface
    ['{5F8C3D4E-2B6F-4A7C-1D9E-3F4A5B6C7D8E}']
    function PluginName: string;
    function Inject: TArray<string>;
    procedure Apply(const Ctx: IOasisContext);
    procedure OnUnload(const Ctx: IOasisContext);
  end;

{ Build a TOasisArgs array from literals: OasisArgs(['hello', 42]) }
function OasisArgs(const A: array of const): TOasisArgs;
{ Cordis truthiness: non-empty and not false / nil. }
function OasisIsTruthy(const V: TValue): Boolean;
function OasisVarRecToValue(const V: TVarRec): TValue;

implementation

function OasisVarRecToValue(const V: TVarRec): TValue;
begin
  case V.VType of
    vtInteger:        Result := TValue.From<Integer>(V.VInteger);
    vtBoolean:        Result := TValue.From<Boolean>(V.VBoolean);
    vtChar:           Result := TValue.From<AnsiChar>(V.VChar);
    vtWideChar:       Result := TValue.From<WideChar>(V.VWideChar);
    vtExtended:       Result := TValue.From<Extended>(V.VExtended^);
    vtString:         Result := TValue.From<string>(string(V.VString^));
    vtAnsiString:     Result := TValue.From<string>(string(AnsiString(V.VAnsiString)));
    vtPChar:          Result := TValue.From<string>(string(V.VPChar));
    vtPWideChar:      Result := TValue.From<string>(string(V.VPWideChar));
    vtObject:         Result := TValue.From<TObject>(V.VObject);
    vtClass:          Result := TValue.From<TClass>(V.VClass);
    vtInt64:          Result := TValue.From<Int64>(V.VInt64^);
    vtUnicodeString:  Result := TValue.From<string>(string(V.VUnicodeString));
    vtCurrency:       Result := TValue.From<Currency>(V.VCurrency^);
    vtInterface:      Result := TValue.From<IInterface>(IInterface(V.VInterface));
    vtPointer:        Result := TValue.From<Pointer>(V.VPointer);
  else
    // vtVariant and friends are not supported as event args.
    Result := TValue.Empty;
  end;
end;

function OasisArgs(const A: array of const): TOasisArgs;
var
  I: Integer;
begin
  SetLength(Result, Length(A));
  for I := 0 to High(A) do
    Result[I] := OasisVarRecToValue(A[I]);
end;

function OasisIsTruthy(const V: TValue): Boolean;
begin
  if V.IsEmpty then
    Exit(False);
  if V.IsType<Boolean> then
    Exit(V.AsBoolean);
  if V.IsObject then
    Exit(V.AsObject <> nil);
  if V.IsType<IInterface> then
    Exit(V.AsType<IInterface> <> nil);
  Result := True;
end;

end.
