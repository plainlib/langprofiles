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
  DEF_DEDUP_THRESHOLD = 3;                  // remove words that appear in this many or more different languages
  MAGIC_COMPRESSED: array[0..3] of byte = ($47, $50, $52, $4F);  // "GPRO" – magic marker indicating zlib-compressed profile format
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

  // Custom comparer for tagged list
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

  // Find words that appear in >= Threshold languages.
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
      // Build flat list "word#langIndex"
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
  corpusText: string;
  IsCJKLang: boolean;
  AllWordLists: array of TWordFreqArray = nil;
  FinalWords: array of TStringArray = nil;
  FinalWeights: array of TWordWeightArray = nil;
  CommonWords: TStringList;
  DedupedList: TWordFreqArray = nil;
  wIdx: integer;
  ProfileFile: string = '';
  MaxLenSet: boolean = False;
begin
  TestMaxLen := DEF_TEST_MAXLEN;
  TestIter := DEF_TEST_ITER;
  NumTrigrams := DEF_TRIG_TOP;
  NumWords := DEF_WORD_TOP;
  MinWordLen := DEF_MIN_WORD_LEN;
  DedupThreshold := DEF_DEDUP_THRESHOLD;

  // Parse command line
  // Check for -i / -info before anything else
  for i := 1 to ParamCount do
    if SameText(ParamStr(i), '-i') or SameText(ParamStr(i), '-info') then
    begin
      ProfileFile := '';
      // Look for -pf argument among the rest
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

  // Branch: generation mode or test mode
  if (ParamCount >= 1) and SameText(ParamStr(1), 'gen') then
  begin
    // Generation mode
    corpusDir := '.\corpus';
    outFile := '.\langprofiles.dat';
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
      if corpusDir = '.\corpus' then
        corpusDir := ParamStr(i)
      else if outFile = '.\langprofiles.dat' then
        outFile := ParamStr(i);
      Inc(i);
    end;
  end
  else
  begin
    // Test mode (including no parameters)
    ProfileFile := '';
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
      // First non-option numeric value is MaxLen, second is Iter
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
    RunLanguageDetectionTest('.\corpus', TestMaxLen, TestIter, ProfileFile);
    WaitForEsc;
    Halt;
  end;

  // Below only reached in "gen" mode
  corpusDir := IncludeTrailingPathDelimiter(corpusDir);
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

  // Phase 1: collect trigrams and word frequencies
  SetLength(AllWordLists, totalLangs);
  for i := 0 to totalLangs - 1 do
    SetLength(AllWordLists[i], 0);

  AssignFile(txtOut, txtFilePath);
  Rewrite(txtOut);
  fs := TFileStream.Create(outFile, fmCreate);
  try
    fs.WriteBuffer(MAGIC_COMPRESSED[0], SizeOf(MAGIC_COMPRESSED));
    fs.WriteBuffer(totalLangs, SizeOf(totalLangs));

    for i := 0 to totalLangs - 1 do
    begin
      langCode := validFiles[i];
      LogToFile(Format('  [%d/%d] %s ...', [i + 1, totalLangs, langCode]));
      fullPath := corpusDir + langCode + '.txt';

      with TStringList.Create do
      begin
        LoadFromFile(fullPath, TEncoding.UTF8);
        corpusText := Text;
        trigArray := langdetect.ExtractCharTrigrams(Text);
        Free;
      end;

      if trigArray = nil then
      begin
        plainStream := TMemoryStream.Create;
        try
          codeLen := Length(langCode);
          plainStream.WriteBuffer(codeLen, SizeOf(codeLen));
          if codeLen > 0 then plainStream.WriteBuffer(langCode[1], codeLen);
          trigCount := 0;
          plainStream.WriteBuffer(trigCount, SizeOf(trigCount));
          wordCount := 0;
          plainStream.WriteBuffer(wordCount, SizeOf(wordCount));

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
        Writeln(txtOut, langCode, ' =');
        if NumWords > 0 then
          LogToFile(' 0 trigrams, 0 words')
        else
          LogToFile(' 0 trigrams');
        Continue;
      end;

      // Trigrams
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
      SetLength(weights, freqMap.Count);
      for j := 0 to freqMap.Count - 1 do
      begin
        logProb := ln((PtrInt(freqMap.Objects[j]) + 1) / (totalTrigrams + vocabSize));
        weights[j].Trig := freqMap[j];
        weights[j].LogWeight := Round(logProb * LOG_SCALE);
      end;
      freqMap.Free;
      if Length(weights) > 1 then
        SortByWeight(weights, 0, High(weights));
      if Length(weights) > NumTrigrams then
        SetLength(weights, NumTrigrams);
      trigCount := Length(weights);

      // Collect words for later dedup (if enabled)
      if NumWords > 0 then
      begin
        IsCJKLang := (langCode = 'zh') or (langCode = 'zh-CN') or (langCode = 'zh-TW') or (langCode = 'ja') or (langCode = 'ko');
        if not IsCJKLang then
          CollectWordsFiltered(corpusText, MinWordLen, UTF8LowerCase(langCode), AllWordLists[i]);
      end;

      // Write placeholder (words=0)
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
        wordCount := 0;
        plainStream.WriteBuffer(wordCount, SizeOf(wordCount));

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

      Write(txtOut, langCode, ' =');
      for j := 0 to trigCount - 1 do
        Write(txtOut, ' "', weights[j].Trig, '"');
      Writeln(txtOut);
      if NumWords > 0 then
        LogToFile(Format(' %d trigrams, 0 words (pre-dedup)', [trigCount]))
      else
        LogToFile(Format(' %d trigrams', [trigCount]));
    end;

    // Phase 2: deduplicate words with threshold and rebuild file
    if NumWords > 0 then
    begin
      CommonWords := FindCommonWordsWithThreshold(AllWordLists, DedupThreshold);
      try
        LogToFile(Format('Dedup: removed %d words appearing in >= %d languages.', [CommonWords.Count, DedupThreshold]));
        LogToFile('Rebuilding final file...');

        SetLength(FinalWords, totalLangs);
        SetLength(FinalWeights, totalLangs);
        for i := 0 to totalLangs - 1 do
        begin
          SetLength(FinalWords[i], 0);
          SetLength(FinalWeights[i], 0);
        end;

        for i := 0 to totalLangs - 1 do
        begin
          if Length(AllWordLists[i]) = 0 then Continue;

          SetLength(DedupedList, 0);
          for j := 0 to High(AllWordLists[i]) do
            if CommonWords.IndexOf(AllWordLists[i][j].W) < 0 then
            begin
              SetLength(DedupedList, Length(DedupedList) + 1);
              DedupedList[High(DedupedList)] := AllWordLists[i][j];
            end;

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

        // Close and reopen files
        fs.Free;
        CloseFile(txtOut);

        fs := TFileStream.Create(outFile, fmCreate);
        try
          fs.WriteBuffer(MAGIC_COMPRESSED[0], SizeOf(MAGIC_COMPRESSED));
          fs.WriteBuffer(totalLangs, SizeOf(totalLangs));

          AssignFile(txtOut, txtFilePath);
          Rewrite(txtOut);

          for i := 0 to totalLangs - 1 do
          begin
            langCode := validFiles[i];
            LogToFile(Format('  [%d/%d] %s ...', [i + 1, totalLangs, langCode]));
            fullPath := corpusDir + langCode + '.txt';

            with TStringList.Create do
            begin
              LoadFromFile(fullPath, TEncoding.UTF8);
              corpusText := Text;
              trigArray := langdetect.ExtractCharTrigrams(Text);
              Free;
            end;

            if trigArray = nil then
            begin
              plainStream := TMemoryStream.Create;
              try
                codeLen := Length(langCode);
                plainStream.WriteBuffer(codeLen, SizeOf(codeLen));
                if codeLen > 0 then plainStream.WriteBuffer(langCode[1], codeLen);
                trigCount := 0;
                plainStream.WriteBuffer(trigCount, SizeOf(trigCount));
                wordCount := Length(FinalWords[i]);
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
              LogToFile(Format(' 0 trigrams, %d words', [wordCount]));
              Writeln(txtOut, langCode, ' =');
              if wordCount > 0 then
              begin
                Write(txtOut, langCode, ' =');
                for j := 0 to wordCount - 1 do
                  Write(txtOut, ' "', FinalWords[i][j], '"');
                Writeln(txtOut);
              end;
              Continue;
            end;

            // Recompute trigrams for final file
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
            SetLength(weights, freqMap.Count);
            for j := 0 to freqMap.Count - 1 do
            begin
              logProb := ln((PtrInt(freqMap.Objects[j]) + 1) / (totalTrigrams + vocabSize));
              weights[j].Trig := freqMap[j];
              weights[j].LogWeight := Round(logProb * LOG_SCALE);
            end;
            freqMap.Free;
            if Length(weights) > 1 then
              SortByWeight(weights, 0, High(weights));
            if Length(weights) > NumTrigrams then
              SetLength(weights, NumTrigrams);
            trigCount := Length(weights);

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

              wordCount := Length(FinalWords[i]);
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

            LogToFile(Format(' %d trigrams, %d words', [trigCount, wordCount]));
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
        finally
          fs.Free;
        end;
      finally
        CommonWords.Free;
      end;
    end
    else
    begin
      // NumWords = 0: nothing to do
      CloseFile(txtOut);
    end;

    LogToFile('Done. Profiles saved to ' + outFile);
    LogToFile('Text dump saved to ' + txtFilePath);
    LogToFile('Press any key to exit (ESC to quit)...');
    WaitForEsc;
  finally
    // txtOut already closed in Phase2 or above; but to be safe, if an exception occurs we close it
    try
      CloseFile(txtOut);
    except
    end;
    validFiles.Free;
  end;
end.
