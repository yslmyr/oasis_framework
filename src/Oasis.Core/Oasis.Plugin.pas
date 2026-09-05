unit Oasis.Plugin;

{ Oasis framework - plugin authoring helpers. IPlugin lives in Oasis.Context; this
  unit adds a convenience base class (subclasses set dependencies in the
  constructor and override Apply) and a descriptor record used by the Host
  catalog. }

interface

uses
  System.SysUtils,
  Oasis.Types, Oasis.Context, Oasis.Inject;

type
  TPluginDescriptor = record
    Name: string;
    Version: string;
    Inject: TArray<TGUID>;
    constructor Create(const AName: string; const AVersion: string = '';
      const AInject: TArray<TGUID> = nil);
  end;

  { Convenience base implementing IPlugin. Call AddInject(<service GUID>) in the
    constructor to declare dependencies; override Apply. }
  TOasisPlugin = class(TInterfacedObject, IPlugin)
  strict private
    FName: string;
    FInject: TArray<TGUID>;
    FInjectMerged: TArray<TGUID>;   { manual ∪ [Inject]-field GUIDs, built once }
    FInjectComputed: Boolean;       { guards the one-time merge above }
  protected
    procedure AddInject(const AGUID: TGUID);
    property Name: string read FName write FName;
  public
    constructor Create(const AName: string);
    function PluginName: string; virtual;
    function Inject: TArray<TGUID>; virtual;
    procedure Apply(const Ctx: IContext); virtual; abstract;
  end;

implementation

{ TPluginDescriptor }

constructor TPluginDescriptor.Create(const AName, AVersion: string;
  const AInject: TArray<TGUID>);
begin
  Name := AName;
  Version := AVersion;
  Inject := AInject;
end;

{ TOasisPlugin }

constructor TOasisPlugin.Create(const AName: string);
begin
  inherited Create;
  FName := AName;
end;

procedure TOasisPlugin.AddInject(const AGUID: TGUID);
begin
  SetLength(FInject, Length(FInject) + 1);
  FInject[High(FInject)] := AGUID;
end;

function TOasisPlugin.PluginName: string;
begin
  Result := FName;
end;

function TOasisPlugin.Inject: TArray<TGUID>;
var
  I, J: Integer;
  LFields: TArray<TGUID>;
  LDup: Boolean;
begin
  if not FInjectComputed then
  begin
    { manual AddInject (constructor-time) ∪ [Inject] fields (scan cache),
      deduplicated by GUID. Built once: DepsSatisfied calls Inject on every
      plugin at every service registration (spec 3.3/N3), so zero-dependency
      plugins must not re-enter this branch either. }
    LFields := TOasisInjector.FieldGuids(ClassType);
    FInjectMerged := Copy(FInject, 0, Length(FInject));
    for I := 0 to High(LFields) do
    begin
      LDup := False;
      for J := 0 to High(FInjectMerged) do
        if IsEqualGUID(FInjectMerged[J], LFields[I]) then
        begin
          LDup := True;
          Break;
        end;
      if not LDup then
      begin
        SetLength(FInjectMerged, Length(FInjectMerged) + 1);
        FInjectMerged[High(FInjectMerged)] := LFields[I];
      end;
    end;
    FInjectComputed := True;
  end;
  Result := FInjectMerged;
end;

end.
