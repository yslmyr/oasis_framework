program WaterfallDemo;

{$APPTYPE CONSOLE}

(* Oasis demo - waterfall middleware pipeline (Cordis 'waterfall' dispatch).

  A request event flows through a chain of around-style middlewares; each one
  receives (args, Next) and either delegates (Next) or VETOES by returning
  without calling Next:

    logging  -> always logs, always delegates
    auth     -> vetoes when the token is wrong (short-circuit: nothing
                downstream runs)
    ratelimit-> delegates, but counts; vetoes after the quota
    handler  -> the terminal step (a plain emit listener can observe it)

  Waterfall() returns True when the chain completed and False when someone
  vetoed - the host can answer 403/429 accordingly. *)

uses
  System.SysUtils,
  Oasis.Types in '..\..\src\Oasis.Core\Oasis.Types.pas',
  Oasis.Spin in '..\..\src\Oasis.Core\Oasis.Spin.pas',
  Oasis.Errors in '..\..\src\Oasis.Core\Oasis.Errors.pas',
  Oasis.Effects in '..\..\src\Oasis.Core\Oasis.Effects.pas',
  Oasis.Services in '..\..\src\Oasis.Core\Oasis.Services.pas',
  Oasis.Events in '..\..\src\Oasis.Core\Oasis.Events.pas',
  Oasis.Inject in '..\..\src\Oasis.Core\Oasis.Inject.pas',
  Oasis.Context in '..\..\src\Oasis.Core\Oasis.Context.pas',
  Oasis.Plugin in '..\..\src\Oasis.Core\Oasis.Plugin.pas';

type
  TMiddlewarePlugin = class(TOasisPlugin)
  strict private
    FCalls: Integer;
  public
    constructor Create;
    procedure Apply(const Ctx: IContext); override;
    property Calls: Integer read FCalls;
  end;

var
  GHandled: Integer;

function Arg(const A: array of const; const ADefault: string): string;
begin
  if (Length(A) > 0) and (A[0].VType = vtUnicodeString) then
    Result := string(A[0].VUnicodeString)
  else
    Result := ADefault;
end;

constructor TMiddlewarePlugin.Create;
begin
  inherited Create('middleware');
end;

procedure TMiddlewarePlugin.Apply(const Ctx: IContext);
begin
  { 1. logging: observes and always delegates }
  Ctx.Events.OnWaterfall('http/request',
    procedure(const A: array of const; const ANext: TWaterfallNext)
    begin
      Writeln('  [logging ] -> ', Arg(A, '?'));
      ANext(A);
    end);

  { 2. auth: VETO unless the token is 'secret' }
  Ctx.Events.OnWaterfall('http/request',
    procedure(const A: array of const; const ANext: TWaterfallNext)
    begin
      if Arg(A, '') = 'secret' then
      begin
        Writeln('  [auth    ] token ok');
        ANext(A);
      end
      else
      begin
        Writeln('  [auth    ] 403 - bad token, vetoing (downstream will NOT run)');
        { no ANext call => short-circuit }
      end;
    end);

  { 3. rate limit: veto after 3 calls }
  Ctx.Events.OnWaterfall('http/request',
    procedure(const A: array of const; const ANext: TWaterfallNext)
    begin
      Inc(FCalls);
      if FCalls > 2 then
        Writeln('  [ratelimit] 429 - quota exceeded, vetoing')
      else
      begin
        Writeln('  [ratelimit] call ', FCalls, ' of 2');
        ANext(A);
      end;
    end);

  { 4. handler: the terminal step }
  Ctx.Events.OnWaterfall('http/request',
    procedure(const A: array of const; const ANext: TWaterfallNext)
    begin
      Inc(GHandled);
      Writeln('  [handler ] 200 OK - handled #', GHandled);
      ANext(A);   { terminal middleware still delegates so the chain 'completes' }
    end);
end;

var
  Ctx: IContext;
  LPlugin: TMiddlewarePlugin;
begin
  ReportMemoryLeaksOnShutdown := True;
  Ctx := TContext.Create('app');
  LPlugin := TMiddlewarePlugin.Create;
  Ctx.Plugin(LPlugin);
  try
    Writeln('--- request 1: valid token (full chain) ---');
    Writeln('  completed=', Ctx.Events.Waterfall('http/request', ['secret']));

    Writeln('--- request 2: bad token (auth vetoes) ---');
    Writeln('  completed=', Ctx.Events.Waterfall('http/request', ['letmein']));

    Writeln('--- request 3: valid again ---');
    Writeln('  completed=', Ctx.Events.Waterfall('http/request', ['secret']));

    Writeln('--- request 4: quota exceeded (ratelimit vetoes) ---');
    Writeln('  completed=', Ctx.Events.Waterfall('http/request', ['secret']));

    Writeln('--- summary ---');
    Writeln('  handled requests: ', GHandled, ' (of 4 - vetoes never reach the handler)');
    Ctx.Dispose;
  finally
    { the context kept the plugin alive for its fiber's lifetime; LPlugin's
      interface ref goes away with Ctx }
  end;
end.
