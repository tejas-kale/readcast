# Readcast

Readcast is a Shiny app for reading Markdown clippings and generating MP3 narrations through OpenRouter.

## Layout

- `app.R` is the standard Shiny entry point.
- `R/` contains the narration and Markdown preprocessing code.
- `org/` contains the editable literate sources. Each org file tangles to exactly one R file.
- `tests/testthat/` contains the tests copied from the original app.

Edit the org files, then regenerate the R files from the project root:

```sh
emacs -Q --batch --eval '(progn (require (quote org)) (mapc (lambda (file) (org-babel-tangle-file file)) (directory-files "org" t "[.]org$")))'
```

## Install and run

Install Readcast from a checkout with:

```sh
./install.sh
```

This copies the app to `~/.local/share/readcast` and installs the `readcast` command in `~/.local/bin`. Add that directory to `PATH` if your shell does not already include it. From a checkout, `./bin/readcast` runs the same command directly. Both commands work from any current directory.

Configure the folder containing your Markdown clippings once:

```sh
readcast configure ~/Documents/Clippings
```

Readcast saves this non-secret setting in `~/.config/readcast/clippings-dir`. You can instead set `CLIPPINGS_DIR` in the environment to override it. The app reports an actionable error when the configured directory is missing or invalid.

## Dependencies and credentials

Install the R packages used by the app:

```sh
Rscript -e 'install.packages(c("base64enc", "callr", "commonmark", "digest", "fs", "htmltools", "httr2", "jsonlite", "magick", "purrr", "readr", "shiny", "stringi", "stringr", "xml2", "yaml"))'
```

Install `ffmpeg` separately and make your OpenRouter key available in the environment before generating narration:

```sh
export OPENROUTER_API_KEY="your-key"
readcast
```

Credentials such as `OPENROUTER_API_KEY`, `GITHUB_TOKEN`, `R2_ACCESS_KEY_ID`, and `R2_SECRET_ACCESS_KEY` belong in environment variables (or a local shell secret manager), never in the repository or Readcast's personal configuration. `NARRATION_CACHE_DIR` can override the default MP3 cache directory (`~/.cache/readcast/narrations`).

Use **Set up Readcast** in the app to save your Clippings folder, podcast show metadata and optional non-secret publishing values. The connection checks are independent and safe to rerun: Clippings counts local Markdown files, OpenRouter checks its models endpoint, R2 lists one bucket page and probes the Worker with a missing object, GitHub repository access makes a read-only repository API request using `GITHUB_TOKEN`, and GitHub Pages separately requests the public site URL. The GitHub token needs repository contents write access for publication and is never displayed or saved. None of the checks creates resources, generates narration, or publishes audio. The app remains open when setup is incomplete; local reading, narration and playback do not depend on publishing services.

Publishing is optional and requires one-time manual provisioning. Create a dedicated public GitHub repository for the Pages site and enable Pages from the root of its main branch. Create the private `readcast-audio` R2 bucket, issue a token with Object Read & Write permission, and deploy the bundled Worker with the `AUDIO_BUCKET` binding; see [worker/README.md](worker/README.md). Configure `READCAST_WORKER_URL`, `R2_ACCOUNT_ID`, `R2_BUCKET`, `R2_ACCESS_KEY_ID`, and `R2_SECRET_ACCESS_KEY` in the environment. The Pages URL and the permanent `workers.dev` URL are separate addresses. The app's **Upload cached audio to R2** action publishes only the currently selected cache file; the Worker origin is saved after a successful upload and must remain unchanged.

To publish an episode, select an existing cached narration, approve a show cover, and confirm the clipping's eligibility the first time you publish it. Readcast uploads the MP3 to R2, the approved cover and RSS 2.0 feed to the Pages repository, then checks that the public resources respond before showing the feed URL. In Apple Podcasts, add the show by URL and follow it. Show title, description, language and explicit-content setting are editable in setup; an episode description is included only when the clipping already has description metadata. **Review aged audio cleanup** asks for confirmation, fetches the current live feed, and deletes only replaced audio that has been retained for at least 30 days and is no longer referenced; it needs GitHub and R2 credentials.

The Podcast cover controls let you edit a starting prompt, generate and inspect a candidate with OpenRouter's `openai/gpt-image-2`, then explicitly approve it. Candidates and approved artwork are saved separately under `~/.local/share/readcast/covers`; `READCAST_DATA_DIR` can override the parent directory. Generation requires `OPENROUTER_API_KEY`. The approved PNG is checked for a square 1400–3000 px size and an opaque background.

When changing the app, edit the org files and regenerate their single R targets from the project root:

```sh
emacs -Q --batch --eval '(progn (require (quote org)) (mapc (lambda (file) (org-babel-tangle-file file)) (directory-files "org" t "[.]org$")))'
```
