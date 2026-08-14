unit VclPluginContract;

(* Shared contract between the VCL host demo (demos/VclHostDemo) and the BPL
  plugin (samples/VclBplPlugin). Compiled into both sides - interface identity
  is by GUID + vtable (same source), exactly like the console SampleContract
  pattern of phase 3.

  Pattern: the HOST registers an IViewHost service. UI plugins receive it in
  Apply, call Add(SelfView), and register Remove via Ctx.Effects.AddCleanup -
  so when the plugin unloads (manually, via reload, or by dependency cascade)
  its tab disappears automatically. The reversible-effect idiom applied to UI. *)

interface

uses
  System.Classes, Vcl.Controls,
  Oasis.Context;

type
  { Implemented by a plugin that contributes UI. }
  IPluginView = interface
    ['{BBBBBBBB-0000-0000-0000-00000000000B}']
    function Caption: string;
    { Create the plugin's UI under AParent; result's Parent must be AParent. }
    function CreateView(AParent: TWinControl): TWinControl;
  end;

  { Implemented by the host; plugins use it from Apply (main thread). }
  IViewHost = interface
    ['{CCCCCCCC-0000-0000-0000-00000000000C}']
    procedure Add(AView: IPluginView);
    procedure Remove(AView: IPluginView);
  end;

  { Sample service showing dependency cascade in the UI: provided by the
    Settings plugin, injected by the Greet plugin. Removing Settings
    deactivates Greet (its tab vanishes); re-adding re-activates it. }
  IAppSettings = interface
    ['{DDDDDDDD-0000-0000-0000-00000000000D}']
    function GetPrefix: string;
    procedure SetPrefix(const AValue: string);
  end;

implementation

end.
