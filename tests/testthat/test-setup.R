source(testthat::test_path("..", "..", "R", "setup.R"), local = TRUE)

testthat::test_that("personal setup persists only allowed non-secret settings", {
  config <- tempfile("readcast-config-")
  settings <- list(clippings_dir = "/tmp/clippings", github_pages_url = "https://reader.github.io/podcast/",
                   r2_account_id = "account-id", r2_bucket = "readcast-audio", worker_url = "https://audio.account.workers.dev")
  save_readcast_setup_settings(settings, config)
  testthat::expect_identical(readcast_setup_settings(config), settings)
  stored <- paste(readLines(file.path(config, "settings"), warn = FALSE), collapse = "\n")
  testthat::expect_false(grepl("SECRET_ACCESS_KEY|access-secret", stored))
  testthat::expect_error(save_readcast_setup_settings(list(secret_access_key = "access-secret"), config), "Only non-secret")
  testthat::expect_error(save_readcast_setup_settings(list(worker_url = "https://user:secret@audio.account.workers.dev"), config), "Do not include credentials")
  testthat::expect_identical(setup_url_for_display("https://user:secret@audio.account.workers.dev"), "")
  testthat::expect_identical(setup_url_for_display("https://audio.account.workers.dev"), "https://audio.account.workers.dev")
})

testthat::test_that("Clippings check reports a useful local result", {
  directory <- tempfile("clippings-")
  dir.create(directory)
  testthat::expect_error(check_readcast_clippings(directory), "contains no Markdown")
  writeLines("# Article", file.path(directory, "article.md"))
  testthat::expect_identical(check_readcast_clippings(directory), list(ok = TRUE, message = "Connected: found 1 Markdown clipping."))
  testthat::expect_error(check_readcast_clippings(file.path(directory, "missing")), "Choose an existing")
})

testthat::test_that("connection checks fail before network access when configuration is absent", {
  testthat::expect_error(check_readcast_openrouter(""), "Set OPENROUTER_API_KEY")
  testthat::expect_error(check_readcast_hosting("", "", "", "", ""), "R2_ACCOUNT_ID")
  testthat::expect_error(check_readcast_github_pages(""), "Enter the HTTPS URL")
  result <- setup_check_result(function() check_readcast_openrouter(""))
  testthat::expect_false(result$ok)
  testthat::expect_match(result$message, "OPENROUTER_API_KEY")
})

testthat::test_that("connection check URLs are restricted to expected public origins", {
  testthat::expect_error(check_readcast_github_pages("http://reader.github.io"), "Use HTTPS")
  testthat::expect_error(check_readcast_github_pages("https://example.com"), "ending in github.io")
  testthat::expect_error(check_readcast_github_pages("https://reader.github.io/?token=secret"), "without credentials")
  testthat::expect_error(check_readcast_hosting("account", "bucket", "key", "secret", "http://audio.account.workers.dev"), "HTTPS workers.dev")
})
