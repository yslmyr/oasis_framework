unit SuiteCoreMain;

(* SuiteCore BPL module - the service-only package of the suite (the role
  Tangram's System package plays): no UI, provides the services every other
  module depends on. Registered lazily under the multi-BPL protocol of
  Oasis.BplContract: UNIQUE factory class name + UnregisterClass in the
  finalization, so the host can unload and re-load this BPL in-process. *)

interface

uses
  System.Classes, System.SysUtils,
  Oasis.Context, Oasis.Plugin, Oasis.BplContract, SuiteContract;

type
  TSuiteCorePlugin = class(TOasisPlugin)
  public
    constructor Create;
    procedure Apply(const Ctx: IContext); override;
  end;

  TSuiteCoreFactory = class(TOasisPluginFactory)
  public
    function CreatePlugin: IPlugin; override;
  end;

implementation

type
  TSuiteSettingsImpl = class(TInterfacedObject, ISuiteSettings)
  strict private
    FPrefix: string;
    FOnChanged: TProc<string>;
  public
    constructor Create(const APrefix: string; AOnChanged: TProc<string>);
    function Prefix: string;
    procedure SetPrefix(const AValue: string);
  end;

  TSuiteClockImpl = class(TInterfacedObject, ISuiteClock)
  public
    function NowText: string;
  end;

{ TSuiteSettingsImpl }

constructor TSuiteSettingsImpl.Create(const APrefix: string;
  AOnChanged: TProc<string>);
begin
  inherited Create;
  FPrefix := APrefix;
  FOnChanged := AOnChanged;
end;

function TSuiteSettingsImpl.Prefix: string;
begin
  Result := FPrefix;
end;

procedure TSuiteSettingsImpl.SetPrefix(const AValue: string);
begin
  if SameText(FPrefix, AValue) then
    Exit;
  FPrefix := AValue;
  if Assigned(FOnChanged) then
    FOnChanged(AValue);
end;

{ TSuiteClockImpl }

function TSuiteClockImpl.NowText: string;
begin
  Result := FormatDateTime('hh:nn:ss', Now);
end;

{ TSuiteCorePlugin }

constructor TSuiteCorePlugin.Create;
begin
  inherited Create('suite-core');
end;

procedure TSuiteCorePlugin.Apply(const Ctx: IContext);
begin
  { LAZY singleton: first Get builds, Has never does. }
  Ctx.Services.RegisterFactory(ISuiteClock,
    function: IInterface
    begin
      Result := TSuiteClockImpl.Create;
    end);

  { Plain instance service. Changing the prefix emits on the context event
    bus so subscribed UI modules update live. The OnChanged closure captures
    Ctx (IContext): released when the fiber-owned registry entry drops the
    settings instance at teardown - no cycle survives an unload. }
  Ctx.Services.Register(ISuiteSettings,
    TSuiteSettingsImpl.Create('ACME',
      procedure(AValue: string)
      begin
        Ctx.Events.Emit(EV_SUITE_SETTINGS_CHANGED, [AValue]);
      end));
end;

{ TSuiteCoreFactory }

function TSuiteCoreFactory.CreatePlugin: IPlugin;
begin
  Result := TSuiteCorePlugin.Create;
end;

initialization
  RegisterClass(TSuiteCoreFactory);

finalization
  UnregisterClass(TSuiteCoreFactory);

end.
