default_cover_prompt <- function() paste(
  "Create polished, distinctive square podcast cover artwork. Use a solid opaque background,",
  "clear high contrast, and a central composition that remains legible as a small thumbnail.",
  "Do not include an Apple logo, device, or hardware."
)

cover_paths <- function(data_dir = path.expand("~/.local/share/readcast")) {
  artwork_dir <- file.path(data_dir, "covers")
  list(candidate = file.path(artwork_dir, "show-cover-candidate.png"),
       approved = file.path(artwork_dir, "show-cover.png"))
}

cover_api_key <- function(key = Sys.getenv("OPENROUTER_API_KEY", unset = "")) {
  key <- trimws(key)
  if (!nzchar(key)) stop("Set OPENROUTER_API_KEY in your environment to generate a podcast cover.", call. = FALSE)
  key
}

generate_cover_candidate <- function(prompt, destination, key = Sys.getenv("OPENROUTER_API_KEY", unset = "")) {
  key <- cover_api_key(key)
  prompt <- trimws(prompt)
  if (!nzchar(prompt)) stop("Enter a cover prompt before generating.", call. = FALSE)
  response <- httr2::request("https://openrouter.ai/api/v1/images") |>
    httr2::req_headers(Authorization = paste("Bearer", key)) |>
    httr2::req_body_json(list(model = "openai/gpt-image-2", prompt = prompt,
                              aspect_ratio = "1:1", size = "1920x1920",
                              output_format = "png", background = "opaque")) |>
    httr2::req_timeout(180) |>
    httr2::req_error(is_error = function(response) FALSE) |>
    httr2::req_perform()
  status <- httr2::resp_status(response)
  if (status %in% c(401L, 403L)) {
    stop("OpenRouter rejected OPENROUTER_API_KEY. Check that the key is valid, enabled, and has image-generation credits.", call. = FALSE)
  }
  httr2::resp_check_status(response)
  result <- httr2::resp_body_json(response, simplifyVector = FALSE)
  image <- result$data[[1]]
  if (is.null(image$b64_json) || !identical(image$media_type, "image/png")) {
    stop("OpenRouter did not return a PNG image. Try generating the candidate again.", call. = FALSE)
  }
  bytes <- base64enc::base64decode(image$b64_json)
  dir.create(dirname(destination), recursive = TRUE, showWarnings = FALSE)
  temporary <- tempfile("cover-", tmpdir = dirname(destination), fileext = ".png")
  on.exit(unlink(temporary), add = TRUE)
  writeBin(bytes, temporary)
  validate_cover_image(temporary)
  if (!file.copy(temporary, destination, overwrite = TRUE)) stop("Cannot save the cover candidate to ", destination, call. = FALSE)
  invisible(destination)
}

validate_cover_image <- function(path) {
  info <- tryCatch(magick::image_info(magick::image_read(path)), error = function(error) NULL)
  if (is.null(info) || nrow(info) != 1L || tolower(info$format[[1]]) != "png") {
    stop("The cover candidate is not a readable PNG image.", call. = FALSE)
  }
  if (info$width[[1]] != info$height[[1]] || info$width[[1]] < 1400L || info$width[[1]] > 3000L) {
    stop("The cover must be square and between 1400 and 3000 pixels per side.", call. = FALSE)
  }
  if (isTRUE(info$matte[[1]])) stop("The cover must have an opaque background with no transparency.", call. = FALSE)
  invisible(info)
}

approve_cover_candidate <- function(candidate, approved) {
  validate_cover_image(candidate)
  dir.create(dirname(approved), recursive = TRUE, showWarnings = FALSE)
  temporary <- tempfile("approved-cover-", tmpdir = dirname(approved), fileext = ".png")
  on.exit(unlink(temporary), add = TRUE)
  if (!file.copy(candidate, temporary, overwrite = TRUE) || !file.rename(temporary, approved)) {
    stop("Cannot save the approved show cover to ", approved, call. = FALSE)
  }
  invisible(approved)
}
