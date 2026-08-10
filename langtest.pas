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

procedure WaitForEsc;

procedure RunLanguageDetectionTest(const CorpusDir: string; MaxLen: integer; Iter: integer; const ProfileFile: string = '');

procedure LogToFile(const Msg: string; const LogFileName: string = 'langprofiles.log'; LogToConsole: boolean = True);

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
  DateUtils,
  langdetect;

const
  BOM_UTF8 = #239#187#191;

procedure LogToFile(const Msg: string; const LogFileName: string = 'langprofiles.log'; LogToConsole: boolean = True);
var
  LogPath: string;
  LogFile: TextFile;
begin
  if LogToConsole then
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

procedure WaitForEsc;
{$IFDEF WINDOWS}
var
  Rec: TInputRecord;
  hIn: THandle;
  Mode: DWORD = 0;
  Read: DWORD = 0;
{$ENDIF}
begin
  LogToFile('Press ESC to quit...');
  {$IFDEF WINDOWS}
  Rec := Default(TInputRecord);
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

procedure ShowLoadedProfilesInfo(const ProfileFile: string = '');
var
  ProfIdx: integer;
  TrigCnt, WordCnt: integer;
  Msg: string;
begin
  if ProfileFile <> '' then
    if FileExists(ProfileFile) then
    begin
      TLangDetect.MergeProfilesFromFile(ProfileFile);
      LogToFile('Additional profiles loaded from: ' + ProfileFile);
    end
    else
      LogToFile('Warning: profile file not found: ' + ProfileFile);

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

// Keep only characters belonging to the target script and spaces
function FilterTextByScript(const Txt: string; const LangCode: string): string;
var
  Script: TScriptType;
  sb: TStringBuilder;
  p, charLen: integer;
  cp: UCS4Char;
  ch: string;
begin
  sb := TStringBuilder.Create;
  try
    Script := TLangDetect.GetScriptByLang(LangCode);
    p := 1;
    while p <= Length(Txt) do
    begin
      charLen := UTF8CodepointSize(@Txt[p]);
      if charLen = 0 then
      begin
        Inc(p);
        Continue;
      end;
      ch := Copy(Txt, p, charLen);
      cp := UTF8CodepointToUnicode(PChar(ch), charLen);

      // Keep spaces and characters that belong to the target script
      if (cp = $20) or TLangDetect.IsCharOfScript(cp, Script) then
        sb.Append(ch);

      Inc(p, charLen);
    end;
    Result := sb.ToString;
  finally
    sb.Free;
  end;
end;

// Collapse multiple spaces into one and trim leading/trailing spaces
function NormalizeSpaces(const S: string): string;
var
  p, charLen: integer;
  ch: string;
  prevSpace: boolean;
  sb: TStringBuilder;
begin
  sb := TStringBuilder.Create;
  try
    prevSpace := True;   // remove leading spaces
    p := 1;
    while p <= Length(S) do
    begin
      charLen := UTF8CodepointSize(@S[p]);
      if charLen = 0 then
      begin
        Inc(p);
        Continue;
      end;
      ch := Copy(S, p, charLen);
      if ch = ' ' then
      begin
        if not prevSpace then
          sb.Append(' ');
        prevSpace := True;
      end
      else
      begin
        sb.Append(ch);
        prevSpace := False;
      end;
      Inc(p, charLen);
    end;
    Result := Trim(sb.ToString);
  finally
    sb.Free;
  end;
end;

// Extract a sample of exactly DesiredLen (after cleaning) from a raw fragment
function PrepareTestSample(const RawText: string; StartIdx: integer; DesiredLen: integer; const LangCode: string): string;
var
  Temp: string;
begin
  // Take a larger window to compensate for filtered-out characters
  Temp := UTF8Copy(RawText, StartIdx, DesiredLen * 10);
  Temp := FilterTextByScript(Temp, LangCode);
  Temp := NormalizeSpaces(Temp);
  // Cut to the exact desired length (or less if not enough characters remain)
  if UTF8Length(Temp) > DesiredLen then
    Temp := UTF8Copy(Temp, 1, DesiredLen);
  Result := Temp;
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
  CorrByConf: array[0..4] of integer;
  WrongByConf: array[0..4] of integer;
  EffectiveLen: integer;   // working area: we don't sample the last MaxLen chars

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

  if ProfileFile <> '' then
    if FileExists(ProfileFile) then
    begin
      TLangDetect.MergeProfilesFromFile(ProfileFile);
      LogToFile('Additional profiles loaded from: ' + ProfileFile);
    end
    else
      LogToFile('Warning: profile file not found: ' + ProfileFile);

  for k := 0 to 4 do
  begin
    CorrByConf[k] := 0;
    WrongByConf[k] := 0;
  end;

  LogToFile('Scanning: ' + CorpusDir);
  if Length(TLangDetect.Profiles) > 0 then
    LogToFile(Format('First Profile: %d trigrams, %d words', [Length(TLangDetect.Profiles[0].Trigrams),
      Length(TLangDetect.Profiles[0].Wrds)]));
  LogToFile('Max sample length: ' + IntToStr(MaxLen) + IfThen(Iter > 1, '. Samples per file: ' + IntToStr(Iter), ''));
  LogToFile('----------------------------------------');

  StartTime := Now;

  if FindFirst(ConcatPaths([CorpusDir, '*.txt']), faAnyFile, SR) = 0 then
  begin
    repeat
      FullPath := ConcatPaths([CorpusDir, SR.Name]);
      if SR.Attr and faDirectory <> 0 then Continue;
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

      if Copy(RawText, 1, 3) = BOM_UTF8 then
        Delete(RawText, 1, 3);

      FileNameNoExt := ChangeFileExt(SR.Name, '');
      TextLen := UTF8Length(RawText);
      FileTotal := 0;   // will count actual non-empty samples
      FileOK := 0;
      ResultsLine := '';

      if Iter = 1 then
      begin
        TestText := PrepareTestSample(RawText, 1, MaxLen, FileNameNoExt);
        // Even a single sample may be empty if the file has no valid characters
        if TestText <> '' then
        begin
          DetectedCode := TLangDetect.DetectLanguageWithConfidence(TestText, Confidence);
          if DetectedCode = FileNameNoExt then
            Inc(CorrByConf[ConfBucket(Confidence)])
          else
            Inc(WrongByConf[ConfBucket(Confidence)]);
          if DetectedCode = FileNameNoExt then Inc(FileOK);
          Msg := Format('%s -> %s (%.2f) %s', [SR.Name, DetectedCode, Confidence, BoolToStr(
            DetectedCode = FileNameNoExt, 'OK', 'FAIL expected ' + FileNameNoExt)]);
          LogToFile(Msg);
          FileTotal := 1;
          Inc(TotalTests);
          Inc(CorrectTests, FileOK);
        end
        else
          LogToFile(SR.Name + ' -> SKIP (empty after cleaning)');
      end
      else
      begin
        EffectiveLen := TextLen - MaxLen;
        if EffectiveLen < 1 then
          EffectiveLen := 1;   // whole file is used

        if EffectiveLen <= MaxLen then
        begin
          // File is small – take the entire cleaned text once and repeat detection
          TestText := PrepareTestSample(RawText, 1, TextLen, FileNameNoExt);
          if TestText <> '' then
          begin
            FileTotal := Iter;
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
            Inc(TotalTests, FileTotal);
            Inc(CorrectTests, FileOK);
          end
          else
            LogToFile(SR.Name + ' -> SKIP (empty after cleaning)');
        end
        else
        begin
          // Sliding window over the safe area
          Step := (EffectiveLen - MaxLen) / (Iter - 1);
          for k := 0 to Iter - 1 do
          begin
            StartIdx := 1 + Round(k * Step);
            TestText := PrepareTestSample(RawText, StartIdx, MaxLen, FileNameNoExt);
            if TestText = '' then
              Continue;   // should not happen in the safe area, but be robust
            DetectedCode := TLangDetect.DetectLanguageWithConfidence(TestText, Confidence);
            if DetectedCode = FileNameNoExt then
              Inc(CorrByConf[ConfBucket(Confidence)])
            else
              Inc(WrongByConf[ConfBucket(Confidence)]);
            if k > 0 then ResultsLine := ResultsLine + ' ';
            ResultsLine := ResultsLine + DetectedCode + Format('%.2f', [Confidence]);
            if DetectedCode = FileNameNoExt then Inc(FileOK);
          end;
          FileTotal := Iter;
          Inc(TotalTests, FileTotal);
          Inc(CorrectTests, FileOK);
        end;

        if FileTotal > 0 then
        begin
          Msg := Format('%s -> %d/%d', [SR.Name, FileOK, FileTotal]);
          if FileOK = FileTotal then
            Msg := Msg + ' OK (all correct)'
          else
            Msg := Msg + Format(' FAIL expected %s', [FileNameNoExt]);
          Msg := Msg + ' [' + ResultsLine + ']';
          LogToFile(Msg);
        end;
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
