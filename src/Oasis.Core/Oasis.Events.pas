unit Oasis.Events;

{ Oasis framework - event bus. Emit/Serial are synchronous, in registration
  order, with per-listener fault isolation (failures aggregate into
  EOasisEventError). Waterfall is around-middleware: a listener that does not
  call Next short-circuits the chain. On() attaches auto-unsubscription to an
  IEffectScope so listeners are reclaimed when their owner unloads. Each
  registration gets a unique integer token; the auto-unsub cleanup captures the
  bus as IEventBus (refcounted, keeping it alive until cleanup runs) and calls
  RemoveListener(Event, Token). NOTE: bus.FOwner(scope) and the scope's cleanup
  closure(bus) form a reference cycle - it is broken by calling the scope's
  Dispose, which the Context does during teardown. Emit bubbles to the parent
  bus (Fork support). }

interface

uses
  System.SysUtils, System.SyncObjs, System.Generics.Collections,
  Oasis.Types, Oasis.Errors, Oasis.Effects;

type
  IEventBus = interface
    ['{C3D4E5F6-A7B8-4C9D-0E1F-2A3B4C5D6E7F}']
    function On(const AEvent: TEventKey; AHandler: TEventHandler): TDisposer; overload;
    function OnWaterfall(const AEvent: TEventKey;
                         AHandler: TWaterfallHandler): TDisposer; overload;

    procedure Emit(const AEvent: TEventKey; const AArgs: array of const);
    procedure Serial(const AEvent: TEventKey; const AArgs: array of const);
    { Returns True if the chain reached the end (no veto); False if short-circuited. }
    function  Waterfall(const AEvent: TEventKey; const AArgs: array of const): Boolean;
    { Remove the listener registered under AToken for AEvent (idempotent). }
    procedure RemoveListener(const AEvent: TEventKey; AToken: Integer);
  end;

  TEventBus = class(TInterfacedObject, IEventBus)
  strict private type
    TListenerKind = (lkEmit, lkWaterfall);
    TListener = record
      Token: Integer;
      Kind: TListenerKind;
      Emit: TEventHandler;
      Waterfall: TWaterfallHandler;
    end;
  strict private
    FLock: TCriticalSection;
    FOwner: IEffectScope;
    FParent: IEventBus;
    FListeners: TObjectDictionary<TEventKey, TList<TListener>>;
    FNextToken: Integer;
    function EnsureList(const AEvent: TEventKey): TList<TListener>;
    procedure Snapshot(const AEvent: TEventKey; out ASnap: TList<TListener>);
  public
    constructor Create(AOwner: IEffectScope; AParent: IEventBus);
    destructor Destroy; override;
    function On(const AEvent: TEventKey; AHandler: TEventHandler): TDisposer; overload;
    function OnWaterfall(const AEvent: TEventKey;
                         AHandler: TWaterfallHandler): TDisposer; overload;
    procedure Emit(const AEvent: TEventKey; const AArgs: array of const);
    procedure Serial(const AEvent: TEventKey; const AArgs: array of const);
    function  Waterfall(const AEvent: TEventKey; const AArgs: array of const): Boolean;
    procedure RemoveListener(const AEvent: TEventKey; AToken: Integer);
  end;

implementation

{ TEventBus }

constructor TEventBus.Create(AOwner: IEffectScope; AParent: IEventBus);
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FOwner := AOwner;
  FParent := AParent;
  FListeners := TObjectDictionary<TEventKey, TList<TListener>>.Create([doOwnsValues]);
  FNextToken := 1;
end;

destructor TEventBus.Destroy;
begin
  FListeners.Free;
  FLock.Free;
  inherited Destroy;
end;

function TEventBus.EnsureList(const AEvent: TEventKey): TList<TListener>;
begin
  if not FListeners.TryGetValue(AEvent, Result) then
  begin
    Result := TList<TListener>.Create;
    FListeners.Add(AEvent, Result);
  end;
end;

procedure TEventBus.Snapshot(const AEvent: TEventKey; out ASnap: TList<TListener>);
var
  LSource: TList<TListener>;
begin
  ASnap := nil;
  FLock.Enter;
  try
    if FListeners.TryGetValue(AEvent, LSource) then
    begin
      ASnap := TList<TListener>.Create;
      ASnap.AddRange(LSource);
    end;
  finally
    FLock.Leave;
  end;
end;

procedure TEventBus.RemoveListener(const AEvent: TEventKey; AToken: Integer);
var
  LList: TList<TListener>;
  I: Integer;
begin
  FLock.Enter;
  try
    if FListeners.TryGetValue(AEvent, LList) then
    begin
      for I := 0 to LList.Count - 1 do
        if LList[I].Token = AToken then
        begin
          LList.Delete(I);
          Break;
        end;
      if LList.Count = 0 then
        FListeners.Remove(AEvent);
    end;
  finally
    FLock.Leave;
  end;
end;

function TEventBus.On(const AEvent: TEventKey;
  AHandler: TEventHandler): TDisposer;
var
  LSelf: IEventBus;
  LEvent: TEventKey;
  LToken: Integer;
  LListener: TListener;
begin
  LSelf := Self;
  LEvent := AEvent;
  LToken := FNextToken;
  Inc(FNextToken);
  LListener.Token := LToken;
  LListener.Kind := lkEmit;
  LListener.Emit := AHandler;
  LListener.Waterfall := nil;
  FLock.Enter;
  try
    EnsureList(AEvent).Add(LListener);
  finally
    FLock.Leave;
  end;
  if FOwner <> nil then
    FOwner.AddCleanup(
      procedure
      begin
        LSelf.RemoveListener(LEvent, LToken);
      end);
  Result := nil;
end;

function TEventBus.OnWaterfall(const AEvent: TEventKey;
  AHandler: TWaterfallHandler): TDisposer;
var
  LSelf: IEventBus;
  LEvent: TEventKey;
  LToken: Integer;
  LListener: TListener;
begin
  LSelf := Self;
  LEvent := AEvent;
  LToken := FNextToken;
  Inc(FNextToken);
  LListener.Token := LToken;
  LListener.Kind := lkWaterfall;
  LListener.Emit := nil;
  LListener.Waterfall := AHandler;
  FLock.Enter;
  try
    EnsureList(AEvent).Add(LListener);
  finally
    FLock.Leave;
  end;
  if FOwner <> nil then
    FOwner.AddCleanup(
      procedure
      begin
        LSelf.RemoveListener(LEvent, LToken);
      end);
  Result := nil;
end;

procedure TEventBus.Emit(const AEvent: TEventKey; const AArgs: array of const);
var
  LSnapshot: TList<TListener>;
  LListener: TListener;
  LErrors: TArray<string>;
  LFailed: Boolean;
begin
  Snapshot(AEvent, LSnapshot);
  LFailed := False;
  if LSnapshot <> nil then
  try
    for LListener in LSnapshot do
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
  finally
    LSnapshot.Free;
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
  LSnapshot: TList<TListener>;
  I: Integer;
  LContinue: Boolean;
  LStop: Boolean;
  LListener: TListener;
begin
  Snapshot(AEvent, LSnapshot);
  Result := True;
  if LSnapshot = nil then
    Exit;
  try
    I := 0;
    LStop := False;
    while (I < LSnapshot.Count) and not LStop do
    begin
      LListener := LSnapshot[I];
      if LListener.Kind = lkWaterfall then
      begin
        LContinue := False;
        LListener.Waterfall(AArgs,
          procedure(const ANextArgs: array of const)
          begin
            LContinue := True;
          end);
        if not LContinue then
          LStop := True;
      end;
      Inc(I);
    end;
    Result := not LStop;
  finally
    LSnapshot.Free;
  end;
end;

end.
