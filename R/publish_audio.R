readcast_worker_url <- function(config_dir = path.expand("~/.config/readcast")) {
  settings <- if (exists("readcast_setup_settings", mode = "function")) readcast_setup_settings(config_dir) else list(worker_url = "")
  worker_url <- trimws(Sys.getenv("READCAST_WORKER_URL", unset = settings$worker_url))
  if (!nzchar(worker_url)) stop("Set READCAST_WORKER_URL to the permanent https://<worker>.<account>.workers.dev address.", call. = FALSE)
  parsed <- httr2::url_parse(worker_url)
  if (!identical(parsed$scheme, "https") || !grepl("^[a-z0-9-]+\\.[a-z0-9-]+\\.workers\\.dev$", parsed$hostname)) {
    stop("READCAST_WORKER_URL must be an HTTPS workers.dev hostname, without a path.", call. = FALSE)
  }
  if (!is.null(parsed$path) && nzchar(parsed$path) && parsed$path != "/") stop("READCAST_WORKER_URL must contain only the Worker origin.", call. = FALSE)
  dir.create(config_dir, recursive = TRUE, showWarnings = FALSE)
  lock_path <- file.path(config_dir, "worker-url")
  if (file.exists(lock_path)) {
    locked <- trimws(readLines(lock_path, warn = FALSE, n = 1L))
    if (!identical(sub("/$", "", worker_url), sub("/$", "", locked))) {
      stop("READCAST_WORKER_URL differs from the address already used for hosted audio (", locked, "). Restore that Worker address; published audio URLs depend on it.", call. = FALSE)
    }
  }
  list(url = sub("/$", "", worker_url), lock_path = lock_path)
}

upload_cached_audio <- function(mp3_path, worker_url = NULL, config_dir = path.expand("~/.config/readcast"), object_key = NULL) {
  if (is.null(worker_url)) hosting <- readcast_worker_url(config_dir) else {
    old <- Sys.getenv("READCAST_WORKER_URL", unset = "")
    on.exit(Sys.setenv(READCAST_WORKER_URL = old), add = TRUE)
    Sys.setenv(READCAST_WORKER_URL = worker_url)
    hosting <- readcast_worker_url(config_dir)
  }
  settings <- if (exists("readcast_setup_settings", mode = "function")) readcast_setup_settings(config_dir) else list(r2_account_id = "", r2_bucket = "")
  account_id <- Sys.getenv("R2_ACCOUNT_ID", unset = settings$r2_account_id)
  bucket <- Sys.getenv("R2_BUCKET", unset = settings$r2_bucket)
  access_key <- Sys.getenv("R2_ACCESS_KEY_ID", unset = "")
  secret_key <- Sys.getenv("R2_SECRET_ACCESS_KEY", unset = "")
  missing <- c(if (!nzchar(account_id)) "R2_ACCOUNT_ID", if (!nzchar(bucket)) "R2_BUCKET",
               if (!nzchar(access_key)) "R2_ACCESS_KEY_ID", if (!nzchar(secret_key)) "R2_SECRET_ACCESS_KEY")
  if (length(missing)) stop("Set the missing R2 environment variable(s): ", paste(missing, collapse = ", "), ". Create an R2 API token with Object Read & Write access.", call. = FALSE)
  if (length(mp3_path) != 1L || !file.exists(mp3_path) || dir.exists(mp3_path)) stop("Select an existing cached MP3 before uploading.", call. = FALSE)
  if (file.info(mp3_path)$size <= 0) stop("The selected cached MP3 is empty.", call. = FALSE)
  digest <- digest::digest(file = mp3_path, algo = "sha256", serialize = FALSE)
  if (is.null(object_key)) object_key <- paste0("audio/", digest, ".mp3")
  if (length(object_key) != 1L || is.na(object_key) || !grepl("^audio/[A-Za-z0-9_-]+[.]mp3$", object_key)) stop("Audio object key must be a safe audio/*.mp3 key.", call. = FALSE)
  key <- object_key
  endpoint <- sprintf("https://%s.r2.cloudflarestorage.com/%s/%s", account_id, utils::URLencode(bucket, reserved = TRUE), key)
  result <- tryCatch({
    request <- httr2::request(endpoint) |>
      httr2::req_method("PUT") |>
      httr2::req_headers(`Content-Type` = "audio/mpeg", `x-amz-storage-class` = "STANDARD") |>
      httr2::req_body_file(mp3_path) |>
      httr2::req_auth_aws_v4(access_key, secret_key, aws_service = "s3", aws_region = "auto") |>
      httr2::req_timeout(300) |>
      httr2::req_error(is_error = function(resp) FALSE) |>
      httr2::req_perform()
    if (httr2::resp_status(request) < 200L || httr2::resp_status(request) >= 300L) {
      stop("R2 rejected the upload (HTTP ", httr2::resp_status(request), "). Check the account ID, bucket name, token permissions and R2 subscription.", call. = FALSE)
    }
    invisible(request)
  }, error = function(error) {
    if (grepl("R2 rejected", conditionMessage(error), fixed = TRUE)) stop(error)
    stop("Could not upload audio to R2: ", conditionMessage(error), ". Check your network and R2 credentials, then retry.", call. = FALSE)
  })
  writeLines(hosting$url, hosting$lock_path, useBytes = TRUE)
  list(url = paste0(hosting$url, "/", key), key = key, size = file.info(mp3_path)$size)
}
