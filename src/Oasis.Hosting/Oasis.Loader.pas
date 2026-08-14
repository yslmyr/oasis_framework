unit Oasis.Loader;

{ Oasis framework - plugin loader abstraction. The MVP ships an in-process loader
  (plugins are classes compiled into the host). Phase 3 adds a BPL loader with the
  same contract. }

interface

uses
  System.SysUtils, System.Generics.Collections,
  Oasis.Types, Oasis.Errors, Oasis.Context;

type
  TPluginFactory = reference to function: IPlugin;

  IPluginLoader = interface
    ['{F6A7B8C9-D0E1-4F2A-3B4C-5D6E7F809102}']
    function  Kind: string;
    function  Load(const ASource: string): TPluginFactory;
    procedure Unload(const AFactory: TPluginFactory);
  end;

  { In-process loader: plugin classes registered at startup. }
  TInProcPluginLoader = class(TInterfacedObject, IPluginLoader)
  strict private
    FMap: TDictionary<string, TInterfacedClass>;
  public
    constructor Create;
    destructor Destroy; override;
    function  Kind: string;
    procedure Register(const AName: string; AClass: TInterfacedClass);
    function  Load(const ASource: string): TPluginFactory;
    procedure Unload(const AFactory: TPluginFactory);
  end;

implementation

{ TInProcPluginLoader }

constructor TInProcPluginLoader.Create;
begin
  inherited Create;
  FMap := TDictionary<string, TInterfacedClass>.Create;
end;

destructor TInProcPluginLoader.Destroy;
begin
  FMap.Free;
  inherited Destroy;
end;

function TInProcPluginLoader.Kind: string;
begin
  Result := 'inproc';
end;

procedure TInProcPluginLoader.Register(const AName: string; AClass: TInterfacedClass);
begin
  FMap.AddOrSetValue(AName, AClass);
end;

function TInProcPluginLoader.Load(const ASource: string): TPluginFactory;
var
  LClass: TInterfacedClass;
begin
  if not FMap.TryGetValue(ASource, LClass) then
    raise EOasisLoaderError.CreateFmt('Unknown in-proc plugin: %s', [ASource]);
  Result := function: IPlugin
           begin
             Result := LClass.Create as IPlugin;
           end;
end;

procedure TInProcPluginLoader.Unload(const AFactory: TPluginFactory);
begin
  { nothing to release for compiled-in classes }
end;

end.
