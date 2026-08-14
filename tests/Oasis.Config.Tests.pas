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
begin
  { TContext.Plugin isolates Apply failures (swallows + rolls back), so a bad
    config file surfaces as: no IOasisConfig registered, and consumers that
    inject it stay PENDING (visible) instead of running on defaults. }
  Host := THost.Create;
  try
    LConsumer := TNamedPlugin.Create('needs-config');
    LConsumer.AddInject(IOasisConfig);
    Host.Mount(LConsumer);
    Host.Mount(TJsonConfigPlugin.Create('Z:\no\such\file.json'));
    Host.Start;
    Assert.IsFalse(Host.Root.Services.Has(IOasisConfig));
    Assert.AreEqual(1, Length(Host.PendingPlugins));
    Assert.AreEqual('needs-config', Host.PendingPlugins[0]);
  finally
    Host.Free;
  end;
end;

initialization
  TDUnitX.RegisterTestFixture(TConfigTests);

end.
