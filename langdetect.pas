//-----------------------------------------------------------------------------------
//  Trayslate © 2026 by Alexander Tverskoy
//  Licensed under the GNU General Public License, Version 3 (GPL-3.0)
//  You may obtain a copy of the License at https://www.gnu.org/licenses/gpl-3.0.html
//-----------------------------------------------------------------------------------
//  uLangDetect.pas  –  Fast language detection using character trigrams
//                      and frequent-word dictionaries for short/ambiguous texts.
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
  Math,
  LCLType,
  LazUTF8,
  osutils;

  {%Region -fold Types}

type
  TStringArray = array of string;
  TWordWeightArray = array of word;   // dynamic array for word weights

  TProfile = record
    Code: string;
    Trigrams: TStringArray;   // sorted by frequency, most frequent first
    Freqs: array of word;     // corresponding frequency values (same order)
    Wrds: TStringArray;       // top frequent words (renamed to avoid conflict with 'Word')
    WrdFreqs: TWordWeightArray; // positional weights for words
    Priority: word;           // lower = more common, used for tie‑breaking
  end;

  TScriptType = (
    stLatin,
    stCyrillic,
    stArabic,
    stGreek,
    stHebrew,
    stCJK,
    stDevanagari,
    stBengali,
    stGurmukhi,
    stGujarati,
    stOriya,
    stTamil,
    stTelugu,
    stKannada,
    stMalayalam,
    stSinhala,
    stThai,
    stLao,
    stMyanmar,
    stKhmer,
    stTibetan,
    stGeorgian,
    stArmenian,
    stEthiopic,
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
    Bengali: integer;
    Gurmukhi: integer;
    Gujarati: integer;
    Oriya: integer;
    Tamil: integer;
    Telugu: integer;
    Kannada: integer;
    Malayalam: integer;
    Sinhala: integer;
    Thai: integer;
    Lao: integer;
    Myanmar: integer;
    Khmer: integer;
    Tibetan: integer;
    Georgian: integer;
    Armenian: integer;
    Ethiopic: integer;
    Other: integer;
    Total: integer;
  end;

var
  Profiles: array of TProfile;

const
  UNKNOWN = 'unknown';

  {%EndRegion}

//  Extract character trigrams from a UTF-8 text
//  For texts dominated by CJK characters, spaces are ignored.
function ExtractCharTrigrams(const AText: string): TStringArray;

// Safe language detection with optional current language hint.
// If a current language is provided and confidence is below MinConfidence
// but above 0.30, the result will still be accepted if the script of the
// detected language differs from the script of the current language.
function DetectLanguageSafe(const AText: string; ACurrentLang: string = ''; MinConfidence: double = 0.5): string;

// Returns language code (e.g. 'en', 'ru') or UNKNOWN
function DetectLanguageForText(const AText: string): string;

// Also returns a confidence value between 0.0 and 1.0
function DetectLanguageWithConfidence(const AText: string; out Confidence: double): string;

// Public wrapper for file-based loading
procedure MergeProfilesFromFile(const FileName: string);

implementation

{%Region -fold Private Methods}

// Script detection by text
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

    if ch = ' ' then Continue;
    if ((ch[1] >= '0') and (ch[1] <= '9')) then Continue;

    Inc(Result.Total);

    if ((ch[1] >= 'A') and (ch[1] <= 'Z')) or ((ch[1] >= 'a') and (ch[1] <= 'z')) then
    begin
      Inc(Result.Latin);
      Continue;
    end;

    cp := UTF8CodepointToUnicode(PChar(ch), CharLen);

    // Extended Latin
    if ((cp >= $00C0) and (cp <= $024F)) or ((cp >= $1E00) and (cp <= $1EFF)) or ((cp >= $2C60) and (cp <= $2C7F)) then
      Inc(Result.Latin)
    // Cyrillic
    else if (cp >= $0400) and (cp <= $04FF) then
      Inc(Result.Cyrillic)
    // Arabic
    else if ((cp >= $0600) and (cp <= $06FF)) or ((cp >= $0750) and (cp <= $077F)) then
      Inc(Result.Arabic)
    // Han
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
    // Bengali (includes Assamese)
    else if (cp >= $0980) and (cp <= $09FF) then
      Inc(Result.Bengali)
    // Gurmukhi (Punjabi)
    else if (cp >= $0A00) and (cp <= $0A7F) then
      Inc(Result.Gurmukhi)
    // Gujarati
    else if (cp >= $0A80) and (cp <= $0AFF) then
      Inc(Result.Gujarati)
    // Oriya
    else if (cp >= $0B00) and (cp <= $0B7F) then
      Inc(Result.Oriya)
    // Tamil
    else if (cp >= $0B80) and (cp <= $0BFF) then
      Inc(Result.Tamil)
    // Telugu
    else if (cp >= $0C00) and (cp <= $0C7F) then
      Inc(Result.Telugu)
    // Kannada
    else if (cp >= $0C80) and (cp <= $0CFF) then
      Inc(Result.Kannada)
    // Malayalam
    else if (cp >= $0D00) and (cp <= $0D7F) then
      Inc(Result.Malayalam)
    // Sinhala
    else if (cp >= $0D80) and (cp <= $0DFF) then
      Inc(Result.Sinhala)
    // Thai
    else if (cp >= $0E00) and (cp <= $0E7F) then
      Inc(Result.Thai)
    // Lao
    else if (cp >= $0E80) and (cp <= $0EFF) then
      Inc(Result.Lao)
    // Myanmar
    else if (cp >= $1000) and (cp <= $109F) then
      Inc(Result.Myanmar)
    // Khmer
    else if (cp >= $1780) and (cp <= $17FF) then
      Inc(Result.Khmer)
    // Georgian
    else if (cp >= $10A0) and (cp <= $10FF) then
      Inc(Result.Georgian)
    // Armenian
    else if (cp >= $0530) and (cp <= $058F) then
      Inc(Result.Armenian)
    // Ethiopic (Amharic, etc.)
    else if (cp >= $1200) and (cp <= $137F) then
      Inc(Result.Ethiopic)
    // Tibetan
    else if (cp >= $0F00) and (cp <= $0FFF) then
      Inc(Result.Tibetan)
    else
      Inc(Result.Other);
  end;

  if Result.Total = 0 then
  begin
    Result.Script := stOther;
    Exit;
  end;

  // Determine dominant script (ordered by specificity: non-Latin scripts first)
  if Result.Bengali / Result.Total > 0.50 then
  begin
    Result.Script := stBengali;
    Exit;
  end;
  if Result.Gurmukhi / Result.Total > 0.50 then
  begin
    Result.Script := stGurmukhi;
    Exit;
  end;
  if Result.Gujarati / Result.Total > 0.50 then
  begin
    Result.Script := stGujarati;
    Exit;
  end;
  if Result.Oriya / Result.Total > 0.50 then
  begin
    Result.Script := stOriya;
    Exit;
  end;
  if Result.Tamil / Result.Total > 0.50 then
  begin
    Result.Script := stTamil;
    Exit;
  end;
  if Result.Telugu / Result.Total > 0.50 then
  begin
    Result.Script := stTelugu;
    Exit;
  end;
  if Result.Kannada / Result.Total > 0.50 then
  begin
    Result.Script := stKannada;
    Exit;
  end;
  if Result.Malayalam / Result.Total > 0.50 then
  begin
    Result.Script := stMalayalam;
    Exit;
  end;
  if Result.Sinhala / Result.Total > 0.50 then
  begin
    Result.Script := stSinhala;
    Exit;
  end;
  if Result.Thai / Result.Total > 0.50 then
  begin
    Result.Script := stThai;
    Exit;
  end;
  if Result.Lao / Result.Total > 0.50 then
  begin
    Result.Script := stLao;
    Exit;
  end;
  if Result.Myanmar / Result.Total > 0.50 then
  begin
    Result.Script := stMyanmar;
    Exit;
  end;
  if Result.Khmer / Result.Total > 0.50 then
  begin
    Result.Script := stKhmer;
    Exit;
  end;
  if Result.Georgian / Result.Total > 0.50 then
  begin
    Result.Script := stGeorgian;
    Exit;
  end;
  if Result.Armenian / Result.Total > 0.50 then
  begin
    Result.Script := stArmenian;
    Exit;
  end;
  if Result.Ethiopic / Result.Total > 0.50 then
  begin
    Result.Script := stEthiopic;
    Exit;
  end;

  if Result.Tibetan / Result.Total > 0.50 then
  begin
    Result.Script := stTibetan;
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

// Returns the primary script associated with a language code.
function GetScriptByLang(const Code: string): TScriptType;
begin
  // Cyrillic
  if (Code = 'ru') or (Code = 'uk') or (Code = 'be') or (Code = 'bg') or (Code = 'sr') or (Code = 'mk') or
    (Code = 'kk') or (Code = 'ky') or (Code = 'mn') or (Code = 'tg') or (Code = 'tt') or (Code = 'ba') or
    (Code = 'cv') or (Code = 'os') or (Code = 'sah') or (Code = 'xal') or (Code = 'ab') or (Code = 'ce') or
    (Code = 'av') or (Code = 'udm') then
    Exit(stCyrillic);

  // Arabic
  if (Code = 'ar') or (Code = 'fa') or (Code = 'ur') or (Code = 'ps') or (Code = 'sd') or (Code = 'ug') or
    (Code = 'ckb') or (Code = 'prs') or (Code = 'ku') or (Code = 'azb') then
    Exit(stArabic);

  // CJK
  if (Code = 'zh') or (Code = 'zh-CN') or (Code = 'zh-TW') or (Code = 'ja') or (Code = 'ko') or (Code = 'yue') then
    Exit(stCJK);

  // Greek
  if (Code = 'el') then Exit(stGreek);

  // Hebrew
  if (Code = 'he') or (Code = 'iw') or (Code = 'yi') then Exit(stHebrew);

  // Devanagari
  if (Code = 'hi') or (Code = 'mr') or (Code = 'ne') or (Code = 'sa') or (Code = 'mai') or (Code = 'new') or
    (Code = 'awa') or (Code = 'bho') then
    Exit(stDevanagari);

  // Bengali (Assamese, Bengali)
  if (Code = 'as') or (Code = 'bn') then Exit(stBengali);

  // Gurmukhi (Punjabi)
  if (Code = 'pa') then Exit(stGurmukhi);

  // Gujarati
  if (Code = 'gu') then Exit(stGujarati);

  // Oriya
  if (Code = 'or') then Exit(stOriya);

  // Tamil
  if (Code = 'ta') then Exit(stTamil);

  // Telugu
  if (Code = 'te') then Exit(stTelugu);

  // Kannada
  if (Code = 'kn') then Exit(stKannada);

  // Malayalam
  if (Code = 'ml') then Exit(stMalayalam);

  // Sinhala
  if (Code = 'si') then Exit(stSinhala);

  // Thai
  if (Code = 'th') then Exit(stThai);

  // Lao
  if (Code = 'lo') then Exit(stLao);

  // Myanmar
  if (Code = 'my') then Exit(stMyanmar);

  // Khmer
  if (Code = 'km') then Exit(stKhmer);

  // Georgian
  if (Code = 'ka') then Exit(stGeorgian);

  // Armenian
  if (Code = 'hy') then Exit(stArmenian);

  // Ethiopic (Amharic, etc.)
  if (Code = 'am') or (Code = 'ti') then Exit(stEthiopic);

  // Tibetan
  if (Code = 'bo') or (Code = 'dz') then Exit(stTibetan);

  // Everything else is Latin script (covers all other world languages)
  Result := stLatin;
end;

// Checks if language code matches current script
function IsLanguageMatchingScript(const Code: string; Script: TScriptType): boolean;
begin
  case Script of
    stLatin:
      // All languages EXCEPT those that normally use a non‑Latin script.
      // This list covers all major non‑Latin languages and their script‑specific codes.
      Result := not (
        // Cyrillic (incl. many languages of Russia, Central Asia, etc.)
        (Code = 'ru') or (Code = 'uk') or (Code = 'be') or (Code = 'bg') or (Code = 'sr') or (Code = 'mk') or
        (Code = 'kk') or (Code = 'ky') or (Code = 'mn') or (Code = 'tg') or (Code = 'tt') or (Code = 'ba') or
        (Code = 'cv') or (Code = 'os') or (Code = 'sah') or (Code = 'xal') or (Code = 'ab') or (Code = 'ce') or
        (Code = 'av') or (Code = 'udm') or
        // Arabic script
        (Code = 'ar') or (Code = 'fa') or (Code = 'ur') or (Code = 'ps') or (Code = 'sd') or (Code = 'ug') or
        (Code = 'ckb') or (Code = 'prs') or (Code = 'ku') or (Code = 'azb') or
        // Greek
        (Code = 'el') or
        // Hebrew
        (Code = 'he') or (Code = 'iw') or (Code = 'yi') or
        // CJK
        (Code = 'zh') or (Code = 'zh-CN') or (Code = 'zh-TW') or (Code = 'ja') or (Code = 'ko') or (Code = 'yue') or
        // Devanagari & related
        (Code = 'hi') or (Code = 'mr') or (Code = 'ne') or (Code = 'sa') or (Code = 'mai') or (Code = 'new') or
        (Code = 'awa') or (Code = 'bho') or
        // Bengali (includes Assamese)
        (Code = 'bn') or (Code = 'as') or
        // Gurmukhi (Punjabi)
        (Code = 'pa') or
        // Gujarati
        (Code = 'gu') or
        // Oriya
        (Code = 'or') or
        // Tamil
        (Code = 'ta') or
        // Telugu
        (Code = 'te') or
        // Kannada
        (Code = 'kn') or
        // Malayalam
        (Code = 'ml') or
        // Sinhala
        (Code = 'si') or
        // Thai
        (Code = 'th') or
        // Lao
        (Code = 'lo') or
        // Myanmar
        (Code = 'my') or
        // Khmer
        (Code = 'km') or
        // Georgian
        (Code = 'ka') or
        // Armenian
        (Code = 'hy') or
        // Ethiopic
        (Code = 'am') or (Code = 'ti') or
        // Tibetan
        (Code = 'bo') or (Code = 'dz'));

    // Cyrillic script
    stCyrillic:
      Result := (Code = 'ru') or (Code = 'uk') or (Code = 'be') or (Code = 'bg') or (Code = 'sr') or
        (Code = 'mk') or (Code = 'kk') or (Code = 'ky') or (Code = 'mn') or (Code = 'tg') or (Code = 'tt') or
        (Code = 'ba') or (Code = 'cv') or (Code = 'os') or (Code = 'sah') or (Code = 'xal') or (Code = 'ab') or
        (Code = 'ce') or (Code = 'av') or (Code = 'udm');

    // Arabic script
    stArabic:
      Result := (Code = 'ar') or (Code = 'fa') or (Code = 'ur') or (Code = 'ps') or (Code = 'sd') or
        (Code = 'ug') or (Code = 'ckb') or (Code = 'prs') or (Code = 'ku') or (Code = 'azb');

    stGreek: Result := (Code = 'el');
    stHebrew: Result := (Code = 'he') or (Code = 'iw') or (Code = 'yi');

    // Devanagari (used by many North Indian languages)
    stDevanagari:
      Result := (Code = 'hi') or (Code = 'mr') or (Code = 'ne') or (Code = 'sa') or (Code = 'mai') or
        (Code = 'new') or (Code = 'awa') or (Code = 'bho');

    // CJK (Chinese, Japanese, Korean)
    stCJK:
      Result := (Code = 'zh') or (Code = 'zh-CN') or (Code = 'zh-TW') or (Code = 'ja') or (Code = 'ko') or (Code = 'yue');

    // Bengali script (used by Bengali and Assamese)
    stBengali: Result := (Code = 'bn') or (Code = 'as');

    // Gurmukhi (Punjabi)
    stGurmukhi: Result := (Code = 'pa');

    // Gujarati
    stGujarati: Result := (Code = 'gu');

    // Oriya
    stOriya: Result := (Code = 'or');

    // Tamil
    stTamil: Result := (Code = 'ta');

    // Telugu
    stTelugu: Result := (Code = 'te');

    // Kannada
    stKannada: Result := (Code = 'kn');

    // Malayalam
    stMalayalam: Result := (Code = 'ml');

    // Sinhala
    stSinhala: Result := (Code = 'si');

    // Thai
    stThai: Result := (Code = 'th');

    // Lao
    stLao: Result := (Code = 'lo');

    // Myanmar (Burmese)
    stMyanmar: Result := (Code = 'my');

    // Khmer
    stKhmer: Result := (Code = 'km');

    // Georgian
    stGeorgian: Result := (Code = 'ka');

    // Armenian
    stArmenian: Result := (Code = 'hy');

    // Ethiopic (Amharic, Tigrinya, etc.)
    stEthiopic: Result := (Code = 'am') or (Code = 'ti');

    // Tibetan
    stTibetan: Result := (Code = 'bo') or (Code = 'dz');

      // For any unknown script, we allow everything (should not normally happen)
    else
      Result := True;
  end;
end;

// Returns a priority value for a language code.
// Lower value = more widely spoken / higher base frequency.
// Used for tie‑breaking on very short texts.
function GetLanguagePriority(const Code: string): word;
begin
  case Code of
    'en': Result := 1;
    'zh-CN': Result := 2;
    'zh-TW': Result := 3;
    'hi': Result := 4;
    'es': Result := 5;
    'ar': Result := 6;
    'fr': Result := 7;
    'pt': Result := 8;
    'ru': Result := 9;
    'ja': Result := 10;
    'de': Result := 11;
    'ko': Result := 12;
    'it': Result := 13;
    'tr': Result := 14;
    'pl': Result := 15;
    'uk': Result := 16;
    'nl': Result := 17;
    'el': Result := 18;
    'cs': Result := 19;
    'sv': Result := 20;
    'hu': Result := 21;
    'ro': Result := 22;
    'fi': Result := 23;
    'da': Result := 24;
    'no': Result := 25;
    'sk': Result := 26;
    'bg': Result := 27;
    'sr': Result := 28;
    'hr': Result := 29;
    'lt': Result := 30;
    'lv': Result := 31;
    'sl': Result := 32;
    'et': Result := 33;
    'he': Result := 34;
    'iw': Result := 35;   // Hebrew alternate code
    'id': Result := 36;
    'ms': Result := 37;
    'vi': Result := 38;
    'th': Result := 39;
    'fa': Result := 40;
    'ur': Result := 41;
    'ta': Result := 42;
    'te': Result := 43;
    'bn': Result := 44;
    'mr': Result := 45;
    'gu': Result := 46;
    'pa': Result := 47;
    'or': Result := 48;
    'ml': Result := 49;
    'kn': Result := 50;
    'si': Result := 51;
    'my': Result := 52;
    'km': Result := 53;
    'lo': Result := 54;
    'ka': Result := 55;
    'hy': Result := 56;
    'az': Result := 57;
    'kk': Result := 58;
    'ky': Result := 59;
    'uz': Result := 60;
    'mn': Result := 61;
    'am': Result := 62;
    'ne': Result := 63;
    'sw': Result := 64;
    'zu': Result := 65;
    'xh': Result := 66;
    'ht': Result := 67;
    'fy': Result := 68;
    'cy': Result := 69;
    'gd': Result := 70;
    'ga': Result := 71;
    'eo': Result := 72;
    'la': Result := 73;
    'be': Result := 74;
    'jv': Result := 75;
    'su': Result := 76;
    'tl': Result := 77;
    'yo': Result := 78;
    'ig': Result := 79;
    'ha': Result := 80;
    'so': Result := 81;
    'om': Result := 82;
    'mg': Result := 83;
    'bs': Result := 84;
    'mk': Result := 85;
    'sq': Result := 86;
    'is': Result := 87;
    'ps': Result := 88;
    'sd': Result := 89;
    'ug': Result := 90;
    'yi': Result := 91;
    'gl': Result := 92;
    'eu': Result := 93;
    'ca': Result := 94;
    'qu': Result := 95;
    'gn': Result := 96;
    'sc': Result := 97;
    'sa': Result := 98;
    'br': Result := 99;
    'rm': Result := 100;
    'ln': Result := 101;
    'lg': Result := 102;
    'ns': Result := 103;
    'ss': Result := 104;
    'tn': Result := 105;
    'ff': Result := 106;
    'wo': Result := 107;
    'li': Result := 108;
    'ku': Result := 109;
    else
      Result := 200;   // unknown languages get low priority
  end;
end;

// Post-correction for language pairs that trigrams alone have trouble separating.
// Optimized: fixed HasWord boundaries bug and reduced repetitive blocks via array helpers.
procedure ApplyPostCorrection(var Code: string; var Confidence: double; const AText: string);
var
  KuScore, TwScore, CnScore: integer;

  // Checks if a word exists with boundaries, correctly handling multiple occurrences
  function HasWord(const Word: string): boolean;
  var
    P, StartPos, Len: integer;
  begin
    Result := False;
    Len := Length(Word);
    if Len = 0 then Exit;
    StartPos := 1;
    while True do
    begin
      P := Pos(Word, AText, StartPos);
      if P = 0 then Exit;
      // Check boundaries
      if ((P = 1) or (AText[P - 1] = ' ')) and
         ((P + Len > Length(AText)) or (AText[P + Len] = ' ')) then
        Exit(True);
      StartPos := P + Len;
    end;
  end;

  // Helper to check if ANY of the words exist
  function HasAnyWord(const Words: array of string): boolean;
  var
    I: integer;
  begin
    for I := Low(Words) to High(Words) do
      if HasWord(Words[I]) then Exit(True);
    Result := False;
  end;

  // Helper to check if ANY of the substrings/chars exist
  function HasAnyChar(const Chars: array of string): boolean;
  var
    I: integer;
  begin
    for I := Low(Chars) to High(Chars) do
      if Pos(Chars[I], AText) > 0 then Exit(True);
    Result := False;
  end;

  // Counters for scoring mechanisms
  function CountChars(const Chars: array of string): integer;
  var
    I: integer;
  begin
    Result := 0;
    for I := Low(Chars) to High(Chars) do
      if Pos(Chars[I], AText) > 0 then Inc(Result);
  end;

  function CountWords(const Words: array of string): integer;
  var
    I: integer;
  begin
    Result := 0;
    for I := Low(Words) to High(Words) do
      if HasWord(Words[I]) then Inc(Result);
  end;

begin
  {%Region -fold Norwegian vs Danish vs Swedish}
  if (Code = 'no') or (Code = 'da') or (Code = 'sv') then
  begin
    if HasAnyChar(['ä', 'ö']) then begin Code := 'sv'; Confidence := 1.0; Exit; end;
    if HasWord('ikkje') then begin Code := 'no'; Confidence := 1.0; Exit; end;

    if HasWord('ikke') then
    begin
      if HasAnyWord(['jeg', 'mig', 'dig', 'jer', 'af']) then begin Code := 'da'; Confidence := 1.0; Exit; end
      else if HasAnyWord(['meg', 'deg', 'dere', 'av']) then begin Code := 'no'; Confidence := 1.0; Exit; end;
    end;

    if HasAnyWord(['och', 'är', 'inte', 'att']) then begin Code := 'sv'; Confidence := 1.0; Exit; end;
    if HasAnyWord(['meg', 'deg', 'dere', 'av', 'bruker']) then begin Code := 'no'; Confidence := 1.0; Exit; end;
    if HasAnyWord(['mig', 'dig', 'jer', 'af', 'bruger']) then begin Code := 'da'; Confidence := 1.0; Exit; end;

    if HasWord('jeg') then begin Code := 'no'; Confidence := 0.9; Exit; end;
  end;
  {%EndRegion}

  {%Region -fold Xhosa vs Zulu}
  if (Code = 'xh') or (Code = 'zu') then
  begin
    if HasAnyWord(['xh', 'kwaye', 'umntu', 'ngoku', 'kwa', 'xa', 'ndi']) then begin Code := 'xh'; Confidence := 1.0; Exit; end;
    if HasAnyWord(['zu', 'ngi', 'uku', 'kanti', 'yena', 'lapha', 'yini', 'nini', 'lona']) then begin Code := 'zu'; Confidence := 1.0; Exit; end;
  end;
  {%EndRegion}

  {%Region -fold Kurdish vs Turkish, Hausa and others}
  if (Code = 'ku') or (Code = 'tr') or (Code = 'ha') or (Code = 'id') then
  begin
    KuScore := CountChars(['ê', 'î', 'û', 'Ê', 'Î', 'Û', 'ev', 'ew', 'xw']) +
               CountWords(['xwe', 'heye', 'gelek', 'kirin', 'çawa', 'çend', 'hinek', 'rojbaş', 'baş']);

    if KuScore >= 2 then begin Code := 'ku'; Confidence := 1.0; Exit; end;
    if HasAnyChar(['ı', 'ğ']) then begin Code := 'tr'; Confidence := 1.0; Exit; end;

    if Code = 'ku' then Confidence := 0.5;
  end;
  {%EndRegion}

  {%Region -fold Assamese vs Bengali}
  if (Code = 'as') or (Code = 'bn') then
  begin
    if HasAnyChar(['ৰ', 'ৱ']) then begin Code := 'as'; Confidence := 1.0; Exit; end;
    if HasAnyChar(['য়']) then begin Code := 'bn'; Confidence := 1.0; Exit; end;

    if HasAnyChar(['যিটো', 'তেওঁ', 'আৰু', 'এটা', 'কৰি', 'কৰা']) then begin Code := 'as'; Confidence := 0.95; Exit; end;
    if HasAnyChar(['যেটা', 'এবং', 'আমি', 'তিনি', 'করতে', 'করেছে']) then begin Code := 'bn'; Confidence := 0.95; Exit; end;

    Confidence := 0.45;
  end;
  {%EndRegion}

  {%Region -fold Bosnian / Croatian / Serbian}
  if (Code = 'bs') or (Code = 'hr') or (Code = 'sr') then
  begin
    if HasAnyWord(['što', 'tko']) then begin Code := 'hr'; Confidence := 0.95; Exit; end;
    if HasAnyWord(['šta', 'ko']) then begin Confidence := 0.8; Exit; end;
    Confidence := 0.6;
  end;
  {%EndRegion}

  {%Region -fold Albanian vs Turkish}
  if (Code = 'sq') or (Code = 'tr') then
  begin
    if HasAnyChar(['ë']) then begin Code := 'sq'; Confidence := 1.0; Exit; end;
    if HasAnyChar(['ı', 'ş', 'ğ']) then begin Code := 'tr'; Confidence := 1.0; Exit; end;
    Confidence := 0.7;
  end;
  {%EndRegion}

  {%Region -fold Sanskrit vs English}
  if (Code = 'sa') and (Confidence < 1.0) then
  begin
    if HasAnyChar(['ā', 'ī', 'ū', 'ṛ', 'ṣ', 'ṃ', 'ḥ']) then begin Code := 'sa'; Confidence := 1.0; Exit; end;
  end;
  {%EndRegion}

  {%Region -fold Cyrillic group: be, uk, ru, bg, mk, sr}
  if (Code = 'be') or (Code = 'uk') or (Code = 'ru') or (Code = 'bg') or (Code = 'mk') or (Code = 'sr') then
  begin
    if HasAnyChar(['ў', 'Ў']) then begin Code := 'be'; Confidence := 1.0; Exit; end;
    if HasAnyChar(['ї', 'є', 'ґ', 'Ї', 'Є', 'Ґ']) then begin Code := 'uk'; Confidence := 1.0; Exit; end;
    if HasAnyChar(['ѓ', 'ќ', 'ѕ']) then begin Code := 'mk'; Confidence := 1.0; Exit; end;
    if HasAnyChar(['ђ', 'ћ', 'џ', 'Ђ', 'Ћ', 'Џ']) then begin Code := 'sr'; Confidence := 1.0; Exit; end;

    if HasAnyChar(['ј']) then
    begin
      if (Code = 'ru') or (Code = 'be') or (Code = 'uk') or (Code = 'bg') then begin Code := 'sr'; Confidence := 1.0; Exit; end;
      if (Code = 'sr') or (Code = 'mk') then begin Confidence := 1.0; Exit; end;
    end;

    if (Pos('ъ', AText) > 0) and not HasAnyChar(['ы', 'ё', 'э']) then begin Code := 'bg'; Confidence := 1.0; Exit; end;

    if HasAnyChar(['і', 'І']) then
    begin
      if HasAnyChar(['ы', 'Ы']) then Code := 'be' else Code := 'uk';
      Confidence := 1.0; Exit;
    end;

    if HasAnyChar(['ы', 'ё', 'э']) then
    begin
      if (Code = 'sr') or (Code = 'mk') then begin Code := 'ru'; Confidence := 1.0; Exit; end;
      if Code = 'ru' then Confidence := 1.0;
    end;

    if (Code = 'sr') and not HasAnyChar(['ђ', 'ћ', 'џ', 'ј']) then Confidence := 0.4;
    if (Code = 'mk') and not HasAnyChar(['ѓ', 'ќ', 'ѕ']) then Confidence := 0.4;
  end;
  {%EndRegion}

  {%Region -fold Spanish vs Galician vs Portuguese}
  if (Code = 'es') or (Code = 'gl') or (Code = 'pt') then
  begin
    if HasAnyChar(['ç', 'ão', 'ção', 'ções']) then begin Code := 'pt'; Confidence := 1.0; Exit; end;
    if HasAnyWord(['non', 'galego', 'nós', 'vós', 'unha', 'dúas', 'ao', 'coa']) then begin Code := 'gl'; Confidence := 1.0; Exit; end;
    if HasAnyChar(['ñ', '¿', '¡']) then begin Code := 'es'; Confidence := 1.0; Exit; end;
  end;
  {%EndRegion}

  {%Region -fold Czech vs Slovak}
  if (Code = 'cs') or (Code = 'sk') then
  begin
    if HasAnyChar(['ä', 'ô', 'ŕ', 'ĺ']) then begin Code := 'sk'; Confidence := 1.0; Exit; end
    else if HasAnyChar(['ř', 'ů']) then begin Code := 'cs'; Confidence := 1.0; Exit; end;
  end;
  {%EndRegion}

  {%Region -fold Chinese Simplified vs Traditional}
  if (Code = 'zh-CN') or (Code = 'zh-TW') then
  begin
    TwScore := CountChars(['國', '體', '門', '機', '關', '開', '電', '學', '說', '這', '個', '為', '與', '實', '歡']);
    CnScore := CountChars(['国', '体', '门', '机', '关', '开', '电', '学', '说', '这', '个', '为', '与', '实', '欢']);

    if TwScore > CnScore then begin Code := 'zh-TW'; Confidence := 1.0; Exit; end;
    if CnScore > TwScore then begin Code := 'zh-CN'; Confidence := 1.0; Exit; end;
  end;
  {%EndRegion}

  {%Region -fold Esperanto vs Khmer}
  if (Code = 'eo') or (Code = 'km') then
  begin
    if HasAnyChar(['ĉ', 'ĝ', 'ĥ', 'ĵ', 'ŝ', 'ŭ']) then begin Code := 'eo'; Confidence := 1.0; Exit; end;
    if HasAnyWord(['kaj', 'estas', 'estis', 'de', 'la', 'al', 'ke']) then begin Code := 'eo'; Confidence := 0.95; Exit; end;
    if Code = 'eo' then begin Code := 'km'; Confidence := 0.7; Exit; end;
    if Code = 'km' then Confidence := 0.8;
  end;
  {%EndRegion}

  {%Region -fold Uzbek vs Guarani}
  if (Code = 'uz') or (Code = 'gn') then
  begin
    if HasAnyChar(['ñ', 'ã', 'ẽ', 'ĩ', 'õ', 'ũ']) then begin Code := 'gn'; Confidence := 1.0; Exit; end;
    if HasAnyChar(['‘', 'ʼ']) then begin Code := 'uz'; Confidence := 1.0; Exit; end;
    Confidence := 0.5;
  end;
  {%EndRegion}

  {%Region -fold Latin-script languages with unique letters vs English}
  if Code = 'en' then
  begin
    if HasAnyChar(['ẹ', 'ọ', 'ṣ', 'Ẹ', 'Ọ', 'Ṣ']) then begin Code := 'yo'; Confidence := 1.0; Exit; end;
    if HasAnyChar(['ï', 'ụ']) then begin Code := 'ig'; Confidence := 1.0; Exit; end;
    if HasAnyChar(['ƙ', 'ɗ']) then begin Code := 'ha'; Confidence := 1.0; Exit; end;
    if HasAnyChar(['ơ', 'ư', 'ă']) then begin Code := 'vi'; Confidence := 1.0; Exit; end;
    if HasAnyChar(['ı', 'İ', 'ş', 'ğ']) then begin Code := 'tr'; Confidence := 1.0; Exit; end;
    if HasAnyChar(['ł', 'ż', 'ź']) then begin Code := 'pl'; Confidence := 1.0; Exit; end;
    if HasAnyChar(['ř', 'ů']) then begin Code := 'cs'; Confidence := 1.0; Exit; end;
    if HasAnyChar(['ŕ', 'ĺ']) then begin Code := 'sk'; Confidence := 1.0; Exit; end;
    if HasAnyChar(['ā', 'ē', 'ī', 'ū', 'ģ', 'ķ', 'ļ', 'ņ']) then begin Code := 'lv'; Confidence := 1.0; Exit; end;
    if HasAnyChar(['į', 'ų', 'ė']) then begin Code := 'lt'; Confidence := 1.0; Exit; end;
    if HasAnyChar(['ĉ', 'ĝ', 'ĥ', 'ĵ', 'ŝ', 'ŭ']) then begin Code := 'eo'; Confidence := 1.0; Exit; end;
    if HasAnyChar(['œ', 'Œ']) then begin Code := 'fr'; Confidence := 1.0; Exit; end;
    if HasAnyChar(['ß', 'ä', 'ö', 'ü']) then begin Code := 'de'; Confidence := 1.0; Exit; end;
    if HasAnyChar(['þ', 'ð']) then begin Code := 'is'; Confidence := 1.0; Exit; end;
    if HasAnyChar(['ő', 'ű']) then begin Code := 'hu'; Confidence := 1.0; Exit; end;
    if HasAnyChar(['ș', 'ț']) then begin Code := 'ro'; Confidence := 1.0; Exit; end;
    if HasAnyChar(['ñ', '¿', '¡']) then begin Code := 'es'; Confidence := 1.0; Exit; end;
    if HasAnyChar(['ã', 'õ', 'ç']) then begin Code := 'pt'; Confidence := 1.0; Exit; end;
    if HasAnyChar(['ŵ', 'ŷ']) then begin Code := 'cy'; Confidence := 1.0; Exit; end;
    if HasAnyChar(['ก']) then begin Code := 'th'; Confidence := 1.0; Exit; end;
  end;
  {%EndRegion}

  {%Region -fold Hebrew script: Hebrew vs Yiddish}
  if (Code = 'he') or (Code = 'iw') or (Code = 'yi') then
  begin
    if HasAnyChar([#$05F0, #$05F1, #$05F2]) then begin Code := 'yi'; Confidence := 1.0; Exit; end;

    if HasAnyChar(['את ', 'על ', 'לא ', 'של ', 'הוא ', 'היא ']) then
    begin
      if (Code = 'he') or (Code = 'iw') then Confidence := 0.95;
      if Code = 'yi' then begin Code := 'he'; Confidence := 0.95; end;
      Exit;
    end;

    if HasAnyChar([' און ', ' איך ', ' נישט ', ' דאס ', ' איז ', ' מיט ', ' פון ', ' צו ', ' מען ', ' זייער ', ' שוין ']) then
    begin Code := 'yi'; Confidence := 0.70; Exit; end;

    if Code = 'yi' then Confidence := 0.5;
  end;
  {%EndRegion}
end;

// Special correction for very short texts (< SHORT_TEXT_THRESHOLD chars)
// Uses unique characters to override the priority guess for many languages
procedure ApplyShortTextCorrection(var Code: string; var Confidence: double; const AText: string);
var
  HasAeOe, HasAa, HasUmlaut, HasI, HasY, HasHardSign, HasRus: boolean;
begin
  // Asian scripts based on highly frequent characters
  if (Pos('の', AText) > 0) or (Pos('に', AText) > 0) or (Pos('は', AText) > 0) or (Pos('を', AText) > 0) or
    (Pos('だ', AText) > 0) then
  begin
    Code := 'ja';
    Confidence := 1.0;
    Exit;
  end;

  if (Pos('다', AText) > 0) or (Pos('요', AText) > 0) or (Pos('는', AText) > 0) or (Pos('이', AText) > 0) or
    (Pos('가', AText) > 0) then
  begin
    Code := 'ko';
    Confidence := 1.0;
    Exit;
  end;

  if (Pos('的', AText) > 0) or (Pos('是', AText) > 0) or (Pos('我', AText) > 0) or (Pos('不', AText) > 0) or
    (Pos('在', AText) > 0) then
  begin
    Code := 'zh-CN';
    Confidence := 1.0;
    Exit;
  end;

  // Thai script
  if (Pos('ก', AText) > 0) or (Pos('ข', AText) > 0) or (Pos('ค', AText) > 0) or (Pos('ง', AText) > 0) then
  begin
    Code := 'th';
    Confidence := 1.0;
    Exit;
  end;

  // Georgian script
  if (Pos('ა', AText) > 0) or (Pos('ბ', AText) > 0) or (Pos('გ', AText) > 0) or (Pos('დ', AText) > 0) then
  begin
    Code := 'ka';
    Confidence := 1.0;
    Exit;
  end;

  // Armenian script
  if (Pos('ա', AText) > 0) or (Pos('բ', AText) > 0) or (Pos('գ', AText) > 0) or (Pos('դ', AText) > 0) then
  begin
    Code := 'hy';
    Confidence := 1.0;
    Exit;
  end;

  // Amharic script
  if (Pos('አ', AText) > 0) or (Pos('በ', AText) > 0) or (Pos('የ', AText) > 0) or (Pos('መ', AText) > 0) then
  begin
    Code := 'am';
    Confidence := 1.0;
    Exit;
  end;

  // Persian specific letters
  if (Pos('پ', AText) > 0) or (Pos('چ', AText) > 0) or (Pos('ژ', AText) > 0) or (Pos('گ', AText) > 0) then
  begin
    Code := 'fa';
    Confidence := 1.0;
    Exit;
  end;

  // Urdu specific letters
  if (Pos('ٹ', AText) > 0) or (Pos('ڈ', AText) > 0) or (Pos('ڑ', AText) > 0) or (Pos('ں', AText) > 0) or (Pos('ے', AText) > 0) then
  begin
    Code := 'ur';
    Confidence := 1.0;
    Exit;
  end;

  // Azerbaijani unique letters
  if (Pos('ə', AText) > 0) or (Pos('Ə', AText) > 0) then
  begin
    Code := 'az';
    Confidence := 1.0;
    Exit;
  end;

  // Esperanto unique letters
  if (Pos('ĉ', AText) > 0) or (Pos('ĝ', AText) > 0) or (Pos('ĥ', AText) > 0) or (Pos('ĵ', AText) > 0) or
    (Pos('ŝ', AText) > 0) or (Pos('ŭ', AText) > 0) or (Pos('Ĉ', AText) > 0) or (Pos('Ĝ', AText) > 0) or
    (Pos('Ĥ', AText) > 0) or (Pos('Ĵ', AText) > 0) or (Pos('Ŝ', AText) > 0) or (Pos('Ŭ', AText) > 0) then
  begin
    Code := 'eo';
    Confidence := 1.0;
    Exit;
  end;

  // Welsh specific letters
  if (Pos('ŵ', AText) > 0) or (Pos('ŷ', AText) > 0) or (Pos('Ŵ', AText) > 0) or (Pos('Ŷ', AText) > 0) then
  begin
    Code := 'cy';
    Confidence := 1.0;
    Exit;
  end;

  // Latvian specific letters
  if (Pos('ā', AText) > 0) or (Pos('ē', AText) > 0) or (Pos('ī', AText) > 0) or (Pos('ū', AText) > 0) or
    (Pos('ģ', AText) > 0) or (Pos('ķ', AText) > 0) or (Pos('ļ', AText) > 0) or (Pos('ņ', AText) > 0) or
    (Pos('Ā', AText) > 0) or (Pos('Ē', AText) > 0) or (Pos('Ī', AText) > 0) or (Pos('Ū', AText) > 0) then
  begin
    Code := 'lv';
    Confidence := 1.0;
    Exit;
  end;

  // Lithuanian specific letters
  if (Pos('ė', AText) > 0) or (Pos('į', AText) > 0) or (Pos('ų', AText) > 0) or (Pos('Ė', AText) > 0) or
    (Pos('Į', AText) > 0) or (Pos('Ų', AText) > 0) then
  begin
    Code := 'lt';
    Confidence := 1.0;
    Exit;
  end;

  // Polish unique letters
  if (Pos('ą', AText) > 0) or (Pos('ć', AText) > 0) or (Pos('ę', AText) > 0) or (Pos('ł', AText) > 0) or
    (Pos('ń', AText) > 0) or (Pos('ó', AText) > 0) or (Pos('ś', AText) > 0) or (Pos('ź', AText) > 0) or
    (Pos('ż', AText) > 0) or (Pos('Ą', AText) > 0) or (Pos('Ć', AText) > 0) or (Pos('Ę', AText) > 0) or
    (Pos('Ł', AText) > 0) or (Pos('Ń', AText) > 0) or (Pos('Ó', AText) > 0) or (Pos('Ś', AText) > 0) or
    (Pos('Ź', AText) > 0) or (Pos('Ż', AText) > 0) then
  begin
    Code := 'pl';
    Confidence := 1.0;
    Exit;
  end;

  // Turkish unique letters
  if (Pos('ğ', AText) > 0) or (Pos('ı', AText) > 0) or (Pos('İ', AText) > 0) or (Pos('ş', AText) > 0) or
    (Pos('Ğ', AText) > 0) or (Pos('Ş', AText) > 0) then
  begin
    Code := 'tr';
    Confidence := 1.0;
    Exit;
  end;

  // Hungarian exclusive letters
  if (Pos('ő', AText) > 0) or (Pos('ű', AText) > 0) or (Pos('Ő', AText) > 0) or (Pos('Ű', AText) > 0) then
  begin
    Code := 'hu';
    Confidence := 1.0;
    Exit;
  end;

  // Spanish exclusive letters
  if (Pos('ñ', AText) > 0) or (Pos('Ñ', AText) > 0) or (Pos('¿', AText) > 0) or (Pos('¡', AText) > 0) then
  begin
    Code := 'es';
    Confidence := 1.0;
    Exit;
  end;

  // Romanian letters
  if (Pos('ă', AText) > 0) or (Pos('ș', AText) > 0) or (Pos('ț', AText) > 0) or (Pos('Ă', AText) > 0) or
    (Pos('Ș', AText) > 0) or (Pos('Ț', AText) > 0) then
  begin
    Code := 'ro';
    Confidence := 1.0;
    Exit;
  end;

  // Czech letters
  if (Pos('ř', AText) > 0) or (Pos('ů', AText) > 0) or (Pos('ě', AText) > 0) or (Pos('Ř', AText) > 0) or
    (Pos('Ů', AText) > 0) or (Pos('Ě', AText) > 0) then
  begin
    Code := 'cs';
    Confidence := 1.0;
    Exit;
  end;

  // Slovak letters
  if (Pos('ô', AText) > 0) or (Pos('ŕ', AText) > 0) or (Pos('ĺ', AText) > 0) or (Pos('Ô', AText) > 0) or
    (Pos('Ŕ', AText) > 0) or (Pos('Ĺ', AText) > 0) then
  begin
    Code := 'sk';
    Confidence := 1.0;
    Exit;
  end;

  // Icelandic letters
  if (Pos('þ', AText) > 0) or (Pos('ð', AText) > 0) or (Pos('Þ', AText) > 0) or (Pos('Ð', AText) > 0) then
  begin
    Code := 'is';
    Confidence := 1.0;
    Exit;
  end;

  // Vietnamese letters
  if (Pos('đ', AText) > 0) or (Pos('ơ', AText) > 0) or (Pos('ư', AText) > 0) or (Pos('Đ', AText) > 0) or
    (Pos('Ơ', AText) > 0) or (Pos('Ư', AText) > 0) then
  begin
    Code := 'vi';
    Confidence := 1.0;
    Exit;
  end;

  // Portuguese letters
  if (Pos('ã', AText) > 0) or (Pos('õ', AText) > 0) or (Pos('Ã', AText) > 0) or (Pos('Õ', AText) > 0) then
  begin
    Code := 'pt';
    Confidence := 1.0;
    Exit;
  end;

  // French letters
  if (Pos('œ', AText) > 0) or (Pos('Œ', AText) > 0) then
  begin
    Code := 'fr';
    Confidence := 1.0;
    Exit;
  end;

  // German eszett
  if Pos('ß', AText) > 0 then
  begin
    Code := 'de';
    Confidence := 1.0;
    Exit;
  end;

  // Ukrainian letters
  if (Pos('ї', AText) > 0) or (Pos('є', AText) > 0) or (Pos('ґ', AText) > 0) or (Pos('Ї', AText) > 0) or
    (Pos('Є', AText) > 0) or (Pos('Ґ', AText) > 0) then
  begin
    Code := 'uk';
    Confidence := 1.0;
    Exit;
  end;

  // Belarusian letters
  if (Pos('ў', AText) > 0) or (Pos('Ў', AText) > 0) then
  begin
    Code := 'be';
    Confidence := 1.0;
    Exit;
  end;

  // Kazakh letters
  if (Pos('ғ', AText) > 0) or (Pos('қ', AText) > 0) or (Pos('ң', AText) > 0) or (Pos('ұ', AText) > 0) or
    (Pos('һ', AText) > 0) or (Pos('Ғ', AText) > 0) or (Pos('Қ', AText) > 0) or (Pos('Ң', AText) > 0) or
    (Pos('Ұ', AText) > 0) or (Pos('Һ', AText) > 0) then
  begin
    Code := 'kk';
    Confidence := 1.0;
    Exit;
  end;

  // Macedonian letters
  if (Pos('ѓ', AText) > 0) or (Pos('ќ', AText) > 0) or (Pos('ѕ', AText) > 0) or (Pos('Ѓ', AText) > 0) or
    (Pos('Ќ', AText) > 0) or (Pos('Ѕ', AText) > 0) then
  begin
    Code := 'mk';
    Confidence := 1.0;
    Exit;
  end;

  // Serbian letters
  if (Pos('ђ', AText) > 0) or (Pos('љ', AText) > 0) or (Pos('њ', AText) > 0) or (Pos('ћ', AText) > 0) or
    (Pos('џ', AText) > 0) or (Pos('Ђ', AText) > 0) or (Pos('Љ', AText) > 0) or (Pos('Њ', AText) > 0) or
    (Pos('Ћ', AText) > 0) or (Pos('Џ', AText) > 0) then
  begin
    Code := 'sr';
    Confidence := 1.0;
    Exit;
  end;

  // Yiddish unique ligatures (tsvey vovn, vav yud, tsvey yudn)
  if (Pos('װ', AText) > 0) or (Pos('ױ', AText) > 0) or (Pos('ײ', AText) > 0) or
    // Common Yiddish letter combinations
    (Pos('גע', AText) > 0) or (Pos('טש', AText) > 0) or (Pos('זש', AText) > 0) or (Pos('ניש', AText) > 0) or
    (Pos('ונג', AText) > 0) or (Pos('ער ', AText) > 0) or (Pos('עס ', AText) > 0) then
  begin
    Code := 'yi';
    Confidence := 1.0;
    Exit;
  end;

  // Wolof (wo) – characteristic letters and particles
  if (Pos('ñ', AText) > 0) or (Pos('Ñ', AText) > 0) or (Pos('ŋ', AText) > 0) or (Pos('Ŋ', AText) > 0) or
    (Pos(' ci ', AText) > 0) or (Pos(' ngi ', AText) > 0) or (Pos(' ak ', AText) > 0) then
  begin
    Code := 'wo';
    Confidence := 1.0;
    Exit;
  end;

  // Scandinavian fallback logic
  HasAeOe := (Pos('æ', AText) > 0) or (Pos('ø', AText) > 0) or (Pos('Æ', AText) > 0) or (Pos('Ø', AText) > 0);
  if HasAeOe then
  begin
    if Pos('af', AText) > 0 then
      Code := 'da'
    else if Pos('av', AText) > 0 then
      Code := 'no'
    else
      Code := 'da'; // Default for nordic
    Confidence := 1.0;
    Exit;
  end;

  HasAa := (Pos('å', AText) > 0) or (Pos('Å', AText) > 0);
  if HasAa then
  begin
    Code := 'sv';
    Confidence := 1.0;
    Exit;
  end;

  HasUmlaut := (Pos('ä', AText) > 0) or (Pos('ö', AText) > 0) or (Pos('ü', AText) > 0) or (Pos('Ä', AText) > 0) or
    (Pos('Ö', AText) > 0) or (Pos('Ü', AText) > 0);
  if HasUmlaut then
  begin
    Code := 'de';
    Confidence := 0.95;
    Exit;
  end;

  // Cyrillic special handling for very short texts
  HasI := (Pos('і', AText) > 0) or (Pos('І', AText) > 0);
  HasY := (Pos('ы', AText) > 0) or (Pos('Ы', AText) > 0);
  HasHardSign := (Pos('ъ', AText) > 0) or (Pos('Ъ', AText) > 0);
  HasRus := (Pos('э', AText) > 0) or (Pos('Э', AText) > 0) or (Pos('ё', AText) > 0) or (Pos('Ё', AText) > 0);

  // Belarusian, ukrainian, russian context check
  if (Code = 'be') or (Code = 'uk') or (Code = 'ru') then
  begin
    if HasI then
    begin
      if HasY then
        Code := 'be'
      else
        Code := 'uk';
      Confidence := 1.0;
      Exit;
    end;
  end;

  // Bulgarian vs macedonian context check
  if (Code = 'bg') or (Code = 'mk') then
  begin
    if HasHardSign and not HasY and not HasRus then
    begin
      Code := 'bg';
      Confidence := 1.0;
      Exit;
    end;
  end;
end;

// Frequency-aware distance (lower = better).
// For each trigram of the text, if found in profile, adds a negative penalty
// proportional to its frequency (or rank). Missing trigrams add a fixed positive penalty.
function DistanceToProfile(const TextTrigrams: TStringArray; const Profile: TProfile): double;
const
  MISSING_PENALTY = 100;               // penalty for a trigram not found
  MAX_POS_WEIGHT = 100;               // used when Freqs are not available
var
  i, j: integer;
  score: integer;                      // total accumulated score (negative = good)
  freq: integer;
  tested: integer;
begin
  score := 0;
  tested := 0;
  for i := 0 to High(TextTrigrams) do
  begin
    freq := -1;                        // -1 means not found
    for j := 0 to High(Profile.Trigrams) do
      if Profile.Trigrams[j] = TextTrigrams[i] then
      begin
        // Use stored frequency if available, otherwise fallback to positional weight
        if j < Length(Profile.Freqs) then
          freq := Profile.Freqs[j]
        else
          freq := MAX_POS_WEIGHT - j;   // first positions get higher weight
        Break;
      end;

    if freq >= 0 then
      Dec(score, freq)                  // negative contribution (better)
    else
      Inc(score, MISSING_PENALTY);     // positive contribution (worse)
    Inc(tested);
  end;

  if tested = 0 then
    Result := MISSING_PENALTY
  else
    Result := score / tested;           // average – lower (more negative) wins
end;

// Uses the same tokenisation as BuildWordList in the generator.
// Returns total weight sum of found words; higher = better.
// Score a language profile by counting word matches (each token once).
function ScoreByWrds(const Text: string; const Profile: TProfile): integer;
var
  p, charLen: integer;
  ch, token: string;
  i: integer;
  seenTokens: TStringList;  // tracks already counted tokens
begin
  Result := 0;
  if Length(Profile.Wrds) = 0 then Exit;

  seenTokens := TStringList.Create;
  try
    seenTokens.Sorted := True;
    seenTokens.Duplicates := dupIgnore;
    p := 1;
    token := '';
    while p <= Length(Text) do
    begin
      {$NOTES OFF}
      charLen := UTF8CodepointSize(@Text[p]);
      {$NOTES ON}
      if charLen = 0 then
      begin
        Inc(p);
        Continue;
      end;
      ch := Copy(Text, p, charLen);
      Inc(p, charLen);
      if ((ch[1] >= 'A') and (ch[1] <= 'Z')) or ((ch[1] >= 'a') and (ch[1] <= 'z')) or (Ord(ch[1]) >= $C0) then
        token := token + UTF8LowerCase(ch)
      else
      begin
        if (UTF8Length(token) >= 2) and (UTF8Length(token) <= 30) then
        begin
          // Process token only once per text
          if seenTokens.IndexOf(token) < 0 then
          begin
            seenTokens.Add(token);
            for i := 0 to High(Profile.Wrds) do
              if Profile.Wrds[i] = token then
              begin
                Inc(Result, Profile.WrdFreqs[i]);
                Break;
              end;
          end;
        end;
        token := '';
      end;
    end;
    // Last token
    if (UTF8Length(token) >= 2) and (UTF8Length(token) <= 30) then
    begin
      if seenTokens.IndexOf(token) < 0 then
      begin
        seenTokens.Add(token);
        for i := 0 to High(Profile.Wrds) do
          if Profile.Wrds[i] = token then
          begin
            Inc(Result, Profile.WrdFreqs[i]);
            Break;
          end;
      end;
    end;
  finally
    seenTokens.Free;
  end;
end;

{%EndRegion}

{%Region -fold Public Methods}

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

function DetectLanguageSafe(const AText: string; ACurrentLang: string = ''; MinConfidence: double = 0.5): string;
const
  MIN_SCRIPT_CHANGE_CONFIDENCE = 0.25;   // lower threshold when script differs
var
  conf: double;
  detectedScript, currentScript: TScriptType;
begin
  Result := DetectLanguageWithConfidence(AText, conf);

  // If confidence is high enough, always accept
  if conf >= MinConfidence then
    Exit;

  // If a current language is given and confidence is not too low,
  // check whether the script changed
  if (ACurrentLang <> '') and (conf >= MIN_SCRIPT_CHANGE_CONFIDENCE) then
  begin
    detectedScript := GetScriptByLang(Result);
    currentScript := GetScriptByLang(ACurrentLang);
    if detectedScript <> currentScript then
      Exit;   // accept the detected language despite low confidence
  end;

  // Otherwise, reject
  Result := UNKNOWN;
end;

function DetectLanguageForText(const AText: string): string;
var
  dummy: double;
begin
  Result := DetectLanguageWithConfidence(AText, dummy);
end;

function DetectLanguageWithConfidence(const AText: string; out Confidence: double): string;
const
  SHORT_TEXT_THRESHOLD = 20;        // characters, below this trigrams are too noisy (disabled)
  SHORT_TEXT_PRIORITY = 7;        // Use priority guess only for texts this short or shorter
  WORD_CORRECTION_ALWAYS = 70;      // always try word correction for texts <= this length
  LOW_TRIGRAM_CONFIDENCE = 0.7;     // trigram confidence below which to try words for longer texts
  WORD_GAP_RATIO = 1.05;            // best word score must exceed second best by this factor
  LENGTH_HALF = 32;                 // half-confidence point in trigram count
var
  textTrigrams: TStringArray;
  bestIdx, secondIdx: integer;
  bestDist, secondDist, currentDist: double;
  ScriptInfo: TScriptInfo;
  Script: TScriptType = stOther;
  bestPriority: word;
  wordScore, maxWordScore, secondWordScore: integer;
  wordIdx: integer;
  matchCount: integer;
  rankSum: integer;
  avgRank: double;
  hitRatio: double;
  rankBonus: double;
  trigCount: integer;
  profileSize: integer;
  pos: integer;
  rawConfidence, separationFactor, deltaDist, sumAbsDist: double;
  i, j: integer;

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
  trigCount := 0;
  if Length(AText) < 3 then Exit(UNKNOWN);

  // 1. Quick script detection + CJK refinement
  Result := QuickScriptDetection(AText, ScriptInfo, Script, Confidence);
  if Result <> '' then Exit;

  // 2. Extract trigrams
  textTrigrams := ExtractCharTrigrams(AText);
  if Length(textTrigrams) = 0 then
    Exit(UNKNOWN);

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

  // For shorter texts, if the two best distances are close,
  // prefer a language with higher base frequency (lower Priority).
  if (UTF8Length(AText) <= 40) and (bestIdx >= 0) and (secondIdx >= 0) then
    if (bestDist > 0) and (secondDist > 0) and (secondDist < bestDist * 1.1) then
      if Profiles[secondIdx].Priority < Profiles[bestIdx].Priority then
      begin
        bestIdx := secondIdx;
        bestDist := secondDist;
      end;

  // 4. Build result and confidence
  if bestIdx >= 0 then
  begin
    Result := Profiles[bestIdx].Code;

    // Base confidence from hit ratio and average rank
    matchCount := 0;
    rankSum := 0;
    trigCount := Length(textTrigrams);
    profileSize := Length(Profiles[bestIdx].Trigrams);
    if (trigCount > 0) and (profileSize > 0) then
    begin
      for i := 0 to trigCount - 1 do
      begin
        pos := -1;
        for j := 0 to profileSize - 1 do
          if Profiles[bestIdx].Trigrams[j] = textTrigrams[i] then
          begin
            pos := j;
            Break;
          end;
        if pos >= 0 then
        begin
          Inc(matchCount);
          rankSum := rankSum + (pos + 1);
        end;
      end;

      hitRatio := matchCount / trigCount;

      if matchCount > 0 then
        avgRank := rankSum / matchCount
      else
        avgRank := profileSize;

      if profileSize > 1 then
        rankBonus := 1.0 - (avgRank - 1) / (profileSize - 1)
      else
        rankBonus := 1.0;

      if rankBonus < 0.0 then rankBonus := 0.0;
      if rankBonus > 1.0 then rankBonus := 1.0;

      // Confidence based on the strongest of hit ratio or rank position
      rawConfidence := Math.Max(hitRatio, rankBonus) + 0.1;
      if rawConfidence > 1.0 then rawConfidence := 1.0;

      // Adaptive separation factor: how much better is best than second?
      if (secondIdx >= 0) and (secondDist < 1e9) then
      begin
        deltaDist := secondDist - bestDist;      // positive = best is better
        sumAbsDist := abs(bestDist) + abs(secondDist);
        if sumAbsDist > 0 then
          separationFactor := 0.5 + 0.5 * (deltaDist / sumAbsDist)
        else
          separationFactor := 0.5;
        if separationFactor < 0.0 then separationFactor := 0.0;
        if separationFactor > 1.0 then separationFactor := 1.0;
      end
      else
        separationFactor := 1.0;

      // Apply separation factor, but never reduce below 70% of raw confidence
      if separationFactor >= 0.7 then
        Confidence := rawConfidence * separationFactor
      else
        Confidence := rawConfidence * 0.7;  // lower bound to avoid zeroing out
    end
    else
      Confidence := 0.0;

    // Smooth length-based confidence scaling.
    // At LENGTH_HALF trigrams confidence is halved; it grows toward 1.0 for very long texts.
    if trigCount > 0 then
      Confidence := Confidence * (trigCount / (trigCount + LENGTH_HALF));

    // Extra safety for extremely short inputs
    if trigCount < 3 then
      Confidence := Confidence * 0.5;

    if Confidence > 1.0 then Confidence := 1.0;
    if Confidence < 0.0 then Confidence := 0.0;
  end;

  // 5. Word-based correction for short or low-confidence results
  if (UTF8Length(AText) < WORD_CORRECTION_ALWAYS) and (Confidence < LOW_TRIGRAM_CONFIDENCE) then
  begin
    maxWordScore := 0;
    secondWordScore := 0;
    wordIdx := -1;
    for i := 0 to High(Profiles) do
    begin
      if (Script <> stOther) and not IsLanguageMatchingScript(Profiles[i].Code, Script) then
        Continue;
      wordScore := ScoreByWrds(AText, Profiles[i]);
      if wordScore > maxWordScore then
      begin
        secondWordScore := maxWordScore;
        maxWordScore := wordScore;
        wordIdx := i;
      end
      else if wordScore > secondWordScore then
        secondWordScore := wordScore;
    end;
    // Replace trigram result only if word signal is strong and unambiguous
    if (maxWordScore > 0) and (wordIdx >= 0) then
    begin
      // For short texts a narrow word-score lead is more reliable than noisy trigrams
      if (UTF8Length(AText) <= WORD_CORRECTION_ALWAYS) and (maxWordScore > secondWordScore * WORD_GAP_RATIO) then
      begin
        Result := Profiles[wordIdx].Code;
        Confidence := 0.9;
      end
      else
      if (secondWordScore = 0) or (maxWordScore > secondWordScore * WORD_GAP_RATIO) then
      begin
        Result := Profiles[wordIdx].Code;
        Confidence := 0.95;
      end;
    end;
  end;

  // 6. Post-correction for difficult pairs
  ApplyPostCorrection(Result, Confidence, AText);

  // 7. For very short texts with extremely few trigrams, fall back to priority guess,
  //    then apply unique-character correction for all short texts.
  if (UTF8Length(AText) < SHORT_TEXT_PRIORITY) and (Confidence < 1.0) then
  begin
    bestIdx := -1;
    bestPriority := High(word);
    for i := 0 to High(Profiles) do
    begin
      if IsLanguageMatchingScript(Profiles[i].Code, Script) then
        if Profiles[i].Priority < bestPriority then
        begin
          bestPriority := Profiles[i].Priority;
          bestIdx := i;
        end;
    end;
    if bestIdx < 0 then
    begin
      bestIdx := 0;
      for i := 1 to High(Profiles) do
        if Profiles[i].Priority < Profiles[bestIdx].Priority then
          bestIdx := i;
    end;
    if bestIdx >= 0 then
    begin
      Result := Profiles[bestIdx].Code;
      Confidence := 0.3;   // almost a guess, special chars may raise it later
    end
    else
    begin
      Result := UNKNOWN;
      Confidence := 0.0;
    end;
  end;

  // 8. For all short texts, apply unique-character correction.
  //    This can override the priority guess or refine the trigram result.
  if (UTF8Length(AText) < SHORT_TEXT_THRESHOLD) and (Confidence < 1.0) then
    ApplyShortTextCorrection(Result, Confidence, AText);
end;

{%EndRegion}

{%Region -fold Merge Profiles}

//  Default profiles (defined in separate include file)
{$include langprofiles_data.inc}

// Internal routine that does the actual merge from any TStream
procedure MergeProfilesFromStream(AStream: TStream);
const
  MAX_TRIGRAMS = 100000;
  MAX_WORDS = 100000;            // safety limit
  MAGIC_COMPRESSED: cardinal = $4F525047; // 'GPRO' in little-endian
var
  magic: cardinal;
  isCompressed: boolean;
  totalLangs, Count: integer;
  i, j, trigCount, wordCount, existingIdx: integer;
  codeLen: integer;
  code: string = string.Empty;
  trigLen, wordLen: integer;
  trig: string = string.Empty;
  wrd: string = string.Empty;
  freq: word;
  fileProfiles: array of TProfile = ();
  comprSize: cardinal;
  tempStream: TMemoryStream;
  plainStream: TMemoryStream;
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
          // Read language code
          codeLen := 0;
          plainStream.ReadBuffer(codeLen, SizeOf(codeLen));
          SetLength(code, codeLen);
          if codeLen > 0 then
            plainStream.ReadBuffer(code[1], codeLen);
          fileProfiles[i].Code := code;
          fileProfiles[i].Priority := GetLanguagePriority(code);

          // Read trigrams
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

          // Read optional word dictionary (backward compatible)
          SetLength(fileProfiles[i].Wrds, 0);
          SetLength(fileProfiles[i].WrdFreqs, 0);
          if plainStream.Position < plainStream.Size then
          begin
            wordCount := 0;
            plainStream.ReadBuffer(wordCount, SizeOf(wordCount));
            if (wordCount > 0) and (wordCount <= MAX_WORDS) then
            begin
              SetLength(fileProfiles[i].Wrds, wordCount);
              SetLength(fileProfiles[i].WrdFreqs, wordCount);
              for j := 0 to wordCount - 1 do
              begin
                wordLen := 0;
                plainStream.ReadBuffer(wordLen, SizeOf(wordLen));
                SetLength(wrd, wordLen);
                if wordLen > 0 then
                  plainStream.ReadBuffer(wrd[1], wordLen);
                fileProfiles[i].Wrds[j] := wrd;

                freq := 0;
                plainStream.ReadBuffer(freq, SizeOf(freq));
                fileProfiles[i].WrdFreqs[j] := freq;
              end;
            end;
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
      fileProfiles[i].Priority := GetLanguagePriority(code);

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
      // Old format had no word dictionaries; leave empty.
      SetLength(fileProfiles[i].Wrds, 0);
      SetLength(fileProfiles[i].WrdFreqs, 0);
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
      Profiles[existingIdx].Wrds := fileProfiles[i].Wrds;
      Profiles[existingIdx].WrdFreqs := fileProfiles[i].WrdFreqs;
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
  idx: integer;

initialization
  InitDefaultProfiles;

  // Set default priority for built‑in profiles: English gets 1, others 100
  for idx := 0 to High(Profiles) do
    Profiles[idx].Priority := GetLanguagePriority(Profiles[idx].Code);

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
