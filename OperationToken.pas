unit OperationToken;

interface

uses
  {Delphi}
  System.SysUtils
  , System.Classes
  , System.SyncObjs
  , System.Generics.Collections
  {Project}
  ;

type
  TOperationToken = class;

  TOperationStatus = (
    osNotFired
    , osCompleted
    , osCanceled
    , osException);

  TOperationCallback = reference to procedure(AToken: TOperationToken);

  TOperationToken = class
  private
    FIsFired: Boolean;
    FLock: TCriticalSection;
    FOnFiredCallbacks: TList<TOperationCallback>;
    FReason: string; // Stores the cancellation reason
    FOperationStatus: TOperationStatus;
  public
    constructor Create;
    destructor Destroy; override;

    procedure Fire(AOperationStatus: TOperationStatus; const AReason: String = '');
    function IsFired: Boolean;
    function GetReason: string;
    function GetStatus: TOperationStatus;

    procedure RegisterCallback(const ACallback: TOperationCallback);
    procedure Reset; // Allows token reuse
  end;

  function OperationStatusToStr(AOperationStatus: TOperationStatus): String;

{*
// Usage Example
procedure SimulateWork(AToken: TOperationToken);
begin
  AToken.RegisterCallback(
    procedure(AToken: TOperationToken)
    begin
      Writeln('Task received cancellation request. Reason: ', AToken.GetReason);
    end
  );

  for var I := 1 to 100 do
  begin
    if AToken.IsFired then
    begin
      Writeln('Operation cancelled. Reason: ', AToken.GetReason);
      Exit;
    end;

    // Simulate some work
    Sleep(50);
    Writeln('Processing ', I);
  end;
end;

var
  Token: TOperationToken;
begin
  Token := TOperationToken.Create;
  try
    TThread.CreateAnonymousThread(
      procedure
      begin
        Sleep(500); // Simulate delay
        Writeln('Cancelling operation...');
        Token.Fire(TOperationStatus.osCanceled, 'User manually stopped the operation.');
      end
    ).Start;

    SimulateWork(Token);
  finally
    Token.Free;
  end;
end;
*}

implementation

uses
  {Delphi}
  RTTI
  {Project}
  ;

function OperationStatusToStr(AOperationStatus: TOperationStatus): String;
begin
  Result := TRttiEnumerationType.GetName(AOperationStatus);
end;

constructor TOperationToken.Create;
begin
  inherited Create;
  FIsFired := False;
  FLock := TCriticalSection.Create;
  FOnFiredCallbacks := TList<TOperationCallback>.Create;
  FReason := '';
end;

destructor TOperationToken.Destroy;
begin
  FLock.Free;
  FOnFiredCallbacks.Free;
  inherited;
end;

procedure TOperationToken.Fire(AOperationStatus: TOperationStatus; const AReason: String = '');
begin
  FLock.Enter;
  try
    if not FIsFired then
    begin
      FIsFired := True;
      FReason := AReason;
      FOperationStatus := AOperationStatus;

      // Notify all registered callbacks
      for var _Callback in FOnFiredCallbacks do
      begin
        TThread.Queue(nil, procedure begin _Callback(Self); end);
      end;
    end;
  finally
    FLock.Leave;
  end;
end;

function TOperationToken.IsFired: Boolean;
begin
  FLock.Enter;
  try
    Result := FIsFired;
  finally
    FLock.Leave;
  end;
end;

function TOperationToken.GetReason: string;
begin
  FLock.Enter;
  try
    Result := FReason;
  finally
    FLock.Leave;
  end;
end;

function TOperationToken.GetStatus: TOperationStatus;
begin
  FLock.Enter;
  try
    Result := FOperationStatus;
  finally
    FLock.Leave;
  end;
end;

procedure TOperationToken.RegisterCallback(const ACallback: TOperationCallback);
begin
  FLock.Enter;
  try
    if FIsFired then
    begin
      // Immediately invoke the callback if already cancelled
      TThread.Queue(nil, procedure begin ACallback(Self); end);
    end
    else
    begin
      FOnFiredCallbacks.Add(ACallback);
    end;
  finally
    FLock.Leave;
  end;
end;

procedure TOperationToken.Reset;
begin
  FLock.Enter;
  try
    FIsFired := False;
    FReason := '';
    // FOnFiredCallbacks.Clear;
    FOperationStatus := TOperationStatus.osNotFired;
  finally
    FLock.Leave;
  end;
end;

end.
