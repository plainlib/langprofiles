// genprofiles.lpr  –  Final TF‑IDF based clean profile generator
// ------------------------------------------------------------------
// Phase 1: for each language, extract unique trigrams and their
//          local frequencies, then merge into a global DF list
//          (kept sorted, binary search for speed).
// Phase 2: compute TF‑IDF per language using binary search,
//          write top FINAL_TOP with 2‑byte rank.
// Only characters of the target script are kept.
//
// Usage: ./genprofiles <corpus_dir> <output_file>

program genprofiles;

{$mode objfpc}{$H+}
{$codepage utf8}
{$warn 6058 off}

uses
  SysUtils, Classes, LazUTF8, Math;

type
  TTrigDF = record
    Trig    : string;
    DocFreq : Integer;   // total global frequency (used as DF)
  end;
  TTrigDFArray = array of TTrigDF;
  TTrigWeight = record
    Trig   : string;
    Weight : Double;
  end;
  TTrigWeightArray = array of TTrigWeight;

const
  MIN_TEXT_LENGTH = 10000;
  FINAL_TOP       = 600;         // keep 600 most characteristic trigrams
  CJK_SAMPLE_SIZE = 200;

// ------------------------------------------------------------------
//  Extended script groups (Ge'ez, Arabic, Armenian, etc.)
// ------------------------------------------------------------------
function CharScript(cp: UCS4Char): Integer;
begin
  // CJK
  if (cp >= $4E00) and (cp <= $9FFF) then Exit(1);
  if (cp >= $3400) and (cp <= $4DBF) then Exit(1);
  if (cp >= $20000) and (cp <= $2A6DF) then Exit(1);
  if (cp >= $3040) and (cp <= $30FF) then Exit(1);   // Hiragana/Katakana
  // Hangul
  if (cp >= $AC00) and (cp <= $D7AF) then Exit(2);
  // Thai
  if (cp >= $0E00) and (cp <= $0E7F) then Exit(3);
  // Lao
  if (cp >= $0E80) and (cp <= $0EFF) then Exit(4);
  // Malayalam
  if (cp >= $0D00) and (cp <= $0D7F) then Exit(5);
  // Bengali / Assamese
  if (cp >= $0980) and (cp <= $09FF) then Exit(6);
  // Devanagari
  if (cp >= $0900) and (cp <= $097F) then Exit(7);
  // Gurmukhi
  if (cp >= $0A00) and (cp <= $0A7F) then Exit(8);
  // Gujarati
  if (cp >= $0A80) and (cp <= $0AFF) then Exit(9);
  // Oriya
  if (cp >= $0B00) and (cp <= $0B7F) then Exit(10);
  // Tamil
  if (cp >= $0B80) and (cp <= $0BFF) then Exit(11);
  // Telugu
  if (cp >= $0C00) and (cp <= $0C7F) then Exit(12);
  // Kannada
  if (cp >= $0C80) and (cp <= $0CFF) then Exit(13);
  // Mongolian (traditional)
  if (cp >= $1800) and (cp <= $18AF) then Exit(14);
  // Myanmar
  if (cp >= $1000) and (cp <= $109F) then Exit(15);
  // Khmer
  if (cp >= $1780) and (cp <= $17FF) then Exit(16);
  // Cyrillic (basic + extended)
  if (cp >= $0400) and (cp <= $052F) then Exit(17);
  // Latin (broad)
  if (cp >= $0041) and (cp <= $005A) then Exit(18);
  if (cp >= $0061) and (cp <= $007A) then Exit(18);
  if (cp >= $00C0) and (cp <= $024F) then Exit(18);
  if (cp >= $1E00) and (cp <= $1EFF) then Exit(18);
  // Ge'ez (Ethiopian)
  if (cp >= $1200) and (cp <= $137F) then Exit(19);
  // Arabic
  if (cp >= $0600) and (cp <= $06FF) then Exit(20);
  if (cp >= $0750) and (cp <= $077F) then Exit(20);
  if (cp >= $FB50) and (cp <= $FDFF) then Exit(20);
  if (cp >= $FE70) and (cp <= $FEFF) then Exit(20);
  // Hebrew
  if (cp >= $0590) and (cp <= $05FF) then Exit(21);
  // Greek
  if (cp >= $0370) and (cp <= $03FF) then Exit(22);
  // Armenian
  if (cp >= $0530) and (cp <= $058F) then Exit(23);
  // Georgian
  if (cp >= $10A0) and (cp <= $10FF) then Exit(24);
  // Tifinagh
  if (cp >= $2D30) and (cp <= $2D7F) then Exit(25);
  // Sinhala
  if (cp >= $0D80) and (cp <= $0DFF) then Exit(26);
  // Tibetan
  if (cp >= $0F00) and (cp <= $0FFF) then Exit(27);
  Result := 0;   // unknown / punctuation
end;

// ------------------------------------------------------------------
//  Map language code to expected script ID (0 = auto‑detect)
// ------------------------------------------------------------------
function ForcedScript(const LangCode: string): Integer;
begin
  case LangCode of
    'am': Result := 19;   // Ge'ez
    'ar': Result := 20;   // Arabic
    'as': Result := 6;    // Bengali script (Assamese uses same script)
    'az': Result := 18;   // Latin
    'be': Result := 17;   // Cyrillic
    'bg': Result := 17;
    'bn': Result := 6;    // Bengali
    'br': Result := 18;
    'bs': Result := 18;
    'ca': Result := 18;
    'cs': Result := 18;
    'cy': Result := 18;
    'da': Result := 18;
    'de': Result := 18;
    'el': Result := 22;   // Greek
    'en': Result := 18;
    'eo': Result := 18;
    'es': Result := 18;
    'et': Result := 18;
    'eu': Result := 18;
    'fa': Result := 20;   // Arabic script
    'ff': Result := 18;
    'fi': Result := 18;
    'fr': Result := 18;
    'fy': Result := 18;
    'ga': Result := 18;
    'gd': Result := 18;
    'gl': Result := 18;
    'gn': Result := 18;
    'gu': Result := 9;    // Gujarati
    'ha': Result := 18;
    'he': Result := 21;   // Hebrew
    'hi': Result := 7;    // Devanagari
    'hr': Result := 18;
    'ht': Result := 18;
    'hu': Result := 18;
    'hy': Result := 23;   // Armenian
    'id': Result := 18;
    'ig': Result := 18;
    'is': Result := 18;
    'it': Result := 18;
    'ja': Result := 1;    // CJK
    'jv': Result := 18;
    'ka': Result := 24;   // Georgian
    'kk': Result := 17;   // Cyrillic
    'km': Result := 16;   // Khmer
    'kn': Result := 13;   // Kannada
    'ko': Result := 2;    // Hangul
    'ku': Result := 18;
    'ky': Result := 17;   // Cyrillic
    'la': Result := 18;
    'lg': Result := 18;
    'li': Result := 18;
    'ln': Result := 18;
    'lo': Result := 4;    // Lao
    'lt': Result := 18;
    'lv': Result := 18;
    'mg': Result := 18;
    'mk': Result := 17;   // Cyrillic
    'ml': Result := 5;    // Malayalam
    'mn': Result := 17;   // Cyrillic (modern Mongolian uses Cyrillic)
    'mr': Result := 7;    // Devanagari
    'ms': Result := 18;
    'my': Result := 15;   // Myanmar
    'ne': Result := 7;    // Devanagari
    'nl': Result := 18;
    'no': Result := 18;
    'ns': Result := 18;
    'om': Result := 18;
    'or': Result := 10;   // Oriya
    'pa': Result := 8;    // Gurmukhi
    'pl': Result := 18;
    'ps': Result := 20;   // Arabic
    'pt': Result := 18;
    'qu': Result := 18;
    'rm': Result := 18;
    'ro': Result := 18;
    'ru': Result := 17;   // Cyrillic
    'sa': Result := 7;    // Devanagari
    'sc': Result := 18;
    'sd': Result := 20;   // Arabic
    'si': Result := 26;   // Sinhala
    'sk': Result := 18;
    'sl': Result := 18;
    'so': Result := 18;
    'sq': Result := 18;
    'sr': Result := 17;   // Cyrillic
    'ss': Result := 18;
    'su': Result := 18;
    'sv': Result := 18;
    'sw': Result := 18;
    'ta': Result := 11;   // Tamil
    'te': Result := 12;   // Telugu
    'th': Result := 3;    // Thai
    'tl': Result := 18;
    'tn': Result := 18;
    'tr': Result := 18;
    'ug': Result := 20;   // Arabic
    'uk': Result := 17;   // Cyrillic
    'ur': Result := 20;   // Arabic
    'uz': Result := 18;
    'vi': Result := 18;
    'wo': Result := 18;
    'xh': Result := 18;
    'yi': Result := 21;   // Hebrew
    'yo': Result := 18;
    'zh-CN': Result := 1;
    'zh-TW': Result := 1;
    'zu': Result := 18;
    else
      Result := 0;        // auto‑detect (fallback)
  end;
end;

// ------------------------------------------------------------------
//  Clean and normalize: collapse all spaces, remove control chars.
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
  while p <= Length(AText) do begin
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
    else begin
      spaceCount := 0;
      if (cp < $0020) or (cp = $007F) or ((cp >= $200B) and (cp <= $200F)) then Continue;
      // keep letters of all known scripts
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
//  Extract trigrams keeping only characters of the target script.
//  CJK heuristic applies when target script is CJK.
// ------------------------------------------------------------------
function ExtractCharTrigrams(const AText: string; TargetScr: Integer): TStringArray;
var
  s: string;
  chars: array of string = nil;
  i, p, charLen, actualCharCount: Integer;
  ch: string;
  totalCount, cjkCount: Integer;
  skipSpaces: Boolean;
  cp: UCS4Char;
  scr: Integer;
begin
  Result := nil;
  s := ' ' + CleanText(AText) + ' ';

  // CJK heuristic only for CJK target
  cjkCount := 0; totalCount := 0;
  if TargetScr = 1 then begin
    p := 1;
    while (p <= Length(s)) and (totalCount < CJK_SAMPLE_SIZE) do begin
      charLen := UTF8CodepointSize(@s[p]);
      if charLen = 0 then begin Inc(p); Continue; end;
      ch := Copy(s, p, charLen);
      Inc(p, charLen);
      if ch = ' ' then Continue;
      if Ord(ch[1]) >= $C0 then begin
        Inc(totalCount);
        cp := UTF8CodepointToUnicode(@ch[1], charLen);
        if (cp >= $4E00) and (cp <= $9FFF) or (cp >= $3400) and (cp <= $4DBF) or
           (cp >= $20000) and (cp <= $2A6DF) then
          Inc(cjkCount);
      end;
    end;
    skipSpaces := (totalCount > 0) and (cjkCount >= 5) and (cjkCount / totalCount > 0.5);
  end else
    skipSpaces := False;

  SetLength(chars, Length(s));
  actualCharCount := 0;
  p := 1;
  while p <= Length(s) do begin
    charLen := UTF8CodepointSize(@s[p]);
    if charLen = 0 then begin Inc(p); Continue; end;
    ch := Copy(s, p, charLen);
    Inc(p, charLen);
    cp := UTF8CodepointToUnicode(@ch[1], charLen);
    if ch = ' ' then begin
      if not skipSpaces then begin
        if (actualCharCount = 0) or (chars[actualCharCount - 1] <> ' ') then begin
          chars[actualCharCount] := ' ';
          Inc(actualCharCount);
        end;
      end;
    end else begin
      scr := CharScript(cp);
      if (scr = TargetScr) then begin
        chars[actualCharCount] := ch;
        Inc(actualCharCount);
      end else begin
        if not skipSpaces then begin
          if (actualCharCount = 0) or (chars[actualCharCount - 1] <> ' ') then begin
            chars[actualCharCount] := ' ';
            Inc(actualCharCount);
          end;
        end;
      end;
    end;
  end;
  SetLength(chars, actualCharCount);
  if Length(chars) < 3 then Exit;
  SetLength(Result, Length(chars) - 2);
  for i := 0 to High(Result) do
    Result[i] := chars[i] + chars[i+1] + chars[i+2];
end;

// ------------------------------------------------------------------
//  Sort array of strings (for grouping identical trigrams)
// ------------------------------------------------------------------
procedure SortStrings(var A: TStringArray; L, R: Integer);
var
  i, j: Integer;
  pivot, tmp: string;
begin
  if L >= R then Exit;
  pivot := A[(L + R) div 2];
  i := L; j := R;
  repeat
    while A[i] < pivot do Inc(i);
    while A[j] > pivot do Dec(j);
    if i <= j then begin
      tmp := A[i]; A[i] := A[j]; A[j] := tmp;
      Inc(i); Dec(j);
    end;
  until i > j;
  SortStrings(A, L, j);
  SortStrings(A, i, R);
end;

// ------------------------------------------------------------------
//  Sort TTrigWeight array by Weight descending, then Trig ascending
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
    while (A[i].Weight > pivot.Weight) or
          ((A[i].Weight = pivot.Weight) and (A[i].Trig < pivot.Trig)) do Inc(i);
    while (A[j].Weight < pivot.Weight) or
          ((A[j].Weight = pivot.Weight) and (A[j].Trig > pivot.Trig)) do Dec(j);
    if i <= j then begin
      tmp := A[i]; A[i] := A[j]; A[j] := tmp;
      Inc(i); Dec(j);
    end;
  until i > j;
  SortByWeight(A, L, j);
  SortByWeight(A, i, R);
end;

// ------------------------------------------------------------------
//  Add a trigram to the global DF list (kept sorted by Trig),
//  or increment its frequency.  Uses binary search.
// ------------------------------------------------------------------
procedure AddToGlobal(var A: TTrigDFArray; var Count: Integer; const Trig: string; Freq: Integer);
var
  L, R, Mid, cmp: Integer;
begin
  if Count = 0 then begin
    SetLength(A, 1);
    A[0].Trig := Trig;
    A[0].DocFreq := Freq;
    Count := 1;
    Exit;
  end;
  L := 0;
  R := Count - 1;
  while L <= R do begin
    Mid := (L + R) div 2;
    cmp := CompareStr(Trig, A[Mid].Trig);
    if cmp = 0 then begin
      Inc(A[Mid].DocFreq, Freq);
      Exit;
    end else if cmp < 0 then
      R := Mid - 1
    else
      L := Mid + 1;
  end;
  // Not found – insert at position L
  SetLength(A, Count + 1);
  if L < Count then
    Move(A[L], A[L+1], (Count - L) * SizeOf(TTrigDF));
  A[L].Trig := Trig;
  A[L].DocFreq := Freq;
  Inc(Count);
end;

// ==================================================================
var
  corpusDir, outFile, txtFilePath: string;
  sr: TSearchRec;
  fullPath, langCode, txtContent, cleanContent: string;
  validFiles: TStringList;
  globalDF: TTrigDFArray = nil;
  globalDFCount: Integer = 0;
  totalLangs, i, j, k, targScript: Integer;
  fs: TFileStream;
  txtOut: TextFile;
  trigArray: TStringArray;
  localWeights: TTrigWeightArray = nil;
  trigCount, codeLen, trigLen, freq: Integer;
  L, R, Mid, cmp: Integer;      // for binary search
  rankWord: Word;
  idf: Double;
begin
  if ParamCount < 2 then begin
    Writeln('Usage: genprofiles <corpus_dir> <output_file>');
    Halt(1);
  end;
  corpusDir := IncludeTrailingPathDelimiter(ParamStr(1));
  outFile   := ParamStr(2);
  txtFilePath := ChangeFileExt(outFile, '.txt');

  validFiles := TStringList.Create;

  // ---------- Collect valid language files ----------
  if FindFirst(corpusDir + '*.txt', faAnyFile, sr) = 0 then begin
    repeat
      langCode := ChangeFileExt(sr.Name, '');
      fullPath := corpusDir + langCode + '.txt';
      with TStringList.Create do begin
        LoadFromFile(fullPath, TEncoding.UTF8);
        txtContent := Text;
        Free;
      end;
      if UTF8Length(txtContent) >= MIN_TEXT_LENGTH then
        validFiles.Add(langCode)
      else
        Writeln('Skipping ', langCode, ' (corpus too short)');
    until FindNext(sr) <> 0;
    FindClose(sr);
  end;
  if validFiles.Count = 0 then begin
    Writeln('No valid corpora found.');
    Halt(1);
  end;
  totalLangs := validFiles.Count;
  Writeln('Found ', totalLangs, ' valid language(s).');

  // ---------- Phase 1: collect unique trigrams and their global frequency ----------
  Writeln('Phase 1: Collecting unique trigrams...');
  for i := 0 to totalLangs - 1 do begin
    langCode := validFiles[i];
    Write(Format('  [%d/%d] %s ...', [i+1, totalLangs, langCode]));
    fullPath := corpusDir + langCode + '.txt';
    with TStringList.Create do begin
      LoadFromFile(fullPath, TEncoding.UTF8);
      txtContent := Text;
      Free;
    end;
    cleanContent := CleanText(txtContent);
    targScript := ForcedScript(langCode);
    if targScript = 0 then targScript := 18;   // default Latin if not forced
    trigArray := ExtractCharTrigrams(cleanContent, targScript);
    if trigArray = nil then begin
      Writeln(' 0 trigrams (skipped)');
      Continue;
    end;

    // Sort and count local frequencies
    SortStrings(trigArray, 0, High(trigArray));
    j := 0;
    while j <= High(trigArray) do begin
      if trigArray[j] = '   ' then begin Inc(j); Continue; end;
      k := j;
      while (k < High(trigArray)) and (trigArray[k+1] = trigArray[j]) do Inc(k);
      freq := k - j + 1;
      AddToGlobal(globalDF, globalDFCount, trigArray[j], freq);
      j := k + 1;
    end;
    Writeln(Format(' done (global unique: %d)', [globalDFCount]));
  end;

  // ---------- Phase 2: TF‑IDF per language and write profiles ----------
  Writeln('Phase 2: Computing TF‑IDF and writing profiles...');
  AssignFile(txtOut, txtFilePath);
  Rewrite(txtOut);
  fs := TFileStream.Create(outFile, fmCreate);
  try
    fs.WriteBuffer(totalLangs, SizeOf(totalLangs));
    for i := 0 to totalLangs - 1 do begin
      langCode := validFiles[i];
      Write(Format('  [%d/%d] %s ...', [i+1, totalLangs, langCode]));
      fullPath := corpusDir + langCode + '.txt';
      with TStringList.Create do begin
        LoadFromFile(fullPath, TEncoding.UTF8);
        txtContent := Text;
        Free;
      end;
      cleanContent := CleanText(txtContent);
      targScript := ForcedScript(langCode);
      if targScript = 0 then targScript := 18;
      trigArray := ExtractCharTrigrams(cleanContent, targScript);
      if trigArray = nil then begin
        codeLen := Length(langCode);
        fs.WriteBuffer(codeLen, SizeOf(codeLen));
        if codeLen > 0 then fs.WriteBuffer(langCode[1], codeLen);
        trigCount := 0;
        fs.WriteBuffer(trigCount, SizeOf(trigCount));
        Writeln(txtOut, langCode, ' =');
        Writeln(' 0 trigrams');
        Continue;
      end;

      // Local frequencies
      SortStrings(trigArray, 0, High(trigArray));
      SetLength(localWeights, 0);
      j := 0;
      while j <= High(trigArray) do begin
        if trigArray[j] = '   ' then begin Inc(j); Continue; end;
        k := j;
        while (k < High(trigArray)) and (trigArray[k+1] = trigArray[j]) do Inc(k);
        freq := k - j + 1;
        idf := 0.0;
        // binary search in globalDF
        L := 0; R := globalDFCount - 1;
        while L <= R do begin
          Mid := (L + R) div 2;
          cmp := CompareStr(trigArray[j], globalDF[Mid].Trig);
          if cmp = 0 then begin
            idf := ln(totalLangs / (globalDF[Mid].DocFreq / freq));
            Break;
          end else if cmp < 0 then
            R := Mid - 1
          else
            L := Mid + 1;
        end;
        SetLength(localWeights, Length(localWeights) + 1);
        localWeights[High(localWeights)].Trig := trigArray[j];
        localWeights[High(localWeights)].Weight := freq * idf;
        j := k + 1;
      end;

      if Length(localWeights) > 1 then
        SortByWeight(localWeights, 0, High(localWeights));
      if Length(localWeights) > FINAL_TOP then
        SetLength(localWeights, FINAL_TOP);

      trigCount := Length(localWeights);
      codeLen := Length(langCode);
      fs.WriteBuffer(codeLen, SizeOf(codeLen));
      if codeLen > 0 then fs.WriteBuffer(langCode[1], codeLen);
      fs.WriteBuffer(trigCount, SizeOf(trigCount));
      for j := 0 to trigCount - 1 do begin
        trigLen := Length(localWeights[j].Trig);
        fs.WriteBuffer(trigLen, SizeOf(trigLen));
        if trigLen > 0 then fs.WriteBuffer(localWeights[j].Trig[1], trigLen);
        rankWord := Word(j + 1);
        fs.WriteBuffer(rankWord, SizeOf(rankWord));
      end;

      Write(txtOut, langCode, ' =');
      for j := 0 to trigCount - 1 do
        Write(txtOut, ' "', localWeights[j].Trig, '"');
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
