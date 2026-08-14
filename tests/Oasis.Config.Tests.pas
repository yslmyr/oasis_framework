unit Oasis.Config.Tests;

interface

uses
  DUnitX.TestFramework, System.SysUtils, System.IOUtils,
  Oasis.Context, Oasis.Plugin, Oasis.Loader, Oasis.Host, Oasis.Config;

type
  TNamedPlugin = class(TOasisPlugin)
  public
    constructor Create(const AName: string); reintroduce;
    procedure Apply(const Ctx: IContext); override;
  end;

  [TestFixture]
  TConfigTests = class
  public
    [Test]
    procedure JsonConfig_Exposes_Disabled_And_Values;

    [Test]
    procedure TryMount_Skips_Disabled_Plugin;

    [Test]
    procedure Missing_File_Fails_The_Plugin;

    [Test]
    procedure Env_Layer_Overrides_Base_Without_Erasing_It;

    [Test]
    procedure Typed_Readers_Int_Bool_Float_With_Fallbacks;
  end;

implementation

{ TNamedPlugin }

constructor TNamedPlugin.Create(const AName: string);
begin
  inherited Create(AName);
end;

procedure TNamedPlugin.Apply(const Ctx: IContext);
begin
  { nothing - only the name matters for these tests }
end;

{ TConfigTests }

procedure TConfigTests.JsonConfig_Exposes_Disabled_And_Values;
var
  Ctx: IContext;
  LPath: string;
  LCfg: IOasisConfig;
begin
  LPath := TPath.Combine(TPath.GetTempPath, 'oasis_cfg_test.json');
  TFile.WriteAllText(LPath,
    '{"plugins":{' +
    '"greeter":{"disabled":true,"config":{"prefix":"Hi"}},' +
    '"server":{"config":{"port":"8080"}}}}');
  try
    Ctx := TContext.Create('root');
    Ctx.Plugin(TJsonConfigPlugin.Create(LPath));
    LCfg := Ctx.Services.Get(IOasisConfig) as IOasisConfig;
    Assert.IsTrue(LCfg.Disabled('greeter'));
    Assert.IsFalse(LCfg.Disabled('server'));
    Assert.IsFalse(LCfg.Disabled('unknown'));
    Assert.AreEqual('Hi', LCfg.Value('greeter', 'prefix', 'dflt'));
    Assert.AreEqual('8080', LCfg.Value('server', 'port', '0'));
    Assert.AreEqual('dflt', LCfg.Value('server', 'missing', 'dflt'));
    Assert.IsTrue(LCfg.HasValue('server', 'port'));
    Assert.IsFalse(LCfg.HasValue('server', 'missing'));
    Ctx.Dispose;
  finally
    TFile.Delete(LPath);
  end;
end;

procedure TConfigTests.TryMount_Skips_Disabled_Plugin;
var
  Host: THost;
  LPath: string;
begin
  LPath := TPath.Combine(TPath.GetTempPath, 'oasis_cfg_trymount.json');
  TFile.WriteAllText(LPath,
    '{"plugins":{"off-plugin":{"disabled":true},"on-plugin":{}}}');
  try
    Host := THost.Create;
    try
      Host.Mount(TJsonConfigPlugin.Create(LPath));
      Host.Start;
      Assert.IsFalse(Host.TryMount(TNamedPlugin.Create('off-plugin')));
      Assert.IsTrue(Host.TryMount(TNamedPlugin.Create('on-plugin')));
      Assert.AreEqual(0, Length(Host.PendingPlugins));
      Assert.AreEqual(0, Length(Host.FailedPlugins));
    finally
      Host.Free;
    end;
  finally
    TFile.Delete(LPath);
  end;
end;

procedure TConfigTests.Missing_File_Fails_The_Plugin;
var
  Host: THost;
  LConsumer: TNamedPlugin;
  LFailEvent: Integer;
begin
  { A bad config file now surfaces BOTH ways: FailedPlugins records the name
    (via the OnPluginFailed hook) + EV_HOST_PLUGIN_FAILED fires, AND consumers
    that inject IOasisConfig stay PENDING instead of running on defaults. }
  Host := THost.Create;
  try
    LFailEvent := 0;
    Host.Root.Events.On(EV_HOST_PLUGIN_FAILED,
      procedure(const A: array of const) begin Inc(LFailEvent); end);
    LConsumer := TNamedPlugin.Create('needs-config');
    LConsumer.AddInject(IOasisConfig);
    Host.Mount(LConsumer);
    Host.Mount(TJsonConfigPlugin.Create('Z:\no\such\file.json'));
    Host.Start;
    Assert.IsFalse(Host.Root.Services.Has(IOasisConfig));
    Assert.AreEqual(1, Length(Host.FailedPlugins));
    Assert.AreEqual('json-config', Host.FailedPlugins[0]);
    Assert.AreEqual(1, LFailEvent);
    Assert.AreEqual(1, Length(Host.PendingPlugins));
    Assert.AreEqual('needs-config', Host.PendingPlugins[0]);
  finally
    Host.Free;
  end;
end;

procedure TConfigTests.Env_Layer_Overrides_Base_Without_Erasing_It;
var
  Ctx: IContext;
  LPath: string;
  LCfg: IOasisConfig;
begin
  LPath := TPath.Combine(TPath.GetTempPath, 'oasis_cfg_layers.json');
  TFile.WriteAllText(LPath,
    '{"plugins":{' +
    '"api":{"disabled":false,"config":{"port":"8080","prefix":"Hi"}}},' +
    '"env":{' +
    '"production":{"plugins":{' +
    '"api":{"disabled":true,"config":{"port":"9090"}},' +
    '"extra":{"config":{"only":"env"}}}}}}');
  try
    { with the env layer: overrides apply, unmentioned base keys survive }
    Ctx := TContext.Create('root');
    Ctx.Plugin(TJsonConfigPlugin.Create(LPath, 'production'));
    LCfg := Ctx.Services.Get(IOasisConfig) as IOasisConfig;
    Assert.IsTrue(LCfg.Disabled('api'));                 { env overrode false->true }
    Assert.AreEqual('9090', LCfg.Value('api', 'port', ''));   { env value }
    Assert.AreEqual('Hi', LCfg.Value('api', 'prefix', ''));   { base survives }
    Assert.AreEqual('env', LCfg.Value('extra', 'only', ''));  { env-only plugin }
    Ctx.Dispose;

    { without the env layer: base values intact }
    Ctx := TContext.Create('root2');
    Ctx.Plugin(TJsonConfigPlugin.Create(LPath));
    LCfg := Ctx.Services.Get(IOasisConfig) as IOasisConfig;
    Assert.IsFalse(LCfg.Disabled('api'));
    Assert.AreEqual('8080', LCfg.Value('api', 'port', ''));
    Assert.IsFalse(LCfg.HasValue('extra', 'only'));
    Ctx.Dispose;
  finally
    TFile.Delete(LPath);
  end;
end;

procedure TConfigTests.Typed_Readers_Int_Bool_Float_With_Fallbacks;
var
  Ctx: IContext;
  LPath: string;
  LCfg: IOasisConfig;
begin
  LPath := TPath.Combine(TPath.GetTempPath, 'oasis_cfg_typed.json');
  TFile.WriteAllText(LPath,
    '{"plugins":{"app":{"config":{' +
    '"port":"8080","verbose":"true","ratio":"1.5",' +
    '"badint":"nope","badbool":"yes","badfloat":"x"}}}}');
  try
    Ctx := TContext.Create('root');
    Ctx.Plugin(TJsonConfigPlugin.Create(LPath));
    LCfg := Ctx.Services.Get(IOasisConfig) as IOasisConfig;
    Assert.AreEqual(8080, LCfg.Int('app', 'port', 0));
    Assert.IsTrue(LCfg.Bool('app', 'verbose', False));
    Assert.AreEqual(Double(1.5), LCfg.Float('app', 'ratio', 0));
    { missing keys -> defaults }
    Assert.AreEqual(42, LCfg.Int('app', 'missing', 42));
    Assert.IsTrue(LCfg.Bool('app', 'missing', True));
    { unparseable -> defaults }
    Assert.AreEqual(7, LCfg.Int('app', 'badint', 7));
    Assert.IsTrue(LCfg.Bool('app', 'badbool', True));
    Assert.AreEqual(Double(0.25), LCfg.Float('app', 'badfloat', 0.25));
    Ctx.Dispose;
  finally
    TFile.Delete(LPath);
  end;
end;

initialization
  TDUnitX.RegisterTestFixture(TConfigTests);

end.
