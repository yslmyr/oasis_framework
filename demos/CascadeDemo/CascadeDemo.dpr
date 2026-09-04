program CascadeDemo;

{$APPTYPE CONSOLE}

(* Oasis demo - dependency deactivation cascade + per-plugin reload/unload.

  A GreeterPlugin provides an IGreeting service; a ConsumerPlugin injects it
  and listens for 'app/ping'. The run shows four phases:

    1. both mounted  -> ping reaches the consumer (it greets)
    2. Unload('greeter') -> the service vanishes, the consumer is deactivated
       (cascade) and re-queued; ping reaches nobody
    3. provider remounted -> the consumer re-activates automatically; ping
       works again
    4. Reload('greeter') -> only the provider is disposed+remounted; the
       consumer keeps working (and listeners are not duplicated) *)

uses
  System.SysUtils,
  Oasis.Types in '..\..\src\Oasis.Core\Oasis.Types.pas',
  Oasis.Spin in '..\..\src\Oasis.Core\Oasis.Spin.pas',
  Oasis.Errors in '..\..\src\Oasis.Core\Oasis.Errors.pas',
  Oasis.Effects in '..\..\src\Oasis.Core\Oasis.Effects.pas',
  Oasis.Services in '..\..\src\Oasis.Core\Oasis.Services.pas',
  Oasis.Events in '..\..\src\Oasis.Core\Oasis.Events.pas',
  Oasis.Inject in '..\..\src\Oasis.Core\Oasis.Inject.pas',
  Oasis.Context in '..\..\src\Oasis.Core\Oasis.Context.pas',
  Oasis.Plugin in '..\..\src\Oasis.Core\Oasis.Plugin.pas',
  Oasis.Loader in '..\..\src\Oasis.Hosting\Oasis.Loader.pas',
  Oasis.Host in '..\..\src\Oasis.Hosting\Oasis.Host.pas',
  Oasis.Config in '..\..\src\Oasis.Hosting\Oasis.Config.pas';

type
  IGreeting = interface
    ['{AAAAAAAA-0000-0000-0000-00000000000A}']
    function Greet(const AWho: string): string;
  end;

  TGreetingImpl = class(TInterfacedObject, IGreeting)
  public
    function Greet(const AWho: string): string;
  end;

  TGreeterPlugin = class(TOasisPlugin)
  public
    constructor Create;
    procedure Apply(const Ctx: IContext); override;
  end;

  TConsumerPlugin = class(TOasisPlugin)
  public
    constructor Create;
    procedure Apply(const Ctx: IContext); override;
  end;

function TGreetingImpl.Greet(const AWho: string): string;
begin
  Result := 'Hello, ' + AWho + '!';
end;

constructor TGreeterPlugin.Create;
begin
  inherited Create('greeter');
end;

procedure TGreeterPlugin.Apply(const Ctx: IContext);
begin
  Ctx.Services.Register(IGreeting, TGreetingImpl.Create);
end;

constructor TConsumerPlugin.Create;
begin
  inherited Create('consumer');
  AddInject(IGreeting);
end;

procedure TConsumerPlugin.Apply(const Ctx: IContext);
var
  LGreeting: IGreeting;
begin
  LGreeting := Ctx.Services.Get(IGreeting) as IGreeting;
  Ctx.Events.On('app/ping',
    procedure(const A: array of const)
    var
      LWho: string;
    begin
      if Length(A) > 0 then
        LWho := string(A[0].VUnicodeString)
      else
        LWho := 'world';
      Writeln('  [consumer] ', LGreeting.Greet(LWho));
    end);
end;

var
  Host: THost;
begin
  ReportMemoryLeaksOnShutdown := True;
  Host := THost.Create;
  try
    Writeln('--- phase 1: both plugins mounted ---');
    Host.Mount(TConsumerPlugin.Create);
    Host.Mount(TGreeterPlugin.Create);
    Host.Start;
    Host.Root.Events.Emit('app/ping', ['Delphi']);

    Writeln('--- phase 2: Unload(greeter) -> cascade deactivates the consumer ---');
    Host.Root.Unload('greeter');
    Writeln('  pending consumers: ', Length(Host.PendingPlugins));
    Host.Root.Events.Emit('app/ping', ['nobody home']);
    Writeln('  (no output above: the consumer is deactivated)');

    Writeln('--- phase 3: provider returns -> consumer re-activates ---');
    Host.Mount(TGreeterPlugin.Create);
    Host.Root.Events.Emit('app/ping', ['again']);

    Writeln('--- phase 4: Reload(greeter) -> only the provider restarts ---');
    Host.Root.Reload('greeter');
    Host.Root.Events.Emit('app/ping', ['after reload']);
    Writeln('  (exactly one greeting per ping: listeners are fiber-scoped)');

    Host.Shutdown;
    Writeln('Done.');
  finally
    Host.Free;
  end;
end.
