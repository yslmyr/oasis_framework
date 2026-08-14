unit SampleContract;

{ Sample BPL plugin contract: the IGreeting service interface. Compiled into
  BOTH the BPL plugin (which registers it) and the host demo (which resolves
  it), so the GUID is identical on both sides. }

interface

type
  IGreeting = interface
    ['{66666666-0000-0000-0000-000000000006}']
    function Greet(const AWho: string): string;
  end;

implementation

end.
