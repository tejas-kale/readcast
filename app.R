module_dir <- Sys.getenv("READCAST_HOME", unset = "")
if (!nzchar(module_dir)) {
  script_argument <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
  module_dir <- if (length(script_argument)) dirname(normalizePath(sub("^--file=", "", script_argument[[1]]), mustWork = TRUE)) else getwd()
}
module_dir <- normalizePath(module_dir, mustWork = TRUE)
source(file.path(module_dir, "R", "narrate_article.R"), local = TRUE)
source(file.path(module_dir, "R", "podcast_cover.R"), local = TRUE)
source(file.path(module_dir, "R", "publish_audio.R"), local = TRUE)
source(file.path(module_dir, "R", "setup.R"), local = TRUE)
source(file.path(module_dir, "R", "publish_podcast.R"), local = TRUE)
setup_settings <- readcast_setup_settings()
clippings_dir <- path.expand(setup_settings$clippings_dir)
clippings_dir <- if (nzchar(clippings_dir) && dir.exists(clippings_dir)) normalizePath(clippings_dir, mustWork = TRUE) else ""
cache_dir <- path.expand(Sys.getenv("NARRATION_CACHE_DIR", "~/.cache/readcast/narrations"))
dir.create(cache_dir, recursive = TRUE, showWarnings = FALSE)
if (!dir.exists(cache_dir)) stop("Cannot create narration cache: ", cache_dir)
cover_data_dir <- path.expand(Sys.getenv("READCAST_DATA_DIR", "~/.local/share/readcast"))
cover_files <- cover_paths(cover_data_dir)
cover_artwork_dir <- dirname(cover_files$candidate)
dir.create(cover_artwork_dir, recursive = TRUE, showWarnings = FALSE)
if (!dir.exists(cover_artwork_dir)) stop("Cannot create Readcast cover directory: ", cover_artwork_dir)
if (nzchar(clippings_dir)) shiny::addResourcePath("clipping-assets", clippings_dir)
shiny::addResourcePath("narration-cache", cache_dir)
shiny::addResourcePath("cover-artwork", cover_artwork_dir)

list_clippings <- function(directory) {
  paths <- list.files(directory, pattern = "\\.md$", recursive = TRUE, ignore.case = TRUE)
  stats::setNames(sort(paths), sort(paths))
}

discover_tts_models <- function() {
  fallback <- c("Microsoft MAI Voice 2 Flash" = "microsoft/mai-voice-2-flash",
                "Microsoft MAI Voice 2" = "microsoft/mai-voice-2",
                "OpenAI GPT-4o mini TTS" = "openai/gpt-4o-mini-tts-2025-12-15")
  tryCatch({
    response <- httr2::request("https://openrouter.ai/api/v1/models") |>
      httr2::req_url_query(output_modalities = "speech") |>
      httr2::req_timeout(10) |>
      httr2::req_perform()
    models <- httr2::resp_body_json(response, simplifyVector = FALSE)$data
    if (length(models) == 0L) return(fallback)
    ids <- vapply(models, function(model) model$id, character(1))
    labels <- vapply(models, function(model) model$name %||% model$id, character(1))
    stats::setNames(ids, make.unique(labels))
  }, error = function(error) fallback)
}

`%||%` <- function(value, fallback) if (is.null(value) || length(value) == 0L) fallback else value

default_voice <- function(model) {
  switch(model,
         "microsoft/mai-voice-2" = "en-US-Harper:MAI-Voice-2",
         "microsoft/mai-voice-2-flash" = "en-US-Harper:MAI-Voice-2",
         "openai/gpt-4o-mini-tts-2025-12-15" = "alloy",
         "deepgram/flux-tts:free" = "flux-haley-en",
         "")
}

article_parts <- function(path) {
  markdown <- read_article(path)
  match <- stringr::str_match(markdown, stringr::regex("\\A---[ \\t]*\\n(.*?)\\n---[ \\t]*(?:\\n|\\z)", dotall = TRUE))
  if (is.na(match[1, 1])) return(list(title = tools::file_path_sans_ext(basename(path)), author = "", description = "", source = "", body = markdown))
  metadata <- yaml::yaml.load(match[1, 2])
  list(title = as.character(metadata$title %||% tools::file_path_sans_ext(basename(path))),
       author = as.character(unlist(metadata$author %||% "", use.names = FALSE)[1]),
       description = as.character(metadata$description %||% ""),
       source = as.character(metadata$source %||% ""),
       body = stringr::str_sub(markdown, stringr::str_length(match[1, 1]) + 1L))
}

preview_html <- function(body, article_path, root) {
  document <- xml2::read_html(commonmark::markdown_html(body, extensions = TRUE))
  for (node in xml2::xml_find_all(document, "//script|//iframe|//object|//embed|//form|//style|//link|//meta|//base")) xml2::xml_remove(node)
  for (node in xml2::xml_find_all(document, "//*[@*]")) {
    for (attribute in names(xml2::xml_attrs(node))) {
      if (grepl("^on", attribute, ignore.case = TRUE) || attribute %in% c("style", "srcset")) xml2::xml_attr(node, attribute) <- NULL
    }
  }
  root <- normalizePath(root, mustWork = TRUE)
  for (node in xml2::xml_find_all(document, "//*[@src or @href]")) {
    for (attribute in c("src", "href")) {
      value <- xml2::xml_attr(node, attribute)
      if (is.na(value)) next
      if (grepl("^https?://", value, ignore.case = TRUE)) next
      if (grepl("^(//|[a-z]+:|#)", value, ignore.case = TRUE)) {
        if (!startsWith(value, "#")) xml2::xml_attr(node, attribute) <- NULL
        next
      }
      local_path <- normalizePath(file.path(dirname(article_path), utils::URLdecode(value)), mustWork = FALSE)
      if (!startsWith(local_path, paste0(root, "/")) || !file.exists(local_path)) {
        xml2::xml_attr(node, attribute) <- NULL
        next
      }
      relative <- substring(local_path, nchar(root) + 2L)
      xml2::xml_attr(node, attribute) <- paste0("/clipping-assets/", utils::URLencode(relative, reserved = FALSE))
    }
  }
  body_node <- xml2::xml_find_first(document, "//body")
  htmltools::HTML(paste(vapply(xml2::xml_children(body_node), as.character, character(1)), collapse = "\n"))
}

cache_path <- function(article_path, model, voice, module_dir, cache_dir) {
  markdown <- read_article(article_path)
  spoken <- prepare_article(markdown, module_dir = module_dir)
  fingerprint <- digest::digest(list("paragraph-pause-v1", spoken, model, voice), algo = "sha256")
  stem <- stringr::str_sub(stringr::str_replace_all(tools::file_path_sans_ext(basename(article_path)), "[^[:alnum:]]+", "-"), 1L, 55L)
  file.path(cache_dir, paste0(stem, "-", stringr::str_sub(fingerprint, 1L, 20L), ".mp3"))
}

start_narration <- function(article_path, output, model, voice, module_dir) {
  progress_file <- paste0(output, ".progress")
  unlink(progress_file)
  job <- callr::r_bg(
    function(article_path, output, model, voice, module_dir, progress_file) {
      source(file.path(module_dir, "R", "narrate_article.R"), local = TRUE)
      narrate(article_path, output, model, voice, module_dir = module_dir,
              progress = function(done, total) writeLines(paste(done, total, sep = "/"), progress_file))
    },
    args = list(article_path, output, model, voice, module_dir, progress_file),
    stdout = paste0(output, ".log"), stderr = paste0(output, ".error.log"),
    supervise = TRUE
  )
  list(process = job, output = output, progress_file = progress_file)
}

app_css <- "
:root { color-scheme: light dark; --canvas: #f5f5f7; --surface: #fff; --text: #1d1d1f; --muted: #6e6e73; --line: #dedee3; --accent: #0878d1; --sidebar: #eeeef0; --player: #1d1d1f; }
@media (prefers-color-scheme: dark) { :root { --canvas: #111113; --surface: #1d1d20; --text: #f5f5f7; --muted: #a1a1a8; --line: #34343a; --accent: #60adff; --sidebar: #19191c; --player: #252529; } }
 * { box-sizing: border-box; }
.container-fluid { padding: 0; }
html, body { margin: 0; min-height: 100%; background: var(--canvas); color: var(--text); font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif; }
body { padding-bottom: 106px; }
a { color: var(--accent); text-decoration: none; }
a:hover { text-decoration: underline; }
button, input, select { font: inherit; }
button:focus-visible, a:focus-visible, input:focus-visible, select:focus-visible, audio:focus-visible { outline: 3px solid var(--accent); outline-offset: 3px; }
.app-shell { min-height: calc(100vh - 106px); display: grid; grid-template-columns: 310px minmax(0, 1fr); }
.sidebar { position: sticky; top: 0; height: calc(100vh - 106px); overflow-y: auto; background: var(--sidebar); border-right: 1px solid var(--line); padding: 30px 22px; }
.brand { display: flex; align-items: center; gap: 12px; margin-bottom: 44px; font-size: 17px; font-weight: 700; letter-spacing: -.03em; }
.brand-mark { display: grid; place-items: center; width: 34px; height: 34px; border-radius: 11px; background: var(--text); color: var(--canvas); font-size: 19px; }
.eyebrow { color: var(--muted); font-size: 11px; letter-spacing: .12em; text-transform: uppercase; font-weight: 700; margin: 28px 0 10px; }
.sidebar .form-group { margin: 0 0 15px; }
.sidebar label { display: block; margin-bottom: 7px; font-size: 13px; font-weight: 600; }
.sidebar .form-control, .sidebar .selectize-input { width: 100%; min-height: 42px; background: var(--surface); color: var(--text); border: 1px solid var(--line); border-radius: 11px; box-shadow: none; padding: 9px 12px; }
.sidebar .selectize-dropdown { color: #1d1d1f; }
.help-text { font-size: 12px; line-height: 1.5; color: var(--muted); margin: 4px 0 16px; }
.keyboard-help { border-top: 1px solid var(--line); padding-top: 18px; margin-top: 25px; }
.keyboard-help kbd { display: inline-block; min-width: 20px; text-align: center; padding: 1px 5px; border: 1px solid var(--line); border-radius: 5px; background: var(--surface); color: var(--text); font: inherit; font-weight: 600; }
.generate-button { width: 100%; min-height: 45px; border: 0; border-radius: 11px; background: var(--accent); color: #fff; font-weight: 650; margin-top: 8px; box-shadow: 0 4px 12px rgba(0, 80, 160, .15); }
.generate-button:hover { filter: brightness(1.08); }
.setup-button { width: 100%; min-height: 40px; border: 1px solid var(--line); border-radius: 11px; background: var(--surface); color: var(--text); font-weight: 600; margin: 0 0 18px; }
.setup-check { border: 1px solid var(--line); border-radius: 11px; padding: 14px; margin: 10px 0; background: var(--surface); }
.setup-check h4 { margin: 0 0 8px; font-size: 15px; }
.setup-result { color: var(--muted); font-size: 13px; line-height: 1.5; margin: 10px 0 0; }
.status { min-height: 40px; margin-top: 14px; color: var(--muted); font-size: 12px; line-height: 1.5; }
.reader-wrap { min-width: 0; padding: 44px clamp(22px, 6vw, 92px) 90px; }
.reader { max-width: 820px; margin: 0 auto; }
.reader-kicker { color: var(--accent); text-transform: uppercase; letter-spacing: .13em; font-size: 11px; font-weight: 750; margin-bottom: 13px; }
.reader h1 { font-size: clamp(34px, 4vw, 57px); line-height: 1.1; letter-spacing: -.045em; margin: 0 0 18px; font-weight: 720; }
.reader-meta { display: flex; gap: 10px 18px; flex-wrap: wrap; color: var(--muted); font-size: 13px; padding-bottom: 29px; border-bottom: 1px solid var(--line); }
.article-body { font-family: Georgia, 'Times New Roman', serif; font-size: 18px; line-height: 1.77; overflow-wrap: anywhere; }
.article-body p { margin: 1.2em 0; }
.article-body h1, .article-body h2, .article-body h3 { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif; letter-spacing: -.025em; line-height: 1.25; margin: 1.7em 0 .5em; }
.article-body h1 { font-size: 30px; } .article-body h2 { font-size: 25px; } .article-body h3 { font-size: 21px; }
.article-body img { display: block; max-width: 100%; height: auto; border-radius: 12px; margin: 26px auto; }
.article-body blockquote { border-left: 3px solid var(--accent); margin: 28px 0; padding: 2px 0 2px 24px; color: var(--muted); }
.article-body pre { overflow-x: auto; padding: 18px; border-radius: 12px; background: var(--sidebar); font-size: 13px; line-height: 1.5; }
.article-body table { display: block; overflow-x: auto; border-collapse: collapse; } .article-body td, .article-body th { border-bottom: 1px solid var(--line); padding: 7px 12px; }
.empty-state { color: var(--muted); text-align: center; padding: 18vh 10px; font-size: 16px; }
.player-bar { position: fixed; inset: auto 0 0; z-index: 30; width: 100%; min-height: 86px; padding: 13px clamp(18px, 3vw, 44px); background: var(--player); color: #fff; border-top: 1px solid rgba(255,255,255,.1); box-shadow: 0 -8px 30px rgba(0,0,0,.08); }
#player { width: 100%; display: flex; align-items: center; gap: 24px; }
.player-icon { flex: 0 0 48px; height: 48px; display: grid; place-items: center; border-radius: 10px; background: linear-gradient(145deg, #80c6ff, #2871d7); color: #fff; font-size: 24px; }
.player-title { width: clamp(140px, 21vw, 280px); min-width: 0; } .player-title strong { display: block; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; font-size: 13px; } .player-title span { display: block; color: #b9b9bd; font-size: 11px; margin-top: 3px; }
.player-audio { flex: 1 1 0; min-width: 0; } .player-audio audio { display: block; width: 100%; height: 42px; accent-color: var(--accent); }
.player-empty { color: #b9b9bd; text-align: center; font-size: 13px; padding: 12px; }
@media (max-width: 760px) { body { padding-bottom: 142px; } .app-shell { display: block; } .sidebar { position: static; height: auto; padding: 18px 20px 24px; } .brand { margin-bottom: 13px; } .reader-wrap { padding: 30px 20px 70px; } .player-bar { min-height: 130px; } #player { flex-wrap: wrap; gap: 7px 12px; } .player-title { flex: 1; width: auto; } .player-audio { flex: 0 0 100%; } }
"

keyboard_shortcuts_js <- "
(function () {
  function focusControl(id) {
    const element = document.getElementById(id);
    if (!element) return false;
    if (element.selectize) {
      element.selectize.focus();
      if (id === 'article') element.selectize.open();
    }
    else element.focus();
    return true;
  }

  document.addEventListener('keydown', function (event) {
    if ((event.metaKey || event.ctrlKey) && event.key === 'Enter' && !event.altKey && !event.shiftKey) {
      const button = document.getElementById('generate');
      if (button) { event.preventDefault(); button.click(); }
      return;
    }
    if (event.metaKey || event.ctrlKey || event.altKey) return;
    const target = event.target;
    if (!(target instanceof Element)) return;
    if (target.closest('input, textarea, select, [contenteditable], [role=combobox], button, a, audio, [role=slider]')) return;

    const key = event.key.toLowerCase();
    if (key === '/' || key === 'a' || key === 'm' || key === 'v') {
      const id = {'/': 'article', a: 'article', m: 'model', v: 'voice'}[key];
      if (focusControl(id)) event.preventDefault();
      return;
    }
    if (key === 'j' || key === 'k') {
      event.preventDefault();
      window.scrollBy(0, key === 'j' ? 96 : -96);
      return;
    }
    const audio = document.querySelector('.player-audio audio');
    if (!audio) return;
    if (event.code === 'Space') {
      event.preventDefault();
      if (audio.paused) audio.play().catch(function () {});
      else audio.pause();
    } else if (key === 'h' || key === 'l') {
      event.preventDefault();
      const next = audio.currentTime + (key === 'l' ? 10 : -10);
      audio.currentTime = Number.isFinite(audio.duration) ? Math.max(0, Math.min(next, audio.duration)) : Math.max(0, next);
    }
  });
}());
"

ui <- shiny::fluidPage(
  shiny::tags$head(shiny::tags$title("Readcast"), shiny::tags$style(htmltools::HTML(app_css)), shiny::tags$script(htmltools::HTML(keyboard_shortcuts_js))),
  shiny::tags$div(class = "app-shell",
    shiny::tags$aside(class = "sidebar",
      shiny::tags$div(class = "brand", shiny::tags$span(class = "brand-mark", "♪"), "Readcast"),
      shiny::actionButton("open_setup", "Set up Readcast", class = "setup-button"),
      shiny::tags$div(class = "eyebrow", "Library"),
      shiny::selectizeInput("article", "Article", choices = NULL, options = list(placeholder = "Search clippings…", maxOptions = 50, openOnFocus = TRUE)),
      shiny::tags$div(class = "eyebrow", "Narration"),
      shiny::selectInput("model", "OpenRouter model", choices = NULL),
      shiny::textInput("voice", "Voice", value = ""),
      shiny::tags$p(class = "help-text", "Voices depend on the model. A default is filled in when known; otherwise enter a voice from the model’s page."),
      shiny::tags$div(class = "eyebrow", "Podcast cover"),
      shiny::textAreaInput("cover_prompt", "Starting prompt", value = default_cover_prompt(), rows = 4),
      shiny::actionButton("generate_cover", "Generate cover candidate", class = "generate-button"),
      shiny::uiOutput("cover_candidate"),
      shiny::actionButton("approve_cover", "Approve this cover", class = "generate-button"),
      shiny::tags$div(class = "status", shiny::textOutput("cover_status")),
      shiny::actionButton("generate", "Generate audio", class = "generate-button"),
      shiny::actionButton("publish_audio", "Upload cached audio to R2", class = "generate-button"),
      shiny::tags$div(class = "status", shiny::textOutput("publish_status")),
      shiny::tags$div(class = "eyebrow", "Podcast episode"),
      shiny::textInput("episode_title", "Episode title", value = ""),
      shiny::actionButton("publish_episode", "Publish episode and RSS feed", class = "generate-button"),
      shiny::tags$div(class = "status", shiny::textOutput("episode_status")),
      shiny::actionButton("cleanup_audio", "Review aged audio cleanup", class = "generate-button"),
      shiny::tags$div(class = "status", shiny::textOutput("cleanup_status")),
      shiny::tags$div(class = "status", shiny::textOutput("status")),
      shiny::tags$p(class = "help-text keyboard-help",
        shiny::tags$kbd("/"), "/", shiny::tags$kbd("a"), " find article · ", shiny::tags$kbd("m"), " model · ", shiny::tags$kbd("v"), " voice", shiny::tags$br(),
        shiny::tags$kbd("j"), "/", shiny::tags$kbd("k"), " scroll · ", shiny::tags$kbd("h"), "/", shiny::tags$kbd("l"), " seek · ", shiny::tags$kbd("Space"), " play/pause", shiny::tags$br(),
        shiny::tags$kbd("⌘/Ctrl+Enter"), " generate. Shortcuts pause while typing.")
    ),
    shiny::tags$main(class = "reader-wrap", shiny::tags$article(class = "reader",
      shiny::uiOutput("article_header"), shiny::uiOutput("article_body")))
  ),
  shiny::tags$footer(class = "player-bar", shiny::uiOutput("player"))
)

server <- function(input, output, session) {
  active_clippings_dir <- shiny::reactiveVal(clippings_dir)
  clippings <- if (nzchar(clippings_dir)) list_clippings(clippings_dir) else character()
  models <- discover_tts_models()
  state <- shiny::reactiveValues(job = NULL, status = "Choose an article to begin.", refresh = 0L)
  cover_state <- shiny::reactiveValues(status = "Edit the prompt, then generate a cover candidate.", refresh = 0L)
  publish_state <- shiny::reactiveValues(status = "Publishing is optional; configure R2 to host an episode.", episode_status = "Confirm eligibility before the first publication of each clipping.", cleanup_status = "Cleanup checks the live feed and retains replaced audio for at least 30 days.")
  setup_state <- shiny::reactiveValues(
    clippings = list(ok = FALSE, message = "Choose your Clippings export folder, then run this check."),
    openrouter = list(ok = FALSE, message = "Set OPENROUTER_API_KEY in your shell environment, then run this check."),
    hosting = list(ok = FALSE, message = "Set the R2 and Worker environment values, then run this check."),
    github_access = list(ok = FALSE, message = "Set GITHUB_TOKEN with repository read access, then run this check."),
    github_pages = list(ok = FALSE, message = "Enter your GitHub Pages site URL, then run this check.")
  )
  shiny::updateSelectizeInput(session, "article", choices = clippings, selected = character(0), server = TRUE)
  shiny::updateSelectInput(session, "model", choices = models, selected = if ("microsoft/mai-voice-2-flash" %in% models) "microsoft/mai-voice-2-flash" else unname(models[[1]]))

  shiny::observeEvent(input$model, {
    shiny::updateTextInput(session, "voice", value = default_voice(input$model))
  })

  selected_path <- shiny::reactive({
    shiny::req(input$article)
    root <- active_clippings_dir()
    shiny::validate(shiny::need(nzchar(root), "Choose a Clippings directory in Set up Readcast."))
    path <- normalizePath(file.path(root, input$article), mustWork = TRUE)
    shiny::validate(shiny::need(startsWith(path, paste0(root, "/")) && grepl("\\.md$", path, ignore.case = TRUE), "Select a Markdown clipping from the library."))
    path
  })
  article <- shiny::reactive(article_parts(selected_path()))

  output$article_header <- shiny::renderUI({
    shiny::req(input$article)
    item <- article()
    source_link <- if (grepl("^https?://", item$source)) shiny::tags$a(href = item$source, target = "_blank", rel = "noopener noreferrer", "Original source ↗") else NULL
    shiny::tagList(shiny::tags$div(class = "reader-kicker", "From your clippings"),
                   shiny::tags$h1(item$title),
                   shiny::tags$div(class = "reader-meta", if (nzchar(item$author)) shiny::tags$span(item$author), source_link))
  })
  output$article_body <- shiny::renderUI({
    if (is.null(input$article) || !nzchar(input$article)) return(shiny::tags$div(class = "empty-state", "Choose an article to read and narrate."))
    shiny::tags$div(class = "article-body", preview_html(article()$body, selected_path(), active_clippings_dir()))
  })
  output$status <- shiny::renderText(state$status)
  output$cover_status <- shiny::renderText(cover_state$status)
  output$publish_status <- shiny::renderText(publish_state$status)
  output$episode_status <- shiny::renderText(publish_state$episode_status)
  output$cleanup_status <- shiny::renderText(publish_state$cleanup_status)
  output$setup_clippings_result <- shiny::renderText(setup_state$clippings$message)
  output$setup_openrouter_result <- shiny::renderText(setup_state$openrouter$message)
  output$setup_hosting_result <- shiny::renderText(setup_state$hosting$message)
  output$setup_github_access_result <- shiny::renderText(setup_state$github_access$message)
  output$setup_github_pages_result <- shiny::renderText(setup_state$github_pages$message)

  shiny::observeEvent(list(input$article, input$model, input$voice), {
    if (is.null(input$article) || !nzchar(input$article)) return()
    item <- article()
    shiny::updateTextInput(session, "episode_title", value = default_episode_title(item$title, input$model %||% "", input$voice %||% ""))
    if (is.null(input$model) || !nzchar(input$model) || is.null(input$voice) || !nzchar(input$voice)) {
      publish_state$episode_status <- "Publication pending: choose a model and voice to identify the episode."
      return()
    }
    saved <- read_podcast_episode(selected_path(), input$model, input$voice)
    status <- podcast_episode_status(saved)
    publish_state$episode_status <- switch(status,
      pending = "Publication pending: no audio has been published for this episode.",
      recoverable = "Publication recoverable: the uploaded audio is saved; publish again to complete the feed.",
      complete = "Publication complete.")
  })

  shiny::observeEvent(input$open_setup, {
    settings <- readcast_setup_settings()
    shiny::showModal(shiny::modalDialog(
      title = "Set up Readcast",
      size = "l", easyClose = TRUE,
      shiny::p("Set up the local library and optional narration publishing connections. Every Check button can be run again after changing configuration. Checks only read configuration or contact the service; they never generate or publish audio and never create cloud resources."),
      shiny::tags$details(open = NA,
        shiny::tags$summary("One-time setup guide"),
        shiny::tags$ol(
          shiny::tags$li("Choose the folder containing your exported Markdown Clippings. This is saved locally in ~/.config/readcast/settings; CLIPPINGS_DIR still takes precedence when set."),
          shiny::tags$li("For narration, create an OpenRouter API key and expose it as OPENROUTER_API_KEY through your shell or secret manager. Readcast never asks to display or save the key."),
          shiny::tags$li("For public episode hosting, create a dedicated public GitHub repository for the Pages site, enable Pages from the root of its main branch, and use the resulting https://<account>.github.io/<repository>/ URL. Keep this separate from private code."),
          shiny::tags$li("In Cloudflare, create the private R2 bucket readcast-audio in Standard storage. Create an R2 token with Object Read & Write access, then deploy the bundled Worker with npx wrangler deploy from the worker directory and bind AUDIO_BUCKET to that bucket."),
          shiny::tags$li("Set R2_ACCOUNT_ID, R2_BUCKET, READCAST_WORKER_URL, R2_ACCESS_KEY_ID and R2_SECRET_ACCESS_KEY in your shell or secret manager. The Worker URL must be its permanent https://<worker>.<account>.workers.dev origin. Keep that URL unchanged after publishing."),
          shiny::tags$li("Set GITHUB_TOKEN with repository contents write access to the dedicated Pages repository. Readcast uses it to publish the feed and cover; it is never shown or saved."),
          shiny::tags$li("Save non-secret site and storage values below. Secret values are read only from the environment; none are shown or written to Readcast configuration.")),
        shiny::p("Provisioning is a one-time manual step. Readcast does not create repositories, buckets, tokens or Workers.")),
      shiny::textInput("setup_clippings", "Clippings directory", value = settings$clippings_dir, placeholder = "~/Documents/Clippings"),
      shiny::div(class = "setup-check", shiny::tags$h4("Clippings"), shiny::actionButton("check_setup_clippings", "Check Clippings"), shiny::tags$p(class = "setup-result", shiny::textOutput("setup_clippings_result"))),
      shiny::div(class = "setup-check", shiny::tags$h4("OpenRouter"), shiny::p("Reads OPENROUTER_API_KEY from the environment; the key is never displayed."), shiny::actionButton("check_setup_openrouter", "Check OpenRouter"), shiny::tags$p(class = "setup-result", shiny::textOutput("setup_openrouter_result"))),
      shiny::textInput("setup_r2_account", "R2 account ID", value = settings$r2_account_id),
      shiny::textInput("setup_r2_bucket", "R2 bucket name", value = settings$r2_bucket),
      shiny::textInput("setup_worker_url", "Worker URL", value = setup_url_for_display(settings$worker_url), placeholder = "https://readcast.<account>.workers.dev"),
      shiny::div(class = "setup-check", shiny::tags$h4("R2 and Worker"), shiny::p("Readcast checks bucket listing permission and sends a HEAD request for a deliberately missing object. Access keys are read from the environment and never displayed."), shiny::actionButton("check_setup_hosting", "Check R2 and Worker"), shiny::tags$p(class = "setup-result", shiny::textOutput("setup_hosting_result"))),
      shiny::textInput("setup_github_url", "GitHub Pages site URL", value = setup_url_for_display(settings$github_pages_url), placeholder = "https://<account>.github.io/<repository>/"),
      shiny::textInput("setup_podcast_title", "Show title", value = settings$podcast_title),
      shiny::textAreaInput("setup_podcast_description", "Show description", value = settings$podcast_description, rows = 2),
      shiny::textInput("setup_podcast_language", "Show language", value = settings$podcast_language),
      shiny::selectInput("setup_podcast_explicit", "Explicit content", choices = c("No" = "false", "Yes" = "true"), selected = settings$podcast_explicit),
      shiny::div(class = "setup-check", shiny::tags$h4("GitHub repository access"), shiny::p("Checks GITHUB_TOKEN against the repository API using a read-only request."), shiny::actionButton("check_setup_github_access", "Check GitHub repository access"), shiny::tags$p(class = "setup-result", shiny::textOutput("setup_github_access_result"))),
      shiny::div(class = "setup-check", shiny::tags$h4("GitHub Pages site"), shiny::p("Checks the public site URL independently of the repository token."), shiny::actionButton("check_setup_github_pages", "Check GitHub Pages site"), shiny::tags$p(class = "setup-result", shiny::textOutput("setup_github_pages_result"))),
      footer = shiny::tagList(shiny::actionButton("save_setup", "Save settings", class = "btn-primary"), shiny::modalButton("Close")))
    )
  })

  shiny::observeEvent(input$save_setup, {
    directory <- path.expand(trimws(input$setup_clippings %||% ""))
    if (nzchar(directory) && !dir.exists(directory)) {
      shiny::showNotification("That Clippings directory does not exist. Correct it before saving.", type = "error")
      return()
    }
    directory <- if (nzchar(directory)) normalizePath(directory, mustWork = TRUE) else ""
    save_readcast_setup_settings(list(
      clippings_dir = directory,
      github_pages_url = input$setup_github_url %||% "",
      podcast_title = input$setup_podcast_title %||% "Readcast",
      podcast_description = input$setup_podcast_description %||% "A personal collection of narrated articles.",
      podcast_language = input$setup_podcast_language %||% "en",
      podcast_explicit = input$setup_podcast_explicit %||% "false",
      r2_account_id = input$setup_r2_account %||% "",
      r2_bucket = input$setup_r2_bucket %||% "",
      worker_url = input$setup_worker_url %||% ""
    ))
    active_clippings_dir(directory)
    if (nzchar(directory)) {
      shiny::addResourcePath("clipping-assets", directory)
      shiny::updateSelectizeInput(session, "article", choices = list_clippings(directory), selected = character(0), server = TRUE)
    } else shiny::updateSelectizeInput(session, "article", choices = character(), selected = character(), server = TRUE)
    shiny::showNotification("Saved local setup values. Environment variables override matching values when the app restarts.", type = "message")
  })

  shiny::observeEvent(input$check_setup_clippings, {
    setup_state$clippings <- setup_check_result(function() check_readcast_clippings(input$setup_clippings))
  })
  shiny::observeEvent(input$check_setup_openrouter, {
    setup_state$openrouter <- setup_check_result(check_readcast_openrouter)
  })
  shiny::observeEvent(input$check_setup_hosting, {
    setup_state$hosting <- setup_check_result(function() check_readcast_hosting(
      input$setup_r2_account, input$setup_r2_bucket,
      Sys.getenv("R2_ACCESS_KEY_ID", unset = ""), Sys.getenv("R2_SECRET_ACCESS_KEY", unset = ""), input$setup_worker_url
    ))
  })
  shiny::observeEvent(input$check_setup_github_access, {
    setup_state$github_access <- setup_check_result(function() check_readcast_github_access(input$setup_github_url))
  })
  shiny::observeEvent(input$check_setup_github_pages, {
    setup_state$github_pages <- setup_check_result(function() check_readcast_github_pages(input$setup_github_url))
  })
  output$cover_candidate <- shiny::renderUI({
    cover_state$refresh
    if (!file.exists(cover_files$candidate)) return(NULL)
    shiny::tags$div(class = "cover-candidate",
      shiny::tags$img(src = "/cover-artwork/show-cover-candidate.png", alt = "Podcast cover candidate", style = "width:100%;max-width:300px;height:auto"))
  })

  shiny::observeEvent(input$generate_cover, {
    tryCatch({
      generate_cover_candidate(input$cover_prompt, cover_files$candidate)
      cover_state$status <- "Candidate ready. Inspect it above, then approve it or edit the prompt and regenerate."
      cover_state$refresh <- cover_state$refresh + 1L
    }, error = function(error) {
      cover_state$status <- conditionMessage(error)
      shiny::showNotification(cover_state$status, type = "error", duration = NULL)
    })
  })

  shiny::observeEvent(input$approve_cover, {
    if (!file.exists(cover_files$candidate)) {
      cover_state$status <- "Generate a cover candidate before approving one."
      shiny::showNotification(cover_state$status, type = "message")
      return()
    }
    tryCatch({
      approve_cover_candidate(cover_files$candidate, cover_files$approved)
      cover_state$status <- "Approved cover saved to your Readcast data directory."
    }, error = function(error) {
      cover_state$status <- conditionMessage(error)
      shiny::showNotification(cover_state$status, type = "error", duration = NULL)
    })
  })

  current_cache <- shiny::reactive({
    shiny::req(input$article, input$model)
    cache_path(selected_path(), input$model, stringr::str_trim(input$voice %||% ""), module_dir, cache_dir)
  })

  shiny::observeEvent(input$publish_audio, {
    path <- tryCatch(current_cache(), error = function(error) {
      publish_state$status <- conditionMessage(error)
      NULL
    })
    if (is.null(path)) return()
    if (!file.exists(path) || file.info(path)$size <= 0L) {
      publish_state$status <- "Generate or select an existing cached narration before uploading it."
      shiny::showNotification(publish_state$status, type = "message")
      return()
    }
    tryCatch({
      uploaded <- upload_cached_audio(path)
      publish_state$status <- paste("Hosted audio:", uploaded$url)
      shiny::showNotification("Cached audio uploaded to R2.", type = "message")
    }, error = function(error) {
      publish_state$status <- conditionMessage(error)
      shiny::showNotification(publish_state$status, type = "error", duration = NULL)
    })
  })

  publish_episode_now <- function(eligible = TRUE) {
    path <- selected_path()
    episode <- read_podcast_episode(path, input$model, input$voice)
    if (is.null(episode)) {
      item <- article()
      episode <- confirm_podcast_eligibility(path, eligible, input$episode_title,
        item$description, input$model, input$voice)
    } else if (!identical(episode$eligible, "true")) {
      publish_state$episode_status <- "This clipping was marked ineligible. Its decision is saved."
      return(invisible(NULL))
    } else {
      episode$title <- trimws(input$episode_title)
      episode$description <- article()$description
      episode$model <- input$model
      episode$voice <- input$voice
    }
    if (!identical(episode$eligible, "true")) {
      publish_state$episode_status <- "This clipping was marked ineligible. Its decision is saved."
      return(invisible(NULL))
    }
    output_path <- current_cache()
    if (!file.exists(output_path) || file.info(output_path)$size <= 0L) stop("Generate or select an existing cached narration before publishing.", call. = FALSE)
    publish_state$episode_status <- "Publication pending: uploading audio and updating the feed."
    result <- publish_podcast_episode(path, output_path, cover_files$approved, episode)
    publish_state$episode_status <- paste("Publication complete. RSS feed:", result$feed_url)
    shiny::showModal(shiny::modalDialog(title = "Podcast published", shiny::p("RSS feed:", shiny::tags$a(href = result$feed_url, target = "_blank", rel = "noopener noreferrer", result$feed_url)),
      shiny::p("In Apple Podcasts, choose Add a Show by URL, paste the feed URL, and follow the show."), footer = shiny::modalButton("Done"), easyClose = TRUE))
    invisible(result)
  }

  shiny::observeEvent(input$cleanup_audio, {
    shiny::showModal(shiny::modalDialog(title = "Clean up replaced podcast audio?",
      shiny::p("Readcast will fetch the current live RSS feed and delete only replaced audio objects that are at least 30 days old and no longer referenced by that feed. Failed deletions remain available for retry."),
      footer = shiny::tagList(shiny::actionButton("confirm_audio_cleanup", "Delete eligible audio"), shiny::modalButton("Cancel")), easyClose = TRUE))
  })

  shiny::observeEvent(input$confirm_audio_cleanup, {
    shiny::removeModal()
    tryCatch({
      result <- cleanup_published_podcast_audio()
      publish_state$cleanup_status <- paste0("Audio cleanup complete. Deleted ", length(result$deleted), " object(s); ", length(result$failed), " deletion(s) will be retried next time.")
      shiny::showNotification(publish_state$cleanup_status, type = if (length(result$failed)) "warning" else "message")
    }, error = function(error) {
      publish_state$cleanup_status <- conditionMessage(error)
      shiny::showNotification(publish_state$cleanup_status, type = "error", duration = NULL)
    })
  })

  shiny::observeEvent(input$publish_episode, {
    path <- tryCatch(selected_path(), error = function(error) NULL)
    if (is.null(path)) return()
    episode <- read_podcast_episode(path, input$model, input$voice)
    if (is.null(episode) && is.null(read_podcast_eligibility(path))) {
      shiny::showModal(shiny::modalDialog(title = "Confirm podcast eligibility",
        shiny::p("Is this clipping eligible for podcast publication? Confirm that you have the rights to publish its narration and metadata."),
        footer = shiny::tagList(shiny::actionButton("confirm_episode_eligible", "Yes, publish this clipping"), shiny::actionButton("deny_episode_eligible", "No, mark ineligible"), shiny::modalButton("Cancel")), easyClose = TRUE))
    } else tryCatch(publish_episode_now(), error = function(error) {
      saved <- read_podcast_episode(selected_path(), input$model, input$voice)
      publish_state$episode_status <- if (identical(podcast_episode_status(saved), "recoverable")) {
        paste("Publication recoverable: uploaded audio is saved. Retry to finish publishing the feed.", conditionMessage(error))
      } else paste("Publication pending:", conditionMessage(error))
      shiny::showNotification(publish_state$episode_status, type = "error", duration = NULL)
    })
  })
  shiny::observeEvent(input$confirm_episode_eligible, {
    tryCatch(publish_episode_now(), error = function(error) {
      saved <- read_podcast_episode(selected_path(), input$model, input$voice)
      publish_state$episode_status <- if (identical(podcast_episode_status(saved), "recoverable")) {
        paste("Publication recoverable: uploaded audio is saved. Retry to finish publishing the feed.", conditionMessage(error))
      } else paste("Publication pending:", conditionMessage(error))
      shiny::showNotification(publish_state$episode_status, type = "error", duration = NULL)
    })
  })
  shiny::observeEvent(input$deny_episode_eligible, {
    tryCatch({
      item <- article()
      confirm_podcast_eligibility(selected_path(), FALSE, input$episode_title,
        item$description, input$model, input$voice)
      publish_state$episode_status <- "This clipping was marked ineligible. Its decision is saved."
    }, error = function(error) {
      publish_state$episode_status <- conditionMessage(error)
      shiny::showNotification(publish_state$episode_status, type = "error", duration = NULL)
    })
  })

  output$player <- shiny::renderUI({
    state$refresh
    path <- tryCatch(current_cache(), error = function(error) NULL)
    title <- if (!is.null(input$article) && nzchar(input$article)) article()$title else "No article selected"
    ready <- !is.null(path) && file.exists(path) && file.info(path)$size > 0L
    shiny::tagList(
      shiny::tags$div(class = "player-icon", "♫"),
      shiny::tags$div(class = "player-title", shiny::tags$strong(title), shiny::tags$span(if (ready) "Ready to play" else "Your narration will appear here")),
      shiny::tags$div(class = "player-audio", if (ready)
        shiny::tags$audio(controls = NA, preload = "metadata", src = paste0("/narration-cache/", utils::URLencode(basename(path), reserved = FALSE)))
        else shiny::tags$div(class = "player-empty", "Select an article and generate audio to listen."))
    )
  })

  shiny::observeEvent(input$generate, {
    if (is.null(input$article) || !nzchar(input$article)) {
      shiny::showNotification("Choose an article first.", type = "message")
      return()
    }
    if (!is.null(state$job) && state$job$process$is_alive()) {
      shiny::showNotification("A narration is already being generated.", type = "message")
      return()
    }
    path <- tryCatch(current_cache(), error = function(error) {
      shiny::showNotification(conditionMessage(error), type = "error", duration = NULL)
      NULL
    })
    if (is.null(path)) return()
    if (file.exists(path) && file.info(path)$size > 0L) {
      state$status <- "Already cached. Press play below."
      state$refresh <- state$refresh + 1L
      return()
    }
    if (!nzchar(Sys.getenv("OPENROUTER_API_KEY", unset = ""))) {
      shiny::showNotification("Set OPENROUTER_API_KEY before generating audio.", type = "error", duration = NULL)
      return()
    }
    if (!nzchar(Sys.which("ffmpeg"))) {
      shiny::showNotification("Install ffmpeg before narrating an article that needs multiple chunks.", type = "error", duration = NULL)
      return()
    }
    voice <- stringr::str_trim(input$voice %||% "")
    if (!nzchar(voice)) {
      shiny::showNotification("Enter a voice supported by this model.", type = "error")
      return()
    }
    state$job <- tryCatch(start_narration(selected_path(), path, input$model, voice, module_dir), error = function(error) {
      shiny::showNotification(conditionMessage(error), type = "error", duration = NULL)
      NULL
    })
    if (!is.null(state$job)) state$status <- "Preparing audio in the background…"
  })

  shiny::observe({
    job <- state$job
    shiny::req(job)
    shiny::invalidateLater(700, session)
    if (file.exists(job$progress_file)) {
      progress <- readLines(job$progress_file, warn = FALSE)
      if (length(progress)) state$status <- paste0("Generated chunk ", progress[[1]], "…")
    }
    if (job$process$is_alive()) return()
    succeeded <- isTRUE(job$process$get_exit_status() == 0L) && file.exists(job$output) && file.info(job$output)$size > 0L
    if (succeeded) {
      state$status <- "Audio is ready. Press play below."
      state$refresh <- state$refresh + 1L
      shiny::showNotification("Narration ready", type = "message")
    } else {
      log_path <- paste0(job$output, ".error.log")
      details <- if (file.exists(log_path)) tail(readLines(log_path, warn = FALSE), 3L) else "See the generation log."
      state$status <- "Generation failed. Your article is still available to read."
      shiny::showNotification(paste(details, collapse = " "), type = "error", duration = NULL)
    }
    state$job <- NULL
  })
}

app <- shiny::shinyApp(ui, server)
if (sys.nframe() == 0L) shiny::runApp(app, launch.browser = TRUE)
