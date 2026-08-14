unit Oasis.Hosting.Tests;

interface

uses
  DUnitX.TestFramework, System.SysUtils, System.Generics.Collections,
  Oasis.Types, Oasis.Errors, Oasis.Context, Oasis.Plugin,
  Oasis.Loader, Oasis.Host;

type
  IGreeter = interface
    ['{33333333-0000-0000-0000-000000000003}']
    function Greet(const AWho: string): string;
  end;

  TGreeterImpl = class(TInterfacedObject, IGreeter)
  public
    function Greet(const AWho: string): string;
  end;

  TGreeterPlugin = class(TOasisPlugin)
  public
    constructor Create;
    procedure Apply(const Ctx: IContext); override;
  end;

  TConsumerPlugin = class(TOasisPlugin)
  strict private
    FTrace: TList<string>;
  public
    constructor Create(ATrace: TList<string>);
    procedure Apply(const Ctx: IContext); override;
  end;

  [TestFixture]
  THostTests = class
  public
    [Test]
    procedure Dependency_Registered_Later_Activates_Consumer;

    [Test]
    procedure Missing_Dependency_Leaves_Plugin_Pending;

    [Test]
    procedure Lifecycle_Events_Fire_In_Order;

    [Test]
    procedure Provider_Unload_Cascades_To_Consumer_And_Back;
  end;

implementation

{ TGreeterImpl }

function TGreeterImpl.Greet(const AWho: string): string;
begin
  Result := 'Hello, ' + AWho;
end;

{ TGreeterPlugin }

constructor TGreeterPlugin.Create;
begin
  inherited Create('greeter');
end;

procedure TGreeterPlugin.Apply(const Ctx: IContext);
begin
  Ctx.Services.Register(IGreeter, TGreeterImpl.Create);
end;

{ TConsumerPlugin }

constructor TConsumerPlugin.Create(ATrace: TList<string>);
begin
  inherited Create('consumer');
  FTrace := ATrace;
  AddInject(IGreeter);
end;

procedure TConsumerPlugin.Apply(const Ctx: IContext);
var
  G: IGreeter;
begin
  G := Ctx.Services.Get(IGreeter) as IGreeter;
  FTrace.Add(G.Greet('Delphi'));
  Ctx.Effects.AddCleanup(procedure begin FTrace.Add('consumer.unload'); end);
end;

{ THostTests }

procedure THostTests.Dependency_Registered_Later_Activates_Consumer;
var
  Host: THost;
  Trace: TList<string>;
begin
  Trace := TList<string>.Create;
  try
    Host := THost.Create;
    try
      Host.Mount(TConsumerPlugin.Create(Trace));   // mounts first, stays pending
      Host.Mount(TGreeterPlugin.Create);           // provides IGreeter -> consumer activates
      Assert.AreEqual(1, Trace.Count);
      Assert.AreEqual('Hello, Delphi', Trace[0]);
    finally
      Host.Free;
    end;
  finally
    Trace.Free;
  end;
end;

procedure THostTests.Missing_Dependency_Leaves_Plugin_Pending;
var
  Host: THost;
  Junk: TList<string>;
begin
  Junk := TList<string>.Create;
  try
    Host := THost.Create;
    try
      Host.Mount(TConsumerPlugin.Create(Junk));    // never satisfied
      Assert.AreEqual(1, Length(Host.PendingPlugins));
    finally
      Host.Free;
    end;
  finally
    Junk.Free;
  end;
end;

procedure THostTests.Lifecycle_Events_Fire_In_Order;
var
  Host: THost;
  Trace: TList<string>;
begin
  Trace := TList<string>.Create;
  try
    Host := THost.Create;
    Host.Root.Events.On(EV_HOST_STARTING, procedure(const A: array of const) begin Trace.Add('starting'); end);
    Host.Root.Events.On(EV_HOST_STARTED,  procedure(const A: array of const) begin Trace.Add('started'); end);
    Host.Root.Events.On(EV_HOST_STOPPING, procedure(const A: array of const) begin Trace.Add('stopping'); end);
    try
      Host.Start;
      Host.Shutdown;
    finally
      Host.Free;
    end;
    Assert.AreEqual(3, Trace.Count);
    Assert.AreEqual('starting', Trace[0]);
    Assert.AreEqual('started',  Trace[1]);
    Assert.AreEqual('stopping', Trace[2]);
  finally
    Trace.Free;
  end;
end;

procedure THostTests.Provider_Unload_Cascades_To_Consumer_And_Back;
var
  Host: THost;
  Trace: TList<string>;
begin
  Trace := TList<string>.Create;
  try
    Host := THost.Create;
    try
      Host.Mount(TConsumerPlugin.Create(Trace));   { pending: no IGreeter yet }
      Host.Mount(TGreeterPlugin.Create);            { provider -> consumer activates }
      Host.Start;
      Assert.AreEqual(1, Trace.Count);              { consumer ran }

      { Unload the provider: its fiber-owned IGreeter unregisters, OnServiceRemoved
        fires, the consumer is unloaded (cleanup trace) and requeued. }
      Assert.IsTrue(Host.Root.Unload('greeter'));
      Assert.AreEqual(1, Length(Host.PendingPlugins));
      Assert.AreEqual('consumer.unload', Trace[1]);
      Assert.IsFalse(Host.Root.Services.Has(IGreeter));

      { Remount the provider: the pending consumer re-activates automatically. }
      Host.Mount(TGreeterPlugin.Create);
      Assert.AreEqual(0, Length(Host.PendingPlugins));
      Assert.AreEqual(3, Trace.Count);              { greet, unload, greet again }
      Assert.AreEqual('Hello, Delphi', Trace[2]);
    finally
      Host.Free;
    end;
  finally
    Trace.Free;
  end;
end;

initialization
  TDUnitX.RegisterTestFixture(THostTests);

end.
