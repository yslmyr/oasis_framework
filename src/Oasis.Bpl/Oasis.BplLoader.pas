unit Oasis.BplLoader;

{ Oasis framework - phase 3: BPL plugin loader. Implements IPluginLoader
  (Kind = 'bpl') with the same contract as TInProcPluginLoader, so the Host and
  Context are unchanged: Host.Mount('bpl:<path>') routes here. Load() loads the
  package (and its required runtime packages), resolves the exported
  OasisCreatePlugin entry, and returns a factory that constructs the IPlugin.
  Unload() unloads the package. }

interface

uses
  System.SysUtils, System.SyncObjs, System.Generics.Collections,
  System.Classes,
  Oasis.Types, Oasis.Errors, Oasis.Context, Oasis.Loader, Oasis.BplContract;

type
  TBplPluginLoader = class(TInterfacedObject, IPluginLoader)
  strict private type
    TBplEntry = record
      Factory: TPluginFactory;
      Handle: NativeUInt;
    end;
  strict private
    FLock: TCriticalSection;
    FEntries: TList<TBplEntry>;
  public
    constructor Create;
    destructor Destroy; override;
    function  Kind: string;
    function  Load(const ASource: string): TPluginFactory;
    procedure Unload(const AFactory: TPluginFactory);
  end;

implementation

{ TBplPluginLoader }

constructor TBplPluginLoader.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FEntries := TList<TBplEntry>.Create;
end;

destructor TBplPluginLoader.Destroy;
begin
  { Release factory closures (and the factory objects they hold) while the BPLs
    are still loaded. We deliberately do NOT UnloadPackage here: runtime BPL
    unloading is fragile (plugin/factory objects may still reference BPL code
    via their destructors) and BPLs are reclaimed at process exit. Call
    Unload(factory) explicitly for a deliberate unload. }
  FEntries.Clear;
  FEntries.Free;
  FLock.Free;
  inherited Destroy;
end;

function TBplPluginLoader.Kind: string;
begin
  Result := 'bpl';
end;

function TBplPluginLoader.Load(const ASource: string): TPluginFactory;
var
  LPath, LFactoryName: string;
  LSemi: Integer;
  LHandle: NativeUInt;
  LClass: TPersistentClass;
  LObj: TObject;
  LFact: IOasisPluginFactory;
  LEntry: TBplEntry;
begin
  { source grammar: '<path-to-bpl>' or '<path>;factory=<ClassName>' - see the
    multi-BPL protocol note in Oasis.BplContract. ';' is not a legal path char
    on Windows, so the split is unambiguous. }
  LSemi := Pos(';', ASource);
  if LSemi > 0 then
  begin
    LPath := Copy(ASource, 1, LSemi - 1);
    LFactoryName := Copy(ASource, LSemi + 1, MaxInt);
    if not LFactoryName.StartsWith('factory=', True) then
      raise EOasisLoaderError.CreateFmt(
        'Malformed BPL source "%s" (only ";factory=<ClassName>" is supported after ";")',
        [ASource]);
    Delete(LFactoryName, 1, Length('factory='));
  end
  else
  begin
    LPath := ASource;
    LFactoryName := OASIS_BPL_FACTORY_CLASS;
  end;
  LHandle := LoadPackage(LPath);   { runs the BPL initialization, which
    registers the factory into the shared (rtl.bpl) class list }
  try
    LClass := FindClass(LFactoryName);
  except
    on E: EClassNotFound do
    begin
      UnloadPackage(LHandle);
      raise EOasisLoaderError.CreateFmt('BPL "%s" does not register factory "%s"',
        [LPath, LFactoryName]);
    end;
  end;
  LObj := LClass.Create;   { TInterfacedPersistent; once we hold it via the
    interface below, refcounting owns it }
  if not Supports(LObj, IOasisPluginFactory, LFact) then
  begin
    LObj.Free;
    UnloadPackage(LHandle);
    raise EOasisLoaderError.CreateFmt('BPL "%s" factory does not implement IOasisPluginFactory',
      [ASource]);
  end;
  LEntry.Handle := LHandle;
  LEntry.Factory := function: IPlugin
                    begin
                      Result := LFact.CreatePlugin;
                    end;
  FLock.Enter;
  try
    FEntries.Add(LEntry);
  finally
    FLock.Leave;
  end;
  Result := LEntry.Factory;
end;

procedure TBplPluginLoader.Unload(const AFactory: TPluginFactory);
var
  I: Integer;
  LHandle: NativeUInt;
  LFactory: TPluginFactory;
begin
  FLock.Enter;
  try
    for I := 0 to FEntries.Count - 1 do
    begin
      LFactory := FEntries[I].Factory;   // copy to local so '=' is not misparsed as a call
      if LFactory = AFactory then
      begin
        LHandle := FEntries[I].Handle;
        FEntries.Delete(I);
        try
          UnloadPackage(LHandle);
        except
        end;
        Exit;
      end;
    end;
  finally
    FLock.Leave;
  end;
end;

end.
