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
    ['{B2C3D4E5-F6A7-4B8C-9D0E-1F2A3B4C5D6E}']
    procedure Register(const AGUID: TGUID; AInstance: IInterface);
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

  TServiceRegistry = class(TInterfacedObject, IServiceRegistry)
  strict private
    FLock: TOasisRWSpinLock;
    FMap: TDictionary<TGUID, IInterface>;
    FParent: IServiceRegistry;
    FOnServiceAdded: TServiceAddedEvent;
    FOnServiceRemoved: TServiceRemovedEvent;
    FOwner: IEffectScope;
    procedure RemoveIfSame(const AGUID: TGUID; AInstance: IInterface);
  public
    constructor Create(AParent: IServiceRegistry);
    destructor Destroy; override;
    procedure Register(const AGUID: TGUID; AInstance: IInterface);
    function  Unregister(const AGUID: TGUID): Boolean;
    function  Get(const AGUID: TGUID): IInterface;
    function  Resolve(const AGUID: TGUID; out AInstance: IInterface): Boolean;
    function  Has(const AGUID: TGUID): Boolean;
    procedure SetOnServiceAdded(AHandler: TServiceAddedEvent);
    procedure SetOnServiceRemoved(AHandler: TServiceRemovedEvent);
    procedure SetOwnerScope(AScope: IEffectScope);
  end;

implementation

{ TServiceRegistry }

constructor TServiceRegistry.Create(AParent: IServiceRegistry);
begin
  inherited Create;
  FMap := TDictionary<TGUID, IInterface>.Create;
  FParent := AParent;
end;

destructor TServiceRegistry.Destroy;
begin
  { Just drop the map. Do NOT fire removal hooks here: teardown re-entrancy is
    handled by the owner scopes (fiber disposals already ran their cleanups). }
  FMap.Free;
  inherited Destroy;
end;

procedure TServiceRegistry.Register(const AGUID: TGUID; AInstance: IInterface);
var
  LAdded: TServiceAddedEvent;
  LOwner: IEffectScope;
  LReg: TServiceRegistry;
  LInst: IInterface;
begin
  FLock.EnterWrite;
  try
    FMap.AddOrSetValue(AGUID, AInstance);
    LAdded := FOnServiceAdded;
    LOwner := FOwner;
  finally
    FLock.LeaveWrite;
  end;
  if LOwner <> nil then
  begin
    { Auto-unregister when the owning scope (plugin fiber) disposes. Captures the
      exact instance so a newer overwrite is not removed by an older cleanup. }
    LReg := Self;
    LInst := AInstance;
    LOwner.AddCleanup(
      procedure
      begin
        LReg.RemoveIfSame(AGUID, LInst);
        LInst := nil;   { release the captured service reference }
      end);
  end;
  if Assigned(LAdded) then
    LAdded(AGUID);
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

procedure TServiceRegistry.RemoveIfSame(const AGUID: TGUID; AInstance: IInterface);
var
  LRemoved: TServiceRemovedEvent;
  LCurrent: IInterface;
begin
  FLock.EnterWrite;
  try
    if FMap.TryGetValue(AGUID, LCurrent) and (LCurrent = AInstance) then
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
begin
  { hot path: shared read lock - concurrent lookups do not block each other }
  FLock.EnterRead;
  try
    Result := FMap.TryGetValue(AGUID, AInstance);
  finally
    FLock.LeaveRead;
  end;
  if (not Result) and (FParent <> nil) then
    Result := FParent.Resolve(AGUID, AInstance);
end;

function TServiceRegistry.Has(const AGUID: TGUID): Boolean;
var
  LDummy: IInterface;
begin
  Result := Resolve(AGUID, LDummy);
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
