unit Oasis.Types;

{ Oasis framework - shared callback and value types, truthiness helper. }

interface

uses
  System.SysUtils, System.Rtti;

type
  { Cleanup function returned by side-effect registrations. Invoking it again is
    a no-op (idempotent); the owning scope also invokes it on teardown. }
  TDisposer = reference to procedure;

  { Side-effect factory: performs the side effect and returns its cleanup. }
  TEffectFn = reference to function: TDisposer;

  { Event name (flat namespace; convention: 'namespace/action'). }
  TEventKey = type string;

  { emit / serial listener. }
  TEventHandler = reference to procedure(const AArgs: array of const);

  { waterfall continuation: call to proceed to the next listener. }
  TWaterfallNext = reference to procedure(const AArgs: array of const);

  { waterfall listener: receive args + Next. Do not call Next to short-circuit. }
  TWaterfallHandler = reference to procedure(const AArgs: array of const;
                                             const ANext: TWaterfallNext);

  { bail listener: returns a value; the first TRUTHY result wins and stops the
    chain (Cordis 'bail' dispatch). }
  TBailHandler = reference to function(const AArgs: array of const): TValue;

  { Lifecycle of one mounted plugin fiber (Cordis state machine).
    fsPending  - mounted, but a required service is not available yet (Host)
    fsLoading  - Apply is running
    fsActive   - Apply completed
    fsUnloading- teardown (effects/listeners/services) in progress
    fsFailed   - Apply raised (effects rolled back; entry is kept for queries)
    fsDisposed - torn down / removed (also the answer for never-mounted names) }
  TFiberState = (fsPending, fsLoading, fsActive, fsUnloading, fsFailed,
    fsDisposed);

  { typed-payload listener (strongly-typed On<TPayload> bridge): the payload is
    carried as TValue internally; the generic wrapper in Oasis.TypedEvents
    converts to/from TPayload at the API boundary. }
  TValueHandler = reference to procedure(const AValue: TValue);

  { Cordis truthiness: non-empty and not false / nil. }
function OasisIsTruthy(const AValue: TValue): Boolean;

implementation

function OasisIsTruthy(const AValue: TValue): Boolean;
begin
  if AValue.IsEmpty then
    Exit(False);
  if AValue.IsType<Boolean> then
    Exit(AValue.AsBoolean);
  if AValue.IsObject then
    Exit(AValue.AsObject <> nil);
  if AValue.IsType<IInterface> then
    Exit(AValue.AsType<IInterface> <> nil);
  Result := True;
end;

end.
