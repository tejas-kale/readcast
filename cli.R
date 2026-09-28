arguments <- commandArgs(trailingOnly = TRUE)
command <- if (length(arguments)) arguments[[1]] else "help"

if (command == "configure") {
  supplied_path <- if (length(arguments) > 1L) arguments[[2]] else readline("Path to your Clippings directory: ")
  supplied_path <- path.expand(trimws(supplied_path))
  if (!nzchar(supplied_path) || !dir.exists(supplied_path)) {
    stop("That Clippings directory does not exist: ", supplied_path, call. = FALSE)
  }
  directory <- normalizePath(supplied_path, mustWork = TRUE)
  config_dir <- path.expand("~/.config/readcast")
  if (!dir.create(config_dir, recursive = TRUE, showWarnings = FALSE) && !dir.exists(config_dir)) {
    stop("Cannot create Readcast configuration directory: ", config_dir, call. = FALSE)
  }
  writeLines(directory, file.path(config_dir, "clippings-dir"), useBytes = TRUE)
  message("Saved Clippings directory: ", directory)
} else if (command %in% c("help", "--help", "-h")) {
  cat("Usage: readcast [configure [CLIPPINGS_DIRECTORY]]\n")
  cat("  readcast                         Launch Readcast\n")
  cat("  readcast configure [DIRECTORY]   Save your personal Clippings directory\n")
} else {
  stop("Unknown command: ", command, ". Run `readcast --help`.", call. = FALSE)
}
