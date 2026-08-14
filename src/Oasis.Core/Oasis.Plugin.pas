unit Oasis.Plugin;

{ Oasis framework - plugin authoring helpers. IPlugin lives in Oasis.Context; this
  unit adds a convenience base class (subclasses set dependencies in the
  constructor and override Apply) and a descriptor record used by the Host
  catalog. }

interface

uses
  System.SysUtils,
  Oasis.Types, Oasis.Context;

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
begin
  Result := FInject;
end;

end.
