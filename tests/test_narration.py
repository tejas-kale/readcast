from pathlib import Path

import readcast.narration as narration


def test_split_article_preserves_paragraphs_and_keeps_titles() -> None:
    text = "Mr. Smith spoke.  Then left!\n\nA third sentence?"
    chunks = narration.split_article(text, word_limit=4, char_limit=30)
    assert chunks[0] == "Mr. Smith spoke.  "
    assert "".join(chunks) == text
    assert narration.split_article("First paragraph.\n\nSecond paragraph.") == [
        "First paragraph.\n\n", "Second paragraph."
    ]


def test_split_rejects_a_sentence_over_the_limit() -> None:
    try:
        narration.split_article("One very long sentence.", word_limit=2)
    except ValueError as error:
        assert "One sentence exceeds" in str(error)
    else:
        raise AssertionError("expected oversized sentence to be rejected")


def test_narration_reuses_chunks_and_completed_mp3_across_outputs(
    tmp_path: Path, monkeypatch
) -> None:
    generated = []

    def fake_generate(text: str, model: str, voice: str) -> bytes:
        generated.append((text, model, voice))
        return f"mp3:{text}".encode()

    def fake_join(paths, output, pauses, pause_seconds):
        output.write_bytes(b"|".join(path.read_bytes() for path in paths))

    monkeypatch.setattr(narration, "generate_chunk", fake_generate)
    monkeypatch.setattr(narration, "_join_mp3s", fake_join)
    cache = tmp_path / "cache"
    first = narration.narrate_chunks(["one", "two"], tmp_path / "a.mp3", cache_dir=cache)
    second = narration.narrate_chunks(["one", "two"], tmp_path / "b.mp3", cache_dir=cache)
    assert first.read_bytes() == second.read_bytes()
    assert len(generated) == 2
    assert generated[0][1:] == (
        narration.DEFAULT_MODEL, "en-US-Harper:MAI-Voice-2"
    )


def test_changed_chunk_reuses_unchanged_chunk_and_invalidates_final_mp3(
    tmp_path: Path, monkeypatch
) -> None:
    generated = []

    def fake_generate(text: str, model: str, voice: str) -> bytes:
        generated.append(text)
        return f"mp3:{text}".encode()

    monkeypatch.setattr(narration, "generate_chunk", fake_generate)
    monkeypatch.setattr(
        narration, "_join_mp3s",
        lambda paths, output, pauses, pause_seconds: output.write_bytes(
            b"|".join(path.read_bytes() for path in paths)
        ),
    )
    cache = tmp_path / "cache"
    narration.narrate_chunks(["one", "two"], tmp_path / "a.mp3", cache_dir=cache)
    narration.narrate_chunks(["one", "changed"], tmp_path / "b.mp3", cache_dir=cache)
    assert generated == ["one", "two", "changed"]
