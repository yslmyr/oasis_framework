unit Oasis.Config;

(* Oasis framework - JSON configuration plugin (cordis.yml-style, JSON edition).

  A TJsonConfigPlugin reads a JSON file and registers an IOasisConfig service:

    {
      "plugins": {
        "greeter": {
          "disabled": true,          <- Host.TryMount skips disabled plugins
          "config": { "prefix": "Hi" }  <- per-plugin string values
        }
      }
    }

  Consumers inject IOasisConfig (GUID) like any service. Values are strings in
  v1 (numbers/bools arrive as their JSON text); layers/overrides are a future
  refinement. A missing file raises EOasisConfigError at Apply time (fail loud
  - a plugin must not run on bad config). *)

interface

uses
  System.SysUtils, System.Generics.Collections,
  Oasis.Context, Oasis.Plugin;

type
  IOasisConfig = interface
    ['{88888888-0000-0000-0000-000000000008}']
    { True when the plugin section exists and sets "disabled": true. }
    function  Disabled(const APluginName: string): Boolean;
    { Per-plugin string value; ADefault when plugin/key is absent. }
    function  Value(const APluginName, AKey, ADefault: string): string;
    function  HasValue(const APluginName, AKey: string): Boolean;
  end;

  EOasisConfigError = class(Exception);

  { Config provider plugin. Mount it like any plugin BEFORE the consumers; its
    IOasisConfig service then satisfies their Inject. }
  TJsonConfigPlugin = class(TOasisPlugin)
  strict private
    FPath: string;
  public
    constructor Create(const APath: string);
    procedure Apply(const Ctx: IContext); override;
  end;

implementation

uses
  System.IOUtils, System.Json;

type
  TConfigImpl = class(TInterfacedObject, IOasisConfig)
  strict private
    FDisabled: TDictionary<string, Boolean>;
    FValues: TObjectDictionary<string, TDictionary<string, string>>;
  public
    constructor Create;
    destructor Destroy; override;
    procedure SetDisabled(const APluginName: string; ADisabled: Boolean);
    procedure SetValue(const APluginName, AKey, AValue: string);
    function  Disabled(const APluginName: string): Boolean;
    function  Value(const APluginName, AKey, ADefault: string): string;
    function  HasValue(const APluginName, AKey: string): Boolean;
  end;

{ TConfigImpl }

constructor TConfigImpl.Create;
begin
  inherited Create;
  FDisabled := TDictionary<string, Boolean>.Create;
  FValues := TObjectDictionary<string, TDictionary<string, string>>.Create([doOwnsValues]);
end;

destructor TConfigImpl.Destroy;
begin
  FValues.Free;
  FDisabled.Free;
  inherited Destroy;
end;

procedure TConfigImpl.SetDisabled(const APluginName: string; ADisabled: Boolean);
begin
  FDisabled.AddOrSetValue(APluginName, ADisabled);
end;

procedure TConfigImpl.SetValue(const APluginName, AKey, AValue: string);
var
  LSection: TDictionary<string, string>;
begin
  if not FValues.TryGetValue(APluginName, LSection) then
  begin
    LSection := TDictionary<string, string>.Create;
    FValues.Add(APluginName, LSection);
  end;
  LSection.AddOrSetValue(AKey, AValue);
end;

function TConfigImpl.Disabled(const APluginName: string): Boolean;
begin
  Result := FDisabled.ContainsKey(APluginName) and FDisabled[APluginName];
end;

function TConfigImpl.Value(const APluginName, AKey, ADefault: string): string;
var
  LSection: TDictionary<string, string>;
begin
  if FValues.TryGetValue(APluginName, LSection) and LSection.ContainsKey(AKey) then
    Result := LSection[AKey]
  else
    Result := ADefault;
end;

function TConfigImpl.HasValue(const APluginName, AKey: string): Boolean;
var
  LSection: TDictionary<string, string>;
begin
  Result := FValues.TryGetValue(APluginName, LSection) and LSection.ContainsKey(AKey);
end;

{ TJsonConfigPlugin }

constructor TJsonConfigPlugin.Create(const APath: string);
begin
  inherited Create('json-config');
  FPath := APath;
end;

procedure TJsonConfigPlugin.Apply(const Ctx: IContext);
var
  LRoot, LPlugins, LSection, LConfigObj: TJSONObject;
  LPair, LCfgPair: TJSONPair;
  LImpl: TConfigImpl;
  I, J: Integer;
begin
  if not TFile.Exists(FPath) then
    raise EOasisConfigError.CreateFmt('Config file not found: %s', [FPath]);
  LRoot := nil;
  try
    try
      LRoot := TJSONObject.ParseJsonValue(TFile.ReadAllText(FPath)) as TJSONObject;
    except
      on E: Exception do
        raise EOasisConfigError.CreateFmt('Config file cannot be read: %s (%s)', [FPath, E.Message]);
    end;
    if LRoot = nil then
      raise EOasisConfigError.CreateFmt('Config file is not a JSON object: %s', [FPath]);

    LImpl := TConfigImpl.Create;
    try
      LPlugins := LRoot.GetValue('plugins') as TJSONObject;
      for I := 0 to LPlugins.Count - 1 do
      begin
        LPair := LPlugins.Pairs[I];
        if not (LPair.JsonValue is TJSONObject) then
          Continue;
        LSection := LPair.JsonValue as TJSONObject;
        if (LSection.FindValue('disabled') <> nil) and LSection.GetValue<Boolean>('disabled') then
          LImpl.SetDisabled(LPair.JsonString.Value, True);
        LConfigObj := LSection.FindValue('config') as TJSONObject;
        if LConfigObj <> nil then
          for J := 0 to LConfigObj.Count - 1 do
          begin
            LCfgPair := LConfigObj.Pairs[J];
            LImpl.SetValue(LPair.JsonString.Value, LCfgPair.JsonString.Value,
              LCfgPair.JsonValue.Value);
          end;
      end;
    except
      on E: EOasisConfigError do
        raise
      else
        raise EOasisConfigError.CreateFmt('Config file structure invalid: %s', [FPath]);
    end;
    Ctx.Services.Register(IOasisConfig, LImpl);
  finally
    LRoot.Free;
  end;
end;

end.
