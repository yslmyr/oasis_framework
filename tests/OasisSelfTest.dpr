program OasisSelfTest;

{ Behavioral self-tests for the Oasis framework core. Run after any change:
    cd tests && dcc32 -B -U..\src OasisSelfTest.dpr && OasisSelfTest.exe }

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  System.Rtti,
  Oasis.Core in '..\src\Oasis.Core.pas',
  Oasis.Config in '..\src\Oasis.Config.pas',
  Oasis.Plugin in '..\src\Oasis.Plugin.pas',
  Oasis.Context in '..\src\Oasis.Context.pas',
  TestPlugins in 'TestPlugins.pas',
  OasisTestHarness in 'OasisTestHarness.pas';

procedure TestServices(H: TTestHarness);
var
  Root: IOasisContext;
  Service: TTestService;
begin
  Root := TOasisContext.Create('t-services');
  try
    Root.Plugin(TTestService.Create('test.svc', 'alpha'));
    H.Expect(Root.Has('test.svc'), 'Has finds the provided service');
    H.Expect(not Root.Has('missing'), 'Has is false for unknown services');
    Service := Root.ServiceObject('test.svc') as TTestService;
    H.Expect(Service <> nil, 'ServiceObject resolves the instance');
    H.Expect(Service.Tag = 'alpha', 'resolved instance is the provided one');
    H.Expect(Root.Get('missing').IsEmpty, 'Get returns empty for unknown services');
    H.Expect(Root.ServiceObject('missing') = nil,
      'typed lookup returns nil for unknown services');
  finally
    Root.Dispose;
  end;
end;

procedure TestInjectOrder(H: TTestHarness);
var
  Root: IOasisContext;
  Consumer: TTestConsumer;
  ConsumerFiber: IOasisFiber;
begin
  Root := TOasisContext.Create('t-inject-order');
  try
    Consumer := TTestConsumer.Create('consumer', ['test.svc']);
    ConsumerFiber := Root.Plugin(Consumer);
    H.Expect(ConsumerFiber.State = fsPending, 'consumer is PENDING without its service');
    H.Expect(Consumer.Applies = 0, 'Apply not called while PENDING');
    Root.Plugin(TTestProvider.Create('test.svc'));
    H.Expect(ConsumerFiber.State = fsActive, 'consumer activates when the service appears');
    H.Expect(Consumer.Applies = 1, 'Apply ran exactly once');
    H.Expect(ConsumerFiber.Name = 'consumer', 'fiber carries the plugin name');
    H.Expect(Root.ActivePluginName = '', 'no plugin is loading outside Apply');
  finally
    Root.Dispose;
  end;
end;

procedure TestUnsatisfiedInjection(H: TTestHarness);
var
  Root: IOasisContext;
  Consumer: TTestConsumer;
  ConsumerFiber: IOasisFiber;
begin
  Root := TOasisContext.Create('t-unsatisfied');
  try
    Consumer := TTestConsumer.Create('waiting', ['never.svc', 'test.svc']);
    ConsumerFiber := Root.Plugin(Consumer);
    Root.Plugin(TTestProvider.Create('test.svc'));
    H.Expect(ConsumerFiber.State = fsPending,
      'one missing dependency keeps the plugin PENDING');
    Root.Plugin(TTestProvider.Create('never.svc'));
    H.Expect(ConsumerFiber.State = fsActive,
      'plugin activates once every declared service exists');
  finally
    Root.Dispose;
  end;
end;

procedure TestServiceReplacement(H: TTestHarness);
var
  Root: IOasisContext;
  Consumer: TTestConsumer;
  ConsumerFiber: IOasisFiber;
  ProviderFiber: IOasisFiber;
begin
  Root := TOasisContext.Create('t-replacement');
  try
    Consumer := TTestConsumer.Create('consumer', ['test.svc']);
    ConsumerFiber := Root.Plugin(Consumer);
    ProviderFiber := Root.Plugin(TTestProvider.Create('test.svc'));
    H.Expect(ConsumerFiber.State = fsActive, 'consumer active with provider 1');
    ProviderFiber.Dispose;
    H.Expect(ConsumerFiber.State = fsPending, 'consumer unloaded when its service vanished');
    H.Expect(Consumer.Unloads = 1, 'unload notification delivered');
    Root.Plugin(TTestProvider.Create('test.svc'));
    H.Expect(ConsumerFiber.State = fsActive, 'consumer reloaded when the service returned');
    H.Expect(Consumer.Applies = 2, 'Apply re-ran on reload');
  finally
    Root.Dispose;
  end;
end;

procedure TestDuplicateService(H: TTestHarness);
var
  Root: IOasisContext;
  First: IOasisFiber;
  Second: IOasisFiber;
begin
  Root := TOasisContext.Create('t-duplicate');
  try
    First := Root.Plugin(TTestService.Create('dup', 'a'));
    H.Expect(First.State = fsActive, 'first provider active');
    Second := Root.Plugin(TTestService.Create('dup', 'b'));
    H.Expect(Second.State = fsFailed, 'duplicate service fails the second fiber');
    H.Expect(Second.Error <> nil, 'failure carries an exception');
    H.Expect(Pos('already provided', Second.Error.Message) > 0,
      'failure explains the duplicate');
    H.Expect((Root.ServiceObject('dup') as TTestService).Tag = 'a',
      'the original registration still answers');
  finally
    Root.Dispose;
  end;
end;

procedure TestEmitAndBail(H: TTestHarness);
var
  Root: IOasisContext;
  EmitCount: Integer;
  GotName: string;
  GotCount: Integer;
  OrderLog: string;
  SecondCalled: Boolean;
  Value: TValue;
begin
  Root := TOasisContext.Create('t-events');
  try
    EmitCount := 0;
    OrderLog := '';
    Root.On('t/event',
      procedure(const Args: TOasisArgs)
      begin
        Inc(EmitCount);
        GotName := Args[0].AsString;
        GotCount := Args[1].AsInteger;
      end);
    Root.On('t/event',
      procedure(const Args: TOasisArgs)
      begin
        OrderLog := OrderLog + 'normal;';
      end);
    Root.On('t/event',
      procedure(const Args: TOasisArgs)
      begin
        OrderLog := OrderLog + 'prepend;';
      end, True);
    Root.Emit('t/event', OasisArgs(['hit', 7]));
    H.Expect(EmitCount = 1, 'emit delivered the payload once to each listener');
    H.Expect((GotName = 'hit') and (GotCount = 7), 'payload arguments arrived intact');
    H.Expect(OrderLog = 'prepend;normal;', 'prepend listener ran before ordinary registrations');

    SecondCalled := False;
    Root.On('t/decision',
      function(const Args: TOasisArgs): TValue
      begin
        Result := 'one';
      end);
    Root.On('t/decision',
      function(const Args: TOasisArgs): TValue
      begin
        SecondCalled := True;
        Result := 'two';
      end);
    Value := Root.Bail('t/decision', OasisArgs(['x']));
    H.Expect(Value.AsString = 'one', 'bail returns the first truthy value');
    H.Expect(not SecondCalled, 'bail stopped after the first truthy value');
    Value := Root.Serial('t/decision', OasisArgs(['x']));
    H.Expect(Value.AsString = 'one', 'serial returns the first truthy value');
    H.Expect(Root.Bail('t/nothing', OasisArgs(['x'])).IsEmpty,
      'bail with no listeners returns empty');
  finally
    Root.Dispose;
  end;
end;

procedure TestWaterfall(H: TTestHarness);
var
  Root: IOasisContext;
  Default: TOasisWaterfallDefault;
  Value: TValue;
  OrderLog: string;
begin
  Root := TOasisContext.Create('t-waterfall');
  try
    Default :=
      function(const Args: TOasisArgs): TValue
      begin
        Result := Args[0];
      end;
    H.Expect(Root.Waterfall('t/none', OasisArgs(['raw']), Default).AsString = 'raw',
      'waterfall without listeners returns the default');

    OrderLog := '';
    Root.On('t/flow',
      function(const Args: TOasisArgs; const Next: TOasisNext): TValue
      begin
        OrderLog := OrderLog + 'outer>';
        Result := UpperCase(Next(Args).AsString);
      end);
    Root.On('t/flow',
      function(const Args: TOasisArgs; const Next: TOasisNext): TValue
      begin
        OrderLog := OrderLog + 'inner>';
        if Args[0].AsString = 'veto' then
          Result := 'vetoed!'
        else
          Result := Next(Args);
      end);
    Value := Root.Waterfall('t/flow', OasisArgs(['hello']), Default);
    H.Expect(Value.AsString = 'HELLO', 'listener wrapped the default result');
    H.Expect(OrderLog = 'outer>inner>', 'listeners run outer-to-inner');
    Value := Root.Waterfall('t/flow', OasisArgs(['veto']), Default);
    H.Expect(Value.AsString = 'VETOED!',
      'short-circuit without next() vetoed the chain (outer listener still wraps)');
  finally
    Root.Dispose;
  end;
end;

procedure TestEffects(H: TTestHarness);
var
  Root: IOasisContext;
  Log: string;
  Fiber: IOasisFiber;
  Manual: TOasisDisposer;
begin
  Root := TOasisContext.Create('t-effects');
  try
    Log := '';
    Fiber := Root.Plugin('eff',
      procedure(C: IOasisContext)
      begin
        C.OnDispose(procedure begin Log := Log + '1'; end);
        C.OnDispose(procedure begin Log := Log + '2'; end);
      end);
    H.Expect(Fiber.State = fsActive, 'function plugin active');
    Fiber.Dispose;
    H.Expect(Log = '21', 'disposers run LIFO');

    Log := '';
    Manual := nil;
    Fiber := Root.Plugin('eff2',
      procedure(C: IOasisContext)
      begin
        Manual := C.Effect(
          function: TOasisDisposer
          begin
            Log := Log + 'setup;';
            Result := procedure begin Log := Log + 'release;'; end;
          end);
      end);
    H.Expect(Log = 'setup;', 'Effect runs the setup immediately');
    Manual();
    H.Expect(Log = 'setup;release;', 'manual disposal releases early');
    Fiber.Dispose;
    H.Expect(Log = 'setup;release;', 'released effect is not run twice on unload');
  finally
    Root.Dispose;
  end;
end;

procedure TestChildPlugins(H: TTestHarness);
var
  Root: IOasisContext;
  ParentFiber: IOasisFiber;
  ChildUnloaded: Integer;
  ChildLoaded: Integer;
begin
  Root := TOasisContext.Create('t-children');
  try
    ChildLoaded := 0;
    ChildUnloaded := 0;
    ParentFiber := Root.Plugin('parent',
      procedure(C: IOasisContext)
      begin
        C.Plugin('child',
          procedure(C2: IOasisContext)
          begin
            Inc(ChildLoaded);
            C2.OnDispose(procedure begin Inc(ChildUnloaded); end);
          end);
      end);
    H.Expect(ChildLoaded = 1, 'child plugin mounted by its parent');
    ParentFiber.Dispose;
    H.Expect(ChildUnloaded = 1, 'child plugin disposed with its parent');
  finally
    Root.Dispose;
  end;
end;

procedure TestConfigValidation(H: TTestHarness);
var
  Root: IOasisContext;
  Plugin: TConfigPlugin;
  Fiber: IOasisFiber;
begin
  Root := TOasisContext.Create('t-config');
  try
    Plugin := TConfigPlugin.Create; // DisplayName empty -> invalid
    Fiber := Root.Plugin(Plugin);
    H.Expect(Fiber.State = fsFailed, 'required field missing fails the fiber');
    H.Expect(Pos('DisplayName', Fiber.Error.Message) > 0,
      'error names the offending field');

    Plugin := TConfigPlugin.Create;
    Plugin.Config.DisplayName := 'ok';
    Plugin.Config.Port := 0; // below minimum
    Fiber := Root.Plugin(Plugin);
    H.Expect(Fiber.State = fsFailed, 'value below the minimum fails the fiber');

    Plugin := TConfigPlugin.Create;
    Plugin.Config.DisplayName := 'ok';
    Plugin.Config.Port := 8080;
    Fiber := Root.Plugin(Plugin);
    H.Expect(Fiber.State = fsActive, 'valid config activates');
  finally
    Root.Dispose;
  end;
end;

procedure TestFork(H: TTestHarness);
var
  Parent: IOasisContext;
  Child: IOasisContext;
  Log: string;
  ChildSeen: Integer;
  Fiber: IOasisFiber;
begin
  Parent := TOasisContext.Create('t-parent');
  try
    Parent.Plugin(TTestService.Create('test.svc', 'root'));
    Child := Parent.Fork('child');
    H.Expect(Child.Has('test.svc'), 'fork resolves parent services');
    H.Expect(Child.Name = 'child', 'fork carries its name');
    H.Expect(Child.Root = Parent, 'fork knows its root');

    Child.Plugin('child-svc',
      procedure(C: IOasisContext)
      begin
        C.Plugin(TTestService.Create('child.only', 'scoped'));
      end);
    H.Expect(Child.Has('child.only'), 'fork sees its own service');
    H.Expect(not Parent.Has('child.only'), 'parent does not see fork services');

    Log := '';
    Parent.On('t/bubble',
      procedure(const Args: TOasisArgs)
      begin
        Log := Log + 'parent;';
      end);
    Child.On('t/bubble',
      procedure(const Args: TOasisArgs)
      begin
        Log := Log + 'child;';
      end);
    Child.Emit('t/bubble', OasisArgs(['x']));
    H.Expect(Log = 'child;parent;', 'events bubble child-first up the fork chain');

    ChildSeen := 0;
    Child.On('t/parent-only',
      procedure(const Args: TOasisArgs)
      begin
        Inc(ChildSeen);
      end);
    Parent.Emit('t/parent-only', OasisArgs(['x']));
    H.Expect(ChildSeen = 0, 'fork listeners do not observe parent-only events');

    Fiber := Child.Plugin('active-name',
      procedure(C: IOasisContext)
      begin
        TestDisposeLog := C.ActivePluginName;
      end);
    H.Expect(TestDisposeLog = 'active-name', 'ActivePluginName visible during Apply');

    Child.Dispose;
    H.Expect(Child.Disposed, 'fork reports disposed');
    H.Expect(Parent.Has('child.only') = False, 'fork services gone after disposal');
    H.Expect(Parent.Has('test.svc'), 'parent services survive fork disposal');
  finally
    Parent.Dispose;
    Parent.Dispose; // idempotent
  end;
end;

var
  Harness: TTestHarness;

begin
  Harness := TTestHarness.Create;
  try
    Writeln('============================================');
    Writeln(' Oasis framework self-tests');
    Writeln('============================================');
    Harness.Run('services: provide / get / typed lookup / optional probe', TestServices);
    Harness.Run('inject: dependency order, PENDING, activation', TestInjectOrder);
    Harness.Run('inject: unsatisfied dependencies stay PENDING', TestUnsatisfiedInjection);
    Harness.Run('service replacement: unload and reload dependents', TestServiceReplacement);
    Harness.Run('services: duplicate names fail loudly', TestDuplicateService);
    Harness.Run('events: emit, prepend, bail, serial', TestEmitAndBail);
    Harness.Run('events: waterfall wrap and veto', TestWaterfall);
    Harness.Run('effects: LIFO teardown, manual early disposal', TestEffects);
    Harness.Run('plugins: child plugins die with their parent', TestChildPlugins);
    Harness.Run('config: validation fails the fiber loudly', TestConfigValidation);
    Harness.Run('fork: inheritance, isolation, bubbling, disposal', TestFork);
    Writeln;
    Writeln('============================================');
    Writeln(' Test result: ', Harness.Summary);
    Writeln('============================================');
    if Harness.Failed > 0 then
      ExitCode := 1;
  finally
    Harness.Free;
  end;
end.
