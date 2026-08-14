unit MainForm;

(* VCL host demo - Oasis as a Windows app plugin-management system.

  Layout (built in code, no .dfm controls):
    [ toolbar: Add Settings | Add Clock | Add Greet | Load BPL... | Reload | Unload ]
    [ left: plugin list (name / status) ]  [ right: plugin-contributed tabs ]
    [ bottom: event log ]

  The host itself is just two Oasis plugins: 'view-host' registers IViewHost
  (tab management) and the UI invoker plugin registers IUIInvoker. Everything
  else - including the BPL-loaded one - is mounted/unmounted/reloaded at run
  time through THost, exactly like the console demos but with visible UI. *)

interface

uses
  System.SysUtils, System.Classes, System.Generics.Collections,
  Winapi.Windows, Winapi.Messages,
  Vcl.Forms, Vcl.Controls, Vcl.StdCtrls, Vcl.ComCtrls, Vcl.ExtCtrls, Vcl.Dialogs,
  Oasis.Types, Oasis.Errors, Oasis.Effects, Oasis.Services, Oasis.Events,
  Oasis.Context, Oasis.Plugin, Oasis.UI, Oasis.BplContract, Oasis.BplLoader,
  Oasis.Loader, Oasis.Host,
  VclPluginContract, InProcPlugins;

type
  TMainForm = class(TForm)
  private
    FHost: THost;
    FList: TListView;
    FPages: TPageControl;
    FLog: TMemo;
    FToolbar: TPanel;
    FMounted: TList<string>;
    procedure BuildUi;
    procedure Log(const AMsg: string);
    procedure RefreshList;
    procedure AddMounted(const AName: string);
    procedure BtnClick(Sender: TObject);
    procedure LoadBpl;
    procedure ReloadSelected;
    procedure UnloadSelected;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure AddView(AView: IPluginView);
    procedure RemoveView(AView: IPluginView);
    procedure RunSelfTest;
    procedure SelfTestBody(const AOut: string);
  end;

var
  GMainForm: TMainForm;

implementation

uses
  System.IOUtils;

type
  { IViewHost service implementation - forwards to the form. Mounts happen on
    the main thread (button clicks), so direct calls are safe. }
  TViewHostImpl = class(TInterfacedObject, IViewHost)
  strict private
    FForm: TMainForm;
  public
    constructor Create(AForm: TMainForm);
    procedure Add(AView: IPluginView);
    procedure Remove(AView: IPluginView);
  end;

  TViewEntry = record
    View: IPluginView;
    Sheet: TTabSheet;
  end;

var
  GViews: TList<TViewEntry>;

{ TViewHostImpl }

constructor TViewHostImpl.Create(AForm: TMainForm);
begin
  inherited Create;
  FForm := AForm;
end;

procedure TViewHostImpl.Add(AView: IPluginView);
begin
  FForm.AddView(AView);
end;

procedure TViewHostImpl.Remove(AView: IPluginView);
begin
  FForm.RemoveView(AView);
end;

{ TMainForm }

constructor TMainForm.Create(AOwner: TComponent);
var
  LSelf: TMainForm;
begin
  inherited CreateNew(AOwner);
  GMainForm := Self;
  GViews := TList<TViewEntry>.Create;
  FMounted := TList<string>.Create;
  BuildUi;

  FHost := THost.Create;
  FHost.Use(TBplPluginLoader.Create);
  FHost.Root.Events.On(EV_HOST_PLUGIN_FAILED,
    procedure(const A: array of const)
    begin
      if Length(A) >= 1 then
        Log('FAILED: ' + string(A[0].VUnicodeString));
    end);

  { host-side services, provided by two ordinary plugins }
  LSelf := Self;
  { the real view-host: a closure plugin registering IViewHost }
  FHost.Root.Plugin('view-host',
    procedure(C: IContext)
    begin
      C.Services.Register(IViewHost, TViewHostImpl.Create(LSelf));
    end);
  FHost.Mount(TUIInvokerPlugin.Create);
  AddMounted('view-host');
  AddMounted('ui-invoker');
  FHost.Start;
  RefreshList;

  if FindCmdLineSwitch('selftest') then
    RunSelfTest;
end;

destructor TMainForm.Destroy;
begin
  FHost.Free;
  FMounted.Free;
  GViews.Free;
  inherited Destroy;
end;

procedure TMainForm.BuildUi;

  function Btn(const ACaption: string; ATag: Integer): TButton;
  begin
    Result := TButton.Create(Self);
    Result.Parent := FToolbar;
    Result.SetBounds(8 + ATag * 150, 8, 140, 30);
    Result.Caption := ACaption;
    Result.Tag := ATag;
    Result.OnClick := BtnClick;
  end;

var
  LSplit: TSplitter;
begin
  Caption := 'Oasis VCL Host - plugin management demo';
  Width := 980;
  Height := 640;
  Position := poScreenCenter;

  FToolbar := TPanel.Create(Self);
  FToolbar.Parent := Self;
  FToolbar.Align := alTop;
  FToolbar.Height := 44;
  FToolbar.Caption := '';

  Btn('Add Settings', 0);
  Btn('Add Clock', 1);
  Btn('Add Greet', 2);
  Btn('Load BPL...', 3);
  Btn('Reload selected', 4);
  Btn('Unload selected', 5);

  FList := TListView.Create(Self);
  FList.Parent := Self;
  FList.Align := alLeft;
  FList.Width := 280;
  FList.ViewStyle := vsReport;
  FList.ReadOnly := True;
  FList.RowSelect := True;
  FList.Columns.Add.Caption := 'Plugin';
  FList.Columns.Items[0].Width := 140;
  FList.Columns.Add.Caption := 'Status';
  FList.Columns.Items[1].Width := 110;

  LSplit := TSplitter.Create(Self);
  LSplit.Parent := Self;
  LSplit.Align := alLeft;
  LSplit.Left := FList.Width;

  FPages := TPageControl.Create(Self);
  FPages.Parent := Self;
  FPages.Align := alClient;

  FLog := TMemo.Create(Self);
  FLog.Parent := Self;
  FLog.Align := alBottom;
  FLog.Height := 130;
  FLog.ReadOnly := True;
end;

procedure TMainForm.BtnClick(Sender: TObject);
begin
  case (Sender as TButton).Tag of
    0: begin FHost.Mount(TSettingsPlugin.Create); AddMounted('settings'); end;
    1: begin FHost.Mount(TClockPlugin.Create); AddMounted('clock'); end;
    2: begin FHost.Mount(TGreetPlugin.Create); AddMounted('greet'); end;
    3: LoadBpl;
    4: ReloadSelected;
    5: UnloadSelected;
  end;
  RefreshList;
end;

procedure TMainForm.LoadBpl;
var
  LDlg: TOpenDialog;
begin
  LDlg := TOpenDialog.Create(nil);
  try
    LDlg.Filter := 'BPL plugins|*.bpl';
    LDlg.InitialDir := ExtractFilePath(ParamStr(0)) + '..\..\samples\\VclBplPlugin';
    if LDlg.Execute then
    begin
      FHost.Mount('bpl:' + LDlg.FileName);
      AddMounted('bpl:' + ExtractFileName(LDlg.FileName));
      Log('BPL mounted: ' + LDlg.FileName);
    end;
  finally
    LDlg.Free;
  end;
end;

function SelectedName(AList: TListView): string;
begin
  Result := '';
  if (AList.Selected <> nil) and (AList.Selected.Caption <> 'view-host') and
     (AList.Selected.Caption <> 'ui-invoker') then
    Result := AList.Selected.Caption;
end;

procedure TMainForm.ReloadSelected;
var
  LName: string;
begin
  LName := SelectedName(FList);
  if (LName <> '') and not LName.StartsWith('bpl:') then
    if FHost.Root.Reload(LName) then
      Log('Reloaded: ' + LName);
end;

procedure TMainForm.UnloadSelected;
var
  LName: string;
begin
  LName := SelectedName(FList);
  if (LName <> '') and not LName.StartsWith('bpl:') then
    if FHost.Root.Unload(LName) then
      Log('Unloaded: ' + LName);
end;

procedure TMainForm.AddMounted(const AName: string);
begin
  if not FMounted.Contains(AName) then
    FMounted.Add(AName);
end;

procedure TMainForm.RefreshList;
var
  I: Integer;
  LName, LStatus: string;
  LPending, LFailed: TArray<string>;
  LItem: TListItem;
  J: Integer;
begin
  LPending := FHost.PendingPlugins;
  LFailed := FHost.FailedPlugins;
  FList.Items.BeginUpdate;
  try
    FList.Items.Clear;
    for I := 0 to FMounted.Count - 1 do
    begin
      LName := FMounted[I];
      LStatus := 'active';
      for J := 0 to Length(LPending) - 1 do
        if SameText(LName, LPending[J]) or LName.EndsWith(':' + LPending[J]) then
          LStatus := 'PENDING (dep gone)';
      for J := 0 to Length(LFailed) - 1 do
        if SameText(LName, LFailed[J]) or LName.EndsWith(':' + LFailed[J]) then
          LStatus := 'FAILED';
      LItem := FList.Items.Add;
      LItem.Caption := LName;
      LItem.SubItems.Add(LStatus);
    end;
  finally
    FList.Items.EndUpdate;
  end;
end;

procedure TMainForm.Log(const AMsg: string);
begin
  FLog.Lines.Add(FormatDateTime('hh:nn:ss  ', Now) + AMsg);
end;

procedure TMainForm.AddView(AView: IPluginView);
var
  LEntry: TViewEntry;
begin
  LEntry.View := AView;
  LEntry.Sheet := TTabSheet.Create(FPages);
  LEntry.Sheet.PageControl := FPages;
  LEntry.Sheet.Caption := AView.Caption;
  AView.CreateView(LEntry.Sheet).Parent := LEntry.Sheet;
  GViews.Add(LEntry);
  Log('view added: ' + AView.Caption);
  RefreshList;
end;

procedure TMainForm.RemoveView(AView: IPluginView);
var
  I: Integer;
begin
  for I := GViews.Count - 1 downto 0 do
    if GViews[I].View = AView then
    begin
      Log('view removed: ' + AView.Caption);
      GViews[I].Sheet.Free;   { frees the plugin's controls with it }
      GViews.Delete(I);
    end;
  RefreshList;
end;

procedure TMainForm.RunSelfTest;
var
  LOut: string;
begin
  LOut := ExpandFileName(ExtractFilePath(ParamStr(0)) + 'vclhost_selftest.txt');
  TFile.WriteAllText(LOut, 'start' + sLineBreak);
  try
    SelfTestBody(LOut);
  except
    { never let a failure pop a modal dialog in headless runs }
    on E: Exception do
      TFile.AppendAllText(LOut, 'EXCEPTION: ' + E.ClassName + ': ' + E.Message + sLineBreak +
        'END' + sLineBreak);
  end;
  Application.Terminate;
end;

procedure TMainForm.SelfTestBody(const AOut: string);
var
  LBplPath: string;
  I: Integer;
begin
  { automated end-to-end verification (no user interaction):
    mount in-proc plugins + the BPL plugin, watch the cascade remove the
    Greet tab when Settings goes away, re-add Settings and see it return. }
  FHost.Mount(TGreetPlugin.Create);   AddMounted('greet');
  FHost.Mount(TClockPlugin.Create);   AddMounted('clock');
  FHost.Mount(TSettingsPlugin.Create); AddMounted('settings');
  TFile.AppendAllText(AOut, 'mounted-inproc' + sLineBreak);

  LBplPath := ExpandFileName(ExtractFilePath(ParamStr(0)) +
    '..\..\samples\\VclBplPlugin\\VclBplPlugin.bpl');
  if FileExists(LBplPath) then
  begin
    FHost.Mount('bpl:' + LBplPath);
    AddMounted('bpl:' + ExtractFileName(LBplPath));
    TFile.AppendAllText(AOut, 'mounted-bpl' + sLineBreak);
  end;
  RefreshList;

  for I := 1 to 20 do   { let the clock thread tick + views settle }
  begin
    Sleep(50);
    Application.ProcessMessages;
  end;
  TFile.AppendAllText(AOut, 'settled' + sLineBreak);

  if FHost.Root.Services.Has(IAppSettings) then
    TFile.AppendAllText(AOut, 'settings-service:present;' + sLineBreak);
  TFile.AppendAllText(AOut, 'views:' + GViews.Count.ToString + ';' + sLineBreak);

  { cascade: removing Settings deactivates Greet (pending) and drops its tab }
  FHost.Root.Unload('settings');
  Sleep(100);
  Application.ProcessMessages;
  TFile.AppendAllText(AOut, 'after-unload:pending=' + Length(FHost.PendingPlugins).ToString +
    ',views=' + GViews.Count.ToString + ';' + sLineBreak);

  { provider returns -> consumer re-activates, tab comes back }
  FHost.Mount(TSettingsPlugin.Create);
  Sleep(100);
  Application.ProcessMessages;
  TFile.AppendAllText(AOut, 'after-remount:pending=' + Length(FHost.PendingPlugins).ToString +
    ',views=' + GViews.Count.ToString + ';' + sLineBreak);

  TFile.AppendAllText(AOut, 'END' + sLineBreak);
  Application.Terminate;
end;

end.
