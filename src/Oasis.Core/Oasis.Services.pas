unit Oasis.Services;

{ Oasis framework - GUID-keyed service registry. Lookup walks the parent chain
  (child shadows parent). Register fires an optional OnServiceAdded hook that the
  Host uses for dependency-activation rescan. The interface is non-generic (Delphi
  forbids generic interface methods); callers register via the interface-id to
  TGUID compiler magic: Services.Register(IConfig, Instance). }

interface

uses
  System.SysUtils, System.SyncObjs, System.Generics.Collections,
  Oasis.Errors;

type
  TServiceAddedEvent = reference to procedure(const AGUID: TGUID);

  IServiceRegistry = interface
    ['{B2C3D4E5-F6A7-4B8C-9D0E-1F2A3B4C5D6E}']
    procedure Register(const AGUID: TGUID; AInstance: IInterface);
    function  Get(const AGUID: TGUID): IInterface;
    function  Resolve(const AGUID: TGUID; out AInstance: IInterface): Boolean;
    function  Has(const AGUID: TGUID): Boolean;
    procedure SetOnServiceAdded(AHandler: TServiceAddedEvent);
  end;

  TServiceRegistry = class(TInterfacedObject, IServiceRegistry)
  strict private
    FLock: TCriticalSection;
    FMap: TDictionary<TGUID, IInterface>;
    FParent: IServiceRegistry;
    FOnServiceAdded: TServiceAddedEvent;
  public
    constructor Create(AParent: IServiceRegistry);
    destructor Destroy; override;
    procedure Register(const AGUID: TGUID; AInstance: IInterface);
    function  Get(const AGUID: TGUID): IInterface;
    function  Resolve(const AGUID: TGUID; out AInstance: IInterface): Boolean;
    function  Has(const AGUID: TGUID): Boolean;
    procedure SetOnServiceAdded(AHandler: TServiceAddedEvent);
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
  FMap.Free;
  FLock.Free;
  inherited Destroy;
end;

procedure TServiceRegistry.Register(const AGUID: TGUID; AInstance: IInterface);
var
  LHandler: TServiceAddedEvent;
begin
  FLock.Enter;
  try
    FMap.AddOrSetValue(AGUID, AInstance);
    LHandler := FOnServiceAdded;
  finally
    FLock.Leave;
  end;
  if Assigned(LHandler) then
    LHandler(AGUID);
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

end.
