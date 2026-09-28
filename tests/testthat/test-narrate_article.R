source("R/narrate_article.R")
testthat::test_that("chunks preserve text and keep a title with its name", {
  text <- "Mr. Smith spoke.  Then left!\n\nA third sentence?"
  chunks <- split_article(text, word_limit = 4L, char_limit = 30L)
  testthat::expect_identical(chunks[[1]], "Mr. Smith spoke.  ")
  testthat::expect_identical(paste0(chunks, collapse = ""), text)
  testthat::expect_identical(split_article("First paragraph.\n\nSecond paragraph."), c("First paragraph.\n\n", "Second paragraph."))
  testthat::expect_error(split_article("One very long sentence.", word_limit = 2L), "One sentence exceeds")
})
