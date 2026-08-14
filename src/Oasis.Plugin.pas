unit Oasis.Plugin;

{ Plugin base classes (Cordis plugin forms ported to Delphi).

  Three ways to write a plugin:
    - class form:  TOasisPlugin / TOasisPlugin<TConfig> subclasses overriding OnApply
    - service form: TOasisService subclasses that register themselves under a
      stable name when they activate (Cordis "Service" subclass)
    - function form: ctx.Plugin('name', procedure(Ctx) ...) (see Oasis.Context)

  Hard service dependencies are declared with InjectServices before mounting;
  the context holds the plugin PENDING until every declared service exists. }

interface

uses
  System.SysUtils,
  System.Generics.Collections,
  Oasis.Core,
  Oasis.Config;

type
  { Base class for plugins. Derive, declare dependencies in the constructor
    with InjectServices, and implement OnApply. }
  TOasisPlugin = class(TInterfacedObject, IOasisPlugin)
  strict private
    FName: string;
    FInject: TList<string>;
    FConfigObject: TObject;
    function GetConfigObject: TObject;
    procedure SetConfigObject(const AConfig: TObject);
  protected
    { Lifecycle entry point. Called once per activation (again after a
      reload), with the owning context. Must be re-entrant. }
    procedure OnApply(const Ctx: IOasisContext); virtual;
    { Called just before the fiber starts unloading. Use ctx.Effect /
      ctx.OnDispose for cleanup instead unless you need a notification. }
    procedure OnUnload(const Ctx: IOasisContext); virtual;
  public
    constructor Create(const AName: string = '');
    destructor Destroy; override;
    { Declare hard service dependencies. The plugin stays PENDING until all of
      them are available, unloads when any of them disappears, and reloads
      when it returns. }
    procedure InjectServices(const ANames: array of string);
    function PluginName: string;
    function Inject: TArray<string>;
    procedure Apply(const Ctx: IOasisContext); virtual;
    { Optional configuration object. The plugin owns it (freed on destroy).
      TOasisConfig instances are validated before Apply. }
    property ConfigObject: TObject read GetConfigObject write SetConfigObject;
  end;

  { Plugin with a typed configuration object. The default configuration is
    created automatically; validation runs before OnApply. }
  TOasisPlugin<TConfig: class, constructor> = class(TOasisPlugin)
  strict private
    function GetConfig: TConfig;
    procedure SetConfig(const AConfig: TConfig);
  public
    constructor Create(const AName: string = ''); reintroduce;
    property Config: TConfig read GetConfig write SetConfig;
  end;

  { A service is a plugin that registers itself under a stable name when it
    activates - the Cordis "Service" subclass form. Consumers look it up with
    ctx.Service<T> / ctx.ServiceObject<T> and declare the dependency with
    InjectServices. }
  TOasisService = class(TOasisPlugin)
  strict private
    FServiceName: string;
    FContextRef: TObject; // weak reference; valid while the service is loaded
  protected
    function GetContext: IOasisContext;
  public
    constructor Create(const AServiceName: string = ''); reintroduce;
    procedure Apply(const Ctx: IOasisContext); override;
    property ServiceName: string read FServiceName;
    { The context the service is loaded into; nil outside Apply. }
    property Context: IOasisContext read GetContext;
  end;

implementation

{ TOasisPlugin }

constructor TOasisPlugin.Create(const AName: string);
begin
  inherited Create;
  FInject := TList<string>.Create;
  if AName <> '' then
    FName := AName
  else
    FName := ClassName;
end;

destructor TOasisPlugin.Destroy;
begin
  FConfigObject.Free;
  FInject.Free;
  inherited;
end;

procedure TOasisPlugin.InjectServices(const ANames: array of string);
var
  S: string;
begin
  for S in ANames do
    if (S <> '') and not FInject.Contains(S) then
      FInject.Add(S);
end;

function TOasisPlugin.PluginName: string;
begin
  Result := FName;
end;

function TOasisPlugin.Inject: TArray<string>;
begin
  Result := FInject.ToArray;
end;

procedure TOasisPlugin.Apply(const Ctx: IOasisContext);
begin
  if (FConfigObject <> nil) and (FConfigObject is TOasisConfig) then
    TOasisConfig(FConfigObject).Validate; // fails the fiber loudly on bad config
  OnApply(Ctx);
end;

procedure TOasisPlugin.OnApply(const Ctx: IOasisContext);
begin
  // no-op by default
end;

procedure TOasisPlugin.OnUnload(const Ctx: IOasisContext);
begin
  // no-op by default
end;

function TOasisPlugin.GetConfigObject: TObject;
begin
  Result := FConfigObject;
end;

procedure TOasisPlugin.SetConfigObject(const AConfig: TObject);
begin
  if FConfigObject <> AConfig then
  begin
    FConfigObject.Free;
    FConfigObject := AConfig;
  end;
end;

{ TOasisPlugin<TConfig> }

constructor TOasisPlugin<TConfig>.Create(const AName: string);
begin
  inherited Create(AName);
  ConfigObject := TConfig.Create;
end;

function TOasisPlugin<TConfig>.GetConfig: TConfig;
begin
  Result := ConfigObject as TConfig;
end;

procedure TOasisPlugin<TConfig>.SetConfig(const AConfig: TConfig);
begin
  ConfigObject := AConfig;
end;

{ TOasisService }

constructor TOasisService.Create(const AServiceName: string);
begin
  inherited Create('');
  if AServiceName = '' then
    raise EOasisError.Create('TOasisService requires a non-empty service name');
  FServiceName := AServiceName;
end;

procedure TOasisService.Apply(const Ctx: IOasisContext);
begin
  inherited Apply(Ctx);
  // Weak reference: the context owns the service lifetime while it is loaded.
  FContextRef := TObject(Ctx); // weak reference: interface -> implementor object
  Ctx.Provide(FServiceName, Self);
end;

function TOasisService.GetContext: IOasisContext;
begin
  if (FContextRef = nil) or not Supports(FContextRef, IOasisContext, Result) then
    Result := nil;
end;

end.
