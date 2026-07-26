// genprofiles.lpr
// Language profile generator for uLangDetect
// Compile: fpc genprofiles.lpr
// Usage:   ./genprofiles <corpus_dir> <output_file>
//
// Scans *.txt files in corpus_dir, each named by language code,
// and produces a binary file with up to 300 most frequent character trigrams
// per language (frequency included).

program genprofiles;

{$mode objfpc}{$H+}
{$codepage utf8}
{$warn 6058 off}

uses
  SysUtils,
  Classes,
  LazUTF8,
  fgl;

type
  TTrigramMap = specialize TFPGMap<string, Integer>;

  TTrigFreq = record
    Trig: string;
    Count: Integer;
  end;
  TTrigFreqArray = array of TTrigFreq;

const
  MIN_TEXT_LENGTH = 10000;    // ignore corpora shorter than this
  MIN_TRIGRAM_COUNT = 2;      // discard trigrams with frequency < 2 (use 2 for small languages)
  FINAL_TOP = 300;            // keep final 300 most frequent

// ---------------------------------------------------------------
//  Quicksort descending by Count, then ascending by Trig
//  (not strictly stable, but pivot is saved for consistency)
// ---------------------------------------------------------------
procedure QuickSortByFrequency(var A: TTrigFreqArray; L, R: Integer);
var
  i, j: Integer;
  pivot: TTrigFreq;
  tmp: TTrigFreq;
begin
  if L >= R then Exit;
  pivot := A[(L + R) div 2];   // save pivot element to avoid changes during swaps
  i := L;
  j := R;
  repeat
    while (A[i].Count > pivot.Count) or
          ((A[i].Count = pivot.Count) and (A[i].Trig < pivot.Trig)) do Inc(i);
    while (A[j].Count < pivot.Count) or
          ((A[j].Count = pivot.Count) and (A[j].Trig > pivot.Trig)) do Dec(j);
    if i <= j then
    begin
      tmp := A[i]; A[i] := A[j]; A[j] := tmp;
      Inc(i); Dec(j);
    end;
  until i > j;
  QuickSortByFrequency(A, L, j);
  QuickSortByFrequency(A, i, R);
end;

//  CJK check (same as in uLangDetect)
function IsCJK(const s: string): Boolean;
var
  cp: UCS4Char;
  CharLen: Integer;
begin
  if s = '' then Exit(False);
  CharLen := 0;
  cp := UTF8CodepointToUnicode(@s[1], CharLen);
  Result :=
    ((cp >= $4E00) and (cp <= $9FFF)) or
    ((cp >= $3400) and (cp <= $4DBF)) or
    ((cp >= $20000) and (cp <= $2A6DF)) or
    ((cp >= $F900) and (cp <= $FAFF)) or
    ((cp >= $2F800) and (cp <= $2FA1F)) or
    ((cp >= $3000) and (cp <= $303F)) or
    ((cp >= $FF00) and (cp <= $FFEF)) or
    ((cp >= $3040) and (cp <= $309F)) or
    ((cp >= $30A0) and (cp <= $30FF)) or
    ((cp >= $AC00) and (cp <= $D7AF));
end;

//  Count trigrams from a UTF-8 text
procedure CountTrigrams(const AText: string; Counts: TTrigramMap);
var
  s: string;
  chars: array of string = nil;
  i, p, charLen, actualCharCount: Integer;
  ch, trig: string;
  totalCount, cjkCount: Integer;
  skipSpaces: Boolean;
  idx: Integer;
begin
  s := UTF8LowerCase(AText);

  // ----- First pass: detect if CJK -----
  cjkCount := 0;
  totalCount := 0;
  p := 1;
  while (p <= Length(s)) and (totalCount < 30) do
  begin
    charLen := UTF8CodepointSize(@s[p]);
    if charLen = 0 then Inc(p)
    else
    begin
      ch := Copy(s, p, charLen);
      Inc(p, charLen);
      if ch = ' ' then Continue;
      if ((ch[1] >= 'A') and (ch[1] <= 'Z')) or
         ((ch[1] >= 'a') and (ch[1] <= 'z')) or
         (Ord(ch[1]) >= $C0) then
      begin
        Inc(totalCount);
        if IsCJK(ch) then Inc(cjkCount);
      end;
    end;
  end;
  skipSpaces := (totalCount > 0) and (cjkCount / totalCount > 0.5);

  // ----- Second pass: build character list -----
  SetLength(chars, Length(s));
  actualCharCount := 0;
  p := 1;
  while p <= Length(s) do
  begin
    charLen := UTF8CodepointSize(@s[p]);
    if charLen = 0 then
    begin
      Inc(p);
      Continue;
    end;
    ch := Copy(s, p, charLen);
    Inc(p, charLen);

    if ch = ' ' then
    begin
      if not skipSpaces then
      begin
        if (actualCharCount = 0) or (chars[actualCharCount - 1] <> ' ') then
        begin
          chars[actualCharCount] := ' ';
          Inc(actualCharCount);
        end;
      end;
    end
    else
    if ((ch[1] >= 'A') and (ch[1] <= 'Z')) or
       ((ch[1] >= 'a') and (ch[1] <= 'z')) or
       (Ord(ch[1]) >= $C0) then
    begin
      chars[actualCharCount] := ch;
      Inc(actualCharCount);
    end
    else
    begin
      if not skipSpaces then
      begin
        if (actualCharCount = 0) or (chars[actualCharCount - 1] <> ' ') then
        begin
          chars[actualCharCount] := ' ';
          Inc(actualCharCount);
        end;
      end;
    end;
  end;
  SetLength(chars, actualCharCount);

  // ----- Build trigrams -----
  Counts.Clear;
  for i := 0 to Length(chars) - 3 do
  begin
    trig := chars[i] + chars[i+1] + chars[i+2];
    if trig = '   ' then Continue;   // skip all-space trigrams
    if skipSpaces then
    begin
      // CJK mode: add directly (no double-space check)
      idx := Counts.IndexOf(trig);
      if idx >= 0 then
        Counts.Data[idx] := Counts.Data[idx] + 1
      else
        Counts.Add(trig, 1);
    end
    else
    begin
      if Pos('  ', trig) = 0 then
      begin
        idx := Counts.IndexOf(trig);
        if idx >= 0 then
          Counts.Data[idx] := Counts.Data[idx] + 1
        else
          Counts.Add(trig, 1);
      end;
    end;
  end;
end;

//  Extract and filter top trigrams
function GetTopTrigrams(Counts: TTrigramMap): TStringArray;
var
  arr: TTrigFreqArray = nil;
  i, keepCount: Integer;
begin
  Result := nil;
  SetLength(arr, Counts.Count);
  for i := 0 to Counts.Count - 1 do
  begin
    arr[i].Trig := Counts.Keys[i];
    arr[i].Count := Counts.Data[i];
  end;

  // 1) Keep only trigrams with Count >= MIN_TRIGRAM_COUNT
  keepCount := 0;
  for i := 0 to High(arr) do
    if arr[i].Count >= MIN_TRIGRAM_COUNT then
    begin
      arr[keepCount] := arr[i];
      Inc(keepCount);
    end;
  SetLength(arr, keepCount);

  // 2) Sort descending by Count, then by Trig
  if Length(arr) > 1 then
    QuickSortByFrequency(arr, 0, High(arr));

  // 3) Limit to FINAL_TOP
  if Length(arr) > FINAL_TOP then
    SetLength(arr, FINAL_TOP);

  SetLength(Result, Length(arr));
  for i := 0 to High(arr) do
    Result[i] := arr[i].Trig;
end;

var
  corpusDir, outFile: string;
  sr: TSearchRec;
  fullPath, langCode: string;
  txtContent: string;
  trigCounts: TTrigramMap;
  topTrigrams: TStringArray;
  fs: TFileStream;
  allFiles, validFiles: TStringList;
  i, j, trigCount, codeLen, trigLen, totalUnique: Integer;
  freq: Integer;
begin
  if ParamCount < 2 then
  begin
    Writeln('Usage: genprofiles <corpus_dir> <output_file>');
    Halt(1);
  end;

  corpusDir := IncludeTrailingPathDelimiter(ParamStr(1));
  outFile := ParamStr(2);

  allFiles := TStringList.Create;
  trigCounts := TTrigramMap.Create;
  trigCounts.Sorted := True;
  trigCounts.Duplicates := dupIgnore;
  fs := nil;
  try
    // Collect all .txt files
    if FindFirst(corpusDir + '*.txt', faAnyFile, sr) = 0 then
    begin
      repeat
        allFiles.Add(ChangeFileExt(sr.Name, ''));
      until FindNext(sr) <> 0;
      FindClose(sr);
    end;

    if allFiles.Count = 0 then
    begin
      Writeln('No .txt files found in ', corpusDir);
      Halt(1);
    end;

    // Filter out corpora that are too short (read once and reuse)
    validFiles := TStringList.Create;
    try
      for i := 0 to allFiles.Count - 1 do
      begin
        langCode := allFiles[i];
        fullPath := corpusDir + langCode + '.txt';
        with TStringList.Create do
        try
          LoadFromFile(fullPath);
          txtContent := Text;
        finally
          Free;
        end;
        if UTF8Length(txtContent) >= MIN_TEXT_LENGTH then
          validFiles.Add(langCode)
        else
          Writeln('Skipping ', langCode, ' (corpus too short)');
      end;
    finally
      allFiles.Free;
    end;

    if validFiles.Count = 0 then
    begin
      Writeln('No valid corpora found.');
      Halt(1);
    end;

    // Write header: number of languages that will be saved
    fs := TFileStream.Create(outFile, fmCreate);
    i := validFiles.Count;
    fs.WriteBuffer(i, SizeOf(i));

    for i := 0 to validFiles.Count - 1 do
    begin
      langCode := validFiles[i];
      fullPath := corpusDir + langCode + '.txt';
      Write('Processing ', langCode, ' ... ');
      with TStringList.Create do
      try
        LoadFromFile(fullPath);
        txtContent := Text;
      finally
        Free;
      end;

      trigCounts.Clear;
      CountTrigrams(txtContent, trigCounts);
      topTrigrams := GetTopTrigrams(trigCounts);
      totalUnique := trigCounts.Count;
      Writeln(Length(topTrigrams), ' trigrams (', totalUnique, ' unique)');

      // Write language code
      codeLen := Length(langCode);
      fs.WriteBuffer(codeLen, SizeOf(codeLen));
      if codeLen > 0 then
        fs.WriteBuffer(langCode[1], codeLen);

      // Write trigram count
      trigCount := Length(topTrigrams);
      fs.WriteBuffer(trigCount, SizeOf(trigCount));

      // Write each trigram + its frequency
      for j := 0 to trigCount - 1 do
      begin
        trigLen := Length(topTrigrams[j]);
        fs.WriteBuffer(trigLen, SizeOf(trigLen));
        if trigLen > 0 then
          fs.WriteBuffer(topTrigrams[j][1], trigLen);
        // Safe retrieval using IndexOf / Data, though KeyData is safe here because we know the key exists
        freq := trigCounts.KeyData[topTrigrams[j]];
        fs.WriteBuffer(freq, SizeOf(freq));
      end;
    end;
    Writeln('Done. Profiles saved to ', outFile);
  finally
    validFiles.Free;
    trigCounts.Free;
    fs.Free;
  end;
end.
