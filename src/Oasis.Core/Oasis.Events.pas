unit Oasis.Events;

{ Oasis framework - event bus. Emit/Serial are synchronous, in registration
  order, with per-listener fault isolation (failures aggregate into
  EOasisEventError). Waterfall is around-middleware: a listener that does not
  call Next short-circuits the chain. On() attaches auto-unsubscription to an
  IEffectScope so listeners are reclaimed when their owner unloads. Emit
  bubbles to the parent bus (Fork support).

  PERFORMANCE DESIGN (perf pass, see spec §19): each event key maps to an
  IMMUTABLE listener array (copy-on-write). Dispatch (Emit/Waterfall) copies
  the array reference out under a short spin lock - no allocation, no list
  copy per dispatch - then iterates lock-free (the local dynarray reference
  keeps the snapshot alive even if a writer swaps in a new array).
  Mutations (On/RemoveListener) rebuild the array for that key only. The lock
  is TOasisSpinLock (user-mode, a few cycles) instead of a kernel
  TCriticalSection. }

interface

uses
  System.SysUtils, System.Rtti, System.Generics.Collections,
  Oasis.Types, Oasis.Errors, Oasis.Effects, Oasis.Spin;

type
  IEventBus = interface
    ['{C3D4E5F6-A7B8-4C9D-0E1F-2A3B4C5D6E7F}']
    function On(const AEvent: TEventKey; AHandler: TEventHandler): TDisposer; overload;
    function OnWaterfall(const AEvent: TEventKey;
                         AHandler: TWaterfallHandler): TDisposer; overload;
    function OnBail(const AEvent: TEventKey;
                    AHandler: TBailHandler): TDisposer; overload;
    function OnValue(const AEvent: TEventKey;
                     AHandler: TValueHandler): TDisposer; overload;

    procedure Emit(const AEvent: TEventKey; const AArgs: array of const);
    procedure Serial(const AEvent: TEventKey; const AArgs: array of const);
    { Returns True if the chain reached the end (no veto); False if short-circuited. }
    function  Waterfall(const AEvent: TEventKey; const AArgs: array of const): Boolean;
    { bail: run bail listeners in registration order; the first TRUTHY result
      (OasisIsTruthy) wins, the chain stops and the value is returned. When no
      listener returns a truthy value, TValue.Empty is returned. }
    function  Bail(const AEvent: TEventKey; const AArgs: array of const): TValue;
    { Typed-payload dispatch: invokes OnValue listeners with the payload as a
      TValue (bridge for the strongly-typed On<TPayload> wrapper). }
    procedure EmitValue(const AEvent: TEventKey; const AValue: TValue);
    { Remove the listener registered under AToken for AEvent (idempotent). }
    procedure RemoveListener(const AEvent: TEventKey; AToken: Integer);
    { Reassign the scope that owns auto-unsubscribe cleanups (used by reload to
      rewire listeners to a fresh scope). }
    procedure SetOwnerScope(AScope: IEffectScope);
  end;

  TEventBus = class(TInterfacedObject, IEventBus)
  strict private type
    TListenerKind = (lkEmit, lkWaterfall, lkBail, lkValue);
    TListener = record
      Token: Integer;
      Kind: TListenerKind;
      Emit: TEventHandler;
      Waterfall: TWaterfallHandler;
      Bail: TBailHandler;
      Value: TValueHandler;
    end;
    TListenerArray = TArray<TListener>;
    { heap state so anonymous Next callbacks can capture + mutate it (var
      parameters and nested procedures cannot be captured: E2555) }
    TWfState = class
    public
      ReachedEnd: Boolean;
    end;
  strict private
    FLock: TOasisSpinLock;
    FOwner: IEffectScope;
    FParent: IEventBus;
    FListeners: TDictionary<TEventKey, TListenerArray>;
    FNextToken: Integer;
    function AppendListener(const AEvent: TEventKey;
      const AListener: TListener): Integer;
    procedure WaterfallRun(const AArr: TListenerArray; const AArgs: TArray<TVarRec>;
      AFrom: Integer; AState: TWfState);
  public
    constructor Create(AOwner: IEffectScope; AParent: IEventBus);
    destructor Destroy; override;
    function On(const AEvent: TEventKey; AHandler: TEventHandler): TDisposer; overload;
    function OnWaterfall(const AEvent: TEventKey;
                         AHandler: TWaterfallHandler): TDisposer; overload;
    function OnBail(const AEvent: TEventKey;
                    AHandler: TBailHandler): TDisposer; overload;
    function OnValue(const AEvent: TEventKey;
                     AHandler: TValueHandler): TDisposer; overload;
    procedure Emit(const AEvent: TEventKey; const AArgs: array of const);
    procedure Serial(const AEvent: TEventKey; const AArgs: array of const);
    function  Waterfall(const AEvent: TEventKey; const AArgs: array of const): Boolean;
    function  Bail(const AEvent: TEventKey; const AArgs: array of const): TValue;
    procedure EmitValue(const AEvent: TEventKey; const AValue: TValue);
    procedure RemoveListener(const AEvent: TEventKey; AToken: Integer);
    procedure SetOwnerScope(AScope: IEffectScope); virtual;
  end;

implementation

{ TEventBus }

constructor TEventBus.Create(AOwner: IEffectScope; AParent: IEventBus);
begin
  inherited Create;
  FOwner := AOwner;
  FParent := AParent;
  FListeners := TDictionary<TEventKey, TListenerArray>.Create;
  FNextToken := 1;
end;

destructor TEventBus.Destroy;
begin
  FListeners.Free;
  inherited Destroy;
end;

function TEventBus.AppendListener(const AEvent: TEventKey;
  const AListener: TListener): Integer;
var
  LArr: TListenerArray;
begin
  { mutation path: rebuild the key's immutable array (copy-on-write) }
  FLock.Enter;
  try
    if not FListeners.TryGetValue(AEvent, LArr) then
      LArr := nil;
    SetLength(LArr, Length(LArr) + 1);
    Result := FNextToken;
    Inc(FNextToken);
    LArr[High(LArr)] := AListener;
    LArr[High(LArr)].Token := Result;
    FListeners.AddOrSetValue(AEvent, LArr);
  finally
    FLock.Leave;
  end;
end;

function TEventBus.On(const AEvent: TEventKey;
  AHandler: TEventHandler): TDisposer;
var
  LListener: TListener;
  LToken: Integer;
  LSelf: IEventBus;
begin
  LListener.Token := 0;
  LListener.Kind := lkEmit;
  LListener.Emit := AHandler;
  LListener.Waterfall := nil;
  LToken := AppendListener(AEvent, LListener);
  if FOwner <> nil then
  begin
    { capture the bus as its INTERFACE so the cleanup keeps it alive even if
      the bus variable is released before the owning scope (interface capture,
      not the raw class pointer which would use-after-free). The resulting
      bus<->scope reference cycle is broken by the scope's Dispose - same
      pattern as OnAsync. }
    LSelf := Self;
    FOwner.AddCleanup(
      procedure
      begin
        LSelf.RemoveListener(AEvent, LToken);
      end);
  end;
  Result := nil;
end;

function TEventBus.OnWaterfall(const AEvent: TEventKey;
  AHandler: TWaterfallHandler): TDisposer;
var
  LListener: TListener;
  LToken: Integer;
  LSelf: IEventBus;
begin
  LListener.Token := 0;
  LListener.Kind := lkWaterfall;
  LListener.Emit := nil;
  LListener.Waterfall := AHandler;
  LToken := AppendListener(AEvent, LListener);
  if FOwner <> nil then
  begin
    LSelf := Self;
    FOwner.AddCleanup(
      procedure
      begin
        LSelf.RemoveListener(AEvent, LToken);
      end);
  end;
  Result := nil;
end;

function TEventBus.OnBail(const AEvent: TEventKey;
  AHandler: TBailHandler): TDisposer;
var
  LListener: TListener;
  LToken: Integer;
  LSelf: IEventBus;
begin
  LListener.Token := 0;
  LListener.Kind := lkBail;
  LListener.Emit := nil;
  LListener.Waterfall := nil;
  LListener.Bail := AHandler;
  LListener.Value := nil;
  LToken := AppendListener(AEvent, LListener);
  if FOwner <> nil then
  begin
    LSelf := Self;
    FOwner.AddCleanup(
      procedure
      begin
        LSelf.RemoveListener(AEvent, LToken);
      end);
  end;
  Result := nil;
end;

function TEventBus.OnValue(const AEvent: TEventKey;
  AHandler: TValueHandler): TDisposer;
var
  LListener: TListener;
  LToken: Integer;
  LSelf: IEventBus;
begin
  LListener.Token := 0;
  LListener.Kind := lkValue;
  LListener.Emit := nil;
  LListener.Waterfall := nil;
  LListener.Bail := nil;
  LListener.Value := AHandler;
  LToken := AppendListener(AEvent, LListener);
  if FOwner <> nil then
  begin
    LSelf := Self;
    FOwner.AddCleanup(
      procedure
      begin
        LSelf.RemoveListener(AEvent, LToken);
      end);
  end;
  Result := nil;
end;

function TEventBus.Bail(const AEvent: TEventKey;
  const AArgs: array of const): TValue;
var
  LArr: TListenerArray;
  LIndex: Integer;
begin
  Result := TValue.Empty;
  FLock.Enter;
  try
    if not FListeners.TryGetValue(AEvent, LArr) then
      LArr := nil;
  finally
    FLock.Leave;
  end;
  for LIndex := 0 to High(LArr) do
    if LArr[LIndex].Kind = lkBail then
    begin
      Result := LArr[LIndex].Bail(AArgs);
      if OasisIsTruthy(Result) then
        Exit;   { first truthy result wins - stop the chain }
    end;
  if FParent <> nil then
    Result := FParent.Bail(AEvent, AArgs);
end;

procedure TEventBus.EmitValue(const AEvent: TEventKey; const AValue: TValue);
var
  LArr: TListenerArray;
  LListener: TListener;
  LErrors: TArray<string>;
  LFailed: Boolean;
begin
  FLock.Enter;
  try
    if not FListeners.TryGetValue(AEvent, LArr) then
      LArr := nil;
  finally
    FLock.Leave;
  end;
  LFailed := False;
  for LListener in LArr do
    if LListener.Kind = lkValue then
    try
      LListener.Value(AValue);
    except
      on E: Exception do
      begin
        LFailed := True;
        SetLength(LErrors, Length(LErrors) + 1);
        LErrors[High(LErrors)] := E.Message;
      end;
    end;
  if FParent <> nil then
    FParent.EmitValue(AEvent, AValue);
  if LFailed then
    raise EOasisEventError.Create(LErrors);
end;

procedure TEventBus.RemoveListener(const AEvent: TEventKey; AToken: Integer);
var
  LArr, LNew: TListenerArray;
  I, J: Integer;
begin
  FLock.Enter;
  try
    if not FListeners.TryGetValue(AEvent, LArr) then
      Exit;
    SetLength(LNew, Length(LArr));
    J := 0;
    for I := 0 to High(LArr) do
      if LArr[I].Token <> AToken then
      begin
        LNew[J] := LArr[I];
        Inc(J);
      end;
    if J = 0 then
      FListeners.Remove(AEvent)
    else
    begin
      SetLength(LNew, J);
      FListeners.AddOrSetValue(AEvent, LNew);
    end;
  finally
    FLock.Leave;
  end;
end;

procedure TEventBus.SetOwnerScope(AScope: IEffectScope);
begin
  FLock.Enter;
  try
    FOwner := AScope;
  finally
    FLock.Leave;
  end;
end;

procedure TEventBus.Emit(const AEvent: TEventKey; const AArgs: array of const);
var
  LArr: TListenerArray;
  LListener: TListener;
  LErrors: TArray<string>;
  LFailed: Boolean;
begin
  { hot path: copy the array reference out (refcount-bumped dynarray), then
    iterate lock-free }
  FLock.Enter;
  try
    if not FListeners.TryGetValue(AEvent, LArr) then
      LArr := nil;
  finally
    FLock.Leave;
  end;

  LFailed := False;
  for LListener in LArr do
    if LListener.Kind = lkEmit then
    try
      LListener.Emit(AArgs);
    except
      on E: Exception do
      begin
        LFailed := True;
        SetLength(LErrors, Length(LErrors) + 1);
        LErrors[High(LErrors)] := E.Message;
      end;
    end;

  if FParent <> nil then
    FParent.Emit(AEvent, AArgs);

  if LFailed then
    raise EOasisEventError.Create(LErrors);
end;

procedure TEventBus.Serial(const AEvent: TEventKey; const AArgs: array of const);
begin
  { Synchronous in Delphi: identical to Emit, kept for API parity with Cordis. }
  Emit(AEvent, AArgs);
end;

function TEventBus.Waterfall(const AEvent: TEventKey;
  const AArgs: array of const): Boolean;
var
  LArr: TListenerArray;
  LArgs: TArray<TVarRec>;
  I: Integer;
  LState: TWfState;
begin
  FLock.Enter;
  try
    if not FListeners.TryGetValue(AEvent, LArr) then
      LArr := nil;
  finally
    FLock.Leave;
  end;
  { open arrays cannot be captured by anonymous methods - copy once into a
    dynarray (an 'array of const' parameter accepts it directly) }
  SetLength(LArgs, Length(AArgs));
  for I := 0 to High(AArgs) do
    LArgs[I] := AArgs[I];
  LState := TWfState.Create;
  try
    LState.ReachedEnd := False;
    if LArr <> nil then
      WaterfallRun(LArr, LArgs, 0, LState);
    Result := LState.ReachedEnd;
  finally
    LState.Free;
  end;
end;

procedure TEventBus.WaterfallRun(const AArr: TListenerArray;
  const AArgs: TArray<TVarRec>; AFrom: Integer; AState: TWfState);
var
  I: Integer;
  LCalledNext: Boolean;
  LNext: TWaterfallNext;
  LListener: TListener;
begin
  { class-method recursion: anonymous Next callbacks may capture Self and
    local vars, but never a nested procedure (E2555) }
  I := AFrom;
  while (I <= High(AArr)) and not AState.ReachedEnd do
  begin
    LListener := AArr[I];
    if LListener.Kind = lkWaterfall then
    begin
      LCalledNext := False;
      LNext := procedure(const ANextArgs: array of const)
               begin
                 if LCalledNext then
                   Exit;
                 LCalledNext := True;
                 WaterfallRun(AArr, AArgs, I + 1, AState);
               end;
      LListener.Waterfall(AArgs, LNext);
      if not LCalledNext then
        Exit;   { short-circuit: handler vetoed }
    end;
    Inc(I);
  end;
  AState.ReachedEnd := True;
end;

end.
