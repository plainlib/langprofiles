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
- Optional filtering of trigrams and words to remove noise (`-f`): mode 1 cleans obvious junk characters,
  mode 2 enforces strict script matching.
- Intermediate corpus data can be cached (compressed) to speed up repeated profile generation.
  The cache file is named `<corpus_folder>.dat` and placed next to the executable.
- Force‑dedup flags (`-fd`, `-fdw`, `-fdt`) allow applying deduplication to cached data without
  re‑collecting, speeding up parameter experiments.

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
langprofiles <max_len> <iter> -d <dir>    # test a specific corpus folder
```

**Options for test mode:**

| Flag        | Description |
|-------------|-------------|
| `-d <corpus_dir>` | Corpus folder to test (default `.\corpus`). |
| `-pf <file>` | Load extra profile file (merged on top of default profiles) before running the test. |

**Examples:**

```bash
langprofiles                       # test with max_len=500, iter=3
langprofiles 1000                  # test with max_len=1000, iter=3
langprofiles 800 5                 # test with max_len=800, iter=5
langprofiles 800 5 -d mycorpus     # test using corpora from 'mycorpus' folder
langprofiles 800 5 -pf alt.dat     # test using alt.dat in addition to the default profile
```

The test scans the given corpus directory, loads each `.txt` file, and runs the detection
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
langprofiles gen <corpus_dir> <out_file>    # custom paths, default settings
langprofiles gen [options]                  # full customisation
```

**Parameters:**

| Flag | Description | Default |
|------|-------------|---------|
| `corpus_dir` | Directory with one `.txt` file per language | `.\corpus` |
| `out_file`   | Path to the generated binary profile | `.\langprofiles.dat` |
| `-n <N>`     | Number of top trigrams to keep per language | `800` |
| `-w <W>`     | Maximum number of frequent words to keep per language | `1000` |
| `-wl <L>`    | Minimum word length (shorter words are ignored) | `3` |
| `-d <D>`     | Word deduplication threshold – remove words appearing in **D** or more languages | `2` |
| `-td <T>`    | Trigram deduplication threshold – remove trigrams appearing in **T** or more languages | `0` (off) |
| `-f <0\|1\|2>` | Filter mode: 0 = no filtering, 1 = remove obvious junk (control/format/etc.), 2 = strict script filter | `0` |
| `-fd`        | Force both word and trigram deduplication even when loading from cache | off |
| `-fdw`       | Force word deduplication on cached data | off |
| `-fdt`       | Force trigram deduplication on cached data | off |

All parameters after `gen` can appear in any order. The first unrecognised argument is treated
as `corpus_dir`, the second as `out_file`. After that, `-n`, `-w`, `-wl`, `-d`, `-td`, `-f`, `-fd`, `-fdw`, `-fdt` are consumed.

**Examples:**

```bash
# Default generation (800 trigrams, 1000 words, min word length 3, dedup thresholds: words=2, trigrams=off)
langprofiles gen

# Custom trigram and word counts, more aggressive word dedup, enable trigram dedup at threshold 2
langprofiles gen -n 600 -w 500 -d 2 -td 2

# Use a custom corpus folder, output file, strict script filter
langprofiles gen ./corpora ./out.bin -f 2

# Regenerate using cached data from previous run, but force trigram dedup with threshold 3
langprofiles gen -td 3 -fdt corpus10Mb langprofiles.dat
```

## Logging

All messages printed to the console are automatically mirrored to a log file: `langprofiles.log`

The log file is created in the same folder as the executable. This provides a permanent record
of every run and is especially useful for long generation sessions or automated testing.

## Corpus Caching

To avoid re‑processing raw text files every time, the generator saves intermediate data
(trigram frequencies and word collections) into a compressed cache file named
`<corpus_folder>.dat` (e.g., `corpus.dat` for the default corpus folder).  
On subsequent runs with the same corpus directory, the cache is loaded, skipping the
time‑consuming extraction phase. The cached data is already deduplicated according to
the parameters used when it was created.

If you want to experiment with different deduplication thresholds or filtering without
re‑extracting all texts, you can force deduplication on the cached data using the
`-fd`, `-fdw`, or `-fdt` flags. This applies the current `-d`, `-td`, and `-f` settings
to the loaded cache and proceeds to build the profile.  
**Note:** Forced dedup does **not** overwrite the cache file, so you can always return
to the original cached state by omitting the force flags.

## How It Works (Two‑Phase Generation)

### Phase 1 – Initial collection
- For each language, trigrams are extracted and counted, storing unique trigrams with their frequencies.
- Simultaneously, all candidate words are collected (minimum length `-wl`) and saved in memory.
- If a filter mode is active (`-f`), trigrams and words are cleaned during this phase.

### Phase 2 – Deduplication and final output
- The tool finds words that appear in at least `-d` languages and discards them.
- Likewise, if `-td` > 1, it finds trigrams common to `-td` or more languages and removes them.
- Remaining words are sorted by frequency, truncated to `-w`, and assigned positional weights.
- Trigrams are re‑processed: log‑probabilities are computed (Laplace smoothing), sorted, truncated to `-n`, and assigned positional weights.
- All data is packed, compressed with zlib, and written to the output file.
- A human‑readable text dump of the selected trigrams and words is also generated.

This approach guarantees that the stored elements are both frequent **and** highly distinctive for their language, greatly improving detection accuracy on short texts.

## Preparing the Corpus FineWeb2 (10 MB samples)

The script `download_corpus.py` downloads 10 MB text samples from the FineWeb‑2 dataset
for all configured languages. It requires **Python 3.9+** and the `datasets` library.

### Windows (PowerShell)

```powershell
# 1. Install Python if missing (as Administrator)
winget install Python.Python.3.12

# 2. Install the datasets library
pip install datasets

# 3. Run the script
python download10Mb.py
```

### Linux (Debian/Ubuntu example)

```bash
# 1. Install Python and pip
sudo apt update
sudo apt install python3 python3-pip

# 2. Install the datasets library
pip install datasets

# 3. Run the script
python3 download10Mb.py
```

The script creates a `corpus10Mb` folder containing one `.txt` file per language.  
You can then use this folder as the corpus directory for `langprofiles gen`.

## License

This project is distributed under the MIT License. See the [LICENSE](LICENSE) file for details.

**FineWeb2 language data used to generate language profiles**
   
License: Open Data Commons Attribution License v1.0 (ODC-By)

**The language corpora in the corpus catalog were obtained from**

xu-song/cc100-samples
https://huggingface.co/datasets/xu-song/cc100-samples

License: unknown