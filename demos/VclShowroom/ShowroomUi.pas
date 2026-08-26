unit ShowroomUi;

(* Oasis Showroom - a VCL app where every Cordis architecture advantage is one
   clickable, visible scenario:

     (1) mount-order independence  - greeter mounts BEFORE its dependencies and
         the list shows PENDING until config arrives (auto-activation rescan)
     (2) failure isolation + heal  - flaky raises during Apply => fsFailed,
         everything else untouched; Reload(name) re-runs Apply cleanly
     (3) dependency cascade        - unloading the 'json-config' provider deactivates
         appcfg AND greeter two hops away; re-providing restores both
     (4) config gating             - IOasisConfig.Disabled blocks TryMount
         (cordis.yml semantics); typed readers surface values in the monitor
     (5) Fork scope tree           - session forks shadow the GLOBAL badge with
         their own; their events bubble to root listeners; Dispose cascades
     (6) worker-thread marshaling  - a TThread emits progress on the event bus
         off-thread; UI updates happen ONLY through IUIInvoker.Queue

  Bottom strip: live event monitor. Right tabs: dispatch playground (emit /
  bail / waterfall with call counters) + context tree.

  Headless check: Showroom.exe /selftest runs every scenario programmatically,
  asserts states, writes vclshowroom_selftest.txt next to the EXE. *)

interface

uses
  System.SysUtils, System.Classes, System.Generics.Collections, System.Rtti,
  Winapi.Windows,
  Vcl.Forms, Vcl.Controls, Vcl.StdCtrls, Vcl.ComCtrls, Vcl.ExtCtrls,
  Vcl.Graphics,
  Oasis.Types, Oasis.Effects, Oasis.Events, Oasis.Context, Oasis.Plugin,
  Oasis.Host, Oasis.Config, Oasis.UI,
  ShowroomPlugins;

type
  TShowroomForm = class(TForm)
  strict private
    FHost: THost;
    FInvoker: IUIInvoker;
    FSessions: TList<IContext>;
    FSessionNames: TStringList;
    FSessionSeq: Integer;
    FGateOn: Boolean;
    FScenarioRunning: Boolean;
    FQuiet: Boolean;
    FJobDoneFlag: Boolean;

    { playground / monitor state }
    FEmitCount: Integer;
    FBailCalled: array[0..3] of Integer;
    FWfMidCalled: array[0..2] of Integer;
    FWfPassCalled: Integer;
    FHelloHits: Integer;
    FSessionHits: Integer;
    FProgressTicks: Integer;

    { self-test report }
    FSelReport: TStringList;

    { controls }
    FList: TListView;
    FTree: TTreeView;
    FMonitor: TMemo;
    FPlayOut: TMemo;
    FProgress: TProgressBar;
    FOrderBtn: TButton;
    FResetBtn: TButton;
    FJobBtn: TButton;

    procedure BuildUi;
    procedure Log(const AMsg: string);
    procedure SafeLog(const AMsg: string);
    procedure SafeQueue(AProc: TProc);
    function ArgsToStr(const AArgs: array of const): string;
    function ArgInt(const AArgs: array of const; AIndex: Integer): Integer;
    function ArgText(const AArgs: array of const; AIndex: Integer): string;
    procedure InstallRootListeners;
    procedure SetupHost(AFreshJson: Boolean);
    procedure EnsureUnmounted(const ANames: array of string);
    procedure ResetScenario(const ATitle: string);
    function ConfigPath: string;
    procedure WriteGateJson(ADisabledPreview: Boolean);
    procedure RemountConfigProvider(ADisabledPreview: Boolean);
    function BadgeOf(ACtx: IContext; out ABadge: string): Boolean;
    function NewSession: IContext;
    procedure DropSession(AIndex: Integer);
    function AnyPendingScenarioPlugin: Boolean;

    { scenario buttons }
    procedure OrderClick(Sender: TObject);
    procedure ResetClick(Sender: TObject);
    procedure FlakyFailClick(Sender: TObject);
    procedure FlakyHealClick(Sender: TObject);
    procedure UnloadProviderClick(Sender: TObject);
    procedure ProvideAgainClick(Sender: TObject);
    procedure GateClick(Sender: TObject);
    procedure AddSessionClick(Sender: TObject);
    procedure DisposeSessionClick(Sender: TObject);
    procedure JobClick(Sender: TObject);
    procedure ThreadDone(Sender: TObject);

    { dispatch playground }
    procedure PlayEmitClick(Sender: TObject);
    procedure PlayBailClick(Sender: TObject);
    procedure PlayWfVetoClick(Sender: TObject);
    procedure PlayWfPassClick(Sender: TObject);

    procedure RefreshList;
    procedure RefreshTree;
    procedure Delayed(AMS: Integer; const AProc: TProc);
    function Check(AName: string; ACond: Boolean): Boolean;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure RunSelfTest(const APath: string);
  end;

{ Ordinary-method timer dispatcher - anonymous methods are not TNotifyEvent,
  so a tiny component carries the timer and its own Tick method. }
TDelayedAction = class(TComponent)
strict private
  FTimer: TTimer;
  FProc: TProc;
  procedure Tick(Sender: TObject);
public
  class procedure After(AOwner: TComponent; AMS: Integer; const AProc: TProc);
end;

var
  GSelfTestFailures: Integer = 0;

implementation

uses
  System.IOUtils;

const
  SCENARIO_NAMES: array[0..4] of string =
    ('json-config', 'appcfg', 'greeter', 'flaky', 'preview');

function StateToStr(AState: TFiberState): string;
begin
  case AState of
    fsPending:   Result := '[PENDING ]';
    fsLoading:   Result := '[LOADING ]';
    fsActive:    Result := '[ACTIVE  ]';
    fsUnloading: Result := '[UNLOAD* ]';
    fsFailed:    Result := '[FAILED  ]';
  else           Result := '[DISPOSED]';
  end;
end;

function BoolText(AValue: Boolean): string;
begin
  if AValue then Result := 'true' else Result := 'false';
end;

{ ------------------------------------------------------------- timer helper }

class procedure TDelayedAction.After(AOwner: TComponent; AMS: Integer;
  const AProc: TProc);
var
  LAction: TDelayedAction;
begin
  LAction := TDelayedAction.Create(AOwner);
  LAction.FTimer := TTimer.Create(LAction);
  LAction.FTimer.Interval := AMS;
  LAction.FTimer.OnTimer := LAction.Tick;
  LAction.FTimer.Enabled := True;
  LAction.FProc := AProc;
end;

procedure TDelayedAction.Tick(Sender: TObject);
begin
  FTimer.Enabled := False;
  FTimer.OnTimer := nil;
  try
    FProc();
  finally
    Free;
  end;
end;

{ ------------------------------------------------------------ small helpers }

function TShowroomForm.ConfigPath: string;
begin
  Result := ExtractFilePath(ParamStr(0)) + 'showroom.json';
end;

procedure TShowroomForm.WriteGateJson(ADisabledPreview: Boolean);
begin
  TFile.WriteAllText(ConfigPath,
    '{"plugins":{"preview":{"disabled":' + BoolText(ADisabledPreview) +
    ',"config":{"retries":7,"verbose":true}}},"env":{}}');
end;

procedure TShowroomForm.Log(const AMsg: string);
begin
  if FQuiet then Exit;
  FMonitor.Lines.Add(FormatDateTime('hh:nn:ss.zzz', Now) + '  ' + AMsg);
end;

procedure TShowroomForm.SafeQueue(AProc: TProc);
var
  LInv: IUIInvoker;
begin
  if MainThreadID = GetCurrentThreadId then
  begin
    AProc();
    Exit;
  end;
  LInv := FInvoker;
  if LInv <> nil then
    LInv.Queue(AProc);
end;

procedure TShowroomForm.SafeLog(const AMsg: string);
begin
  SafeQueue(procedure begin Log(AMsg); end);
end;

function TShowroomForm.ArgsToStr(const AArgs: array of const): string;
var
  I: Integer;
  LOne: string;
begin
  Result := '';
  for I := 0 to High(AArgs) do
  begin
    case AArgs[I].VType of
      vtInteger:       LOne := IntToStr(AArgs[I].VInteger);
      vtInt64:         LOne := IntToStr(AArgs[I].VInt64^);
      vtBoolean:       LOne := BoolText(AArgs[I].VBoolean);
      vtExtended:      LOne := FloatToStr(AArgs[I].VExtended^);
      vtString:        LOne := string(AArgs[I].VString^);
      vtAnsiString:    LOne := string(AnsiString(AArgs[I].VAnsiString));
      vtPChar:         LOne := string(AArgs[I].VPChar);
      vtPWideChar:     LOne := string(AArgs[I].VPWideChar);
      vtUnicodeString: LOne := string(AArgs[I].VUnicodeString);
    else               LOne := '?';
    end;
    if Result <> '' then
      Result := Result + ', ';
    Result := Result + LOne;
  end;
end;

function TShowroomForm.ArgInt(const AArgs: array of const; AIndex: Integer): Integer;
begin
  Result := -1;
  if (AIndex < 0) or (AIndex > High(AArgs)) then Exit;
  if AArgs[AIndex].VType = vtInteger then
    Result := AArgs[AIndex].VInteger
  else if AArgs[AIndex].VType = vtInt64 then
    Result := Integer(AArgs[AIndex].VInt64^);
end;

function TShowroomForm.ArgText(const AArgs: array of const; AIndex: Integer): string;
begin
  Result := '';
  if (AIndex < 0) or (AIndex > High(AArgs)) then Exit;
  if AArgs[AIndex].VType = vtUnicodeString then
    Result := string(AArgs[AIndex].VUnicodeString);
end;

function TShowroomForm.BadgeOf(ACtx: IContext; out ABadge: string): Boolean;
var
  LBadge: ISessionBadge;
begin
  Result := False;
  ABadge := '';
  if ACtx = nil then Exit;
  try
    if Supports(ACtx.Services.Get(ISessionBadge), ISessionBadge, LBadge) then
    begin
      ABadge := LBadge.Badge;
      Result := True;
    end;
  except
    Result := False;
  end;
end;

{ ------------------------------------------------------------------ builder }

constructor TShowroomForm.Create(AOwner: TComponent);
begin
  inherited CreateNew(AOwner);
  Caption := 'Oasis Showroom - Cordis 架构优势演示（全部场景可点击观察）';
  ClientWidth := 1180;
  ClientHeight := 720;
  Position := poScreenCenter;
  Font.Name := 'Microsoft YaHei UI';
  Font.Size := 9;

  FSessions := TList<IContext>.Create;
  FSessionNames := TStringList.Create;
  FSessionSeq := 0;

  BuildUi;
  SetupHost(True);
  Log('[host] 就绪：基线插件 ui-invoker 与 json-config 已挂载，六个演示区随时可点。');
end;

destructor TShowroomForm.Destroy;
var
  I: Integer;
begin
  if FHost <> nil then
  begin
    for I := FSessions.Count - 1 downto 0 do
      try FSessions[I].Dispose; except end;
    FreeAndNil(FHost);   { destructor calls Shutdown -> root.Dispose }
  end;
  FreeAndNil(FSessions);
  FreeAndNil(FSessionNames);
  inherited Destroy;
end;

procedure TShowroomForm.BuildUi;

  function MakeButton(AParent: TWinControl; const ACaption: string;
    AHandler: TNotifyEvent): TButton;
  begin
    Result := TButton.Create(Self);
    Result.Parent := AParent;
    Result.Caption := ACaption;
    Result.OnClick := AHandler;
    Result.Height := 27;
  end;

  function MakeCard(AParent: TWinControl; const ACaption: string): TPanel;
  var
    LLab: TLabel;
  begin
    Result := TPanel.Create(Self);
    Result.Parent := AParent;
    Result.Width := 186;
    Result.Height := 136;
    Result.Margins.SetBounds(3, 3, 3, 3);
    Result.BevelOuter := bvNone;
    LLab := TLabel.Create(Self);
    LLab.Parent := Result;
    LLab.SetBounds(8, 6, 172, 18);
    LLab.Caption := ACaption;
    LLab.Font.Style := [fsBold];
  end;

var
  LTop, LMid, LLeftPan, LSep, LBot: TPanel;
  LFlow: TFlowPanel;
  LCard: TPanel;
  LPages: TPageControl;
  LPlaySheet, LTreeSheet: TTabSheet;
  LB: TButton;
  LLab: TLabel;
begin
  { ---- top: six scenario cards in one row ---- }
  LTop := TPanel.Create(Self);
  LTop.Parent := Self;
  LTop.Align := alTop;
  LTop.Height := 152;
  LTop.BevelOuter := bvNone;
  LTop.Padding.SetBounds(4, 2, 0, 2);

  LFlow := TFlowPanel.Create(Self);
  LFlow.Parent := LTop;
  LFlow.Align := alClient;
  LFlow.BevelOuter := bvNone;
  LFlow.AutoWrap := False;

  LCard := MakeCard(LFlow, '① 加载顺序无关');
  FOrderBtn := MakeButton(LCard, '乱序挂载 greeter→config', OrderClick);
  FOrderBtn.SetBounds(8, 30, 170, 27);
  FResetBtn := MakeButton(LCard, '清场重置', ResetClick);
  FResetBtn.SetBounds(8, 62, 170, 27);

  LCard := MakeCard(LFlow, '② 故障隔离 · Reload 愈合');
  LB := MakeButton(LCard, '挂载 flaky（注入故障）', FlakyFailClick);
  LB.SetBounds(8, 30, 170, 27);
  LB := MakeButton(LCard, '修复后 Reload(flaky)', FlakyHealClick);
  LB.SetBounds(8, 62, 170, 27);

  LCard := MakeCard(LFlow, '③ 依赖失效级联（两跳）');
  LB := MakeButton(LCard, '卸载 config 提供者', UnloadProviderClick);
  LB.SetBounds(8, 30, 170, 27);
  LB := MakeButton(LCard, '重新提供 config', ProvideAgainClick);
  LB.SetBounds(8, 62, 170, 27);

  LCard := MakeCard(LFlow, '④ 配置门控 cordis.yml');
  LB := MakeButton(LCard, 'TryMount preview（切换门控）', GateClick);
  LB.SetBounds(8, 30, 170, 27);
  LLab := TLabel.Create(Self);
  LLab.Parent := LCard;
  LLab.SetBounds(8, 66, 172, 56);
  LLab.WordWrap := True;
  LLab.Font.Size := 8;
  LLab.Font.Color := clGrayText;
  LLab.Caption := '改写 JSON 的 disabled 字段并重挂 config 提供者，观察 TryMount 是否放行';

  LCard := MakeCard(LFlow, '⑤ Fork 作用域树');
  LB := MakeButton(LCard, '+ 新会话（遮蔽演示）', AddSessionClick);
  LB.SetBounds(8, 30, 170, 27);
  LB := MakeButton(LCard, 'Dispose 选中会话', DisposeSessionClick);
  LB.SetBounds(8, 62, 170, 27);

  LCard := MakeCard(LFlow, '⑥ 工作线程→UI 封送');
  FJobBtn := MakeButton(LCard, '启动后台任务（5 步）', JobClick);
  FJobBtn.SetBounds(8, 30, 170, 27);

  { ---- bottom: progress strip + event monitor ---- }
  LBot := TPanel.Create(Self);
  LBot.Parent := Self;
  LBot.Align := alBottom;
  LBot.Height := 210;
  LBot.BevelOuter := bvNone;

  FMonitor := TMemo.Create(Self);
  FMonitor.Parent := LBot;
  FMonitor.Align := alClient;
  FMonitor.ReadOnly := True;
  FMonitor.ScrollBars := ssVertical;
  FMonitor.Font.Name := 'Consolas';
  FMonitor.Font.Size := 9;

  FProgress := TProgressBar.Create(Self);
  FProgress.Parent := LBot;
  FProgress.Align := alTop;
  FProgress.Height := 18;
  FProgress.Position := 0;

  LLab := TLabel.Create(Self);
  LLab.Parent := LBot;
  LLab.Align := alTop;
  LLab.Height := 18;
  LLab.Caption := '   事件监视器（根上下文的监听器能听到子作用域 fork 冒泡上来的事件；工作线程的行经 IUIInvoker 封送后打印）';

  { ---- middle band: plugin list | separator | right pages ---- }
  LMid := TPanel.Create(Self);
  LMid.Parent := Self;
  LMid.Align := alClient;
  LMid.BevelOuter := bvNone;

  LLeftPan := TPanel.Create(Self);
  LLeftPan.Parent := LMid;
  LLeftPan.Align := alLeft;
  LLeftPan.Width := 430;
  LLeftPan.BevelOuter := bvNone;
  LLeftPan.Padding.SetBounds(4, 4, 0, 4);

  FList := TListView.Create(Self);
  FList.Parent := LLeftPan;
  FList.Align := alClient;
  FList.ViewStyle := vsReport;
  FList.RowSelect := True;
  FList.ReadOnly := True;
  FList.GridLines := True;
  FList.Columns.Add.Caption := '插件名';
  FList.Columns.Add.Caption := '状态';
  FList.Columns.Add.Caption := '角色';
  FList.Columns[0].Width := 92;
  FList.Columns[1].Width := 96;
  FList.Columns[2].Width := 218;

  LSep := TPanel.Create(Self);
  LSep.Parent := LMid;
  LSep.Align := alLeft;
  LSep.Width := 4;
  LSep.Color := clBtnShadow;
  LSep.ParentColor := False;

  LPages := TPageControl.Create(Self);
  LPages.Parent := LMid;
  LPages.Align := alClient;

  LPlaySheet := TTabSheet.Create(Self);
  LPlaySheet.PageControl := LPages;
  LPlaySheet.Caption := '派发演练场';

  LB := MakeButton(LPlaySheet, 'Emit 广播（3 个监听器）', PlayEmitClick);
  LB.SetBounds(14, 14, 172, 27);
  LB := MakeButton(LPlaySheet, 'Bail 首真胜出', PlayBailClick);
  LB.SetBounds(198, 14, 150, 27);
  LB := MakeButton(LPlaySheet, 'Waterfall 否决', PlayWfVetoClick);
  LB.SetBounds(14, 48, 172, 27);
  LB := MakeButton(LPlaySheet, 'Waterfall 全放行', PlayWfPassClick);
  LB.SetBounds(198, 48, 150, 27);

  LLab := TLabel.Create(Self);
  LLab.Parent := LPlaySheet;
  LLab.SetBounds(14, 86, 340, 40);
  LLab.WordWrap := True;
  LLab.Font.Size := 8;
  LLab.Font.Color := clGrayText;
  LLab.Caption := '四种派发模式的监听器均已注册在根上下文上，点击按钮查看调用计数与链路行为对照说明。';

  FPlayOut := TMemo.Create(Self);
  FPlayOut.Parent := LPlaySheet;
  FPlayOut.Align := alBottom;
  FPlayOut.Height := 140;
  FPlayOut.ReadOnly := True;
  FPlayOut.ScrollBars := ssVertical;
  FPlayOut.Font.Name := 'Consolas';
  FPlayOut.Font.Size := 9;

  LTreeSheet := TTabSheet.Create(Self);
  LTreeSheet.PageControl := LPages;
  LTreeSheet.Caption := '作用域树 (Fork)';

  FTree := TTreeView.Create(Self);
  FTree.Parent := LTreeSheet;
  FTree.Align := alClient;
  FTree.ReadOnly := True;
  FTree.HideSelection := False;
end;

{ ------------------------------------------------------------- host plumbing }

procedure TShowroomForm.SetupHost(AFreshJson: Boolean);
var
  I: Integer;
begin
  for I := FSessions.Count - 1 downto 0 do
    try FSessions[I].Dispose; except end;
  FSessions.Clear;
  FSessionNames.Clear;
  FSessionSeq := 0;

  FEmitCount := 0;
  FBailCalled[0] := 0; FBailCalled[1] := 0; FBailCalled[2] := 0; FBailCalled[3] := 0;
  FWfMidCalled[0] := 0; FWfMidCalled[1] := 0; FWfMidCalled[2] := 0;
  FWfPassCalled := 0;
  FHelloHits := 0;
  FSessionHits := 0;
  FProgressTicks := 0;
  FGateOn := False;
  FScenarioRunning := False;
  FJobDoneFlag := True;
  FProgress.Position := 0;
  FJobBtn.Enabled := True;
  FOrderBtn.Enabled := True;

  if AFreshJson then
    WriteGateJson(False);

  FreeAndNil(FHost);
  FHost := THost.Create;

  FHost.Mount(TUIInvokerPlugin.Create);
  Supports(FHost.Root.Services.Get(IUIInvoker), IUIInvoker, FInvoker);

  { root-owned default badge: provided OUTSIDE any plugin lifetime }
  ProvideGlobalBadge(FHost.Root);

  InstallRootListeners;

  FHost.Mount(TJsonConfigPlugin.Create(ConfigPath));
  FHost.Start;

  RefreshList;
  RefreshTree;
end;

procedure TShowroomForm.InstallRootListeners;
var
  LEvents: IEventBus;

  procedure RegLog(const AKey, APrefix: string);
  begin
    LEvents.On(AKey,
      procedure(const AArgs: array of const)
      var
        LTxt: string;
      begin
        LTxt := ArgsToStr(AArgs);
        SafeLog(APrefix + LTxt);
      end);
  end;

begin
  LEvents := FHost.Root.Events;

  RegLog(EV_MARK, '[事件 showroom/mark]');

  LEvents.On(EV_GREET_HELLO,
    procedure(const AArgs: array of const)
    var
      LTxt: string;
    begin
      Inc(FHelloHits);
      LTxt := ArgsToStr(AArgs);
      SafeLog('[事件 greet/hello] ' + LTxt);
    end);

  LEvents.On(EV_SESSION_START,
    procedure(const AArgs: array of const)
    var
      LTxt: string;
    begin
      Inc(FSessionHits);
      LTxt := ArgText(AArgs, 0);
      SafeLog('[冒泡←子上下文] session/started ' + LTxt);
    end);

  LEvents.On(EV_JOB_PROGRESS,
    procedure(const AArgs: array of const)
    var
      LStep, LTotal: Integer;
    begin
      LStep := ArgInt(AArgs, 0);
      LTotal := ArgInt(AArgs, 1);
      SafeQueue(procedure
        begin
          Inc(FProgressTicks);
          if LTotal > 0 then
            FProgress.Position := Round(LStep * 100 / LTotal);
          Log(Format('[工作线程] job/progress %d/%d（已通过 IUIInvoker.Queue 封送到主线程）',
            [LStep, LTotal]));
        end);
    end);

  LEvents.On(EV_JOB_DONE,
    procedure(const AArgs: array of const)
    var
      LTxt: string;
    begin
      LTxt := ArgText(AArgs, 0);
      SafeQueue(procedure
        begin
          FJobDoneFlag := True;
          FJobBtn.Enabled := True;
          Log('[工作线程] job/done ' + LTxt);
        end);
    end);

  LEvents.On(EV_HOST_PLUGIN_FAILED,
    procedure(const AArgs: array of const)
    var
      LName, LMsg: string;
    begin
      LName := ArgText(AArgs, 0);
      LMsg := ArgText(AArgs, 1);
      SafeLog('[插件失败!] ' + LName + ' : ' + LMsg);
    end);

  { ---- dispatch playground handlers (counted) ---- }

  LEvents.On('play/emit',
    procedure(const AArgs: array of const)
    begin
      Inc(FEmitCount);
    end);
  LEvents.On('play/emit',
    procedure(const AArgs: array of const)
    begin
      Inc(FEmitCount);
    end);
  LEvents.On('play/emit',
    procedure(const AArgs: array of const)
    begin
      Inc(FEmitCount);
    end);

  LEvents.OnBail('play/bail',
    function(const AArgs: array of const): TValue
    begin
      Inc(FBailCalled[0]);
      Result := TValue.Empty;                     { falsy - chain continues }
    end);
  LEvents.OnBail('play/bail',
    function(const AArgs: array of const): TValue
    begin
      Inc(FBailCalled[1]);
      Result := TValue.Empty;                     { falsy - chain continues }
    end);
  LEvents.OnBail('play/bail',
    function(const AArgs: array of const): TValue
    begin
      Inc(FBailCalled[2]);
      Result := TValue.From<string>('answer #3'); { TRUTHY - wins and stops }
    end);
  LEvents.OnBail('play/bail',
    function(const AArgs: array of const): TValue
    begin
      Inc(FBailCalled[3]);                        { must stay 0: chain stopped }
      Result := TValue.From<string>('answer #4 NEVER');
    end);

  LEvents.OnWaterfall('play/wf',
    procedure(const AArgs: array of const; const ANext: TWaterfallNext)
    begin
      Inc(FWfMidCalled[0]);
      ANext(AArgs);
    end);
  LEvents.OnWaterfall('play/wf',
    procedure(const AArgs: array of const; const ANext: TWaterfallNext)
    begin
      Inc(FWfMidCalled[1]);
      { veto: deliberately NOT calling Next short-circuits the chain }
    end);
  LEvents.OnWaterfall('play/wf',
    procedure(const AArgs: array of const; const ANext: TWaterfallNext)
    begin
      Inc(FWfMidCalled[2]);
      ANext(AArgs);
    end);

  LEvents.OnWaterfall('play/wf2',
    procedure(const AArgs: array of const; const ANext: TWaterfallNext)
    begin
      Inc(FWfPassCalled);
      ANext(AArgs);
    end);
end;

{ ------------------------------------------------------------ list and tree }

procedure TShowroomForm.RefreshList;

  procedure AddRow(const AName, ADesc: string);
  var
    LItem: TListItem;
  begin
    LItem := FList.Items.Add;
    LItem.Caption := AName;
    LItem.SubItems.Add(StateToStr(FHost.PluginState(AName)));
    LItem.SubItems.Add(ADesc);
  end;

begin
  if FHost = nil then Exit;
  FList.Items.BeginUpdate;
  try
    FList.Items.Clear;
    AddRow('json-config','提供 IOasisConfig（JSON 文件）');
    AddRow('appcfg',    'IOasisConfig → IAppConfig 适配层');
    AddRow('greeter',   '注入 IAppConfig 的消费者');
    AddRow('flaky',     '可注入故障的演示插件');
    AddRow('preview',   '受 disabled 门控的消费者');
    AddRow('ui-invoker','主线程封送桥服务');
  finally
    FList.Items.EndUpdate;
  end;
end;

procedure TShowroomForm.RefreshTree;
var
  I: Integer;
  LRootNode: TTreeNode;
  LBadge: string;
begin
  FTree.Items.BeginUpdate;
  try
    FTree.Items.Clear;
    if BadgeOf(FHost.Root, LBadge) then
      LRootNode := FTree.Items.AddChild(nil, 'root(host) · 全局 ISessionBadge = ' + LBadge)
    else
      LRootNode := FTree.Items.AddChild(nil, 'root(host)');
    for I := 0 to FSessions.Count - 1 do
      FTree.Items.AddChildObjectFirst(LRootNode,
        'session-' + FSessionNames[I] + ' · 遮蔽 ISessionBadge',
        Pointer(NativeInt(I) + 1));
    LRootNode.Expand(False);
  finally
    FTree.Items.EndUpdate;
  end;
end;

{ ------------------------------------------------------------ scenarios (UI) }

procedure TShowroomForm.EnsureUnmounted(const ANames: array of string);
var
  I: Integer;
begin
  for I := Low(ANames) to High(ANames) do
    FHost.Root.Unload(ANames[I]);
end;

function TShowroomForm.AnyPendingScenarioPlugin: Boolean;
var
  I: Integer;
begin
  Result := False;
  for I := Low(SCENARIO_NAMES) to High(SCENARIO_NAMES) do
    if FHost.PluginState(SCENARIO_NAMES[I]) = fsPending then
      Exit(True);
end;

procedure TShowroomForm.ResetScenario(const ATitle: string);
begin
  FScenarioRunning := False;
  EnsureUnmounted(SCENARIO_NAMES);
  RefreshList;
  Log(ATitle);
end;

procedure TShowroomForm.Delayed(AMS: Integer; const AProc: TProc);
begin
  TDelayedAction.After(Self, AMS, AProc);
end;

procedure TShowroomForm.OrderClick(Sender: TObject);
begin
  if FScenarioRunning then Exit;
  if AnyPendingScenarioPlugin then
  begin
    Log('[提示] 队列中仍有 PENDING 插件，请先点「清场重置」。');
    Exit;
  end;
  FScenarioRunning := True;
  FOrderBtn.Enabled := False;

  ResetScenario('[演示①] 乱序挂载：先挂 greeter（它依赖的服务还不存在）…');
  FHost.Mount(TGreeterPlugin.Create);
  RefreshList;
  Delayed(900,
    procedure
    begin
      Log('[演示①] 此刻 greeter 缺 IAppConfig → 停在 PENDING 等待队列。接着挂中间层 appcfg …');
      FHost.Mount(TAppCfgPlugin.Create);
      RefreshList;
    end);
  Delayed(1800,
    procedure
    begin
      Log('[演示①] appcfg 同样缺 IOasisConfig → 也进入 PENDING。最后挂根提供者 config …');
      FHost.Mount(TJsonConfigPlugin.Create(ConfigPath));
      RefreshList;
    end);
  Delayed(2700,
    procedure
    begin
      Log('[演示①] 完成：config 注册服务的瞬间宿主重扫队列，appcfg 与 greeter 自动激活（监视器可见 greet/hello）。加载顺序完全无关紧要。');
      FScenarioRunning := False;
      FOrderBtn.Enabled := True;
      RefreshList;
    end);
end;

procedure TShowroomForm.ResetClick(Sender: TObject);
begin
  ResetScenario('[场景] 已清场：五个演示插件全部卸载。');
end;

procedure TShowroomForm.FlakyFailClick(Sender: TObject);
begin
  if FScenarioRunning then Exit;
  EnsureUnmounted(['flaky']);
  GFlakyFaultOn := True;
  FHost.Mount(TFlakyPlugin.Create);
  RefreshList;
  Log('[演示②] flaky 在 Apply 里抛异常：被隔离为 FAILED（见状态列与失败事件），其余插件不受任何影响。');
end;

procedure TShowroomForm.FlakyHealClick(Sender: TObject);
var
  LWasMounted: Boolean;
begin
  if FScenarioRunning then Exit;
  GFlakyFaultOn := False;
  LWasMounted := FHost.Root.Reload('flaky');
  if not LWasMounted then
  begin
    FHost.Mount(TFlakyPlugin.Create);
    Log('[演示②] flaky 此前未挂载，这次直接挂载。');
  end;
  RefreshList;
  Log('[演示②] 故障开关关闭后 Reload(flaky)：同一个 Apply 重跑成功，回到 ACTIVE —— 单插件热修复。');
end;

procedure TShowroomForm.UnloadProviderClick(Sender: TObject);
begin
  if FScenarioRunning then Exit;
  if FHost.PluginState('json-config') <> fsActive then
  begin
    Log('[提示] config 尚未激活（先跑一次「乱序挂载」或点「重新提供 config」）。');
    Exit;
  end;
  Log('[演示③] 卸载 config 提供者：其 fiber 注销 IOasisConfig ……');
  FHost.Root.Unload('json-config');
  RefreshList;
  Delayed(1100,
    procedure
    begin
      RefreshList;
      Log('[演示③] 宿主把注入它的 appcfg 停用；appcfg 注销自己的 IAppConfig 又停用了 greeter —— 两跳级联，二者都已自动排队等待复活。');
    end);
end;

procedure TShowroomForm.ProvideAgainClick(Sender: TObject);
begin
  if FScenarioRunning then Exit;
  EnsureUnmounted(['json-config']);              { avoid duplicate entries }
  FHost.Mount(TJsonConfigPlugin.Create(ConfigPath));
  RefreshList;
  Log('[演示③] 服务重新注册 → RescanPending：appcfg 复活，随之恢复的 IAppConfig 让 greeter 也自动归位。');
end;

procedure TShowroomForm.GateClick(Sender: TObject);
var
  LOk: Boolean;
begin
  if FScenarioRunning then Exit;
  FGateOn := not FGateOn;
  EnsureUnmounted(['preview']);
  RemountConfigProvider(FGateOn);
  LOk := FHost.TryMount(TPreviewPlugin.Create);
  if LOk then
    Log('[演示④] disabled=false：TryMount 放行，preview 已激活（typed 值输出见监视器）。')
  else
    Log('[演示④] disabled=true：TryMount 返回 False —— cordis.yml 的门控语义在 JSON 上复刻。');
  RefreshList;
end;

procedure TShowroomForm.RemountConfigProvider(ADisabledPreview: Boolean);
begin
  FHost.Root.Unload('json-config');
  WriteGateJson(ADisabledPreview);
  FHost.Mount(TJsonConfigPlugin.Create(ConfigPath));
end;

function TShowroomForm.NewSession: IContext;
var
  LSid: string;
begin
  Inc(FSessionSeq);
  LSid := IntToStr(FSessionSeq);
  Result := FHost.Root.Fork('session-' + LSid);
  MountSessionCore(Result, LSid);
  FSessions.Add(Result);
  FSessionNames.Add(LSid);
  RefreshTree;
end;

procedure TShowroomForm.DropSession(AIndex: Integer);
var
  LCtx: IContext;
  LSid: string;
begin
  if (AIndex < 0) or (AIndex >= FSessions.Count) then Exit;
  LCtx := FSessions[AIndex];
  LSid := FSessionNames[AIndex];
  FSessions.Delete(AIndex);
  FSessionNames.Delete(AIndex);
  try
    LCtx.Dispose;
  except
    on E: Exception do
      Log('[树] 会话销毁期间产生聚合错误：' + E.Message);
  end;
  Log(Format('[演示⑤] 会话 session-%s 已级联销毁：遮蔽徽章随子上下文消失，父上的 GLOBAL-BADGE 不受影响。',
    [LSid]));
  RefreshTree;
end;

procedure TShowroomForm.AddSessionClick(Sender: TObject);
var
  LFork: IContext;
  LGlobal, LForkBadge: string;
begin
  if FScenarioRunning then Exit;
  LFork := NewSession;
  if BadgeOf(LFork, LForkBadge) then
    LForkBadge := 'fork 内=' + LForkBadge
  else
    LForkBadge := '(fork 无)';
  if BadgeOf(FHost.Root, LGlobal) then
    LGlobal := 'root 上=' + LGlobal
  else
    LGlobal := '(root 无)';
  Log(Format('[演示⑤] 新建会话并遮蔽同名服务：%s ；%s （两层各自解析正确）',
    [LForkBadge, LGlobal]));
end;

procedure TShowroomForm.DisposeSessionClick(Sender: TObject);
var
  LIdx: Integer;
begin
  if FScenarioRunning then Exit;
  if (FTree.Selected = nil) or (FTree.Selected.Parent = nil) or
     (FTree.Selected.Data = nil) then
  begin
    Log('[提示] 请先在「作用域树」页选中某个 session 节点。');
    Exit;
  end;
  LIdx := Integer(NativeInt(FTree.Selected.Data)) - 1;
  DropSession(LIdx);
end;

procedure TShowroomForm.JobClick(Sender: TObject);
var
  LJob: TJobThread;
begin
  if not FJobBtn.Enabled then Exit;
  FJobBtn.Enabled := False;
  FJobDoneFlag := False;
  FProgressTicks := 0;
  FProgress.Position := 0;
  LJob := TJobThread.Create(FHost.Root);
  LJob.OnTerminate := ThreadDone;
  Log('[演示⑥] 工作线程启动：它在后台线程直接 Emit —— 监听器因此跑在工作线程上，触碰 UI 只能通过 IUIInvoker 封送回来。');
end;

procedure TShowroomForm.ThreadDone(Sender: TObject);
begin
  FJobDoneFlag := True;
  FJobBtn.Enabled := True;
end;

{ ---------------------------------------------------------------- playground }

procedure TShowroomForm.PlayEmitClick(Sender: TObject);
begin
  FEmitCount := 0;
  FHost.Root.Events.Emit('play/emit', ['x']);
  FPlayOut.Lines.Clear;
  FPlayOut.Lines.Add(Format(
    'Emit 广播：三个监听器按注册顺序全部执行（本次共触发 %d 次）。无短路、无返回值；单个监听器异常会被聚合而不是中断广播。',
    [FEmitCount]));
end;

procedure TShowroomForm.PlayBailClick(Sender: TObject);
var
  LR: TValue;
begin
  FBailCalled[0] := 0; FBailCalled[1] := 0; FBailCalled[2] := 0; FBailCalled[3] := 0;
  LR := FHost.Root.Events.Bail('play/bail', ['q']);
  FPlayOut.Lines.Clear;
  FPlayOut.Lines.Add(Format(
    'Bail 首真胜出：四个监听器返回 (#1假,#2假,#3真,#4守卫)。实际调用次数 = [%d, %d, %d, %d]',
    [FBailCalled[0], FBailCalled[1], FBailCalled[2], FBailCalled[3]]));
  if LR.IsEmpty then
    FPlayOut.Lines.Add('链在首个真值处停止；返回值 = <empty>')
  else
    FPlayOut.Lines.Add('链在 #3 处停止 —— #4 从未执行；返回值 = ' + LR.AsString);
end;

procedure TShowroomForm.PlayWfVetoClick(Sender: TObject);
var
  LReachedEnd: Boolean;
begin
  FWfMidCalled[0] := 0; FWfMidCalled[1] := 0; FWfMidCalled[2] := 0;
  LReachedEnd := FHost.Root.Events.Waterfall('play/wf', ['veto-demo']);
  FPlayOut.Lines.Clear;
  FPlayOut.Lines.Add(Format(
    'Waterfall 否决：中间件 #2 拒绝调用 Next。到达链尾 = %s；调用次数 = [%d, %d, %d]',
    [BoolText(LReachedEnd), FWfMidCalled[0], FWfMidCalled[1], FWfMidCalled[2]]));
  FPlayOut.Lines.Add('#2 一票否决后整个管道短路 —— 权限校验/参数拦截的天然形态。');
end;

procedure TShowroomForm.PlayWfPassClick(Sender: TObject);
var
  LReachedEnd: Boolean;
begin
  FWfPassCalled := 0;
  LReachedEnd := FHost.Root.Events.Waterfall('play/wf2', ['pass-through']);
  FPlayOut.Lines.Clear;
  FPlayOut.Lines.Add(Format(
    'Waterfall 全放行：唯一的中间件调用了 Next。到达链尾 = %s；调用次数 = %d',
    [BoolText(LReachedEnd), FWfPassCalled]));
  FPlayOut.Lines.Add('与上一个按钮对照：Next 决定链路继续与否 —— around 中间件语义与 Node/Koa 一致。');
end;

{ ------------------------------------------------------------------ selftest }

function TShowroomForm.Check(AName: string; ACond: Boolean): Boolean;
begin
  Result := ACond;
  if Result then
    FSelReport.Add(Format('%-52s PASS', [AName]))
  else
  begin
    FSelReport.Add(Format('%-52s FAIL', [AName]));
    Inc(GSelfTestFailures);
  end;
end;

procedure TShowroomForm.RunSelfTest(const APath: string);
var
  LFlakyOk: Boolean;
  LFailedNames: TArray<string>;
  LI: Integer;
  LOk, LWfEnd: Boolean;
  LFork: IContext;
  LGBadge, LFBadge: string;
  LRes: TValue;
  LDeadline: Cardinal;
  LJob: TJobThread;
begin
  GSelfTestFailures := 0;
  FSelReport := TStringList.Create;
  try
    FSelReport.Add('Oasis Showroom selftest');
    FSelReport.Add('');

    SetupHost(True);

    Check('baseline: ui-invoker ACTIVE',
      FHost.PluginState('ui-invoker') = fsActive);
    Check('baseline: json-config ACTIVE',
      FHost.PluginState('json-config') = fsActive);

    { ---- S1: mount-order independence ---- }
    EnsureUnmounted(SCENARIO_NAMES);
    FHelloHits := 0;
    FHost.Mount(TGreeterPlugin.Create);
    Check('S1: greeter before deps => fsPending',
      FHost.PluginState('greeter') = fsPending);
    FHost.Mount(TAppCfgPlugin.Create);
    Check('S1: appcfg before its dep => fsPending',
      FHost.PluginState('appcfg') = fsPending);
    FHost.Mount(TJsonConfigPlugin.Create(ConfigPath));
    Check('S1: after config arrives greeter ACTIVE',
      FHost.PluginState('greeter') = fsActive);
    Check('S1: adapter appcfg ACTIVE too',
      FHost.PluginState('appcfg') = fsActive);
    Check('S1: greet/hello fired on activation (hits=' + IntToStr(FHelloHits) +
      ')', FHelloHits >= 1);

    { ---- S2: failure isolation + Reload heal ---- }
    GFlakyFaultOn := True;
    EnsureUnmounted(['flaky']);
    FHost.Mount(TFlakyPlugin.Create);
    Check('S2: flaky Apply raised => fsFailed',
      FHost.PluginState('flaky') = fsFailed);
    Check('S2: failure did not disturb greeter',
      FHost.PluginState('greeter') = fsActive);
    LFailedNames := FHost.FailedPlugins;
    LFlakyOk := False;
    for LI := 0 to Length(LFailedNames) - 1 do
      if SameText(LFailedNames[LI], 'flaky') then LFlakyOk := True;
    Check('S2: FailedPlugins records flaky', LFlakyOk);

    GFlakyFaultOn := False;
    LOk := FHost.Root.Reload('flaky');
    Check('S2: Reload(flaky) returns True', LOk);
    Check('S2: healed flaky is fsActive',
      FHost.PluginState('flaky') = fsActive);

    { ---- S3: two-hop dependency cascade ---- }
    FHost.Root.Unload('json-config');
    Check('S3: provider unload -> appcfg PENDING',
      FHost.PluginState('appcfg') = fsPending);
    Check('S3: greeter (two hops away) also PENDING',
      FHost.PluginState('greeter') = fsPending);
    Check('S3: unrelated flaky untouched',
      FHost.PluginState('flaky') = fsActive);
    FHost.Mount(TJsonConfigPlugin.Create(ConfigPath));
    Check('S3: re-provided => appcfg ACTIVE again',
      FHost.PluginState('appcfg') = fsActive);
    Check('S3: re-provided => greeter ACTIVE again',
      FHost.PluginState('greeter') = fsActive);

    { ---- S4: config gating ---- }
    EnsureUnmounted(['preview']);
    RemountConfigProvider(True);
    Check('S4: disabled=true => TryMount blocked',
      not FHost.TryMount(TPreviewPlugin.Create));
    Check('S4: blocked preview NOT queued (fsDisposed)',
      FHost.PluginState('preview') = fsDisposed);
    RemountConfigProvider(False);
    Check('S4: disabled=false => TryMount mounts',
      FHost.TryMount(TPreviewPlugin.Create));
    Check('S4: preview ACTIVE with typed readers',
      FHost.PluginState('preview') = fsActive);

    { ---- S5: fork scope tree ---- }
    FSessionHits := 0;
    LFork := NewSession;
    Check('S5: session start bubbled to ROOT listener once', FSessionHits = 1);
    Check('S5: fork shadows ISessionBadge',
      BadgeOf(LFork, LFBadge) and (LFBadge = 'BADGE#' + FSessionNames[FSessionNames.Count - 1]));
    Check('S5: root still resolves GLOBAL-BADGE',
      BadgeOf(FHost.Root, LGBadge) and (LGBadge = 'GLOBAL-BADGE'));
    DropSession(FSessions.Count - 1);
    Check('S5: after dispose root badge intact',
      BadgeOf(FHost.Root, LGBadge) and (LGBadge = 'GLOBAL-BADGE'));

    { ---- S6: dispatch semantics ---- }
    FBailCalled[0] := 0; FBailCalled[1] := 0; FBailCalled[2] := 0; FBailCalled[3] := 0;
    LRes := FHost.Root.Events.Bail('play/bail', ['q']);
    Check('S6: bail stops after truthy (calls 1,1,1,0)',
      (FBailCalled[0] = 1) and (FBailCalled[1] = 1) and
      (FBailCalled[2] = 1) and (FBailCalled[3] = 0));
    Check('S6: bail returns winning value', LRes.AsString = 'answer #3');

    FWfMidCalled[0] := 0; FWfMidCalled[1] := 0; FWfMidCalled[2] := 0;
    LWfEnd := FHost.Root.Events.Waterfall('play/wf', ['veto']);
    Check('S6: waterfall veto => not reached end', not LWfEnd);
    Check('S6: veto cuts the tail (0,1,0) got=[' +
      IntToStr(FWfMidCalled[0]) + ',' + IntToStr(FWfMidCalled[1]) + ',' +
      IntToStr(FWfMidCalled[2]) + ']',
      (FWfMidCalled[0] = 1) and (FWfMidCalled[1] = 1) and (FWfMidCalled[2] = 0));

    FWfPassCalled := 0;
    LWfEnd := FHost.Root.Events.Waterfall('play/wf2', ['pass']);
    Check('S6: pass-through reaches end', LWfEnd and (FWfPassCalled = 1));

    { ---- S7: worker thread + marshaled progress ---- }
    FProgressTicks := 0;
    FJobDoneFlag := False;
    FQuiet := False;
    LJob := TJobThread.Create(FHost.Root);
    LJob.OnTerminate := ThreadDone;
    LDeadline := GetTickCount + 6000;
    while (not FJobDoneFlag) and (GetTickCount < LDeadline) do
    begin
      Sleep(40);
      CheckSynchronize;
    end;
    Check('S7: background job completed', FJobDoneFlag);
    Check('S7: 5 progress updates marshaled to main thread', FProgressTicks >= 5);

    FSelReport.Add('');
    if GSelfTestFailures = 0 then
      FSelReport.Add('SHOWROOM SELFTEST: OK')
    else
      FSelReport.Add('SHOWROOM SELFTEST: FAILED (' + IntToStr(GSelfTestFailures) +
        ' failures)');
  finally
    FQuiet := False;
    if FSelReport <> nil then
    try
      TFile.WriteAllLines(APath, FSelReport.ToStringArray, TEncoding.UTF8);
    except
      ;   { never mask the exit code with an IO problem }
    end;
    FreeAndNil(FSelReport);
  end;
end;

end.
