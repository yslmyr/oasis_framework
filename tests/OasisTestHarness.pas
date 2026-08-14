unit OasisTestHarness;

{ Minimal console assertion harness (no external test framework dependency;
  adapt to DUnitX by wrapping Expect/Run in a test fixture). }

interface

uses
  System.SysUtils;

type
  TTestHarness = class;

  TTestProc = reference to procedure(H: TTestHarness);

  TTestHarness = class
  strict private
    FPassed: Integer;
    FFailed: Integer;
  public
    procedure Run(const AName: string; const ATest: TTestProc);
    procedure Expect(const ACondition: Boolean; const AMessage: string);
    function Summary: string;
    property Passed: Integer read FPassed;
    property Failed: Integer read FFailed;
  end;

implementation

procedure TTestHarness.Run(const AName: string; const ATest: TTestProc);
begin
  Writeln;
  Writeln('--- ', AName, ' ---');
  try
    ATest(Self);
  except
    on E: Exception do
    begin
      Inc(FFailed);
      Writeln('  UNEXPECTED EXCEPTION: ', E.ClassName, ': ', E.Message);
    end;
  end;
end;

procedure TTestHarness.Expect(const ACondition: Boolean; const AMessage: string);
begin
  if ACondition then
  begin
    Inc(FPassed);
    Writeln('  ok     - ', AMessage);
  end
  else
  begin
    Inc(FFailed);
    Writeln('  FAIL   - ', AMessage);
  end;
end;

function TTestHarness.Summary: string;
begin
  Result := Format('%d passed, %d failed', [FPassed, FFailed]);
end;

end.
