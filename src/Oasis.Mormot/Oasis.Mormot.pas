unit Oasis.Mormot;

{ Oasis framework - mORMot2 DI bridge (OPTIONAL unit; static-link only, no
  .dpk - mORMot has unit-level global state that must not be duplicated
  across a BPL boundary).

  LICENSE BOUNDARY: this unit is original Oasis (MIT) code and only *uses*
  mORMot2 units - ZERO mORMot2 code is copied into this repository. mORMot2
  is MPL 1.1; binary redistribution including it carries the MPL terms for
  the mORMot2 parts, borne by the distributor. Project red line: borrow
  ideas, never copy MPL code into MIT Oasis.

  Refcount rule (spec 5.2/N1): mORMot Resolve hands out ONE _AddRef which the
  caller owns. The forward closure RECEIVES it into an IInterface local and
  returns it VERBATIM (no intermediate pointer/interface conversions). The
  reverse bridge must CONVERT to the requested interface entry (the Oasis
  registry hands out a bare IInterface): it passes the GUID through
  QueryInterface, which grants the caller that same single _AddRef. The two
  styles are deliberately different - never share a conversion helper
  between them. }

interface

uses
  System.SysUtils,
  Oasis.Types, Oasis.Errors, Oasis.Services, Oasis.Context, Oasis.Plugin,
  mormot.core.base, mormot.core.rtti, mormot.core.interfaces;

type
  { Mirrors a mORMot resolver's interfaces into the Oasis registry as
    per-resolve factories (every resolve pierces through to mORMot; sic*
    lifetimes stay owned by the mORMot container - a shared instance stays
    shared, a transient class registration yields a fresh instance per
    resolve; a lazy-singleton memo would wrongly freeze that). Unmounting the
    bridge cascades to Oasis consumers. AInterfaces are TypeInfo(Ixxx)
    values - compile-time checked. }
  TMormotServicesPlugin = class(TOasisPlugin)
  strict private
    FResolver: TInterfaceResolver;
    FOwnsResolver: Boolean;
    FInterfaces: TArray<PRttiInfo>;
  public
    constructor Create(AResolver: TInterfaceResolver;
      const AInterfaces: array of PRttiInfo;
      AOwnsResolver: Boolean = False);
    destructor Destroy; override;
    procedure Apply(const Ctx: IContext); override;
  end;

  { Reverse bridge: expose the Oasis registry as a mORMot TInterfaceResolver,
    so mORMot-side DI graphs (TInjectableObject published properties,
    TInterfaceResolverInjected.InjectResolver composition) can consume
    Oasis fiber-registered services. }
  TOasisResolver = class(TInterfaceResolver)
  strict private
    FRegistry: IServiceRegistry;
  public
    constructor Create(const ARegistry: IServiceRegistry);
    function TryResolve(aInterface: PRttiInfo; out Obj): Boolean; override;
    function Implements(aInterface: PRttiInfo): Boolean; override;
  end;

implementation

{ TMormotServicesPlugin }

constructor TMormotServicesPlugin.Create(AResolver: TInterfaceResolver;
  const AInterfaces: array of PRttiInfo; AOwnsResolver: Boolean);
var
  I: Integer;
begin
  inherited Create('mormot-services');
  FResolver := AResolver;
  FOwnsResolver := AOwnsResolver;
  SetLength(FInterfaces, Length(AInterfaces));
  for I := 0 to Length(AInterfaces) - 1 do
    FInterfaces[I] := AInterfaces[I];
end;

destructor TMormotServicesPlugin.Destroy;
begin
  if FOwnsResolver then
    FResolver.Free;
  FResolver := nil;
  inherited Destroy;
end;

procedure TMormotServicesPlugin.Apply(const Ctx: IContext);

  procedure RegisterOne(const AGuid: TGUID; AInfo: PRttiInfo);
  var
    LResolver: TInterfaceResolver;   { object capture - never an interface (cycle) }
  begin
    LResolver := FResolver;
    { RegisterTransient (not RegisterFactory) so the mirror PRESERVES the
      mORMot-side lifetime (spec 7.2/2: class registration = new instance per
      resolve). RegisterFactory's lazy-singleton memo would freeze the first
      pierce result and silently turn mORMot class registrations into Oasis
      singletons. Shared instances stay shared: mORMot Resolve keeps handing
      out the same instance (+1 per resolve - balanced under the N1 rule). }
    Ctx.Services.RegisterTransient(AGuid,
      function: IInterface
      var
        LInst: IInterface;
      begin
        { receive-and-return: Resolve's single _AddRef transfers to LInst,
          then verbatim to the caller (spec 5.2/N1). }
        if not LResolver.Resolve(AInfo, LInst) then
          raise EOasisServiceFactoryError.CreateFmt(
            'mORMot resolver failed for %s', [GUIDToString(AGuid)]);
        Result := LInst;
      end);
  end;

var
  I: Integer;
begin
  { nested RegisterOne: value parameters give each closure its own AGuid/AInfo
    (Delphi anonymous methods capture by reference - loop vars would be shared).
    GUID via mormot's own TRttiInfo.InterfaceGuid (PRttiInfo lives in
    mormot.core.rtti - Delphi uses are non-transitive). }
  for I := 0 to Length(FInterfaces) - 1 do
    RegisterOne(FInterfaces[I]^.InterfaceGuid^, FInterfaces[I]);
end;

{ TOasisResolver }

constructor TOasisResolver.Create(const ARegistry: IServiceRegistry);
begin
  inherited Create;
  FRegistry := ARegistry;
end;

function TOasisResolver.TryResolve(aInterface: PRttiInfo; out Obj): Boolean;
var
  LInst: IInterface;
begin
  { Reverse of the forward closure above: pull ONE instance out of the Oasis
    registry (GUID via mormot's TRttiInfo extension, like Apply) and CONVERT
    it to the REQUESTED interface entry before handing it out. The registry
    stores a bare IInterface, but mORMot callers index the returned pointer
    with the target interface's vtable - a raw IInterface(Obj) := copy hands
    them the wrong entry (AV on first method call). mORMot's own
    TInterfaceResolverList only copies raw because Add() pre-converts its
    instances via GetInterfaceFromEntry; its fDependencies path converts via
    GetInterface(guid, Obj) - QueryInterface passthrough is the IInterface-
    side equivalent, and it grants the caller the single _AddRef (S_OK = 0,
    spec 5.2/N1); LInst's own take is released at scope exit. }
  Result := FRegistry.Resolve(aInterface^.InterfaceGuid^, LInst);
  if Result then
    Result := LInst.QueryInterface(aInterface^.InterfaceGuid^, Obj) = 0;
end;

function TOasisResolver.Implements(aInterface: PRttiInfo): Boolean;
begin
  { Has never triggers a factory build - cheap probe, mirrors registry semantics. }
  Result := FRegistry.Has(aInterface^.InterfaceGuid^);
end;

end.
