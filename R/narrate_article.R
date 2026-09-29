read_article <- function(input_markdown) {
  text <- readr::read_file(input_markdown)
  if (!nzchar(stringr::str_trim(text))) stop("Markdown file is empty: ", input_markdown)
  text
}

prepare_article <- function(markdown, replacements = character(), module_dir = ".") {
  preprocessing <- new.env(parent = baseenv())
  sys.source(file.path(module_dir, "R", "preprocess_article.R"), envir = preprocessing)
  text <- preprocessing$preprocess_markdown(markdown, replacements)
  if (!nzchar(text)) stop("Preprocessing produced no text")
  text
}

split_article <- function(text, word_limit = 350L, char_limit = 1900L) {
  if (!nzchar(text) || word_limit < 1L || char_limit < 1L) stop("Text and chunk limits must be non-empty and positive")
  word_count <- function(value) {
    value <- stringr::str_trim(value)
    if (!nzchar(value)) 0L else length(stringr::str_split(value, "\\s+")[[1]])
  }
  fits <- function(value) word_count(value) <= word_limit && stringr::str_length(value) <= char_limit

  paragraphs <- stringr::str_split(text, "\\n{2,}")[[1]]
  separators <- stringr::str_extract_all(text, "\\n{2,}")[[1]]
  units <- vapply(seq_along(paragraphs), function(index) paste0(paragraphs[[index]], if (index <= length(separators)) separators[[index]] else ""), character(1))
  chunks <- character()
  current <- ""
  for (unit in units) {
    segments <- if (fits(unit)) unit else stringi::stri_split_boundaries(unit, type = "sentence", locale = "en_US@ss=standard")[[1]]
    if (!identical(paste0(segments, collapse = ""), unit)) stop("Sentence segmentation changed the article")
    for (segment in segments) {
      if (!fits(segment)) stop("One sentence exceeds the model's chunk limit")
      if (nzchar(current) && !fits(paste0(current, segment))) {
        chunks <- c(chunks, current)
        current <- segment
      } else {
        current <- paste0(current, segment)
      }
    }
    if (nzchar(current)) chunks <- c(chunks, current)
    current <- ""
  }
  if (length(chunks) == 0L || !identical(paste0(chunks, collapse = ""), text) || !all(vapply(chunks, fits, logical(1)))) stop("Chunking did not preserve the prepared article")
  chunks
}

generate_chunk <- function(text, model, voice) {
  key <- Sys.getenv("OPENROUTER_API_KEY", unset = "")
  if (!nzchar(key)) stop("Set OPENROUTER_API_KEY before generating audio")
  response <- httr2::request("https://openrouter.ai/api/v1/audio/speech") |>
    httr2::req_headers(Authorization = paste("Bearer", key)) |>
    httr2::req_body_json(list(model = model, input = text, voice = voice, response_format = "mp3", speed = 1)) |>
    httr2::req_timeout(300) |>
    httr2::req_error(is_error = function(response) FALSE) |>
    httr2::req_perform()
  status <- httr2::resp_status(response)
  if (status < 200L || status >= 300L) {
    payload <- tryCatch(httr2::resp_body_json(response, simplifyVector = FALSE), error = function(error) NULL)
    details <- if (is.list(payload)) payload$error else NULL
    if (is.character(details) && length(details) == 1L) details <- list(message = details)
    if (!is.list(details)) details <- list()
    code <- details$code
    message <- details$message
    if (!is.character(code) && !is.numeric(code)) code <- NULL
    if (length(code) != 1L) code <- NULL
    if (!is.character(message) || length(message) != 1L) message <- NULL
    clean_detail <- function(value) {
      if (is.null(value) || !nzchar(value)) return(NULL)
      value <- gsub(key, "[redacted]", value, fixed = TRUE)
      value <- gsub(text, "[redacted request text]", value, fixed = TRUE)
      value <- gsub("[[:cntrl:]]+", " ", value)
      value <- stringr::str_squish(value)
      if (!nzchar(value)) NULL else substr(value, 1L, 240L)
    }
    code <- clean_detail(if (is.null(code)) "" else as.character(code))
    message <- clean_detail(message)
    description <- c(if (!is.null(code)) paste0("code ", code), if (!is.null(message)) message)
    suffix <- if (length(description)) paste0(": ", paste(description, collapse = " — ")) else ""
    stop("OpenRouter audio request failed (HTTP ", status, ")", suffix, call. = FALSE)
  }
  content_type <- httr2::resp_header(response, "content-type", default = "")
  if (!startsWith(tolower(content_type), "audio/mpeg")) stop("Expected MP3 audio, got ", content_type)
  audio <- httr2::resp_body_raw(response)
  if (length(audio) == 0L) stop("OpenRouter returned an empty MP3")
  generation_id <- httr2::resp_header(response, "x-generation-id", default = "")
  if (!nzchar(generation_id)) stop("OpenRouter did not return X-Generation-Id")
  list(audio = audio, generation_id = generation_id)
}

save_mp3 <- function(chunks, output_mp3, pause_after = integer(), pause_seconds = 0.55) {
  if (length(chunks) == 0L || any(lengths(chunks) == 0L)) stop("Cannot save missing audio chunks")
  if (!is.finite(pause_seconds) || pause_seconds < 0) stop("Pause length must be non-negative")
  output <- fs::path_abs(fs::path_expand(output_mp3))
  fs::dir_create(fs::path_dir(output))
  temporary <- tempfile("narrate-", tmpdir = fs::path_dir(output))
  dir.create(temporary)
  on.exit(unlink(temporary, recursive = TRUE), add = TRUE)

  chunk_files <- file.path(temporary, sprintf("chunk-%04d.mp3", seq_along(chunks) - 1L))
  purrr::walk2(chunks, chunk_files, writeBin)
  if (length(chunk_files) == 1L) {
    result <- chunk_files[[1]]
  } else {
    result <- file.path(temporary, "joined.mp3")
    pauses <- intersect(as.integer(pause_after), seq_len(length(chunk_files) - 1L))
    if (length(pauses) && pause_seconds > 0) {
      inputs <- unlist(lapply(chunk_files, function(path) c("-i", shQuote(path))), use.names = FALSE)
      segments <- vapply(seq_along(chunk_files), function(index) {
        filter <- if (index %in% pauses) paste0(",apad=pad_dur=", pause_seconds) else ""
        paste0("[", index - 1L, ":a]asetpts=PTS-STARTPTS", filter, "[a", index, "]")
      }, character(1))
      filter_graph <- paste0(paste(segments, collapse = ";"), ";", paste0(sprintf("[a%d]", seq_along(chunk_files)), collapse = ""),
                             "concat=n=", length(chunk_files), ":v=0:a=1[out]")
      arguments <- c("-hide_banner", "-loglevel", "error", inputs, "-filter_complex", shQuote(filter_graph),
                     "-map", shQuote("[out]"), "-c:a", "libmp3lame", "-b:a", "192k", shQuote(result))
    } else {
      manifest <- file.path(temporary, "chunks.txt")
      writeLines(sprintf("file '%s'", basename(chunk_files)), manifest, useBytes = TRUE)
      arguments <- c("-hide_banner", "-loglevel", "error", "-f", "concat", "-safe", "0", "-i", shQuote(manifest), "-c", "copy", shQuote(result))
    }
    log <- suppressWarnings(system2("ffmpeg", arguments, stdout = TRUE, stderr = TRUE))
    status <- attr(log, "status")
    if (!is.null(status) && status != 0L) stop("ffmpeg could not join MP3 chunks: ", paste(log, collapse = "\n"))
  }
  if (file.info(result)$size == 0L) stop("The resulting MP3 is empty")
  if (!file.rename(result, output)) stop("Could not install MP3 at ", output)
  output
}

narrate <- function(input_markdown, output_mp3, model = "microsoft/mai-voice-2-flash", voice = NULL, replacements = character(), module_dir = ".", progress = function(done, total) invisible(NULL)) {
  voices <- c("microsoft/mai-voice-2" = "en-US-Harper:MAI-Voice-2", "microsoft/mai-voice-2-flash" = "en-US-Harper:MAI-Voice-2", "deepgram/flux-tts:free" = "flux-haley-en")
  selected_voice <- if (!is.null(voice)) voice else voices[[model]]
  if (is.null(selected_voice)) stop("Supply a voice for model ", model)

  markdown <- read_article(input_markdown)
  prepared <- prepare_article(markdown, replacements, module_dir)
  chunks <- split_article(prepared)
  message("Prepared ", length(chunks), " chunks from ", input_markdown)
  audio <- purrr::map(seq_along(chunks), function(index) {
    chunk <- generate_chunk(stringr::str_trim(chunks[[index]], side = "right"), model, selected_voice)
    message("Generated chunk ", index, "/", length(chunks), " (", chunk$generation_id, ")")
    progress(index, length(chunks))
    chunk$audio
  })
  result <- save_mp3(audio, output_mp3, pause_after = which(stringr::str_detect(chunks, "\\n{2,}$")))
  message("Saved ", result)
  result
}
