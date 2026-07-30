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
//    4. Pack the language data into a memory stream, compress it with zlib
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
//-----------------------------------------------------------------------------------
//  Zlib compression is used to reduce the profile file size 3-5x without
//  any noticeable runtime cost – decompression is extremely fast (hundreds
//  of MB/s) and the smaller file loads quicker from disk.
//-----------------------------------------------------------------------------------
//  Usage:
//    langprofiles                            run test with .\corpus (max 500, 5 samples)
//    langprofiles <max_len> <iter>           test with custom sample size and count
//    langprofiles gen                        generate profiles from .\corpus to .\langprofiles.dat
//    langprofiles gen <corpus_dir> <out_file>  generate with custom paths
//-----------------------------------------------------------------------------------

program langprofiles;

{$mode objfpc}{$H+}
{$codepage utf8}

uses
  SysUtils,
  Classes,
  LazUTF8,
  Interfaces,        // required for LCL-based langdetect unit
  Crt,
  langdetect,
  osutils,           // provides CompressMemoryStream / DecompressMemoryStream
  langtest;

const
  MIN_TEXT_LENGTH = 10000;
  FINAL_TOP = 600;            // keep 600 most characteristic trigrams
  LOG_SCALE = 1000;           // multiply log-prob by this for sorting
  POS_WEIGHT_BASE = 60000;    // maximum positional weight (must fit in Word)
  MAGIC_COMPRESSED: array[0..3] of byte = ($47, $50, $52, $4F);   // Magic signature for compressed profile file ('GPRO')
  DEF_TEST_MAXLEN = 500;
  DEF_TEST_ITER = 3;

type
  TTrigWeight = record
    Trig: string;
    LogWeight: integer;            // ln(prob) * LOG_SCALE (only for sorting)
  end;
  TTrigWeightArray = array of TTrigWeight;

  // Sort TTrigWeight array by LogWeight descending, then Trig ascending
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

var
  corpusDir, outFile, txtFilePath, langCode, fullPath: string;
  sr: TSearchRec;
  validFiles: TStringList;
  i, j, k, totalLangs, trigCount, codeLen, trigLen: integer;
  fs: TFileStream;
  txtOut: TextFile;
  trigArray: TStringArray;
  freqMap: TStringList;        // simple map trig -> count
  weights: TTrigWeightArray = ();
  totalTrigrams, vocabSize: integer;
  logProb: double;
  posWeight: word;
  plainStream: TMemoryStream;
  comprStream: TMemoryStream;
  comprSize: cardinal;
  TestMaxLen: integer;
  TestIter: integer;
begin
  // Default parameters
  TestMaxLen := DEF_TEST_MAXLEN;
  TestIter := DEF_TEST_ITER;

  // Parse command line
  if ParamCount = 0 then
  begin
    // No arguments -> test with default corpus .\corpus
    RunLanguageDetectionTest('.\corpus', TestMaxLen, TestIter);
    Halt;
  end;

  if SameText(ParamStr(1), 'gen') then
  begin
    // Generation mode
    if ParamCount >= 2 then
      corpusDir := ParamStr(2)
    else
      corpusDir := '.\corpus';
    if ParamCount >= 3 then
      outFile := ParamStr(3)
    else
      outFile := '.\langprofiles.dat';
  end
  else
  begin
    // Test mode with optional custom max_len and iter
    if ParamCount >= 1 then
      TestMaxLen := StrToIntDef(ParamStr(1), TestMaxLen);
    if ParamCount >= 2 then
      TestIter := StrToIntDef(ParamStr(2), TestIter);
    if TestIter < 1 then TestIter := 1;
    RunLanguageDetectionTest('.\corpus', TestMaxLen, TestIter);
    Halt;
  end;

  // If we are here, GenMode is True – proceed with profile generation
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
    // Write magic to mark the file as compressed
    fs.WriteBuffer(MAGIC_COMPRESSED[0], SizeOf(MAGIC_COMPRESSED));
    fs.WriteBuffer(totalLangs, SizeOf(totalLangs));
    for i := 0 to totalLangs - 1 do
    begin
      langCode := validFiles[i];
      Write(Format('  [%d/%d] %s ...', [i + 1, totalLangs, langCode]));
      fullPath := corpusDir + langCode + '.txt';

      // Load text and extract trigrams using the same function as the detector
      with TStringList.Create do
      begin
        LoadFromFile(fullPath, TEncoding.UTF8);
        trigArray := langdetect.ExtractCharTrigrams(Text);
        Free;
      end;

      if trigArray = nil then
      begin
        // Pack empty language block (codeLen, langCode, trigCount=0) and compress
        begin
          plainStream := TMemoryStream.Create;
          try
            codeLen := Length(langCode);
            plainStream.WriteBuffer(codeLen, SizeOf(codeLen));
            if codeLen > 0 then plainStream.WriteBuffer(langCode[1], codeLen);
            trigCount := 0;
            plainStream.WriteBuffer(trigCount, SizeOf(trigCount));

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
        end;
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

      // Compute log probabilities with Laplace smoothing (for ordering only)
      SetLength(weights, freqMap.Count);
      for j := 0 to freqMap.Count - 1 do
      begin
        logProb := ln((PtrInt(freqMap.Objects[j]) + 1) / (totalTrigrams + vocabSize));
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

      // Pack language binary data into a temporary stream and compress
      begin
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
            // Positional weight: most probable trigram gets highest value
            posWeight := word(POS_WEIGHT_BASE - j);
            plainStream.WriteBuffer(posWeight, SizeOf(posWeight));
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
    WriteLn('Press any key to exit (ESC to quit)...');
    repeat
      if KeyPressed then
      begin
        if ReadKey = #27 then Break;
      end;
      Sleep(50);
    until False;
  finally
    CloseFile(txtOut);
    fs.Free;
  end;
  validFiles.Free;
end.
