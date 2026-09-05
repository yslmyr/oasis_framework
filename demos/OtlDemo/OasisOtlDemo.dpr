program OasisOtlDemo;

{$APPTYPE CONSOLE}

{ Oasis phase-2 demo: async events via OmniThreadLibrary. Registers the async
  event bus factory, mounts 5 async listeners, and dispatches them in parallel.
  Each listener records the worker thread it ran on, so you can see concurrency
  (more than one distinct thread means the listeners really ran concurrently). }

uses
  System.SysUtils, System.SyncObjs, System.Generics.Collections,
  System.Classes, Winapi.Windows,
  Oasis.Types in '..\..\src\Oasis.Core\Oasis.Types.pas',
  Oasis.Errors in '..\..\src\Oasis.Core\Oasis.Errors.pas',
  Oasis.Spin in '..\..\src\Oasis.Core\Oasis.Spin.pas',
  Oasis.Effects in '..\..\src\Oasis.Core\Oasis.Effects.pas',
  Oasis.Services in '..\..\src\Oasis.Core\Oasis.Services.pas',
  Oasis.Events in '..\..\src\Oasis.Core\Oasis.Events.pas',
  Oasis.Inject in '..\..\src\Oasis.Core\Oasis.Inject.pas',
  Oasis.Context in '..\..\src\Oasis.Core\Oasis.Context.pas',
  Oasis.Plugin in '..\..\src\Oasis.Core\Oasis.Plugin.pas',
  Oasis.OtlEvents in '..\..\src\Oasis.Otl\Oasis.OtlEvents.pas';

var
  Ctx: IContext;
  Bus: IAsyncEventBus;
  Lock: TCriticalSection;
  Ids: TDictionary<TThreadID, Boolean>;
  I: Integer;
  LCount: Integer;
begin
  ReportMemoryLeaksOnShutdown := True;
  OasisRegisterAsyncEventBus;
  Ctx := TContext.Create('app');
  Bus := Ctx.Events as IAsyncEventBus;
  Lock := TCriticalSection.Create;
  Ids := TDictionary<TThreadID, Boolean>.Create;
  try
    for I := 1 to 5 do
      Bus.OnAsync('work',
        procedure(const A: array of const)
        begin
          Sleep(60);   { simulate work }
          Lock.Enter;
          try Ids.AddOrSetValue(TThread.CurrentThread.ThreadID, True); finally Lock.Leave; end;
        end);
    Writeln('Dispatching 5 async listeners in parallel...');
    LCount := Bus.Parallel('work', []);
    Writeln(Format('Ran %d listeners across %d distinct worker threads.',
      [LCount, Ids.Count]));
    Writeln('(>1 distinct thread => listeners ran concurrently, not serially.)');
    Ctx.Dispose;
  finally
    Ids.Free;
    Lock.Free;
  end;
end.
