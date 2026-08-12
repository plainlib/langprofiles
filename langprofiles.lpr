//-----------------------------------------------------------------------------------
//  langprofiles © 2026 by Alexander Tverskoy
//  Licensed under the MIT License
//  You may obtain a copy of the License at https://opensource.org/licenses/MIT
//-----------------------------------------------------------------------------------
//  This tool generates a compact binary language profile file from a
//  directory of UTF-8 text corpora. For each language the following steps
//  are performed:
//    1. Extract character trigrams using the same function as the language
//       detector (langdetect.ExtractCharTrigrams).
//    2. Count frequencies, compute log-probabilities with Laplace smoothing,
//       sort by descending probability, and keep the top FINAL_TOP trigrams.
//    3. Assign a positional weight: the most probable trigram receives the
//       highest weight (POS_WEIGHT_BASE - rank), so that common trigrams
//       contribute stronger in the distance metric.
//    4. For non-CJK languages, extract frequent words (min length 3),
//       remove words that appear in more than one language, and store
//       the top NumWords with positional weights.
//    5. Pack the language data into a memory stream, compress it with zlib
//       (deflate) using osutils.CompressMemoryStream, and write the
//       compressed block prefixed by its size.
//-----------------------------------------------------------------------------------
//  The resulting binary format is:
//      [totalLangs: Integer]
//      For each language:
//        [compressedSize: Cardinal][zlib-compressed block]
//      The compressed block contains:
//        [codeLen: Integer][langCode: UTF-8 bytes]
//        [trigCount: Integer][for each trigram: trigLen: Integer, trig: UTF-8 bytes, weight: Word]
//        [wordCount: Integer][for each word: wordLen: Integer, word: UTF-8 bytes, weight: Word]
//-----------------------------------------------------------------------------------
//  Zlib compression is used to reduce the profile file size 3-5x without
//  any noticeable runtime cost – decompression is extremely fast (hundreds
//  of MB/s) and the smaller file loads quicker from disk.
//-----------------------------------------------------------------------------------
//  Usage:
//    langprofiles                            run test with .\corpus (max 500, 5 samples)
//    langprofiles <max_len> <iter>           test with custom sample size and count
//    langprofiles gen [-n <N>] [-w <W>]      generate profiles ...
//    langprofiles gen <corpus_dir> <out_file> [-n <N>] [-w <W>] generate with custom paths
//    -n <N>  number of trigrams per language (default 800)
//    -w <W>  number of words per language (default 100)
//-----------------------------------------------------------------------------------

program langprofiles;

{$mode objfpc}{$H+}
{$codepage utf8}

uses
  SysUtils,
  Classes,
  LazUTF8,
  Character,
  Interfaces,
  langdetect,
  osutils,
  langtest;

const
  MIN_TEXT_LENGTH = 10000;                  // minimum corpus size (in characters) to consider a language valid
  DEF_TRIG_TOP = 800;                       // default number of top trigrams to keep per language
  DEF_WORD_TOP = 1000;                      // default number of top unique words to keep per language
  DEF_MIN_WORD_LEN = 3;                     // minimum word length when extracting frequent words (shorter words are too common)
  LOG_SCALE = 1000;                         // multiplier to convert log-probabilities into integer weights
  POS_WEIGHT_BASE = 60000;                  // weight assigned to the most frequent trigram/word, decreasing by rank
  DEF_DEDUP_THRESHOLD = 2;                  // remove words that appear in this many or more different languages
  DEF_TRIG_DEDUP_THRESHOLD = 0;             // default trigram dedup threshold (0=off)
  DEF_FILTER_LETTER = 0;                    // default filter out trigrams containing non-script-letter
  MAGIC_COMPRESSED: array[0..3] of byte = ($47, $50, $52, $4F);  // "GPRO" – magic marker indicating zlib-compressed profile format
  MAGIC_CACHE: array[0..3] of byte = ($43, $43, $4D, $50);  // "CCMP" – corpus cache compressed marker
  DEF_TEST_MAXLEN = 500;                    // default maximum text length for the detection test
  DEF_TEST_ITER = 3;                        // default number of test iterations for each sample length

type
  TTrigWeight = record
    Trig: string;
    LogWeight: integer;
  end;
  TTrigWeightArray = array of TTrigWeight;
  TWordWeightArray = array of word;

  TWordFreq = record
    W: string;
    C: integer;
  end;
  TWordFreqArray = array of TWordFreq;

  TStringListArray = array of TStringList;
  TWordFreqArrayArray = array of TWordFreqArray;

  // QuickSort for word frequency arrays (descending by count, then alphabetically)
  procedure SortWordFreqArray(var A: TWordFreqArray; L, R: integer);
  var
    i, j: integer;
    pivot: TWordFreq;
    tmp: TWordFreq;
  begin
    if L >= R then Exit;
    pivot := A[(L + R) div 2];
    i := L;
    j := R;
    repeat
      while (A[i].C > pivot.C) or ((A[i].C = pivot.C) and (A[i].W < pivot.W)) do Inc(i);
      while (A[j].C < pivot.C) or ((A[j].C = pivot.C) and (A[j].W > pivot.W)) do Dec(j);
      if i <= j then
      begin
        tmp := A[i];
        A[i] := A[j];
        A[j] := tmp;
        Inc(i);
        Dec(j);
      end;
    until i > j;
    SortWordFreqArray(A, L, j);
    SortWordFreqArray(A, i, R);
  end;

  // QuickSort for trigram weight arrays (descending by LogWeight, then alphabetically)
  procedure SortByWeight(var A: TTrigWeightArray; L, R: integer);
  var
    i, j: integer;
    pivot: TTrigWeight;
    tmp: TTrigWeight;
  begin
    if L >= R then Exit;
    pivot := A[(L + R) div 2];
    i := L;
    j := R;
    repeat
      while (A[i].LogWeight > pivot.LogWeight) or ((A[i].LogWeight = pivot.LogWeight) and (A[i].Trig < pivot.Trig)) do Inc(i);
      while (A[j].LogWeight < pivot.LogWeight) or ((A[j].LogWeight = pivot.LogWeight) and (A[j].Trig > pivot.Trig)) do Dec(j);
      if i <= j then
      begin
        tmp := A[i];
        A[i] := A[j];
        A[j] := tmp;
        Inc(i);
        Dec(j);
      end;
    until i > j;
    SortByWeight(A, L, j);
    SortByWeight(A, i, R);
  end;

  // Extract lowercase words (min length, excluding a given word) from corpus and return frequencies
  procedure CollectWordsFiltered(const Corpus: string; MinLen: integer; const ExcludeWord: string; out FreqArr: TWordFreqArray);
  var
    freqMap: TStringList;
    p, charLen, idx: integer;
    ch, token: string;
    i: integer;
  begin
    FreqArr := nil;
    SetLength(FreqArr, 0);
    freqMap := TStringList.Create;
    try
      freqMap.Sorted := True;
      freqMap.Duplicates := dupIgnore;
      p := 1;
      token := '';
      while p <= Length(Corpus) do
      begin
        {$NOTES OFF}
        charLen := UTF8CodepointSize(@Corpus[p]);
        {$NOTES ON}
        if charLen = 0 then
        begin
          Inc(p);
          Continue;
        end;
        ch := Copy(Corpus, p, charLen);
        Inc(p, charLen);
        if ((ch[1] >= 'A') and (ch[1] <= 'Z')) or ((ch[1] >= 'a') and (ch[1] <= 'z')) or (Ord(ch[1]) >= $C0) then
          token := token + UTF8LowerCase(ch)
        else
        begin
          if (UTF8Length(token) >= MinLen) and (UTF8Length(token) <= 30) and (token <> ExcludeWord) then
          begin
            idx := freqMap.IndexOf(token);
            if idx >= 0 then
              freqMap.Objects[idx] := TObject(PtrInt(freqMap.Objects[idx]) + 1)
            else
              freqMap.AddObject(token, TObject(1));
          end;
          token := '';
        end;
      end;
      if (UTF8Length(token) >= MinLen) and (UTF8Length(token) <= 30) and (token <> ExcludeWord) then
      begin
        idx := freqMap.IndexOf(token);
        if idx >= 0 then
          freqMap.Objects[idx] := TObject(PtrInt(freqMap.Objects[idx]) + 1)
        else
          freqMap.AddObject(token, TObject(1));
      end;

      SetLength(FreqArr, freqMap.Count);
      for i := 0 to freqMap.Count - 1 do
      begin
        FreqArr[i].W := freqMap[i];
        FreqArr[i].C := PtrInt(freqMap.Objects[i]);
      end;
    finally
      freqMap.Free;
    end;
  end;

  // Compare two tagged entries ("string#langIndex") by the string part before #0
  function CompareTagged(List: TStringList; Index1, Index2: integer): integer;
  var
    word1, word2: string;
  begin
    word1 := Copy(List[Index1], 1, Pos(#0, List[Index1]) - 1);
    word2 := Copy(List[Index2], 1, Pos(#0, List[Index2]) - 1);
    {$NOTES OFF}
    Result := AnsiCompareStr(word1, word2);
    {$NOTES ON}
  end;

  // Return list of words that appear in at least Threshold different languages
  function FindCommonWordsWithThreshold(const AllWords: array of TWordFreqArray; Threshold: integer): TStringList;
  var
    taggedList: TStringList;
    i, j, start, langCount: integer;
    word, prevTag: string;
  begin
    Result := TStringList.Create;
    Result.Sorted := True;
    Result.Duplicates := dupIgnore;
    if (Length(AllWords) = 0) or (Threshold < 2) then Exit;

    taggedList := TStringList.Create;
    try
      for i := 0 to High(AllWords) do
        for j := 0 to High(AllWords[i]) do
          taggedList.Add(AllWords[i][j].W + #0 + IntToStr(i));

      taggedList.CustomSort(@CompareTagged);

      start := 0;
      while start < taggedList.Count do
      begin
        word := Copy(taggedList[start], 1, Pos(#0, taggedList[start]) - 1);
        langCount := 1;
        prevTag := taggedList[start];
        for i := start + 1 to taggedList.Count - 1 do
        begin
          if Copy(taggedList[i], 1, Length(word)) = word then
          begin
            if taggedList[i] <> prevTag then
            begin
              Inc(langCount);
              prevTag := taggedList[i];
            end;
          end
          else
            Break;
        end;
        if langCount >= Threshold then
          Result.Add(word);
        while (start < taggedList.Count) and (Copy(taggedList[start], 1, Length(word)) = word) do
          Inc(start);
      end;
    finally
      taggedList.Free;
    end;
  end;

  // Return list of trigrams that appear in at least Threshold different languages
  function FindCommonTrigramsWithThreshold(const AllTrigrams: array of TStringList; Threshold: integer): TStringList;
  var
    taggedList: TStringList;
    i, j, start, langCount: integer;
    trig, prevTag: string;
  begin
    Result := TStringList.Create;
    Result.Sorted := True;
    Result.Duplicates := dupIgnore;
    if (Length(AllTrigrams) = 0) or (Threshold < 2) then Exit;

    taggedList := TStringList.Create;
    try
      for i := 0 to High(AllTrigrams) do
        for j := 0 to AllTrigrams[i].Count - 1 do
          taggedList.Add(AllTrigrams[i][j] + #0 + IntToStr(i));

      taggedList.CustomSort(@CompareTagged);

      start := 0;
      while start < taggedList.Count do
      begin
        trig := Copy(taggedList[start], 1, Pos(#0, taggedList[start]) - 1);
        langCount := 1;
        prevTag := taggedList[start];
        for i := start + 1 to taggedList.Count - 1 do
        begin
          if Copy(taggedList[i], 1, Length(trig)) = trig then
          begin
            if taggedList[i] <> prevTag then
            begin
              Inc(langCount);
              prevTag := taggedList[i];
            end;
          end
          else
            Break;
        end;
        if langCount >= Threshold then
          Result.Add(trig);
        while (start < taggedList.Count) and (Copy(taggedList[start], 1, Length(trig)) = trig) do
          Inc(start);
      end;
    finally
      taggedList.Free;
    end;
  end;

  // Remove words that appear in >= DedupThreshold languages from AllWordLists in-place.
  procedure DeduplicateWords(var AllWordLists: array of TWordFreqArray; DedupThreshold: integer; const ValidFiles: TStringList);
  var
    CommonWords: TStringList;
    i, j, newCount: integer;
    CleanArray: TWordFreqArray = nil;
  begin
    if DedupThreshold < 2 then Exit;
    LogToFile('Starting word deduplication...');
    CommonWords := FindCommonWordsWithThreshold(AllWordLists, DedupThreshold);
    LogToFile(Format('Word dedup: found %d common words appearing in >= %d languages.', [CommonWords.Count, DedupThreshold]));
    if CommonWords.Count > 0 then
    begin
      for i := 0 to High(AllWordLists) do
      begin
        LogToFile(Format('  Dedup words [%d/%d] %s ...', [i + 1, Length(AllWordLists), ValidFiles[i]]));
        SetLength(CleanArray, Length(AllWordLists[i]));
        newCount := 0;
        for j := 0 to High(AllWordLists[i]) do
          if CommonWords.IndexOf(AllWordLists[i][j].W) < 0 then
          begin
            CleanArray[newCount] := AllWordLists[i][j];
            Inc(newCount);
          end;
        SetLength(CleanArray, newCount);
        AllWordLists[i] := CleanArray;
      end;
    end;
    CommonWords.Free;
    LogToFile('Word deduplication complete.');
  end;

  // Remove trigrams that appear in >= TrigDedupThreshold languages from AllTrigramLists in-place
  procedure DeduplicateTrigrams(var AllTrigramLists: array of TStringList; TrigDedupThreshold: integer; const ValidFiles: TStringList);
  var
    TrigCommonList: TStringList;
    i, j: integer;
    CleanList: TStringList;
    Trig: string;
  begin
    if TrigDedupThreshold <= 1 then Exit;
    LogToFile('Starting trigram deduplication...');
    TrigCommonList := FindCommonTrigramsWithThreshold(AllTrigramLists, TrigDedupThreshold);
    LogToFile(Format('Trig dedup: found %d common trigrams appearing in >= %d languages.', [TrigCommonList.Count, TrigDedupThreshold]));
    if TrigCommonList.Count > 0 then
    begin
      for i := 0 to High(AllTrigramLists) do
      begin
        if AllTrigramLists[i] = nil then Continue;
        LogToFile(Format('  Dedup trigrams [%d/%d] %s ...', [i + 1, Length(AllTrigramLists), ValidFiles[i]]));
        CleanList := TStringList.Create;
        try
          for j := 0 to AllTrigramLists[i].Count - 1 do
          begin
            Trig := AllTrigramLists[i][j];
            if TrigCommonList.IndexOf(Trig) < 0 then   // binary search, fast
              CleanList.AddObject(Trig, AllTrigramLists[i].Objects[j]);
          end;
          AllTrigramLists[i].Free;
          AllTrigramLists[i] := CleanList;
          CleanList := nil;   // prevent double-free
        finally
          CleanList.Free;
        end;
      end;
    end;
    TrigCommonList.Free;
    LogToFile('Trigram deduplication complete.');
  end;

  // Return True if the trigram contains no obvious junk characters.
  // FilterMode: 1 = remove control/format/private-use/surrogate/unassigned characters (keep letters, digits, punctuation, spaces),
  //             2 = strict script filter (only letters of the script + space).
  function IsCleanTrigram(const trig: string; Script: TScriptType; FilterMode: integer): boolean;
  var
    p: integer;
    cp: UCS4Char;
    charLen: integer;
    cat: TUnicodeCategory;
  begin
    Result := False;
    p := 1;
    while p <= Length(trig) do
    begin
      {$NOTES OFF}
      charLen := UTF8CodepointSize(@trig[p]);
      {$NOTES ON}
      if charLen = 0 then Exit;
      cp := UTF8CodepointToUnicode(PChar(@trig[p]), charLen);
      case FilterMode of
        1: begin
          // Allow space (U+0020) for trigrams, remove other control/format/private-use/surrogates/unassigned
          if cp = $20 then
          begin
            Inc(p, charLen);
            Continue;
          end;
          cat := TCharacter.GetUnicodeCategory(widechar(cp));
          if cat in [TUnicodeCategory.ucControl, TUnicodeCategory.ucFormat, TUnicodeCategory.ucSurrogate,
            TUnicodeCategory.ucPrivateUse, TUnicodeCategory.ucUnassigned] then
            Exit;
        end;
        2: begin
          // Strict script filter: only letters belonging to the script, plus space
          if cp = $20 then
          begin
            Inc(p, charLen);
            Continue;
          end;
          {$NOTES OFF}
          if not TCharacter.IsLetter(widechar(cp)) then Exit;
          {$NOTES ON}
          if not TLangDetect.IsCharOfScript(cp, Script) then Exit;
        end;
        else
          Exit; // unknown mode – reject
      end;
      Inc(p, charLen);
    end;
    Result := True;
  end;

  // Return True if the word contains no obvious junk characters.
  // FilterMode: 1 = remove control/format/private-use/surrogate/unassigned and any whitespace (words can't have spaces),
  //             2 = strict script filter (only letters of the script).
  function IsCleanWord(const word: string; Script: TScriptType; FilterMode: integer): boolean;
  var
    p: integer;
    cp: UCS4Char;
    charLen: integer;
    cat: TUnicodeCategory;
  begin
    Result := False;
    p := 1;
    while p <= Length(word) do
    begin
      {$NOTES OFF}
      charLen := UTF8CodepointSize(@word[p]);
      {$NOTES ON}
      if charLen = 0 then Exit;
      cp := UTF8CodepointToUnicode(PChar(@word[p]), charLen);
      case FilterMode of
        1: begin
          // No whitespace allowed in words; reject control/format/private-use/surrogates/unassigned
          cat := TCharacter.GetUnicodeCategory(widechar(cp));
          if cat in [TUnicodeCategory.ucControl, TUnicodeCategory.ucFormat, TUnicodeCategory.ucSurrogate,
            TUnicodeCategory.ucPrivateUse, TUnicodeCategory.ucUnassigned, TUnicodeCategory.ucSpaceSeparator,
            TUnicodeCategory.ucLineSeparator, TUnicodeCategory.ucParagraphSeparator] then
            Exit;
        end;
        2: begin
          {$NOTES OFF}
          if not TCharacter.IsLetter(widechar(cp)) then Exit;
          {$NOTES ON}
          if not TLangDetect.IsCharOfScript(cp, Script) then Exit;
        end;
        else
          Exit;
      end;
      Inc(p, charLen);
    end;
    Result := True;
  end;

  // Build full path relative to the application directory
  function AppPath(const RelativePath: string): string;
  begin
    Result := ConcatPaths([ExtractFilePath(ParamStr(0)), RelativePath]);
  end;

  // Save prepared corpus data (trigrams and words) into a compressed cache file
  procedure SaveCorpusCache(const CacheFileName: string; const ValidFiles: TStringList;
  const AllTrigramLists: array of TStringList; const AllWordLists: array of TWordFreqArray);
  var
    plainStream, comprStream: TMemoryStream;
    fs: TFileStream;
    i, j, Count, len, freq: integer;
    code: string;
  begin
    LogToFile(Format('Compressing cache data: %d trigram lists, %d word lists', [Length(AllTrigramLists), Length(AllWordLists)]));
    plainStream := TMemoryStream.Create;
    try
      Count := ValidFiles.Count;
      plainStream.WriteBuffer(Count, SizeOf(Count));
      for i := 0 to Count - 1 do
      begin
        code := ValidFiles[i];
        len := Length(code);
        plainStream.WriteBuffer(len, SizeOf(len));
        if len > 0 then
          plainStream.WriteBuffer(code[1], len);

        // Save trigrams
        if (AllTrigramLists[i] <> nil) then
          Count := AllTrigramLists[i].Count
        else
          Count := 0;
        plainStream.WriteBuffer(Count, SizeOf(Count));
        for j := 0 to Count - 1 do
        begin
          code := AllTrigramLists[i][j];
          len := Length(code);
          plainStream.WriteBuffer(len, SizeOf(len));
          if len > 0 then
            plainStream.WriteBuffer(code[1], len);
          freq := PtrInt(AllTrigramLists[i].Objects[j]);
          plainStream.WriteBuffer(freq, SizeOf(freq));
        end;

        // Save words
        Count := Length(AllWordLists[i]);
        plainStream.WriteBuffer(Count, SizeOf(Count));
        for j := 0 to Count - 1 do
        begin
          code := AllWordLists[i][j].W;
          len := Length(code);
          plainStream.WriteBuffer(len, SizeOf(len));
          if len > 0 then
            plainStream.WriteBuffer(code[1], len);
          freq := AllWordLists[i][j].C;
          plainStream.WriteBuffer(freq, SizeOf(freq));
        end;
      end;

      plainStream.Position := 0;
      comprStream := TOS.CompressMemoryStream(plainStream);
      try
        LogToFile('Cache compressed, saving to file...');
        fs := TFileStream.Create(CacheFileName, fmCreate);
        try
          fs.WriteBuffer(MAGIC_CACHE[0], SizeOf(MAGIC_CACHE));
          fs.CopyFrom(comprStream, comprStream.Size);
        finally
          fs.Free;
        end;
      finally
        comprStream.Free;
      end;
    finally
      plainStream.Free;
    end;
  end;

  // Load prepared corpus data from a compressed cache file
  function LoadCorpusCache(const CacheFileName: string; out ValidFiles: TStringList; out AllTrigramLists: TStringListArray;
    out AllWordLists: TWordFreqArrayArray): boolean;
  var
    fs: TFileStream;
    magic: array[0..3] of byte;
    comprStream, plainStream: TMemoryStream;
    i, j, totalLangs, Count, len, freq: integer;
    code, trig, word: string;
  begin
    Result := False;
    if not FileExists(CacheFileName) then Exit;

    AllTrigramLists := nil;
    AllWordLists := nil;
    code := string.Empty;
    trig := string.Empty;
    word := string.Empty;

    LogToFile('Loading cache from file...');
    fs := TFileStream.Create(CacheFileName, fmOpenRead);
    try
      // Check magic
      magic[0] := 0;
      magic[1] := 0;
      magic[2] := 0;
      magic[3] := 0;
      fs.ReadBuffer(magic[0], SizeOf(magic));
      if (magic[0] <> MAGIC_CACHE[0]) or (magic[1] <> MAGIC_CACHE[1]) or (magic[2] <> MAGIC_CACHE[2]) or
        (magic[3] <> MAGIC_CACHE[3]) then
      begin
        LogToFile('Invalid cache format (missing CCMP marker).');
        Exit;
      end;

      // Read the rest as compressed data
      comprStream := TMemoryStream.Create;
      try
        comprStream.CopyFrom(fs, fs.Size - fs.Position);
        comprStream.Position := 0;
        LogToFile('Decompressing cache data...');
        plainStream := TOS.DecompressMemoryStream(comprStream);
        try
          plainStream.Position := 0;
          totalLangs := 0;
          plainStream.ReadBuffer(totalLangs, SizeOf(totalLangs));
          ValidFiles := TStringList.Create;
          SetLength(AllTrigramLists, totalLangs);
          SetLength(AllWordLists, totalLangs);
          for i := 0 to totalLangs - 1 do
          begin
            len := 0;
            plainStream.ReadBuffer(len, SizeOf(len));
            SetLength(code, len);
            if len > 0 then
              plainStream.ReadBuffer(code[1], len);
            ValidFiles.Add(code);

            // Read trigrams
            Count := 0;
            plainStream.ReadBuffer(Count, SizeOf(Count));
            AllTrigramLists[i] := TStringList.Create;
            for j := 0 to Count - 1 do
            begin
              len := 0;
              plainStream.ReadBuffer(len, SizeOf(len));
              SetLength(trig, len);
              if len > 0 then
                plainStream.ReadBuffer(trig[1], len);
              freq := 0;
              plainStream.ReadBuffer(freq, SizeOf(freq));
              AllTrigramLists[i].AddObject(trig, TObject(PtrInt(freq)));
            end;

            // Read words
            Count := 0;
            plainStream.ReadBuffer(Count, SizeOf(Count));
            SetLength(AllWordLists[i], Count);
            for j := 0 to Count - 1 do
            begin
              len := 0;
              plainStream.ReadBuffer(len, SizeOf(len));
              SetLength(word, len);
              if len > 0 then
                plainStream.ReadBuffer(word[1], len);
              freq := 0;
              plainStream.ReadBuffer(freq, SizeOf(freq));
              AllWordLists[i][j].W := word;
              AllWordLists[i][j].C := freq;
            end;
          end;
          Result := True;
          LogToFile('Cache loaded successfully.');
        finally
          plainStream.Free;
        end;
      finally
        comprStream.Free;
      end;
    finally
      fs.Free;
    end;
  end;

  // Filter trigrams and words in already aggregated lists using the current filter mode.
  procedure FilterCorpusData(var AllTrigramLists: array of TStringList; var AllWordLists: array of TWordFreqArray;
  const ValidFiles: TStringList; FilterMode: integer; NumWords: integer);
  var
    i, j, newCount: integer;
    Script: TScriptType;
    CleanTrigList: TStringList;
    CleanWordArray: TWordFreqArray = nil;
  begin
    if FilterMode <= 0 then Exit;
    LogToFile('Filtering data (mode ' + IntToStr(FilterMode) + ')...');
    for i := 0 to High(AllTrigramLists) do
    begin
      Script := TLangDetect.GetScriptByLang(ValidFiles[i]);
      LogToFile(Format('  Filtering [%d/%d] %s ...', [i + 1, Length(AllTrigramLists), ValidFiles[i]]));

      // Filter trigrams – build a new clean list
      if AllTrigramLists[i] <> nil then
      begin
        CleanTrigList := TStringList.Create;
        try
          for j := 0 to AllTrigramLists[i].Count - 1 do
            if IsCleanTrigram(AllTrigramLists[i][j], Script, FilterMode) then
              CleanTrigList.AddObject(AllTrigramLists[i][j], AllTrigramLists[i].Objects[j]);
          AllTrigramLists[i].Free;
          AllTrigramLists[i] := CleanTrigList;
          CleanTrigList := nil;   // prevent double free
        finally
          CleanTrigList.Free;
        end;
      end;

      // Filter words – build a new clean array
      if NumWords > 0 then
      begin
        SetLength(CleanWordArray, Length(AllWordLists[i]));
        newCount := 0;
        for j := 0 to High(AllWordLists[i]) do
          if IsCleanWord(AllWordLists[i][j].W, Script, FilterMode) then
          begin
            CleanWordArray[newCount] := AllWordLists[i][j];
            Inc(newCount);
          end;
        SetLength(CleanWordArray, newCount);
        AllWordLists[i] := CleanWordArray;
      end;
    end;
    LogToFile('Filtering complete.');
  end;

  // Print short usage instructions and exit
  procedure ShowHelp;
  begin
    LogToFile('Language profile generator and detection test utility');
    LogToFile('');
    LogToFile('Syntax: langprofiles [mode] [required args] [options]');
    LogToFile('Options (starting with -) can be placed anywhere, but the recommended order is');
    LogToFile('positional arguments first, then options.');
    LogToFile('');
    LogToFile('TEST MODE');
    LogToFile('  langprofiles [max_len] [iter] [-d <corpus_dir>] [-pf <profile_file>]');
    LogToFile('      max_len         : max sample length in characters (default 500)');
    LogToFile('      iter            : number of test iterations per file (default 3)');
    LogToFile('      -d <corpus_dir> : corpus folder to test (default .\corpus)');
    LogToFile('      -pf <file>      : load extra detection profile');
    LogToFile('  Examples:');
    LogToFile('    langprofiles');
    LogToFile('    langprofiles 300 5');
    LogToFile('    langprofiles 300 5 -d mycorpus');
    LogToFile('    langprofiles 200 2 -d testdata -pf custom.dat');
    LogToFile('');
    LogToFile('GENERATION MODE');
    LogToFile('  langprofiles gen [corpus_dir] [out_file] [options]');
    LogToFile('      corpus_dir      : input folder with .txt corpora (default .\corpus)');
    LogToFile('      out_file        : output profile file (default .\langprofiles.dat)');
    LogToFile('      Options (after positional args):');
    LogToFile('        -n <N>        : number of trigrams per language (default 800)');
    LogToFile('        -w <W>        : number of words per language (default 1000)');
    LogToFile('        -wl <min_len> : minimum word length (default 3)');
    LogToFile('        -d <threshold>: word dedup threshold (default 2)');
    LogToFile('        -td <threshold>: trigram dedup threshold (default 0 = off)');
    LogToFile('        -f <0|1|2>    : filter mode (0=off, 1=remove obvious junk, 2=strict script filter)');
    LogToFile('        -fdt             : force deduplication of trigrams even when loading from cache');
    LogToFile('        -fdw             : force deduplication of words even when loading from cache');
    LogToFile('  Examples (options at the end):');
    LogToFile('    langprofiles gen');
    LogToFile('    langprofiles gen mycorpus out.dat -n 1000 -w 500');
    LogToFile('    langprofiles gen mycorpus out.dat -d 3 -td 5 -f 1');
    LogToFile('');
    LogToFile('INFO MODE');
    LogToFile('  langprofiles -i / -info [-pf <profile_file>]');
    LogToFile('      Show loaded profile details.');
    LogToFile('');
    LogToFile('  langprofiles /? /help --help ?   This help.');
    WaitForEsc;
    Halt(0);
  end;

var
  corpusDir, outFile, txtFilePath, langCode, fullPath: string;
  sr: TSearchRec;
  validFiles: TStringList;
  i, j, k, totalLangs, trigCount, codeLen, trigLen, wordCount, wordLen: integer;
  fs: TFileStream;
  txtOut: TextFile;
  trigArray: TStringArray;
  freqMap: TStringList;
  weights: TTrigWeightArray = ();
  totalTrigrams, vocabSize: integer;
  logProb: double;
  posWeight: word;
  plainStream: TMemoryStream;
  comprStream: TMemoryStream;
  comprSize: cardinal;
  TestMaxLen: integer;
  TestIter: integer;
  NumTrigrams: integer;
  NumWords: integer;
  MinWordLen: integer;
  DedupThreshold: integer;
  TrigDedupThreshold: integer;
  corpusText: string;
  IsCJKLang: boolean;
  AllWordLists: TWordFreqArrayArray = nil;
  FinalWords: array of TStringArray = nil;
  FinalWeights: array of TWordWeightArray = nil;
  DedupedList: TWordFreqArray = nil;
  wIdx: integer;
  ProfileFile: string = '';
  CorpusDirForTest: string;
  MaxLenSet: boolean = False;
  AllTrigramLists: TStringListArray = nil;   // stores unique trigrams with counts as Objects
  trigObjCount: integer;
  FilterLetter: integer;
  ForceDedupTrig: boolean;
  ForceDedupWord: boolean;
  Script: TScriptType;
  cacheLoaded: boolean;
  CacheFile: string;
begin
  // Check for help request (any of the known help flags as first parameter)
  if (ParamCount >= 1) and ((ParamStr(1) = '/?') or (ParamStr(1) = '?') or (ParamStr(1) = '--?') or
    (ParamStr(1) = '--help') or (LowerCase(ParamStr(1)) = 'help') or (ParamStr(1) = '/help')) then
    ShowHelp;

  TestMaxLen := DEF_TEST_MAXLEN;
  TestIter := DEF_TEST_ITER;
  NumTrigrams := DEF_TRIG_TOP;
  NumWords := DEF_WORD_TOP;
  MinWordLen := DEF_MIN_WORD_LEN;
  DedupThreshold := DEF_DEDUP_THRESHOLD;
  TrigDedupThreshold := DEF_TRIG_DEDUP_THRESHOLD;
  FilterLetter := DEF_FILTER_LETTER;
  ForceDedupTrig := False;
  ForceDedupWord := False;

  TLangDetect.LoadProfiles;

  // Parse command line
  for i := 1 to ParamCount do
    if SameText(ParamStr(i), '-i') or SameText(ParamStr(i), '-info') then
    begin
      ProfileFile := '';
      for j := i + 1 to ParamCount do
        if (ParamStr(j) = '-pf') and (j + 1 <= ParamCount) then
        begin
          ProfileFile := ParamStr(j + 1);
          Break;
        end;
      langtest.ShowLoadedProfilesInfo(ProfileFile);
      WaitForEsc;
      Halt;
    end;

  if (ParamCount >= 1) and SameText(ParamStr(1), 'gen') then
  begin
    corpusDir := AppPath('corpus');
    outFile := AppPath('langprofiles.dat');
    i := 2;
    while i <= ParamCount do
    begin
      if (ParamStr(i) = '-n') and (i + 1 <= ParamCount) then
      begin
        NumTrigrams := StrToIntDef(ParamStr(i + 1), NumTrigrams);
        Inc(i, 2);
        Continue;
      end;
      if (ParamStr(i) = '-w') and (i + 1 <= ParamCount) then
      begin
        NumWords := StrToIntDef(ParamStr(i + 1), NumWords);
        Inc(i, 2);
        Continue;
      end;
      if (ParamStr(i) = '-wl') and (i + 1 <= ParamCount) then
      begin
        MinWordLen := StrToIntDef(ParamStr(i + 1), MinWordLen);
        Inc(i, 2);
        Continue;
      end;
      if (ParamStr(i) = '-d') and (i + 1 <= ParamCount) then
      begin
        DedupThreshold := StrToIntDef(ParamStr(i + 1), DedupThreshold);
        if DedupThreshold < 2 then DedupThreshold := 2;
        Inc(i, 2);
        Continue;
      end;
      if (ParamStr(i) = '-td') and (i + 1 <= ParamCount) then
      begin
        TrigDedupThreshold := StrToIntDef(ParamStr(i + 1), DEF_TRIG_DEDUP_THRESHOLD);
        Inc(i, 2);
        Continue;
      end;
      if (ParamStr(i) = '-f') and (i + 1 <= ParamCount) then
      begin
        FilterLetter := StrToIntDef(ParamStr(i + 1), DEF_FILTER_LETTER);
        if FilterLetter > 2 then FilterLetter := 2;
        Inc(i, 2);
        Continue;
      end;
      if (ParamStr(i) = '-fdt') then
      begin
        ForceDedupTrig := True;
        Inc(i);
        Continue;
      end;
      if (ParamStr(i) = '-fdw') then
      begin
        ForceDedupWord := True;
        Inc(i);
        Continue;
      end;
      if corpusDir = AppPath('corpus') then
        corpusDir := ParamStr(i)
      else if outFile = AppPath('langprofiles.dat') then
        outFile := ParamStr(i);
      Inc(i);
    end;
  end
  else
  begin
    ProfileFile := '';
    CorpusDirForTest := AppPath('corpus');
    TestMaxLen := DEF_TEST_MAXLEN;
    TestIter := DEF_TEST_ITER;
    i := 1;
    while i <= ParamCount do
    begin
      if (ParamStr(i) = '-pf') and (i + 1 <= ParamCount) then
      begin
        ProfileFile := ParamStr(i + 1);
        Inc(i, 2);
        Continue;
      end;
      if (ParamStr(i) = '-d') and (i + 1 <= ParamCount) then
      begin
        CorpusDirForTest := ParamStr(i + 1);
        Inc(i, 2);
        Continue;
      end;
      if not MaxLenSet then
      begin
        TestMaxLen := StrToIntDef(ParamStr(i), TestMaxLen);
        MaxLenSet := True;
      end
      else
        TestIter := StrToIntDef(ParamStr(i), TestIter);
      Inc(i);
    end;
    if TestIter < 1 then TestIter := 1;
    RunLanguageDetectionTest(CorpusDirForTest, TestMaxLen, TestIter, ProfileFile);
    WaitForEsc;
    Halt;
  end;

  // Generation mode
  corpusDir := IncludeTrailingPathDelimiter(corpusDir);
  txtFilePath := ChangeFileExt(outFile, '.txt');

  // Build cache file name: <corpus_folder_name>.dat located next to the executable
  CacheFile := AppPath(ExtractFileName(ExcludeTrailingPathDelimiter(corpusDir)) + '.dat');

  cacheLoaded := False;
  // Try to load cached prepared data
  if FileExists(CacheFile) then
  begin
    LogToFile('Found corpus cache file, trying to load...');
    if LoadCorpusCache(CacheFile, validFiles, AllTrigramLists, AllWordLists) then
    begin
      totalLangs := validFiles.Count;
      LogToFile(Format('Loaded cached data for %d languages.', [totalLangs]));
      cacheLoaded := True;
      FilterCorpusData(AllTrigramLists, AllWordLists, validFiles, FilterLetter, NumWords);
    end
    else
      LogToFile('Failed to load cache; will regenerate from scratch.');
  end;

  if not cacheLoaded then
  begin
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
            LogToFile('Skipping ' + langCode + ' (corpus too short)');
          Free;
        end;
      until FindNext(sr) <> 0;
      FindClose(sr);
    end;
    if validFiles.Count = 0 then
    begin
      LogToFile('No valid corpora found.');
      Halt(1);
    end;
    totalLangs := validFiles.Count;

    // Allocate arrays for raw data
    SetLength(AllWordLists, totalLangs);
    SetLength(AllTrigramLists, totalLangs);
    for i := 0 to totalLangs - 1 do
    begin
      SetLength(AllWordLists[i], 0);
      AllTrigramLists[i] := nil;
    end;

    // Single collection pass
    LogToFile('Collecting trigrams and words...');
    for i := 0 to totalLangs - 1 do
    begin
      langCode := validFiles[i];
      LogToFile(Format('  Collect [%d/%d] %s ...', [i + 1, totalLangs, langCode]));
      fullPath := corpusDir + langCode + '.txt';

      with TStringList.Create do
      begin
        LoadFromFile(fullPath, TEncoding.UTF8);
        corpusText := Text;
        trigArray := TLangDetect.ExtractCharTrigrams(Text);
        Free;
      end;

      // Determine script for current language (used only when -f is active)
      Script := TLangDetect.GetScriptByLang(langCode);

      // Filter out trigrams containing non-letter symbols or symbols from other scripts
      if (FilterLetter >= 1) and (trigArray <> nil) then
      begin
        j := 0;
        for k := 0 to High(trigArray) do
          if IsCleanTrigram(trigArray[k], Script, FilterLetter) then
          begin
            trigArray[j] := trigArray[k];
            Inc(j);
          end;
        SetLength(trigArray, j);
      end;

      // Process trigrams
      if trigArray <> nil then
      begin
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

        AllTrigramLists[i] := TStringList.Create;
        for j := 0 to freqMap.Count - 1 do
          AllTrigramLists[i].AddObject(freqMap[j], freqMap.Objects[j]);
        freqMap.Free;
      end;

      // Collect words for later dedup
      if NumWords > 0 then
      begin
        IsCJKLang := (langCode = 'zh') or (langCode = 'zh-CN') or (langCode = 'zh-TW') or (langCode = 'ja') or (langCode = 'ko');
        if not IsCJKLang then
        begin
          CollectWordsFiltered(corpusText, MinWordLen, UTF8LowerCase(langCode), AllWordLists[i]);

          // Filter out words containing non-letter symbols or symbols from other scripts
          if (FilterLetter >= 1) and (Length(AllWordLists[i]) > 0) then
          begin
            j := 0;
            for k := 0 to High(AllWordLists[i]) do
              if IsCleanWord(AllWordLists[i][k].W, Script, FilterLetter) then
              begin
                AllWordLists[i][j] := AllWordLists[i][k];
                Inc(j);
              end;
            SetLength(AllWordLists[i], j);
          end;
        end;
      end;
    end;

    // Deduplication before caching
    if NumWords > 0 then
      DeduplicateWords(AllWordLists, DedupThreshold, validFiles);
    DeduplicateTrigrams(AllTrigramLists, TrigDedupThreshold, validFiles);

    // Save prepared data (already deduplicated) into compressed cache
    LogToFile('Saving prepared data to cache...');
    SaveCorpusCache(CacheFile, validFiles, AllTrigramLists, AllWordLists);
    LogToFile('Cached prepared data to ' + CacheFile);
  end;

  // If data was loaded from cache and force dedup is enabled, run deduplication on the loaded data.
  if cacheLoaded and (ForceDedupWord or ForceDedupTrig) then
  begin
    LogToFile('Forcing deduplication on cached data...');
    if ForceDedupWord and (NumWords > 0) then
      DeduplicateWords(AllWordLists, DedupThreshold, validFiles);
    if ForceDedupTrig then
      DeduplicateTrigrams(AllTrigramLists, TrigDedupThreshold, validFiles);
    // Cache file is not updated; regenerate without -fd to update the cache permanently.
  end;

  // Build final word lists (from possibly deduplicated AllWordLists)
  LogToFile('Building final word lists...');
  SetLength(FinalWords, totalLangs);
  SetLength(FinalWeights, totalLangs);
  for i := 0 to totalLangs - 1 do
  begin
    LogToFile(Format('  Building words [%d/%d] %s ...', [i + 1, totalLangs, validFiles[i]]));
    SetLength(FinalWords[i], 0);
    SetLength(FinalWeights[i], 0);

    if Length(AllWordLists[i]) > 0 then
    begin
      // Already deduplicated, just sort and truncate
      SetLength(DedupedList, Length(AllWordLists[i]));
      for j := 0 to High(AllWordLists[i]) do
        DedupedList[j] := AllWordLists[i][j];

      if Length(DedupedList) > 1 then
        SortWordFreqArray(DedupedList, 0, High(DedupedList));

      if Length(DedupedList) > NumWords then
        SetLength(DedupedList, NumWords);

      SetLength(FinalWords[i], Length(DedupedList));
      SetLength(FinalWeights[i], Length(DedupedList));
      for wIdx := 0 to High(DedupedList) do
      begin
        FinalWords[i][wIdx] := DedupedList[wIdx].W;
        FinalWeights[i][wIdx] := word(POS_WEIGHT_BASE - wIdx);
      end;
    end;
  end;

  // Write final profile file
  LogToFile('Writing final profile file...');
  fs := TFileStream.Create(outFile, fmCreate);
  try
    fs.WriteBuffer(MAGIC_COMPRESSED[0], SizeOf(MAGIC_COMPRESSED));
    fs.WriteBuffer(totalLangs, SizeOf(totalLangs));

    AssignFile(txtOut, txtFilePath);
    Rewrite(txtOut);

    for i := 0 to totalLangs - 1 do
    begin
      langCode := validFiles[i];
      LogToFile(Format('  Write [%d/%d] %s ...', [i + 1, totalLangs, langCode]));

      // Compute trigram weights from stored data (already deduplicated if TrigDedupThreshold > 1)
      SetLength(weights, 0);
      trigCount := 0;
      if AllTrigramLists[i] <> nil then
      begin
        totalTrigrams := 0;
        for j := 0 to AllTrigramLists[i].Count - 1 do
          Inc(totalTrigrams, PtrInt(AllTrigramLists[i].Objects[j]));
        vocabSize := AllTrigramLists[i].Count;

        SetLength(weights, AllTrigramLists[i].Count);
        for j := 0 to AllTrigramLists[i].Count - 1 do
        begin
          trigObjCount := PtrInt(AllTrigramLists[i].Objects[j]);
          logProb := ln((trigObjCount + 1) / (totalTrigrams + vocabSize));
          weights[j].Trig := AllTrigramLists[i][j];
          weights[j].LogWeight := Round(logProb * LOG_SCALE);
        end;

        // Sort and truncate
        if Length(weights) > 1 then
          SortByWeight(weights, 0, High(weights));
        if Length(weights) > NumTrigrams then
          SetLength(weights, NumTrigrams);
        trigCount := Length(weights);
      end;

      wordCount := Length(FinalWords[i]);

      // Pack to compressed stream
      plainStream := TMemoryStream.Create;
      try
        codeLen := Length(langCode);
        plainStream.WriteBuffer(codeLen, SizeOf(codeLen));
        if codeLen > 0 then plainStream.WriteBuffer(langCode[1], codeLen);

        plainStream.WriteBuffer(trigCount, SizeOf(trigCount));
        for j := 0 to trigCount - 1 do
        begin
          trigLen := Length(weights[j].Trig);
          plainStream.WriteBuffer(trigLen, SizeOf(trigLen));
          if trigLen > 0 then plainStream.WriteBuffer(weights[j].Trig[1], trigLen);
          posWeight := word(POS_WEIGHT_BASE - j);
          plainStream.WriteBuffer(posWeight, SizeOf(posWeight));
        end;

        plainStream.WriteBuffer(wordCount, SizeOf(wordCount));
        for j := 0 to wordCount - 1 do
        begin
          wordLen := Length(FinalWords[i][j]);
          plainStream.WriteBuffer(wordLen, SizeOf(wordLen));
          if wordLen > 0 then plainStream.WriteBuffer(FinalWords[i][j][1], wordLen);
          plainStream.WriteBuffer(FinalWeights[i][j], SizeOf(word));
        end;

        comprStream := TOS.CompressMemoryStream(plainStream);
        try
          comprSize := comprStream.Size;
          fs.WriteBuffer(comprSize, SizeOf(comprSize));
          fs.CopyFrom(comprStream, comprSize);
        finally
          comprStream.Free;
        end;
      finally
        plainStream.Free;
      end;

      LogToFile(Format('  %d trigrams, %d words', [trigCount, wordCount]));
      Write(txtOut, langCode, ' =');
      for j := 0 to trigCount - 1 do
        Write(txtOut, ' "', weights[j].Trig, '"');
      Writeln(txtOut);
      if wordCount > 0 then
      begin
        Write(txtOut, langCode, ' =');
        for j := 0 to wordCount - 1 do
          Write(txtOut, ' "', FinalWords[i][j], '"');
        Writeln(txtOut);
      end;
    end;

    CloseFile(txtOut);
  finally
    fs.Free;
  end;

  // Cleanup
  for i := 0 to totalLangs - 1 do
    AllTrigramLists[i].Free;

  LogToFile('Done. Profiles saved to ' + outFile);
  LogToFile('Text dump saved to ' + txtFilePath);
  LogToFile('Press any key to exit (ESC to quit)...');
  WaitForEsc;
end.
