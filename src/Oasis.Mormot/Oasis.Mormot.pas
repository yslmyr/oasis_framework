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
  reverse bridge assigns via IInterface(Obj) := ... The two styles are
  deliberately different - never share a conversion helper between them. }

interface

uses
  System.SysUtils,
  Oasis.Types, Oasis.Errors, Oasis.Services, Oasis.Context, Oasis.Plugin,
  mormot.core.base, mormot.core.rtti, mormot.core.interfaces;

type
  { Mirrors a mORMot resolver's interfaces into the Oasis registry as LAZY
    factories (resolve pierces through to mORMot; sic* lifetimes stay owned
    by the mORMot container - a shared instance stays shared, a transient
    class registration yields a fresh instance per resolve). Unmounting the
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

end.
