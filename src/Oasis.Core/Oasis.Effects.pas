unit Oasis.Effects;

{ Oasis framework - reversible effect scopes. A scope is a LIFO stack of cleanup
  callbacks. Dispose pops in reverse order. A cleanup raising does NOT abort the
  rest; failures are aggregated into EOasisDisposeError. Manual early dispose via
  the returned TDisposer is idempotent and claims the entry so Dispose won't
  double-run it. }

interface

uses
  System.SysUtils, System.SyncObjs, System.Generics.Collections,
  Oasis.Types, Oasis.Errors;

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
    TEntry = class
    public
      Cleanup: TDisposer;
      Done: Boolean;
      constructor Create(ACleanup: TDisposer);
    end;
  strict private
    FLock: TCriticalSection;
    FStack: TStack<TEntry>;
    FDisposed: Boolean;
    function Claim(AEntry: TEntry): Boolean;
    procedure PushEntry(AEntry: TEntry);
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
  FLock := TCriticalSection.Create;
  FStack := TStack<TEntry>.Create;
end;

destructor TEffectScope.Destroy;
begin
  Dispose;
  FStack.Free;
  FLock.Free;
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
  while True do
  begin
    FLock.Enter;
    try
      if FStack.Count = 0 then
        Break;
      LEntry := FStack.Pop;
    finally
      FLock.Leave;
    end;
    try
      try
        if Claim(LEntry) and Assigned(LEntry.Cleanup) then
          LEntry.Cleanup();
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
  end;

  if LFailed then
    raise EOasisDisposeError.Create(LErrors);
end;

end.
