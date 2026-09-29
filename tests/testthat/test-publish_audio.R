source(testthat::test_path("..", "..", "R", "setup.R"), local = TRUE)
source(testthat::test_path("..", "..", "R", "publish_audio.R"), local = TRUE)

testthat::test_that("hosted audio reads its origin from YAML and preserves the first address", {
  config <- tempfile("readcast-config-")
  save_readcast_setup_settings(list(worker_url = "http://audio.example.workers.dev"), config)
  testthat::expect_error(readcast_worker_url(config), "HTTPS workers.dev")
  save_readcast_setup_settings(list(worker_url = "https://audio.example.workers.dev"), config)
  testthat::expect_match(readcast_worker_url(config)$url, "^https://audio\\.example\\.workers\\.dev$")
  save_readcast_setup_settings(list(hosted_worker_url = "https://audio.example.workers.dev"), config)
  save_readcast_setup_settings(list(worker_url = "https://renamed.example.workers.dev"), config)
  testthat::expect_error(readcast_worker_url(config), "Restore that Worker address")
})

testthat::test_that("legacy Worker origin locks are read for migration", {
  config <- tempfile("readcast-config-")
  save_readcast_setup_settings(list(worker_url = "https://audio.example.workers.dev"), config)
  writeLines("https://audio.example.workers.dev", file.path(config, "worker-url"))
  hosting <- readcast_worker_url(config)
  testthat::expect_identical(hosting$url, "https://audio.example.workers.dev")
  testthat::expect_true(file.exists(hosting$legacy_lock_path))
})

testthat::test_that("uploads report missing credentials before network access", {
  original <- Sys.getenv(c("R2_ACCESS_KEY_ID", "R2_SECRET_ACCESS_KEY"), unset = NA_character_)
  on.exit({
    names(original) <- c("R2_ACCESS_KEY_ID", "R2_SECRET_ACCESS_KEY")
    for (name in names(original)) if (is.na(original[[name]])) Sys.unsetenv(name) else do.call(Sys.setenv, setNames(list(original[[name]]), name))
  })
  Sys.unsetenv(c("R2_ACCESS_KEY_ID", "R2_SECRET_ACCESS_KEY"))
  config <- tempfile("readcast-config-")
  save_readcast_setup_settings(list(worker_url = "https://audio.example.workers.dev"), config)
  testthat::expect_error(upload_cached_audio("missing.mp3", config_dir = config), "R2_ACCOUNT_ID")
})
