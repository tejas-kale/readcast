"""Deterministic speech cleanup carried over from the R application."""

from datetime import date, datetime
from pathlib import Path
import re
import unicodedata

import yaml


FRONTMATTER = re.compile(r"\A---[ \t]*\n(.*?)\n---[ \t]*(?:\n|\Z)", re.S)
PRONUNCIATIONS_FILE = Path(__file__).with_name("pronunciations.yml")


def load_pronunciations(path: Path | str | None = None) -> dict[str, str]:
    mapping = {}
    for file in (PRONUNCIATIONS_FILE, Path(path).expanduser() if path else None):
        if file is None:
            continue
        if file == PRONUNCIATIONS_FILE and not file.exists():
            raise FileNotFoundError(f"Missing packaged pronunciation map: {file}")
        if not file.exists():
            continue
        if not file.is_file():
            raise ValueError(f"Pronunciation path is not a file: {file}")
        try:
            entries = yaml.safe_load(file.read_text(encoding="utf-8"))
        except yaml.YAMLError as error:
            raise ValueError(f"Invalid pronunciation YAML: {file}") from error
        if not isinstance(entries, dict) or any(
            not isinstance(name, str) or not name.strip() or
            not isinstance(spoken, str) or not spoken.strip()
            for name, spoken in entries.items()
        ):
            raise ValueError(f"{file} must map written words to spoken words")
        mapping.update({name.casefold(): spoken for name, spoken in entries.items()})
    return mapping


def apply_pronunciations(text: str, path: Path | str | None = None) -> str:
    for written, spoken in load_pronunciations(path).items():
        text = re.sub(rf"(?<!\w){re.escape(written)}(?!\w)",
                      lambda match: spoken, text, flags=re.I)
    return text


def parse_markdown(markdown: str) -> tuple[dict, str]:
    match = FRONTMATTER.match(markdown)
    if not match:
        raise ValueError("Markdown needs YAML frontmatter with a title")
    metadata = yaml.safe_load(match.group(1))
    if not isinstance(metadata, dict):
        raise ValueError("Markdown frontmatter must be a YAML mapping")
    title = metadata.get("title")
    if not isinstance(title, str) or not title.strip():
        raise ValueError("Markdown frontmatter needs a title")
    return metadata, markdown[match.end():]


def _author(value) -> str:
    if isinstance(value, list):
        value = value[0] if value else ""
    return re.sub(r"\[\[([^]|]+)(?:\|[^]]+)?\]\]", r"\1", str(value or ""))


def spoken_preamble(metadata: dict, body: str) -> str:
    opening = [str(metadata["title"]).strip()]
    author = _author(metadata.get("author"))
    if author:
        opening.append(f"By {author}")
    published = metadata.get("published", metadata.get("date"))
    if published:
        if isinstance(published, (date, datetime)):
            published = published.strftime("%-d %B %Y")
        else:
            try:
                published = date.fromisoformat(str(published)[:10]).strftime("%-d %B %Y")
            except ValueError:
                published = str(published)
        opening.append(f"Published {published}")
    return ". ".join(opening) + ".\n\n" + body.lstrip()


def _code_fence(info: str, content: str) -> bool:
    language = (re.match(r"[\w+.#-]+", info.strip()) or [""])[0].lower()
    if language and language not in {"text", "plaintext", "plain", "prompt", "prose", "markdown", "md", "quote"}:
        return True
    lines = [line.strip() for line in content.splitlines() if line.strip()]
    if not lines:
        return False
    joined = "\n".join(lines)
    if re.match(r"\s*(?:<\?xml\b|<[A-Za-z][\w.:-]*(?:\s|>|/))", joined, re.I) and len(re.findall(r"</?[A-Za-z][\w.:-]*(?:\s|>|/)", joined)) >= 2:
        return True
    if re.search(r"^\s*[\[{]\s*$", joined, re.M) and re.search(r"^\s*[\]}]\s*[,;]?$", joined, re.M) and re.search(r'^\s*["\'][^"\']+["\']\s*:', joined, re.M):
        return True
    syntax = re.compile(r"^(?:[#@]?[A-Za-z_]\w*(?:\s*::?=|\s*=|\s*\(|\s*=>)|(?:if|else|for|while|return|function|def|class|import|from|const|let|var|CREATE|SELECT|INSERT|UPDATE|DELETE)\b|[{}\[\]]|\$[A-Za-z_])")
    ratio = sum(bool(syntax.match(line)) for line in lines) / len(lines)
    density = len(re.findall(r"[{}\[\]();=<>]", joined)) / max(1, len(joined))
    return ratio >= .5 or (len(lines) >= 3 and ratio >= .3 and density >= .035)


def replace_code_fences(text: str) -> str:
    output: list[str] = []
    block: list[str] = []
    fence = ""
    info = ""
    for line in text.split("\n"):
        if not fence:
            match = re.match(r"^ {0,3}(`{3,}|~{3,})(.*)$", line)
            if match:
                fence, info, block = match.group(1), match.group(2), []
            else:
                output.append(line)
        elif re.match(rf"^ {{0,3}}{re.escape(fence[0])}{{{len(fence)},}}[ \t]*$", line):
            output.extend(["Please read the code block in the article."] if _code_fence(info, "\n".join(block)) else block)
            fence = ""
        else:
            block.append(line)
    if fence:
        output.extend(["Please read the code block in the article."] if _code_fence(info, "\n".join(block)) else block)
    return "\n".join(output)


def remove_images_and_chrome(text: str) -> str:
    patterns = [
        (r"^[ \t]*!\[[^]]*\]\([^\n)]*\)[ \t]*\n?", re.M),
        (r"^\*?the bottom of this article could be cut off in some email clients[^\n]*\n?", re.I | re.M),
        (r"^\[read the full article online\]\([^\n)]*\)[ \t]*\n?", re.I | re.M),
        (r"^[ \t]*(?:source|references?):[ \t]*[^\n]*\n?", re.I | re.M),
        (r"^[ \t]*\[(?:source|references?)\]\([^\n)]*\)[ \t]*\n?", re.I | re.M),
        (r"\[(?:source|references?)\]\(https?://[^\n)]*\)", re.I),
        (r"^[ \t]*\[[^]\n]+\]:[ \t]*<?https?://[^\n]*\n?", re.M),
        (r"^[ \t]*\[\^[^]\n]+\]:[^\n]*\n?", re.M),
        (r"\[\^[^]\n]+\]", 0),
    ]
    for pattern, flags in patterns:
        text = re.sub(pattern, "", text, flags=flags)
    text = re.sub(r"\[([^]]+)\]\((?:<https?://[^>\n]+>|https?://[^\n)]*)\)", r"\1", text)
    for pattern in (r"^[ \t]*(?:visit|see|read)[ \t]+https?://[^\n]*\n?", r"^[ \t]*(?:https?://|www\.)[^\n]*\n?"):
        text = re.sub(pattern, "", text, flags=re.I | re.M)
    return re.sub(r"\b(?:https?://|www\.)[^\s<>]+", "", text, flags=re.I)


def cue_blockquotes(text: str) -> str:
    output: list[str] = []
    quote: list[str] = []

    def flush():
        if not quote:
            return
        paragraphs = re.split(r"\n\s*\n", "\n".join(quote))
        if output and output[-1]:
            output.append("")
        output.extend("\n\n".join(" ".join(p.splitlines()) for p in paragraphs).split("\n"))
        quote.clear()

    for line in text.split("\n"):
        match = re.match(r"^ {0,3}> ?(.*)$", line)
        if match:
            quote.append(match.group(1).strip())
        else:
            was_quote = bool(quote)
            flush()
            if was_quote and line:
                output.append("")
            output.append(line)
    flush()
    return re.sub(r"\n{3,}", "\n\n", "\n".join(output))


def speak_markdown_structure(text: str) -> str:
    text = re.sub(r"\[([^]]+)\]\([^\n)]*\)", r"\1", text)
    text = re.sub(r"\[\[([^]|]+)\|([^]]+)\]\]", r"\2", text)
    text = re.sub(r"\[\[([^]]+)\]\]", r"\1", text)
    text = re.sub(r"\[([A-Za-z])\](?=[A-Za-z])", r"\1", text)
    text = cue_blockquotes(text)
    lines = []
    bullet_number = 0
    for line in text.split("\n"):
        bullet = re.match(r"^[ \t]*[-*+][ \t]+(.+)$", line)
        if bullet:
            bullet_number += 1
            item = bullet.group(1).strip()
            if not re.search(r"[.!?][\"'”’]?$", item):
                item += "."
            lines.append(f"{ordinal_words(bullet_number).capitalize()}, {item}")
        else:
            bullet_number = 0
            lines.append(line)
    text = "\n".join(lines)
    text = re.sub(r"^[ \t]*[0-9]+\.[ \t]+", "", text, flags=re.M)
    text = re.sub(r"^#{1,6}[ \t]+([^\n]+)", lambda m: m.group(1).rstrip(" .") + ".\n", text, flags=re.M)
    text = re.sub(r"\*\*([A-Z][A-Z0-9 ,.-]{8,})\*\*", lambda m: m.group(1).capitalize(), text)
    text = re.sub(r"(?<!\w)[*_]{1,2}([^\n]*?)[*_]{1,2}(?!\w)", r"\1", text)
    text = re.sub(r"`([^`]+)`", r"\1", text)
    return re.sub(r"\n{3,}", "\n\n", text).strip()


def normalise_typography(text: str) -> str:
    text = unicodedata.normalize("NFC", text)
    for old, new in {"‘": "'", "’": "'", "“": '"', "”": '"', "—": ", ", "–": " to ", "→": " then ", "…": ".", "\u00a0": " "}.items():
        text = text.replace(old, new)
    return "".join(char for char in text if char in "\n\t" or unicodedata.category(char) not in {"Cc", "Cf"})


UNITS = "zero one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen".split()
TENS = ["", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"]


def number_words(number: int) -> str:
    if number < 0:
        raise ValueError("Only non-negative numbers can be spoken")
    if number < 20:
        return UNITS[number]
    if number < 100:
        return TENS[number // 10] + ("-" + UNITS[number % 10] if number % 10 else "")
    if number < 1000:
        return UNITS[number // 100] + " hundred" + (" and " + number_words(number % 100) if number % 100 else "")
    for name, scale in (("trillion", 10**12), ("billion", 10**9), ("million", 10**6), ("thousand", 10**3)):
        if number >= scale:
            return number_words(number // scale) + " " + name + (" " + number_words(number % scale) if number % scale else "")
    raise AssertionError(number)


def ordinal_words(number: int) -> str:
    irregular = {
        1: "first", 2: "second", 3: "third", 5: "fifth", 8: "eighth",
        9: "ninth", 12: "twelfth", 20: "twentieth", 30: "thirtieth",
    }
    if number in irregular:
        return irregular[number]
    if number < 20:
        return number_words(number) + "th"
    if number < 100 and number % 10:
        return TENS[number // 10] + "-" + ordinal_words(number % 10)
    if number < 100:
        return number_words(number)[:-1] + "ieth"
    words = number_words(number)
    if number % 100 == 0:
        return words + "th"
    return words.rsplit(" ", 1)[0] + " " + ordinal_words(number % 100)


def year_words(year: int) -> str:
    if 1000 <= year < 2000:
        century, rest = divmod(year, 100)
        return number_words(century) + (" hundred" if not rest else " oh " + number_words(rest) if rest < 10 else " " + number_words(rest))
    if 2000 <= year < 2010:
        return "two thousand" + (" and " + number_words(year - 2000) if year > 2000 else "")
    if 2020 <= year < 2040:
        return "two thousand and " + number_words(year - 2000)
    if 2010 <= year < 2100:
        return "twenty " + number_words(year - 2000)
    return number_words(year)


def speak_numbers(text: str) -> str:
    months = "January February March April May June July August September October November December".split()
    month_pattern = "|".join(months)
    text = re.sub(rf"\b(\d{{1,2}}) ({month_pattern}) (\d{{4}})\b", lambda m: f"{ordinal_words(int(m[1]))} {m[2].title()} {year_words(int(m[3]))}", text, flags=re.I)
    text = re.sub(r"\bRs[ \t]*([\d,]+)(?:[ \t]+(billion|million|thousand))?", lambda m: " ".join(filter(None, [number_words(int(m[1].replace(",", ""))), m[2], "rupees"])), text, flags=re.I)
    text = re.sub(r"\$([\d,]+)(?:[ \t]+(billion|million|thousand))?", lambda m: " ".join(filter(None, [number_words(int(m[1].replace(",", ""))), m[2], "dollars"])), text, flags=re.I)
    text = re.sub(r"\b[0-9][0-9,]*[ \t]*%", lambda m: number_words(int(re.sub(r"\D", "", m[0]))) + " percent", text)
    text = re.sub(r"\b(?:1[5-9]\d{2}|20\d{2})\b", lambda m: year_words(int(m[0])), text)
    return re.sub(r"\b[0-9][0-9,]*\b", lambda m: number_words(int(m[0].replace(",", ""))), text)


def preprocess_markdown(markdown: str, pronunciation_file: Path | str | None = None) -> tuple[dict, str]:
    metadata, body = parse_markdown(markdown)
    text = spoken_preamble(metadata, body)
    for step in (replace_code_fences, remove_images_and_chrome, speak_markdown_structure, normalise_typography, speak_numbers):
        text = step(text)
    text = apply_pronunciations(text, pronunciation_file)
    text = re.sub(r"(?m)^[ \t]+(?=\n|$)", "", text)
    text = re.sub(r"\n{3,}", "\n\n", text).strip()
    if not text:
        raise ValueError("Preparation produced no spoken text")
    return metadata, text
