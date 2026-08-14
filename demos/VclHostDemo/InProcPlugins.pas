unit InProcPlugins;

(* In-process UI plugins for the VCL host demo.

  - TSettingsPlugin: provides IAppSettings + an editable view (the provider
    side of the dependency-cascade showcase). Typing updates the service live;
    the Greet plugin reads it on every click.
  - TClockPlugin: a label updated by a background thread THROUGH IUIInvoker
    (Oasis.UI marshaling). The queued closures capture a refcounted label
    sink, so an update still queued after unload is a safe no-op. Fiber
    cleanups run LIFO: stop the thread -> unhook the label -> remove the view.
  - TGreetPlugin: injects IAppSettings (the cascade consumer): unload
    Settings and this plugin deactivates automatically (its tab vanishes);
    re-add Settings and it comes back. *)

interface

uses
  System.SysUtils, System.Classes,
  Vcl.Controls, Vcl.StdCtrls, Vcl.Forms, Vcl.ExtCtrls, Vcl.Dialogs,
  Oasis.Context, Oasis.Plugin, Oasis.UI, VclPluginContract;

type
  TSettingsPlugin = class(TOasisPlugin, IPluginView)
  strict private
    FSettings: IAppSettings;
  public
    constructor Create;
    procedure Apply(const Ctx: IContext); override;
    function Caption: string;
    function CreateView(AParent: TWinControl): TWinControl;
  end;

  TClockPlugin = class(TOasisPlugin, IPluginView)
  strict private
    FSinkLabel: TLabel;
  public
    constructor Create;
    procedure Apply(const Ctx: IContext); override;
    function Caption: string;
    function CreateView(AParent: TWinControl): TWinControl;
  end;

  TGreetPlugin = class(TOasisPlugin, IPluginView)
  strict private
    FSettings: IAppSettings;
  public
    constructor Create;
    procedure Apply(const Ctx: IContext); override;
    function Caption: string;
    function CreateView(AParent: TWinControl): TWinControl;
  end;

implementation

type
  TSettingsImpl = class(TInterfacedObject, IAppSettings)
  strict private
    FPrefix: string;
  public
    constructor Create;
    function GetPrefix: string;
    procedure SetPrefix(const AValue: string);
  end;

  { Anonymous methods cannot be assigned to TNotifyEvent, so the edit is a
    small class pushing its text into the service on every change. }
  TPrefixEdit = class(TEdit)
  strict private
    FSettings: IAppSettings;
  public
    procedure Change; override;
    property Settings: IAppSettings read FSettings write FSettings;
  end;

  ILabelSink = interface
    ['{EEEEEEEE-0000-0000-0000-00000000000E}']
    procedure SetLabel(ALabel: TLabel);
    procedure Update(const AText: string);
  end;

  TLabelSink = class(TInterfacedObject, ILabelSink)
  strict private
    FLabel: TLabel;
  public
    procedure SetLabel(ALabel: TLabel);
    procedure Update(const AText: string);
  end;

  TClockThread = class(TThread)
  strict private
    FInvoker: IUIInvoker;
    FSink: ILabelSink;
  protected
    procedure Execute; override;
  public
    constructor Create(AInvoker: IUIInvoker; ASink: ILabelSink);
  end;

  TGreetView = class(TPanel)
  strict private
    FSettings: IAppSettings;
    procedure GreetClick(Sender: TObject);
  public
    constructor CreateWithSettings(AOwner: TComponent; ASettings: IAppSettings);
  end;

{ TSettingsImpl }

constructor TSettingsImpl.Create;
begin
  inherited Create;
  FPrefix := 'Hi';
end;

function TSettingsImpl.GetPrefix: string;
begin
  Result := FPrefix;
end;

procedure TSettingsImpl.SetPrefix(const AValue: string);
begin
  FPrefix := AValue;
end;

{ TPrefixEdit }

procedure TPrefixEdit.Change;
begin
  inherited Change;
  if FSettings <> nil then
    FSettings.SetPrefix(Text);
end;

{ TLabelSink }

procedure TLabelSink.SetLabel(ALabel: TLabel);
begin
  FLabel := ALabel;
end;

procedure TLabelSink.Update(const AText: string);
begin
  if FLabel <> nil then
    FLabel.Caption := AText;
end;

{ TClockThread }

constructor TClockThread.Create(AInvoker: IUIInvoker; ASink: ILabelSink);
begin
  inherited Create(False);
  FInvoker := AInvoker;
  FSink := ASink;
end;

procedure TClockThread.Execute;
var
  LSink: ILabelSink;
  LInvoker: IUIInvoker;
begin
  LSink := FSink;
  LInvoker := FInvoker;
  while not Terminated do
  begin
    Sleep(200);
    if Terminated then
      Break;
    LInvoker.Queue(
      procedure
      begin
        LSink.Update(FormatDateTime('yyyy-mm-dd hh:nn:ss', Now));
      end);
  end;
end;

{ TGreetView }

constructor TGreetView.CreateWithSettings(AOwner: TComponent; ASettings: IAppSettings);
var
  LButton: TButton;
begin
  inherited Create(AOwner);
  Align := alClient;
  Caption := '';
  FSettings := ASettings;
  LButton := TButton.Create(Self);
  LButton.Parent := Self;
  LButton.SetBounds(16, 16, 260, 30);
  LButton.Caption := 'Greet me (reads the Settings service)';
  LButton.OnClick := GreetClick;
end;

procedure TGreetView.GreetClick(Sender: TObject);
begin
  ShowMessage(FSettings.GetPrefix + ' from the Oasis VCL host!');
end;

{ TSettingsPlugin }

constructor TSettingsPlugin.Create;
begin
  inherited Create('settings');
end;

procedure TSettingsPlugin.Apply(const Ctx: IContext);
var
  LViewHost: IViewHost;
  LSelf: IPluginView;
begin
  FSettings := TSettingsImpl.Create;
  Ctx.Services.Register(IAppSettings, FSettings);
  LViewHost := Ctx.Services.Get(IViewHost) as IViewHost;
  LSelf := Self;
  LViewHost.Add(LSelf);
  Ctx.Effects.AddCleanup(procedure begin LViewHost.Remove(LSelf); end);
end;

function TSettingsPlugin.Caption: string;
begin
  Result := 'Settings';
end;

function TSettingsPlugin.CreateView(AParent: TWinControl): TWinControl;
var
  LPanel: TPanel;
  LLabel: TLabel;
  LEdit: TPrefixEdit;
begin
  LPanel := TPanel.Create(AParent);
  LPanel.Align := alClient;
  LPanel.Caption := '';
  LLabel := TLabel.Create(LPanel);
  LLabel.Parent := LPanel;
  LLabel.Left := 16;
  LLabel.Top := 20;
  LLabel.Caption := 'Greeting prefix (consumed live by the Greet plugin):';
  LEdit := TPrefixEdit.Create(LPanel);
  LEdit.Parent := LPanel;
  LEdit.Left := 16;
  LEdit.Top := 44;
  LEdit.Width := 220;
  LEdit.Text := FSettings.GetPrefix;
  LEdit.Settings := FSettings;
  Result := LPanel;
end;

{ TClockPlugin }

constructor TClockPlugin.Create;
begin
  inherited Create('clock');
end;

procedure TClockPlugin.Apply(const Ctx: IContext);
var
  LViewHost: IViewHost;
  LSelf: IPluginView;
  LInvoker: IUIInvoker;
  LSink: ILabelSink;
  LThread: TClockThread;
begin
  LViewHost := Ctx.Services.Get(IViewHost) as IViewHost;
  LSelf := Self;
  LViewHost.Add(LSelf);
  LInvoker := Ctx.Services.Get(IUIInvoker) as IUIInvoker;
  LSink := TLabelSink.Create;
  if FSinkLabel <> nil then
    LSink.SetLabel(FSinkLabel);
  LThread := TClockThread.Create(LInvoker, LSink);
  Ctx.Effects.AddCleanup(procedure begin LViewHost.Remove(LSelf); end);
  Ctx.Effects.AddCleanup(procedure begin LSink.SetLabel(nil); end);
  Ctx.Effects.AddCleanup(
    procedure
    begin
      LThread.Terminate;
      LThread.WaitFor;
      LThread.Free;
    end);
end;

function TClockPlugin.Caption: string;
begin
  Result := 'Clock (UI-marshaled thread)';
end;

function TClockPlugin.CreateView(AParent: TWinControl): TWinControl;
var
  LPanel: TPanel;
  LLabel: TLabel;
begin
  LPanel := TPanel.Create(AParent);
  LPanel.Align := alClient;
  LPanel.Caption := '';
  LLabel := TLabel.Create(LPanel);
  LLabel.Parent := LPanel;
  LLabel.Left := 16;
  LLabel.Top := 20;
  LLabel.Caption := '(waiting for the worker thread...)';
  FSinkLabel := LLabel;
  Result := LPanel;
end;

{ TGreetPlugin }

constructor TGreetPlugin.Create;
begin
  inherited Create('greet');
  AddInject(IAppSettings);
end;

procedure TGreetPlugin.Apply(const Ctx: IContext);
var
  LViewHost: IViewHost;
  LSelf: IPluginView;
begin
  FSettings := Ctx.Services.Get(IAppSettings) as IAppSettings;
  LViewHost := Ctx.Services.Get(IViewHost) as IViewHost;
  LSelf := Self;
  LViewHost.Add(LSelf);
  Ctx.Effects.AddCleanup(procedure begin LViewHost.Remove(LSelf); end);
end;

function TGreetPlugin.Caption: string;
begin
  Result := 'Greet (depends on Settings)';
end;

function TGreetPlugin.CreateView(AParent: TWinControl): TWinControl;
begin
  Result := TGreetView.CreateWithSettings(AParent, FSettings);
end;

end.
