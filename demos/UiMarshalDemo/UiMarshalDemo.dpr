program UiMarshalDemo;

{$APPTYPE CONSOLE}

(* Oasis demo - UI-thread marshaling (Oasis.UI / IUIInvoker).

  The pattern every VCL/FMX app needs: background workers compute, but only
  the UI thread may touch UI state. Three worker threads simulate downloads;
  each "renders" its progress on the MAIN thread through Invoker.Queue(...)
  - exactly what a background task would do with a TLabel.

  This console host plays the role of the UI thread: it pumps CheckSynchronize
  (in a VCL/FMX app, Application.Run does that for you). Every rendered line
  shows which thread executed it: all "render" lines carry the main thread id.

  Note the closure factory (MakeRender): anonymous methods capture VARIABLES
  by reference, so a per-iteration snapshot must be taken via function
  parameters - otherwise all closures would see the final loop value. *)

uses
  System.SysUtils, System.Classes, System.SyncObjs, System.Generics.Collections,
  Oasis.Types in '..\..\src\Oasis.Core\Oasis.Types.pas',
  Oasis.Errors in '..\..\src\Oasis.Core\Oasis.Errors.pas',
  Oasis.Effects in '..\..\src\Oasis.Core\Oasis.Effects.pas',
  Oasis.Services in '..\..\src\Oasis.Core\Oasis.Services.pas',
  Oasis.Events in '..\..\src\Oasis.Core\Oasis.Events.pas',
  Oasis.Context in '..\..\src\Oasis.Core\Oasis.Context.pas',
  Oasis.Plugin in '..\..\src\Oasis.Core\Oasis.Plugin.pas',
  Oasis.UI in '..\..\src\Oasis.UI\Oasis.UI.pas';

type
  TDownloadPlugin = class(TOasisPlugin)
  strict private
    FName: string;
  public
    constructor Create(const AName: string);
    procedure Apply(const Ctx: IContext); override;
  end;

var
  GMain: TThreadID;
  GDone: Integer;
  GLock: TCriticalSection;

{ Per-iteration closure factory: parameters are captured by value per call. }
function MakeRender(const AName: string; APercent: Integer): TProc;
begin
  Result :=
    procedure
    begin
      Writeln(Format('  [render ] %s: %d%%  (thread %d, main=%d)',
        [AName, APercent, TThread.CurrentThread.ThreadID, GMain]));
      if APercent >= 99 then
      begin
        GLock.Enter;
        try Inc(GDone); finally GLock.Leave; end;
      end;
    end;
end;

constructor TDownloadPlugin.Create(const AName: string);
begin
  inherited Create('download-' + AName);
  FName := AName;
end;

procedure TDownloadPlugin.Apply(const Ctx: IContext);
var
  LInvoker: IUIInvoker;
  LName: string;
  LThread: TThread;
begin
  LInvoker := Ctx.Services.Get(IUIInvoker) as IUIInvoker;
  LName := FName;

  { this plugin's "work" runs on its own background thread: three progress
    updates, each marshaled to the UI thread for rendering }
  LThread := TThread.CreateAnonymousThread(
    procedure
    var
      I: Integer;
    begin
      for I := 1 to 3 do
      begin
        Sleep(30);   { pretend to download }
        LInvoker.Queue(MakeRender(LName, I * 33));
      end;
    end);
  LThread.Start;
end;

var
  Ctx: IContext;
  I: Integer;
begin
  ReportMemoryLeaksOnShutdown := True;
  GMain := TThread.CurrentThread.ThreadID;
  GLock := TCriticalSection.Create;
  try
    { the invoker plugin must be mounted so the workers can Inject it }
    Ctx := TContext.Create('app');
    Ctx.Plugin(TUIInvokerPlugin.Create);
    Ctx.Plugin(TDownloadPlugin.Create('docs'));
    Ctx.Plugin(TDownloadPlugin.Create('images'));
    Ctx.Plugin(TDownloadPlugin.Create('data'));

    Writeln('--- main thread (the "UI thread"): ', GMain, ' - pumping while workers run ---');
    for I := 1 to 2000 do
    begin
      if GDone >= 3 then
        Break;
      CheckSynchronize;   { VCL/FMX: Application.Run does this for you }
      Sleep(5);
    end;

    { CreateAnonymousThread workers free themselves (FreeOnTerminate=True
      internally), so: give them a moment to finish their last Queue calls,
      drain the queue, then let them self-free before shutdown. }
    Sleep(100);
    CheckSynchronize;
    Sleep(50);

    Writeln('--- all downloads rendered on the main thread: ', GDone, '/3 done ---');
    Ctx.Dispose;
  finally
    GLock.Free;
  end;
end.
