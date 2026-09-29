"""Feed preservation and retry state at the publishing boundary."""

from pathlib import Path
import xml.etree.ElementTree as ET

import pytest

from readcast import publishing


LEGACY_FEED = b'''<?xml version="1.0"?><rss version="2.0"><channel><title>Readcast</title><item><title>Older article</title><guid>urn:legacy:42</guid><enclosure url="https://old.example/audio.mp3" length="12" type="audio/mpeg"/></item></channel></rss>'''


def test_feed_upsert_preserves_legacy_item_and_replaces_guid():
    config = {"podcast_title": "Readcast", "podcast_explicit": "false"}
    state = {"id": "abc", "guid": "urn:readcast:episode:abc", "title": "A new article",
             "description": "Summary", "audio_url": "https://worker.example/audio/a.mp3", "audio_size": 3}
    first = publishing._feed_bytes(LEGACY_FEED, config, "https://example.github.io/show", state, "https://example.github.io/show/cover.png")
    state["audio_url"] = "https://worker.example/audio/b.mp3"
    replaced = publishing._feed_bytes(first, config, "https://example.github.io/show", state, "https://example.github.io/show/cover.png")
    root = ET.fromstring(replaced)
    items = root.findall("channel/item")
    assert len(items) == 2
    assert next(item for item in items if item.findtext("guid") == "urn:legacy:42").find("enclosure").get("url") == "https://old.example/audio.mp3"
    current = next(item for item in items if item.findtext("guid") == state["guid"])
    assert current.find("enclosure").get("url") == state["audio_url"]


def test_public_verification_identifies_readcast_to_worker(monkeypatch):
    class Response:
        headers = {"Content-Type": "audio/mpeg", "Content-Length": "3"}

        def __init__(self, status):
            self.status = status

        def __enter__(self):
            return self

        def __exit__(self, *_):
            pass

        def read(self):
            return b""

    def fake_urlopen(request, timeout):
        return Response(200 if request.get_header("User-agent") == "Readcast/0.1" else 403)

    monkeypatch.setattr(publishing.urllib.request, "urlopen", fake_urlopen)
    publishing._verify("https://example.workers.dev/audio/episode.mp3", "audio/mpeg", 3)


def test_publish_does_not_mark_complete_when_feed_verification_fails(tmp_path: Path, monkeypatch):
    workspace = tmp_path / "workspace"
    workspace.mkdir()
    (workspace / "episode.mp3").write_bytes(b"mp3")
    cover = tmp_path / "cover.png"
    cover.write_bytes(b"png")
    state = {"id": "abc", "guid": "urn:readcast:episode:abc", "title": "Episode"}
    config = {"github_pages_url": "https://example.github.io/show/"}
    monkeypatch.setattr(publishing, "upload_episode", lambda config, state, path: state.update(audio_url="https://worker.example/audio/a.mp3", audio_size=3) or state["audio_url"])
    monkeypatch.setenv("GITHUB_TOKEN", "fake-token")

    def fake_github(owner, repo, path, token, method="GET", payload=None):
        return (404, {}) if method == "GET" else (201, {})

    monkeypatch.setattr(publishing, "_github_request", fake_github)
    monkeypatch.setattr(publishing, "_wait_for_visibility", lambda check: check())
    monkeypatch.setattr(publishing, "_verify", lambda *args: None)
    monkeypatch.setattr(publishing, "_http", lambda *args, **kwargs: (404, {}, b""))
    with pytest.raises(RuntimeError, match="not reachable"):
        publishing.publish_episode(config, state, workspace, cover)
    assert "published_at" not in state
    assert state["publication_started_at"]
