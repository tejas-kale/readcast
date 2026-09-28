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

## Run locally

Install the R packages used by the app:

```sh
Rscript -e 'install.packages(c("callr", "commonmark", "digest", "fs", "htmltools", "httr2", "purrr", "readr", "shiny", "stringi", "stringr", "xml2", "yaml"))'
```

Install `ffmpeg` separately, set `OPENROUTER_API_KEY` and `CLIPPINGS_DIR`, then launch from the project root:

```sh
Rscript app.R
```

`NARRATION_CACHE_DIR` can override the default MP3 cache directory. The app currently uses local files only; podcast publishing is being designed.
