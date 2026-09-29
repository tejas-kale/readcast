"""Speech cleanup examples carried forward from the R tests."""

from readcast.narration import split_article
from readcast.preprocess import preprocess_markdown


def test_preparation_removes_chrome_but_keeps_spoken_structure():
    markdown = """---
title: A story
author:
  - "[[Jane Writer]]"
published: 2012-03-01
---

## The first section

![](images/illustration.png)
[Read the full article online](https://example.com/article)
> The big theme is coding agents.
> They write artefacts.

Source: https://example.com/source
The [sites plugin](https://example.com/sites) helps.

```js
console.log('skip me')
```

She paid $450 and saved 25%.
"""
    metadata, script = preprocess_markdown(markdown)
    assert metadata["title"] == "A story"
    assert "By Jane Writer" in script
    assert "Published one March twenty twelve" in script
    assert "The first section." in script
    assert "The big theme is coding agents. They write artefacts." in script
    assert "sites plugin helps" in script
    assert "Please read the code block in the article." in script
    assert "four hundred and fifty dollars" in script
    assert "twenty-five percent" in script
    assert "https://" not in script
    assert "console.log" not in script
    assert "images/" not in script


def test_prose_fence_and_typography_are_spoken():
    markdown = """---
title: Notes
---

```prompt
You are reading a story.
```

It’s rare—really rare…
"""
    _, script = preprocess_markdown(markdown)
    assert "You are reading a story." in script
    assert "It's rare, really rare." in script


def test_indented_blank_lines_do_not_become_empty_narration_chunks():
    indent = " " * 20
    markdown = f"""---
title: A story
---

First paragraph.

{indent}
{indent}

Second paragraph.
"""
    _, script = preprocess_markdown(markdown)
    chunks = split_article(script)
    assert all(chunk.strip() for chunk in chunks)
