unit Oasis.Services;

{ Oasis framework - GUID-keyed service registry. Lookup walks the parent chain
  (child shadows parent). Register fires an optional OnServiceAdded hook that the
  Host uses for dependency-activation rescan; Unregister (explicit, or automatic
  when the owning plugin's fiber disposes) fires OnServiceRemoved so the Host can
  deactivate dependents (dependency cascade). The interface is non-generic
  (Delphi forbids generic interface methods); callers register via the
  interface-id to TGUID compiler magic: Services.Register(IConfig, Instance).

  PERFORMANCE DESIGN (perf pass, see spec §19): the registry is read-mostly
  (every Get/Inject resolution) and write-rare (mount-time), so reads take the
  lightweight multi-reader spin lock and may run CONCURRENTLY; only
  Register/Unregister/handler setters take the write side. }

interface

uses
  System.SysUtils, System.Generics.Collections,
  Oasis.Types, Oasis.Errors, Oasis.Effects, Oasis.Spin;

type
  TServiceAddedEvent = reference to procedure(const AGUID: TGUID);
  TServiceRemovedEvent = reference to procedure(const AGUID: TGUID);

  IServiceRegistry = interface
    ['{B2C3D4E5-F6A7-4B8C-9D0E-1F2A3B4C5D6F}']
    procedure Register(const AGUID: TGUID; AInstance: IInterface);
    { Register a lazy singleton factory: first Get/Resolve builds and memoizes;
      Has never triggers a build. Factory closures must NOT capture the
      registry as IServiceRegistry (refcount cycle) - capture class refs. }
    procedure RegisterFactory(const AGUID: TGUID; AFactory: TFunc<IInterface>);
    { Register a transient factory: every Get/Resolve builds a fresh instance;
      instance lifetime = the consumer's interface refcount. }
    procedure RegisterTransient(const AGUID: TGUID; AFactory: TFunc<IInterface>);
    { Remove the local registration for AGUID. Returns True if it existed (and
      fires OnServiceRemoved). }
    function  Unregister(const AGUID: TGUID): Boolean;
    function  Get(const AGUID: TGUID): IInterface;
    function  Resolve(const AGUID: TGUID; out AInstance: IInterface): Boolean;
    function  Has(const AGUID: TGUID): Boolean;
    procedure SetOnServiceAdded(AHandler: TServiceAddedEvent);
    procedure SetOnServiceRemoved(AHandler: TServiceRemovedEvent);
    { While set, Register attaches an auto-unregister cleanup to the scope (the
      plugin fiber during Apply), so services vanish when their provider
      unloads/reloads. SetOwnerScope(nil) detaches. }
    procedure SetOwnerScope(AScope: IEffectScope);
  end;

  TServiceKind = (skInstance, skLazySingleton, skTransient);

  TServiceEntry = record
    Kind: TServiceKind;
    Token: UInt64;              { identity for fiber-cleanup "remove if still mine" }
    Instance: IInterface;       { skInstance value / skLazySingleton memo }
    Factory: TFunc<IInterface>; { skLazySingleton / skTransient }
    class function Make(AKind: TServiceKind; AToken: UInt64;
      const AInstance: IInterface; AFactory: TFunc<IInterface>): TServiceEntry; static;
  end;

  TServiceRegistry = class(TInterfacedObject, IServiceRegistry)
  strict private
    FLock: TOasisRWSpinLock;
    FMap: TDictionary<TGUID, TServiceEntry>;
    FParent: IServiceRegistry;
    FOnServiceAdded: TServiceAddedEvent;
    FOnServiceRemoved: TServiceRemovedEvent;
    FOwner: IEffectScope;
    FNextToken: UInt64;
    procedure RegisterEntry(AKind: TServiceKind; const AGUID: TGUID;
      const AInstance: IInterface; AFactory: TFunc<IInterface>);
    procedure RemoveEntryIfToken(const AGUID: TGUID; AToken: UInt64);
  public
    constructor Create(AParent: IServiceRegistry);
    destructor Destroy; override;
    procedure Register(const AGUID: TGUID; AInstance: IInterface);
    procedure RegisterFactory(const AGUID: TGUID; AFactory: TFunc<IInterface>);
    procedure RegisterTransient(const AGUID: TGUID; AFactory: TFunc<IInterface>);
    function  Unregister(const AGUID: TGUID): Boolean;
    function  Get(const AGUID: TGUID): IInterface;
    function  Resolve(const AGUID: TGUID; out AInstance: IInterface): Boolean;
    function  Has(const AGUID: TGUID): Boolean;
    procedure SetOnServiceAdded(AHandler: TServiceAddedEvent);
    procedure SetOnServiceRemoved(AHandler: TServiceRemovedEvent);
    procedure SetOwnerScope(AScope: IEffectScope);
  end;

implementation

const
  CMaxBuildDepth = 16;

type
  { Per-thread build guard: leak-free (record threadvar, no heap). A lazy
    factory resolving its own GUID re-enters and hits the circular check. }
  TBuildStack = record
    Depth: Integer;
    Guids: array[0..CMaxBuildDepth - 1] of TGUID;
  end;

threadvar
  FBuildStack: TBuildStack;

function BuildGuarded(const AGUID: TGUID; AFactory: TFunc<IInterface>): IInterface;
var
  I: Integer;
begin
  for I := 0 to FBuildStack.Depth - 1 do
    if IsEqualGUID(FBuildStack.Guids[I], AGUID) then
      raise EOasisServiceFactoryError.CreateFmt(
        'Circular lazy factory build: %s', [GUIDToString(AGUID)]);
  if FBuildStack.Depth >= CMaxBuildDepth then
    raise EOasisServiceFactoryError.Create('Lazy factory build recursion too deep');
  FBuildStack.Guids[FBuildStack.Depth] := AGUID;
  Inc(FBuildStack.Depth);
  try
    Result := AFactory();   { NEVER called under the registry lock }
  finally
    Dec(FBuildStack.Depth);
  end;
end;

{ TServiceEntry }

class function TServiceEntry.Make(AKind: TServiceKind; AToken: UInt64;
  const AInstance: IInterface; AFactory: TFunc<IInterface>): TServiceEntry;
begin
  Result.Kind := AKind;
  Result.Token := AToken;
  Result.Instance := AInstance;
  Result.Factory := AFactory;
end;

{ TServiceRegistry }

constructor TServiceRegistry.Create(AParent: IServiceRegistry);
begin
  inherited Create;
  FMap := TDictionary<TGUID, TServiceEntry>.Create;
  FParent := AParent;
  FNextToken := 0;
end;

destructor TServiceRegistry.Destroy;
begin
  { Just drop the map. Do NOT fire removal hooks here: teardown re-entrancy is
    handled by the owner scopes (fiber disposals already ran their cleanups). }
  FMap.Free;
  inherited Destroy;
end;

procedure TServiceRegistry.RegisterEntry(AKind: TServiceKind;
  const AGUID: TGUID; const AInstance: IInterface;
  AFactory: TFunc<IInterface>);
var
  LAdded: TServiceAddedEvent;
  LOwner: IEffectScope;
  LReg: TServiceRegistry;
  LEntry: TServiceEntry;
begin
  FLock.EnterWrite;
  try
    Inc(FNextToken);
    LEntry := TServiceEntry.Make(AKind, FNextToken, AInstance, AFactory);
    FMap.AddOrSetValue(AGUID, LEntry);
    LAdded := FOnServiceAdded;
    LOwner := FOwner;
  finally
    FLock.LeaveWrite;
  end;
  if LOwner <> nil then
  begin
    { capture the CLASS ref (never IServiceRegistry - refcount cycle) and the
      entry's token so a newer overwrite is not removed by an older cleanup }
    LReg := Self;
    LOwner.AddCleanup(
      procedure
      begin
        LReg.RemoveEntryIfToken(AGUID, LEntry.Token);
        LEntry.Instance := nil;   { release captured memo/instance }
        LEntry.Factory := nil;    { release captured factory closure }
      end);
  end;
  if Assigned(LAdded) then
    LAdded(AGUID);
end;

procedure TServiceRegistry.Register(const AGUID: TGUID; AInstance: IInterface);
begin
  RegisterEntry(skInstance, AGUID, AInstance, nil);
end;

procedure TServiceRegistry.RegisterFactory(const AGUID: TGUID;
  AFactory: TFunc<IInterface>);
begin
  RegisterEntry(skLazySingleton, AGUID, nil, AFactory);
end;

procedure TServiceRegistry.RegisterTransient(const AGUID: TGUID;
  AFactory: TFunc<IInterface>);
begin
  RegisterEntry(skTransient, AGUID, nil, AFactory);
end;

function TServiceRegistry.Unregister(const AGUID: TGUID): Boolean;
var
  LRemoved: TServiceRemovedEvent;
begin
  FLock.EnterWrite;
  try
    Result := FMap.ContainsKey(AGUID);
    if Result then
    begin
      FMap.Remove(AGUID);
      LRemoved := FOnServiceRemoved;
    end;
  finally
    FLock.LeaveWrite;
  end;
  if Result and Assigned(LRemoved) then
    LRemoved(AGUID);
end;

procedure TServiceRegistry.RemoveEntryIfToken(const AGUID: TGUID; AToken: UInt64);
var
  LRemoved: TServiceRemovedEvent;
  LEntry: TServiceEntry;
begin
  FLock.EnterWrite;
  try
    if FMap.TryGetValue(AGUID, LEntry) and (LEntry.Token = AToken) then
    begin
      FMap.Remove(AGUID);
      LRemoved := FOnServiceRemoved;
    end
    else
      Exit;
  finally
    FLock.LeaveWrite;
  end;
  if Assigned(LRemoved) then
    LRemoved(AGUID);
end;

function TServiceRegistry.Get(const AGUID: TGUID): IInterface;
begin
  if not Resolve(AGUID, Result) then
    raise EOasisServiceNotFound.CreateFmt('Service not found: %s', [GUIDToString(AGUID)]);
end;

function TServiceRegistry.Resolve(const AGUID: TGUID; out AInstance: IInterface): Boolean;
var
  LEntry, LNow: TServiceEntry;
  LBuilt: IInterface;
begin
  { hot path: shared read lock - concurrent lookups do not block each other }
  FLock.EnterRead;
  try
    if not FMap.TryGetValue(AGUID, LEntry) then
    begin
      if FParent = nil then
        Exit(False);
      Exit(FParent.Resolve(AGUID, AInstance));
    end;
    if LEntry.Kind = skInstance then
    begin
      AInstance := LEntry.Instance;
      Exit(True);
    end;
    if (LEntry.Kind = skLazySingleton) and (LEntry.Instance <> nil) then
    begin
      AInstance := LEntry.Instance;   { memoized already }
      Exit(True);
    end;
  finally
    FLock.LeaveRead;
  end;
  { factory entries: build WITHOUT holding the lock; thread-local circular guard }
  LBuilt := BuildGuarded(AGUID, LEntry.Factory);
  if LEntry.Kind = skLazySingleton then
  begin
    FLock.EnterWrite;
    try
      { last-write-wins under concurrent first resolve (spec 4.3/F6). Memoize
        only if OUR registration is still current (token match against the
        FIRST read's token) - a newer overwrite must not be clobbered by an
        older factory's late build. A losing build is released when LBuilt
        goes out of scope. }
      if FMap.TryGetValue(AGUID, LNow) and (LNow.Token = LEntry.Token) then
        FMap.AddOrSetValue(AGUID,
          TServiceEntry.Make(LEntry.Kind, LEntry.Token, LBuilt, LEntry.Factory));
    finally
      FLock.LeaveWrite;
    end;
  end;
  AInstance := LBuilt;
  Result := True;
end;

function TServiceRegistry.Has(const AGUID: TGUID): Boolean;
var
  LEntry: TServiceEntry;
begin
  { EXISTENCE check only - a factory must NEVER be triggered by Has/DepsSatisfied
    (spec 4.2/F1). For skInstance this is behaviorally identical to the old
    Resolve-based implementation. }
  FLock.EnterRead;
  try
    Result := FMap.TryGetValue(AGUID, LEntry);
  finally
    FLock.LeaveRead;
  end;
  if (not Result) and (FParent <> nil) then
    Result := FParent.Has(AGUID);
end;

procedure TServiceRegistry.SetOnServiceAdded(AHandler: TServiceAddedEvent);
begin
  FLock.EnterWrite;
  try
    FOnServiceAdded := AHandler;
  finally
    FLock.LeaveWrite;
  end;
end;

procedure TServiceRegistry.SetOnServiceRemoved(AHandler: TServiceRemovedEvent);
begin
  FLock.EnterWrite;
  try
    FOnServiceRemoved := AHandler;
  finally
    FLock.LeaveWrite;
  end;
end;

procedure TServiceRegistry.SetOwnerScope(AScope: IEffectScope);
begin
  FLock.EnterWrite;
  try
    FOwner := AScope;
  finally
    FLock.LeaveWrite;
  end;
end;

end.
