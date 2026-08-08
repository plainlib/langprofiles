//-----------------------------------------------------------------------------------
//  langtest © 2026 by Alexander Tverskoy
//  Licensed under the MIT License
//  You may obtain a copy of the License at https://opensource.org/licenses/MIT
//-----------------------------------------------------------------------------------
//  Language detection test utility.
//  Runs DetectLanguageWithConfidence on a directory of UTF-8 .txt corpora
//  and reports accuracy statistics.
//-----------------------------------------------------------------------------------

unit langtest;

{$mode objfpc}{$H+}
{$codepage utf8}

interface

// Pause with exit via ESC
procedure WaitForEsc;

// Run language detection test on corpus files in the given directory.
// MaxLen: maximum number of characters taken from each file (starting at 1).
// Iter:   number of samples per file (sliding window if file longer than MaxLen).
// ProfileFile: if not empty, additional profile file is loaded before testing.
procedure RunLanguageDetectionTest(const CorpusDir: string; MaxLen: integer; Iter: integer; const ProfileFile: string = '');

// Write a message to both console and a log file.
// LogFileName defaults to 'langprofiles.log' in the application folder.
procedure LogToFile(const Msg: string; const LogFileName: string = 'langprofiles.log');

// Print information about currently loaded language profiles.
procedure ShowLoadedProfilesInfo(const ProfileFile: string = '');

implementation

uses
  {$IFDEF WINDOWS}
  Windows,
  {$ENDIF}
  SysUtils,
  StrUtils,
  Classes,
  LazUTF8,
  Math,
  DateUtils,        // for MilliSecondsBetween
  langdetect;

const
  BOM_UTF8 = #239#187#191;

procedure LogToFile(const Msg: string; const LogFileName: string = 'langprofiles.log');
var
  LogPath: string;
  LogFile: TextFile;
begin
  WriteLn(Msg);
  LogPath := ExtractFilePath(ParamStr(0)) + LogFileName;
  AssignFile(LogFile, LogPath);
  if FileExists(LogPath) then
    Append(LogFile)
  else
    Rewrite(LogFile);
  WriteLn(LogFile, Msg);
  CloseFile(LogFile);
end;

procedure ShowLoadedProfilesInfo(const ProfileFile: string = '');
var
  ProfIdx: integer;
  TrigCnt, WordCnt: integer;
  Msg: string;
begin
  // Load additional profiles if requested
  if ProfileFile <> '' then
  begin
    if FileExists(ProfileFile) then
    begin
      TLangDetect.MergeProfilesFromFile(ProfileFile);
      LogToFile('Additional profiles loaded from: ' + ProfileFile);
    end
    else
      LogToFile('Warning: profile file not found: ' + ProfileFile);
  end;

  LogToFile('Profile info (loaded from langprofiles.dat or built-in):');
  LogToFile(Format('Total languages: %d', [Length(TLangDetect.Profiles)]));
  for ProfIdx := 0 to High(TLangDetect.Profiles) do
  begin
    TrigCnt := Length(TLangDetect.Profiles[ProfIdx].Trigrams);
    WordCnt := Length(TLangDetect.Profiles[ProfIdx].Wrds);
    Msg := Format('  %-6s  trigrams: %5d', [TLangDetect.Profiles[ProfIdx].Code, TrigCnt]);
    if WordCnt > 0 then
      Msg := Msg + Format('  words: %5d', [WordCnt])
    else
      Msg := Msg + '  words:     -';
    Msg := Msg + Format('  priority: %d', [TLangDetect.Profiles[ProfIdx].Priority]);
    LogToFile(Msg);
  end;
end;

procedure WaitForEsc;
{$IFDEF WINDOWS}
var
  hIn: THandle;
  Mode: DWORD = 0;
  Rec: TInputRecord;
  Read: DWORD = 0;
{$ENDIF}
begin
  Rec := Default(TInputRecord);

  LogToFile('Press ESC to quit...');
  {$IFDEF WINDOWS}
  hIn := GetStdHandle(STD_INPUT_HANDLE);

  GetConsoleMode(hIn, Mode);
  SetConsoleMode(hIn, ENABLE_PROCESSED_INPUT or ENABLE_WINDOW_INPUT);

  repeat
    ReadConsoleInput(hIn, Rec, 1, Read);

    if (Rec.EventType = KEY_EVENT) and
       Rec.Event.KeyEvent.bKeyDown and
       (Rec.Event.KeyEvent.wVirtualKeyCode = VK_ESCAPE) then
      Break;
  until False;
  {$ELSE}
  Readln;
  {$ENDIF}
end;

procedure RunLanguageDetectionTest(const CorpusDir: string; MaxLen: integer; Iter: integer; const ProfileFile: string = '');
var
  SR: TSearchRec;
  FullPath: string;
  RawText: string;
  TestText: string;
  FileNameNoExt: string;
  DetectedCode: string;
  Confidence: double;
  TotalTests: integer = 0;
  CorrectTests: integer = 0;
  FileOK, FileTotal: integer;
  StartIdx, k: integer;
  Step: double;
  TextLen: integer;
  Percent: double;
  ResultsLine: string;
  StartTime, EndTime: TDateTime;
  Msg: string;
  // Confidence bucket counters for correct and wrong results
  CorrByConf: array[0..4] of integer;
  WrongByConf: array[0..4] of integer;

// Helper: return bucket index (0..4) for a confidence value
  function ConfBucket(conf: double): integer; inline;
  begin
    if conf < 0.2 then
      Result := 0
    else if conf < 0.4 then
      Result := 1
    else if conf < 0.6 then
      Result := 2
    else if conf < 0.8 then
      Result := 3
    else
      Result := 4;
  end;

begin
  if not DirectoryExists(CorpusDir) then
  begin
    LogToFile('Directory not found: ' + CorpusDir);
    Exit;
  end;

  // Load additional profiles if specified
  if ProfileFile <> '' then
  begin
    if FileExists(ProfileFile) then
    begin
      TLangDetect.MergeProfilesFromFile(ProfileFile);
      LogToFile('Additional profiles loaded from: ' + ProfileFile);
    end
    else
      LogToFile('Warning: profile file not found: ' + ProfileFile);
  end;

  // Reset confidence distribution counters
  for k := 0 to 4 do
  begin
    CorrByConf[k] := 0;
    WrongByConf[k] := 0;
  end;

  LogToFile('Scanning: ' + CorpusDir);
  if Length(TLangDetect.Profiles) > 0 then
    LogToFile(Format('First Profile: %d trigrams, %d words', [Length(TLangDetect.Profiles[0].Trigrams), Length(TLangDetect.Profiles[0].Wrds)]));
  LogToFile('Max sample length: ' + IntToStr(MaxLen) + IfThen(Iter > 1, '. Samples per file: ' + IntToStr(Iter), ''));
  LogToFile('----------------------------------------');

  StartTime := Now;

  if FindFirst(CorpusDir + '\*.txt', faAnyFile, SR) = 0 then
  begin
    repeat
      FullPath := CorpusDir + '\' + SR.Name;
      if SR.Attr and faDirectory <> 0 then Continue;

      // read whole file
    try
      with TStringList.Create do
      try
        LoadFromFile(FullPath);
        RawText := Text;
      finally
        Free;
      end;
    except
      LogToFile(SR.Name + ' -> [read error]');
      Continue;
    end;

      // strip UTF-8 BOM if present
      if Copy(RawText, 1, 3) = BOM_UTF8 then
        Delete(RawText, 1, 3);

      FileNameNoExt := ChangeFileExt(SR.Name, '');
      TextLen := UTF8Length(RawText);
      FileTotal := Iter;
      FileOK := 0;
      ResultsLine := '';

      if Iter = 1 then
      begin
        TestText := UTF8Copy(RawText, 1, Min(MaxLen, TextLen));
        DetectedCode := TLangDetect.DetectLanguageWithConfidence(TestText, Confidence);

        // Update confidence distribution
        if DetectedCode = FileNameNoExt then
          Inc(CorrByConf[ConfBucket(Confidence)])
        else
          Inc(WrongByConf[ConfBucket(Confidence)]);

        ResultsLine := DetectedCode;
        if DetectedCode = FileNameNoExt then
          Inc(FileOK);
        Msg := Format('%s -> %s (%.2f) %s', [SR.Name, DetectedCode, Confidence, BoolToStr(DetectedCode =
          FileNameNoExt, 'OK', 'FAIL expected ' + FileNameNoExt)]);
        LogToFile(Msg);
        Inc(TotalTests);
        Inc(CorrectTests, FileOK);
      end
      else
      begin
        if TextLen <= MaxLen then
        begin
          TestText := RawText;
          for k := 1 to Iter do
          begin
            DetectedCode := TLangDetect.DetectLanguageWithConfidence(TestText, Confidence);

            if DetectedCode = FileNameNoExt then
              Inc(CorrByConf[ConfBucket(Confidence)])
            else
              Inc(WrongByConf[ConfBucket(Confidence)]);

            if k > 1 then ResultsLine := ResultsLine + ' ';
            ResultsLine := ResultsLine + DetectedCode + Format('%.2f', [Confidence]);
            if DetectedCode = FileNameNoExt then Inc(FileOK);
          end;
        end
        else
        begin
          Step := (TextLen - MaxLen) / (Iter - 1);
          for k := 0 to Iter - 1 do
          begin
            StartIdx := 1 + Round(k * Step);
            TestText := UTF8Copy(RawText, StartIdx, MaxLen);
            DetectedCode := TLangDetect.DetectLanguageWithConfidence(TestText, Confidence);

            if DetectedCode = FileNameNoExt then
              Inc(CorrByConf[ConfBucket(Confidence)])
            else
              Inc(WrongByConf[ConfBucket(Confidence)]);

            if k > 0 then ResultsLine := ResultsLine + ' ';
            ResultsLine := ResultsLine + DetectedCode + Format('%.2f', [Confidence]);
            if DetectedCode = FileNameNoExt then Inc(FileOK);
          end;
        end;

        Msg := Format('%s -> %d/%d', [SR.Name, FileOK, FileTotal]);
        if FileOK = FileTotal then
          Msg := Msg + ' OK (all correct)'
        else
          Msg := Msg + Format(' FAIL expected %s', [FileNameNoExt]);
        Msg := Msg + ' [' + ResultsLine + ']';
        LogToFile(Msg);

        Inc(TotalTests, FileTotal);
        Inc(CorrectTests, FileOK);
      end;

    until FindNext(SR) <> 0;
    FindClose(SR);
  end;

  EndTime := Now;

  if TotalTests > 0 then
    Percent := CorrectTests * 100.0 / TotalTests
  else
    Percent := 0;

  LogToFile('----------------------------------------');
  LogToFile('Max sample length: ' + IntToStr(MaxLen) + IfThen(Iter > 1, '. Samples per file: ' + IntToStr(Iter), ''));
  Msg := Format('Processed: %d tests over %d files, Correct: %d (%.1f%%)', [TotalTests, TotalTests div Iter, CorrectTests, Percent]);
  LogToFile(Msg);

  // Confidence distribution output
  Msg := 'Correct: <0.2 ' + IntToStr(CorrByConf[0]) + ' <0.4 ' + IntToStr(CorrByConf[1]) + ' <0.6 ' +
    IntToStr(CorrByConf[2]) + ' <0.8 ' + IntToStr(CorrByConf[3]) + ' <1.0 ' + IntToStr(CorrByConf[4]);
  LogToFile(Msg);
  Msg := 'Wrong:   <0.2 ' + IntToStr(WrongByConf[0]) + ' <0.4 ' + IntToStr(WrongByConf[1]) + ' <0.6 ' +
    IntToStr(WrongByConf[2]) + ' <0.8 ' + IntToStr(WrongByConf[3]) + ' <1.0 ' + IntToStr(WrongByConf[4]);
  LogToFile(Msg);

  Msg := Format('Test completed in %d ms.', [MilliSecondsBetween(EndTime, StartTime)]);
  LogToFile(Msg);
end;

end.
