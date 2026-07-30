// genprofiles.lpr  –  Log‑probability profile generator (Laplace smoothing)
// ------------------------------------------------------------------
// For each language corpus, extracts character trigrams,
// computes smoothed log‑probabilities, keeps the top FINAL_TOP
// trigrams and writes them to a binary .dat file.
//
// Usage: ./genprofiles <corpus_dir> <output_file>

program genprofiles;

{$mode objfpc}{$H+}
{$codepage utf8}

uses
  SysUtils, Classes, LazUTF8;

const
  MIN_TEXT_LENGTH = 10000;
  FINAL_TOP       = 600;       // keep 600 most characteristic trigrams
  LOG_SCALE       = 1000;      // multiply log-prob by this and store as SmallInt

type
  TTrigWeight = record
    Trig      : string;
    LogWeight : Integer;       // ln(prob) * LOG_SCALE
  end;
  TTrigWeightArray = array of TTrigWeight;

// ------------------------------------------------------------------
// Clean and normalise text: collapse spaces, keep only letters
// of the most common scripts.
// ------------------------------------------------------------------
function CleanText(const AText: string): string;
var
  p, charLen, spaceCount: Integer;
  ch: string;
  cp: UCS4Char;
begin
  Result := '';
  spaceCount := 0;
  p := 1;
  while p <= Length(AText) do
  begin
    charLen := UTF8CodepointSize(@AText[p]);
    if charLen = 0 then begin Inc(p); Continue; end;
    ch := Copy(AText, p, charLen);
    Inc(p, charLen);
    cp := UTF8CodepointToUnicode(@ch[1], charLen);
    if (cp = $0020) or (cp = $00A0) or (cp = $2000) or (cp = $2001) or
       (cp = $2002) or (cp = $2003) or (cp = $2004) or (cp = $2005) or
       (cp = $2006) or (cp = $2007) or (cp = $2008) or (cp = $2009) or
       (cp = $200A) or (cp = $200B) or (cp = $202F) or (cp = $205F) or
       (cp = $3000) then
    begin
      Inc(spaceCount);
      if spaceCount = 1 then Result := Result + ' ';
    end
    else
    begin
      spaceCount := 0;
      if (cp < $0020) or (cp = $007F) or ((cp >= $200B) and (cp <= $200F)) then Continue;
      // Keep letters of many scripts
      if ((cp >= $0041) and (cp <= $005A)) or
         ((cp >= $0061) and (cp <= $007A)) or
         ((cp >= $00C0) and (cp <= $024F)) or
         ((cp >= $1E00) and (cp <= $1EFF)) or
         ((cp >= $0400) and (cp <= $052F)) or
         ((cp >= $0E00) and (cp <= $0EFF)) or
         ((cp >= $0D00) and (cp <= $0D7F)) or
         ((cp >= $0900) and (cp <= $09FF)) or
         ((cp >= $0A00) and (cp <= $0B7F)) or
         ((cp >= $0B80) and (cp <= $0CFF)) or
         ((cp >= $4E00) and (cp <= $9FFF)) or
         ((cp >= $3040) and (cp <= $30FF)) or
         ((cp >= $AC00) and (cp <= $D7AF)) or
         ((cp >= $1000) and (cp <= $109F)) or
         ((cp >= $1780) and (cp <= $17FF)) or
         ((cp >= $1800) and (cp <= $18AF)) or
         ((cp >= $1200) and (cp <= $137F)) or
         ((cp >= $0600) and (cp <= $06FF)) or
         ((cp >= $0750) and (cp <= $077F)) or
         ((cp >= $FB50) and (cp <= $FDFF)) or
         ((cp >= $FE70) and (cp <= $FEFF)) or
         ((cp >= $0590) and (cp <= $05FF)) or
         ((cp >= $0370) and (cp <= $03FF)) or
         ((cp >= $0530) and (cp <= $058F)) or
         ((cp >= $10A0) and (cp <= $10FF)) or
         ((cp >= $2D30) and (cp <= $2D7F)) or
         ((cp >= $0D80) and (cp <= $0DFF)) or
         ((cp >= $0F00) and (cp <= $0FFF)) then
        Result := Result + ch;
    end;
  end;
  Result := UTF8LowerCase(Result);
end;

// ------------------------------------------------------------------
// Extract trigrams (no script filtering – CleanText already does it)
// ------------------------------------------------------------------
function ExtractCharTrigrams(const AText: string): TStringArray;
var
  chars: array of string = nil;
  i, p, charLen, actualCharCount: Integer;
  ch: string;
begin
  Result := nil;
  SetLength(chars, UTF8Length(AText));
  actualCharCount := 0;
  p := 1;
  while p <= Length(AText) do
  begin
    charLen := UTF8CodepointSize(@AText[p]);
    if charLen = 0 then begin Inc(p); Continue; end;
    ch := Copy(AText, p, charLen);
    Inc(p, charLen);
    chars[actualCharCount] := ch;
    Inc(actualCharCount);
  end;
  SetLength(chars, actualCharCount);
  if Length(chars) < 3 then Exit;
  SetLength(Result, Length(chars) - 2);
  for i := 0 to High(Result) do
    Result[i] := chars[i] + chars[i+1] + chars[i+2];
end;

// ------------------------------------------------------------------
// Sort TTrigWeight array by LogWeight descending, then Trig ascending
// ------------------------------------------------------------------
procedure SortByWeight(var A: TTrigWeightArray; L, R: Integer);
var
  i, j: Integer;
  pivot: TTrigWeight;
  tmp: TTrigWeight;
begin
  if L >= R then Exit;
  pivot := A[(L + R) div 2];
  i := L; j := R;
  repeat
    while (A[i].LogWeight > pivot.LogWeight) or
          ((A[i].LogWeight = pivot.LogWeight) and (A[i].Trig < pivot.Trig)) do Inc(i);
    while (A[j].LogWeight < pivot.LogWeight) or
          ((A[j].LogWeight = pivot.LogWeight) and (A[j].Trig > pivot.Trig)) do Dec(j);
    if i <= j then
    begin
      tmp := A[i]; A[i] := A[j]; A[j] := tmp;
      Inc(i); Dec(j);
    end;
  until i > j;
  SortByWeight(A, L, j);
  SortByWeight(A, i, R);
end;

var
  corpusDir, outFile, txtFilePath, langCode, fullPath, clean: string;
  sr: TSearchRec;
  validFiles: TStringList;
  i, j, k, totalLangs, trigCount, codeLen, trigLen: Integer;
  fs: TFileStream;
  txtOut: TextFile;
  trigArray: TStringArray;
  freqMap: TStringList;        // simple map trig -> count
  weights: TTrigWeightArray;
  totalTrigrams, vocabSize: Integer;
  logProb: Double;
  logWeight: SmallInt;
begin
  if ParamCount < 2 then
  begin
    Writeln('Usage: genprofiles <corpus_dir> <output_file>');
    Halt(1);
  end;
  corpusDir := IncludeTrailingPathDelimiter(ParamStr(1));
  outFile   := ParamStr(2);
  txtFilePath := ChangeFileExt(outFile, '.txt');

  validFiles := TStringList.Create;
  if FindFirst(corpusDir + '*.txt', faAnyFile, sr) = 0 then
  begin
    repeat
      langCode := ChangeFileExt(sr.Name, '');
      fullPath := corpusDir + langCode + '.txt';
      with TStringList.Create do
      begin
        LoadFromFile(fullPath, TEncoding.UTF8);
        if UTF8Length(Text) >= MIN_TEXT_LENGTH then
          validFiles.Add(langCode)
        else
          Writeln('Skipping ', langCode, ' (corpus too short)');
        Free;
      end;
    until FindNext(sr) <> 0;
    FindClose(sr);
  end;
  if validFiles.Count = 0 then
  begin
    Writeln('No valid corpora found.');
    Halt(1);
  end;
  totalLangs := validFiles.Count;

  AssignFile(txtOut, txtFilePath);
  Rewrite(txtOut);
  fs := TFileStream.Create(outFile, fmCreate);
  try
    fs.WriteBuffer(totalLangs, SizeOf(totalLangs));
    for i := 0 to totalLangs - 1 do
    begin
      langCode := validFiles[i];
      Write(Format('  [%d/%d] %s ...', [i+1, totalLangs, langCode]));
      fullPath := corpusDir + langCode + '.txt';
      with TStringList.Create do
      begin
        LoadFromFile(fullPath, TEncoding.UTF8);
        clean := CleanText(Text);
        Free;
      end;
      trigArray := ExtractCharTrigrams(clean);
      if trigArray = nil then
      begin
        codeLen := Length(langCode);
        fs.WriteBuffer(codeLen, SizeOf(codeLen));
        if codeLen > 0 then fs.WriteBuffer(langCode[1], codeLen);
        trigCount := 0;
        fs.WriteBuffer(trigCount, SizeOf(trigCount));
        Writeln(txtOut, langCode, ' =');
        Writeln(' 0 trigrams');
        Continue;
      end;

      // Count frequencies
      freqMap := TStringList.Create;
      freqMap.Sorted := True;
      freqMap.Duplicates := dupIgnore;
      totalTrigrams := 0;
      for j := 0 to High(trigArray) do
      begin
        k := freqMap.IndexOf(trigArray[j]);
        if k >= 0 then
          freqMap.Objects[k] := TObject(PtrInt(freqMap.Objects[k]) + 1)
        else
          freqMap.AddObject(trigArray[j], TObject(1));
        Inc(totalTrigrams);
      end;
      vocabSize := freqMap.Count;

      // Compute log probabilities with Laplace smoothing
      SetLength(weights, freqMap.Count);
      for j := 0 to freqMap.Count - 1 do
      begin
        logProb := ln( (PtrInt(freqMap.Objects[j]) + 1) / (totalTrigrams + vocabSize) );
        weights[j].Trig := freqMap[j];
        weights[j].LogWeight := Round(logProb * LOG_SCALE);
      end;
      freqMap.Free;

      // Sort by descending log-weight and keep top FINAL_TOP
      if Length(weights) > 1 then
        SortByWeight(weights, 0, High(weights));
      if Length(weights) > FINAL_TOP then
        SetLength(weights, FINAL_TOP);

      trigCount := Length(weights);
      // Write to binary file
      codeLen := Length(langCode);
      fs.WriteBuffer(codeLen, SizeOf(codeLen));
      if codeLen > 0 then fs.WriteBuffer(langCode[1], codeLen);
      fs.WriteBuffer(trigCount, SizeOf(trigCount));
      for j := 0 to trigCount - 1 do
      begin
        trigLen := Length(weights[j].Trig);
        fs.WriteBuffer(trigLen, SizeOf(trigLen));
        if trigLen > 0 then fs.WriteBuffer(weights[j].Trig[1], trigLen);
        logWeight := weights[j].LogWeight;
        fs.WriteBuffer(logWeight, SizeOf(logWeight));
      end;

      // Write text dump
      Write(txtOut, langCode, ' =');
      for j := 0 to trigCount - 1 do
        Write(txtOut, ' "', weights[j].Trig, '"');
      Writeln(txtOut);
      Writeln(Format(' %d trigrams', [trigCount]));
    end;
    Writeln('Done. Profiles saved to ', outFile);
    Writeln('Text dump saved to ', txtFilePath);
  finally
    CloseFile(txtOut);
    fs.Free;
  end;
  validFiles.Free;
end.
