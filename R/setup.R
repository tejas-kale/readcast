validate_readcast_setting_url <- function(name, value) {
  value <- trimws(value %||% "")
  if (!nzchar(value)) return(invisible(TRUE))
  parsed <- tryCatch(httr2::url_parse(value), error = function(error) {
    stop("Readcast setting '", name, "' must be a valid URL.", call. = FALSE)
  })
  if (nzchar(parsed$username %||% "") || nzchar(parsed$password %||% "") || length(parsed$query) || nzchar(parsed$fragment %||% "")) {
    stop("Do not include credentials, query parameters or fragments in Readcast setting '", name, "'.", call. = FALSE)
  }
  invisible(TRUE)
}

readcast_setup_settings <- function(config_dir = path.expand("~/.config/readcast")) {
  defaults <- list(clippings_dir = "", github_pages_url = "", podcast_title = "Readcast",
    podcast_description = "A personal collection of narrated articles.", podcast_language = "en",
    podcast_explicit = "false", r2_account_id = "", r2_bucket = "", worker_url = "", hosted_worker_url = "",
    narration_cache_dir = "~/.cache/readcast/narrations", data_dir = "~/.local/share/readcast")
  path <- file.path(config_dir, "config.yml")
  legacy_paths <- file.path(config_dir, c("settings", "clippings-dir"))
  migrating <- !file.exists(path) && any(file.exists(legacy_paths))
  if (file.exists(path)) {
    stored <- tryCatch(yaml::read_yaml(path), error = function(error) {
      stop("Readcast config.yml must be valid YAML with unique mapping keys: ", conditionMessage(error), call. = FALSE)
    })
  } else if (migrating) {
    stored <- list()
    if (file.exists(legacy_paths[[1L]])) {
      dcf <- tryCatch(read.dcf(legacy_paths[[1L]]), error = function(error) {
        stop("Legacy Readcast settings could not be read. Fix or remove ~/.config/readcast/settings.", call. = FALSE)
      })
      if (nrow(dcf)) stored <- as.list(dcf[1L, , drop = TRUE])
    }
    if (file.exists(legacy_paths[[2L]])) {
      clipping <- readLines(legacy_paths[[2L]], warn = FALSE, n = 1L)
      stored$clippings_dir <- if (length(clipping)) clipping[[1L]] else ""
    }
  } else {
    stored <- list()
  }
  if (!is.list(stored)) stop("Readcast config.yml must contain a YAML mapping.", call. = FALSE)
  stored_names <- names(stored)
  if (length(stored) && (is.null(stored_names) || length(stored_names) != length(stored) || anyNA(stored_names) || any(!nzchar(trimws(stored_names))) || anyDuplicated(stored_names))) {
    stop("Readcast config.yml must contain a mapping with unique, non-empty setting names.", call. = FALSE)
  }
  allowed <- names(defaults)
  credential_names <- names(stored)[grepl("secret|token|password|credential|api[_-]?key|access[_-]?key", names(stored), ignore.case = TRUE)]
  if (length(credential_names)) stop("Credentials must be supplied through environment variables, not Readcast configuration.", call. = FALSE)
  if (any(!names(stored) %in% allowed)) stop("config.yml contains an unsupported setting.", call. = FALSE)
  for (name in names(stored)) {
    value <- stored[[name]]
    if (is.null(value) || !is.atomic(value) || length(value) != 1L || is.na(value)) {
      stop("Readcast config.yml setting '", name, "' must be a single scalar value.", call. = FALSE)
    }
    defaults[[name]] <- as.character(value)
  }
  for (name in c("github_pages_url", "worker_url", "hosted_worker_url")) validate_readcast_setting_url(name, defaults[[name]])
  if (migrating) {
    if (!dir.create(config_dir, recursive = TRUE, showWarnings = FALSE) && !dir.exists(config_dir)) stop("Cannot create Readcast configuration directory.", call. = FALSE)
    yaml::write_yaml(defaults, path)
    unlink(legacy_paths[file.exists(legacy_paths)])
  }
  defaults
}

setup_url_for_display <- function(value) {
  value <- trimws(value %||% "")
  if (!nzchar(value)) return("")
  parsed <- tryCatch(httr2::url_parse(value), error = function(error) NULL)
  if (is.null(parsed) || nzchar(parsed$username %||% "") || nzchar(parsed$password %||% "") || length(parsed$query) || nzchar(parsed$fragment %||% "")) "" else value
}

save_readcast_setup_settings <- function(settings, config_dir = path.expand("~/.config/readcast")) {
  allowed <- c("clippings_dir", "github_pages_url", "podcast_title", "podcast_description", "podcast_language", "podcast_explicit", "r2_account_id", "r2_bucket", "worker_url", "hosted_worker_url", "narration_cache_dir", "data_dir")
  if (any(!names(settings) %in% allowed)) stop("Only non-secret Readcast settings can be saved.", call. = FALSE)
  if (!dir.create(config_dir, recursive = TRUE, showWarnings = FALSE) && !dir.exists(config_dir)) stop("Cannot create Readcast configuration directory.", call. = FALSE)
  settings <- as.list(settings[allowed[allowed %in% names(settings)]])
  values <- lapply(names(settings), function(name) {
    value <- settings[[name]]
    if (is.null(value) || !is.atomic(value) || length(value) != 1L || is.na(value)) {
      stop("Readcast setting '", name, "' must be a single scalar value.", call. = FALSE)
    }
    trimws(as.character(value))
  })
  names(values) <- names(settings)
  for (name in c("github_pages_url", "worker_url", "hosted_worker_url")) validate_readcast_setting_url(name, values[[name]] %||% "")
  existing <- readcast_setup_settings(config_dir)
  for (name in names(values)) existing[[name]] <- values[[name]]
  yaml::write_yaml(existing, file.path(config_dir, "config.yml"))
  invisible(settings)
}

`%||%` <- function(value, fallback) if (is.null(value) || length(value) == 0L) fallback else value

setup_check_result <- function(check) {
  tryCatch(check(), error = function(error) list(ok = FALSE, message = conditionMessage(error)))
}

check_readcast_clippings <- function(directory) {
  directory <- path.expand(trimws(directory %||% ""))
  if (!nzchar(directory) || !dir.exists(directory)) stop("Choose an existing Clippings directory.", call. = FALSE)
  count <- length(list.files(directory, pattern = "\\.md$", recursive = TRUE, ignore.case = TRUE))
  if (!count) stop("The folder is reachable, but contains no Markdown clippings yet. Check the exported Clippings folder.", call. = FALSE)
  list(ok = TRUE, message = sprintf("Connected: found %s Markdown clipping%s.", count, if (count == 1L) "" else "s"))
}

check_readcast_openrouter <- function(api_key = Sys.getenv("OPENROUTER_API_KEY", unset = ""), perform = httr2::req_perform) {
  if (!nzchar(trimws(api_key))) stop("Set OPENROUTER_API_KEY in your shell environment, then relaunch Readcast.", call. = FALSE)
  response <- httr2::request("https://openrouter.ai/api/v1/models") |>
    httr2::req_headers(Authorization = paste("Bearer", api_key)) |>
    httr2::req_timeout(15) |>
    httr2::req_error(is_error = function(response) FALSE) |>
    perform()
  status <- httr2::resp_status(response)
  if (status < 200L || status >= 300L) stop(if (status == 401L || status == 403L) "OpenRouter rejected the key. Check that it is valid and enabled." else paste("OpenRouter returned HTTP", status, "while checking the connection."), call. = FALSE)
  list(ok = TRUE, message = "Connected to OpenRouter. No narration was generated.")
}

# Keep credential-bearing R2 requests inside a local libcurl handle. httr2
# retains performed requests in last_request(), including their curl options.
readcast_r2_fetch <- function(url, method, access_key, secret_key, timeout = 15) {
  handle <- curl::new_handle(
    aws_sigv4 = "aws:amz:auto:s3",
    userpwd = paste0(access_key, ":", secret_key),
    customrequest = method,
    timeout = timeout
  )
  result <- curl::curl_fetch_memory(url, handle = handle)
  httr2::response(status_code = result$status_code, url = url, method = method)
}

check_readcast_hosting <- function(account_id, bucket, access_key, secret_key, worker_url, perform = NULL) {
  missing_settings <- c(if (!nzchar(trimws(account_id))) "r2_account_id", if (!nzchar(trimws(bucket))) "r2_bucket", if (!nzchar(trimws(worker_url))) "worker_url")
  missing_credentials <- c(if (!nzchar(trimws(access_key))) "R2_ACCESS_KEY_ID", if (!nzchar(trimws(secret_key))) "R2_SECRET_ACCESS_KEY")
  if (length(missing_settings) || length(missing_credentials)) {
    guidance <- c(if (length(missing_settings)) paste0(paste(missing_settings, collapse = ", "), " in ~/.config/readcast/config.yml"),
                  if (length(missing_credentials)) paste0(paste(missing_credentials, collapse = ", "), " in your shell environment"))
    stop("Set ", paste(guidance, collapse = " and "), ", then relaunch Readcast.", call. = FALSE)
  }
  parsed <- httr2::url_parse(worker_url)
  if (!identical(parsed$scheme, "https") || !grepl("^[a-z0-9-]+\\.[a-z0-9-]+\\.workers\\.dev$", parsed$hostname)) stop("worker_url must be the permanent HTTPS workers.dev origin, without a path.", call. = FALSE)
  if (nzchar(parsed$username %||% "") || nzchar(parsed$password %||% "") || length(parsed$query) || nzchar(parsed$fragment %||% "") || (nzchar(parsed$path %||% "") && parsed$path != "/")) stop("worker_url must not include credentials, query parameters, fragments or a path.", call. = FALSE)
  endpoint <- sprintf("https://%s.r2.cloudflarestorage.com/%s", account_id, utils::URLencode(bucket, reserved = TRUE))
  r2_url <- paste0(endpoint, "?list-type=2&max-keys=1")
  r2 <- if (is.null(perform)) {
    readcast_r2_fetch(r2_url, "GET", access_key, secret_key)
  } else {
    request <- httr2::request(endpoint) |>
      httr2::req_url_query(`list-type` = "2", `max-keys` = "1")
    perform(request)
  }
  r2_status <- httr2::resp_status(r2)
  if (r2_status < 200L || r2_status >= 300L) stop(paste("R2 could not list this bucket (HTTP", r2_status, "). Check the account, bucket and token's object read permission."), call. = FALSE)
  probe <- paste0(sub("/$", "", worker_url), "/audio/readcast-setup-probe-does-not-exist.mp3")
  worker_perform <- perform %||% httr2::req_perform
  worker <- httr2::request(probe) |>
    httr2::req_method("HEAD") |>
    httr2::req_timeout(15) |>
    httr2::req_error(is_error = function(response) FALSE) |>
    worker_perform()
  worker_status <- httr2::resp_status(worker)
  if (worker_status != 404L) stop(if (worker_status == 503L) "The Worker is reachable, but it could not read its R2 bucket. Check the AUDIO_BUCKET binding and deploy the Worker." else paste("The Worker probe returned HTTP", worker_status, ". Check the workers.dev URL and deploy the audio Worker."), call. = FALSE)
  list(ok = TRUE, message = "Connected to the R2 bucket and Worker. No objects were changed.")
}

github_repository_from_pages_url <- function(url) {
  url <- trimws(url %||% "")
  if (!nzchar(url)) stop("Enter the HTTPS URL of your dedicated public GitHub Pages repository.", call. = FALSE)
  parsed <- httr2::url_parse(url)
  if (!identical(parsed$scheme, "https")) stop("Use HTTPS for the GitHub Pages site URL.", call. = FALSE)
  if (nzchar(parsed$username %||% "") || nzchar(parsed$password %||% "") || length(parsed$query) || nzchar(parsed$fragment %||% "")) stop("Use the public GitHub Pages URL without credentials, query parameters or fragments.", call. = FALSE)
  host_match <- regexec("^([a-z0-9-]+)\\.github\\.io$", parsed$hostname, ignore.case = TRUE)
  owner <- regmatches(parsed$hostname, host_match)[[1L]]
  if (length(owner) != 2L) stop("Use a GitHub Pages URL in the form https://<account>.github.io/<repository>/.", call. = FALSE)
  owner <- owner[[2L]]
  path <- sub("^/", "", parsed$path %||% "")
  path <- sub("/$", "", path)
  repository <- if (nzchar(path)) strsplit(path, "/", fixed = TRUE)[[1L]][[1L]] else paste0(owner, ".github.io")
  if (!grepl("^[A-Za-z0-9_.-]+$", repository)) stop("The GitHub Pages URL must include a valid repository name.", call. = FALSE)
  list(owner = owner, repository = repository)
}

check_readcast_github_access <- function(url, token = Sys.getenv("GITHUB_TOKEN", unset = ""), perform = httr2::req_perform) {
  repository <- github_repository_from_pages_url(url)
  if (!nzchar(trimws(token))) stop("Set GITHUB_TOKEN in your shell environment with read access to the dedicated Pages repository, then relaunch Readcast.", call. = FALSE)
  endpoint <- sprintf("https://api.github.com/repos/%s/%s", utils::URLencode(repository$owner, reserved = TRUE), utils::URLencode(repository$repository, reserved = TRUE))
  response <- httr2::request(endpoint) |>
    httr2::req_headers(Authorization = paste("Bearer", token), Accept = "application/vnd.github+json", `X-GitHub-Api-Version` = "2022-11-28", `User-Agent` = "Readcast setup check") |>
    httr2::req_timeout(15) |>
    httr2::req_error(is_error = function(response) FALSE) |>
    perform()
  status <- httr2::resp_status(response)
  if (status == 401L || status == 403L) stop("GitHub rejected GITHUB_TOKEN. Check that the token is valid and has repository read access.", call. = FALSE)
  if (status == 404L) stop("GitHub could not find this repository or GITHUB_TOKEN cannot read it. Check the Pages URL and grant the token repository read access.", call. = FALSE)
  if (status < 200L || status >= 300L) stop(paste("GitHub repository access returned HTTP", status, ". Check the token's repository read permission."), call. = FALSE)
  list(ok = TRUE, message = paste0("GITHUB_TOKEN can read ", repository$owner, "/", repository$repository, ". No repository settings were changed."))
}

check_readcast_github_pages <- function(url, perform = httr2::req_perform) {
  url <- trimws(url %||% "")
  if (!nzchar(url)) stop("Enter the HTTPS URL of your dedicated public GitHub Pages repository.", call. = FALSE)
  parsed <- httr2::url_parse(url)
  if (!identical(parsed$scheme, "https")) stop("Use HTTPS for the GitHub Pages site URL.", call. = FALSE)
  if (!grepl("(^|\\.)github\\.io$", parsed$hostname)) stop("Use the HTTPS URL ending in github.io for the dedicated public Pages repository.", call. = FALSE)
  if (nzchar(parsed$username %||% "") || nzchar(parsed$password %||% "") || length(parsed$query) || nzchar(parsed$fragment %||% "")) stop("Use the public GitHub Pages URL without credentials, query parameters or fragments.", call. = FALSE)
  response <- httr2::request(url) |>
    httr2::req_timeout(15) |>
    httr2::req_error(is_error = function(response) FALSE) |>
    perform()
  status <- httr2::resp_status(response)
  if (status < 200L || status >= 300L) stop(paste("GitHub Pages returned HTTP", status, ". Enable Pages for the public repository and check the site URL."), call. = FALSE)
  list(ok = TRUE, message = "GitHub Pages site is reachable. No content was published.")
}
