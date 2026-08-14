unit Oasis.UI;

(* Oasis framework - UI thread marshaling bridge.

  Background threads (OTL Parallel listeners, TTask workers, raw threads) must
  not touch UI state. IUIInvoker marshals a closure to the MAIN thread:

    - Queue(AProc): asynchronous - returns immediately; AProc runs on the main
      thread the next time it pumps (Application.Idle in VCL/FMX, or an explicit
      CheckSynchronize in console/services).
    - Sync(AProc): blocking - waits until AProc has run on the main thread.

  Implementation is plain RTL (System.Classes.TThread.Queue/Synchronize with a
  nil thread), so the same unit serves VCL and FMX apps without depending on
  either UI framework. Requirements at run time: the main thread must pump
  CheckSynchronize (VCL/FMX Application.Run does; console hosts must call it
  periodically), and Queue/Synchronize must not be called FROM the main thread
  in a way that deadlocks (Queue from the main thread executes inline).

  TUIInvokerPlugin registers the IUIInvoker service; consumers Inject it like
  any service. Queued closures are interface-refcounted, so entries still
  pending at teardown are memory-safe. *)

interface

uses
  System.SysUtils, System.Classes,
  Oasis.Context, Oasis.Plugin;

type
  IUIInvoker = interface
    ['{99999999-0000-0000-0000-000000000009}']
    { Run AProc on the main thread asynchronously (returns immediately). }
    procedure Queue(AProc: TProc);
    { Run AProc on the main thread and block until it completes. }
    procedure Sync(AProc: TProc);
    { Thread id AProc closures are marshaled to (the id captured at creation). }
    function  MainThreadID: TThreadID;
  end;

  TUIInvokerPlugin = class(TOasisPlugin)
  public
    constructor Create;
    procedure Apply(const Ctx: IContext); override;
  end;

implementation

type
  TUIInvokerImpl = class(TInterfacedObject, IUIInvoker)
  strict private
    FMainThreadID: TThreadID;
  public
    constructor Create;
    procedure Queue(AProc: TProc);
    procedure Sync(AProc: TProc);
    function  MainThreadID: TThreadID;
  end;

{ TUIInvokerImpl }

constructor TUIInvokerImpl.Create;
begin
  inherited Create;
  FMainThreadID := TThread.CurrentThread.ThreadID;   { the thread that mounts }
end;

procedure TUIInvokerImpl.Queue(AProc: TProc);
begin
  TThread.Queue(nil,
    procedure
    begin
      AProc;
    end);
end;

procedure TUIInvokerImpl.Sync(AProc: TProc);
begin
  TThread.Synchronize(nil,
    procedure
    begin
      AProc;
    end);
end;

function TUIInvokerImpl.MainThreadID: TThreadID;
begin
  Result := FMainThreadID;
end;

{ TUIInvokerPlugin }

constructor TUIInvokerPlugin.Create;
begin
  inherited Create('ui-invoker');
end;

procedure TUIInvokerPlugin.Apply(const Ctx: IContext);
begin
  Ctx.Services.Register(IUIInvoker, TUIInvokerImpl.Create);
end;

end.
