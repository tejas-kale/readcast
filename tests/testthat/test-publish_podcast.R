source(testthat::test_path("..", "..", "R", "setup.R"), local = TRUE)
source(testthat::test_path("..", "..", "R", "podcast_cover.R"), local = TRUE)
source(testthat::test_path("..", "..", "R", "publish_audio.R"), local = TRUE)
source(testthat::test_path("..", "..", "R", "publish_podcast.R"), local = TRUE)

testthat::test_that("eligibility and episode identity persist per clipping", {
  directory <- tempfile("episode-test-")
  dir.create(directory)
  on.exit(unlink(directory, recursive = TRUE), add = TRUE)
  clipping <- file.path(directory, "article.md")
  writeLines("# Article", clipping)
  episode <- confirm_podcast_eligibility(clipping, TRUE, "Article (Model - Voice)", "Desc", "model/name", "voice", directory)
  testthat::expect_identical(episode$eligible, "true")
  testthat::expect_identical(read_podcast_episode(clipping, "model/name", "voice", directory)$guid, episode$guid)
  testthat::expect_identical(confirm_podcast_eligibility(clipping, FALSE, "Changed", "", "model/name", "voice", directory)$guid, episode$guid)
  different_voice <- confirm_podcast_eligibility(clipping, TRUE, "Article (Model - Other)", "", "model/name", "other", directory)
  testthat::expect_false(identical(different_voice$guid, episode$guid))
  testthat::expect_identical(read_podcast_episode(clipping, "model/name", "other", directory)$guid, different_voice$guid)
  other <- file.path(directory, "other.md")
  writeLines("# Other", other)
  denied <- confirm_podcast_eligibility(other, FALSE, "Other", "", "model", "voice", directory)
  testthat::expect_identical(read_podcast_eligibility(other, directory)$eligible, "false")
  testthat::expect_null(read_podcast_episode(other, "model", "voice", directory))
  testthat::expect_false(identical(denied$guid, episode$guid))
})

testthat::test_that("episode defaults and RSS include stable podcast metadata", {
  testthat::expect_identical(default_episode_title("An Article", "acme/clear-voice", "en-US-Alex"), "An Article (Acme Clear Voice - en US Alex)")
  episode <- list(eligible = "true", title = "A & B < C", description = "Description", guid = "urn:readcast:1",
                  published = "Mon, 01 Jan 2024 12:00:00 GMT", audio_url = "https://audio.example/1.mp3", audio_size = "42")
  feed <- build_podcast_feed(list(episode), "https://reader.github.io/podcast", "Readcast", "Collection", "en", "false")
  testthat::expect_match(feed, '<rss version="2.0"')
  testthat::expect_match(feed, "<itunes:block>yes</itunes:block>")
  testthat::expect_match(feed, "<itunes:explicit>false</itunes:explicit>")
  testthat::expect_match(feed, "<language>en</language>")
  testthat::expect_match(feed, "A &amp; B &lt; C")
  testthat::expect_match(feed, 'length="42" type="audio/mpeg"')
  testthat::expect_match(feed, 'isPermaLink="false"')
  testthat::expect_false(grepl("itunes:block", sub("(?s)^.*?<item>(.*?)</item>.*$", "\\1", feed, perl = TRUE)))
  testthat::expect_error(build_podcast_feed(list(), "https://reader.github.io/podcast"), "no published episodes")
})

testthat::test_that("remote feed upserts one GUID and preserves other items and show metadata", {
  prior <- list(eligible = "true", title = "Earlier", description = "Old", guid = "urn:readcast:old",
    published = "Mon, 01 Jan 2024 12:00:00 GMT", audio_url = "https://audio.example/old.mp3", audio_size = "12")
  current <- list(eligible = "true", title = "New", description = "Metadata description", guid = "urn:readcast:new",
    published = "", audio_url = "https://audio.example/new.mp3", audio_size = "42")
  existing <- sub("<title>Readcast</title>", "<title>My existing show</title>",
    build_podcast_feed(list(prior), "https://reader.github.io/podcast", cover_url = "https://cdn.example/show.png"))
  merged <- upsert_podcast_feed(existing, list(current, current), "https://reader.github.io/podcast", "Ignored", "Ignored", "fr", "true", "https://reader.github.io/podcast/cover.png")
  xml <- xml2::read_xml(merged)
  testthat::expect_identical(xml2::xml_text(xml2::xml_find_first(xml, "/rss/channel/title")), "My existing show")
  testthat::expect_identical(xml2::xml_text(xml2::xml_find_first(xml, "/rss/channel/language")), "en")
  guids <- xml2::xml_text(xml2::xml_find_all(xml, "/rss/channel/item/guid"))
  testthat::expect_setequal(guids, c("urn:readcast:old", "urn:readcast:new"))
  testthat::expect_identical(sum(guids == "urn:readcast:new"), 1L)
  testthat::expect_identical(podcast_feed_cover_url(existing, "fallback"), "https://cdn.example/show.png")
  testthat::expect_identical(podcast_episode_status(NULL), "pending")
  testthat::expect_identical(podcast_episode_status(current), "recoverable")
  abandoned <- current
  abandoned$guid <- "urn:readcast:recoverable"
  testthat::expect_length(podcast_feed_candidates(list(abandoned), current, remote_feed_exists = TRUE), 1L)
  testthat::expect_length(podcast_feed_candidates(list(abandoned), current, remote_feed_exists = FALSE), 1L)
  saved_complete <- prior
  saved_complete$publication_state <- "complete"
  candidates_without_remote <- podcast_feed_candidates(list(abandoned, saved_complete), current, remote_feed_exists = FALSE)
  testthat::expect_setequal(vapply(candidates_without_remote, `[[`, character(1), "guid"), c(prior$guid, current$guid))
  current$publication_state <- "complete"
  testthat::expect_identical(podcast_episode_status(current), "complete")
})

testthat::test_that("audio retention waits 30 days and protects URLs still in the feed", {
  directory <- tempfile("retention-")
  dir.create(directory)
  on.exit(unlink(directory, recursive = TRUE), add = TRUE)
  entries <- list(
    list(url = "https://audio.example/audio/old.mp3", key = "audio/old.mp3", retired_at = "2024-01-01T00:00:00Z"),
    list(url = "https://audio.example/audio/live.mp3", key = "audio/live.mp3", retired_at = "2024-01-01T00:00:00Z"),
    list(url = "https://audio.example/audio/recent.mp3", key = "audio/recent.mp3", retired_at = "2024-02-20T00:00:00Z"))
  save_podcast_retention(entries, directory)
  testthat::expect_error(cleanup_podcast_audio(directory, NULL, function(key) NULL), "current readable feed")
  feed <- build_podcast_feed(list(list(eligible = "true", title = "Live", guid = "live", published = "", audio_url = entries[[2]]$url, audio_size = "1")), "https://pages.example")
  deleted <- character()
  result <- cleanup_podcast_audio(directory, feed, function(key) deleted <<- c(deleted, key), now = as.POSIXct("2024-03-01", tz = "UTC"))
  testthat::expect_identical(deleted, "audio/old.mp3")
  testthat::expect_identical(result, "audio/old.mp3")
  testthat::expect_length(read_podcast_retention(directory), 2L)
})

testthat::test_that("Pages publication rejects failed requests and verifies public resources", {
  calls <- character()
  fake <- function(request) {
    calls <<- c(calls, request$url)
    status <- if (grepl("api.github.com", request$url)) if (identical(request$method, "PUT")) 201L else 404L else 200L
    httr2::response(status_code = status, url = request$url)
  }
  testthat::expect_no_error(publish_pages_file("owner", "repo", "feed.xml", charToRaw("feed"), "token", fake))
  testthat::expect_length(calls, 2L)
  testthat::expect_error(verify_public_resource("https://reader.github.io/missing", perform = function(request) httr2::response(status_code = 404L, url = request$url)), "not reachable")
  testthat::expect_error(verify_public_resource("https://audio.example/file", "audio/mpeg", perform = function(request) httr2::response(url = request$url, headers = list(`content-type` = "audio/mpeg-evil"))), "unexpected content type")
})

testthat::test_that("episode publication verifies audio, cover and the live RSS enclosure", {
  directory <- tempfile("podcast-publish-")
  dir.create(directory)
  on.exit(unlink(directory, recursive = TRUE), add = TRUE)
  config <- file.path(directory, "config")
  state <- file.path(directory, "episodes")
  data <- file.path(directory, "data")
  save_readcast_setup_settings(list(github_pages_url = "https://reader.github.io/podcast/",
    podcast_title = "Readcast", podcast_description = "Collection", podcast_language = "en", podcast_explicit = "false"), config)
  clipping <- file.path(directory, "article.md")
  writeLines(c("---", "title: Sample", "description: Clipping description", "---", "Body"), clipping)
  mp3 <- file.path(directory, "cached.mp3")
  writeBin(as.raw(1:42), mp3)
  cover <- file.path(directory, "cover.png")
  magick::image_blank(1400, 1400, "white") |> magick::image_write(path = cover, format = "png")
  episode <- confirm_podcast_eligibility(clipping, TRUE, "Sample (Voice - Harper)", "Clipping description", "model/voice", "Harper", state)
  episode$audio_url <- "https://audio.example/audio/hash.mp3"
  episode$audio_size <- "42"
  episode$published <- "Mon, 01 Jan 2024 12:00:00 GMT"
  cover_url <- "https://reader.github.io/podcast/cover.png"
  live_feed <- build_podcast_feed(list(episode), "https://reader.github.io/podcast", "Readcast", "Collection", "en", "false", cover_url)
  token_before <- Sys.getenv("GITHUB_TOKEN", unset = NA_character_)
  pages_before <- Sys.getenv("READCAST_PAGES_URL", unset = NA_character_)
  on.exit({
    if (is.na(token_before)) Sys.unsetenv("GITHUB_TOKEN") else Sys.setenv(GITHUB_TOKEN = token_before)
    if (is.na(pages_before)) Sys.unsetenv("READCAST_PAGES_URL") else Sys.setenv(READCAST_PAGES_URL = pages_before)
  }, add = TRUE)
  Sys.setenv(GITHUB_TOKEN = "test-token")
  Sys.unsetenv("READCAST_PAGES_URL")
  calls <- character()
  feed_puts <- 0L
  uploads <- 0L
  upload_keys <- character()
  fail_upload <- TRUE
  fail_feed_put <- TRUE
  fake <- function(request) {
    calls <<- c(calls, paste(request$method %||% "GET", request$url))
    if (grepl("api.github.com", request$url)) {
      if (identical(request$method, "PUT") && grepl("feed[.]xml", request$url)) {
        feed_puts <<- feed_puts + 1L
        if (fail_feed_put) return(httr2::response(status_code = 500L, url = request$url))
      }
      if (identical(request$method, "GET") && grepl("feed[.]xml", request$url)) {
        encoded <- base64enc::base64encode(charToRaw(live_feed), linewidth = 0L, newline = "")
        body <- charToRaw(jsonlite::toJSON(list(sha = "feed-sha", content = encoded), auto_unbox = TRUE))
        return(httr2::response(status_code = 200L, url = request$url, body = body))
      }
      status <- if (identical(request$method, "PUT")) 201L else 404L
      return(httr2::response(status_code = status, url = request$url))
    }
    if (identical(request$method, "GET")) return(httr2::response(url = request$url, body = charToRaw(live_feed)))
    headers <- if (identical(request$url, cover_url)) list(`content-type` = "image/png") else list(`content-type` = "audio/mpeg", `content-length` = "42")
    httr2::response(url = request$url, method = request$method, headers = headers)
  }
  uploader <- function(path, config_dir, object_key = NULL) {
    uploads <<- uploads + 1L
    upload_keys <<- c(upload_keys, object_key)
    if (fail_upload) { fail_upload <<- FALSE; stop("simulated interrupted upload") }
    list(url = paste0("https://audio.example/", object_key), size = as.numeric(episode$audio_size))
  }
  unrelated_recoverable <- episode
  unrelated_recoverable$guid <- "urn:readcast:unfinished-other-episode"
  other_clipping <- file.path(directory, "other.md")
  writeLines("# Another article", other_clipping)
  save_podcast_episode(other_clipping, unrelated_recoverable, state)
  testthat::expect_error(publish_podcast_episode(clipping, mp3, cover, episode, config_dir = config, data_dir = state,
    audio_uploader = uploader, perform = fake), "simulated interrupted upload")
  pending_after_interruption <- read_podcast_episode(clipping, "model/voice", "Harper", state)
  testthat::expect_true(nzchar(pending_after_interruption$replacement_key))
  testthat::expect_error(publish_podcast_episode(clipping, mp3, cover, pending_after_interruption, config_dir = config, data_dir = state,
    audio_uploader = uploader, perform = fake), "rejected feed.xml")
  saved_after_failure <- read_podcast_episode(clipping, "model/voice", "Harper", state)
  testthat::expect_identical(podcast_episode_status(saved_after_failure), "recoverable")
  testthat::expect_identical(saved_after_failure$audio_url, paste0("https://audio.example/", upload_keys[[2L]]))
  live_feed <- build_podcast_feed(list(saved_after_failure), "https://reader.github.io/podcast", "Readcast", "Collection", "en", "false", cover_url)
  fail_feed_put <- FALSE
  result <- publish_podcast_episode(clipping, mp3, cover, saved_after_failure, config_dir = config, data_dir = state,
    audio_uploader = uploader, perform = fake)
  testthat::expect_identical(result$feed_url, "https://reader.github.io/podcast/feed.xml")
  testthat::expect_true(any(grepl(paste0("HEAD ", saved_after_failure$audio_url), calls, fixed = TRUE)))
  testthat::expect_true(any(grepl("HEAD https://reader.github.io/podcast/cover.png", calls, fixed = TRUE)))
  testthat::expect_true(any(grepl("GET https://reader.github.io/podcast/feed.xml", calls, fixed = TRUE)))
  testthat::expect_identical(uploads, 2L)
  testthat::expect_identical(upload_keys[[1L]], upload_keys[[2L]])
  testthat::expect_identical(feed_puts, 2L)
  testthat::expect_identical(read_podcast_episode(clipping, "model/voice", "Harper", state)$audio_size, "42")
  testthat::expect_identical(podcast_episode_status(read_podcast_episode(clipping, "model/voice", "Harper", state)), "complete")
  testthat::expect_identical(read_podcast_episode(clipping, "model/voice", "Harper", state)$published, episode$published)
  testthat::expect_length(read_podcast_retention(state), 1L)
  testthat::expect_identical(read_podcast_retention(state)[[1L]]$url, episode$audio_url)
})
