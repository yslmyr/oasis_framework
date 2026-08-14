unit Oasis.Config;

(* Oasis framework - JSON configuration plugin (cordis.yml-style, JSON edition).

  A TJsonConfigPlugin reads a JSON file and registers an IOasisConfig service:

    {
      "plugins": {
        "greeter": {
          "disabled": true,          <- Host.TryMount skips disabled plugins
          "config": { "prefix": "Hi", "retries": 3, "verbose": true }
        }
      },
      "env": {                                   <- optional override layers
        "production": {
          "plugins": {
            "greeter": { "config": { "retries": 5 } }
          }
        }
      }
    }

  Create(APath) loads the base layer only. Create(APath, 'production') merges
  that env layer ON TOP: per plugin, "disabled" overrides when present (either
  way), and "config" keys override individually - keys not mentioned survive
  from the base layer (cordis.yml override semantics).

  Values are stored as their JSON text and read typed: Value (string), Int,
  Bool, Float - each falling back to its default when the key is missing or
  not parseable. A missing file raises EOasisConfigError at Apply time (fail
  loud - a plugin must not run on bad config). *)

interface

uses
  System.SysUtils, System.Generics.Collections,
  Oasis.Context, Oasis.Plugin;

type
  IOasisConfig = interface
    ['{88888888-0000-0000-0000-000000000008}']
    { True when the (merged) plugin section sets "disabled": true. }
    function  Disabled(const APluginName: string): Boolean;
    { Per-plugin string value; ADefault when plugin/key is absent. }
    function  Value(const APluginName, AKey, ADefault: string): string;
    function  HasValue(const APluginName, AKey: string): Boolean;
    { Typed readers: JSON text is parsed; ADefault when missing/unparseable. }
    function  Int(const APluginName, AKey: string; ADefault: Integer): Integer;
    function  Bool(const APluginName, AKey: string; ADefault: Boolean): Boolean;
    function  Float(const APluginName, AKey: string; ADefault: Double): Double;
  end;

  EOasisConfigError = class(Exception);

  { Config provider plugin. Mount it like any plugin BEFORE the consumers; its
    IOasisConfig service then satisfies their Inject. }
  TJsonConfigPlugin = class(TOasisPlugin)
  strict private
    FPath: string;
    FEnv: string;
    procedure LoadSection(AImpl: TObject; ASection: TObject);
  public
    constructor Create(const APath: string); overload;
    constructor Create(const APath, AEnv: string); overload;
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
    function  Int(const APluginName, AKey: string; ADefault: Integer): Integer;
    function  Bool(const APluginName, AKey: string; ADefault: Boolean): Boolean;
    function  Float(const APluginName, AKey: string; ADefault: Double): Double;
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

function TConfigImpl.Int(const APluginName, AKey: string; ADefault: Integer): Integer;
var
  LText: string;
begin
  LText := Value(APluginName, AKey, '');
  if not TryStrToInt(LText, Result) then
    Result := ADefault;
end;

function TConfigImpl.Bool(const APluginName, AKey: string; ADefault: Boolean): Boolean;
var
  LText: string;
begin
  LText := Value(APluginName, AKey, '');
  if SameText(LText, 'true') then
    Result := True
  else if SameText(LText, 'false') then
    Result := False
  else
    Result := ADefault;
end;

function TConfigImpl.Float(const APluginName, AKey: string; ADefault: Double): Double;
var
  LText: string;
begin
  LText := Value(APluginName, AKey, '');
  if not TryStrToFloat(LText, Result) then
    Result := ADefault;
end;

{ TJsonConfigPlugin }

constructor TJsonConfigPlugin.Create(const APath: string);
begin
  inherited Create('json-config');
  FPath := APath;
  FEnv := '';
end;

constructor TJsonConfigPlugin.Create(const APath, AEnv: string);
begin
  inherited Create('json-config');
  FPath := APath;
  FEnv := AEnv;
end;

procedure TJsonConfigPlugin.LoadSection(AImpl: TObject; ASection: TObject);
var
  LImpl: TConfigImpl;
  LSection: TJSONObject;
  LPlugins, LConfigObj: TJSONObject;
  LPair, LCfgPair: TJSONPair;
  I, J: Integer;
begin
  LImpl := TConfigImpl(AImpl);
  LSection := TJSONObject(ASection);
  LPlugins := LSection.GetValue('plugins') as TJSONObject;
  for I := 0 to LPlugins.Count - 1 do
  begin
    LPair := LPlugins.Pairs[I];
    if not (LPair.JsonValue is TJSONObject) then
      Continue;
    LConfigObj := LPair.JsonValue as TJSONObject;
    if LConfigObj.FindValue('disabled') <> nil then
      LImpl.SetDisabled(LPair.JsonString.Value, LConfigObj.GetValue<Boolean>('disabled'));
    LConfigObj := LConfigObj.FindValue('config') as TJSONObject;
    if LConfigObj <> nil then
      for J := 0 to LConfigObj.Count - 1 do
      begin
        LCfgPair := LConfigObj.Pairs[J];
        LImpl.SetValue(LPair.JsonString.Value, LCfgPair.JsonString.Value,
          LCfgPair.JsonValue.Value);
      end;
  end;
end;

procedure TJsonConfigPlugin.Apply(const Ctx: IContext);
var
  LRoot, LEnvSection: TJSONObject;
  LImpl: TConfigImpl;
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
      LoadSection(LImpl, LRoot);   { base layer }
      if FEnv <> '' then
      begin
        LEnvSection := nil;
        if LRoot.FindValue('env') is TJSONObject then
          LEnvSection := (LRoot.FindValue('env') as TJSONObject).FindValue(FEnv) as TJSONObject;
        if LEnvSection <> nil then
          LoadSection(LImpl, LEnvSection)   { env layer ON TOP (overrides) }
        else
          raise EOasisConfigError.CreateFmt('Config env layer not found: %s (%s)', [FPath, FEnv]);
      end;
      Ctx.Services.Register(IOasisConfig, LImpl);  { registry/fiber own it now }
    except
      on E: EOasisConfigError do
      begin
        LImpl.Free;   { refcount 0 here - nothing has captured it yet }
        raise;
      end;
      else
      begin
        LImpl.Free;
        raise EOasisConfigError.CreateFmt('Config file structure invalid: %s', [FPath]);
      end;
    end;
  finally
    LRoot.Free;
  end;
end;

end.
