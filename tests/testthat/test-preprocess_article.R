source(if (file.exists("R/preprocess_article.R")) "R/preprocess_article.R" else "../../R/preprocess_article.R")
testthat::test_that("front matter becomes a short spoken opening", {
  clipping <- '---\ntitle: "The rise of Narendra Modi"\nauthor:\n  - "[[Vinod K Jose]]"\npublished: 2012-03-01\ntags:\n  - clippings\n---\n\n**ON THE AFTERNOON OF 22 APRIL 1498** ...'
  testthat::expect_identical(spoken_preamble(clipping), "The rise of Narendra Modi. By Vinod K Jose. Published 1 March 2012.\n\n**ON THE AFTERNOON OF 22 APRIL 1498** ...")
  testthat::expect_identical(spoken_preamble("Plain body, no front matter."), "Plain body, no front matter.")
  testthat::expect_identical(spoken_preamble("---\ntitle: Untitled\n---\n\nBody"), "Untitled.\n\nBody")
})

testthat::test_that("images, source references and newsletter furniture disappear", {
  excerpt <- paste0("The token usage chart below shows this sudden adoption surge:\n\n",
                    "![](images/inside-openais-agentic-software-factory-0.png)\n\n",
                    "[Read the full article online](https://example.org/read)\n",
                    "The actual article continues here.")
  cleaned <- remove_images_and_chrome(excerpt)
  testthat::expect_false(stringr::str_detect(cleaned, "images/|Read the full article online"))
  testthat::expect_true(stringr::str_detect(cleaned, "The token usage chart"))
  testthat::expect_true(stringr::str_detect(cleaned, "The actual article continues here."))
  sources <- paste0("Source: https://caravanmagazine.in/reportage/emperor-uncrowned-narendra-modi-profile\n",
                    "[Source](https://example.org/article)\n",
                    "[1]: https://example.org/reference\n",
                    "[^note]: A source note.\n",
                    "The only source of information is Modi himself.[^note][Source](https://example.org/citation)\n",
                    "Visit https://example.org/article for details.\n",
                    "[Sites plugin](https://openai.com/academy/chatgpt-sites/) helps.")
  cleaned_sources <- remove_images_and_chrome(sources)
  testthat::expect_false(stringr::str_detect(cleaned_sources, "https?://|example.org|source note|\\[\\^|\\[1\\]:|\\[Source\\]"))
  testthat::expect_false(stringr::str_detect(cleaned_sources, stringr::fixed("Visit for details")))
  testthat::expect_true(stringr::str_detect(cleaned_sources, stringr::fixed("The only source of information is Modi himself.")))
  testthat::expect_true(stringr::str_detect(cleaned_sources, stringr::fixed("Sites plugin helps.")))
  testthat::expect_identical(remove_images_and_chrome("My brother shared a [Reddit post](<https://reddit.com/r/books>) earlier today."),
                             "My brother shared a Reddit post earlier today.")
  testthat::expect_identical(remove_images_and_chrome("She read a [Wikipedia entry](<https://en.wikipedia.org/wiki/Book_(object)>) yesterday."),
                             "She read a Wikipedia entry yesterday.")
})

testthat::test_that("blockquotes become spoken paragraphs without an editorial cue", {
  excerpt <- "Andrew Ambrosino told me:\n\n> The big theme is coding agents.\n> They write artifacts.\n\nMy commentary.\n\n> A second quote."
  expected <- "Andrew Ambrosino told me:\n\nThe big theme is coding agents. They write artifacts.\n\nMy commentary.\n\nA second quote."
  testthat::expect_identical(cue_blockquotes(excerpt), expected)
  testthat::expect_identical(cue_blockquotes("Before\n> First line.\n>\n> Second paragraph.\nAfter"), "Before\n\nFirst line.\n\nSecond paragraph.\n\nAfter")
  testthat::expect_identical(cue_blockquotes("The figure 2 > 1 is plain prose."), "The figure 2 > 1 is plain prose.")
  testthat::expect_identical(cue_blockquotes("Already plain.\n\nStill plain."), "Already plain.\n\nStill plain.")
})

testthat::test_that("Markdown markers disappear but spoken structure remains", {
  excerpt <- "## 1. Codex takes over at OpenAI\n\n- **Codex takes over at OpenAI.**\n\n> The big theme is coding agents.\n\nSee [the article](https://example.org) by [[Gergely Orosz]]."
  spoken <- speak_markdown_structure(excerpt)
  testthat::expect_true(startsWith(spoken, "1. Codex takes over at OpenAI.\n"))
  testthat::expect_true(stringr::str_detect(spoken, stringr::fixed("\n\nThe big theme is coding agents.\n\n")))
  testthat::expect_false(stringr::str_detect(spoken, stringr::fixed("Quoted passage")))
  testthat::expect_true(stringr::str_detect(spoken, stringr::fixed("See the article by Gergely Orosz.")))
  testthat::expect_false(stringr::str_detect(spoken, "https://|\\[\\["))
  testthat::expect_identical(speak_markdown_structure("Already plain prose."), "Already plain prose.")
  testthat::expect_identical(speak_markdown_structure("**IN THE SECOND WEEK OF JANUARY 2011**"), "In the second week of january 2011")
})

testthat::test_that("speech punctuation is normalised without losing line breaks", {
  testthat::expect_identical(normalise_typography("It’s rare—really rare…\u00a0“Today”"), "It's rare, really rare. \"Today\"")
  testthat::expect_identical(normalise_typography("2019–2023\u200b\nNext line"), "2019 to 2023\nNext line")
  testthat::expect_identical(normalise_typography("Plain ASCII stays.\nSecond line."), "Plain ASCII stays.\nSecond line.")
})

testthat::test_that("integers become English words", {
  testthat::expect_identical(number_words(0), "zero")
  testthat::expect_identical(number_words(25), "twenty-five")
  testthat::expect_identical(number_words(100), "one hundred")
  testthat::expect_identical(number_words(450e9), "four hundred and fifty billion")
  testthat::expect_error(number_words(-1), "non-negative")
})

testthat::test_that("four-digit dates are read as years", {
  testthat::expect_identical(year_words(1498), "fourteen ninety-eight")
  testthat::expect_identical(year_words(1900), "nineteen hundred")
  testthat::expect_identical(year_words(1980), "nineteen eighty")
  testthat::expect_identical(year_words(2002), "two thousand and two")
  testthat::expect_identical(year_words(2012), "twenty twelve")
  testthat::expect_identical(year_words(2026), "two thousand and twenty-six")
  testthat::expect_identical(year_words(42), "forty-two")
})

testthat::test_that("amounts, percentages and dates are spoken", {
  testthat::expect_identical(speak_numbers("$450 billion"), "four hundred and fifty billion dollars")
  testthat::expect_identical(speak_numbers("$1,000 and Rs 1,000"), "one thousand dollars and one thousand rupees")
  testthat::expect_identical(speak_numbers("Rs 20 billion ($409 million)"), "twenty billion rupees (four hundred and nine million dollars)")
  testthat::expect_identical(speak_numbers("25% of 10,000"), "twenty-five percent of ten thousand")
  testthat::expect_identical(speak_numbers("22 April 1498"), "twenty-two April fourteen ninety-eight")
  testthat::expect_identical(speak_numbers("24 September 2026. In 1980, the lottery was rigged."), "twenty-four September two thousand and twenty-six. In nineteen eighty, the lottery was rigged.")
  testthat::expect_identical(speak_numbers("$450 billion and $920 billion; 25% then 60%"), "four hundred and fifty billion dollars and nine hundred and twenty billion dollars; twenty-five percent then sixty percent")
  testthat::expect_identical(speak_numbers("Vikaas Purush and API v2"), "Vikaas Purush and API v2")
})

testthat::test_that("reviewed respellings match terms, not larger words", {
  lexicon <- c("Vikaas Purush" = "Vee-kaas Poo-roosh")
  testthat::expect_identical(apply_respellings("*Vikaas Purush*, or Development Man.", lexicon), "*Vee-kaas Poo-roosh*, or Development Man.")
  testthat::expect_identical(apply_respellings("vikaas purush", lexicon), "Vee-kaas Poo-roosh")
  testthat::expect_identical(apply_respellings("Vikaas Purusha", lexicon), "Vikaas Purusha")
  testthat::expect_identical(apply_respellings("Unchanged without a lexicon."), "Unchanged without a lexicon.")
})

testthat::test_that("the complete pipeline combines each step", {
  clipping <- '---\ntitle: "The rise of Narendra Modi"\nauthor:\n  - "[[Vinod K Jose]]"\npublished: 2012-03-01\n---\n\n**ON THE AFTERNOON OF 22 APRIL 1498**, Vikaas Purush drew a crowd.\n\n![](images/the-rise-of-narendra-modi-0.jpg)\n\n> “The figure was $450 billion.”'
  spoken <- preprocess_markdown(clipping, c("Vikaas Purush" = "Vee-kaas Poo-roosh"))
  testthat::expect_true(startsWith(spoken, "The rise of Narendra Modi. By Vinod K Jose. Published one March twenty twelve."))
  testthat::expect_true(stringr::str_detect(spoken, stringr::fixed("On the afternoon of twenty-two April fourteen ninety-eight")))
  testthat::expect_true(stringr::str_detect(spoken, stringr::fixed("Vee-kaas Poo-roosh drew a crowd.")))
  testthat::expect_true(stringr::str_detect(spoken, stringr::fixed('"The figure was four hundred and fifty billion dollars."')))
  testthat::expect_false(stringr::str_detect(spoken, stringr::fixed("Quoted passage")))
  testthat::expect_false(stringr::str_detect(spoken, "images/|\\[\\["))
  testthat::expect_identical(preprocess_markdown("Plain article text."), "Plain article text.")
})
