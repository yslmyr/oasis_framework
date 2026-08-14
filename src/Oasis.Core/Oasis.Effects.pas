unit Oasis.Effects;

{ Oasis framework - reversible effect scopes. A scope is a LIFO stack of cleanup
  callbacks. Dispose pops in reverse order. A cleanup raising does NOT abort the
  rest; failures are aggregated into EOasisDisposeError. Manual early dispose via
  the returned TDisposer is idempotent and claims the entry so Dispose won't
  double-run it.

  PERFORMANCE DESIGN (perf pass, see spec §19): the lock is TOasisSpinLock -
  these critical sections are a few instructions (push/pop/claim) and never
  held while user cleanup code runs. }

interface

uses
  System.SysUtils, System.Generics.Collections,
  Oasis.Types, Oasis.Errors, Oasis.Spin;

type
  IEffectScope = interface
    ['{A1B2C3D4-E5F6-4A7B-8C9D-0E1F2A3B4C5D}']
    function IsActive: Boolean;
    function Add(AEffect: TEffectFn): TDisposer;
    function AddCleanup(ACleanup: TDisposer): TDisposer;
    procedure AddDisposable(AObj: IInterface);
    procedure Dispose;
  end;

  TEffectScope = class(TInterfacedObject, IEffectScope)
  private type
    { Each pushed cleanup is wrapped so manual early-dispose and Dispose never
      double-run it. Claim() atomically marks the entry as taken. }
    TEntry = class
    public
      Cleanup: TDisposer;
      Done: Boolean;
      constructor Create(ACleanup: TDisposer);
    end;
  strict private
    FLock: TOasisSpinLock;
    FStack: TStack<TEntry>;
    FDisposed: Boolean;
    function Claim(AEntry: TEntry): Boolean;
    procedure PushEntry(AEntry: TEntry);
    function TryPop(out AEntry: TEntry): Boolean;
  public
    constructor Create;
    destructor Destroy; override;
    function IsActive: Boolean;
    function Add(AEffect: TEffectFn): TDisposer;
    function AddCleanup(ACleanup: TDisposer): TDisposer;
    procedure AddDisposable(AObj: IInterface);
    procedure Dispose;
  end;

implementation

{ TEffectScope.TEntry }

constructor TEffectScope.TEntry.Create(ACleanup: TDisposer);
begin
  inherited Create;
  Cleanup := ACleanup;
  Done := False;
end;

{ TEffectScope }

constructor TEffectScope.Create;
begin
  inherited Create;
  FStack := TStack<TEntry>.Create;
end;

destructor TEffectScope.Destroy;
begin
  Dispose;
  FStack.Free;
  inherited Destroy;
end;

function TEffectScope.IsActive: Boolean;
begin
  Result := not FDisposed;
end;

procedure TEffectScope.PushEntry(AEntry: TEntry);
begin
  FLock.Enter;
  try
    if FDisposed then
    begin
      { already torn down: run immediately and drop, never retain }
      if Assigned(AEntry.Cleanup) then
        AEntry.Cleanup();
      AEntry.Free;
      Exit;
    end;
    FStack.Push(AEntry);
  finally
    FLock.Leave;
  end;
end;

function TEffectScope.Claim(AEntry: TEntry): Boolean;
begin
  FLock.Enter;
  try
    if AEntry.Done then
      Exit(False);
    AEntry.Done := True;
    Result := True;
  finally
    FLock.Leave;
  end;
end;

function TEffectScope.TryPop(out AEntry: TEntry): Boolean;
begin
  FLock.Enter;
  try
    Result := FStack.Count > 0;
    if Result then
      AEntry := FStack.Pop;
  finally
    FLock.Leave;
  end;
end;

function TEffectScope.Add(AEffect: TEffectFn): TDisposer;
var
  LCleanup: TDisposer;
begin
  if Assigned(AEffect) then
    LCleanup := AEffect()
  else
    LCleanup := nil;
  Result := AddCleanup(LCleanup);
end;

function TEffectScope.AddCleanup(ACleanup: TDisposer): TDisposer;
var
  LEntry: TEntry;
begin
  LEntry := TEntry.Create(ACleanup);
  PushEntry(LEntry);
  Result := procedure
            begin
              if Claim(LEntry) and Assigned(LEntry.Cleanup) then
                LEntry.Cleanup();
            end;
end;

procedure TEffectScope.AddDisposable(AObj: IInterface);
begin
  AddCleanup(procedure begin AObj := nil; end);
end;

procedure TEffectScope.Dispose;
var
  LErrors: TArray<string>;
  LFailed: Boolean;
  LEntry: TEntry;
begin
  FLock.Enter;
  try
    if FDisposed then
      Exit;
    FDisposed := True;
  finally
    FLock.Leave;
  end;

  LFailed := False;
  while TryPop(LEntry) do
  try
    try
      if Claim(LEntry) and Assigned(LEntry.Cleanup) then
        LEntry.Cleanup();   { runs WITHOUT the lock held }
    finally
      LEntry.Free;
    end;
  except
    on E: Exception do
    begin
      LFailed := True;
      SetLength(LErrors, Length(LErrors) + 1);
      LErrors[High(LErrors)] := E.Message;
    end;
  end;

  if LFailed then
    raise EOasisDisposeError.Create(LErrors);
end;

end.
