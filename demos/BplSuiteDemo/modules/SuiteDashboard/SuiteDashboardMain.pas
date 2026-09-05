unit SuiteDashboardMain;

(* SuiteDashboard BPL module - the [Inject] showcase: the plugin declares its
  dependencies as attribute-marked INTERFACE FIELDS and Oasis populates them
  at mount time (no Service.Get calls in Apply). Because it needs ISuiteClock
  and ISuiteSettings - both provided by SuiteCore - the Host keeps it PENDING
  until that BPL is mounted, whatever the load order. Unloading SuiteCore
  cascades: this fiber deactivates, its tab disappears, and both return when
  the provider comes back.

  Also demonstrates a fiber-owned EVENT listener: Core emits
  EV_SUITE_SETTINGS_CHANGED and the prefix display updates live; the listener
  is removed automatically with the fiber. *)

interface

uses
  System.Classes, System.SysUtils,
  Vcl.Controls, Vcl.StdCtrls, Vcl.ExtCtrls, Vcl.Forms,
  Oasis.Context, Oasis.Plugin, Oasis.Inject, Oasis.BplContract, SuiteContract;

type
  TSuiteDashboardPlugin = class(TOasisPlugin, ISuiteView, ISuiteDashboardState)
  strict private
    [Inject] FClock: ISuiteClock;
    [Inject] FSettings: ISuiteSettings;
    FClockLabel: TLabel;
    FPrefixLabel: TLabel;
    FPrefixEdit: TEdit;
    procedure Tick(Sender: TObject);
    procedure ApplyPrefix(Sender: TObject);
    procedure RefreshClock;
  public
    constructor Create;
    procedure Apply(const Ctx: IContext); override;
    { ISuiteView }
    function Caption: string;
    function CreateView(AParent: TWinControl): TWinControl;
    { ISuiteDashboardState (selftest read-model) }
    function ClockText: string;
    function PrefixText: string;
  end;

  TSuiteDashboardFactory = class(TOasisPluginFactory)
  public
    function CreatePlugin: IPlugin; override;
  end;

implementation

{ TSuiteDashboardPlugin }

constructor TSuiteDashboardPlugin.Create;
begin
  inherited Create('suite-dashboard');
end;

procedure TSuiteDashboardPlugin.Apply(const Ctx: IContext);
var
  LShell: IShellHost;
  LSelf: ISuiteView;
begin
  LShell := Ctx.Services.Get(IShellHost) as IShellHost;
  LSelf := Self;
  LShell.AddView(LSelf);
  Ctx.Effects.AddCleanup(procedure begin LShell.RemoveView(LSelf); end);

  { read-model so the host/selftest can look inside the tab without linking
    this BPL (fiber-owned: unregisters with the tab) }
  Ctx.Services.Register(ISuiteDashboardState, Self as ISuiteDashboardState);

  { live prefix updates from the Core module (fiber-owned listener) }
  Ctx.Events.On(EV_SUITE_SETTINGS_CHANGED,
    procedure(const A: array of const)
    begin
      if (Length(A) >= 1) and (FPrefixLabel <> nil) then
      begin
        FPrefixLabel.Caption := 'prefix: ' + string(A[0].VUnicodeString);
        if FPrefixEdit <> nil then
          FPrefixEdit.Text := string(A[0].VUnicodeString);
      end;
    end);

  LShell.Log('dashboard mounted (deps injected: clock + settings)');
end;

function TSuiteDashboardPlugin.Caption: string;
begin
  Result := 'Dashboard';
end;

function TSuiteDashboardPlugin.CreateView(AParent: TWinControl): TWinControl;
var
  LPanel: TPanel;
  LTimer: TTimer;
  LBtn: TButton;
begin
  LPanel := TPanel.Create(AParent);
  LPanel.Align := alClient;
  LPanel.Caption := '';

  FPrefixLabel := TLabel.Create(LPanel);
  FPrefixLabel.Parent := LPanel;
  FPrefixLabel.Left := 24;
  FPrefixLabel.Top := 20;
  FPrefixLabel.Font.Size := 11;
  FPrefixLabel.Caption := 'prefix: ' + FSettings.Prefix;

  FPrefixEdit := TEdit.Create(LPanel);
  FPrefixEdit.Parent := LPanel;
  FPrefixEdit.Left := 160;
  FPrefixEdit.Top := 16;
  FPrefixEdit.Width := 160;
  FPrefixEdit.Text := FSettings.Prefix;

  LBtn := TButton.Create(LPanel);
  LBtn.Parent := LPanel;
  LBtn.Left := 336;
  LBtn.Top := 14;
  LBtn.Caption := 'Set prefix';
  LBtn.OnClick := ApplyPrefix;

  FClockLabel := TLabel.Create(LPanel);
  FClockLabel.Parent := LPanel;
  FClockLabel.Align := alClient;
  FClockLabel.Alignment := taCenter;
  FClockLabel.Layout := tlCenter;
  FClockLabel.Font.Size := 32;
  RefreshClock;

  LTimer := TTimer.Create(LPanel);   { dies with the tab }
  LTimer.Interval := 500;
  LTimer.OnTimer := Tick;

  Result := LPanel;
end;

procedure TSuiteDashboardPlugin.Tick(Sender: TObject);
begin
  { the timer is freed with the tab (view-host Remove cleanup) before the
    injector Clear could ever nil the fields - the guard is belt-and-braces }
  if (FClock <> nil) and (FClockLabel <> nil) then
    RefreshClock;
end;

procedure TSuiteDashboardPlugin.ApplyPrefix(Sender: TObject);
begin
  if FSettings <> nil then
    FSettings.SetPrefix(Trim(FPrefixEdit.Text));
end;

procedure TSuiteDashboardPlugin.RefreshClock;
begin
  FClockLabel.Caption := FSettings.Prefix + '  ' + FClock.NowText;
end;

function TSuiteDashboardPlugin.ClockText: string;
begin
  Result := '';
  if FClockLabel <> nil then
    Result := FClockLabel.Caption;
end;

function TSuiteDashboardPlugin.PrefixText: string;
begin
  Result := '';
  if FPrefixLabel <> nil then
    Result := FPrefixLabel.Caption;
end;

{ TSuiteDashboardFactory }

function TSuiteDashboardFactory.CreatePlugin: IPlugin;
begin
  Result := TSuiteDashboardPlugin.Create;
end;

initialization
  RegisterClass(TSuiteDashboardFactory);

finalization
  UnregisterClass(TSuiteDashboardFactory);

end.
