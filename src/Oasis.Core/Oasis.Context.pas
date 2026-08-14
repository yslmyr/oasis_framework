unit Oasis.Context;

{ Oasis framework - the central context. IContext and IPlugin live together
  here because they are mutually recursive (IContext.Plugin takes IPlugin;
  IPlugin.Apply takes IContext) and Delphi forbids a cross-unit interface
  circular uses.

  Isolation model = FIBER: plugins mount on a shared context (shared services +
  events, so DI works across plugins). Each plugin gets its own IEffectScope
  ("fiber") that tracks its side effects, so the plugin can unload independently.
  During Apply, the context's active effect scope is the plugin's fiber; outside
  Apply it is the context-level scope (nested mounts save/restore the active
  fiber).

  Fork creates an isolated sub-context (own services/events/effects, parent
  chain) for genuine sub-scoping. Dispose order: children (reverse) -> fibers
  (reverse mount order) -> context effects; failures aggregate into
  EOasisDisposeError. Idempotent. A plugin Apply that raises has its partial
  effects rolled back; the rest keep mounting (fault isolation). }

interface

uses
  System.SysUtils, System.Generics.Collections,
  Oasis.Types, Oasis.Errors, Oasis.Effects, Oasis.Services, Oasis.Events;

type
  IContext = interface;   // forward: IPlugin.Apply references IContext

  IPlugin = interface
    ['{E5F6A7B8-C9D0-4E1F-2A3B-4C5D6E7F8091}']
    function PluginName: string;
    function Inject: TArray<TGUID>;
    procedure Apply(const Ctx: IContext);
  end;

  IContext = interface
    ['{D4E5F6A7-B8C9-4D0E-1F2A-3B4C5D6E7F80}']
    function  Parent: IContext;
    function  Name: string;
    function  IsActive: Boolean;

    { The active effect scope: the fiber of the plugin currently being applied,
      else this context's own scope. }
    function  Effects: IEffectScope;
    function  Services: IServiceRegistry;
    function  Events: IEventBus;

    procedure Effect(AEffect: TEffectFn);

    { Mount a class plugin on this (shared) context under a fresh fiber. }
    procedure Plugin(APlugin: IPlugin); overload;
    { Mount a closure plugin (no deps, no name metadata). }
    procedure Plugin(const AName: string; AFn: TProc<IContext>); overload;
    { Mount a closure plugin that returns a top-level disposer (Cordis style). }
    procedure Plugin(const AName: string; AFn: TFunc<IContext, TDisposer>); overload;

    { Isolated sub-context: own services/events/effects, resolves up the chain. }
    function  Fork(const AName: string = ''): IContext;

    procedure Dispose;
    { Tear down all plugin side-effects (effects + event listeners) and re-run
      every mounted plugin's Apply. Services are overwritten on re-register. }
    procedure Reload; overload;
    { Tear down ONE plugin's side-effects and re-run its Apply. Returns False if
      no mounted plugin has that name. }
    function  Reload(const AName: string): Boolean; overload;
    { Unmount ONE plugin: dispose its fiber (effects + listeners + services) and
      drop it. Returns False if no mounted plugin has that name. }
    function  Unload(const AName: string): Boolean;
  end;

  TEventBusFactory = reference to function(AOwner: IEffectScope;
                                           AParent: IEventBus): IEventBus;

  TContext = class(TInterfacedObject, IContext)
  strict private type
    TPluginEntry = record
      Name: string;
      Apply: TProc<IContext>;
      Returned: TFunc<IContext, TDisposer>;
      Fiber: IEffectScope;
    end;
  strict private
    FName: string;
    FParent: IContext;
    FContextEffects: IEffectScope;
    FServices: IServiceRegistry;
    FEvents: IEventBus;
    FPlugins: TList<TPluginEntry>;
    FChildren: TList<IContext>;
    FActiveFiber: IEffectScope;
    FDisposed: Boolean;
    procedure MountUnderFreshFiber(const AName: string; AApply: TProc<IContext>;
                                   AReturned: TFunc<IContext, TDisposer>);
    function  CreateEventBus(AParent: IEventBus): IEventBus;
  public
    constructor Create(const AName: string; AParent: IContext = nil);
    class function  EventBusFactory: TEventBusFactory; static;
    class procedure SetEventBusFactory(AFactory: TEventBusFactory); static;
    destructor Destroy; override;
    function  Parent: IContext;
    function  Name: string;
    function  IsActive: Boolean;
    function  Effects: IEffectScope;
    function  Services: IServiceRegistry;
    function  Events: IEventBus;
    procedure Effect(AEffect: TEffectFn);
    procedure Plugin(APlugin: IPlugin); overload;
    procedure Plugin(const AName: string; AFn: TProc<IContext>); overload;
    procedure Plugin(const AName: string; AFn: TFunc<IContext, TDisposer>); overload;
    function  Fork(const AName: string = ''): IContext;
    procedure Dispose;
    procedure Reload; overload;
    function  Reload(const AName: string): Boolean; overload;
    function  Unload(const AName: string): Boolean;
  end;

implementation

var
  GEventBusFactory: TEventBusFactory;

{ TContext }

constructor TContext.Create(const AName: string; AParent: IContext);
begin
  inherited Create;
  FName := AName;
  FParent := AParent;
  FContextEffects := TEffectScope.Create;
  if AParent <> nil then
    FServices := TServiceRegistry.Create(AParent.Services)
  else
    FServices := TServiceRegistry.Create(nil);
  if AParent <> nil then
    FEvents := CreateEventBus(AParent.Events)
  else
    FEvents := CreateEventBus(nil);
  FPlugins := TList<TPluginEntry>.Create;
  FChildren := TList<IContext>.Create;
end;

destructor TContext.Destroy;
begin
  Dispose;
  FPlugins.Free;
  FChildren.Free;
  inherited Destroy;
end;

function TContext.CreateEventBus(AParent: IEventBus): IEventBus;
var
  LParentBus: IEventBus;
  LFactory: TEventBusFactory;
begin
  LParentBus := AParent;
  LFactory := GEventBusFactory;
  if Assigned(LFactory) then
    Result := LFactory(FContextEffects, LParentBus)
  else
    Result := TEventBus.Create(FContextEffects, LParentBus);
end;

class function TContext.EventBusFactory: TEventBusFactory;
begin
  Result := GEventBusFactory;
end;

class procedure TContext.SetEventBusFactory(AFactory: TEventBusFactory);
begin
  GEventBusFactory := AFactory;
end;

function TContext.Parent: IContext;
begin
  Result := FParent;
end;

function TContext.Name: string;
begin
  Result := FName;
end;

function TContext.IsActive: Boolean;
begin
  Result := not FDisposed;
end;

function TContext.Effects: IEffectScope;
begin
  if FActiveFiber <> nil then
    Result := FActiveFiber
  else
    Result := FContextEffects;
end;

function TContext.Services: IServiceRegistry;
begin
  Result := FServices;
end;

function TContext.Events: IEventBus;
begin
  Result := FEvents;
end;

procedure TContext.Effect(AEffect: TEffectFn);
begin
  Effects.Add(AEffect);
end;

procedure TContext.MountUnderFreshFiber(const AName: string;
  AApply: TProc<IContext>; AReturned: TFunc<IContext, TDisposer>);
var
  LFiber: IEffectScope;
  LPrev: IEffectScope;
  LDisp: TDisposer;
  LEntry: TPluginEntry;
begin
  LFiber := TEffectScope.Create;
  LPrev := FActiveFiber;        // save (nested mounts restore it)
  FActiveFiber := LFiber;
  { While Apply runs, the event bus's owner is this fiber: listeners the plugin
    registers are auto-unsubscribed when the fiber is disposed (per-plugin
    unload/reload) instead of waiting for context teardown. }
  FEvents.SetOwnerScope(LFiber);
  { Services registered during Apply are fiber-owned too: they unregister when
    the fiber disposes (provider unload/reload), firing OnServiceRemoved. }
  FServices.SetOwnerScope(LFiber);
  try
    try
      if Assigned(AApply) then
        AApply(Self);
      if Assigned(AReturned) then
      begin
        LDisp := AReturned(Self);
        if Assigned(LDisp) then
          LFiber.AddCleanup(LDisp);
      end;
    except
      { Fault isolation: roll back this fiber's partial effects and swallow the
        exception. The Host surfaces plugin failures via events. }
      try
        LFiber.Dispose;
      except
        on EOasisDisposeError do ;
      end;
      Exit;
    end;
  finally
    FActiveFiber := LPrev;
    FServices.SetOwnerScope(Effects); // ditto for service registrations
    FEvents.SetOwnerScope(Effects);  // back to the enclosing active scope
  end;
  LEntry.Name := AName;
  LEntry.Apply := AApply;
  LEntry.Returned := AReturned;
  LEntry.Fiber := LFiber;
  FPlugins.Add(LEntry);
end;
procedure TContext.Plugin(APlugin: IPlugin);
var
  LPlugin: IPlugin;
begin
  LPlugin := APlugin;
  MountUnderFreshFiber(APlugin.PluginName,
    procedure(C: IContext)
    begin
      { Keep the plugin alive for the lifetime of its fiber: its cleanups may
        capture the plugin object via Self. Registered first so it is released
        last (after the plugin's own cleanups run). }
      C.Effects.AddDisposable(LPlugin);
      LPlugin.Apply(C);
    end, nil);
end;

procedure TContext.Plugin(const AName: string; AFn: TProc<IContext>);
var
  LFn: TProc<IContext>;
begin
  LFn := AFn;
  MountUnderFreshFiber(AName, procedure(C: IContext) begin LFn(C); end, nil);
end;

procedure TContext.Plugin(const AName: string; AFn: TFunc<IContext, TDisposer>);
var
  LFn: TFunc<IContext, TDisposer>;
begin
  LFn := AFn;
  MountUnderFreshFiber(AName, nil, LFn);
end;

function TContext.Fork(const AName: string): IContext;
var
  LForkName: string;
begin
  if AName = '' then
    LForkName := FName + '.fork'
  else
    LForkName := AName;
  Result := TContext.Create(LForkName, Self);
  FChildren.Add(Result);
end;

procedure TContext.Dispose;
var
  I: Integer;
  LMsgs: TArray<string>;
  LFailed: Boolean;
begin
  if FDisposed then
    Exit;
  FDisposed := True;
  LFailed := False;

  for I := FChildren.Count - 1 downto 0 do
  try
    FChildren[I].Dispose;
  except
    on E: Exception do
    begin
      LFailed := True;
      SetLength(LMsgs, Length(LMsgs) + 1);
      LMsgs[High(LMsgs)] := E.Message;
    end;
  end;
  FChildren.Clear;
  for I := FPlugins.Count - 1 downto 0 do
  try
    FPlugins[I].Fiber.Dispose;
  except
    on E: Exception do
    begin
      LFailed := True;
      SetLength(LMsgs, Length(LMsgs) + 1);
      LMsgs[High(LMsgs)] := E.Message;
    end;
  end;
  FPlugins.Clear;

  try
    FContextEffects.Dispose;
  except
    on E: Exception do
    begin
      LFailed := True;
      SetLength(LMsgs, Length(LMsgs) + 1);
      LMsgs[High(LMsgs)] := E.Message;
    end;
  end;

  if LFailed then
    raise EOasisDisposeError.Create(LMsgs);
end;

procedure TContext.Reload;
var
  LSnap: TList<TPluginEntry>;
  I: Integer;
  LEntry: TPluginEntry;
  LFailed: Boolean;
  LMsgs: TArray<string>;
begin
  if FDisposed then
    Exit;
  LSnap := TList<TPluginEntry>.Create;
  try
    for I := 0 to FPlugins.Count - 1 do
      LSnap.Add(FPlugins[I]);
    LFailed := False;
    { 1. tear down plugin fibers (reverse) - reverses their registered effects }
    for I := LSnap.Count - 1 downto 0 do
    try
      LSnap[I].Fiber.Dispose;
    except
      on E: Exception do
      begin
        LFailed := True;
        SetLength(LMsgs, Length(LMsgs) + 1);
        LMsgs[High(LMsgs)] := E.Message;
      end;
    end;
    FPlugins.Clear;
    { 2. tear down context-level effects (this also removes ALL event listeners,
      since On() registered their auto-unsubscribe here) }
    try
      FContextEffects.Dispose;
    except
      on E: Exception do
      begin
        LFailed := True;
        SetLength(LMsgs, Length(LMsgs) + 1);
        LMsgs[High(LMsgs)] := E.Message;
      end;
    end;
    { 3. fresh context scope; rewire the bus so new listeners attach here }
    FContextEffects := TEffectScope.Create;
    FEvents.SetOwnerScope(FContextEffects);
    { 4. re-run every plugin's Apply (re-registers effects/listeners/services) }
    for I := 0 to LSnap.Count - 1 do
    begin
      LEntry := LSnap[I];
      MountUnderFreshFiber(LEntry.Name, LEntry.Apply, LEntry.Returned);
    end;
    if LFailed then
      raise EOasisDisposeError.Create(LMsgs);
  finally
    LSnap.Free;
  end;
end;

function TContext.Reload(const AName: string): Boolean;
var
  I: Integer;
  LEntry: TPluginEntry;
begin
  Result := False;
  if FDisposed then
    Exit;
  for I := 0 to FPlugins.Count - 1 do
    if SameText(FPlugins[I].Name, AName) then
    begin
      LEntry := FPlugins[I];
      FPlugins.Delete(I);
      { Dispose removes this plugin's effects AND its event listeners (they are
        fiber-owned since Apply ran with the bus owner set to the fiber). A
        cleanup raising does not stop the remount (fault isolation). }
      try
        LEntry.Fiber.Dispose;
      except
        on EOasisDisposeError do ;
      end;
      MountUnderFreshFiber(LEntry.Name, LEntry.Apply, LEntry.Returned);
      Exit(True);
    end;
end;

function TContext.Unload(const AName: string): Boolean;
var
  I: Integer;
  LEntry: TPluginEntry;
begin
  Result := False;
  if FDisposed then
    Exit;
  for I := 0 to FPlugins.Count - 1 do
    if SameText(FPlugins[I].Name, AName) then
    begin
      LEntry := FPlugins[I];
      FPlugins.Delete(I);
      { Fiber disposal rolls back the plugin's effects + listeners and now also
        unregisters its fiber-owned services (firing OnServiceRemoved, which the
        Host uses to deactivate dependents). The entry is dropped, NOT remounted. }
      try
        LEntry.Fiber.Dispose;
      except
        on EOasisDisposeError do ;
      end;
      Exit(True);
    end;
end;

end.
