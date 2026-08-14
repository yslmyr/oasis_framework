program OasisDemo;

{ Oasis plugin framework demo: every Cordis design concept, runnable.
  Walk the console output top to bottom; each section asserts the contract
  it demonstrates. }

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  System.Classes,
  System.Rtti,
  System.DateUtils,
  Oasis.Core in '..\src\Oasis.Core.pas',
  Oasis.Config in '..\src\Oasis.Config.pas',
  Oasis.Plugin in '..\src\Oasis.Plugin.pas',
  Oasis.Context in '..\src\Oasis.Context.pas',
  DemoPlugins in 'DemoPlugins.pas',
  OasisTestHarness in '..\tests\OasisTestHarness.pas';

var
  Harness: TTestHarness;
  Root: IOasisContext;
  Consumer: TGreeterConsumer;
  ConsumerFiber: IOasisFiber;
  GreeterFiber: IOasisFiber;
  ProviderFiber: IOasisFiber;
  HeartbeatFiber: IOasisFiber;
  OrderFiber: IOasisFiber;
  BadFiber: IOasisFiber;
  GoodFiber: IOasisFiber;
  Child: IOasisContext;
  Greeter: TGreeterService;
  Stats: TStatsService;
  WaterfallDefault: TOasisWaterfallDefault;
  StartTime: TDateTime;
  Elapsed: Integer;
  Value: TValue;
  BadServer: TServerPlugin;
  GoodServer: TServerPlugin;

begin
  Harness := TTestHarness.Create;
  try
    Writeln('============================================================');
    Writeln(' Oasis - a Cordis-style plugin framework for Delphi');
    Writeln(' (services, inject/PENDING, five event modes, effects,');
    Writeln('  config validation, hot replacement, fork scoping)');
    Writeln('============================================================');
    DemoLog := '';
    EffectOrderLog := '';
    Root := TOasisContext.Create('demo');
    try
      { ----------------------------------------------------------
        1. Services + inject: load order is expressed through service
           requirements, not boot sequencing.
        ---------------------------------------------------------- }
      Writeln;
      Writeln('== 1. inject: dependencies, not file order, decide startup ==');

      // Optional dependency probe (no inject declaration).
      Root.Plugin(TProbePlugin.Create);
      Harness.Expect(Pos('probe: no greeter available', DemoLog) > 0,
        'optional dependency probe sees the missing service as nil');

      Consumer := TGreeterConsumer.Create;
      ConsumerFiber := Root.Plugin(Consumer);
      Harness.Expect(ConsumerFiber.State = fsPending,
        'consumer (declares "greeter") waits in PENDING before its provider');
      Harness.Expect(Consumer.Greets = 0, 'Apply is not called while PENDING');

      GreeterFiber := Root.Plugin(TGreeterService.Create('greeter', 'Hello'));
      Harness.Expect(ConsumerFiber.State = fsActive,
        'consumer activates the moment "greeter" exists');
      Harness.Expect(Consumer.Greets = 1, 'Apply ran exactly once');

      Greeter := Root.ServiceObject('greeter') as TGreeterService;
      Harness.Expect(Greeter.Greet('world') = 'Hello, world!',
        'typed service lookup by stable key');

      Root.Plugin(TProbePlugin.Create);
      Harness.Expect(Pos('probe: Hello, probe!', DemoLog) > 0,
        'optional dependency probe finds the service once provided');

      { ----------------------------------------------------------
        2. emit: announce without knowing who listens.
        ---------------------------------------------------------- }
      Writeln;
      Writeln('== 2. emit: announce without knowing who listens ==');
      Root.Plugin(TStatsReporter.Create);      // declared first: waits for "stats"
      Root.Plugin(TStatsService.Create('stats'));
      Stats := Root.ServiceObject('stats') as TStatsService;
      Harness.Expect(Stats.CountOf('tool_call') = 2,
        'emit listeners observed every bump (registration-order broadcast)');

      { ----------------------------------------------------------
        3. bail / serial: first truthy result wins, chain stops.
        ---------------------------------------------------------- }
      Writeln;
      Writeln('== 3. bail / serial: first truthy value wins ==');
      Root.Plugin(TBailDemoPlugin.Create);
      Value := Root.Bail('demo/decision', OasisArgs(['q']));
      Harness.Expect(Value.AsString = 'first',
        'bail returned the first listener value');
      Value := Root.Serial('demo/decision', OasisArgs(['q']));
      Harness.Expect(Value.AsString = 'first',
        'serial returned the first listener value');

      { ----------------------------------------------------------
        4. parallel: every listener runs concurrently, awaited together.
        ---------------------------------------------------------- }
      Writeln;
      Writeln('== 4. parallel: listeners run concurrently ==');
      Root.Plugin(TParallelDemoPlugin.Create);
      StartTime := Now;
      Root.Parallel('demo/parallel', OasisArgs(['x']));
      Elapsed := MilliSecondsBetween(Now, StartTime);
      Harness.Expect(Elapsed > 200,
        Format('listeners overlapped (elapsed %d ms vs 400 ms serial)', [Elapsed]));
      Harness.Expect(Elapsed < 900, 'parallel waits for every listener');

      { ----------------------------------------------------------
        5. waterfall: wrap or veto.
        ---------------------------------------------------------- }
      Writeln;
      Writeln('== 5. waterfall: around-middleware with next() ==');
      WaterfallDefault :=
        function(const Args: TOasisArgs): TValue
        begin
          Result := Args[0];
        end;
      Root.Plugin(TWaterfallDemoPlugin.Create);
      Value := Root.Waterfall('demo/transform', OasisArgs(['hello']), WaterfallDefault);
      Harness.Expect(Value.AsString = 'HELLO',
        'listener wrapped the default result (next() delegation)');
      Value := Root.Waterfall('demo/transform', OasisArgs(['blocked words']), WaterfallDefault);
      Harness.Expect(Value.AsString = '** BLOCKED **',
        'listener vetoed: short-circuit without next() (outer listener still wraps)');

      { ----------------------------------------------------------
        6. effects: registrations are reversible; disposers run LIFO.
        ---------------------------------------------------------- }
      Writeln;
      Writeln('== 6. effects: reversible registrations, LIFO teardown ==');
      HeartbeatFiber := Root.Plugin(THeartbeatPlugin.Create);
      TThread.Sleep(650); // let the background thread tick
      EffectOrderLog := '';
      OrderFiber := Root.Plugin(TEffectOrderPlugin.Create);
      OrderFiber.Dispose;
      Harness.Expect(EffectOrderLog = '21',
        'disposers run in reverse registration order');
      HeartbeatFiber.Dispose;
      Harness.Expect(Pos('heartbeat cleaned up', DemoLog) > 0,
        'ctx.Effect released the unmanaged thread resource');

      { ----------------------------------------------------------
        7. Hot replacement: a service disappears -> dependents unload
           and reload when it returns.
        ---------------------------------------------------------- }
      Writeln;
      Writeln('== 7. service replacement: dependents unload and reload ==');
      GreeterFiber.Dispose;
      Harness.Expect(ConsumerFiber.State = fsPending,
        'consumer unloaded when "greeter" was removed');
      Harness.Expect(Consumer.Unloads = 1, 'consumer got its unload notification');
      ProviderFiber := Root.Plugin(TGreeterService.Create('greeter', 'Hi'));
      Harness.Expect(ConsumerFiber.State = fsActive,
        'consumer reloaded against the new provider');
      Harness.Expect(Consumer.Greets = 2, 'Apply re-ran on reload');
      Harness.Expect((Root.ServiceObject('greeter') as TGreeterService).Greet('oasis') = 'Hi, oasis!',
        'the replacement provider answers');

      { ----------------------------------------------------------
        8. Config validation fails the fiber loudly.
        ---------------------------------------------------------- }
      Writeln;
      Writeln('== 8. config validation: fail loud on bad input ==');
      BadServer := TServerPlugin.Create;
      BadServer.Config.Port := 0; // below the declared minimum
      BadFiber := Root.Plugin(BadServer);
      Harness.Expect(BadFiber.State = fsFailed,
        'invalid config failed the fiber instead of half-running');
      Writeln('  [config] error: ', BadFiber.Error.Message);
      GoodServer := TServerPlugin.Create;
      GoodServer.Config.Port := 8080;
      GoodFiber := Root.Plugin(GoodServer);
      Harness.Expect(GoodFiber.State = fsActive, 'valid config activated');

      { ----------------------------------------------------------
        9. Function-form plugins with declared dependencies.
        ---------------------------------------------------------- }
      Writeln;
      Writeln('== 9. function plugins: anonymous Apply with inject ==');
      Root.Plugin('fn-consumer',
        procedure(C: IOasisContext)
        begin
          DemoLogAdd('fn: ' + (C.ServiceObject('fn-service') as TGreeterService).Greet('anon'));
        end,
        ['fn-service']);
      Root.Plugin('fn-provider',
        procedure(C: IOasisContext)
        begin
          // A provider plugin mounts its service as a child plugin, so the
          // registration and its teardown ride the child fiber.
          C.Plugin(TGreeterService.Create('fn-service', 'FN'));
        end);
      Harness.Expect(Pos('fn: FN, anon!', DemoLog) > 0,
        'function-form consumer activated after its provider');

      { ----------------------------------------------------------
        10. Fork: scoped plugins, inherited services, bubbling events.
        ---------------------------------------------------------- }
      Writeln;
      Writeln('== 10. fork: child scopes inherit services, bubble events ==');
      Root.Plugin(TBubbleCatcher.Create);
      Child := Root.Fork('child');
      Harness.Expect(Child.Has('greeter'), 'fork sees parent services');
      Child.Plugin(TInheritedGreeterUser.Create);
      Harness.Expect(Pos('fork-greet: Hi, fork!', DemoLog) > 0,
        'child plugin resolved the inherited service');
      Child.Plugin('child-only-service',
        procedure(C: IOasisContext)
        begin
          C.Plugin(TGreeterService.Create('child-only', 'Scoped'));
        end);
      Harness.Expect(Child.Has('child-only'), 'child sees its own service');
      Harness.Expect(not Root.Has('child-only'),
        'parent does not see child services (isolation)');
      Child.Plugin(TChildEmitter.Create);
      Harness.Expect(Pos('child:ping;parent:ping;', DemoLog) > 0,
        'events bubble from the fork up to the parent (child first)');
      Child.Dispose;

      { ----------------------------------------------------------
        11. Root disposal unwinds everything.
        ---------------------------------------------------------- }
      Writeln;
      Writeln('== 11. disposing the root context unwinds everything ==');
      Root.Dispose;
      Harness.Expect(Root.Disposed, 'context reports disposed');
      Root.Dispose; // idempotent
    finally
      Root := nil;
    end;

    Writeln;
    Writeln('============================================================');
    Writeln(' Demo result: ', Harness.Summary);
    Writeln('============================================================');
    if Harness.Failed > 0 then
      ExitCode := 1;
  finally
    Harness.Free;
  end;
end.
