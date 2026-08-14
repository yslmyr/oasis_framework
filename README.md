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
  `Next`. (Async `Parallel` via OmniThreadLibrary is phase 2.)
- **Dependency activation** — a plugin declares the service GUIDs it needs
  (`Inject`); it activates as soon as they are resolvable. Mount order does not
  matter — the host rescans the pending queue on every service registration.
- **Loaders** — pluggable `IPluginLoader` abstraction (in-process first; BPL in
  phase 3).

## Status

| Phase | Scope | Status |
|---|---|---|
| MVP | `Oasis.Core` + `Oasis.Hosting` (in-process loader + `THost`) | **Done** — 25/25 tests, demo runs |
| Phase 2 | `Oasis.Otl` — async `Parallel`/`Serial` via OTL | Planned |
| Phase 3 | `Oasis.Bpl` — dynamic BPL loading | Planned |
| Future | `Context.Reload` hot-reload | Evaluated |

## Requirements

- Delphi 10.4 Sydney or newer (built/tested on **Delphi 13 Florence**).
- DUnitX (ships with RAD Studio) for tests.

## Layout

```
src/
  Oasis.Core/      zero-dependency core: Types, Errors, Effects, Services,
                   Events, Context (IContext+IPlugin+TContext), Plugin base
  Oasis.Hosting/   IPluginLoader + TInProcPluginLoader, THost
tests/             DUnitX unit tests (Oasis.Tests.dpr)
demos/ConsoleDemo/ 3-plugin dependency chain + lifecycle event
docs/superpowers/  design spec + implementation plan
```

## Build & run

The Delphi 13 toolchain is used directly (`dcc32`). From the respective folder:

```bash
# tests (DUnitX console runner) — from tests/
dcc32 -B -U"<BDS>\source\DunitX" Oasis.Tests.dpr
Oasis.Tests.exe            # expect: Tests Passed: 25, Failed: 0, Errored: 0

# demo — from demos/ConsoleDemo/
dcc32 -B ConsoleDemo.dpr
ConsoleDemo.exe            # expect: "OasisDemo is running." / Pending: 0 / Failed: 0
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
