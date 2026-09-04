unit Oasis.Inject;

{ Oasis framework - [Inject] field-injection primitives.

  IMPLEMENTATION IS LOCKED to the compiled-and-verified recipe (spec appendix
  A.3): Supports() converts the registry's IInterface to the FIELD's GUID,
  then a refcounted write lands it at TRttiField.Offset. TValue/SetValue is
  NOT viable (EInvalidCast, spec A.1); raw interface-pointer copies without
  Supports corrupt method calls (spec A.2). Do not "improve" this.

  This unit must NOT use Oasis.Context (cycle-free core): Populate takes the
  plugin as TObject. GetFields covers inherited fields (verified, A.10). }

interface

uses
  System.SysUtils, System.TypInfo, System.Rtti, System.Generics.Collections,
  Oasis.Types, Oasis.Errors, Oasis.Services, Oasis.Spin;

type
  { Marks an interface-typed field for dependency injection. The service GUID
    comes from the field's declared interface type. Declaration errors
    (non-interface field / GUID-less interface) surface on the first scan,
    i.e. at the first Inject call - fail fast. }
  InjectAttribute = class(TCustomAttribute);

  { Typed pull helpers for closure plugins and non-field injection styles.
    T must be an interface type. }
  TOasisDI = record
    class function Need<T>(const ARegistry: IServiceRegistry): T; static;
    class function TryNeed<T>(const ARegistry: IServiceRegistry;
      out AService: T): Boolean; static;
  end;

  { Scans [Inject] fields once per class (cached), fills them from the
    registry, and clears them on teardown. }
  TOasisInjector = class
  public
    class procedure Populate(APlugin: TObject;
      const ARegistry: IServiceRegistry); static;
    class procedure Clear(APlugin: TObject); static;
    class function  FieldGuids(APluginClass: TClass): TArray<TGUID>; static;
  end;

implementation

type
  PIInterface = ^IInterface;

  { Cached per-class scan result: offset + GUID only (never TRttiField
    objects - their lifetime is bound to a TRttiContext). }
  TInjectFieldInfo = record
    Name: string;
    Offset: Integer;
    Guid: TGUID;
  end;

  TInjectClassCache = class
  public
    class var FLock: TOasisSpinLock;
    class var FMap: TDictionary<TClass, TArray<TInjectFieldInfo>>;
    class constructor Create;
    class destructor Destroy;
    class function FieldsFor(APluginClass: TClass): TArray<TInjectFieldInfo>; static;
  end;

class constructor TInjectClassCache.Create;
begin
  FMap := TDictionary<TClass, TArray<TInjectFieldInfo>>.Create;
end;

class destructor TInjectClassCache.Destroy;
begin
  FMap.Free;
end;

class function TInjectClassCache.FieldsFor(APluginClass: TClass): TArray<TInjectFieldInfo>;
var
  Ctx: TRttiContext;
  Typ: TRttiType;
  F: TRttiField;
  A: TCustomAttribute;
  Guid: TGUID;
  HasAttr: Boolean;
  Count: Integer;
  Cached: TArray<TInjectFieldInfo>;
begin
  FLock.Enter;
  try
    if FMap.TryGetValue(APluginClass, Cached) then
      Exit(Cached);
  finally
    FLock.Leave;
  end;
  { scan outside the lock; only plain data is cached }
  Count := 0;
  SetLength(Result, 0);
  Ctx := TRttiContext.Create;
  Typ := Ctx.GetType(APluginClass);
  if Typ <> nil then
    for F in Typ.GetFields do
    begin
      HasAttr := False;
      for A in F.GetAttributes do
        if A is InjectAttribute then
          HasAttr := True;
      if not HasAttr then
        Continue;
      if (F.FieldType = nil) or (F.FieldType.TypeKind <> tkInterface) then
        raise EOasisInjectError.CreateFmt(
          '[Inject] field %s.%s is not an interface type',
          [APluginClass.ClassName, F.Name]);
      Guid := GetTypeData(F.FieldType.Handle).Guid;
      if Guid = TGUID.Empty then
        raise EOasisInjectError.CreateFmt(
          '[Inject] field %s.%s has an interface type without a GUID',
          [APluginClass.ClassName, F.Name]);
      SetLength(Result, Count + 1);
      Result[Count].Name := F.Name;
      Result[Count].Offset := F.Offset;
      Result[Count].Guid := Guid;
      Inc(Count);
    end;
  FLock.Enter;
  try
    if not FMap.TryGetValue(APluginClass, Cached) then
      FMap.Add(APluginClass, Result)
    else
      Result := Cached;   { another thread won the race - use its copy }
  finally
    FLock.Leave;
  end;
end;

{ TOasisInjector }

class procedure TOasisInjector.Populate(APlugin: TObject;
  const ARegistry: IServiceRegistry);
var
  Fields: TArray<TInjectFieldInfo>;
  I: Integer;
  LInst, LConv: IInterface;
begin
  if APlugin = nil then
    Exit;
  Fields := TInjectClassCache.FieldsFor(APlugin.ClassType);
  for I := 0 to Length(Fields) - 1 do
  begin
    if not ARegistry.Resolve(Fields[I].Guid, LInst) then
      raise EOasisInjectError.CreateFmt(
        'Inject failed: service %s not found for %s.%s',
        [GUIDToString(Fields[I].Guid), APlugin.ClassType.ClassName, Fields[I].Name]);
    if not Supports(LInst, Fields[I].Guid, LConv) then
      raise EOasisInjectError.CreateFmt(
        'Inject failed: instance does not implement %s (%s.%s)',
        [GUIDToString(Fields[I].Guid), APlugin.ClassType.ClassName, Fields[I].Name]);
    { verified recipe (spec A.3): refcounted offset write }
    PIInterface(PByte(APlugin) + Fields[I].Offset)^ := LConv;
    LConv := nil;   { the field owns the reference now }
  end;
end;

class procedure TOasisInjector.Clear(APlugin: TObject);
var
  Fields: TArray<TInjectFieldInfo>;
  I: Integer;
begin
  if APlugin = nil then
    Exit;
  Fields := TInjectClassCache.FieldsFor(APlugin.ClassType);
  for I := 0 to Length(Fields) - 1 do
    PIInterface(PByte(APlugin) + Fields[I].Offset)^ := nil;
end;

class function TOasisInjector.FieldGuids(APluginClass: TClass): TArray<TGUID>;
var
  Fields: TArray<TInjectFieldInfo>;
  I: Integer;
begin
  Fields := TInjectClassCache.FieldsFor(APluginClass);
  SetLength(Result, Length(Fields));
  for I := 0 to Length(Fields) - 1 do
    Result[I] := Fields[I].Guid;
end;

{ TOasisDI }

class function TOasisDI.Need<T>(const ARegistry: IServiceRegistry): T;
begin
  if not TryNeed<T>(ARegistry, Result) then
    raise EOasisServiceNotFound.CreateFmt('Service not found: %s',
      [GUIDToString(GetTypeData(TypeInfo(T)).Guid)]);
end;

class function TOasisDI.TryNeed<T>(const ARegistry: IServiceRegistry;
  out AService: T): Boolean;
var
  LInst: IInterface;
  LGuid: TGUID;
begin
  LGuid := GetTypeData(TypeInfo(T)).Guid;
  if not ARegistry.Resolve(LGuid, LInst) then
    Exit(False);
  Result := Supports(LInst, LGuid, AService);
end;

end.