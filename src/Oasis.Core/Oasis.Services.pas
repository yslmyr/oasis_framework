unit Oasis.Services;

{ Oasis framework - GUID-keyed service registry. Lookup walks the parent chain
  (child shadows parent). Register fires an optional OnServiceAdded hook that the
  Host uses for dependency-activation rescan; Unregister (explicit, or automatic
  when the owning plugin's fiber disposes) fires OnServiceRemoved so the Host can
  deactivate dependents (dependency cascade). The interface is non-generic
  (Delphi forbids generic interface methods); callers register via the
  interface-id to TGUID compiler magic: Services.Register(IConfig, Instance). }

interface

uses
  System.SysUtils, System.SyncObjs, System.Generics.Collections,
  Oasis.Types, Oasis.Errors, Oasis.Effects;

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
    FLock: TCriticalSection;
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
  FLock := TCriticalSection.Create;
  FMap := TDictionary<TGUID, IInterface>.Create;
  FParent := AParent;
end;

destructor TServiceRegistry.Destroy;
begin
  { Just drop the map. Do NOT fire removal hooks here: teardown re-entrancy is
    handled by the owner scopes (fiber disposals already ran their cleanups). }
  FMap.Free;
  FLock.Free;
  inherited Destroy;
end;

procedure TServiceRegistry.Register(const AGUID: TGUID; AInstance: IInterface);
var
  LAdded: TServiceAddedEvent;
  LOwner: IEffectScope;
  LReg: TServiceRegistry;
  LInst: IInterface;
begin
  FLock.Enter;
  try
    FMap.AddOrSetValue(AGUID, AInstance);
    LAdded := FOnServiceAdded;
    LOwner := FOwner;
  finally
    FLock.Leave;
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
  FLock.Enter;
  try
    Result := FMap.ContainsKey(AGUID);
    if Result then
    begin
      FMap.Remove(AGUID);
      LRemoved := FOnServiceRemoved;
    end;
  finally
    FLock.Leave;
  end;
  if Result and Assigned(LRemoved) then
    LRemoved(AGUID);
end;
procedure TServiceRegistry.RemoveIfSame(const AGUID: TGUID; AInstance: IInterface);
var
  LRemoved: TServiceRemovedEvent;
  LCurrent: IInterface;
begin
  FLock.Enter;
  try
    if FMap.TryGetValue(AGUID, LCurrent) and (LCurrent = AInstance) then
    begin
      FMap.Remove(AGUID);
      LRemoved := FOnServiceRemoved;
    end
    else
      Exit;
  finally
    FLock.Leave;
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
  FLock.Enter;
  try
    Result := FMap.TryGetValue(AGUID, AInstance);
  finally
    FLock.Leave;
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
  FLock.Enter;
  try
    FOnServiceAdded := AHandler;
  finally
    FLock.Leave;
  end;
end;

procedure TServiceRegistry.SetOnServiceRemoved(AHandler: TServiceRemovedEvent);
begin
  FLock.Enter;
  try
    FOnServiceRemoved := AHandler;
  finally
    FLock.Leave;
  end;
end;

procedure TServiceRegistry.SetOwnerScope(AScope: IEffectScope);
begin
  FLock.Enter;
  try
    FOwner := AScope;
  finally
    FLock.Leave;
  end;
end;

end.
