"""Durable local identity and stage records for managed episodes."""

from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import tempfile
from urllib.parse import urlsplit

from .preprocess import _author, preprocess_markdown


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def episodes_dir(config: dict) -> Path:
    return Path(config["data_dir"]).expanduser() / "episodes"


def workspace(config: dict, episode_id: str) -> Path:
    if not episode_id or any(char not in "0123456789abcdef" for char in episode_id) or len(episode_id) != 24:
        raise ValueError("Invalid managed episode ID")
    return episodes_dir(config) / episode_id


def load_state(path: Path) -> dict:
    return json.loads((path / "state.json").read_text(encoding="utf-8"))


def save_state(path: Path, state: dict) -> None:
    path.mkdir(parents=True, exist_ok=True)
    state["last_activity"] = datetime.now(timezone.utc).isoformat()
    with tempfile.NamedTemporaryFile("w", encoding="utf-8", dir=path, prefix="state-", suffix=".tmp", delete=False) as stream:
        json.dump(state, stream, indent=2, sort_keys=True)
        stream.write("\n")
        temporary = Path(stream.name)
    os.replace(temporary, path / "state.json")


def all_states(config: dict):
    root = episodes_dir(config)
    if root.exists():
        for path in sorted(root.iterdir()):
            if (path / "state.json").is_file():
                yield path, load_state(path)


def find_episode(config: dict, reference: str) -> tuple[Path, dict]:
    candidate = Path(reference).expanduser()
    if candidate.suffix.lower() == ".md" or candidate.exists():
        original = str(candidate.resolve())
        for path, state in all_states(config):
            if state.get("source_path") == original:
                return path, state
        raise ValueError(f"No managed episode for {original}; run prepare first")
    path = workspace(config, reference)
    if not (path / "state.json").is_file():
        raise ValueError(f"Unknown episode ID: {reference}")
    return path, load_state(path)


def _source_url(metadata: dict) -> str:
    value = metadata.get("source_url") or metadata.get("source") or metadata.get("url") or ""
    if isinstance(value, dict):
        value = value.get("url", "")
    value = str(value or "").strip()
    if value:
        parsed = urlsplit(value)
        if parsed.scheme not in ("http", "https") or not parsed.netloc:
            raise ValueError("Frontmatter source URL must be HTTP or HTTPS")
    return value


def prepare(config: dict, reference: str) -> tuple[Path, dict]:
    if reference.startswith(("http://", "https://")):
        raise ValueError("Readcast accepts Markdown files, not URLs")
    candidate = Path(reference).expanduser()
    if candidate.suffix.lower() != ".md" and not candidate.exists():
        path, state = find_episode(config, reference)
        source_path = state.get("source_path")
        if not source_path or not Path(source_path).is_file():
            if not (path / "script.txt").is_file():
                raise ValueError("Original Markdown moved and no prepared script remains")
            return path, state
        candidate = Path(source_path)
    if candidate.suffix.lower() != ".md":
        raise ValueError("Readcast accepts .md Markdown files only")
    if not candidate.is_file():
        raise ValueError(f"Markdown file does not exist: {candidate}")
    original = str(candidate.resolve())
    raw = candidate.read_bytes()
    if not raw.strip():
        raise ValueError("Markdown file is empty")
    try:
        markdown = raw.decode("utf-8")
    except UnicodeDecodeError as error:
        raise ValueError("Markdown must be UTF-8") from error
    metadata, script = preprocess_markdown(markdown)
    source_url = _source_url(metadata)
    by_path = next(((path, state) for path, state in all_states(config) if state.get("source_path") == original), None)
    by_url = next(((path, state) for path, state in all_states(config) if source_url and state.get("source_url") == source_url), None)
    old = by_url if source_url else by_path
    if old is None and by_path:
        # A changed source URL represents a different article identity. Keep
        # the previous episode available by ID, and move the path mapping.
        previous_path, previous_state = by_path
        previous_state["source_path"] = ""
        save_state(previous_path, previous_state)
    if old:
        path, state = old
    else:
        identity = source_url or original
        episode_id = digest(identity.encode("utf-8"))[:24]
        path = workspace(config, episode_id)
        state = {"id": episode_id, "guid": f"urn:readcast:episode:{episode_id}"}
    raw_hash = digest(raw)
    script_hash = digest(script.encode("utf-8"))
    changed = state.get("source_hash") != raw_hash or state.get("script_hash") != script_hash
    state.update({
        "source_path": original,
        "source_url": source_url,
        "title": str(metadata["title"]).strip(),
        "author": _author(metadata.get("author")),
        "description": str(metadata.get("description") or ""),
        "published": str(metadata.get("published") or metadata.get("date") or ""),
        "source_hash": raw_hash,
        "script_hash": script_hash,
    })
    path.mkdir(parents=True, exist_ok=True)
    if changed or not (path / "snapshot.md").is_file():
        (path / "snapshot.md").write_bytes(raw)
    if changed or not (path / "script.txt").is_file():
        (path / "script.txt").write_text(script, encoding="utf-8")
    if changed:
        (path / "episode.mp3").unlink(missing_ok=True)
        for key in ("narration_hash", "mp3_hash", "mp3_path", "audio_url", "audio_key", "audio_hash", "audio_size"):
            state.pop(key, None)
        if not state.get("published_at"):
            state.pop("publication_state", None)
    save_state(path, state)
    return path, state


def stage_status(path: Path, state: dict) -> dict[str, str]:
    return {
        "prepared": "complete" if (path / "script.txt").is_file() else "missing",
        "narrated": "complete" if state.get("narration_hash") and (path / "episode.mp3").is_file() else "missing",
        "uploaded": "complete" if state.get("audio_url") else "missing",
        "published": "complete" if state.get("published_at") else "missing",
    }
