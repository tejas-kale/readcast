# Readcast

Readcast is a Python command-line application for turning Markdown clippings into narrated podcast episodes. It prepares article text, generates resumable MP3 narration, manages local episode workspaces, creates podcast artwork, and can publish episodes through GitHub Pages and Cloudflare R2.

## Install

Readcast requires Python 3.11 or later. Install `ffmpeg` separately; it is used to assemble multi-part narration. On macOS, for example:

```sh
brew install ffmpeg
uv tool install .
```

Run `uv tool install .` from a checkout of this project. The `readcast` executable is then available on `PATH`. To update an existing installation after changing or pulling the project, run the same command with `--reinstall`.

## Configure

Create `~/.config/readcast/config.yml` and set the folder containing your Markdown clippings. Readcast stores narration cache entries in `~/.cache/readcast/narrations` and episode state and workspaces under `~/.local/share/readcast`. The configuration directory can be changed with the global `--config-dir` option; the data and cache paths are settings in the YAML file. Paths beginning with `~` are expanded.

Example configuration:

```yaml
clippings_dir: ~/Documents/Clippings
data_dir: ~/.local/share/readcast
narration_cache_dir: ~/.cache/readcast/narrations
speech_model: microsoft/mai-voice-2-flash
speech_voice: en-US-Harper:MAI-Voice-2
github_pages_url: https://account.github.io/readcast-podcast/
podcast_title: Readcast
podcast_description: A personal collection of narrated articles.
podcast_language: en
podcast_explicit: false
r2_account_id: your-cloudflare-account-id
r2_bucket: readcast-audio
worker_url: https://readcast.account.workers.dev
image_model: openai/gpt-image-2
cover_prompt: Create polished square podcast artwork with an opaque background.
```

The accepted settings and defaults are listed in the example above and in `readcast/config.py`. Keep credentials out of this file and out of the repository. Provide them to the process through environment variables:

```sh
export OPENROUTER_API_KEY="your-openrouter-key"
export GITHUB_TOKEN="your-github-token"
export R2_ACCESS_KEY_ID="your-r2-access-key-id"
export R2_SECRET_ACCESS_KEY="your-r2-secret-access-key"
```

Only the credentials needed for a particular operation are required. Narration and cover generation use `OPENROUTER_API_KEY`; publication uses the GitHub and R2 credentials. A secret manager can inject these variables when launching Readcast. Existing YAML files load with defaults for the new speech and cover settings; `hosted_worker_url`, when present, keeps the published Worker origin fixed. `readcast config check` also needs all four credentials; it reads the OpenRouter model catalogue, lists one R2 bucket page, probes a missing Worker object, and checks the GitHub repository and public Pages site. It does not generate or publish anything.

## Commands

Use `readcast --help` and `readcast <command> --help` for command options. `readcast prepare article.md` creates or refreshes a managed episode; `readcast narrate <episode-id>` generates audio; `readcast upload <episode-id>` uploads audio; and `readcast publish <episode-id>` publishes the RSS item. Stage commands also accept the original Markdown path. `readcast run article.md` performs the full workflow. A repeat run skips an already published CLI episode; `readcast run --replace article.md` updates its existing RSS item and GUID. `readcast narrate --model MODEL --voice VOICE <episode-id>` overrides speech settings for one command. `readcast list` and `readcast show <episode-id>` report local progress. Local episode work is resumable; generated chunks and state allow an interrupted narration to continue. `readcast cover generate [--prompt TEXT] [--model MODEL]` creates an artwork candidate, and `readcast cover set [candidate.png]` approves it. `readcast config check` reports missing prerequisites.

Preview stale local episode products and narration cache entries before removing them:

```sh
readcast cleanup
readcast cleanup --apply
```

Cleanup reads each episode's `last_activity` timestamp and retains its `state.json`. When an episode exceeds 30 days without activity, cleanup may remove its generated snapshot, script, MP3, and chunk files. Cache files are aged by their local modification time. Cleanup operates only on local files; it does not delete audio or feed resources from GitHub or Cloudflare.

## Publishing infrastructure

Publishing is optional. The deployment uses a public GitHub repository for the podcast feed and artwork, a private Cloudflare R2 bucket for episode audio, and the Worker in [`worker/`](worker/README.md) to serve audio. Keep the R2 bucket private and do not configure an `r2.dev` public URL. Set `github_pages_url`, `r2_account_id`, `r2_bucket`, and `worker_url` in `config.yml`; inject `GITHUB_TOKEN`, `R2_ACCESS_KEY_ID`, and `R2_SECRET_ACCESS_KEY` through the environment.

Create the GitHub Pages repository and enable Pages from the root of its default branch. The GitHub token needs repository Contents write access for publishing. Create the Cloudflare R2 bucket and deploy the bundled Worker with Wrangler; the account must have R2 activated first. Wrangler login is used for infrastructure setup, while Readcast's S3 upload requires a separate R2 access key and secret scoped to the bucket. Keep the Worker origin stable after publishing, because published feed entries point to it.

For the full Worker deployment steps and binding details, see [`worker/README.md`](worker/README.md). Cloudflare's [R2 setup guide](https://developers.cloudflare.com/r2/get-started/), [Wrangler R2 commands](https://developers.cloudflare.com/r2/reference/wrangler-commands/), and [Worker deployment guide](https://developers.cloudflare.com/workers/get-started/guide/) cover the account and deployment steps. GitHub documents [repository creation](https://cli.github.com/manual/gh_repo_create) and [Pages setup](https://docs.github.com/en/pages).

## Migration from the Shiny app

The Python CLI replaces the former R/Shiny application and its Emacs Org tangling workflow. Install Readcast with `uv tool install .` and keep your existing `~/.config/readcast/config.yml`; new speech and artwork settings receive defaults. Existing Markdown clippings remain in place. Make credentials available as environment variables. Local state and MP3s from the old app are not imported, while its published feed items and remote audio remain available.
