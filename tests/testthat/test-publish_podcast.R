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
  testthat::expect_identical(read_podcast_episode(other, "model", "voice", directory)$eligible, "false")
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
  fake <- function(request) {
    calls <<- c(calls, paste(request$method %||% "GET", request$url))
    if (grepl("api.github.com", request$url)) {
      status <- if (identical(request$method, "PUT")) 201L else 404L
      return(httr2::response(status_code = status, url = request$url))
    }
    if (identical(request$method, "GET")) return(httr2::response(url = request$url, body = charToRaw(live_feed)))
    headers <- if (identical(request$url, cover_url)) list(`content-type` = "image/png") else list(`content-type` = "audio/mpeg", `content-length` = "42")
    httr2::response(url = request$url, method = request$method, headers = headers)
  }
  uploader <- function(path, config_dir) list(url = episode$audio_url, size = as.numeric(episode$audio_size))
  result <- publish_podcast_episode(clipping, mp3, cover, episode, config_dir = config, data_dir = state,
    audio_uploader = uploader, perform = fake)
  testthat::expect_identical(result$feed_url, "https://reader.github.io/podcast/feed.xml")
  testthat::expect_true(any(grepl("HEAD https://audio.example/audio/hash.mp3", calls, fixed = TRUE)))
  testthat::expect_true(any(grepl("HEAD https://reader.github.io/podcast/cover.png", calls, fixed = TRUE)))
  testthat::expect_true(any(grepl("GET https://reader.github.io/podcast/feed.xml", calls, fixed = TRUE)))
  testthat::expect_identical(read_podcast_episode(clipping, "model/voice", "Harper", state)$audio_size, "42")
})
