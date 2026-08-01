//-----------------------------------------------------------------------------------
//  Trayslate © 2026 by Alexander Tverskoy
//  Licensed under the GNU General Public License, Version 3 (GPL-3.0)
//  You may obtain a copy of the License at https://www.gnu.org/licenses/gpl-3.0.html
//-----------------------------------------------------------------------------------
//  uLangDetect.pas  –  Fast language detection using character trigrams
//  Always initialises a set of default profiles, then merges in any profiles
//  found in an external binary file (langprofiles.dat).  Profiles from the
//  file overwrite defaults for matching language codes; new codes are added.
//  Public functions:
//    function DetectLanguageForText(const AText: string): string;
//    function DetectLanguageWithConfidence(const AText: string; out Confidence: Double): string;
//  Cross-platform: Windows, Linux, macOS.  Lazarus / FPC 3.2.2+
//-----------------------------------------------------------------------------------

unit langdetect;

{$mode objfpc}{$H+}
{$codepage utf8}

interface

uses
  SysUtils,
  Classes,
  LCLType,
  LazUTF8,
  osutils;

type
  TStringArray = array of string;

//  Extract character trigrams from a UTF-8 text
//  For texts dominated by CJK characters, spaces are ignored.
function ExtractCharTrigrams(const AText: string): TStringArray;

// Returns language code (e.g. 'en', 'ru') or 'unknown'
function DetectLanguageForText(const AText: string): string;

// Also returns a confidence value between 0.0 and 1.0
function DetectLanguageWithConfidence(const AText: string; out Confidence: double): string;

implementation

type
  // Entry for binary search: trigram + its weight
  TTrigEntry = record
    Trig: string;
    Weight: word;
  end;

  TProfile = record
    Code: string;
    Trigrams: TStringArray;   // sorted by frequency, most frequent first
    Freqs: array of word;     // corresponding frequency values (same order)
    SortedTrigrams: array of TTrigEntry; // alphabetically sorted for binary search
  end;

var
  Profiles: array of TProfile;

type
  TScriptType = (
    stLatin,
    stCyrillic,
    stArabic,
    stGreek,
    stHebrew,
    stCJK,
    stDevanagari,
    stOther
    );

  TScriptInfo = record
    Script: TScriptType;

    Latin: integer;
    Cyrillic: integer;
    Arabic: integer;

    Han: integer;
    Hiragana: integer;
    Katakana: integer;
    Hangul: integer;

    Greek: integer;
    Hebrew: integer;
    Devanagari: integer;
    Other: integer;

    Total: integer;
  end;

  {%Region -fold Private Methods}

// Analyse the script composition of the first 300 characters.
// Returns detailed counts for Latin, Cyrillic, CJK sub‑ranges, etc.
function DetectScript(const Txt: string): TScriptInfo;
const
  SAMPLE_SIZE = 300;
var
  p: integer;
  CharLen: integer;
  cp: UCS4Char;
  ch: string;
begin
  Result := Default(TScriptInfo);
  FillChar(Result, SizeOf(Result), 0);
  Result.Script := stOther;

  p := 1;

  while (p <= Length(Txt)) and (Result.Total < SAMPLE_SIZE) do
  begin
    {$NOTES OFF}
    CharLen := UTF8CodepointSize(@Txt[p]);
    {$NOTES ON}

    if CharLen = 0 then
    begin
      Inc(p);
      Continue;
    end;

    ch := Copy(Txt, p, CharLen);
    Inc(p, CharLen);

    if ch = ' ' then
      Continue;

    if ((ch[1] >= '0') and (ch[1] <= '9')) then
      Continue;

    Inc(Result.Total);

    if ((ch[1] >= 'A') and (ch[1] <= 'Z')) or ((ch[1] >= 'a') and (ch[1] <= 'z')) then
    begin
      Inc(Result.Latin);
      Continue;
    end;

    cp := UTF8CodepointToUnicode(PChar(ch), CharLen);

    // Extended Latin
    if ((cp >= $00C0) and (cp <= $024F)) or ((cp >= $1E00) and (cp <= $1EFF)) or ((cp >= $2C60) and (cp <= $2C7F)) then
    begin
      Inc(Result.Latin);
    end

    // Cyrillic
    else if (cp >= $0400) and (cp <= $04FF) then
      Inc(Result.Cyrillic)

    // Arabic
    else if ((cp >= $0600) and (cp <= $06FF)) or ((cp >= $0750) and (cp <= $077F)) then
      Inc(Result.Arabic)

    // Han (Chinese ideographs)
    else if ((cp >= $3400) and (cp <= $4DBF)) or ((cp >= $4E00) and (cp <= $9FFF)) or ((cp >= $20000) and (cp <= $2A6DF)) then
      Inc(Result.Han)

    // Hiragana
    else if (cp >= $3040) and (cp <= $309F) then
      Inc(Result.Hiragana)

    // Katakana
    else if (cp >= $30A0) and (cp <= $30FF) then
      Inc(Result.Katakana)

    // Hangul
    else if (cp >= $AC00) and (cp <= $D7AF) then
      Inc(Result.Hangul)

    // Greek
    else if (cp >= $0370) and (cp <= $03FF) then
      Inc(Result.Greek)

    // Hebrew
    else if (cp >= $0590) and (cp <= $05FF) then
      Inc(Result.Hebrew)

    // Devanagari
    else if (cp >= $0900) and (cp <= $097F) then
      Inc(Result.Devanagari)

    else
      Inc(Result.Other);
  end;

  if Result.Total = 0 then
  begin
    Result.Script := stOther;   // keep script explicit for compiler hint
    Exit;
  end;

  if Result.Latin / Result.Total > 0.60 then
  begin
    Result.Script := stLatin;
    Exit;
  end;

  if Result.Cyrillic / Result.Total > 0.50 then
  begin
    Result.Script := stCyrillic;
    Exit;
  end;

  if Result.Arabic / Result.Total > 0.50 then
  begin
    Result.Script := stArabic;
    Exit;
  end;

  if Result.Greek / Result.Total > 0.50 then
  begin
    Result.Script := stGreek;
    Exit;
  end;

  if Result.Hebrew / Result.Total > 0.50 then
  begin
    Result.Script := stHebrew;
    Exit;
  end;

  if Result.Devanagari / Result.Total > 0.50 then
  begin
    Result.Script := stDevanagari;
    Exit;
  end;

  if (Result.Han + Result.Hiragana + Result.Katakana + Result.Hangul) / Result.Total > 0.30 then
  begin
    Result.Script := stCJK;
    Exit;
  end;

  Result.Script := stOther;
end;

// Checks if language code matches current script
function IsLanguageMatchingScript(const Code: string; Script: TScriptType): boolean;
begin
  case Script of
    stLatin:
      // All codes are allowed EXCEPT those known to be non-Latin scripts
      Result := not ((Code = 'ru') or (Code = 'uk') or (Code = 'be') or (Code = 'bg') or (Code = 'sr') or
        (Code = 'mk') or (Code = 'kk') or (Code = 'ky') or (Code = 'mn') or   // Cyrillic (may add more if needed)
        (Code = 'ar') or (Code = 'fa') or (Code = 'ur') or (Code = 'ps') or (Code = 'sd') or (Code = 'ug') or // Arabic
        (Code = 'el') or   // Greek
        (Code = 'he') or (Code = 'iw') or (Code = 'yi') or // Hebrew
        (Code = 'hi') or (Code = 'mr') or (Code = 'ne') or (Code = 'sa') or   // Devanagari
        (Code = 'zh') or (Code = 'zh-CN') or (Code = 'zh-TW') or (Code = 'ja') or (Code = 'ko') or // CJK
        (Code = 'am') or (Code = 'as') or (Code = 'bn') or (Code = 'gu') or (Code = 'kn') or (Code = 'ml') or
        (Code = 'or') or (Code = 'pa') or (Code = 'ta') or (Code = 'te') or (Code = 'th') or (Code = 'lo') or
        (Code = 'my') or (Code = 'km') or (Code = 'si') or (Code = 'ka') or (Code = 'hy')   // scripts not Latin (Ge'ez, Indic, Thai, etc.)
        );
    stCyrillic:
      // For Cyrillic, allow all except known non-Cyrillic
      Result := not ((Code = 'ar') or (Code = 'fa') or (Code = 'ur') or (Code = 'ps') or (Code = 'sd') or
        (Code = 'ug') or (Code = 'el') or (Code = 'he') or (Code = 'iw') or (Code = 'yi') or (Code = 'hi') or
        (Code = 'mr') or (Code = 'ne') or (Code = 'sa') or (Code = 'zh') or (Code = 'zh-CN') or (Code = 'zh-TW') or
        (Code = 'ja') or (Code = 'ko') or (Code = 'am') or (Code = 'as') or (Code = 'bn') or (Code = 'gu') or
        (Code = 'kn') or (Code = 'ml') or (Code = 'or') or (Code = 'pa') or (Code = 'ta') or (Code = 'te') or
        (Code = 'th') or (Code = 'lo') or (Code = 'my') or (Code = 'km') or (Code = 'si') or (Code = 'ka') or
        (Code = 'hy') or (Code = 'en') or (Code = 'de') or (Code = 'fr') or // Latin family
        (Code = 'es') or (Code = 'pt') or (Code = 'it') or (Code = 'nl') or (Code = 'sv') or (Code = 'no') or
        (Code = 'da') or (Code = 'fi') or (Code = 'hu') or (Code = 'ro') or (Code = 'cs') or (Code = 'pl') or
        (Code = 'tr') or (Code = 'id') or (Code = 'ms') or (Code = 'vi') or (Code = 'sk') or (Code = 'sl') or
        (Code = 'hr') or (Code = 'lt') or (Code = 'lv'));
    stArabic:
      Result := not ((Code = 'ru') or (Code = 'uk') or (Code = 'be') or (Code = 'bg') or (Code = 'sr') or
        (Code = 'mk') or (Code = 'kk') or (Code = 'ky') or (Code = 'mn') or (Code = 'el') or (Code = 'he') or
        (Code = 'iw') or (Code = 'yi') or (Code = 'hi') or (Code = 'mr') or (Code = 'ne') or (Code = 'sa') or
        (Code = 'zh') or (Code = 'zh-CN') or (Code = 'zh-TW') or (Code = 'ja') or (Code = 'ko') or (Code = 'am') or
        (Code = 'as') or (Code = 'bn') or (Code = 'gu') or (Code = 'kn') or (Code = 'ml') or (Code = 'or') or
        (Code = 'pa') or (Code = 'ta') or (Code = 'te') or (Code = 'th') or (Code = 'lo') or (Code = 'my') or
        (Code = 'km') or (Code = 'si') or (Code = 'ka') or (Code = 'hy') or (Code = 'en') or (Code = 'de') or
        (Code = 'fr') or (Code = 'es') or (Code = 'pt') or (Code = 'it') or (Code = 'nl') or (Code = 'sv') or
        (Code = 'no') or (Code = 'da') or (Code = 'fi') or (Code = 'hu') or (Code = 'ro') or (Code = 'cs') or
        (Code = 'pl') or (Code = 'tr') or (Code = 'id') or (Code = 'ms') or (Code = 'vi') or (Code = 'sk') or
        (Code = 'sl') or (Code = 'hr') or (Code = 'lt') or (Code = 'lv'));
    stGreek: Result := (Code = 'el');
    stHebrew: Result := (Code = 'he') or (Code = 'iw') or (Code = 'yi');
    stDevanagari:
      Result := (Code = 'hi') or (Code = 'mr') or (Code = 'ne') or (Code = 'sa');
    stCJK: Result := (Code = 'zh') or (Code = 'zh-CN') or (Code = 'zh-TW') or (Code = 'ja') or (Code = 'ko');
    else
      Result := True;
  end;
end;

//  Check if a UTF-8 character is in the CJK (Chinese/Japanese/Korean) range
function IsCJK(const s: string): boolean;
var
  cp: UCS4Char;
  CharLen: integer;
begin
  if s = '' then Exit(False);
  CharLen := 0;
  cp := UTF8CodepointToUnicode(@s[1], CharLen);
  Result :=
    // CJK Unified Ideographs (Chinese)
    ((cp >= $4E00) and (cp <= $9FFF)) or ((cp >= $3400) and (cp <= $4DBF)) or ((cp >= $20000) and (cp <= $2A6DF)) or
    // Hiragana & Katakana (Japanese)
    ((cp >= $3040) and (cp <= $30FF)) or
    // Hangul Syllables (Korean)
    ((cp >= $AC00) and (cp <= $D7AF));
end;

// Frequency-aware distance (lower = better).
// Uses binary search on SortedTrigrams if available, otherwise falls back to linear search.
function DistanceToProfile(const TextTrigrams: TStringArray; const Profile: TProfile): double;
const
  MISSING_PENALTY = 100;               // penalty for a trigram not found
var
  i, j: integer;
  score: integer;
  freq: integer;
  tested: integer;
  L, R, M: integer;
begin
  score := 0;
  tested := 0;
  if Length(Profile.SortedTrigrams) > 0 then
  begin
    // Binary search on sorted trigram list
    for i := 0 to High(TextTrigrams) do
    begin
      L := 0;
      R := Length(Profile.SortedTrigrams) - 1;
      freq := -1;
      while L <= R do
      begin
        M := (L + R) div 2;
        if Profile.SortedTrigrams[M].Trig = TextTrigrams[i] then
        begin
          freq := Profile.SortedTrigrams[M].Weight;
          Break;
        end
        else if Profile.SortedTrigrams[M].Trig < TextTrigrams[i] then
          L := M + 1
        else
          R := M - 1;
      end;
      if freq >= 0 then
        Dec(score, freq)
      else
        Inc(score, MISSING_PENALTY);
      Inc(tested);
    end;
  end
  else
  begin
    // Fallback to original linear search for profiles without sorted list (built‑in defaults)
    for i := 0 to High(TextTrigrams) do
    begin
      freq := -1;
      for j := 0 to High(Profile.Trigrams) do
        if Profile.Trigrams[j] = TextTrigrams[i] then
        begin
          if j < Length(Profile.Freqs) then
            freq := Profile.Freqs[j]
          else
            freq := 100 - j;   // approximate positional weight when Freqs missing
          Break;
        end;
      if freq >= 0 then
        Dec(score, freq)
      else
        Inc(score, MISSING_PENALTY);
      Inc(tested);
    end;
  end;

  if tested = 0 then
    Result := MISSING_PENALTY
  else
    Result := score / tested;
end;

// Detects script, refines CJK classification, and returns script info.
// No language-specific fast rules here – all of that is now in ApplyPostCorrection.
function QuickScriptDetection(const AText: string; var Info: TScriptInfo; var Script: TScriptType; out Confidence: double): string;
begin
  Result := '';          // we never exit early with a language code
  Confidence := 0.0;
  Info := DetectScript(AText);
  Script := Info.Script;

  // CJK script refinement (avoid mis-classification due to punctuation or stray kana)
  if (Script <> stCJK) and (Info.Han >= 5) and (Info.Hangul = 0) and (Info.Latin / Info.Total < 0.5) then
  begin
    Script := stCJK;
    Info.Hiragana := 0;
    Info.Katakana := 0;
  end
  else if (Script = stCJK) and (Info.Hangul = 0) and (Info.Han > 0) then
  begin
    if (Info.Hiragana + Info.Katakana) < 5 then
    begin
      Info.Hiragana := 0;
      Info.Katakana := 0;
    end;
  end;
end;

// Post-correction for language pairs that trigrams alone have trouble separating.
// Only fires when the current best guess belongs to one of the problematic pairs,
// and then uses unique characters or high-frequency words to decide.
procedure ApplyPostCorrection(var Code: string; var Confidence: double; const AText: string);
begin
  // Norwegian vs Danish vs Swedish
  if (Code = 'no') or (Code = 'da') or (Code = 'sv') then
  begin
    // Unique letter for Swedish
    if Pos('ä', AText) > 0 then
    begin
      Code := 'sv';
      Confidence := 1.0;
      Exit;
    end;
    // Danish/Norwegian have æ/ø, Swedish doesn't
    if (Pos('æ', AText) > 0) or (Pos('ø', AText) > 0) then
    begin
      if Pos('dere', AText) > 0 then
        Code := 'no'
      else if Pos('af', AText) > 0 then
        Code := 'da'
      else if Pos('av', AText) > 0 then
        Code := 'no';
      Confidence := 1.0;
      Exit;
    end;
    // Fallback to frequent words
    if (Pos('och', AText) > 0) or (Pos('är', AText) > 0) or (Pos('inte', AText) > 0) then
      Code := 'sv'
    else if (Pos('seg', AText) > 0) or (Pos('dere', AText) > 0) then
      Code := 'no'
    else if (Pos('sig', AText) > 0) or (Pos('af', AText) > 0) then
      Code := 'da';
    Confidence := 1.0;
    Exit;
  end;

  // Xhosa vs Zulu
  if (Code = 'xh') or (Code = 'zu') then
  begin
    if Pos('xh', AText) > 0 then
    begin
      Code := 'xh';
      Confidence := 1.0;
      Exit;
    end;
    // If no 'xh', keep the trigram result (could be zu or xh)
  end;

  // Belarusian vs others (unique letter 'ў')
  if (Code = 'be') or (Code = 'uk') or (Code = 'ru') then
  begin
    if (Pos('ў', AText) > 0) or (Pos('Ў', AText) > 0) then
    begin
      Code := 'be';
      Confidence := 1.0;
      Exit;
    end;
  end;

  // Bulgarian vs Macedonian (both use 'ъ', but bg lacks 'ы','ё','э')
  if (Code = 'bg') or (Code = 'mk') then
  begin
    if (Pos('ъ', AText) > 0) and (Pos('ы', AText) = 0) and (Pos('ё', AText) = 0) and (Pos('э', AText) = 0) then
    begin
      Code := 'bg';
      Confidence := 1.0;
      Exit;
    end
    else if (Pos('ѓ', AText) > 0) or (Pos('ќ', AText) > 0) then
    begin
      Code := 'mk';
      Confidence := 1.0;
      Exit;
    end;
  end;

  // Ukrainian vs Russian
  if (Code = 'uk') or (Code = 'ru') then
  begin
    if (Pos('ї', AText) > 0) or (Pos('є', AText) > 0) or (Pos('ґ', AText) > 0) or (Pos('Ї', AText) > 0) or
      (Pos('Є', AText) > 0) or (Pos('Ґ', AText) > 0) then
    begin
      Code := 'uk';
      Confidence := 1.0;
      Exit;
    end;
  end;

  // Spanish vs Galician vs Portuguese
  if (Code = 'es') or (Code = 'gl') or (Code = 'pt') then
  begin
    // Strong markers for Portuguese
    if (Pos('ç', AText) > 0) or (Pos('ão', AText) > 0) then
    begin
      Code := 'pt';
      Confidence := 1.0;
      Exit;
    end;
    // Strong marker for Spanish: letter ñ
    if Pos('ñ', AText) > 0 then
    begin
      Code := 'es';
      Confidence := 1.0;
      Exit;
    end;
    // Galician indicators – specific unique words
    if (Pos('non', AText) > 0) or (Pos('galego', AText) > 0) or (Pos('nós', AText) > 0) or (Pos('vós', AText) > 0) or
      (Pos('unha', AText) > 0) or (Pos('dúas', AText) > 0) then
    begin
      Code := 'gl';
      Confidence := 1.0;
      Exit;
    end;
    // Article-based heuristic: Galician uses "o"/"a" as definite articles,
    // Spanish uses "el"/"la". Absence of Spanish articles and presence of
    // "o" or "a" as separate words (with spaces) suggests Galician.
    if (Pos(' o ', AText) > 0) or (Pos(' a ', AText) > 0) then
    begin
      if (Pos(' el ', AText) = 0) and (Pos(' la ', AText) = 0) and (Pos(' los ', AText) = 0) and (Pos(' las ', AText) = 0) then
      begin
        // No Spanish articles found, and no ñ – strong indication of Galician
        Code := 'gl';
        Confidence := 0.9;
        Exit;
      end
      else
      begin
        // Spanish articles present – it's Spanish
        Code := 'es';
        Confidence := 0.9;
        Exit;
      end;
    end;
    // If no markers, keep the original trigram result (likely es)
  end;

  // Czech vs Slovak (very close, but Slovak has 'ä', 'ô', 'ŕ', 'ĺ')
  if (Code = 'cs') or (Code = 'sk') then
  begin
    if (Pos('ä', AText) > 0) or (Pos('ô', AText) > 0) or (Pos('ŕ', AText) > 0) or (Pos('ĺ', AText) > 0) then
    begin
      Code := 'sk';
      Confidence := 1.0;
      Exit;
    end
    else if (Pos('ř', AText) > 0) or (Pos('ů', AText) > 0) then
    begin
      Code := 'cs';
      Confidence := 1.0;
      Exit;
    end;
  end;

  // Chinese Simplified vs Traditional
  if (Code = 'zh-CN') or (Code = 'zh-TW') then
  begin
    // If the text contains any Traditional-only character, it's zh-TW
    // Very few unique ones can be checked quickly
    if (Pos('國', AText) > 0) or (Pos('體', AText) > 0) or (Pos('門', AText) > 0) or (Pos('機', AText) > 0) or
      (Pos('關', AText) > 0) then  // high-freq trad chars
    begin
      Code := 'zh-TW';
      Confidence := 1.0;
      Exit;
    end;
  end;
end;

{%EndRegion}

{%Region -fold Public Methods}

//  Extract character trigrams from a UTF-8 text
//  For texts dominated by CJK characters, spaces are ignored.
function ExtractCharTrigrams(const AText: string): TStringArray;
const
  CJK_SAMPLE_SIZE = 200;
var
  s: string;
  chars: array of string = nil;
  i, p, charLen, actualCharCount: integer;
  ch: string;
  totalCount, cjkCount: integer;
  skipSpaces: boolean;
begin
  Result := nil;
  s := UTF8LowerCase(AText);

  // First pass: decide whether to ignore spaces (CJK heuristic)
  cjkCount := 0;
  totalCount := 0;
  p := 1;
  while (p <= Length(s)) and (totalCount < CJK_SAMPLE_SIZE) do
  begin
    {$NOTES OFF}
    charLen := UTF8CodepointSize(@s[p]);
    {$NOTES ON}
    if charLen = 0 then Inc(p)
    else
    begin
      ch := Copy(s, p, charLen);
      Inc(p, charLen);
      if ch = ' ' then Continue;
      if ((ch[1] >= 'A') and (ch[1] <= 'Z')) or ((ch[1] >= 'a') and (ch[1] <= 'z')) or (Ord(ch[1]) >= $C0) then
      begin
        Inc(totalCount);
        if IsCJK(ch) then Inc(cjkCount);
      end;
    end;
  end;
  // Require a minimum number of characters before deciding to ignore spaces
  skipSpaces := (totalCount >= 10) and (cjkCount >= 5) and (cjkCount / totalCount > 0.5);

  // Second pass: build character list
  SetLength(chars, Length(s));
  actualCharCount := 0;
  p := 1;
  while p <= Length(s) do
  begin
    {$NOTES OFF}
    charLen := UTF8CodepointSize(@s[p]);
    {$NOTES ON}
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
    if ((ch[1] >= 'A') and (ch[1] <= 'Z')) or ((ch[1] >= 'a') and (ch[1] <= 'z')) or (Ord(ch[1]) >= $C0) then
    begin
      chars[actualCharCount] := ch;
      Inc(actualCharCount);
    end
    else
    begin
      // For non-CJK texts: simply skip punctuation instead of inserting a space.
      // This matches the behaviour of the generator's CleanText.
      if not skipSpaces then
      begin
        // Do nothing – the character is ignored (removed).
        // Words will be concatenated, exactly as they were when building the profiles.
      end;
    end;
  end;
  SetLength(chars, actualCharCount);

  if Length(chars) < 3 then Exit;
  SetLength(Result, Length(chars) - 2);
  for i := 0 to High(Result) do
    Result[i] := chars[i] + chars[i + 1] + chars[i + 2];
end;

function DetectLanguageForText(const AText: string): string;
var
  dummy: double;
begin
  Result := DetectLanguageWithConfidence(AText, dummy);
end;

function DetectLanguageWithConfidence(const AText: string; out Confidence: double): string;
var
  textTrigrams: TStringArray;
  i, bestIdx, secondIdx: integer;
  bestDist, secondDist, currentDist: double;
  ScriptInfo: TScriptInfo;
  Script: TScriptType = stOther;

  function IsCJKCodeAllowed(const Code: string): boolean;
  begin
    if (ScriptInfo.Hiragana > 0) or (ScriptInfo.Katakana > 0) then
      Result := (Code = 'ja')
    else if ScriptInfo.Hangul > 0 then
      Result := (Code = 'ko')
    else
      Result := (Code = 'zh') or (Code = 'zh-CN');
  end;

begin
  ScriptInfo := Default(TScriptInfo);
  Confidence := 0.0;
  if Length(AText) < 3 then Exit('unknown');

  // 1. Quick script detection + CJK refinement
  Result := QuickScriptDetection(AText, ScriptInfo, Script, Confidence);
  if Result <> '' then Exit;

  // 2. Extract trigrams
  textTrigrams := ExtractCharTrigrams(AText);
  if Length(textTrigrams) = 0 then
    Exit('unknown');

  // 3. Main trigram-based matching
  bestDist := 1e9;
  bestIdx := -1;
  secondDist := 1e9;
  secondIdx := -1;

  for i := 0 to High(Profiles) do
  begin
    if Script = stCJK then
    begin
      if not IsCJKCodeAllowed(Profiles[i].Code) then
        Continue;
    end
    else
    begin
      if not IsLanguageMatchingScript(Profiles[i].Code, Script) then
        Continue;
    end;

    currentDist := DistanceToProfile(textTrigrams, Profiles[i]);

    if currentDist < bestDist then
    begin
      secondDist := bestDist;
      secondIdx := bestIdx;
      bestDist := currentDist;
      bestIdx := i;
    end
    else if currentDist < secondDist then
    begin
      secondDist := currentDist;
      secondIdx := i;
    end;
  end;

  // Fallback: no script match – compare against all profiles
  if bestIdx = -1 then
  begin
    for i := 0 to High(Profiles) do
    begin
      currentDist := DistanceToProfile(textTrigrams, Profiles[i]);
      if currentDist < bestDist then
      begin
        secondDist := bestDist;
        secondIdx := bestIdx;
        bestDist := currentDist;
        bestIdx := i;
      end
      else if currentDist < secondDist then
      begin
        secondDist := currentDist;
        secondIdx := i;
      end;
    end;
  end;

  // 4. Build result and confidence
  if bestIdx >= 0 then
  begin
    Result := Profiles[bestIdx].Code;
    if (secondIdx >= 0) and (bestDist + secondDist > 0) then
      Confidence := 1.0 - (bestDist / (bestDist + secondDist))
    else
      Confidence := 1.0;
  end
  else
  begin
    Result := 'unknown';
    Confidence := 0.0;
  end;

  // 5. Post-correction for difficult pairs
  ApplyPostCorrection(Result, Confidence, AText);
end;

{%EndRegion}

{%Region -fold Merge Profiles}

//  Default profiles (defined in separate include file)
{$include langprofiles_data.inc}

// Internal routine that does the actual merge from any TStream
procedure MergeProfilesFromStream(AStream: TStream);
const
  MAX_TRIGRAMS = 1000;
  MAGIC_COMPRESSED: cardinal = $4F525047; // 'GPRO' in little-endian
var
  magic: cardinal;
  isCompressed: boolean;
  totalLangs, Count: integer;
  i, j, k, trigCount, existingIdx: integer;
  codeLen: integer;
  code: string = string.Empty;
  trigLen: integer;
  trig: string = string.Empty;
  freq: word;
  fileProfiles: array of TProfile = ();
  comprSize: cardinal;
  tempStream: TMemoryStream;
  plainStream: TMemoryStream;
  entry: TTrigEntry;
begin
  // Detect format: if first 4 bytes are 'GPRO', it's compressed
  magic := 0;
  AStream.ReadBuffer(magic, SizeOf(magic));
  isCompressed := (magic = MAGIC_COMPRESSED);

  if isCompressed then
  begin
    // Compressed format: read totalLangs, then per-language compressed blocks
    totalLangs := 0;
    AStream.ReadBuffer(totalLangs, SizeOf(totalLangs));
    Count := totalLangs;
  end
  else
  begin
    // Old uncompressed format: first 4 bytes were already totalLangs
    Count := integer(magic);
  end;

  SetLength(fileProfiles, Count);
  for i := 0 to Count - 1 do
  begin
    if isCompressed then
    begin
      // Read compressed size and decompress the block into a memory stream
      comprSize := 0;
      AStream.ReadBuffer(comprSize, SizeOf(comprSize));
      if (comprSize <= 0) or (comprSize > AStream.Size - AStream.Position) then
        raise Exception.Create('Invalid compressed size');
      tempStream := TMemoryStream.Create;
      try
        tempStream.CopyFrom(AStream, comprSize);
        tempStream.Position := 0;
        plainStream := TOS.DecompressMemoryStream(tempStream);
        try
          plainStream.Position := 0;
          // Now read language data from plainStream
          codeLen := 0;
          plainStream.ReadBuffer(codeLen, SizeOf(codeLen));
          SetLength(code, codeLen);
          if codeLen > 0 then
            plainStream.ReadBuffer(code[1], codeLen);
          fileProfiles[i].Code := code;

          trigCount := 0;
          plainStream.ReadBuffer(trigCount, SizeOf(trigCount));
          if trigCount > MAX_TRIGRAMS then
          begin
            fileProfiles[i].Code := '';
            Continue;
          end;
          SetLength(fileProfiles[i].Trigrams, trigCount);
          SetLength(fileProfiles[i].Freqs, trigCount);
          for j := 0 to trigCount - 1 do
          begin
            trigLen := 0;
            plainStream.ReadBuffer(trigLen, SizeOf(trigLen));
            SetLength(trig, trigLen);
            if trigLen > 0 then
              plainStream.ReadBuffer(trig[1], trigLen);
            fileProfiles[i].Trigrams[j] := trig;

            freq := 0;
            plainStream.ReadBuffer(freq, SizeOf(freq));
            fileProfiles[i].Freqs[j] := freq;
          end;
        finally
          plainStream.Free;
        end;
      finally
        tempStream.Free;
      end;
    end
    else
    begin
      // Old uncompressed code (unchanged)
      codeLen := 0;
      AStream.ReadBuffer(codeLen, SizeOf(codeLen));
      SetLength(code, codeLen);
      if codeLen > 0 then
        AStream.ReadBuffer(code[1], codeLen);
      fileProfiles[i].Code := code;

      trigCount := 0;
      AStream.ReadBuffer(trigCount, SizeOf(trigCount));
      if trigCount > MAX_TRIGRAMS then
      begin
        for j := 0 to trigCount - 1 do
        begin
          trigLen := 0;
          AStream.ReadBuffer(trigLen, SizeOf(trigLen));
          if trigLen > 0 then
            AStream.Seek(trigLen + SizeOf(freq), soFromCurrent);
        end;
        fileProfiles[i].Code := '';
        Continue;
      end;

      SetLength(fileProfiles[i].Trigrams, trigCount);
      SetLength(fileProfiles[i].Freqs, trigCount);
      for j := 0 to trigCount - 1 do
      begin
        trigLen := 0;
        AStream.ReadBuffer(trigLen, SizeOf(trigLen));
        SetLength(trig, trigLen);
        if trigLen > 0 then
          AStream.ReadBuffer(trig[1], trigLen);
        fileProfiles[i].Trigrams[j] := trig;

        freq := 0;
        AStream.ReadBuffer(freq, SizeOf(freq));
        fileProfiles[i].Freqs[j] := freq;
      end;
    end;

    // Build sorted trigram list for binary search
    if trigCount > 0 then
    begin
      SetLength(fileProfiles[i].SortedTrigrams, trigCount);
      for j := 0 to trigCount - 1 do
      begin
        fileProfiles[i].SortedTrigrams[j].Trig := fileProfiles[i].Trigrams[j];
        fileProfiles[i].SortedTrigrams[j].Weight := fileProfiles[i].Freqs[j];
      end;
      // Sort alphabetically (bubble sort – fast enough for one-time init of 2000 items)
      for j := 0 to trigCount - 2 do
        for k := j + 1 to trigCount - 1 do
          if fileProfiles[i].SortedTrigrams[j].Trig > fileProfiles[i].SortedTrigrams[k].Trig then
          begin
            entry := fileProfiles[i].SortedTrigrams[j];
            fileProfiles[i].SortedTrigrams[j] := fileProfiles[i].SortedTrigrams[k];
            fileProfiles[i].SortedTrigrams[k] := entry;
          end;
    end;
  end;

  // Merge into global Profiles
  for i := 0 to High(fileProfiles) do
  begin
    if fileProfiles[i].Code = '' then Continue;
    existingIdx := -1;
    for j := 0 to High(Profiles) do
      if Profiles[j].Code = fileProfiles[i].Code then
      begin
        existingIdx := j;
        Break;
      end;
    if existingIdx >= 0 then
    begin
      Profiles[existingIdx].Trigrams := fileProfiles[i].Trigrams;
      Profiles[existingIdx].Freqs := fileProfiles[i].Freqs;
      Profiles[existingIdx].SortedTrigrams := fileProfiles[i].SortedTrigrams;
    end
    else
    begin
      SetLength(Profiles, Length(Profiles) + 1);
      Profiles[High(Profiles)] := fileProfiles[i];
    end;
  end;
end;

// Public wrapper for file-based loading
procedure MergeProfilesFromFile(const FileName: string);
var
  fs: TFileStream;
begin
  if not FileExists(FileName) then Exit;
  fs := TFileStream.Create(FileName, fmOpenRead);
  try
    MergeProfilesFromStream(fs);
  finally
    fs.Free;
  end;
end;

{%EndRegion}

{%Region -fold Initialization}
var
  ExePath: string;
  ResStream: TResourceStream;

initialization
  InitDefaultProfiles;

  // Do not attempt to load external profiles when the language profile
  // generator (langprofiles) is running with the 'gen' command.
  // The generator only uses the trigram extraction routines and does not
  // need detection profiles – a corrupted output file must not prevent it
  // from starting.
  if (LowerCase(ExtractFileName(ParamStr(0))) = 'langprofiles') or (LowerCase(ExtractFileName(ParamStr(0))) = 'langprofiles.exe') then
  begin
    if (ParamCount >= 1) and SameText(ParamStr(1), 'gen') then
      Exit;   // Generator mode – skip external profile loading
  end;

  ExePath := ExtractFilePath(ParamStr(0));
  if FileExists(ExePath + 'langprofiles.dat') then
    MergeProfilesFromFile(ExePath + 'langprofiles.dat')
  else if FileExists(IncludeTrailingPathDelimiter(ExePath + 'corpus') + 'langprofiles.dat') then
    MergeProfilesFromFile(IncludeTrailingPathDelimiter(ExePath + 'corpus') + 'langprofiles.dat')
  else
  begin
    if FindResource(HInstance, 'LANGPROFILES', RT_RCDATA) <> 0 then
    begin
      ResStream := TResourceStream.Create(HInstance, 'LANGPROFILES', RT_RCDATA);
      try
        MergeProfilesFromStream(ResStream);
      finally
        ResStream.Free;
      end;
    end;
  end;

  {%EndRegion}
end.
