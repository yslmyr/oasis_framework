unit Oasis.Config;

{ Declarative configuration validation via RTTI attributes.

  A config class derives from TOasisConfig, declares its fields as published
  properties and annotates them with [OasisConfig(...)]:

    TServerConfig = class(TOasisConfig)
    strict private
      FPort: Integer;
    published
      [OasisConfig('TCP port to listen on', True, 1, 65535)]
      property Port: Integer read FPort write FPort;
    end;

  TOasisPlugin<TConfig> runs Validate before Apply; invalid configurations
  raise EOasisConfigError, which fails the fiber loudly (fsFailed) instead of
  running half-configured code. }

interface

uses
  System.SysUtils,
  System.Classes,
  System.Rtti,
  Oasis.Core;

type
  { Attribute for config fields.
    - ADescription: human-readable description (used in error messages)
    - ARequired: True when the value must be present (non-empty string, non-nil object)
    - AMin/AMax: inclusive bounds for numeric fields }
  OasisConfigAttribute = class(TCustomAttribute)
  strict private
    FDescription: string;
    FRequired: Boolean;
    FMin: Double;
    FMax: Double;
    FHasMin: Boolean;
    FHasMax: Boolean;
  public
    constructor Create(const ADescription: string = ''); overload;
    constructor Create(const ADescription: string; ARequired: Boolean); overload;
    constructor Create(const ADescription: string; ARequired: Boolean;
      AMin: Double; AMax: Double); overload;
    property Description: string read FDescription;
    property Required: Boolean read FRequired;
    property HasMin: Boolean read FHasMin;
    property HasMax: Boolean read FHasMax;
    property Min: Double read FMin;
    property Max: Double read FMax;
  end;

  { Base class for plugin configuration objects. Subclasses expose their fields
    as published properties annotated with OasisConfigAttribute. }
  {$M+}
  TOasisConfig = class
  public
    procedure Validate;
  end;
  {$M-}

implementation

function OasisTryNumeric(const V: TValue; out ANumber: Double): Boolean;
begin
  case V.Kind of
    tkInteger: begin ANumber := V.AsInteger; Exit(True); end;
    tkInt64:   begin ANumber := V.AsInt64;   Exit(True); end;
    tkFloat:   begin ANumber := V.AsExtended; Exit(True); end;
  else
    Result := False;
  end;
end;

{ OasisConfigAttribute }

constructor OasisConfigAttribute.Create(const ADescription: string);
begin
  inherited Create;
  FDescription := ADescription;
end;

constructor OasisConfigAttribute.Create(const ADescription: string; ARequired: Boolean);
begin
  Create(ADescription);
  FRequired := ARequired;
end;

constructor OasisConfigAttribute.Create(const ADescription: string; ARequired: Boolean;
  AMin: Double; AMax: Double);
begin
  Create(ADescription, ARequired);
  FHasMin := True;
  FHasMax := True;
  FMin := AMin;
  FMax := AMax;
end;

{ TOasisConfig }

procedure TOasisConfig.Validate;
var
  Rtti: TRttiContext;
  RttiType: TRttiType;
  Prop: TRttiProperty;
  Attr: TCustomAttribute;
  Spec: OasisConfigAttribute;
  Value: TValue;
  Number: Double;
  Errors: TStringList;
begin
  Errors := TStringList.Create;
  Rtti := TRttiContext.Create;
  try
    RttiType := Rtti.GetType(Self.ClassType);
    if RttiType = nil then
      Exit;
    for Prop in RttiType.GetProperties do
      for Attr in Prop.GetAttributes do
        if Attr is OasisConfigAttribute then
        begin
          Spec := OasisConfigAttribute(Attr);
          Value := Prop.GetValue(Self);
          if Spec.Required then
          begin
            if Value.IsEmpty or
               (Value.IsType<string> and (Value.AsString = '')) or
               (Value.IsObject and (Value.AsObject = nil)) then
              Errors.Add(Format('config field "%s": value is required (%s)',
                [Prop.Name, Spec.Description]));
          end;
          if (not Value.IsEmpty) and (Spec.HasMin or Spec.HasMax) and
             OasisTryNumeric(Value, Number) then
          begin
            if Spec.HasMin and (Number < Spec.Min) then
              Errors.Add(Format('config field "%s": %s is below the minimum of %s (%s)',
                [Prop.Name, FloatToStr(Number), FloatToStr(Spec.Min), Spec.Description]));
            if Spec.HasMax and (Number > Spec.Max) then
              Errors.Add(Format('config field "%s": %s is above the maximum of %s (%s)',
                [Prop.Name, FloatToStr(Number), FloatToStr(Spec.Max), Spec.Description]));
          end;
        end;
    if Errors.Count > 0 then
      raise EOasisConfigError.Create(Format('%s config is invalid:'#13#10'%s',
        [Self.ClassName, Errors.Text]));
  finally
    Rtti.Free;
    Errors.Free;
  end;
end;

end.
