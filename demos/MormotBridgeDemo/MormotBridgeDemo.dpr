program MormotBridgeDemo;

{$APPTYPE CONSOLE}

{ Oasis demo - mORMot2 DI bridge, both directions (ConsoleDemo style).

  Forward: a standalone TInterfaceResolverList holding one shared instance is
  mirrored into Oasis as per-resolve factories; a consumer plugin gets it via
  [Inject]; unloading the bridge cascades the consumer.
  Reverse: a mORMot TInterfaceResolverInjected resolves an Oasis-registered
  service through TOasisResolver.

  Needs a local mormot2 checkout on the unit search path (see build.cmd). }

uses
  System.SysUtils,
  Oasis.Types in '..\..\src\Oasis.Core\Oasis.Types.pas',
  Oasis.Errors in '..\..\src\Oasis.Core\Oasis.Errors.pas',
  Oasis.Spin in '..\..\src\Oasis.Core\Oasis.Spin.pas',
  Oasis.Effects in '..\..\src\Oasis.Core\Oasis.Effects.pas',
  Oasis.Services in '..\..\src\Oasis.Core\Oasis.Services.pas',
  Oasis.Events in '..\..\src\Oasis.Core\Oasis.Events.pas',
  Oasis.Inject in '..\..\src\Oasis.Core\Oasis.Inject.pas',
  Oasis.Context in '..\..\src\Oasis.Core\Oasis.Context.pas',
  Oasis.Plugin in '..\..\src\Oasis.Core\Oasis.Plugin.pas',
  Oasis.Loader in '..\..\src\Oasis.Hosting\Oasis.Loader.pas',
  Oasis.Config in '..\..\src\Oasis.Hosting\Oasis.Config.pas',
  Oasis.Host in '..\..\src\Oasis.Hosting\Oasis.Host.pas',
  Oasis.Mormot in '..\..\src\Oasis.Mormot\Oasis.Mormot.pas',
  mormot.core.base, mormot.core.interfaces;

type
  IGreeter = interface
    ['{44444444-0000-0000-0000-000000000001}']
    function Greet(const AWho: string): string;
  end;

  TGreeterImpl = class(TInterfacedObject, IGreeter)
  public
    function Greet(const AWho: string): string;
  end;

  TConsumerPlugin = class(TOasisPlugin)
  strict private
    [Inject] FGreeter: IGreeter;
  public
    constructor Create;
    procedure Apply(const Ctx: IContext); override;
  end;

function TGreeterImpl.Greet(const AWho: string): string;
begin
  Result := 'Hello from mORMot, ' + AWho;
end;

constructor TConsumerPlugin.Create;
begin
  inherited Create('consumer');
end;

procedure TConsumerPlugin.Apply(const Ctx: IContext);
begin
  Writeln('  [consumer] ', FGreeter.Greet('Oasis'));
end;

var
  Host: THost;
  List: TInterfaceResolverList;
  Bridge: TMormotServicesPlugin;
  Ctx: IContext;
  Inj: TInterfaceResolverInjected;
  G: IGreeter;
begin
  ReportMemoryLeaksOnShutdown := True;
  Writeln('--- forward: mORMot container -> Oasis [Inject] consumer ---');
  Host := THost.Create;
  try
    List := TInterfaceResolverList.Create;
    List.Add(TypeInfo(IGreeter), TGreeterImpl.Create);
    Bridge := TMormotServicesPlugin.Create(List, [TypeInfo(IGreeter)], {OwnsResolver=}True);
    Host.Mount(Bridge);
    Host.Mount(TConsumerPlugin.Create);
    Host.Start;
    Writeln('  unload bridge -> consumer cascades:');
    Host.Root.Unload('mormot-services');
    Writeln('  pending consumers: ', Length(Host.PendingPlugins));
    Host.Shutdown;
  finally
    Host.Free;
  end;

  Writeln('--- reverse: Oasis registry -> mORMot resolver ---');
  Ctx := TContext.Create('demo');
  Ctx.Services.Register(IGreeter, TGreeterImpl.Create);
  Inj := TInterfaceResolverInjected.Create;
  try
    Inj.InjectResolver([TOasisResolver.Create(Ctx.Services)], True);
    if Inj.Resolve(TypeInfo(IGreeter), G) then
      Writeln('  [mormot] ', G.Greet('via resolver'))
    else
      Writeln('  [mormot] resolve FAILED');
  finally
    Inj.Free;
  end;
  Ctx.Dispose;
  Writeln('Done.');
end.
