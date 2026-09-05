unit SuiteOrdersMain;

(* SuiteOrders BPL module - the TRANSIENT lifetime showcase. The module itself
  is a UI plugin (one tab) that also PUBLISHES a service: ISuiteOrders,
  registered with RegisterTransient - every resolve builds a fresh instance,
  visible in the UI as a changing object address and a growing sequence
  number. The ticket prefix comes from SuiteCore's settings service via an
  [Inject] field, so this module also demonstrates a UI module that is both
  service CONSUMER (settings) and service PROVIDER (orders) at once. *)

interface

uses
  System.Classes, System.SysUtils,
  Vcl.Controls, Vcl.StdCtrls, Vcl.ExtCtrls, Vcl.Forms,
  Oasis.Context, Oasis.Plugin, Oasis.Inject, Oasis.Services, Oasis.BplContract,
  SuiteContract;

type
  TSuiteOrdersPlugin = class(TOasisPlugin, ISuiteView)
  strict private
    [Inject] FSettings: ISuiteSettings;
    FRegistry: IServiceRegistry;   { set in Apply; owned ref released with the plugin }
    FLog: TListBox;
    procedure ResolveTicket(Sender: TObject);
  public
    constructor Create;
    procedure Apply(const Ctx: IContext); override;
    { ISuiteView }
    function Caption: string;
    function CreateView(AParent: TWinControl): TWinControl;
  end;

  TSuiteOrdersFactory = class(TOasisPluginFactory)
  public
    function CreatePlugin: IPlugin; override;
  end;

implementation

type
  TSuiteOrdersImpl = class(TInterfacedObject, ISuiteOrders)
  strict private
    class var FCreates: Integer;
  strict private
    FPrefix: string;
    FSeq: Integer;
  public
    constructor Create(const APrefix: string);
    function Ticket: string;
  end;

{ TSuiteOrdersImpl }

constructor TSuiteOrdersImpl.Create(const APrefix: string);
begin
  inherited Create;
  Inc(FCreates);
  FPrefix := APrefix;
  FSeq := FCreates;
end;

function TSuiteOrdersImpl.Ticket: string;
begin
  Result := Format('%s-%d (obj %.8x)', [FPrefix, FSeq, NativeUInt(Self)]);
end;

{ TSuiteOrdersPlugin }

constructor TSuiteOrdersPlugin.Create;
begin
  inherited Create('suite-orders');
end;

procedure TSuiteOrdersPlugin.Apply(const Ctx: IContext);
var
  LShell: IShellHost;
  LSelf: ISuiteView;
begin
  LShell := Ctx.Services.Get(IShellHost) as IShellHost;
  LSelf := Self;
  LShell.AddView(LSelf);
  Ctx.Effects.AddCleanup(procedure begin LShell.RemoveView(LSelf); end);

  FRegistry := Ctx.Services;

  { TRANSIENT: the closure runs on EVERY resolve, reading the injected
    settings field live (both this fiber and the entry die together, so the
    captured plugin object always outlives the closure). }
  Ctx.Services.RegisterTransient(ISuiteOrders,
    function: IInterface
    begin
      Result := TSuiteOrdersImpl.Create(FSettings.Prefix);
    end);

  LShell.Log('orders mounted (provides transient ISuiteOrders)');
end;

function TSuiteOrdersPlugin.Caption: string;
begin
  Result := 'Orders';
end;

function TSuiteOrdersPlugin.CreateView(AParent: TWinControl): TWinControl;
var
  LPanel: TPanel;
  LBtn: TButton;
  LHint: TLabel;
begin
  LPanel := TPanel.Create(AParent);
  LPanel.Align := alClient;
  LPanel.Caption := '';

  LHint := TLabel.Create(LPanel);
  LHint.Parent := LPanel;
  LHint.Left := 24;
  LHint.Top := 20;
  LHint.Font.Size := 11;
  LHint.Caption := 'Each click RESOLVES ISuiteOrders - a transient factory '
    + 'builds a NEW instance every time (address changes, sequence grows):';

  LBtn := TButton.Create(LPanel);
  LBtn.Parent := LPanel;
  LBtn.Left := 24;
  LBtn.Top := 56;
  LBtn.Width := 220;
  LBtn.Caption := 'Resolve ticket (transient)';
  LBtn.OnClick := ResolveTicket;

  FLog := TListBox.Create(LPanel);
  FLog.Parent := LPanel;
  FLog.Left := 24;
  FLog.Top := 100;
  FLog.Width := AParent.Width - 48;
  FLog.Height := AParent.Height - 140;
  FLog.Anchors := [akLeft, akTop, akRight, akBottom];
  FLog.Font.Name := 'Consolas';

  Result := LPanel;
end;

procedure TSuiteOrdersPlugin.ResolveTicket(Sender: TObject);
begin
  if (FRegistry = nil) or (FSettings = nil) then
    Exit;
  FLog.Items.Add(TOasisDI.Need<ISuiteOrders>(FRegistry).Ticket);
end;

{ TSuiteOrdersFactory }

function TSuiteOrdersFactory.CreatePlugin: IPlugin;
begin
  Result := TSuiteOrdersPlugin.Create;
end;

initialization
  RegisterClass(TSuiteOrdersFactory);

finalization
  UnregisterClass(TSuiteOrdersFactory);

end.
