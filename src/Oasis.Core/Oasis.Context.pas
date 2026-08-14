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
  end;

  TEventBusFactory = reference to function(AOwner: IEffectScope;
                                           AParent: IEventBus): IEventBus;

  TContext = class(TInterfacedObject, IContext)
  strict private
    FName: string;
    FParent: IContext;
    FContextEffects: IEffectScope;
    FServices: IServiceRegistry;
    FEvents: IEventBus;
    FFibers: TList<IEffectScope>;
    FChildren: TList<IContext>;
    FActiveFiber: IEffectScope;
    FDisposed: Boolean;
    procedure MountUnderFreshFiber(AApply: TProc<IContext>;
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
  FFibers := TList<IEffectScope>.Create;
  FChildren := TList<IContext>.Create;
end;

destructor TContext.Destroy;
begin
  Dispose;
  FFibers.Free;
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

procedure TContext.MountUnderFreshFiber(AApply: TProc<IContext>;
  AReturned: TFunc<IContext, TDisposer>);
var
  LFiber: IEffectScope;
  LPrev: IEffectScope;
  LDisp: TDisposer;
begin
  LFiber := TEffectScope.Create;
  LPrev := FActiveFiber;        // save (nested mounts restore it)
  FActiveFiber := LFiber;
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
  end;
  FFibers.Add(LFiber);
end;

procedure TContext.Plugin(APlugin: IPlugin);
var
  LPlugin: IPlugin;
begin
  LPlugin := APlugin;
  MountUnderFreshFiber(
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
  MountUnderFreshFiber(procedure(C: IContext) begin LFn(C); end, nil);
end;

procedure TContext.Plugin(const AName: string; AFn: TFunc<IContext, TDisposer>);
var
  LFn: TFunc<IContext, TDisposer>;
begin
  LFn := AFn;
  MountUnderFreshFiber(nil, LFn);
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

  for I := FFibers.Count - 1 downto 0 do
  try
    FFibers[I].Dispose;
  except
    on E: Exception do
    begin
      LFailed := True;
      SetLength(LMsgs, Length(LMsgs) + 1);
      LMsgs[High(LMsgs)] := E.Message;
    end;
  end;
  FFibers.Clear;

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

end.
