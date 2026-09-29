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

Readcast saves non-secret settings in `~/.config/readcast/config.yml`. The app reports an actionable error when the configured directory is missing or invalid.

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

All non-secret app settings belong in `~/.config/readcast/config.yml`. This includes `clippings_dir`, `github_pages_url`, `podcast_title`, `podcast_description`, `podcast_language`, `podcast_explicit`, `r2_account_id`, `r2_bucket`, `worker_url`, `narration_cache_dir`, and `data_dir`. Readcast manages `hosted_worker_url` in that file to preserve the origin used for published audio; leave it unchanged. Credentials such as `OPENROUTER_API_KEY`, `GITHUB_TOKEN`, `R2_ACCESS_KEY_ID`, and `R2_SECRET_ACCESS_KEY` must be supplied as environment variables, never in the repository or Readcast's personal configuration. A secret manager may provide them by injecting environment variables into the Readcast process. There are no environment overrides for non-secret settings.

Edit `~/.config/readcast/config.yml` to set app preferences and non-secret service details. The app's **Check connections** panel provides independent, safe-to-rerun checks: Clippings counts local Markdown files, OpenRouter checks its models endpoint, R2 lists one bucket page and probes the Worker with a missing object, GitHub repository access makes a read-only repository API request using `GITHUB_TOKEN`, and GitHub Pages separately requests the public site URL. The GitHub token needs repository contents write access for publication and is never displayed or saved. None of the checks creates resources, generates narration, or publishes audio. The app remains open when setup is incomplete; local reading, narration and playback do not depend on publishing services.

For example, a configuration can contain:

```yaml
clippings_dir: ~/Documents/Clippings
github_pages_url: https://account.github.io/podcast/
podcast_title: Readcast
podcast_description: A personal collection of narrated articles.
podcast_language: en
podcast_explicit: false
r2_account_id: your-cloudflare-account-id
r2_bucket: readcast-audio
worker_url: https://readcast.account.workers.dev
narration_cache_dir: ~/.cache/readcast/narrations
data_dir: ~/.local/share/readcast
```

## Set up publishing with the CLI

Publishing is optional. These commands create a dedicated public GitHub Pages repository and a private Cloudflare R2 bucket served by the bundled Worker. Run them from this checkout. You need `gh`, Node.js/npm, `curl`, and `jq`. Before running Wrangler, activate R2 for your account in the [Cloudflare dashboard](https://developers.cloudflare.com/r2/get-started/): **Storage & databases → R2 → Overview → complete checkout**. Cloudflare does not document a Wrangler command for the initial R2 subscription; subsequent bucket and Worker setup uses the CLI. Wrangler's login opens a browser. The R2 API token command below also needs a one-time bootstrap token from the [Cloudflare dashboard](https://developers.cloudflare.com/fundamentals/api/how-to/create-via-api/) with **Account API Tokens Write** permission. Keep all tokens out of this repository and `config.yml`.

### Cloudflare: bucket, Worker, and R2 credentials

Authenticate Wrangler, create the Standard-storage bucket, and deploy the Worker from `worker/`. Its existing `wrangler.jsonc` binds `AUDIO_BUCKET` to `readcast-audio`. Record the account ID shown by `whoami` and the permanent `https://…workers.dev` URL printed by `deploy`; do not change that Worker address after publishing audio. The bucket stays private: there is no need to enable an `r2.dev` public URL. See the [Wrangler login](https://developers.cloudflare.com/workers/wrangler/commands/general/), [R2 bucket](https://developers.cloudflare.com/r2/reference/wrangler-commands/), and [Worker deployment](https://developers.cloudflare.com/workers/get-started/guide/) documentation.

```sh
cd worker
npx wrangler login
npx wrangler whoami
npx wrangler r2 bucket create readcast-audio
npx wrangler deploy
cd ..
```

Readcast uploads through the R2 S3 API, so it also needs an access key ID and secret access key with bucket-scoped **Object Read & Write** permission. Wrangler login alone does not supply these to Readcast. The following CLI steps use Cloudflare's [account token API](https://developers.cloudflare.com/fundamentals/api/how-to/create-via-api/) and [R2 token policy](https://developers.cloudflare.com/r2/api/tokens/). Enter your account ID from `wrangler whoami`; enter the bootstrap token at the silent prompt. The new token's ID becomes `R2_ACCESS_KEY_ID`, and the SHA-256 digest of its one-time value becomes `R2_SECRET_ACCESS_KEY`. The commands assume the bucket's default jurisdiction, which matches Readcast's S3 endpoint.

```sh
export CLOUDFLARE_ACCOUNT_ID="your-account-id"
printf 'Cloudflare bootstrap API token: '
read -rs CLOUDFLARE_API_TOKEN
printf '\n'
export CLOUDFLARE_API_TOKEN

R2_PERMISSION_ID="$(curl -fsS \
  -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
  "https://api.cloudflare.com/client/v4/accounts/$CLOUDFLARE_ACCOUNT_ID/tokens/permission_groups" \
  | jq -er '.result[] | select(.name == "Workers R2 Storage Bucket Item Write") | .id')"
R2_POLICY="$(jq -n --arg account "$CLOUDFLARE_ACCOUNT_ID" --arg permission "$R2_PERMISSION_ID" \
  '{name:"readcast-r2",policies:[{effect:"allow",resources:{("com.cloudflare.edge.r2.bucket." + $account + "_default_readcast-audio"):"*"},permission_groups:[{id:$permission}]}]}')"
R2_TOKEN_RESPONSE="$(curl -fsS \
  -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
  -H 'Content-Type: application/json' \
  --data "$R2_POLICY" \
  "https://api.cloudflare.com/client/v4/accounts/$CLOUDFLARE_ACCOUNT_ID/tokens")"
R2_TOKEN_VALUE="$(printf '%s' "$R2_TOKEN_RESPONSE" | jq -er '.result.value')"
export R2_ACCESS_KEY_ID="$(printf '%s' "$R2_TOKEN_RESPONSE" | jq -er '.result.id')"
export R2_SECRET_ACCESS_KEY="$(printf '%s' "$R2_TOKEN_VALUE" | shasum -a 256 | awk '{print $1}')"
unset CLOUDFLARE_API_TOKEN R2_PERMISSION_ID R2_POLICY R2_TOKEN_RESPONSE R2_TOKEN_VALUE
```

The R2 keys must be present in the environment each time you launch Readcast. Use a shell secret manager to inject them if you need them across sessions. The token value is only returned when created; store the resulting credentials securely.

### GitHub: repository and Pages site

Log in with GitHub CLI, create a **separate public repository** for the podcast site, add a minimal index page, and configure Pages to publish from the root of the repository's default branch. Readcast writes `feed.xml` and the approved cover to that branch through the GitHub Contents API. The token used by Readcast therefore needs repository **Contents: write** permission; the CLI's usual `repo` scope also works. Pages creation requires permission to manage Pages settings. See the [repository creation](https://cli.github.com/manual/gh_repo_create), [Pages API](https://docs.github.com/en/rest/pages/pages), and [Contents API](https://docs.github.com/en/rest/repos/contents) documentation.

```sh
gh auth login --scopes repo
GH_OWNER="$(gh api user --jq .login)"
PODCAST_REPO=readcast-podcast
gh repo create "$GH_OWNER/$PODCAST_REPO" --public --add-readme
DEFAULT_BRANCH="$(gh api "repos/$GH_OWNER/$PODCAST_REPO" --jq .default_branch)"
INDEX_CONTENT="$(printf '%s' '<!doctype html><title>Readcast podcast</title><h1>Readcast podcast</h1>' | base64 | tr -d '\n')"
gh api -X PUT "repos/$GH_OWNER/$PODCAST_REPO/contents/index.html" \
  -f message='Initialise podcast site' -f "content=$INDEX_CONTENT"
gh api -X POST "repos/$GH_OWNER/$PODCAST_REPO/pages" \
  -f build_type=legacy -f "source[branch]=$DEFAULT_BRANCH" -f 'source[path]=/'
gh api "repos/$GH_OWNER/$PODCAST_REPO/pages" --jq .html_url
export GITHUB_TOKEN="$(gh auth token)"
```

Copy the Pages `html_url`, Cloudflare account ID, and deployed Worker origin into `github_pages_url`, `r2_account_id`, and `worker_url` in `~/.config/readcast/config.yml`; set `r2_bucket: readcast-audio`. `GITHUB_TOKEN`, `R2_ACCESS_KEY_ID`, and `R2_SECRET_ACCESS_KEY` belong only in the process environment. Start Readcast from that environment and use **Check connections**. The Pages URL and Worker URL are separate addresses. The app's **Upload cached audio to R2** action uploads only the selected cache file; after its first successful upload, Readcast records the Worker origin and rejects changes to it.

To publish an episode, select an existing cached narration, approve a show cover, and confirm the clipping's eligibility the first time you publish it. Readcast uploads the MP3 to R2, the approved cover and RSS 2.0 feed to the Pages repository, then checks that the public resources respond before showing the feed URL. In Apple Podcasts, add the show by URL and follow it. Set show title, description, language, and explicit-content status in `config.yml`; an episode description is included only when the clipping already has description metadata. **Review aged audio cleanup** asks for confirmation, fetches the current live feed, and deletes only replaced audio that has been retained for at least 30 days and is no longer referenced; it needs GitHub and R2 credentials.

The Podcast cover controls let you edit a starting prompt, generate and inspect a candidate with OpenRouter's `openai/gpt-image-2`, then explicitly approve it. Candidates and approved artwork are saved separately under the configured `data_dir` (default `~/.local/share/readcast`). Generation requires `OPENROUTER_API_KEY`. The approved PNG is checked for a square 1400–3000 px size and an opaque background.

When changing the app, edit the org files and regenerate their single R targets from the project root:

```sh
emacs -Q --batch --eval '(progn (require (quote org)) (mapc (lambda (file) (org-babel-tangle-file file)) (directory-files "org" t "[.]org$")))'
```
