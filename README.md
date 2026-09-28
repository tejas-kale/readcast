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
Rscript -e 'install.packages(c("base64enc", "callr", "commonmark", "digest", "fs", "htmltools", "httr2", "magick", "purrr", "readr", "shiny", "stringi", "stringr", "xml2", "yaml"))'
```

Install `ffmpeg` separately and make your OpenRouter key available in the environment before generating narration:

```sh
export OPENROUTER_API_KEY="your-key"
readcast
```

Credentials such as `OPENROUTER_API_KEY` belong in environment variables (or a local shell secret manager), never in the repository or Readcast's personal configuration. `NARRATION_CACHE_DIR` can override the default MP3 cache directory (`~/.cache/readcast/narrations`). To host an already-cached narration, deploy the private-bucket Worker in [worker/README.md](worker/README.md), then set `READCAST_WORKER_URL`, `R2_ACCOUNT_ID`, `R2_BUCKET`, `R2_ACCESS_KEY_ID`, and `R2_SECRET_ACCESS_KEY` in the environment before launching Readcast. The app's **Upload cached audio to R2** action publishes only the currently selected cache file; the Worker origin is saved after a successful upload and must remain unchanged.

The Podcast cover controls let you edit a starting prompt, generate and inspect a candidate with OpenRouter's `openai/gpt-image-2`, then explicitly approve it. Candidates and approved artwork are saved separately under `~/.local/share/readcast/covers`; `READCAST_DATA_DIR` can override the parent directory. Generation requires `OPENROUTER_API_KEY`. The approved PNG is checked for a square 1400–3000 px size and an opaque background.

When changing the app, edit the org files and regenerate their single R targets from the project root:

```sh
emacs -Q --batch --eval '(progn (require (quote org)) (mapc (lambda (file) (org-babel-tangle-file file)) (directory-files "org" t "[.]org$")))'
```
