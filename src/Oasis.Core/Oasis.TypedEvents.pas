unit Oasis.TypedEvents;

(* Oasis framework - strongly-typed events (the On<TPayload> variant deferred
  by spec §12 / promised as a phase-2 enhancement in §6.1).

  Delphi forbids generic methods on interfaces, so the typed layer is a generic
  RECORD wrapper around the weak-typed bus: the payload is carried internally
  as a TValue (TValueHandler / EmitValue on IEventBus), and converted to/from
  TPayload at the wrapper boundary - compile-time type safety for both ends:

    var E: TOasisEvent<TPoint>;
    E := TOasisEvent<TPoint>.Create('mouse/move');
    E.Subscribe(Ctx.Events,
      procedure(const P: TPoint)
      begin
        Writeln(P.X)
      end);
    E.Emit(Ctx.Events, Point(3, 4));

  Works for any TPayload TValue can box/unbox (ints, floats, strings, enums,
  records, classes, interfaces). Listener isolation, auto-unsubscribe on owner
  scope dispose, and fork bubbling all come from the underlying bus. *)

interface

uses
  System.SysUtils, System.Rtti,
  Oasis.Types, Oasis.Events;

type
  TOasisEvent<TPayload> = record
  strict private
    FName: TEventKey;
  public
    constructor Create(const AName: TEventKey);
    { The event name (flat namespace; convention 'namespace/action'). }
    property Name: TEventKey read FName;
    { Typed subscribe: the handler receives the payload as TPayload. }
    procedure Subscribe(ABus: IEventBus; AHandler: TProc<TPayload>);
    { Typed dispatch: delivers APayload to all typed listeners of this event. }
    procedure Emit(ABus: IEventBus; const APayload: TPayload);
  end;

implementation

{ TOasisEvent<TPayload> }

constructor TOasisEvent<TPayload>.Create(const AName: TEventKey);
begin
  FName := AName;
end;

procedure TOasisEvent<TPayload>.Subscribe(ABus: IEventBus;
  AHandler: TProc<TPayload>);
var
  LName: TEventKey;
begin
  LName := FName;
  ABus.OnValue(LName,
    procedure(const AValue: TValue)
    begin
      AHandler(AValue.AsType<TPayload>);
    end);
end;

procedure TOasisEvent<TPayload>.Emit(ABus: IEventBus;
  const APayload: TPayload);
begin
  ABus.EmitValue(FName, TValue.From<TPayload>(APayload));
end;

end.
