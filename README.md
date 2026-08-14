# Oasis

A Delphi plugin framework inspired by [Cordis](https://github.com/cordiverse/cordis).

Oasis brings Cordis's core design ideas to Delphi:

- **Context** — a shared service/event host; plugins mount on it and share a
  GUID-keyed service registry, so dependency injection works across plugins.
- **Reversible effects** — every registration (`Effect`, `On`) has a paired
  disposer that runs automatically (LIFO) on teardown; a cleanup that raises
  does not abort the rest (failures aggregate into `EOasisDisposeError`).
- **Fibers** — each plugin runs under its own `IEffectScope` ("fiber") so it can
  unload independently; side effects registered during `Apply` attach to the
  active fiber.
- **Services** — strongly-typed, GUID-keyed registry with parent-chain lookup
  and child-shadowing (`Ctx.Services.Register(IConfig, inst)` /
  `Ctx.Services.Get(IConfig) as IConfig`).
- **Events** — `Emit` / `Serial` / `Waterfall` (sync) with per-listener fault
  isolation and bubbling; `Waterfall` short-circuits when a listener skips
  `Next`. **Async** `Parallel` / `SerialAsync` (concurrent / sequential on the
  OmniThreadLibrary pool) via the optional `Oasis.Otl` package.
- **Dependency activation** — a plugin declares the service GUIDs it needs
  (`Inject`); it activates as soon as they are resolvable. Mount order does not
  matter — the host rescans the pending queue on every service registration.
- **Loaders** — pluggable `IPluginLoader` abstraction: in-process (`TInProcPluginLoader`)
  and dynamic BPL (`TBplPluginLoader`, phase 3) with the same contract.
- **Reload** — `IContext.Reload` (phase 4): tears down every plugin's effects +
  listeners and re-runs all `Apply` calls (hot-restart the context);
  `Reload(name)` / `Unload(name)` do it for a single plugin.
- **Dependency cascade** — services registered during Apply are fiber-owned:
  unloading a provider unregisters its services, the Host deactivates the
  affected consumers (re-queued), and they re-activate when the dependency
  returns.
- **Config** — `TJsonConfigPlugin` registers an `IOasisConfig` service
  (`disabled` flag + per-plugin values); `Host.TryMount` skips disabled plugins
  (cordis.yml semantics, JSON edition). Optional **env layers** merge overrides
  on top of the base config (`Create(path, 'production')`); typed readers
  `Int`/`Bool`/`Float` fall back to defaults on missing/unparseable values.
- **UI marshaling** — `Oasis.UI` (optional package): `TUIInvokerPlugin`
  registers an `IUIInvoker` service with `Queue`/`Sync` closures marshaled to
  the mounting (main) thread. RTL-only implementation (`TThread.Queue/
  Synchronize`), so the same package serves VCL and FMX hosts; console hosts
  must pump `CheckSynchronize`.

## Status

| Phase | Scope | Status |
|---|---|---|
| MVP | `Oasis.Core` + `Oasis.Hosting` (in-process loader + `THost`) | **Done** — 25/25 tests, demo runs |
| Phase 2 | `Oasis.Otl` — async `Parallel`/`SerialAsync` via OTL | **Done** — 6/6 tests, async demo runs |
| Phase 3 | `Oasis.Bpl` — dynamic BPL loading | **Done** — sample BPL loads, demo runs |
| Phase 4 | `Context.Reload` hot-reload | **Done** — tests |
| Roadmap 1 | per-plugin `Reload(name)` / `Unload(name)`, fiber-owned listeners | **Done** — tests |
| Roadmap 2 | dependency deactivation cascade (`Unregister`/`OnServiceRemoved`) | **Done** — tests |
| Roadmap 4 | JSON config plugin + `Host.TryMount` (`disabled` support) | **Done** — tests |
| Hardening | Apply-failure visibility (`FailedPlugins` + `EV_HOST_PLUGIN_FAILED`); runtime packages (`Oasis.Core/.Hosting/.Otl/.Bpl/.UI.dpk`) + one-click `build.cmd` | **Done** |
| Roadmap 3 | `Oasis.UI` — `IUIInvoker` (`Queue`/`Sync`) main-thread marshaling bridge (RTL-only, VCL/FMX-agnostic) | **Done** — tests |
| Roadmap 4b | Config env layers (base + override) + typed readers (`Int`/`Bool`/`Float`) | **Done** — tests |
| Future | — | — |

## Requirements

- Delphi 10.4 Sydney or newer (built/tested on **Delphi 13 Florence**).
- DUnitX (ships with RAD Studio) for tests.

## Layout

```
src/
  Oasis.Core/      zero-dependency core: Types, Errors, Effects, Services,
                   Events, Context (IContext+IPlugin+TContext), Plugin base
                   + Oasis.Core.dpk (runtime package)
  Oasis.Hosting/   IPluginLoader + TInProcPluginLoader, THost, Oasis.Config
                   (JSON config plugin + TryMount) + Oasis.Hosting.dpk
  Oasis.Otl/       (phase 2) IAsyncEventBus + TAsyncEventBus — Parallel/SerialAsync
                   via OmniThreadLibrary; inherits TEventBus + Oasis.Otl.dpk
  Oasis.Bpl/       (phase 3) TBplPluginLoader + IOasisPluginFactory contract
                   + Oasis.Bpl.dpk
  Oasis.UI/        (roadmap 3) IUIInvoker + TUIInvokerPlugin — main-thread
                   marshaling (Queue/Sync), RTL-only + Oasis.UI.dpk
build.cmd          one-click build & test script (packages -> bin\)
samples/BplPlugin/ (phase 3) a sample BPL plugin (.dpk/.pas) + shared contract
tests/             DUnitX unit tests (Oasis.Tests.dpr — Core/Hosting, OTL-free)
tests/otl/         OTL test runner (Oasis.Otl.Tests.dpr — needs OmniThreadLibrary)
demos/ConsoleDemo/ 3-plugin dependency chain + lifecycle event (OTL-free)
demos/OtlDemo/     async Parallel demo (needs OmniThreadLibrary)
demos/BplDemo/     dynamic BPL-loading demo (needs rtl.bpl on PATH; writes bpldemo_out.txt)
demos/CascadeDemo/ dependency cascade + per-plugin Reload/Unload (4 phases)
demos/ConfigDemo/  config-driven assembly: disabled skip, env layers, typed values
                   (run with no args = base layer; `ConfigDemo production` = env layer)
demos/WaterfallDemo/ middleware pipeline: logging/auth-veto/rate-limit/handler
demos/UiMarshalDemo/ background workers -> main-thread rendering via IUIInvoker
docs/superpowers/  design spec + implementation plan
```

## Build & run

**One click** (builds runtime packages + runs both test suites + builds all demos):

```bash
build.cmd        # expect: ALL GREEN (32/32 + 6/6 tests, packages in bin\)
```

The Delphi 13 toolchain is used directly (`dcc32`). From the respective folder:

```bash
# tests (DUnitX console runner) — from tests/
dcc32 -B -U"<BDS>\source\DunitX" Oasis.Tests.dpr
Oasis.Tests.exe            # expect: Tests Passed: 25, Failed: 0, Errored: 0

# demo — from demos/ConsoleDemo/
dcc32 -B ConsoleDemo.dpr
ConsoleDemo.exe            # expect: "OasisDemo is running." / Pending: 0 / Failed: 0
```

**Phase 2 (async, needs OmniThreadLibrary)** — add OTL to the search path and the
`Winapi` namespace:

```bash
# OTL tests — from tests/otl/  (OTL at D:\code\awesome-pascal\OmniThreadLibrary)
dcc32 -B -NSWinapi;System;System.Win;Vcl \
  -U"<DUnitX>" -U"<OTL>" -U"<OTL>\src" Oasis.Otl.Tests.dpr
Oasis.Otl.Tests.exe        # expect: Tests Passed: 6

# async demo — from demos/OtlDemo/
dcc32 -B -NSWinapi;System;System.Win;Vcl -U"<OTL>" -U"<OTL>\src" OasisOtlDemo.dpr
OasisOtlDemo.exe           # expect: 5 listeners across 5 distinct worker threads
```

**Phase 3 (BPL plugin, dynamic loading)** — build the sample BPL, then the host
(the host must use the RTL runtime package so it shares `rtl.bpl`'s class list
with the BPL; `rtl.bpl` and the Oasis `.bpl`s must be on PATH at run time):

```bash
# runtime packages first (produces .bpl/.dcp next to each .dpk or in bin/)
dcc32 -B -NSWinapi;System;System.Win;Vcl;System.Classes \
  -U"<repo>/src/Oasis.Core" -E"<repo>/bin" src/Oasis.Core/Oasis.Core.dpk
# ... likewise Oasis.Hosting.dpk and Oasis.Bpl.dpk (or just run build.cmd)

# sample BPL — from samples/BplPlugin/ (requires Oasis.Core + Oasis.Bpl)
dcc32 -B -NSWinapi;System;System.Win;Vcl;System.Classes \
  -U"<repo>/src/Oasis.Core" -U"<repo>/src/Oasis.Bpl" \
  -U"<repo>/src/Oasis.Hosting" -U. SamplePlugin.dpk
# -> SamplePlugin.bpl

# host — from demos/BplDemo/  (note -LUrtl)
dcc32 -B -NSWinapi;System;System.Win;Vcl;System.Classes -LUrtl BplDemo.dpr
BplDemo.exe                # writes bpldemo_out.txt: "Hello from BPL, world" / 0/0
```

## A plugin in 30 seconds

```pascal
type
  IGreeter = interface
    ['{...}']
    function Greet(const AWho: string): string;
  end;

  TGreeterPlugin = class(TOasisPlugin)
  public
    constructor Create;
    procedure Apply(const Ctx: IContext); override;
  end;

constructor TGreeterPlugin.Create;
begin
  inherited Create('greeter');
end;

procedure TGreeterPlugin.Apply(const Ctx: IContext);
begin
  Ctx.Services.Register(IGreeter, TGreeterImpl.Create);
end;

// host
Host := THost.Create;
try
  Host.Mount(TConsumerPlugin.Create);   // injects IGreeter - stays pending until ready
  Host.Mount(TGreeterPlugin.Create);    // provides IGreeter -> consumer activates
  Host.Start;
  Host.Shutdown;
finally
  Host.Free;
end;
```

## Lifetime note

Interface reference cycles exist between an event bus and its owning effect
scope (and between a context and its fibers). They are broken by calling
`Dispose` — `THost.Shutdown` / `TContext.Dispose` / `IEffectScope.Dispose` all
do this. Always dispose contexts/hosts; do not rely solely on interface
refcounting to reclaim them.

## Documentation

- [Design spec](docs/superpowers/specs/2026-08-14-oasis-plugin-framework-design.md)
- [MVP implementation plan](docs/superpowers/plans/2026-08-14-oasis-mvp.md)
