"""Generate, validate and approve Readcast podcast cover artwork."""

from __future__ import annotations

import base64
import json
import os
import tempfile
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any


DEFAULT_PROMPT = (
    "Create polished, distinctive square podcast cover artwork. Use a solid opaque background, "
    "clear high contrast, and a central composition that remains legible as a small thumbnail. "
    "Do not include an Apple logo, device, or hardware."
)
DEFAULT_MODEL = "openai/gpt-image-2"


def _cover_paths(config: dict[str, Any]) -> tuple[Path, Path]:
    directory = Path(config["data_dir"]).expanduser() / "covers"
    return directory / "show-cover-candidate.png", directory / "show-cover.png"


def _validate_png(path: Path) -> None:
    """Validate PNG signature, dimensions, and opacity using Pillow."""
    try:
        from PIL import Image

        with Image.open(path) as image:
            if image.format != "PNG":
                raise ValueError("The cover candidate is not a readable PNG image.")
            if image.width != image.height or not 1400 <= image.width <= 3000:
                raise ValueError("The cover must be square and between 1400 and 3000 pixels per side.")
            if "A" in image.getbands() and image.getchannel("A").getextrema()[0] < 255:
                raise ValueError("The cover must have an opaque background with no transparency.")
            if "transparency" in image.info:
                alpha = image.convert("RGBA").getchannel("A")
                if alpha.getextrema()[0] < 255:
                    raise ValueError("The cover must have an opaque background with no transparency.")
    except ValueError:
        raise
    except Exception as error:
        raise ValueError("The cover candidate is not a readable PNG image.") from error


def generate_candidate(
    config: dict[str, Any], prompt: str | None = None, model: str | None = None
) -> Path:
    """Generate and save a validated candidate through OpenRouter's image API."""
    key = os.environ.get("OPENROUTER_API_KEY", "").strip()
    if not key:
        raise RuntimeError("Set OPENROUTER_API_KEY in your environment to generate a podcast cover.")
    selected_prompt = (prompt if prompt is not None else config.get("cover_prompt", DEFAULT_PROMPT)).strip()
    if not selected_prompt:
        raise ValueError("Enter a cover prompt before generating.")
    selected_model = model or config.get("image_model") or DEFAULT_MODEL
    payload = json.dumps({
        "model": selected_model,
        "prompt": selected_prompt,
        "aspect_ratio": "1:1",
        "size": "1920x1920",
        "output_format": "png",
        "background": "opaque",
    }).encode()
    request = urllib.request.Request(
        "https://openrouter.ai/api/v1/images", data=payload,
        headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(request, timeout=180) as response:
            result = json.loads(response.read())
    except urllib.error.HTTPError as error:
        if error.code in (401, 403):
            raise RuntimeError(
                "OpenRouter rejected OPENROUTER_API_KEY. Check that the key is valid, enabled, and has image-generation credits."
            ) from error
        raise
    try:
        image = result["data"][0]
        if image["media_type"] != "image/png":
            raise ValueError
        content = base64.b64decode(image["b64_json"], validate=True)
    except (KeyError, IndexError, TypeError, ValueError) as error:
        raise ValueError("OpenRouter did not return a PNG image. Try generating the candidate again.") from error

    candidate, _ = _cover_paths(config)
    candidate.parent.mkdir(parents=True, exist_ok=True)
    temporary: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(dir=candidate.parent, prefix="cover-", suffix=".png", delete=False) as stream:
            temporary = Path(stream.name)
            stream.write(content)
        _validate_png(temporary)
        temporary.replace(candidate)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)
    return candidate


def set_approved(config: dict[str, Any], candidate: Path | None = None) -> Path:
    """Copy a valid candidate to the persistent approved-cover path."""
    default_candidate, approved = _cover_paths(config)
    source = Path(candidate) if candidate is not None else default_candidate
    _validate_png(source)
    approved.parent.mkdir(parents=True, exist_ok=True)
    temporary: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(dir=approved.parent, prefix="approved-cover-", suffix=".png", delete=False) as stream:
            temporary = Path(stream.name)
        temporary.write_bytes(source.read_bytes())
        temporary.replace(approved)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)
    return approved


def approved_cover(config: dict[str, Any]) -> Path:
    """Return the approved cover path after validating the stored artwork."""
    _, approved = _cover_paths(config)
    _validate_png(approved)
    return approved
