unit Threading.AsyncListProcessing;

interface

uses
  {Delphi}
  System.SysUtils
  , System.Generics.Collections
  , System.Classes
  , System.Threading
  {Project}
  , OperationToken
  ;

type
  IAsyncList<TInput, TOutput> = interface
    ['{A152A530-5B22-4C9F-B493-349FAD9299D7}']
    procedure Await(const AAwaitProc: TProc<TArray<TOutput>>);
  end;

  TAsyncListProcessor<TInput, TOutput> = class(TInterfacedObject, IAsyncList<TInput, TOutput>)
  strict private
    FSelf: IAsyncList<TInput, TOutput>;
    FArray: TArray<TInput>;
    FAsyncProc: TFunc<TInput, TOutput>;
    FAwaitProc: TProc<TArray<TOutput>>;
    FLock: TObject;
    FResults: TArray<TOutput>;
    FTaskLists: TObjectList<TList<TInput>>;
    FCancellationToken: TOperationToken;
    FCurrentListIndex: Integer;

    procedure Run;
  public
    constructor Create(AOperationToken: TOperationToken; const AArray: TArray<TInput>; const AAsyncProc: TFunc<TInput, TOutput>);
    destructor Destroy; override;
    procedure Await(const AAwaitProc: TProc<TArray<TOutput>>);
  end;

  TAsyncListHelper = class
  public
    class function Create<TInput, TOutput>(
      AOperationToken: TOperationToken;
      const AArray: TArray<TInput>;
      const AAsyncProc: TFunc<TInput, TOutput>
    ): IAsyncList<TInput, TOutput>;
  end;

{*
  Usage:
    procedure TForm4.CancellationCallback(AToken: TOperationToken);
    begin
      Memo1.Lines.Add(IntToStr(GetCurrentThreadId) + ' - ' + IntToStr(MainThreadID) + ': ' + OperationStatusToStr(AToken.GetStatus) + '-' + AToken.GetReason);
      BitBtn1.Enabled := True;
    end;

    procedure TForm4.FormCreate(Sender: TObject);
    begin
      FOperationToken := TOperationToken.Create;
      FOperationToken.RegisterCallback(CancellationCallback);
    end;

    procedure TForm4.FormDestroy(Sender: TObject);
    begin
      FreeAndNil(FOperationToken);
    end;

    function TForm4.AsyncProcessFileFunc(AFile: String): String; // Warning - this function is run NOT in main thread
    var
      _Content: TStringList;
    begin
      Result := '';
      _Content := TStringList.Create;
      try
        _Content.LoadFromFile(AFile);
        if AnsiContainsText(_Content.Text, 'procedure TfrmLogin.lblErrorMouseMove(Sender: TObject; Shift: TShiftState; X,') then
        begin
          Result := AFile;
          if Assigned(FOperationToken) then
            FOperationToken.Fire(TOperationStatus.osCompleted, 'Found');  // Stop all other tasks
        end;
      finally
        FreeAndNil(_Content);
      end;
    end;

    procedure TForm4.ProcessFileResult(AResults: TArray<String>); // This procedure is ran in main thread
    var
      _Res: String;
    begin
      for _Res in AResults do
      begin
        if Trim(_Res) <> '' then
          Memo1.Lines.Add(_Res);
      end;
    end;

    procedure TForm4.TestAsyncFileProcessing(AFileArray: TArray<String>);
    var
      _AsyncProcessFile: TFunc<String, String>;
    begin
      _AsyncProcessFile := AsyncProcessFileFunc;

      TAsyncListProcessor<String, String>.Create(FOperationToken, AFileArray, _AsyncProcessFile).Await(ProcessFileResult);
    end;

    procedure TForm4.BitBtn1Click(Sender: TObject);
    var
      _FileArray: TArray<String>;
      _Path: String;
    begin
      Memo1.Clear;
      BitBtn1.Enabled := False;
      SetLength(_FileArray, 0);
      for _Path in TDirectory.GetFiles('C:\License', '*.pas', TSearchOption.soAllDirectories) do
      begin
        SetLength(_FileArray, Length(_FileArray) + 1);
        _FileArray[Length(_FileArray) - 1] := _Path;
      end;
      TestAsyncFileProcessing(_FileArray);
    end;

    procedure TForm4.BitBtn2Click(Sender: TObject);
    begin
      FOperationToken.Fire(TOperationStatus.osCanceled, 'User canceled the operation')
    end;
*}

implementation

uses
  {Delphi}
  Math
  , WinAPI.Windows
  {Project}
  ;

{ TAsyncListHelper }

class function TAsyncListHelper.Create<TInput, TOutput>(
  AOperationToken: TOperationToken;
  const AArray: TArray<TInput>;
  const AAsyncProc: TFunc<TInput, TOutput>
): IAsyncList<TInput, TOutput>;
begin
  Result := TAsyncListProcessor<TInput, TOutput>.Create(AOperationToken, AArray, AAsyncProc);
end;

{ TAsyncListProcessor<TInput, TOutput> }

constructor TAsyncListProcessor<TInput, TOutput>.Create(
  AOperationToken: TOperationToken;
  const AArray: TArray<TInput>;
  const AAsyncProc: TFunc<TInput, TOutput>);
var
  _List: TList<TInput>;
  _ThreadCount, _ItemsPerThread, _StartIdx, _EndIdx, I: Integer;
begin
  inherited Create;
  FArray := AArray;
  FAsyncProc := AAsyncProc;
  FLock := TObject.Create;
  FCancellationToken := AOperationToken;
  SetLength(FResults, Length(FArray));
  FTaskLists := TObjectList<TList<TInput>>.Create;

  // Split the array into multiple smaller lists
  _ThreadCount := Trunc(Min(Length(FArray), TThread.ProcessorCount) / 2) + 1;
  _ItemsPerThread := Ceil(Length(FArray) / _ThreadCount);

  for I := 0 to _ThreadCount - 1 do
  begin
    _StartIdx := I * _ItemsPerThread;
    _EndIdx := Min(_StartIdx + _ItemsPerThread - 1, Length(FArray) - 1);

    if _StartIdx <= _EndIdx then
    begin
      _List := TList<TInput>.Create;
      _List.AddRange(Copy(FArray, _StartIdx, _EndIdx - _StartIdx + 1));
      FTaskLists.Add(_List);
    end;
  end;
  FCurrentListIndex := 0;
end;

destructor TAsyncListProcessor<TInput, TOutput>.Destroy;
begin
  FreeAndNil(FLock);
  FreeAndNil(FTaskLists);
  inherited;
end;

procedure TAsyncListProcessor<TInput, TOutput>.Await(const AAwaitProc: TProc<TArray<TOutput>>);
begin
  FSelf := Self;
  FAwaitProc := AAwaitProc;
  TTask.Run(Run);
end;

procedure TAsyncListProcessor<TInput, TOutput>.Run;
var
  _Tasks: TArray<ITask>;
  _Idx: Integer;
  _ProcessingTask: ITask;
begin
  SetLength(_Tasks, FTaskLists.Count);
  FCancellationToken.Reset; // Reset cancellation flag

  for _Idx := 0 to FTaskLists.Count - 1 do
  begin
    _ProcessingTask := TTask.Create(procedure
    var
      _ListIndex: Integer;
      _ItemIndex: Integer;
      _List: TList<TInput>;
      _Element: TInput;
      _Result: TOutput;
    begin
      try
        TMonitor.Enter(FLock);
        try
          _ListIndex := FCurrentListIndex;
          Inc(FCurrentListIndex);
        finally
          TMonitor.Exit(FLock);
        end;
        _List := FTaskLists[_ListIndex];
        for _ItemIndex := 0 to _List.Count - 1 do
        begin
          if FCancellationToken.IsFired then
            Exit; // Graceful exit

          _Element := _List[_ItemIndex];
          _Result := FAsyncProc(_Element);

          TThread.Synchronize(nil, // Synchronize is painful, but Queue produces unexpected results
            procedure
            begin
              if Assigned(FAwaitProc) then
                FAwaitProc(TArray<TOutput>.Create(_Result));
            end);
        end;
      except
        on E: Exception do begin
          FCancellationToken.Fire(TOperationStatus.osException, E.Message);
        end;
      end;
    end);
    _ProcessingTask.Start;
    _Tasks[_Idx] := _ProcessingTask;
  end;

  TTask.WaitForAll(_Tasks);
  // It would be possible to call Synchronize here and only once, but we couldn't cancel in FAwaitProc if we wanted
  FSelf := nil;
end;

end.

