"""Remove aged local episode work products and narration cache entries."""

from datetime import datetime, timedelta, timezone
import json
from pathlib import Path
import shutil


EPISODE_ARTIFACTS = ("snapshot.md", "script.txt", "episode.mp3", "chunks")


def _activity_time(state_path: Path) -> datetime | None:
    """Read an episode's last_activity timestamp, returning None if invalid."""
    try:
        state = json.loads(state_path.read_text(encoding="utf-8"))
        value = state["last_activity"]
        if isinstance(value, (int, float)):
            return datetime.fromtimestamp(value, timezone.utc)
        if not isinstance(value, str):
            return None
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=timezone.utc)
        return parsed.astimezone(timezone.utc)
    except (OSError, ValueError, TypeError, KeyError, json.JSONDecodeError, OverflowError):
        return None


def _remove(path: Path, removed: list[Path]) -> None:
    try:
        if path.is_dir() and not path.is_symlink():
            shutil.rmtree(path)
        elif path.exists() or path.is_symlink():
            path.unlink()
        else:
            return
        removed.append(path)
    except OSError:
        # A failed local cleanup must not stop cleanup of other stale files.
        return


def cleanup(config: dict, apply: bool = False, days: int = 30) -> list[Path]:
    """Return stale local paths, deleting them only when ``apply`` is true.

    Episode age comes from each ``state.json`` file's ``last_activity`` value.
    Only the known regenerable episode products are removed; state files are
    retained. Narration cache files use their filesystem modification time.
    This function only accesses the configured local data and cache directories.
    """
    if days < 0:
        raise ValueError("days must be zero or greater")
    cutoff = datetime.now(timezone.utc) - timedelta(days=days)
    removed: list[Path] = []
    data_dir = Path(config["data_dir"]).expanduser()
    cache_dir = Path(config["narration_cache_dir"]).expanduser()

    episodes_dir = data_dir / "episodes"
    if episodes_dir.is_dir():
        for state_path in episodes_dir.glob("*/state.json"):
            activity = _activity_time(state_path)
            if activity is None or activity >= cutoff:
                continue
            for name in EPISODE_ARTIFACTS:
                target = state_path.parent / name
                if apply:
                    _remove(target, removed)
                elif target.exists() or target.is_symlink():
                    removed.append(target)

    if cache_dir.is_dir():
        for target in cache_dir.rglob("*"):
            if not target.is_file() or target.is_symlink():
                continue
            try:
                stale = datetime.fromtimestamp(target.stat().st_mtime, timezone.utc) < cutoff
            except OSError:
                continue
            if not stale:
                continue
            if apply:
                _remove(target, removed)
            else:
                removed.append(target)
    return removed
