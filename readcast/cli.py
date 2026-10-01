"""Click command boundary for Readcast's resumable workflow."""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import shutil
import sys

import click

from .config import load_config
from .workspace import all_states, find_episode, find_stdin_episode, prepare as prepare_workspace, save_state, stage_status


def _config(ctx: click.Context) -> dict:
    if "config" not in ctx.obj:
        ctx.obj["config"] = load_config(ctx.obj["config_dir"])
    return ctx.obj["config"]


def _narrate(config: dict, path: Path, state: dict, model: str | None, voice: str | None,
             renarrate: bool = False) -> Path:
    from .narration import default_voice_for, narrate_chunks, split_article

    script = path / "script.txt"
    if not script.is_file():
        raise ValueError("No prepared script remains; run prepare on the original Markdown")
    selected_model = model or config["speech_model"]
    selected_voice = voice or config["speech_voice"] or default_voice_for(selected_model)
    chunks = split_article(script.read_text(encoding="utf-8"))
    # A model or voice change alters all dependent audio and upload records.
    fingerprint = hashlib.sha256(json.dumps([state["script_hash"], selected_model, selected_voice]).encode()).hexdigest()
    output = path / "episode.mp3"
    if not renarrate and state.get("narration_hash") == fingerprint and output.is_file() and output.stat().st_size:
        if state.get("mp3_hash") == hashlib.sha256(output.read_bytes()).hexdigest():
            click.echo("Using completed narration", err=True)
            return output
    click.echo("Generating narration", err=True)
    for key in ("audio_url", "audio_key", "audio_hash", "audio_size"):
        state.pop(key, None)
    state.pop("narration_hash", None)
    state.pop("mp3_hash", None)
    output.unlink(missing_ok=True)
    save_state(path, state)
    pauses_after = [i for i, chunk in enumerate(chunks, start=1) if chunk.endswith("\n\n")]
    output = narrate_chunks(
        chunks, output, model=selected_model, voice=selected_voice,
        cache_dir=config["narration_cache_dir"], pauses_after=pauses_after,
        force=renarrate,
        progress=lambda done, total: click.echo(f"Completed chunk {done}/{total}", err=True),
    )
    state.update(narration_hash=fingerprint, mp3_hash=hashlib.sha256(output.read_bytes()).hexdigest(),
                 mp3_path=str(output), model=selected_model, voice=selected_voice)
    save_state(path, state)
    return output


def _upload(config: dict, path: Path, state: dict) -> str:
    from .publishing import upload_episode

    if not _valid_mp3(path, state):
        raise ValueError("Narration is incomplete or stale; run narrate before upload")
    click.echo("Uploading audio", err=True)
    try:
        return upload_episode(config, state, path)
    finally:
        save_state(path, state)


def _publish(config: dict, path: Path, state: dict, replace: bool = False) -> str:
    from .cover import approved_cover
    from .publishing import publish_episode

    if state.get("published_at") and not replace:
        return state.get("feed_url") or config["github_pages_url"].rstrip("/") + "/feed.xml"
    if not _valid_mp3(path, state):
        raise ValueError("Narration is incomplete or stale; run narrate before publishing")
    click.echo("Publishing podcast episode", err=True)
    try:
        return publish_episode(config, state, path, approved_cover(config), replace=replace)
    finally:
        save_state(path, state)


def _valid_mp3(path: Path, state: dict) -> bool:
    audio = path / "episode.mp3"
    return bool(state.get("narration_hash") and state.get("mp3_hash") and audio.is_file()
                and audio.stat().st_size and hashlib.sha256(audio.read_bytes()).hexdigest() == state["mp3_hash"])


@click.group()
@click.option("--config-dir", type=click.Path(path_type=Path), default="~/.config/readcast", help="Directory containing config.yml")
@click.pass_context
def main(ctx: click.Context, config_dir: Path):
    """Prepare, narrate and publish Markdown to your podcast feed."""
    ctx.ensure_object(dict)
    ctx.obj["config_dir"] = config_dir.expanduser()


def _read_markdown_input(reference: str | None, source_id: str | None) -> bytes | None:
    if reference is None and sys.stdin.isatty():
        raise ValueError("Provide a Markdown file or pipe Markdown on stdin")
    if reference in (None, "-"):
        stream = getattr(sys.stdin, "buffer", sys.stdin)
        contents = stream.read()
        return contents.encode("utf-8") if isinstance(contents, str) else contents
    if source_id is not None:
        raise ValueError("--source-id is only available when reading Markdown from stdin")
    return None


@main.command()
@click.argument("reference", required=False)
@click.option("--source-id", help="Stable identity for Markdown read from stdin")
@click.pass_context
def prepare(ctx: click.Context, reference: str | None, source_id: str | None):
    """Prepare a Markdown file or refresh an existing episode."""
    try:
        click.echo("Preparing Markdown", err=True)
        markdown = _read_markdown_input(reference, source_id)
        if markdown is not None:
            _, state = prepare_workspace(_config(ctx), raw_input=markdown, source_id=source_id)
        else:
            _, state = prepare_workspace(_config(ctx), reference)
        click.echo(state["id"])
    except (ValueError, OSError) as error:
        raise click.ClickException(str(error)) from error


@main.command()
@click.argument("reference")
@click.option("--model", help="OpenRouter speech model for this narration")
@click.option("--voice", help="Voice for this narration")
@click.option("--renarrate", is_flag=True, help="Generate fresh speech for every chunk")
@click.pass_context
def narrate(ctx: click.Context, reference: str, model: str | None, voice: str | None, renarrate: bool):
    """Create an MP3 from a prepared episode or Markdown path."""
    try:
        config = _config(ctx)
        path, state = prepare_workspace(config, reference)
        click.echo(_narrate(config, path, state, model, voice, renarrate))
    except Exception as error:
        raise click.ClickException(str(error)) from error


@main.command()
@click.argument("reference")
@click.pass_context
def upload(ctx: click.Context, reference: str):
    """Upload a completed MP3 to the private R2 bucket."""
    try:
        config = _config(ctx)
        path, state = find_episode(config, reference)
        click.echo(_upload(config, path, state))
    except Exception as error:
        raise click.ClickException(str(error)) from error


@main.command()
@click.argument("reference")
@click.option("--replace", is_flag=True, help="Update an existing published RSS item")
@click.pass_context
def publish(ctx: click.Context, reference: str, replace: bool):
    """Upload a completed MP3 if needed and publish its RSS item."""
    try:
        config = _config(ctx)
        path, state = find_episode(config, reference)
        click.echo(_publish(config, path, state, replace))
    except Exception as error:
        raise click.ClickException(str(error)) from error


@main.command()
@click.argument("reference", required=False)
@click.option("--source-id", help="Stable identity for Markdown read from stdin")
@click.option("--model", help="OpenRouter speech model for this run")
@click.option("--voice", help="Voice for this run")
@click.option("--replace", is_flag=True, help="Update an existing published RSS item")
@click.option("--renarrate", is_flag=True, help="Generate fresh speech for every chunk")
@click.pass_context
def run(ctx: click.Context, reference: str | None, source_id: str | None, model: str | None, voice: str | None,
        replace: bool, renarrate: bool):
    """Prepare, narrate, upload and publish one Markdown article."""
    try:
        if renarrate and not replace:
            raise ValueError("--renarrate requires --replace when using run")
        config = _config(ctx)
        markdown = _read_markdown_input(reference, source_id)
        if markdown is not None:
            if not replace:
                existing = find_stdin_episode(config, markdown, source_id)
                if existing and existing[1].get("published_at"):
                    state = existing[1]
                    click.echo(state.get("feed_url") or config["github_pages_url"].rstrip("/") + "/feed.xml")
                    click.echo(f"Episode {state['id']} is already published", err=True)
                    return
            path, state = prepare_workspace(config, raw_input=markdown, source_id=source_id)
        if not replace:
            if markdown is None:
                try:
                    _, existing = find_episode(config, reference)
                except ValueError:
                    existing = None
                if existing and existing.get("published_at"):
                    click.echo(existing.get("feed_url") or config["github_pages_url"].rstrip("/") + "/feed.xml")
                    click.echo(f"Episode {existing['id']} is already published", err=True)
                    return
        click.echo("Preparing Markdown", err=True)
        if markdown is None:
            path, state = prepare_workspace(config, reference)
        _narrate(config, path, state, model, voice, renarrate)
        click.echo(_publish(config, path, state, replace))
    except Exception as error:
        raise click.ClickException(str(error)) from error


@main.command("list")
@click.pass_context
def list_episodes(ctx: click.Context):
    """List managed episode IDs and stage status."""
    for path, state in all_states(_config(ctx)):
        stages = stage_status(path, state)
        click.echo(f"{state['id']}\t{stages['prepared']}\t{stages['narrated']}\t{stages['uploaded']}\t{stages['published']}\t{state.get('title', '')}")


@main.command()
@click.argument("reference")
@click.pass_context
def show(ctx: click.Context, reference: str):
    """Show an episode's identity and stage status."""
    try:
        path, state = find_episode(_config(ctx), reference)
        click.echo(json.dumps({**state, "stages": stage_status(path, state)}, indent=2, sort_keys=True))
    except ValueError as error:
        raise click.ClickException(str(error)) from error


@main.command()
@click.option("--apply", is_flag=True, help="Delete the listed local artefacts")
@click.pass_context
def cleanup(ctx: click.Context, apply: bool):
    """Preview or remove local artefacts inactive for 30 days."""
    from .cleanup import cleanup as clean

    for path in clean(_config(ctx), apply=apply):
        click.echo(path)
    click.echo("Deleted eligible local artefacts" if apply else "Preview only; use --apply to delete", err=True)


@main.group()
def cover():
    """Generate and approve podcast cover artwork."""


@cover.command("generate")
@click.option("--prompt", help="Prompt for this candidate")
@click.option("--model", help="Image model for this candidate")
@click.pass_context
def cover_generate(ctx: click.Context, prompt: str | None, model: str | None):
    from .cover import generate_candidate

    try:
        click.echo(generate_candidate(_config(ctx), prompt, model))
    except Exception as error:
        raise click.ClickException(str(error)) from error


@cover.command("set")
@click.argument("candidate", required=False, type=click.Path(path_type=Path))
@click.pass_context
def cover_set(ctx: click.Context, candidate: Path | None):
    from .cover import set_approved

    try:
        click.echo(set_approved(_config(ctx), candidate))
    except Exception as error:
        raise click.ClickException(str(error)) from error


@main.group()
def config():
    """Inspect local and service configuration."""


@config.command("check")
@click.pass_context
def config_check(ctx: click.Context):
    """Report missing prerequisites without generating or publishing."""
    try:
        settings = _config(ctx)
    except ValueError as error:
        raise click.ClickException(str(error)) from error
    missing = []
    if not shutil.which("ffmpeg"):
        missing.append("ffmpeg executable")
    for key in ("r2_account_id", "r2_bucket", "worker_url", "github_pages_url"):
        if not settings.get(key):
            missing.append(f"{key} in config.yml")
    for name in ("OPENROUTER_API_KEY", "R2_ACCESS_KEY_ID", "R2_SECRET_ACCESS_KEY", "GITHUB_TOKEN"):
        if not os.environ.get(name):
            missing.append(f"{name} environment variable")
    if not (Path(settings["data_dir"]) / "covers" / "show-cover.png").is_file():
        missing.append("approved podcast cover (run cover set)")
    for item in missing:
        click.echo(f"Missing: {item}", err=True)
    if missing:
        raise click.ClickException(f"{len(missing)} prerequisite(s) missing")
    from .checks import check_connections

    try:
        for service in check_connections(settings):
            click.echo(f"Connected: {service}")
    except Exception as error:
        raise click.ClickException(f"Connection check failed: {error}") from error


if __name__ == "__main__":
    main()
