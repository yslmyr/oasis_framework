program OasisBench;

{$APPTYPE CONSOLE}

{ Oasis micro-benchmark for the hot paths touched by the perf work:
    - Emit with 1 listener / 0 listeners
    - Service Resolve (hit)
    - On churn (mutation path)
  Same code compiles before and after the change; identical flags both runs. }

uses
  System.SysUtils, System.Diagnostics,
  Oasis.Types in '..\src\Oasis.Core\Oasis.Types.pas',
  Oasis.Spin in '..\src\Oasis.Core\Oasis.Spin.pas',
  Oasis.Errors in '..\src\Oasis.Core\Oasis.Errors.pas',
  Oasis.Effects in '..\src\Oasis.Core\Oasis.Effects.pas',
  Oasis.Services in '..\src\Oasis.Core\Oasis.Services.pas',
  Oasis.Events in '..\src\Oasis.Core\Oasis.Events.pas';

type
  IBenchSvc = interface
    ['{ABEC0001-0000-0000-0000-000000000001}']
  end;

  TBench = class
  public
    class procedure Emit1(N: Integer);
    class procedure Emit0(N: Integer);
    class procedure ResolveHit(N: Integer);
    class procedure Churn(N: Integer);
  end;

var
  GCounter: Int64;

procedure Report(const AName: string; AN, AElapMs: Int64);
begin
  Writeln(Format('%-22s %10d ops in %6d ms  -> %10.0f ops/s',
    [AName, AN, AElapMs, AN / (AElapMs / 1000.0)]));
end;

{ TBench }

class procedure TBench.Emit1(N: Integer);
var
  LScope: IEffectScope;
  LBus: IEventBus;
  LSw: TStopwatch;
  LCount: Int64;
  I: Integer;
begin
  LCount := 0;
  LScope := TEffectScope.Create;
  LBus := TEventBus.Create(LScope, nil);
  LBus.On('bench',
    procedure(const A: array of const)
    begin
      Inc(LCount);
    end);
  LSw := TStopwatch.StartNew;
  for I := 1 to N do
    LBus.Emit('bench', []);
  LSw.Stop;
  GCounter := GCounter + LCount;
  Report('Emit (1 listener)', N, LSw.ElapsedMilliseconds);
end;

class procedure TBench.Emit0(N: Integer);
var
  LScope: IEffectScope;
  LBus: IEventBus;
  LSw: TStopwatch;
  I: Integer;
begin
  LScope := TEffectScope.Create;
  LBus := TEventBus.Create(LScope, nil);
  LSw := TStopwatch.StartNew;
  for I := 1 to N do
    LBus.Emit('nobody-listening', []);
  LSw.Stop;
  Report('Emit (0 listeners)', N, LSw.ElapsedMilliseconds);
end;

class procedure TBench.ResolveHit(N: Integer);
var
  LReg: IServiceRegistry;
  LSw: TStopwatch;
  LInst: IInterface;
  I: Integer;
begin
  LReg := TServiceRegistry.Create(nil);
  LReg.Register(IBenchSvc, TInterfacedObject.Create);
  LSw := TStopwatch.StartNew;
  for I := 1 to N do
    if not LReg.Resolve(IBenchSvc, LInst) then
      raise Exception.Create('resolve failed');
  LSw.Stop;
  Report('Resolve (hit)', N, LSw.ElapsedMilliseconds);
end;

class procedure TBench.Churn(N: Integer);
var
  LScope: IEffectScope;
  LBus: IEventBus;
  LSw: TStopwatch;
  LCount: Int64;
  I: Integer;
begin
  LCount := 0;
  LScope := TEffectScope.Create;
  LBus := TEventBus.Create(LScope, nil);
  LSw := TStopwatch.StartNew;
  for I := 1 to N do
    LBus.On('churn/' + I.ToString,
      procedure(const A: array of const)
      begin
        Inc(LCount);
      end);
  LSw.Stop;
  GCounter := GCounter + LCount;
  Report('On (distinct keys)', N, LSw.ElapsedMilliseconds);
end;

begin
  TBench.Emit1(2000000);
  TBench.Emit0(2000000);
  TBench.ResolveHit(2000000);
  TBench.Churn(200000);
  Writeln('counter=', GCounter);
end.
