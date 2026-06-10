# Semantic naming models

Frozen model assets for the semantic helper-naming classifiers. Both are
distilled once from [`potion-multilingual-128M`](https://huggingface.co/minishlab/potion-multilingual-128M)
(a Model2Vec static embedding) and loaded at compile time — no neural runtime,
no Python, no extra Elixir dependency. A word's vector is the mean of its token
vectors; the JSON stores per-word token vectors so the Elixir mean is
bit-identical to the reference encoder for any word in the lexicon.

## `verb_model.json` — `Number42.Refactors.Semantic`

Maps a call name to one of 11 verb buckets (`fetch`, `build`, `validate`,
`format`, `normalize`, `compute`, `filter`, `group`, `extract`, `update`,
`notify`) by cosine-matching against frozen prototype vectors, gated by an
absolute score + margin over the runner-up. Used as the fallback behind
`HelperNaming`'s `@verb_rules` stem table — the table always wins; the model
only catches synonyms the table doesn't enumerate.

Shape: `{dim, lexicon: word -> [token_vec], prototypes: bucket -> vec, thresh,
margin}`.

## `attribute_model.json` — `Number42.Refactors.AttributeClassifier`

A trained logistic-regression classifier (not nearest-prototype) over the same
embedding, mapping a filter predicate's field name to an adjective attribute
(`active`, `deleted`, `stale`, …) or `:none`. Fit against many real
non-attribute code words as `:none` so it defaults to "not an attribute" and
only fires on words near the adjective set.

Shape: `{dim, classes, W (12+1 × 256), b, none_floor, lexicon: word ->
[token_vec]}`. Classification is `argmax(softmax(W·x + b))`, gated by
`none_floor`.

## Regenerating

The assets are produced by the export scripts in `regen/` (Python, needs
`model2vec` + `scikit-learn`). They are deterministic given the same source
model and word lists. Vectors are rounded to 3 decimals — measured to leave
every classification unchanged while cutting the JSON ~65% (the confidence
gates have far more margin than 1e-3). The vectors themselves are not meant for
human review; trust the regen scripts and the parity tests, not the diff. The word lists / prototypes are curated against measured
coverage on real code (n42-refactors, position-db, the whk umbrella) — adding
words beyond the verb vocabulary's ~100 was measured to add noise, not
coverage. See the scripts for the exact lists and the filtering rationale.
