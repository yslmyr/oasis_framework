unit SuiteContract;

(* Shared contract of the BPL Suite demo (demos/BplSuiteDemo), modeled after
  the Interfaces/ folder of Tangram's AdvancedDemo: ONE unit every side
  compiles from source - the host EXE and each BPL module. Interface identity
  is by GUID + vtable (identical source on both sides), so no package has to
  be shared beyond rtl/vcl.

  Roles:
    IShellHost   - implemented by the HOST main form (Tangram's IMainForm):
                   tab docking + status bar + event log.
    ISuiteView   - implemented by any UI module: contributes one tab.
    ISuiteSettings / ISuiteClock - provided by the SuiteCore BPL; consumed by
                   the UI modules through [Inject] fields (Oasis DI).
    ISuiteOrders - provided by the SuiteOrders BPL as a TRANSIENT factory:
                   every resolve builds a new instance (visible in the UI).
    ISuiteDashboardState - read-model the selftest uses to look INSIDE the
                   dashboard tab without linking its BPL. *)

interface

uses
  Vcl.Controls;

const
  { plain event-bus channel Core emits when the settings prefix changes;
    UI modules subscribe with Ctx.Events.On (fiber-owned listener) }
  EV_SUITE_SETTINGS_CHANGED = 'suite.settings.changed';

type
  ISuiteView = interface
    ['{9D5E1B20-4C7A-4B18-9E2F-B01A6C3D4E01}']
    function Caption: string;
    { Create the module's UI under AParent; result's Parent must be AParent. }
    function CreateView(AParent: TWinControl): TWinControl;
  end;

  IShellHost = interface
    ['{9D5E1B20-4C7A-4B18-9E2F-B01A6C3D4E02}']
    procedure AddView(AView: ISuiteView);
    procedure RemoveView(AView: ISuiteView);
    procedure ShowStatus(const AMsg: string);
    procedure Log(const AMsg: string);
  end;

  ISuiteSettings = interface
    ['{9D5E1B20-4C7A-4B18-9E2F-B01A6C3D4E03}']
    function Prefix: string;
    procedure SetPrefix(const AValue: string);
  end;

  ISuiteClock = interface
    ['{9D5E1B20-4C7A-4B18-9E2F-B01A6C3D4E04}']
    function NowText: string;
  end;

  ISuiteOrders = interface
    ['{9D5E1B20-4C7A-4B18-9E2F-B01A6C3D4E05}']
    { Instance-identity probe: '<prefix>-<seq> (obj <addr>)'. A transient
      registration yields a NEW addr (and a growing seq) per resolve. }
    function Ticket: string;
  end;

  ISuiteDashboardState = interface
    ['{9D5E1B20-4C7A-4B18-9E2F-B01A6C3D4E06}']
    function ClockText: string;
    function PrefixText: string;
  end;

implementation

end.
