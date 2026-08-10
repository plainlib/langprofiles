from pathlib import Path
from datasets import load_dataset

# Output directory next to this script
BASE_DIR = Path(__file__).resolve().parent
CORPUS_DIR = BASE_DIR / "corpus"

LIMIT = 10 * 1024 * 1024  # 10 MB (default, can be overridden)
SKIP = 0                  # from beginning by default

# Language code -> FineWeb2 subset
LANGUAGES = {
    "af":    "afr_Latn",   # Afrikaans
    "am":    "amh_Ethi",   # Amharic
    "ar":    "arb_Arab",   # Arabic
    "as":    "asm_Beng",   # Assamese
    "az":    "azj_Latn",   # Azerbaijani
    "be":    "bel_Cyrl",   # Belarusian
    "bg":    "bul_Cyrl",   # Bulgarian
    "bn":    "ben_Beng",   # Bengali
    "br":    "bre_Latn",   # Breton
    "bs":    "bos_Latn",   # Bosnian
    "ca":    "cat_Latn",   # Catalan
    "cs":    "ces_Latn",   # Czech
    "cy":    "cym_Latn",   # Welsh
    "da":    "dan_Latn",   # Danish
    "de":    "deu_Latn",   # German
    "el":    "ell_Grek",   # Greek
    "en":    "eng_Latn",   # English
    "eo":    "epo_Latn",   # Esperanto
    "es":    "spa_Latn",   # Spanish
    "et":    "ekk_Latn",   # Estonian
    "eu":    "eus_Latn",   # Basque
    "fa":    "fas_Arab",   # Persian
    "ff":    "fuf_Latn",   # Fula
    "fi":    "fin_Latn",   # Finnish
    "fr":    "fra_Latn",   # French
    "fy":    "fry_Latn",   # Western Frisian
    "ga":    "gle_Latn",   # Irish
    "gd":    "gla_Latn",   # Scottish Gaelic
    "gl":    "glg_Latn",   # Galician
    "gn":    "gug_Latn",   # Guarani
    "gu":    "guj_Gujr",   # Gujarati
    "ha":    "hau_Latn",   # Hausa
    "hi":    "hin_Deva",   # Hindi
    "hr":    "hrv_Latn",   # Croatian
    "ht":    "hat_Latn",   # Haitian Creole
    "hu":    "hun_Latn",   # Hungarian
    "hy":    "hye_Armn",   # Armenian
    "id":    "ind_Latn",   # Indonesian
    "ig":    "ibo_Latn",   # Igbo
    "is":    "isl_Latn",   # Icelandic
    "it":    "ita_Latn",   # Italian
    "he":    "heb_Hebr",   # Hebrew
    "ja":    "jpn_Jpan",   # Japanese
    "jv":    "jav_Latn",   # Javanese
    "ka":    "kat_Geor",   # Georgian
    "kk":    "kaz_Cyrl",   # Kazakh
    "km":    "khm_Khmr",   # Khmer
    "kn":    "kan_Knda",   # Kannada
    "ko":    "kor_Hang",   # Korean
    "ku":    "kmr_Latn",   # Kurdish
    "ky":    "kir_Cyrl",   # Kyrgyz
    "la":    "lat_Latn",   # Latin
    "lg":    "lug_Latn",   # Ganda
    "li":    "lim_Latn",   # Limburgish
    "ln":    "lin_Latn",   # Lingala
    "lo":    "lao_Laoo",   # Lao
    "lt":    "lit_Latn",   # Lithuanian
    "lv":    "lvs_Latn",   # Latvian
    "mg":    "plt_Latn",   # Malagasy
    "mk":    "mkd_Cyrl",   # Macedonian
    "ml":    "mal_Mlym",   # Malayalam
    "mn":    "khk_Cyrl",   # Mongolian
    "mr":    "mar_Deva",   # Marathi
    "ms":    "zsm_Latn",   # Malay
    "my":    "mya_Mymr",   # Burmese
    "ne":    "npi_Deva",   # Nepali
    "nl":    "nld_Latn",   # Dutch
    "no":    "nob_Latn",   # Norwegian
    "ns":    "nso_Latn",   # Northern Sotho
    "om":    "gaz_Latn",   # Oromo
    "or":    "ory_Orya",   # Odia
    "pa":    "pan_Guru",   # Punjabi
    "pl":    "pol_Latn",   # Polish
    "ps":    "pbt_Arab",   # Pashto
    "pt":    "por_Latn",   # Portuguese
    "qu":    "quy_Latn",   # Quechua
    "rm":    "roh_Latn",   # Romansh
    "ro":    "ron_Latn",   # Romanian
    "ru":    "rus_Cyrl",   # Russian
    "sa":    "san_Deva",   # Sanskrit
    "sc":    "srd_Latn",   # Sardinian
    "sd":    "snd_Arab",   # Sindhi
    "si":    "sin_Sinh",   # Sinhala
    "sk":    "slk_Latn",   # Slovak
    "sl":    "slv_Latn",   # Slovenian
    "so":    "som_Latn",   # Somali
    "sq":    "als_Latn",   # Albanian
    "sr":    "srp_Cyrl",   # Serbian
    "ss":    "ssw_Latn",   # Swati
    "su":    "sun_Latn",   # Sundanese
    "sv":    "swe_Latn",   # Swedish
    "sw":    "swh_Latn",   # Swahili
    "ta":    "tam_Taml",   # Tamil
    "te":    "tel_Telu",   # Telugu
    "th":    "tha_Thai",   # Thai
    "tl":    "fil_Latn",   # Tagalog
    "tn":    "tsn_Latn",   # Tswana
    "tr":    "tur_Latn",   # Turkish
    "ug":    "uig_Arab",   # Uyghur
    "uk":    "ukr_Cyrl",   # Ukrainian
    "ur":    "urd_Arab",   # Urdu
    "uz":    "uzn_Latn",   # Uzbek
    "vi":    "vie_Latn",   # Vietnamese
    "wo":    "wol_Latn",   # Wolof
    "xh":    "xho_Latn",   # Xhosa
    "yi":    "ydd_Hebr",   # Yiddish
    "yo":    "yor_Latn",   # Yoruba
    "zh-CN": "cmn_Hani",   # Chinese (Simplified)
    "zh-TW": "cmn_Hani",   # Chinese (Traditional)
    "zu":    "zul_Latn",   # Zulu
}


def _utf8_forward_align(data, start):
    """Advance 'start' to the first byte that begins a new UTF-8 character."""
    while start < len(data) and (data[start] & 0xC0) == 0x80:
        start += 1
    return start


def _utf8_backward_align(data, end):
    """Retreat 'end' to the last byte that starts a whole UTF-8 character."""
    while end > 0 and (data[end - 1] & 0xC0) == 0x80:
        end -= 1
    return end


def download_language(code, subset, skip_bytes=0, limit_bytes=10*1024*1024):
    """
    Download a slice of the FineWeb corpus.

    Parameters
    ----------
    code : str
        Language code (e.g. 'en', 'ru').
    subset : str
        FineWeb-2 subset name (e.g. 'rus_Cyrl').
    skip_bytes : int
        Number of bytes to skip from the beginning of the stream.
    limit_bytes : int
        Maximum number of bytes to write after skipping.
    """
    output = CORPUS_DIR / f"{code}.txt"

    print()
    print(f"=== {code} ({subset}) skip={skip_bytes} limit={limit_bytes} ===")

    try:
        if code == "en":
            ds = load_dataset(
                "HuggingFaceFW/fineweb",
                name="default",
                split="train",
                streaming=True,
            )
        else:
            ds = load_dataset(
                "HuggingFaceFW/fineweb-2",
                name=subset,
                split="train",
                streaming=True,
            )

        skipped = 0
        written = 0

        with open(output, "w", encoding="utf-8") as f:
            for row in ds:
                text = row.get("text", "")
                if not text:
                    continue

                data = (text + "\n").encode("utf-8")

                # Skip the initial bytes without cutting inside a character
                if skipped < skip_bytes:
                    remaining_to_skip = skip_bytes - skipped
                    if len(data) <= remaining_to_skip:
                        skipped += len(data)
                        continue
                    else:
                        # Align the cut point to a safe character start
                        cut_point = _utf8_forward_align(data, remaining_to_skip)
                        data = data[cut_point:]
                        skipped = skip_bytes  # skipping finished

                # Truncate to the remaining byte limit without breaking characters
                remaining_to_write = limit_bytes - written
                if len(data) > remaining_to_write:
                    trunc_point = _utf8_backward_align(data, remaining_to_write)
                    data = data[:trunc_point]

                # Write the chunk (safe bytes -> string)
                chunk = data.decode("utf-8")
                f.write(chunk)
                written += len(data)

                print(
                    f"\r{written / 1024 / 1024:.2f} MB",
                    end="",
                    flush=True,
                )

                if written >= limit_bytes:
                    break

        print(f"\nSaved: {output}")
        print(f"Size: {written / 1024 / 1024:.2f} MB")

    except Exception as e:
        print(f"\nERROR: {e}")


def main():
    CORPUS_DIR.mkdir(exist_ok=True)

    print(f"Output directory: {CORPUS_DIR}")
    print(f"Languages: {len(LANGUAGES)}")
    print(f"Target size: {LIMIT / 1024 / 1024:.0f} MB")
    print(f"Skip length: {SKIP / 1024 / 1024:.0f} MB")

    # Example: download the first 10 MB for every language
    for code, subset in LANGUAGES.items():
        download_language(code, subset, skip_bytes=SKIP, limit_bytes=LIMIT)

    # If you want to download subsequent chunks, simply call again with a different skip:
    # download_language('ru', 'rus_Cyrl', skip_bytes=10*1024*1024, limit_bytes=10*1024*1024)
    # Make sure to change the output filename inside the function or rename afterwards.

    print()
    print("Done.")


if __name__ == "__main__":
    main()
    input("\nPress Enter to exit...")