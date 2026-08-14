unit Oasis.Host;

{ Oasis framework - the host. Owns the root context, a set of loaders, and the
  dependency-activation machinery (pending queue + rescan-on-register). Mount:
  'kind:name' routing; bare name uses the first loader. Fires lifecycle events.
  Dependency ordering is resolved at runtime: a plugin activates as soon as its
  declared service GUIDs are resolvable; every service registration triggers a
  rescan. }

interface

uses
  System.SysUtils, System.SyncObjs, System.Generics.Collections,
  Oasis.Types, Oasis.Errors, Oasis.Context, Oasis.Plugin, Oasis.Loader;

const
  EV_HOST_STARTING      : TEventKey = 'host/starting';
  EV_HOST_STARTED       : TEventKey = 'host/started';
  EV_HOST_STOPPING      : TEventKey = 'host/stopping';
  EV_HOST_PLUGIN_FAILED : TEventKey = 'host/plugin_failed';

type
  THost = class
  strict private
    FRoot: IContext;
    FLoaders: TList<IPluginLoader>;
    FPending: TList<IPlugin>;
    FPendingLock: TCriticalSection;
    FFailed: TList<string>;
    FActive: TList<IPlugin>;
    FStarted: Boolean;
    function  DepsSatisfied(APlugin: IPlugin): Boolean;
    procedure DoActivate(APlugin: IPlugin);
    procedure RescanPending;
    procedure OnServiceAdded(const AGUID: TGUID);
    procedure OnServiceRemoved(const AGUID: TGUID);
    function  ResolvePlugin(const ASource: string): IPlugin;
  public
    constructor Create;
    destructor Destroy; override;
    function  Root: IContext;
    procedure Use(ALoader: IPluginLoader);
    procedure Mount(APlugin: IPlugin); overload;
    procedure Mount(const ASource: string); overload;
    procedure Start;
    procedure Shutdown;
    function  PendingPlugins: TArray<string>;
    function  FailedPlugins: TArray<string>;
  end;

implementation

{ THost }

constructor THost.Create;
begin
  inherited Create;
  FRoot := TContext.Create('host');
  FLoaders := TList<IPluginLoader>.Create;
  FPending := TList<IPlugin>.Create;
  FPendingLock := TCriticalSection.Create;
  FFailed := TList<string>.Create;
  FActive := TList<IPlugin>.Create;
  FRoot.Services.SetOnServiceAdded(OnServiceAdded);
  FRoot.Services.SetOnServiceRemoved(OnServiceRemoved);
end;

destructor THost.Destroy;
begin
  Shutdown;
  FActive.Free;
  FFailed.Free;
  FPending.Free;
  FPendingLock.Free;
  FLoaders.Free;
  inherited Destroy;
end;

function THost.Root: IContext;
begin
  Result := FRoot;
end;

procedure THost.Use(ALoader: IPluginLoader);
begin
  FLoaders.Add(ALoader);
end;

function THost.ResolvePlugin(const ASource: string): IPlugin;
var
  LKind, LName: string;
  LPos: Integer;
  LLoader: IPluginLoader;
  LFactory: TPluginFactory;
begin
  LPos := Pos(':', ASource);
  if LPos > 0 then
  begin
    LKind := Copy(ASource, 1, LPos - 1);
    LName := Copy(ASource, LPos + 1, MaxInt);
  end
  else
  begin
    LKind := '';
    LName := ASource;
  end;

  LLoader := nil;
  for LLoader in FLoaders do
    if (LKind = '') or SameText(LLoader.Kind, LKind) then
      Break;
  if LLoader = nil then
    raise EOasisLoaderError.CreateFmt('No loader for kind "%s"', [LKind]);
  LFactory := LLoader.Load(LName);
  Result := LFactory();
end;

function THost.DepsSatisfied(APlugin: IPlugin): Boolean;
var
  LGUID: TGUID;
  LDummy: IInterface;
begin
  for LGUID in APlugin.Inject do
    if not FRoot.Services.Resolve(LGUID, LDummy) then
      Exit(False);
  Result := True;
end;

procedure THost.DoActivate(APlugin: IPlugin);
begin
  FRoot.Plugin(APlugin);
  FActive.Add(APlugin);
end;

procedure THost.RescanPending;
var
  LSnap: TList<IPlugin>;
  I: Integer;
  LPlugin: IPlugin;
begin
  { Snapshot under lock, then process OUTSIDE the lock: DoActivate may register
    services, which re-enters RescanPending via OnServiceAdded. TCriticalSection
    is not recursive, so we must not hold it across DoActivate. }
  LSnap := TList<IPlugin>.Create;
  try
    FPendingLock.Enter;
    try
      for I := 0 to FPending.Count - 1 do
        LSnap.Add(FPending[I]);
      FPending.Clear;
    finally
      FPendingLock.Leave;
    end;

    for I := 0 to LSnap.Count - 1 do
    begin
      LPlugin := LSnap[I];
      if DepsSatisfied(LPlugin) then
      begin
        try
          DoActivate(LPlugin);
        except
          on E: Exception do
          begin
            FFailed.Add(LPlugin.PluginName);
            try FRoot.Events.Emit(EV_HOST_PLUGIN_FAILED, []); except end;
          end;
        end;
      end
      else
      begin
        FPendingLock.Enter;
        try
          FPending.Add(LPlugin);
        finally
          FPendingLock.Leave;
        end;
      end;
    end;
  finally
    LSnap.Free;
  end;
end;

procedure THost.OnServiceAdded(const AGUID: TGUID);
begin
  RescanPending;
end;

procedure THost.OnServiceRemoved(const AGUID: TGUID);
var
  LSnap: TList<IPlugin>;
  I: Integer;
  LPlugin: IPlugin;
  LGUID: TGUID;
begin
  if not FStarted then
    Exit;   { teardown in progress - do not cascade }
  { Snapshot then act outside any list mutation: Unload disposes the dependent's
    fiber, which unregisters ITS services, re-entering this handler (deeper
    cascade levels). Single-threaded by contract. }
  LSnap := TList<IPlugin>.Create;
  try
    for I := 0 to FActive.Count - 1 do
      LSnap.Add(FActive[I]);
    for I := 0 to LSnap.Count - 1 do
    begin
      LPlugin := LSnap[I];
      for LGUID in LPlugin.Inject do
        if IsEqualGUID(LGUID, AGUID) then
        begin
          { Provider vanished: deactivate the dependent (fiber unload -> its own
            services unregister -> deeper cascade) and requeue it; it re-activates
            when the dependency is registered again. }
          if FRoot.Unload(LPlugin.PluginName) then
          begin
            FActive.Remove(LPlugin);
            FPendingLock.Enter;
            try
              FPending.Add(LPlugin);
            finally
              FPendingLock.Leave;
            end;
          end;
          Break;   { next dependent }
        end;
    end;
  finally
    LSnap.Free;
  end;
end;

procedure THost.Mount(APlugin: IPlugin);
begin
  if DepsSatisfied(APlugin) then
  begin
    try
      DoActivate(APlugin);
    except
      on E: Exception do
      begin
        FFailed.Add(APlugin.PluginName);
        try FRoot.Events.Emit(EV_HOST_PLUGIN_FAILED, []); except end;
      end;
    end;
  end
  else
  begin
    FPendingLock.Enter;
    try
      FPending.Add(APlugin);
    finally
      FPendingLock.Leave;
    end;
  end;
end;

procedure THost.Mount(const ASource: string);
begin
  Mount(ResolvePlugin(ASource));
end;

procedure THost.Start;
begin
  if FStarted then
    Exit;
  FRoot.Events.Emit(EV_HOST_STARTING, []);
  RescanPending;
  FStarted := True;
  FRoot.Events.Emit(EV_HOST_STARTED, []);
end;

procedure THost.Shutdown;
begin
  if FStarted then
    FRoot.Events.Emit(EV_HOST_STOPPING, []);
  FStarted := False;
  { EV_HOST_STOPPED is not emitted: the root context (and its bus) is torn down
    by Dispose. Subscribers use STOPPING. }
  if (FRoot <> nil) and FRoot.IsActive then
  try
    FRoot.Dispose;
  except
    on EOasisDisposeError do ;
  end;
end;

function THost.PendingPlugins: TArray<string>;
var
  I: Integer;
begin
  FPendingLock.Enter;
  try
    SetLength(Result, FPending.Count);
    for I := 0 to FPending.Count - 1 do
      Result[I] := FPending[I].PluginName;
  finally
    FPendingLock.Leave;
  end;
end;

function THost.FailedPlugins: TArray<string>;
begin
  Result := FFailed.ToArray;
end;

end.
