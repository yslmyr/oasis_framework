unit Oasis.Types;

{ Oasis framework - shared callback and value types. No implementations. }

interface

uses
  System.SysUtils;

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

implementation

end.
