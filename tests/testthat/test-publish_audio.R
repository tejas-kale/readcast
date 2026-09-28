source(testthat::test_path("..", "..", "R", "publish_audio.R"), local = TRUE)

testthat::test_that("hosted audio requires a workers.dev HTTPS origin", {
  original <- Sys.getenv("READCAST_WORKER_URL", unset = NA_character_)
  on.exit(if (is.na(original)) Sys.unsetenv("READCAST_WORKER_URL") else Sys.setenv(READCAST_WORKER_URL = original))
  Sys.setenv(READCAST_WORKER_URL = "http://audio.example.workers.dev")
  testthat::expect_error(readcast_worker_url(tempfile()), "HTTPS workers.dev")
  Sys.setenv(READCAST_WORKER_URL = "https://audio.example.workers.dev")
  testthat::expect_match(readcast_worker_url(tempfile())$url, "^https://audio\\.example\\.workers\\.dev$")
})

testthat::test_that("the first hosted audio origin remains locked", {
  original <- Sys.getenv("READCAST_WORKER_URL", unset = NA_character_)
  on.exit(if (is.na(original)) Sys.unsetenv("READCAST_WORKER_URL") else Sys.setenv(READCAST_WORKER_URL = original))
  config <- tempfile()
  Sys.setenv(READCAST_WORKER_URL = "https://audio.example.workers.dev")
  hosting <- readcast_worker_url(config)
  writeLines(hosting$url, hosting$lock_path)
  Sys.setenv(READCAST_WORKER_URL = "https://renamed.example.workers.dev")
  testthat::expect_error(readcast_worker_url(config), "Restore that Worker address")
})

testthat::test_that("uploads report missing credentials before network access", {
  original <- Sys.getenv(c("READCAST_WORKER_URL", "R2_ACCOUNT_ID", "R2_BUCKET", "R2_ACCESS_KEY_ID", "R2_SECRET_ACCESS_KEY"), unset = NA_character_)
  on.exit({
    names(original) <- c("READCAST_WORKER_URL", "R2_ACCOUNT_ID", "R2_BUCKET", "R2_ACCESS_KEY_ID", "R2_SECRET_ACCESS_KEY")
    for (name in names(original)) if (is.na(original[[name]])) Sys.unsetenv(name) else do.call(Sys.setenv, setNames(list(original[[name]]), name))
  })
  Sys.unsetenv(c("R2_ACCOUNT_ID", "R2_BUCKET", "R2_ACCESS_KEY_ID", "R2_SECRET_ACCESS_KEY"))
  Sys.setenv(READCAST_WORKER_URL = "https://audio.example.workers.dev")
  testthat::expect_error(upload_cached_audio("missing.mp3", config_dir = tempfile()), "R2_ACCOUNT_ID")
})
