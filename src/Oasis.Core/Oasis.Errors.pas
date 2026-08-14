unit Oasis.Errors;

{ Oasis framework - exception hierarchy. Aggregated failures store message
  strings (not Exception objects) to avoid object-lifetime headaches. }

interface

uses
  System.SysUtils;

type
  EOasisError = class(Exception);

  EOasisServiceNotFound = class(EOasisError);

  EOasisDependencyCycle = class(EOasisError)
  strict private
    FCyclePath: string;
  public
    constructor Create(const AMessage, ACyclePath: string);
    property CyclePath: string read FCyclePath;
  end;

  EOasisPluginActivateError = class(EOasisError)
  strict private
    FPluginName: string;
  public
    constructor Create(const APluginName, AInnerMessage: string);
    property PluginName: string read FPluginName;
  end;

  { Base for aggregated multi-failure errors (dispose / event dispatch). }
  EOasisAggregateError = class abstract (EOasisError)
  strict private
    FMessages: TArray<string>;
  protected
    constructor Create(const AIntro: string; const AMessages: TArray<string>);
  public
    property Messages: TArray<string> read FMessages;
  end;

  EOasisDisposeError = class(EOasisAggregateError)
  public
    constructor Create(const AMessages: TArray<string>);
  end;

  EOasisEventError = class(EOasisAggregateError)
  public
    constructor Create(const AMessages: TArray<string>);
  end;

  EOasisLoaderError = class(EOasisError);

implementation

{ EOasisDependencyCycle }

constructor EOasisDependencyCycle.Create(const AMessage, ACyclePath: string);
begin
  inherited Create(AMessage);
  FCyclePath := ACyclePath;
end;

{ EOasisPluginActivateError }

constructor EOasisPluginActivateError.Create(const APluginName, AInnerMessage: string);
begin
  if AInnerMessage <> '' then
    inherited CreateFmt('Plugin "%s" failed to activate: %s', [APluginName, AInnerMessage])
  else
    inherited CreateFmt('Plugin "%s" failed to activate', [APluginName]);
  FPluginName := APluginName;
end;

{ EOasisAggregateError }

constructor EOasisAggregateError.Create(const AIntro: string;
  const AMessages: TArray<string>);
var
  LBuilder: TStringBuilder;
  LMsg: string;
begin
  LBuilder := TStringBuilder.Create;
  try
    LBuilder.Append(AIntro);
    for LMsg in AMessages do
      LBuilder.Append(#10).Append('  - ').Append(LMsg);
    inherited Create(LBuilder.ToString);
  finally
    LBuilder.Free;
  end;
  FMessages := AMessages;
end;

{ EOasisDisposeError }

constructor EOasisDisposeError.Create(const AMessages: TArray<string>);
begin
  inherited Create('One or more disposers raised during teardown:', AMessages);
end;

{ EOasisEventError }

constructor EOasisEventError.Create(const AMessages: TArray<string>);
begin
  inherited Create('One or more event listeners raised:', AMessages);
end;

end.
