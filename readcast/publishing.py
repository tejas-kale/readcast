"""Remote audio and podcast feed publication for Readcast."""

from __future__ import annotations

import base64
import hashlib
import json
import os
import re
import time
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from datetime import datetime, timezone
from email.utils import format_datetime
from pathlib import Path
from typing import Any


ITUNES = "http://www.itunes.com/dtds/podcast-1.0.dtd"
DC = "http://purl.org/dc/elements/1.1/"
ET.register_namespace("itunes", ITUNES)
ET.register_namespace("dc", DC)


def _need(config: dict, key: str) -> str:
    value = str(config.get(key, "")).strip()
    if not value:
        raise ValueError(f"Set {key} in the Readcast configuration before publishing.")
    return value


def _http(url: str, method: str = "GET", *, headers: dict | None = None,
          data: bytes | None = None, timeout: int = 30) -> tuple[int, dict, bytes]:
    request = urllib.request.Request(url, data=data, headers=headers or {}, method=method)
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return response.status, dict(response.headers.items()), response.read()
    except urllib.error.HTTPError as error:
        return error.code, dict(error.headers.items()), error.read()


def _verify(url: str, content_type: str | None = None, length: int | None = None) -> None:
    status, headers, _ = _http(url, "HEAD")
    if not 200 <= status < 300:
        raise RuntimeError(f"Public resource is not reachable yet (HTTP {status}): {url}")
    if content_type and headers.get("Content-Type", "").split(";", 1)[0].strip().lower() != content_type:
        raise RuntimeError(f"Public resource has unexpected content type at {url}.")
    if length is not None and headers.get("Content-Length") != str(length):
        raise RuntimeError(f"Public resource has unexpected byte length at {url}.")


def _wait_for_visibility(check, timeout: int = 120) -> None:
    deadline = time.monotonic() + timeout
    delay = 2
    while True:
        try:
            check()
            return
        except RuntimeError as error:
            message = str(error)
            retryable = any(part in message for part in (
                "HTTP 404", "HTTP 408", "HTTP 429", "HTTP 5",
                "expected episode GUID", "valid RSS 2.0", "hosted audio",
                "approved cover", "unexpected content type", "unexpected byte length",
            ))
            if not retryable or time.monotonic() >= deadline:
                raise
            time.sleep(min(delay, max(0, deadline - time.monotonic())))
            delay = min(delay * 2, 10)


def upload_episode(config: dict, state: dict, workspace: Path) -> str:
    """Upload the episode MP3 to R2 and return its stable public URL."""
    audio = Path(workspace) / "episode.mp3"
    if not audio.is_file() or audio.stat().st_size <= 0:
        raise ValueError("The workspace does not contain a non-empty episode.mp3.")
    account = _need(config, "r2_account_id")
    bucket = _need(config, "r2_bucket")
    access = os.environ.get("R2_ACCESS_KEY_ID", "").strip()
    secret = os.environ.get("R2_SECRET_ACCESS_KEY", "").strip()
    if not access or not secret:
        raise ValueError("Set R2_ACCESS_KEY_ID and R2_SECRET_ACCESS_KEY in the shell environment.")
    worker = _need(config, "worker_url").rstrip("/")
    if not re.fullmatch(r"https://[a-z0-9-]+\.[a-z0-9-]+\.workers\.dev", worker):
        raise ValueError("worker_url must be the permanent HTTPS workers.dev origin.")
    hosted_origin = str(config.get("hosted_worker_url") or state.get("worker_origin") or "").rstrip("/")
    if hosted_origin and hosted_origin != worker:
        raise ValueError("worker_url differs from the Worker origin already used for published audio.")
    digest = hashlib.sha256(audio.read_bytes()).hexdigest()
    key = state.get("audio_key") or f"audio/{digest}.mp3"
    if not re.fullmatch(r"audio/[A-Za-z0-9_-]+\.mp3", key):
        raise ValueError("Saved audio object key is invalid.")
    url = f"{worker}/{key}"
    # Reuse a matching completed upload, while deterministic keys make an interrupted
    # upload safely repeatable if state was not persisted after the remote write.
    if state.get("audio_url") == url and state.get("audio_hash") == digest:
        _verify(url, "audio/mpeg", audio.stat().st_size)
        return url
    try:
        import boto3
        from botocore.config import Config
    except ImportError as error:
        raise RuntimeError("Publishing requires boto3. Install the project dependencies and retry.") from error
    client = boto3.client(
        "s3", endpoint_url=f"https://{account}.r2.cloudflarestorage.com",
        aws_access_key_id=access, aws_secret_access_key=secret,
        region_name="auto", config=Config(signature_version="s3v4"),
    )
    client.upload_file(str(audio), bucket, key, ExtraArgs={"ContentType": "audio/mpeg"})
    state.update(audio_url=url, audio_key=key, audio_hash=digest, worker_origin=worker,
                 audio_size=audio.stat().st_size, publication_state="audio_uploaded")
    _verify(url, "audio/mpeg", audio.stat().st_size)
    return url


def _repository(pages_url: str) -> tuple[str, str, str]:
    parsed = urllib.parse.urlparse(pages_url)
    match = re.fullmatch(r"([A-Za-z0-9-]+)\.github\.io", parsed.hostname or "", re.I)
    if parsed.scheme != "https" or not match or parsed.query or parsed.fragment:
        raise ValueError("github_pages_url must be an HTTPS URL of the form https://<account>.github.io/<repository>/.")
    owner = match.group(1)
    parts = parsed.path.strip("/").split("/") if parsed.path.strip("/") else []
    repository = parts[0] if parts else f"{owner}.github.io"
    return owner, repository, pages_url.rstrip("/")


def _github_request(owner: str, repo: str, path: str, token: str,
                    method: str = "GET", payload: dict | None = None) -> tuple[int, dict]:
    url = f"https://api.github.com/repos/{urllib.parse.quote(owner)}/{urllib.parse.quote(repo)}/contents/{path}"
    headers = {"Authorization": f"Bearer {token}", "Accept": "application/vnd.github+json",
               "X-GitHub-Api-Version": "2022-11-28", "User-Agent": "Readcast podcast publisher"}
    data = json.dumps(payload).encode() if payload is not None else None
    if data is not None:
        headers["Content-Type"] = "application/json"
    status, _, body = _http(url, method, headers=headers, data=data)
    try:
        return status, json.loads(body) if body else {}
    except (ValueError, UnicodeDecodeError):
        return status, {}


def _contents_put(owner: str, repo: str, path: str, content: bytes, token: str,
                  sha: str | None = None) -> None:
    payload = {"message": f"Publish Readcast {Path(path).name}",
               "content": base64.b64encode(content).decode("ascii")}
    if sha:
        payload["sha"] = sha
    status, _ = _github_request(owner, repo, path, token, "PUT", payload)
    if not 200 <= status < 300:
        raise RuntimeError(f"GitHub Pages rejected {path} (HTTP {status}).")


def _xml_text(parent: ET.Element, name: str, value: str) -> None:
    node = ET.SubElement(parent, name)
    node.text = value


def _episode_item(state: dict) -> ET.Element:
    item = ET.Element("item")
    _xml_text(item, "title", str(state.get("title") or "Untitled episode"))
    if state.get("source_url"):
        _xml_text(item, "link", str(state["source_url"]))
    if state.get("author"):
        _xml_text(item, f"{{{ITUNES}}}author", str(state["author"]))
    if state.get("published"):
        _xml_text(item, f"{{{DC}}}date", str(state["published"]))
    if state.get("description"):
        _xml_text(item, "description", str(state["description"]))
    guid = str(state.get("guid") or f"urn:readcast:episode:{state['id']}")
    ET.SubElement(item, "guid", {"isPermaLink": "false"}).text = guid
    published = state.get("published_at") or state.get("publication_started_at") or datetime.now(timezone.utc).isoformat()
    try:
        parsed = datetime.fromisoformat(str(published).replace("Z", "+00:00"))
    except ValueError:
        parsed = datetime.now(timezone.utc)
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    _xml_text(item, "pubDate", format_datetime(parsed.astimezone(timezone.utc), usegmt=True))
    ET.SubElement(item, "enclosure", {"url": str(state["audio_url"]),
        "length": str(state["audio_size"]), "type": "audio/mpeg"})
    return item


def _feed_bytes(existing: bytes | None, config: dict, pages_url: str,
                state: dict, cover_url: str) -> bytes:
    if existing:
        try:
            root = ET.fromstring(existing)
            channel = root.find("channel")
            if root.tag != "rss" or channel is None:
                raise ValueError("missing RSS channel")
        except (ET.ParseError, ValueError) as error:
            raise RuntimeError("The existing published RSS feed is unreadable; refusing to replace it.") from error
    else:
        root = ET.Element("rss", {"version": "2.0"})
        channel = ET.SubElement(root, "channel")
        for tag, key, fallback in (("title", "podcast_title", "Readcast"),
                                   ("link", "", pages_url),
                                   ("description", "podcast_description", "A personal collection of narrated articles."),
                                   ("language", "podcast_language", "en")):
            _xml_text(channel, tag, str(config.get(key) or fallback) if key else fallback)
        _xml_text(channel, f"{{{ITUNES}}}explicit", str(config.get("podcast_explicit") or "false"))
        _xml_text(channel, f"{{{ITUNES}}}block", "yes")
    guid = str(state.get("guid") or f"urn:readcast:episode:{state['id']}")
    for item in list(channel.findall("item")):
        item_guid = item.findtext("guid", "")
        if item_guid == guid:
            channel.remove(item)
    cover = channel.find(f"{{{ITUNES}}}image")
    if cover is None:
        cover = ET.SubElement(channel, f"{{{ITUNES}}}image")
    cover.set("href", cover_url)
    channel.append(_episode_item(state))
    return ET.tostring(root, encoding="utf-8", xml_declaration=True)


def publish_episode(config: dict, state: dict, workspace: Path,
                    cover_path: Path, replace: bool = False) -> str:
    """Publish the episode, preserving other feed entries and replacing its GUID in place."""
    audio_url = upload_episode(config, state, workspace)
    state["guid"] = state.get("guid") or f"urn:readcast:episode:{state['id']}"
    state.setdefault("audio_size", (Path(workspace) / "episode.mp3").stat().st_size)
    state.setdefault("publication_started_at", datetime.now(timezone.utc).isoformat())
    cover_file = Path(cover_path)
    if not cover_file.is_file() or cover_file.stat().st_size <= 0:
        raise ValueError("Select an existing non-empty approved podcast cover.")
    owner, repo, pages_url = _repository(_need(config, "github_pages_url"))
    token = os.environ.get("GITHUB_TOKEN", "").strip()
    if not token:
        raise ValueError("Set GITHUB_TOKEN with contents write access to the Pages repository.")
    cover_url = f"{pages_url}/cover.png"
    cover_data = cover_file.read_bytes()
    status, current_cover = _github_request(owner, repo, "cover.png", token)
    if status not in (200, 404):
        raise RuntimeError(f"Could not inspect GitHub Pages cover.png (HTTP {status}).")
    _contents_put(owner, repo, "cover.png", cover_data, token,
                  current_cover.get("sha") if status == 200 else None)
    _wait_for_visibility(lambda: _verify(cover_url, "image/png", len(cover_data)))
    status, current = _github_request(owner, repo, "feed.xml", token)
    if status == 404:
        old_feed, sha = None, None
    elif status == 200:
        sha = current.get("sha")
        try:
            old_feed = base64.b64decode(re.sub(r"\s", "", current["content"]), validate=True)
        except (KeyError, ValueError) as error:
            raise RuntimeError("The existing published RSS feed is unreadable; refusing to replace it.") from error
    else:
        raise RuntimeError(f"Could not read the current GitHub Pages feed (HTTP {status}).")
    # A replacement uses the same stable GUID and a content-addressed audio URL.
    # The flag is retained for the caller's explicit replacement flow; the remote
    # upsert itself is idempotent in either case.
    _ = replace
    feed = _feed_bytes(old_feed, config, pages_url, state, cover_url)
    _contents_put(owner, repo, "feed.xml", feed, token, sha)
    feed_url = f"{pages_url}/feed.xml"
    def check_feed():
        status, _, response = _http(feed_url)
        if not 200 <= status < 300:
            raise RuntimeError(f"Published RSS feed is not reachable yet (HTTP {status}): {feed_url}")
        try:
            published = ET.fromstring(response)
        except ET.ParseError as error:
            raise RuntimeError("Published URL did not return a valid RSS 2.0 feed.") from error
        if published.get("version") != "2.0":
            raise RuntimeError("Published URL did not return a valid RSS 2.0 feed.")
        channel = published.find("channel")
        items = channel.findall("item") if channel is not None else []
        item = next((item for item in items if item.findtext("guid") == state["guid"]), None)
        if item is None:
            raise RuntimeError("Published RSS feed does not contain the expected episode GUID.")
        enclosure = item.find("enclosure")
        if enclosure is None or enclosure.get("url") != audio_url or enclosure.get("length") != str(state["audio_size"]):
            raise RuntimeError("Published RSS enclosure does not match the hosted audio.")
        image = channel.find(f"{{{ITUNES}}}image") if channel is not None else None
        if image is None or image.get("href") != cover_url:
            raise RuntimeError("Published RSS feed does not reference the approved cover.")

    _wait_for_visibility(check_feed)
    state.update(publication_state="complete", published_at=state.get("published_at") or state["publication_started_at"],
                 feed_url=feed_url)
    return feed_url
