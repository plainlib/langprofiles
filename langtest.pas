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
procedure RunLanguageDetectionTest(const CorpusDir: string; MaxLen: integer; Iter: integer);

implementation

uses
  {$IFDEF WINDOWS}
  Windows,
  {$ENDIF}
  SysUtils,
  Classes,
  LazUTF8,
  Math,
  DateUtils,        // for MilliSecondsBetween
  langdetect;

const
  BOM_UTF8 = #239#187#191;

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

  WriteLn('Press ESC to quit...');
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

procedure RunLanguageDetectionTest(const CorpusDir: string; MaxLen: integer; Iter: integer);
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
begin
  if not DirectoryExists(CorpusDir) then
  begin
    WriteLn('Directory not found: ', CorpusDir);
    Exit;
  end;

  WriteLn('Scanning: ', CorpusDir);
  WriteLn('Max sample length: ', MaxLen);
  if Iter > 1 then
    WriteLn('Samples per file: ', Iter);
  WriteLn('----------------------------------------');

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
      WriteLn(SR.Name, ' -> [read error]');
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
        DetectedCode := DetectLanguageWithConfidence(TestText, Confidence);
        ResultsLine := DetectedCode;
        if DetectedCode = FileNameNoExt then
          Inc(FileOK);
        WriteLn(Format('%s -> %s (%.2f) %s', [SR.Name, DetectedCode, Confidence, BoolToStr(DetectedCode =
          FileNameNoExt, 'OK', 'FAIL expected ' + FileNameNoExt)]));
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
            DetectedCode := DetectLanguageWithConfidence(TestText, Confidence);
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
            DetectedCode := DetectLanguageWithConfidence(TestText, Confidence);
            if k > 0 then ResultsLine := ResultsLine + ' ';
            ResultsLine := ResultsLine + DetectedCode + Format('%.2f', [Confidence]);
            if DetectedCode = FileNameNoExt then Inc(FileOK);
          end;
        end;

        Write(Format('%s -> %d/%d', [SR.Name, FileOK, FileTotal]));
        if FileOK = FileTotal then
          Write(' OK (all correct)')
        else
          Write(Format(' FAIL expected %s', [FileNameNoExt]));
        WriteLn(' [' + ResultsLine + ']');

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

  WriteLn('----------------------------------------');
  WriteLn('Max sample length: ', MaxLen);
  if Iter > 1 then
    WriteLn('Samples per file: ', Iter);
  WriteLn('----------------------------------------');
  WriteLn(Format('Processed: %d tests over %d files, Correct: %d (%.1f%%)', [TotalTests, TotalTests div Iter, CorrectTests, Percent]));
  WriteLn(Format('Test completed in %d ms.', [MilliSecondsBetween(EndTime, StartTime)]));
  WaitForEsc;
end;

end.
