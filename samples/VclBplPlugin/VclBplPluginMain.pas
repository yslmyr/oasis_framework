unit VclBplPluginMain;

(* Sample BPL plugin WITH a user interface, loaded dynamically by the VCL host
  demo (demos/VclHostDemo). It adds a colored tab through the host's IViewHost
  service - proving a BPL can extend a running Windows app's UI.

  Factory contract: same as the console SamplePlugin of phase 3 - a
  TOasisPluginFactory registered under OASIS_BPL_FACTORY_CLASS in the
  initialization section; the host finds it via the shared rtl.bpl class
  list (host EXE built with -LUrtl,vcl). *)

interface

uses
  System.Classes, Vcl.Controls, Vcl.StdCtrls, Vcl.ExtCtrls, Vcl.Graphics,
  Oasis.Context, Oasis.Plugin, Oasis.BplContract, VclPluginContract;

type
  TVclBplPlugin = class(TOasisPlugin, IPluginView)
  public
    constructor Create;
    procedure Apply(const Ctx: IContext); override;
    function Caption: string;
    function CreateView(AParent: TWinControl): TWinControl;
  end;

  TVclBplPluginFactory = class(TOasisPluginFactory)
  public
    function CreatePlugin: IPlugin; override;
  end;

implementation

function TVclBplPluginFactory.CreatePlugin: IPlugin;
begin
  Result := TVclBplPlugin.Create;
end;

constructor TVclBplPlugin.Create;
begin
  inherited Create('vcl-bpl');
end;

procedure TVclBplPlugin.Apply(const Ctx: IContext);
var
  LViewHost: IViewHost;
  LSelf: IPluginView;
begin
  LViewHost := Ctx.Services.Get(IViewHost) as IViewHost;
  LSelf := Self;
  LViewHost.Add(LSelf);
  Ctx.Effects.AddCleanup(procedure begin LViewHost.Remove(LSelf); end);
end;

function TVclBplPlugin.Caption: string;
begin
  Result := 'Hello from a BPL plugin!';
end;

function TVclBplPlugin.CreateView(AParent: TWinControl): TWinControl;
var
  LPanel: TPanel;
  LLabel: TLabel;
begin
  LPanel := TPanel.Create(AParent);
  LPanel.Align := alClient;
  LPanel.Caption := '';
  LPanel.Color := clMoneyGreen;
  LLabel := TLabel.Create(LPanel);
  LLabel.Parent := LPanel;
  LLabel.Left := 24;
  LLabel.Top := 24;
  LLabel.Font.Size := 14;
  LLabel.Caption := 'This tab was loaded from a .bpl at run time.';
  Result := LPanel;
end;

initialization
  RegisterClassAlias(TVclBplPluginFactory, OASIS_BPL_FACTORY_CLASS);

end.
