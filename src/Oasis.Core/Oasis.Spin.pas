unit Oasis.Spin;

(* Oasis framework - lightweight spin locks for very short critical sections
  (inspired by the pattern used in mORMot2's TLightLock/TRWLightLock, but
  written from scratch for Oasis's MIT licensing).

  - TOasisSpinLock: exclusive, NON-reentrant, one Integer of state.
  - TOasisRWSpinLock: multiple concurrent readers / single writer,
    NON-reentrant and non-upgradable. Bit 0 = write flag; upper bits = reader
    count.

  Both spin on TInterlocked.CompareExchange and yield the core between
  attempts (SwitchToThread on Windows, Sleep(0) elsewhere). They are meant for
  critical sections lasting a few CPU cycles - exactly the profile of the
  event/service/effect hot paths. For long sections keep TCriticalSection.
  WARNING: calling Enter twice on the same thread deadlocks (non-reentrant). *)

interface

uses
  System.SysUtils;

type
  TOasisSpinLock = record
  strict private
    FLocked: Integer;
    class procedure YieldCore; static;
  public
    procedure Enter;
    procedure Leave;
  end;

  TOasisRWSpinLock = record
  strict private
    FState: Integer;   { bit 0 = writer; bits 1.. = reader count / 2 }
    class procedure YieldCore; static;
  public
    procedure EnterRead;
    procedure LeaveRead;
    procedure EnterWrite;
    procedure LeaveWrite;
  end;

implementation

uses
  {$IFDEF MSWINDOWS}
  System.SyncObjs, Winapi.Windows;
  {$ELSE}
  System.Classes;
  {$ENDIF}

{ TOasisSpinLock }

class procedure TOasisSpinLock.YieldCore;
begin
  {$IFDEF MSWINDOWS}
  SwitchToThread;
  {$ELSE}
  Sleep(0);
  {$ENDIF}
end;

procedure TOasisSpinLock.Enter;
begin
  while TInterlocked.CompareExchange(FLocked, 1, 0) <> 0 do
    YieldCore;
end;

procedure TOasisSpinLock.Leave;
begin
  TInterlocked.Exchange(FLocked, 0);
end;

{ TOasisRWSpinLock }

class procedure TOasisRWSpinLock.YieldCore;
begin
  {$IFDEF MSWINDOWS}
  SwitchToThread;
  {$ELSE}
  Sleep(0);
  {$ENDIF}
end;

procedure TOasisRWSpinLock.EnterRead;
var
  LOld: Integer;
  LOk: Boolean;
begin
  repeat
    LOld := FState;
    LOk := (LOld and 1) = 0;
    if LOk then
      LOk := TInterlocked.CompareExchange(FState, LOld + 2, LOld) = LOld;
    if not LOk then
      YieldCore;
  until LOk;
end;

procedure TOasisRWSpinLock.LeaveRead;
begin
  TInterlocked.Add(FState, -2);
end;

procedure TOasisRWSpinLock.EnterWrite;
var
  LOld: Integer;
  LOk: Boolean;
begin
  repeat
    LOld := FState;
    LOk := LOld = 0;
    if LOk then
      LOk := TInterlocked.CompareExchange(FState, 1, 0) = 0;
    if not LOk then
      YieldCore;
  until LOk;
end;

procedure TOasisRWSpinLock.LeaveWrite;
begin
  TInterlocked.Exchange(FState, 0);
end;

end.
