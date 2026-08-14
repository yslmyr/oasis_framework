unit TestPlugins;

{ Plugin fixtures for the Oasis self-tests. }

interface

uses
  System.SysUtils,
  Oasis.Core,
  Oasis.Config,
  Oasis.Plugin;

var
  TestDisposeLog: string;

type
  TTestService = class(TOasisService)
  strict private
    FTag: string;
  public
    constructor Create(const AServiceName: string; const ATag: string); reintroduce;
    property Tag: string read FTag;
  end;

  TTestProvider = class(TOasisService)
  strict private
    FLoads: Integer;
  public
    constructor Create(const AServiceName: string); reintroduce;
    procedure Apply(const Ctx: IOasisContext); override;
    property Loads: Integer read FLoads;
  end;

  TTestConsumer = class(TOasisPlugin)
  strict private
    FApplies: Integer;
    FUnloads: Integer;
  protected
    procedure OnApply(const Ctx: IOasisContext); override;
    procedure OnUnload(const Ctx: IOasisContext); override;
  public
    constructor Create(const APluginName: string; const AInject: array of string); reintroduce;
    property Applies: Integer read FApplies;
    property Unloads: Integer read FUnloads;
  end;

  TConfigTarget = class(TOasisConfig)
  strict private
    FDisplayName: string;
    FPort: Integer;
  published
    [OasisConfig('display name', True)]
    property DisplayName: string read FDisplayName write FDisplayName;
    [OasisConfig('port', False, 1, 65535)]
    property Port: Integer read FPort write FPort;
  end;

  TConfigPlugin = class(TOasisPlugin<TConfigTarget>)
  public
    constructor Create; reintroduce;
  end;

implementation

{ TTestService }

constructor TTestService.Create(const AServiceName: string; const ATag: string);
begin
  inherited Create(AServiceName);
  FTag := ATag;
end;

{ TTestProvider }

constructor TTestProvider.Create(const AServiceName: string);
begin
  inherited Create(AServiceName);
end;

procedure TTestProvider.Apply(const Ctx: IOasisContext);
begin
  Inc(FLoads);
  inherited Apply(Ctx);
end;

{ TTestConsumer }

constructor TTestConsumer.Create(const APluginName: string; const AInject: array of string);
begin
  inherited Create(APluginName);
  InjectServices(AInject);
end;

procedure TTestConsumer.OnApply(const Ctx: IOasisContext);
begin
  Inc(FApplies);
end;

procedure TTestConsumer.OnUnload(const Ctx: IOasisContext);
begin
  Inc(FUnloads);
end;

{ TConfigPlugin }

constructor TConfigPlugin.Create;
begin
  inherited Create;
end;

end.
