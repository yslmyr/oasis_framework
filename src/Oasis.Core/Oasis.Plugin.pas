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
    FInjectMerged: TArray<TGUID>;   { lazy manual ∪ [Inject]-fields cache }
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
  I, LN: Integer;
  LFields: TArray<TGUID>;
begin
  if FInjectMerged = nil then
  begin
    { 手动 AddInject（仅构造期）∪ [Inject] 字段（扫描缓存）。合并结果缓存：
      DepsSatisfied 每次服务注册都会对每个插件调 Inject（spec 3.3/N3）。 }
    LFields := TOasisInjector.FieldGuids(ClassType);
    LN := Length(FInject);
    SetLength(FInjectMerged, LN + Length(LFields));
    for I := 0 to LN - 1 do
      FInjectMerged[I] := FInject[I];
    for I := 0 to Length(LFields) - 1 do
      FInjectMerged[LN + I] := LFields[I];
  end;
  Result := FInjectMerged;
end;

end.
