unit SuiteMainForm;

(* Host main form of the BPL Suite demo. Owns the THost, provides IShellHost
  (tab docking, status bar, event log) as its single host-side plugin, and
  manages the feature BPL modules. Deliberate demo scenario: "Load all
  modules" mounts the two UI modules FIRST and the service module LAST, so
  the module list visibly shows PENDING -> ACTIVE (mount-order independence
  via dependency activation). Unloading the service module cascades: both UI
  tabs vanish; re-loading it heals them.

  The form knows NOTHING about module internals - only the SuiteContract
  interfaces and the ';factory=' class names. *)

interface

uses
  System.SysUtils, System.Classes, System.Generics.Collections,
  System.IOUtils, System.StrUtils, System.TypInfo,
  Winapi.Windows,
  Vcl.Forms, Vcl.Controls, Vcl.StdCtrls, Vcl.ComCtrls, Vcl.ExtCtrls,
  Vcl.Dialogs,
  Oasis.Types, Oasis.Errors, Oasis.Effects, Oasis.Services, Oasis.Events,
  Oasis.Inject, Oasis.Context, Oasis.Plugin, Oasis.BplContract,
  Oasis.BplLoader, Oasis.Loader, Oasis.Host,
  SuiteContract;

type
  TSuiteMainForm = class(TForm)
  private
    FHost: THost;
    FList: TListView;
    FPages: TPageControl;
    FLog: TMemo;
    FStatus: TStatusBar;
    FToolbar: TPanel;
    FViews: TList<ISuiteView>;
    FMounted: TList<string>;
    FSelfTestFailed: Boolean;
    procedure BuildUi;
    procedure LogLine(const AMsg: string);
    procedure RefreshList;
    procedure BtnClick(Sender: TObject);
    function ModulePath(const AFolder: string): string;
    function MountModule(const AFolder, AFactory: string): Boolean;
    procedure LoadOne;
    procedure LoadAll;
    procedure UnloadSelected;
    procedure ReloadSelected;
    procedure Pump(AMs: Integer);
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure AddView(AView: ISuiteView);
    procedure RemoveView(AView: ISuiteView);
    procedure ShowStatusMsg(const AMsg: string);
    procedure LogMsg(const AMsg: string);
    procedure RunSelfTest;
    property SelfTestFailed: Boolean read FSelfTestFailed;
  end;

var
  GSuiteMainForm: TSuiteMainForm;

implementation

type
  { IShellHost implementation - forwards to the form. All mounts and module
    callbacks happen on the main thread, so direct calls are safe. }
  TShellHostImpl = class(TInterfacedObject, IShellHost)
  strict private
    FForm: TSuiteMainForm;
  public
    constructor Create(AForm: TSuiteMainForm);
    procedure AddView(AView: ISuiteView);
    procedure RemoveView(AView: ISuiteView);
    procedure ShowStatus(const AMsg: string);
    procedure Log(const AMsg: string);
  end;

{ TShellHostImpl }

constructor TShellHostImpl.Create(AForm: TSuiteMainForm);
begin
  inherited Create;
  FForm := AForm;
end;

procedure TShellHostImpl.AddView(AView: ISuiteView);
begin
  FForm.AddView(AView);
end;

procedure TShellHostImpl.RemoveView(AView: ISuiteView);
begin
  FForm.RemoveView(AView);
end;

procedure TShellHostImpl.ShowStatus(const AMsg: string);
begin
  FForm.ShowStatusMsg(AMsg);
end;

procedure TShellHostImpl.Log(const AMsg: string);
begin
  FForm.LogMsg(AMsg);
end;

{ TSuiteMainForm }

constructor TSuiteMainForm.Create(AOwner: TComponent);
var
  LSelf: TSuiteMainForm;
begin
  inherited CreateNew(AOwner);
  GSuiteMainForm := Self;
  FViews := TList<ISuiteView>.Create;
  FMounted := TList<string>.Create;
  FMounted.Add('shell-host');
  BuildUi;

  FHost := THost.Create;
  FHost.Use(TBplPluginLoader.Create);
  FHost.Root.Events.On(EV_HOST_PLUGIN_FAILED,
    procedure(const A: array of const)
    begin
      if Length(A) >= 2 then
        LogLine('FAILED: ' + string(A[0].VUnicodeString) + ' - ' + string(A[1].VUnicodeString))
      else if Length(A) >= 1 then
        LogLine('FAILED: ' + string(A[0].VUnicodeString));
    end);

  { the host's only built-in plugin: the shell service every UI module docks to }
  LSelf := Self;
  FHost.Root.Plugin('shell-host',
    procedure(C: IContext)
    begin
      C.Services.Register(IShellHost, TShellHostImpl.Create(LSelf));
    end);
  FHost.Start;
  RefreshList;
  ShowStatusMsg('Ready - load modules to build the application.');

  if FindCmdLineSwitch('selftest') then
    RunSelfTest;
end;

destructor TSuiteMainForm.Destroy;
begin
  FHost.Free;
  FViews.Free;
  FMounted.Free;
  inherited Destroy;
end;

procedure TSuiteMainForm.BuildUi;

  function Btn(const ACaption: string; ATag: Integer): TButton;
  begin
    Result := TButton.Create(Self);
    Result.Parent := FToolbar;
    Result.SetBounds(8 + ATag * 170, 8, 160, 30);
    Result.Caption := ACaption;
    Result.Tag := ATag;
    Result.OnClick := BtnClick;
  end;

var
  LSplit: TSplitter;
begin
  Caption := 'Oasis BPL Suite - host exe + interface-oriented BPL modules';
  Width := 1020;
  Height := 680;
  Position := poScreenCenter;

  FToolbar := TPanel.Create(Self);
  FToolbar.Parent := Self;
  FToolbar.Align := alTop;
  FToolbar.Height := 44;
  FToolbar.Caption := '';

  Btn('Load module...', 0);
  Btn('Load all modules', 1);
  Btn('Reload selected', 2);
  Btn('Unload selected', 3);

  FList := TListView.Create(Self);
  FList.Parent := Self;
  FList.Align := alLeft;
  FList.Width := 240;
  FList.ViewStyle := vsReport;
  FList.ReadOnly := True;
  FList.RowSelect := True;
  FList.Columns.Add.Caption := 'Module';
  FList.Columns.Items[0].Width := 130;
  FList.Columns.Add.Caption := 'Status';
  FList.Columns.Items[1].Width := 90;

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
  FLog.Height := 120;
  FLog.ReadOnly := True;

  FStatus := TStatusBar.Create(Self);
  FStatus.Parent := Self;
  FStatus.Panels.Add;
  FStatus.Panels[0].Width := 900;
end;

procedure TSuiteMainForm.BtnClick(Sender: TObject);
begin
  case (Sender as TButton).Tag of
    0: LoadOne;
    1: LoadAll;
    2: ReloadSelected;
    3: UnloadSelected;
  end;
  RefreshList;
end;

function TSuiteMainForm.ModulePath(const AFolder: string): string;
begin
  Result := ExpandFileName(ExtractFilePath(ParamStr(0)) +
    '..\modules\' + AFolder + '\' + AFolder + '.bpl');
end;

function TSuiteMainForm.MountModule(const AFolder, AFactory: string): Boolean;
var
  LPath: string;
begin
  LPath := ModulePath(AFolder);
  if not FileExists(LPath) then
  begin
    LogLine('module BPL not found: ' + LPath);
    Exit(False);
  end;
  FHost.Mount('bpl:' + LPath + ';factory=' + AFactory);
  FMounted.Add('suite-' + Copy(AFolder, 6, MaxInt).ToLower);   { 'SuiteCore' -> 'suite-core' }
  LogLine('mounted ' + AFolder + ' (' + AFactory + ')');
  Result := True;
end;

procedure TSuiteMainForm.LoadOne;
var
  LDlg: TOpenDialog;
begin
  LDlg := TOpenDialog.Create(nil);
  try
    LDlg.Filter := 'BPL modules|*.bpl';
    LDlg.InitialDir := ExpandFileName(ExtractFilePath(ParamStr(0)) + '..\modules');
    if LDlg.Execute then
    begin
      FHost.Mount('bpl:' + LDlg.FileName + ';factory=' +
        Copy(ExtractFileName(LDlg.FileName), 1,
          Length(ExtractFileName(LDlg.FileName)) - 4) + 'Factory');
      LogLine('mounted ' + ExtractFileName(LDlg.FileName));
    end;
  finally
    LDlg.Free;
  end;
end;

procedure TSuiteMainForm.LoadAll;
begin
  { UI modules FIRST, services LAST: watch PENDING flip to ACTIVE below }
  MountModule('SuiteDashboard', 'TSuiteDashboardFactory');
  MountModule('SuiteOrders', 'TSuiteOrdersFactory');
  Pump(200);
  RefreshList;
  MountModule('SuiteCore', 'TSuiteCoreFactory');
  Pump(200);
  RefreshList;
  ShowStatusMsg('All modules loaded - unload SuiteCore to watch the cascade.');
end;

procedure TSuiteMainForm.UnloadSelected;
begin
  if (FList.Selected <> nil) and (FList.Selected.Caption <> 'shell-host') then
    if FHost.Root.Unload(FList.Selected.Caption) then
      LogLine('unloaded ' + FList.Selected.Caption);
end;

procedure TSuiteMainForm.ReloadSelected;
begin
  if (FList.Selected <> nil) and (FList.Selected.Caption <> 'shell-host') then
    if FHost.Root.Reload(FList.Selected.Caption) then
      LogLine('reloaded ' + FList.Selected.Caption);
end;

procedure TSuiteMainForm.Pump(AMs: Integer);
var
  LStop: Cardinal;
begin
  LStop := GetTickCount + Cardinal(AMs);
  repeat
    Application.ProcessMessages;
    Sleep(25);
  until GetTickCount >= LStop;
end;

procedure TSuiteMainForm.RefreshList;
var
  I: Integer;
  LItem: TListItem;
  LState: TFiberState;
  LStateText: string;
begin
  FList.Items.BeginUpdate;
  try
    FList.Items.Clear;
    for I := 0 to FMounted.Count - 1 do
    begin
      LState := FHost.PluginState(FMounted[I]);
      case LState of
        fsPending:  LStateText := 'PENDING';
        fsActive:   LStateText := 'active';
        fsFailed:   LStateText := 'FAILED';
      else
        LStateText := 'inactive';
      end;
      LItem := FList.Items.Add;
      LItem.Caption := FMounted[I];
      LItem.SubItems.Add(LStateText);
    end;
  finally
    FList.Items.EndUpdate;
  end;
end;

procedure TSuiteMainForm.LogLine(const AMsg: string);
begin
  FLog.Lines.Add(FormatDateTime('hh:nn:ss  ', Now) + AMsg);
end;

procedure TSuiteMainForm.AddView(AView: ISuiteView);
var
  LSheet: TTabSheet;
begin
  LSheet := TTabSheet.Create(FPages);
  LSheet.PageControl := FPages;
  LSheet.Caption := AView.Caption;
  AView.CreateView(LSheet).Parent := LSheet;
  FViews.Add(AView);
  LogLine('view added: ' + AView.Caption);
  RefreshList;
end;

procedure TSuiteMainForm.RemoveView(AView: ISuiteView);
var
  I: Integer;
begin
  for I := FViews.Count - 1 downto 0 do
    if FViews[I] = AView then
    begin
      LogLine('view removed: ' + AView.Caption);
      FViews.Delete(I);   { the TTabSheet (owned by FPages) frees the module's controls }
    end;
  RefreshList;
end;

procedure TSuiteMainForm.ShowStatusMsg(const AMsg: string);
begin
  FStatus.Panels[0].Text := AMsg;
end;

procedure TSuiteMainForm.LogMsg(const AMsg: string);
begin
  LogLine('[module] ' + AMsg);
end;

{ ---- selftest ---- }

procedure TSuiteMainForm.RunSelfTest;
var
  LOut: string;

  procedure Check(N: Integer; const ADesc: string; AOk: Boolean);
  begin
    TFile.AppendAllText(LOut, Format('%s %d - %s' + sLineBreak,
      [IfThen(AOk, 'ok  ', 'FAIL'), N, ADesc]));
    if not AOk then
      FSelfTestFailed := True;
  end;

  function Dash: ISuiteDashboardState;
  begin
    Result := FHost.Root.Services.Get(ISuiteDashboardState) as ISuiteDashboardState;
  end;

var
  LT1, LT2: string;
begin
  LOut := ExpandFileName(ExtractFilePath(ParamStr(0)) + 'bplsuite_selftest.txt');
  TFile.WriteAllText(LOut, 'BPL Suite selftest' + sLineBreak);
  try
    { 1-2: mount the UI modules BEFORE the service module -> both stay
      pending, no tabs; then SuiteCore activates them (order independence) }
    Check(1, 'mount dashboard+orders first', MountModule('SuiteDashboard', 'TSuiteDashboardFactory')
      and MountModule('SuiteOrders', 'TSuiteOrdersFactory'));
    Pump(300);
    Check(2, 'both UI modules PENDING (deps not resolvable), no tabs',
      (Length(FHost.PendingPlugins) = 2) and (FViews.Count = 0));

    Check(3, 'mount SuiteCore (services)', MountModule('SuiteCore', 'TSuiteCoreFactory'));
    Pump(600);
    TFile.AppendAllText(LOut, Format('info: core=%s dash=%s orders=%s tabs=%d pending=%d failed=%d' + sLineBreak,
      [GetEnumName(TypeInfo(TFiberState), Ord(FHost.PluginState('suite-core'))),
       GetEnumName(TypeInfo(TFiberState), Ord(FHost.PluginState('suite-dashboard'))),
       GetEnumName(TypeInfo(TFiberState), Ord(FHost.PluginState('suite-orders'))),
       FViews.Count, Length(FHost.PendingPlugins), Length(FHost.FailedPlugins)]));
    Check(4, 'core activated the UI modules: no pending, 2 tabs',
      (Length(FHost.PendingPlugins) = 0) and (FViews.Count = 2));

    { 5: cross-BPL [Inject] - dashboard renders from the injected services }
    Check(5, 'dashboard injected deps (clock text carries settings prefix)',
      Dash.ClockText.Contains('ACME'));

    { 6: lazy clock factory actually ticks (TTimer resolving per tick) }
    LT1 := Dash.ClockText;
    Pump(1300);
    LT2 := Dash.ClockText;
    Check(6, 'clock ticks (lazy factory resolved per display refresh)',
      (LT1 <> '') and (LT2 <> LT1));

    { 7: transient service - two resolves, two distinct instances }
    LT1 := TOasisDI.Need<ISuiteOrders>(FHost.Root.Services).Ticket;
    LT2 := TOasisDI.Need<ISuiteOrders>(FHost.Root.Services).Ticket;
    Check(7, 'transient ISuiteOrders: new instance per resolve',
      (LT1 <> LT2) and LT1.Contains('ACME-') and LT2.Contains('ACME-'));

    { 8: settings change event updates the dashboard live }
    (FHost.Root.Services.Get(ISuiteSettings) as ISuiteSettings).SetPrefix('ZONE');
    Pump(300);
    Check(8, 'settings change event updates dashboard prefix live',
      Dash.PrefixText.Contains('ZONE'));

    { 9: unload the service module -> cascade: tabs vanish, UI pending }
    FHost.Root.Unload('suite-core');
    Pump(400);
    Check(9, 'cascade on core unload: 2 pending, 0 tabs',
      (Length(FHost.PendingPlugins) = 2) and (FViews.Count = 0));

    { 10: re-load core in the SAME process (UnregisterClass + re-register):
      everything heals, fresh service instances }
    Check(10, 're-mount SuiteCore in-process', MountModule('SuiteCore', 'TSuiteCoreFactory'));
    Pump(600);
    Check(11, 'healed: no pending, 2 tabs again, fresh prefix default',
      (Length(FHost.PendingPlugins) = 0) and (FViews.Count = 2)
      and Dash.ClockText.Contains('ACME'));

    TFile.AppendAllText(LOut, IfThen(FSelfTestFailed, 'FAILED', 'ALL PASSED')
      + sLineBreak);
    TFile.AppendAllText(LOut, sLineBreak + '--- event log ---' + sLineBreak + FLog.Text
      + 'END' + sLineBreak);
  except
    on E: Exception do
    begin
      FSelfTestFailed := True;
      TFile.AppendAllText(LOut, 'EXCEPTION: ' + E.ClassName + ': ' + E.Message
        + sLineBreak);
      TFile.AppendAllText(LOut, sLineBreak + '--- event log ---' + sLineBreak + FLog.Text
        + 'END' + sLineBreak);
    end;
  end;
  Application.Terminate;
end;

end.
