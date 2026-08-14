unit Oasis.OtlEvents;

{ Oasis framework - phase 2: async event bus backed by OmniThreadLibrary.
  TAsyncEventBus inherits the synchronous TEventBus (reusing On/Emit/Serial/
  Waterfall + the token-based auto-unsubscribe) and adds async handlers that run
  on the OTL thread pool. Parallel runs them concurrently (fork-join via
  IOmniFuture<T>.Value); SerialAsync runs them sequentially.

  Phase-2 refinements over the spec (forced by OTL reality, same 'spec-meets-
  reality' pattern as the MVP):
    - TAsyncEventHandler is a procedure (not a function returning IOmniFuture):
      OTL futures are generic and the framework wraps each listener in a future
      itself, which is far more ergonomic.
    - Parallel/SerialAsync return Integer (count run) and block until complete.
      The parallelism is in concurrent listener execution on the pool — the
      actual value Cordis 'parallel' provides. A non-blocking IOmniFuture<Integer>
      variant is a future refinement.
  Like the sync bus, an OnAsync registration creates a bus<->owner-scope
  reference cycle broken by calling the scope's Dispose. }

interface

uses
  System.SysUtils, System.SyncObjs, System.Generics.Collections,
  OtlParallel,
  Oasis.Types, Oasis.Errors, Oasis.Effects, Oasis.Events;

type
  TAsyncEventHandler = reference to procedure(const AArgs: array of const);

  IAsyncEventBus = interface(IEventBus)
    ['{1A2B3C4D-5E6F-4A7B-8C9D-0F1E2A3B4C5E}']
    function OnAsync(const AEvent: TEventKey; AHandler: TAsyncEventHandler): TDisposer;
    { Run all async listeners for AEvent concurrently on the OTL thread pool,
      block until all complete, return the number run. A listener raising does
      not stop the others; failures aggregate into EOasisEventError. }
    function Parallel(const AEvent: TEventKey; const AArgs: array of const): Integer;
    { Run async listeners sequentially (each on a pool thread), block, return count. }
    function SerialAsync(const AEvent: TEventKey; const AArgs: array of const): Integer;
    procedure RemoveAsyncListener(const AEvent: TEventKey; AToken: Integer);
  end;

  TAsyncEventBus = class(TEventBus, IEventBus, IAsyncEventBus)
  strict private type
    TAsyncListener = record
      Token: Integer;
      Handler: TAsyncEventHandler;
    end;
  strict private
    FAsyncLock: TCriticalSection;
    FAsyncOwner: IEffectScope;
    FAsyncListeners: TObjectDictionary<TEventKey, TList<TAsyncListener>>;
    FAsyncNextToken: Integer;
    function EnsureAsyncList(const AEvent: TEventKey): TList<TAsyncListener>;
    procedure SnapshotAsync(const AEvent: TEventKey; out ASnap: TList<TAsyncListener>);
    function MakeFuture(AHandler: TAsyncEventHandler;
      const AArgs: TArray<TVarRec>): IOmniFuture<string>;
  public
    constructor Create(AOwner: IEffectScope; AParent: IEventBus);
    destructor Destroy; override;
    function OnAsync(const AEvent: TEventKey; AHandler: TAsyncEventHandler): TDisposer;
    function Parallel(const AEvent: TEventKey; const AArgs: array of const): Integer;
    function SerialAsync(const AEvent: TEventKey; const AArgs: array of const): Integer;
    procedure RemoveAsyncListener(const AEvent: TEventKey; AToken: Integer);
  end;

{ Copy an open-array 'array of const' into a capture-friendly dynamic array (open
  arrays cannot be captured by anonymous methods). References point into the
  caller's data, which must outlive the copy. }
function OasisCopyArgs(const A: array of const): TArray<TVarRec>;

implementation

function OasisCopyArgs(const A: array of const): TArray<TVarRec>;
var
  I: Integer;
begin
  SetLength(Result, Length(A));
  for I := 0 to High(A) do
    Result[I] := A[I];
end;

{ TAsyncEventBus }

constructor TAsyncEventBus.Create(AOwner: IEffectScope; AParent: IEventBus);
begin
  inherited Create(AOwner, AParent);
  FAsyncLock := TCriticalSection.Create;
  FAsyncOwner := AOwner;   // own ref for OnAsync auto-unsubscribe
  FAsyncListeners := TObjectDictionary<TEventKey, TList<TAsyncListener>>.Create([doOwnsValues]);
  FAsyncNextToken := 1;
end;

destructor TAsyncEventBus.Destroy;
begin
  FAsyncListeners.Free;
  FAsyncLock.Free;
  inherited Destroy;
end;

function TAsyncEventBus.EnsureAsyncList(const AEvent: TEventKey): TList<TAsyncListener>;
begin
  if not FAsyncListeners.TryGetValue(AEvent, Result) then
  begin
    Result := TList<TAsyncListener>.Create;
    FAsyncListeners.Add(AEvent, Result);
  end;
end;

procedure TAsyncEventBus.SnapshotAsync(const AEvent: TEventKey;
  out ASnap: TList<TAsyncListener>);
var
  LSource: TList<TAsyncListener>;
begin
  ASnap := nil;
  FAsyncLock.Enter;
  try
    if FAsyncListeners.TryGetValue(AEvent, LSource) then
    begin
      ASnap := TList<TAsyncListener>.Create;
      ASnap.AddRange(LSource);
    end;
  finally
    FAsyncLock.Leave;
  end;
end;

function TAsyncEventBus.MakeFuture(AHandler: TAsyncEventHandler;
  const AArgs: TArray<TVarRec>): IOmniFuture<string>;
begin
  { AHandler/AArgs are value-captured (parameters): each future closes over its
    own pair. The delegate returns '' on success or the exception message on
    failure, so the future never raises fatally — isolation is handled by the
    caller aggregating non-empty results. Qualify OtlParallel.Parallel because
    this class also has a method named Parallel. }
  Result := OtlParallel.Parallel.Future<string>(
    function: string
    begin
      Result := '';
      try
        AHandler(AArgs);
      except
        on E: Exception do
          Result := E.Message;
      end;
    end);
end;

function TAsyncEventBus.OnAsync(const AEvent: TEventKey;
  AHandler: TAsyncEventHandler): TDisposer;
var
  LSelf: IAsyncEventBus;
  LEvent: TEventKey;
  LToken: Integer;
  LListener: TAsyncListener;
begin
  LSelf := Self;   // refcounted keep-alive (cycle broken by owner scope Dispose)
  LEvent := AEvent;
  LToken := FAsyncNextToken;
  Inc(FAsyncNextToken);
  LListener.Token := LToken;
  LListener.Handler := AHandler;
  FAsyncLock.Enter;
  try
    EnsureAsyncList(AEvent).Add(LListener);
  finally
    FAsyncLock.Leave;
  end;
  if FAsyncOwner <> nil then
    FAsyncOwner.AddCleanup(procedure begin LSelf.RemoveAsyncListener(LEvent, LToken); end);
  Result := nil;
end;

procedure TAsyncEventBus.RemoveAsyncListener(const AEvent: TEventKey; AToken: Integer);
var
  LList: TList<TAsyncListener>;
  I: Integer;
begin
  FAsyncLock.Enter;
  try
    if FAsyncListeners.TryGetValue(AEvent, LList) then
    begin
      for I := 0 to LList.Count - 1 do
        if LList[I].Token = AToken then
        begin
          LList.Delete(I);
          Break;
        end;
      if LList.Count = 0 then
        FAsyncListeners.Remove(AEvent);
    end;
  finally
    FAsyncLock.Leave;
  end;
end;

function TAsyncEventBus.Parallel(const AEvent: TEventKey;
  const AArgs: array of const): Integer;
var
  LSnap: TList<TAsyncListener>;
  LArgs: TArray<TVarRec>;
  LFutures: TList<IOmniFuture<string>>;
  LListener: TAsyncListener;
  LFut: IOmniFuture<string>;
  LMsgs: TArray<string>;
  LFailed: Boolean;
  LMsg: string;
begin
  Result := 0;
  SnapshotAsync(AEvent, LSnap);
  if LSnap = nil then
    Exit;
  LArgs := OasisCopyArgs(AArgs);
  LFutures := TList<IOmniFuture<string>>.Create;
  try
    for LListener in LSnap do
      LFutures.Add(MakeFuture(LListener.Handler, LArgs));
    LFailed := False;
    for LFut in LFutures do
    begin
      LMsg := LFut.Value;   // blocks until this future is done (join)
      if LMsg <> '' then
      begin
        LFailed := True;
        SetLength(LMsgs, Length(LMsgs) + 1);
        LMsgs[High(LMsgs)] := LMsg;
      end;
    end;
    Result := LFutures.Count;
  finally
    LFutures.Free;
    LSnap.Free;
  end;
  if LFailed then
    raise EOasisEventError.Create(LMsgs);
end;

function TAsyncEventBus.SerialAsync(const AEvent: TEventKey;
  const AArgs: array of const): Integer;
var
  LSnap: TList<TAsyncListener>;
  LArgs: TArray<TVarRec>;
  LListener: TAsyncListener;
  LFut: IOmniFuture<string>;
  LMsgs: TArray<string>;
  LFailed: Boolean;
  LMsg: string;
begin
  Result := 0;
  SnapshotAsync(AEvent, LSnap);
  if LSnap = nil then
    Exit;
  LArgs := OasisCopyArgs(AArgs);
  try
    LFailed := False;
    for LListener in LSnap do
    begin
      LFut := MakeFuture(LListener.Handler, LArgs);
      LMsg := LFut.Value;   // await before launching the next (sequential)
      if LMsg <> '' then
      begin
        LFailed := True;
        SetLength(LMsgs, Length(LMsgs) + 1);
        LMsgs[High(LMsgs)] := LMsg;
      end;
      Inc(Result);
    end;
  finally
    LSnap.Free;
  end;
  if LFailed then
    raise EOasisEventError.Create(LMsgs);
end;

end.
