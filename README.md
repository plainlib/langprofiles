```markdown
# langprofiles – Language Profile Generator

A command-line tool that reads a directory of UTF-8 text corpora (one file per language)
and produces a compact binary profile file used for fast language detection.

## Features

- Processes any number of languages from plain `.txt` files.
- Cleans and normalises text: collapses whitespace, keeps letters from many scripts
  (Latin, Cyrillic, Arabic, CJK, Thai, etc.), lowercases everything.
- Extracts character trigrams (three consecutive Unicode codepoints) and computes
  their log‑probabilities using Laplace smoothing.
- Keeps only the most characteristic trigrams (`FINAL_TOP = 600`) and assigns each
  a positional weight – the most probable trigram gets the highest weight.
- Compresses the binary data with **zlib (deflate)** to reduce file size by 3–5×
  without any noticeable runtime overhead during decompression.
- Writes the profile in a self‑describing format that can be optionally read by
  the detection library.
- Also generates a human‑readable text dump (`.txt`) with the list of selected trigrams
  for each language.

## Binary File Format

All integers are little‑endian.

### File layout

| Offset | Field | Type | Description |
|--------|-------|------|-------------|
| 0 | Magic | 4 bytes | `GPRO` signature (optional, marks compressed format) |
| 4 | TotalLanguages | Integer | Number of language entries |
| 8 | LanguageBlocks | sequence | For each language: CompressedSize (Cardinal) followed by compressed data |

**Note:** Older uncompressed files lack the `GPRO` magic and start directly with `TotalLanguages`.
Reading code should first check for the magic; if it matches, the rest of the file is compressed,
otherwise fall back to the legacy uncompressed layout.

### Per-language block (after decompression)

| Offset | Field | Type | Description |
|--------|-------|------|-------------|
| 0 | LangCodeLen | Integer | Length of the language code string |
| 4 | LangCode | UTF‑8 bytes | Language identifier (e.g. `en`) |
| 4 + LangCodeLen | TrigramCount | Integer | Number of trigrams that follow |
| | *For each trigram:* | | |
| +0 | TrigLen | Integer | Length of the trigram string |
| +4 | Trigram | UTF‑8 bytes | The trigram itself |
| +4 + TrigLen | Weight | Word | Positional weight (most frequent trigram = 60000, second = 59999, …) |

## Requirements

- [Free Pascal Compiler](https://www.freepascal.org/) 3.2.2 or later (Lazarus IDE optional)
- Packages: `Classes`, `SysUtils`, `PasZLib`, `LazUTF8` (all ship with Lazarus/FPC)
- Input corpora must be UTF‑8 encoded `.txt` files, at least `MIN_TEXT_LENGTH` (10000) characters long.

## Usage

```bash
./genprofiles <corpus_dir> <output_file>
```

- `corpus_dir` – directory containing one `.txt` file per language.  
  The file name (without extension) is used as the language code (e.g., `en.txt` → code `en`).
- `output_file` – path to the generated binary profile (e.g., `profiles.bin`).  
  A text dump with the same name but `.txt` extension will be created alongside.

### Example

```bash
./genprofiles ./corpora ./profiles.bin
```

Output:

```
  [1/5] en ...  600 trigrams
  [2/5] de ...  598 trigrams
  ...
Done. Profiles saved to ./profiles.bin
Text dump saved to ./profiles.txt
```

## Building

Compile from the command line:

```bash
fpc genprofiles.lpr
```

Or open `genprofiles.lpr` in Lazarus and build as a console application.

No external dependencies beyond the standard Free Pascal libraries.

## How It Works

1. **Scan** the input directory for `.txt` files, skip any corpus shorter than 10 000 codepoints.
2. For each language:
   - Load the text, clean and normalise it (whitespace collapsing, script filtering, lowercasing).
   - Extract all overlapping character trigrams.
   - Count trigram frequencies.
   - Compute Laplace‑smoothed log‑probabilities, sort trigrams by descending probability.
   - Keep the top `FINAL_TOP` (600) trigrams and assign weights:  
     `weight = POS_WEIGHT_BASE – rank` (so the most frequent trigram gets 60000, the second 59999, …).
3. **Pack** the language data (code, trigram count, trigrams and weights) into a memory stream.
4. **Compress** that stream with `zlib` (deflate) and prepend a 4‑byte original size.
5. **Write** the magic signature, total language count, and for each language the compressed size
   followed by the compressed block.
6. **Text dump** is written in parallel as a plain list of selected trigrams per language.

Compression typically reduces the profile file size by 3–5×, making distribution and loading faster.

## License

This project is distributed under the MIT License. See the [LICENSE](LICENSE) file for details.
```