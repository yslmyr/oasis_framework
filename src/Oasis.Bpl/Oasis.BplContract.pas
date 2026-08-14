unit Oasis.BplContract;

{ Oasis framework - phase 3: the contract a BPL plugin package must satisfy.

  Delphi packages do not support an `exports` clause, so a BPL cannot export a
  free function. Instead the package registers a factory OBJECT under a
  conventional alias (OASIS_BPL_FACTORY_CLASS) via RegisterClassAlias in its
  initialization section. This works across the host/BPL boundary because both
  share the Delphi RTL runtime package (rtl.bpl), whose global class list is
  therefore shared.

  The factory is a TInterfacedPersistent (RegisterClass-compatible, since it
  must descend from TPersistent) that implements IOasisPluginFactory. The host
  casts the located object to IOasisPluginFactory by GUID (interface identity is
  by GUID, so the host and BPL may each statically contain their own copy of
  this unit). }

interface

uses
  System.Classes,
  Oasis.Context;

const
  OASIS_BPL_FACTORY_CLASS = 'OasisPluginFactory';

type
  IOasisPluginFactory = interface
    ['{77777777-0000-0000-0000-000000000007}']
    function CreatePlugin: IPlugin;
  end;

  { Base factory a BPL registers under OASIS_BPL_FACTORY_CLASS. Subclass and
    override CreatePlugin. TInterfacedPersistent is TPersistent-derived
    (RegisterClass accepts it) and refcounted (the host holds it via the
    IOasisPluginFactory interface). }
  TOasisPluginFactory = class(TInterfacedPersistent, IOasisPluginFactory)
  public
    function CreatePlugin: IPlugin; virtual; abstract;
  end;

implementation

end.
