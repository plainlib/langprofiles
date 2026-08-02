# langprofiles – Language Profile Generator

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](https://opensource.org/licenses/MIT)
[![Build with: Lazarus](https://img.shields.io/badge/Build_with-Lazarus-blueviolet)](https://www.lazarus-ide.org/)
[![Platform: Windows Linux](https://img.shields.io/badge/Platform-Windows_Linux-yellow)](#)
[![Latest Release](https://img.shields.io/github/v/release/plainlib/langprofiles?label=Release)](https://github.com/plainlib/langprofiles/releases/latest)

A command‑line tool that reads a directory of UTF‑8 text corpora (one file per language)
and produces a compact binary profile file used for fast language detection.
Also includes a built‑in test mode to evaluate detection accuracy on the same corpora.

## Features

- Processes any number of languages from plain `.txt` files.
- Extracts character trigrams (three consecutive Unicode codepoints) and computes
  their log‑probabilities using Laplace smoothing.
- Keeps only the top **N** most characteristic trigrams (default 800) and assigns each
  a positional weight – the most probable trigram gets the highest weight (60000).
- For non‑CJK languages, extracts frequent words, removes words that appear in several
  languages (deduplication), and stores the top **W** unique words (default 1000)
  with positional weights.
- Compresses the binary data with **zlib (deflate)** to reduce file size by 3–5×
  without any noticeable runtime overhead during decompression.
- Writes the profile in a self‑describing format that can be read by the
  detection library.
- Also generates a human‑readable text dump (`.txt`) listing the selected trigrams
  and words for each language.
- Test mode runs `DetectLanguageWithConfidence` on the corpus files and reports accuracy.

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

The program has two modes: **test** and **generation**.

### Test mode (default when no `gen` argument)

```bash
langprofiles                           # run test with default settings
langprofiles <max_len> [<iter>]        # custom sample size and number of samples
```

- `max_len` – maximum characters taken from each file (default 500).
- `iter` – number of samples per file (default 3). If the file is longer than `max_len`,
  a sliding window is used. Only one sample is taken if the file is shorter.

**Examples:**

```bash
langprofiles                    # test with max_len=500, iter=3
langprofiles 1000               # test with max_len=1000, iter=3
langprofiles 800 5              # test with max_len=800, iter=5
```

The test scans the `.\corpus` directory, loads each `.txt` file, and runs the detection
function. It reports per‑file results and overall accuracy.

### Generation mode

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
| `-d <D>`     | Deduplication threshold – remove words that appear in **D** or more languages | `3` |

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

**How words are selected (deduplication):**

1. For each non‑CJK language, all words of length ≥ `-wl` are collected from the corpus.
2. Words that appear in **≥ `-d`** different languages are considered “common” and removed from all profiles.
3. The remaining unique words are sorted by frequency within each language, and the top `-w` words are kept (fewer if not enough remain).
4. Each selected word gets a positional weight: the most frequent gets 60000, the next 59999, etc.

CJK languages (zh, ja, ko, etc.) skip word extraction entirely; their word list is empty.

## Building

Compile from the command line:

```bash
fpc langprofiles.lpr
```

Or open `langprofiles.lpr` in Lazarus and build as a console application.

No external dependencies beyond the standard Free Pascal libraries.

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