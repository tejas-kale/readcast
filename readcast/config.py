"""Load the existing Readcast YAML configuration with Python defaults."""

from pathlib import Path
from urllib.parse import urlsplit
import re

import yaml


DEFAULTS = {
    "clippings_dir": "",
    "github_pages_url": "",
    "podcast_title": "Readcast",
    "podcast_description": "A personal collection of narrated articles.",
    "podcast_language": "en",
    "podcast_explicit": "false",
    "r2_account_id": "",
    "r2_bucket": "",
    "worker_url": "",
    "hosted_worker_url": "",
    "narration_cache_dir": "~/.cache/readcast/narrations",
    "data_dir": "~/.local/share/readcast",
    "speech_model": "microsoft/mai-voice-2-flash",
    "speech_voice": "",
    "image_model": "openai/gpt-image-2",
    "cover_prompt": "Create polished, distinctive square podcast cover artwork. Use a solid opaque background, clear high contrast, and a central composition that remains legible as a small thumbnail. Do not include an Apple logo, device, or hardware.",
}


class _UniqueKeysLoader(yaml.SafeLoader):
    pass


def _mapping(loader, node):
    result = {}
    for key_node, value_node in node.value:
        key = loader.construct_object(key_node)
        if key in result:
            raise ValueError(f"Duplicate configuration setting: {key}")
        result[key] = loader.construct_object(value_node)
    return result


_UniqueKeysLoader.add_constructor(yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, _mapping)


def load_config(config_dir: Path | None = None) -> dict:
    directory = Path(config_dir or "~/.config/readcast").expanduser()
    path = directory / "config.yml"
    try:
        stored = yaml.load(path.read_text(encoding="utf-8"), Loader=_UniqueKeysLoader) if path.exists() else {}
    except (OSError, yaml.YAMLError, ValueError) as error:
        raise ValueError(f"Readcast config.yml is invalid: {error}") from error
    if not isinstance(stored, dict):
        raise ValueError("Readcast config.yml must contain a YAML mapping")
    config = DEFAULTS.copy()
    for key, value in stored.items():
        if not isinstance(key, str) or not key.strip():
            raise ValueError("Configuration setting names must be non-empty strings")
        if re.search(r"secret|token|password|credential|api[_-]?key|access[_-]?key", key, re.I):
            raise ValueError("Credentials belong in environment variables, not config.yml")
        if key not in config:
            raise ValueError(f"Unsupported Readcast setting: {key}")
        if value is None or isinstance(value, (dict, list)):
            raise ValueError(f"Readcast setting {key} must be a scalar")
        config[key] = str(value).lower() if isinstance(value, bool) else str(value)
    for key in ("github_pages_url", "worker_url", "hosted_worker_url"):
        value = config[key].strip()
        if value:
            parsed = urlsplit(value)
            if parsed.scheme not in ("http", "https") or not parsed.netloc or parsed.username or parsed.password or parsed.query or parsed.fragment:
                raise ValueError(f"Readcast setting {key} must be a URL without credentials, query or fragment")
    for key in ("data_dir", "narration_cache_dir"):
        config[key] = str(Path(config[key]).expanduser())
    return config
