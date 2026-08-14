unit SamplePlugin;

{ Sample BPL plugin. Implements IPlugin (via TOasisPlugin), registers an IGreeting
  service on Apply. A TSamplePluginFactory (a TOasisPluginFactory, i.e. a
  refcounted TPersistent) is registered under OASIS_BPL_FACTORY_CLASS in the
  initialization section so the host's TBplPluginLoader can find it via
  FindClass and construct plugins through IOasisPluginFactory. }

interface

uses
  System.Classes,
  Oasis.Context, Oasis.Plugin, Oasis.BplContract, SampleContract;

type
  TGreetingImpl = class(TInterfacedObject, IGreeting)
  public
    function Greet(const AWho: string): string;
  end;

  TSamplePlugin = class(TOasisPlugin)
  public
    constructor Create;
    procedure Apply(const Ctx: IContext); override;
  end;

  TSamplePluginFactory = class(TOasisPluginFactory)
  public
    function CreatePlugin: IPlugin; override;
  end;

implementation

function TSamplePluginFactory.CreatePlugin: IPlugin;
begin
  Result := TSamplePlugin.Create;
end;

function TGreetingImpl.Greet(const AWho: string): string;
begin
  Result := 'Hello from BPL, ' + AWho;
end;

constructor TSamplePlugin.Create;
begin
  inherited Create('sample-bpl');
end;

procedure TSamplePlugin.Apply(const Ctx: IContext);
begin
  Ctx.Services.Register(IGreeting, TGreetingImpl.Create);
end;

initialization
  RegisterClassAlias(TSamplePluginFactory, OASIS_BPL_FACTORY_CLASS);

end.
