# Local model comparison — Qwen 3.5 4B vs Gemma 4 E4B

_Measured 2026-07-29 on an M4 Max / 64 GB, via `llama-server` (llama.cpp, Metal, 32k context, Q5_K_M).
Test input: a real 38-minute Russian work meeting transcript (31 052 characters, ~13k tokens).
Reproduce with `Transcriber --selftest-llm-ab <transcript.md>`._

## Numbers

| | Qwen 3.5 4B | Gemma 4 E4B |
|---|---|---|
| File size (Q5_K_M) | **2.9 GB** | 5.1 GB |
| Model load | 2 s | 2 s |
| Summary (map-reduce over 31k chars) | **22 s** | 29 s |
| Summary with custom prompt | **9 s** | 14 s |
| First Q&A (cold prompt) | 14 s | **13 s** |
| Follow-up Q&A (prompt cached) | 1–2 s | **0–2 s** |

Both are comfortably fast enough for interactive use: after the first question the transcript
stays in the KV cache and answers come back in ~1–2 s. That makes a local
"chat with your transcript" feature clearly viable.

## Quality on Russian

**Qwen 3.5 4B — more thorough, less careful.**
- Richer, more complete action-item extraction; inferred real participant names from context
  (mapped "Speaker 1" → Семён, "Speaker 2" → Макс).
- But garbled proper nouns and terms: "Lenya Pisheva" (should be Лена Пишкова), "Seimen",
  and invented word-forms like «депрэшиону», «пессистентности».
- **Less grounded:** asked how many people took part, it answered "два человека" — the test
  transcript literally labels only one speaker. It inferred rather than read.

**Gemma 4 E4B — cleaner and more faithful.**
- Noticeably better Russian orthography; got «Лена Пишкова» right.
- **More grounded:** for the same speaker-count question it answered "один спикер (Speaker 1)",
  which is literally what the transcript says. It didn't invent.
- Slightly thinner extraction: sticks to "Speaker 1" instead of inferring real names, and lists
  fewer action items.

Both produced correct, well-structured summaries of the actual subject matter (Grazie API
deprecation, the GCP migration, chat-vs-Bhyok prioritisation, the end-of-year support deadline).

## Recommendation

- **Default: Qwen 3.5 4B.** Half the disk, ~25% faster, and the more useful extraction for
  summaries and action items. This is what the app ships as the default download.
- **Offer Gemma 4 E4B as the "more faithful" alternative** for users who care about exact
  wording/names, or for sensitive material where invention is worse than omission.
- **For the future chat feature, groundedness matters more than richness** — invented facts are
  much worse in Q&A than in a summary. Gemma looks better on that axis at this size, so the
  chat feature should either default to Gemma or (better) be re-benchmarked at the 9B/12B tier
  before choosing.

## Caveats

- One transcript, one language, one machine — this is a directional read, not a benchmark suite.
  The groundedness difference showed up on a single question; worth re-testing across more
  transcripts before treating it as settled.
- The test transcript was an older, pre-fix export (1 speaker, junk language tags), which is
  exactly why the speaker-count question was a useful groundedness probe. Diarization quality
  feeds summary quality: garbage speakers in → confused attribution out.
- Larger options (`Qwen 3.5 9B`, `Gemma 4 12B`) are already wired into the model picker but not
  yet benchmarked here.
