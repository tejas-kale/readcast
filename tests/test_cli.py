"""Command boundary checks for local stages and remote adapters."""

from pathlib import Path
import json

from click.testing import CliRunner
import pytest

from readcast.cli import main
from readcast import narration, publishing
from readcast.config import load_config


ARTICLE = """---
title: A useful article
author: Jane Smith
source: https://example.com/article
description: A short description
published: 2024-01-02
---

## Opening

The article has **useful** prose and [a link](https://example.com).

```python
print('not spoken')
```
"""


@pytest.fixture
def project(tmp_path, monkeypatch):
    config = tmp_path / "config"
    config.mkdir()
    (config / "config.yml").write_text(
        f"data_dir: {tmp_path / 'data'}\n"
        f"narration_cache_dir: {tmp_path / 'cache'}\n"
        "github_pages_url: https://example.github.io/readcast/\n"
    )
    article = tmp_path / "article.md"
    article.write_text(ARTICLE)
    return config, article, tmp_path


def invoke(config: Path, *args: str):
    return CliRunner().invoke(main, ["--config-dir", str(config), *map(str, args)])


def test_prepare_rejects_bad_input_and_saves_inspectable_work(project):
    config, article, root = project
    result = invoke(config, "prepare", article)
    assert result.exit_code == 0, result.output
    episode_id = result.stdout.strip()
    workspace = root / "data" / "episodes" / episode_id
    assert (workspace / "snapshot.md").read_text() == ARTICLE
    script = (workspace / "script.txt").read_text()
    assert "Jane Smith" in script
    assert "Please read the code block" in script
    assert "https://" not in script
    assert (workspace / "state.json").is_file()
    assert invoke(config, "show", episode_id).exit_code == 0
    assert episode_id in invoke(config, "list").output
    assert invoke(config, "prepare", "https://example.com").exit_code != 0
    article.write_text("---\nauthor: Jane\n---\nBody")
    failed = invoke(config, "prepare", article)
    assert failed.exit_code != 0 and "title" in failed.output


def test_full_run_resume_skip_and_replace(project, monkeypatch):
    config, article, root = project
    generated = []
    published = []

    def fake_narrate(chunks, output_path, **kwargs):
        generated.append((list(chunks), kwargs["model"], kwargs["voice"]))
        output_path.write_bytes(b"MP3" + str(len(generated)).encode())
        return output_path

    def fake_publish(settings, state, workspace, cover_path, replace=False):
        published.append((state["guid"], replace))
        state["audio_url"] = "https://worker.example/audio/test.mp3"
        state["published_at"] = "2024-01-03T00:00:00+00:00"
        state["feed_url"] = "https://example.github.io/readcast/feed.xml"
        return state["feed_url"]

    monkeypatch.setattr(narration, "narrate_chunks", fake_narrate)
    monkeypatch.setattr(publishing, "publish_episode", fake_publish)
    monkeypatch.setattr("readcast.cover.approved_cover", lambda settings: root / "cover.png")
    first = invoke(config, "run", article)
    assert first.exit_code == 0, first.output
    assert len(generated) == len(published) == 1
    second = invoke(config, "run", article)
    assert second.exit_code == 0
    assert len(generated) == len(published) == 1
    article.write_text(ARTICLE.replace("**useful** prose", "**changed** prose"))
    replacement = invoke(config, "run", "--replace", article)
    assert replacement.exit_code == 0, replacement.output
    assert len(generated) == len(published) == 2
    assert published[0][0] == published[1][0]
    assert published[-1][1] is True


def test_failed_narration_resumes_and_stage_commands_use_episode_id(project, monkeypatch):
    config, article, root = project
    episode_id = invoke(config, "prepare", article).stdout.strip()
    calls = []

    def failed_once(chunks, output_path, **kwargs):
        calls.append(1)
        if len(calls) == 1:
            raise RuntimeError("speech interrupted")
        output_path.write_bytes(b"MP3")
        return output_path

    monkeypatch.setattr(narration, "narrate_chunks", failed_once)
    article.rename(root / "moved.md")
    assert invoke(config, "narrate", episode_id).exit_code != 0
    recovered = invoke(config, "narrate", episode_id)
    assert recovered.exit_code == 0, recovered.output
    state = json.loads((root / "data" / "episodes" / episode_id / "state.json").read_text())
    assert state["narration_hash"]
    assert invoke(config, "show", episode_id).exit_code == 0


def test_cleanup_preview_and_apply_preserve_identity(project):
    config, article, root = project
    episode_id = invoke(config, "prepare", article).stdout.strip()
    workspace = root / "data" / "episodes" / episode_id
    state_path = workspace / "state.json"
    state = json.loads(state_path.read_text())
    state["last_activity"] = "2020-01-01T00:00:00+00:00"
    state["published_at"] = "2020-01-02T00:00:00+00:00"
    state_path.write_text(json.dumps(state))
    preview = invoke(config, "cleanup")
    assert preview.exit_code == 0 and "snapshot.md" in preview.output
    assert (workspace / "snapshot.md").exists()
    applied = invoke(config, "cleanup", "--apply")
    assert applied.exit_code == 0
    assert not (workspace / "snapshot.md").exists()
    assert state_path.exists()
    assert invoke(config, "run", article).exit_code == 0  # published record skips


def test_existing_yaml_defaults_and_config_check(project, monkeypatch):
    config, _, _ = project
    settings = load_config(config)
    assert settings["speech_model"] == "microsoft/mai-voice-2-flash"
    assert settings["image_model"] == "openai/gpt-image-2"
    monkeypatch.delenv("OPENROUTER_API_KEY", raising=False)
    result = invoke(config, "config", "check")
    assert result.exit_code != 0
    assert "OPENROUTER_API_KEY" in result.output


def test_config_check_uses_read_only_service_boundary(project, monkeypatch):
    config, _, root = project
    (config / "config.yml").write_text((config / "config.yml").read_text() +
        "r2_account_id: account\nr2_bucket: bucket\nworker_url: https://readcast.account.workers.dev\n")
    for name in ("OPENROUTER_API_KEY", "R2_ACCESS_KEY_ID", "R2_SECRET_ACCESS_KEY", "GITHUB_TOKEN"):
        monkeypatch.setenv(name, "test-value")
    approved = root / "data" / "covers" / "show-cover.png"
    approved.parent.mkdir(parents=True)
    approved.write_bytes(b"selected")
    monkeypatch.setattr("readcast.cli.shutil.which", lambda executable: "/usr/bin/ffmpeg")
    called = []
    monkeypatch.setattr("readcast.checks.check_connections", lambda settings: called.append(settings["r2_bucket"]) or ["OpenRouter", "R2", "GitHub Pages"])
    result = invoke(config, "config", "check")
    assert result.exit_code == 0, result.output
    assert called == ["bucket"]
    assert "Connected: GitHub Pages" in result.output


def test_changed_article_identity_and_stale_audio_cannot_upload(project):
    config, article, root = project
    first_id = invoke(config, "prepare", article).stdout.strip()
    first_workspace = root / "data" / "episodes" / first_id
    (first_workspace / "episode.mp3").write_bytes(b"old")
    state = json.loads((first_workspace / "state.json").read_text())
    state["narration_hash"] = "old narration"
    (first_workspace / "state.json").write_text(json.dumps(state))
    article.write_text(ARTICLE.replace("https://example.com/article", "https://example.com/new-article"))
    second_id = invoke(config, "prepare", article).stdout.strip()
    assert second_id != first_id
    assert invoke(config, "show", article).output.find(second_id) >= 0
    assert invoke(config, "show", first_id).exit_code == 0
    assert invoke(config, "prepare", first_id).exit_code == 0
    assert invoke(config, "upload", second_id).exit_code != 0


def test_changed_markdown_invalidates_unpublished_mp3(project):
    config, article, root = project
    episode_id = invoke(config, "prepare", article).stdout.strip()
    workspace = root / "data" / "episodes" / episode_id
    (workspace / "episode.mp3").write_bytes(b"old")
    state_path = workspace / "state.json"
    state = json.loads(state_path.read_text())
    state["narration_hash"] = "old narration"
    state_path.write_text(json.dumps(state))
    article.write_text(ARTICLE.replace("**useful**", "**different**"))
    assert invoke(config, "prepare", article).exit_code == 0
    assert not (workspace / "episode.mp3").exists()
    assert "narration_hash" not in json.loads(state_path.read_text())


def test_cover_candidate_requires_explicit_selection(project):
    from PIL import Image

    config, _, root = project
    candidate = root / "candidate.png"
    Image.new("RGB", (1400, 1400), "navy").save(candidate)
    approved = root / "data" / "covers" / "show-cover.png"
    assert not approved.exists()
    result = invoke(config, "cover", "set", candidate)
    assert result.exit_code == 0, result.output
    assert approved.read_bytes() == candidate.read_bytes()
    invalid = root / "invalid.png"
    Image.new("RGBA", (1400, 1400), (0, 0, 0, 0)).save(invalid)
    failed = invoke(config, "cover", "set", invalid)
    assert failed.exit_code != 0
    assert approved.read_bytes() == candidate.read_bytes()
