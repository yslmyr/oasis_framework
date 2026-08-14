unit Oasis.UI.Tests;

interface

uses
  DUnitX.TestFramework, System.SysUtils, System.Classes,
  Oasis.Context, Oasis.Plugin, Oasis.UI;

type
  [TestFixture]
  TUITests = class
  public
    [Test]
    procedure Queue_Marshals_To_Main_Thread;

    [Test]
    procedure Sync_Marshals_To_Main_Thread;
  end;

implementation

{ Console-host contract: the "main" thread (this one) must pump CheckSynchronize
  so queued/synchronized closures can run here. }

procedure TUITests.Queue_Marshals_To_Main_Thread;
var
  Ctx: IContext;
  LInvoker: IUIInvoker;
  LDone: Boolean;
  LSeen: TThreadID;
  LThread: TThread;
  I: Integer;
begin
  Ctx := TContext.Create('root');
  Ctx.Plugin(TUIInvokerPlugin.Create);
  LInvoker := Ctx.Services.Get(IUIInvoker) as IUIInvoker;
  LDone := False;
  LSeen := 0;

  LThread := TThread.CreateAnonymousThread(
    procedure
    begin
      LInvoker.Queue(
        procedure
        begin
          LSeen := TThread.CurrentThread.ThreadID;
          LDone := True;
        end);
    end);
  LThread.FreeOnTerminate := False;
  LThread.Start;
  for I := 1 to 2000 do
  begin
    if LDone then
      Break;
    CheckSynchronize;
    Sleep(5);
  end;
  LThread.WaitFor;
  LThread.Free;

  Assert.IsTrue(LDone, 'queued closure never ran (pump timeout)');
  Assert.AreEqual(LInvoker.MainThreadID, LSeen, 'closure ran on the wrong thread');
  Ctx.Dispose;
end;

procedure TUITests.Sync_Marshals_To_Main_Thread;
var
  Ctx: IContext;
  LInvoker: IUIInvoker;
  LDone: Boolean;
  LSeen: TThreadID;
  LThread: TThread;
  I: Integer;
begin
  Ctx := TContext.Create('root');
  Ctx.Plugin(TUIInvokerPlugin.Create);
  LInvoker := Ctx.Services.Get(IUIInvoker) as IUIInvoker;
  LDone := False;
  LSeen := 0;

  LThread := TThread.CreateAnonymousThread(
    procedure
    begin
      LInvoker.Sync(
        procedure
        begin
          LSeen := TThread.CurrentThread.ThreadID;
          LDone := True;
        end);
    end);
  LThread.FreeOnTerminate := False;
  LThread.Start;
  { Pump while the worker is inside Sync - otherwise it would deadlock:
    Sync waits for the main thread to process the closure. }
  for I := 1 to 2000 do
  begin
    if LDone then
      Break;
    CheckSynchronize;
    Sleep(5);
  end;
  LThread.WaitFor;
  LThread.Free;

  Assert.IsTrue(LDone, 'Sync returned before the closure ran');
  Assert.AreEqual(LInvoker.MainThreadID, LSeen, 'closure ran on the wrong thread');
  Ctx.Dispose;
end;

initialization
  TDUnitX.RegisterTestFixture(TUITests);

end.
