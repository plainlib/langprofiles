# langprofiles – Language Profile Generator

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](https://opensource.org/licenses/MIT)
[![Build with: Lazarus](https://img.shields.io/badge/Build_with-Lazarus-blueviolet)](https://www.lazarus-ide.org/)
[![Platform: Windows Linux](https://img.shields.io/badge/Platform-Windows_Linux-yellow)](#)
[![Latest Release](https://img.shields.io/github/v/release/plainlib/langprofiles?label=Release)](https://github.com/plainlib/langprofiles/releases/latest)

A command‑line tool that reads a directory of UTF‑8 text corpora (one file per language)
and produces a compact binary profile file used for fast language detection.
Also includes a built‑in test mode to evaluate detection accuracy on the same corpora,
and utilities to inspect loaded profiles and test with alternative profile files.

## Features

- Processes any number of languages from plain `.txt` files.
- Extracts character trigrams and computes their log‑probabilities (Laplace smoothing).
- Keeps only the top **N** most characteristic trigrams (default 800) with positional weights.
- For non‑CJK languages, extracts frequent words, removes common words (deduplication),
  and stores the top **W** unique words (default 1000) with weights.
- Compresses the binary data with **zlib (deflate)** for 3–5× smaller files.
- Writes the profile in a self‑describing format compatible with the detection library.
- Generates a human‑readable text dump (`.txt`) of the selected trigrams and words.
- Test mode runs `DetectLanguageWithConfidence` on corpus files and reports accuracy.
- All console messages are simultaneously written to `langprofiles.log` (or `langprofiles_test.log`)
  so you have a permanent record of every run.
- Display loaded profile statistics with `-i`/`-info` (number of languages, trigrams, words, priorities).
- In test mode, you can load an extra profile file with `-pf <file>` to test detection with
  custom or experimental profiles without rebuilding the main file.

## Binary File Format

All integers are little‑endian.

### File layout

| Offset | Field | Type | Description |
|--------|-------|------|-------------|
| 0 | Magic | 4 bytes | `GPRO` signature (always present for compressed format) |
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
| After trigrams | WordCount | Integer | Number of frequent unique words (0 for CJK languages or when words disabled) |
| | *For each word:* | | |
| +0 | WordLen | Integer | Length of the word string |
| +4 | Word | UTF‑8 bytes | The word (lowercased) |
| +4 + WordLen | Weight | Word | Positional weight (most frequent unique word = 60000, …) |

## Requirements

- [Lazarus](https://www.lazarus-ide.org/) 4.8 or later
- [Free Pascal Compiler](https://www.freepascal.org/) 3.2.2 or later
- Packages: `Classes`, `SysUtils`, `PasZLib`, `LazUTF8` (all ship with Lazarus/FPC)
- Input corpora must be UTF‑8 encoded `.txt` files, at least `MIN_TEXT_LENGTH` (10000) characters long.

## Usage

The tool has three operating modes: **test**, **generation**, and **profile info**.

### 1. Test mode (default when no `gen` or `-i` argument)

```bash
langprofiles                              # run test with default settings (max_len=500, iter=3)
langprofiles <max_len> [<iter>] [options] # custom sample size and iterations
langprofiles <max_len> <iter> -pf <file>  # test with an additional profile file
```

**Options for test mode:**

| Flag        | Description |
|-------------|-------------|
| `-pf <file>` | Load extra profile file (merged on top of default profiles) before running the test. |

**Examples:**

```bash
langprofiles                       # test with max_len=500, iter=3
langprofiles 1000                  # test with max_len=1000, iter=3
langprofiles 800 5                 # test with max_len=800, iter=5
langprofiles 800 5 -pf alt.dat     # test using alt.dat in addition to the default profile
```

The test scans the `.\corpus` directory, loads each `.txt` file, and runs the detection
function. It reports per‑file results and overall accuracy.  
All console output is logged to `langprofiles.log` (or `langprofiles_test.log` depending on
context).

### 2. Profile info

```bash
langprofiles -i                       # display currently loaded profiles
langprofiles -info                    # same as -i
langprofiles -i -pf <file>            # load extra profile file and display combined info
langprofiles -info -pf <file>         # equivalent
```

Prints to console (and log) a summary of all language profiles available for detection.
If a profile file is specified with `-pf <file>`, it is loaded (merged on top of the
default built‑in and `langprofiles.dat` profiles) before the summary is shown.

The output includes:
- total number of languages,
- for each language: code, number of trigrams, number of stored words (if any), priority.

Useful to quickly check what data is available for detection, and to verify that a
custom profile file contains the expected languages and counts.

### 3. Generation mode

```bash
langprofiles gen                            # generate with default paths and settings
langprofiles gen -n 800                     # custom trigram count, default paths
langprofiles gen <corpus_dir> <out_file>    # custom paths, default settings
langprofiles gen -n 800 -w 500 -wl 3 -d 2  # full customisation
```

**Parameters:**

| Flag | Description | Default |
|------|-------------|---------|
| `corpus_dir` | Directory with one `.txt` file per language | `.\corpus` |
| `out_file`   | Path to the generated binary profile | `.\langprofiles.dat` |
| `-n <N>`     | Number of top trigrams to keep per language | `800` |
| `-w <W>`     | Maximum number of frequent words to keep per language | `1000` |
| `-wl <L>`    | Minimum word length (shorter words are ignored) | `4` |
| `-d <D>`     | Deduplication threshold – remove words appearing in **D** or more languages | `3` |

All parameters after `gen` can appear in any order. The first unrecognised argument is treated
as `corpus_dir`, the second as `out_file`. After that, `-n`, `-w`, `-wl`, `-d` are consumed.

**Examples:**

```bash
# Default generation (800 trigrams, 1000 words, min word length 4, dedup threshold 3)
langprofiles gen

# Custom trigram and word counts, more aggressive deduplication
langprofiles gen -n 600 -w 500 -d 2

# Everything custom, words of length 3 allowed
langprofiles gen ./corpora ./out.bin -n 800 -w 500 -wl 3 -d 2
```

## Logging

All messages printed to the console are automatically mirrored to a log file: `langprofiles.log`

The log file is created in the same folder as the executable. This provides a permanent record
of every run and is especially useful for long generation sessions or automated testing.

## How It Works (Two‑Phase Generation)

### Phase 1 – Initial collection
- For each language, trigrams are extracted and immediately written to a temporary file (words = 0).
- At the same time, all candidate words are collected and saved in memory.

### Phase 2 – Deduplication and final output
- The tool scans all collected word lists to find words present in ≥ `-d` languages.
- Those common words are discarded.
- For each language, the remaining words are sorted by frequency, truncated to `-w`, and assigned positional weights.
- The final profile is rebuilt: trigrams are re‑extracted (to ensure consistency) and written together with the filtered word list.
- The output file and text dump are overwritten with the complete data.

This approach guarantees that the stored words are both frequent **and** highly distinctive for their language, greatly improving detection accuracy on short texts.

## License

This project is distributed under the MIT License. See the [LICENSE](LICENSE) file for details.

**Language corpora were obtained from:**

xu-song/cc100-samples
https://huggingface.co/datasets/xu-song/cc100-samples

License: unknown