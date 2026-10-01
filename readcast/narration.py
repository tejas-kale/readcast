"""Chunk text, generate speech, and assemble resumable MP3 narration."""

from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
import subprocess
import tempfile
from pathlib import Path
from typing import Callable, Sequence

import requests


DEFAULT_MODEL = "microsoft/mai-voice-2-flash"
SPEECH_ENDPOINT = "https://openrouter.ai/api/v1/audio/speech"
VOICE_BY_MODEL = {
    "microsoft/mai-voice-2": "en-US-Harper:MAI-Voice-2",
    "microsoft/mai-voice-2-flash": "en-US-Harper:MAI-Voice-2",
    "deepgram/flux-tts:free": "flux-haley-en",
}
DEFAULT_WORD_LIMIT = 350
DEFAULT_CHAR_LIMIT = 1900


def default_voice_for(model: str) -> str:
    """Return the known default voice, rejecting unsupported model IDs."""
    try:
        return VOICE_BY_MODEL[model]
    except KeyError as exc:
        raise ValueError(f"Supply a voice for model {model}") from exc


def _fits(text: str, word_limit: int, char_limit: int) -> bool:
    return len(text.split()) <= word_limit and len(text) <= char_limit


def _sentences(paragraph: str) -> list[str]:
    """Split at sentence endings while retaining all original characters."""
    # Keep frequent title abbreviations and initials attached to their names.
    abbreviations = {"Mr.", "Mrs.", "Ms.", "Dr.", "Prof.", "St.", "e.g.", "i.e."}
    ends = []
    for match in re.finditer(r"[.!?](?=\s+)", paragraph):
        prefix = paragraph[:match.end()]
        token = re.search(r"(?:^|\s)(\S+)$", prefix)
        if token and (token.group(1) in abbreviations or
                      re.fullmatch(r"[A-Z]\.\s*", token.group(1))):
            continue
        # Assign inter-sentence whitespace to the sentence before it. This
        # retains paragraph spacing and mirrors the R chunker.
        whitespace = re.match(r"\s+", paragraph[match.end():])
        ends.append(match.end() + (whitespace.end() if whitespace else 0))
    pieces = []
    start = 0
    for end in ends:
        pieces.append(paragraph[start:end])
        start = end
    pieces.append(paragraph[start:])
    return pieces


def split_article(text: str, word_limit: int = DEFAULT_WORD_LIMIT,
                  char_limit: int = DEFAULT_CHAR_LIMIT) -> list[str]:
    """Split prepared prose into bounded chunks without changing its text."""
    if not text or word_limit < 1 or char_limit < 1:
        raise ValueError("Text and chunk limits must be non-empty and positive")
    # Group separators with the preceding paragraph, matching the R implementation.
    units = re.findall(r".*?(?:\n{2,}|$)", text, flags=re.S)
    units = [unit for unit in units if unit]
    chunks: list[str] = []
    for unit in units:
        segments = [unit] if _fits(unit, word_limit, char_limit) else _sentences(unit)
        current = ""
        for segment in segments:
            if not _fits(segment, word_limit, char_limit):
                raise ValueError("One sentence exceeds the model's chunk limit")
            if current and not _fits(current + segment, word_limit, char_limit):
                chunks.append(current)
                current = segment
            else:
                current += segment
        if current:
            chunks.append(current)
    if not chunks or "".join(chunks) != text or any(
        not _fits(chunk, word_limit, char_limit) for chunk in chunks
    ):
        raise ValueError("Chunking did not preserve the prepared article")
    return chunks


def _cache_root(cache_dir: Path | str | None) -> Path:
    if cache_dir is not None:
        return Path(cache_dir).expanduser()
    base = Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache"))
    return base / "readcast" / "narration"


def _digest(*parts: str) -> str:
    hasher = hashlib.sha256()
    for part in parts:
        data = part.encode("utf-8")
        hasher.update(len(data).to_bytes(8, "big"))
        hasher.update(data)
    return hasher.hexdigest()


def _atomic_bytes(path: Path, value: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(prefix=".narration-", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(value)
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def generate_chunk(text: str, model: str, voice: str) -> bytes:
    """Request one MP3 from OpenRouter and validate its response."""
    key = os.environ.get("OPENROUTER_API_KEY", "")
    if not key:
        raise RuntimeError("Set OPENROUTER_API_KEY before generating audio")
    response = requests.post(
        SPEECH_ENDPOINT,
        headers={"Authorization": f"Bearer {key}"},
        json={"model": model, "input": text.rstrip(), "voice": voice,
              "response_format": "mp3", "speed": 1},
        timeout=300,
    )
    if not 200 <= response.status_code < 300:
        # Avoid echoing request text or credentials from provider error bodies.
        detail = ""
        try:
            error = response.json().get("error", {})
            if isinstance(error, str):
                detail = error
            elif isinstance(error, dict):
                detail = str(error.get("code", "") or "") + " " + str(error.get("message", "") or "")
        except (ValueError, AttributeError):
            pass
        detail = re.sub(r"[\x00-\x1f\x7f]+", " ", detail).strip()
        detail = detail.replace(key, "[redacted]").replace(text, "[redacted request text]")[:240]
        suffix = f": {detail}" if detail else ""
        raise RuntimeError(f"OpenRouter audio request failed (HTTP {response.status_code}){suffix}")
    content_type = response.headers.get("content-type", "")
    if not content_type.lower().startswith("audio/mpeg"):
        raise RuntimeError(f"Expected MP3 audio, got {content_type}")
    if not response.content:
        raise RuntimeError("OpenRouter returned an empty MP3")
    return response.content


def _join_mp3s(chunk_files: Sequence[Path], output: Path,
               pauses_after: Sequence[int], pause_seconds: float) -> None:
    if not chunk_files:
        raise ValueError("Cannot save missing audio chunks")
    if len(chunk_files) == 1:
        shutil.copyfile(chunk_files[0], output)
        return
    ffmpeg = shutil.which("ffmpeg")
    if ffmpeg is None:
        raise RuntimeError("ffmpeg is required to join narration chunks")
    pauses = set(pauses_after)
    with tempfile.TemporaryDirectory(prefix="readcast-join-") as temp:
        temp_path = Path(temp)
        # Copy to stable local names; ffmpeg concat manifests require quoted paths.
        local_files = []
        for i, source in enumerate(chunk_files):
            dest = temp_path / f"chunk-{i:04d}.mp3"
            shutil.copyfile(source, dest)
            local_files.append(dest)
        if pauses and pause_seconds > 0:
            args = [ffmpeg, "-hide_banner", "-loglevel", "error"]
            args.extend(arg for path in local_files for arg in ("-i", str(path)))
            filters = []
            for i in range(len(local_files)):
                pad = f",apad=pad_dur={pause_seconds}" if i + 1 in pauses else ""
                filters.append(f"[{i}:a]asetpts=PTS-STARTPTS{pad}[a{i}]")
            graph = ";".join(filters) + ";" + "".join(
                f"[a{i}]" for i in range(len(local_files))
            ) + f"concat=n={len(local_files)}:v=0:a=1[out]"
            args.extend(["-filter_complex", graph, "-map", "[out]", "-c:a",
                         "libmp3lame", "-b:a", "192k", str(output)])
        else:
            manifest = temp_path / "chunks.txt"
            manifest.write_text("".join(f"file '{p.name}'\n" for p in local_files), encoding="utf-8")
            args = [ffmpeg, "-hide_banner", "-loglevel", "error", "-f", "concat",
                    "-safe", "0", "-i", str(manifest), "-c", "copy", str(output)]
        run = subprocess.run(args, cwd=temp_path, capture_output=True, text=True, check=False)
        if run.returncode:
            raise RuntimeError(f"ffmpeg could not join MP3 chunks: {run.stderr.strip()}")
    if not output.exists() or output.stat().st_size == 0:
        raise RuntimeError("The resulting MP3 is empty")


def narrate_chunks(
    chunks: Sequence[str], output_path: Path | str, *, model: str = DEFAULT_MODEL,
    voice: str | None = None, cache_dir: Path | str | None = None,
    pauses_after: Sequence[int] = (), pause_seconds: float = 0.55,
    force: bool = False,
    progress: Callable[[int, int], object] | None = None,
) -> Path:
    """Generate and assemble chunks, resuming valid per-chunk and MP3 caches.

    ``pauses_after`` contains one-based chunk indices after which silence is added.
    Cache keys include text, model, voice, chunk order, and assembly options, so
    changed inputs naturally invalidate only affected chunks and final outputs.
    ``force`` requests fresh speech for every chunk, ignoring both caches.
    """
    if not chunks or any(not isinstance(chunk, str) or not chunk.strip() for chunk in chunks):
        raise ValueError("Cannot narrate empty chunks")
    if pause_seconds < 0:
        raise ValueError("Pause length must be non-negative")
    selected_voice = voice if voice is not None else default_voice_for(model)
    root = _cache_root(cache_dir)
    chunk_dir = root / "chunks"
    output = Path(output_path).expanduser().resolve()
    chunk_keys = [_digest(model, selected_voice, chunk) for chunk in chunks]
    cache_key = _digest(json.dumps({"model": model, "voice": selected_voice,
                                   "chunks": chunk_keys, "pauses_after": sorted(pauses_after),
                                   "pause_seconds": pause_seconds}, sort_keys=True))
    final_cache = root / "mp3" / f"{cache_key}.mp3"
    retry_file = output.with_name(output.name + ".renarrate.json")
    output.parent.mkdir(parents=True, exist_ok=True)
    if not force and final_cache.is_file() and final_cache.stat().st_size:
        final_cache.touch()
        shutil.copyfile(final_cache, output)
        retry_file.unlink(missing_ok=True)
        return output

    completed: dict[str, str] = {}
    if force:
        if retry_file.is_file():
            try:
                previous = json.loads(retry_file.read_text(encoding="utf-8"))
                if previous.get("key") == cache_key and isinstance(previous.get("completed"), dict):
                    completed = previous["completed"]
            except (ValueError, AttributeError):
                pass
        _atomic_bytes(retry_file, json.dumps({"key": cache_key, "completed": completed}).encode())

    paths: list[Path] = []
    for index, (chunk, key) in enumerate(zip(chunks, chunk_keys), start=1):
        path = chunk_dir / f"{key}.mp3"
        resumed = (force and path.is_file() and path.stat().st_size > 0
                   and completed.get(str(index)) == hashlib.sha256(path.read_bytes()).hexdigest())
        if not resumed and (force or not path.is_file() or not path.stat().st_size):
            audio = generate_chunk(chunk, model, selected_voice)
            _atomic_bytes(path, audio)
            if force:
                completed[str(index)] = hashlib.sha256(audio).hexdigest()
                _atomic_bytes(retry_file, json.dumps({"key": cache_key, "completed": completed}).encode())
        else:
            path.touch()
        paths.append(path)
        if progress:
            progress(index, len(chunks))

    with tempfile.TemporaryDirectory(prefix="readcast-narration-", dir=output.parent) as temp:
        assembled = Path(temp) / "episode.mp3"
        _join_mp3s(paths, assembled, pauses_after, pause_seconds)
        data = assembled.read_bytes()
        _atomic_bytes(final_cache, data)
        _atomic_bytes(output, data)
    retry_file.unlink(missing_ok=True)
    return output
