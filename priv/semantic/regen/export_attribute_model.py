"""
Regenerates attribute_model.json — the trained adjective classifier for filter
predicate fields. Needs: model2vec, scikit-learn, numpy.

Trains a logistic regression over the static embedding with a FEW positive
adjectives per class and MANY real non-attribute code words labelled `none`, so
the model defaults to :none and only fires on words near the adjective set.

Run from a dir containing fn_names.txt + whk_fn_names.txt (the negative word
corpus — any large Elixir function-name dump works).
"""
import re, json
import numpy as np
from sklearn.linear_model import LogisticRegression
from model2vec import StaticModel

m = StaticModel.from_pretrained("minishlab/potion-multilingual-128M")
emb, tok = m.embedding, m.tokenizer

# Positive: fixed adjective classes, each with synonyms (the training labels).
ADJ_CLASSES = {
    "active":   ["active", "enabled", "live", "running", "online"],
    "inactive": ["inactive", "disabled", "archived", "offline", "suspended"],
    "stale":    ["stale", "expired", "outdated", "old", "obsolete"],
    "recent":   ["recent", "new", "latest", "fresh", "newest"],
    "pending":  ["pending", "unconfirmed", "waiting", "queued", "draft"],
    "deleted":  ["deleted", "removed", "trashed", "discarded"],
    "selected": ["selected", "chosen", "picked", "checked", "marked"],
    "valid":    ["valid", "verified", "approved", "confirmed"],
    "invalid":  ["invalid", "rejected", "failed", "broken"],
    "visible":  ["visible", "shown", "public", "displayed"],
    "hidden":   ["hidden", "private", "internal", "secret"],
    "empty":    ["empty", "blank", "missing", "null"],
}
# Input lexicon = the adjective synonyms plus real boolean field names; a field
# outside this set yields :none in Elixir (correct — unknown field, no attr).
LEXICON_WORDS = sorted({w for ws in ADJ_CLASSES.values() for w in ws} |
                       {"visibility", "drafts"})

def token_vecs(w):
    return [emb[i].astype(np.float32) for i in tok.encode(w).ids]

def vec(w):
    v = np.mean([np.array(t) for t in token_vecs(w)], axis=0).astype(np.float32)
    return v / (np.linalg.norm(v) + 1e-9)

# Negatives: frequent real code words that are NOT attributes.
names = open("fn_names.txt").read() + open("whk_fn_names.txt").read()
from collections import Counter
freq = Counter(w for w in re.findall(r"[a-z]+", names) if len(w) > 2)
adjset = {w for ws in ADJ_CLASSES.values() for w in ws}
negatives = [w for w, _ in freq.most_common(800) if w not in adjset][:600]

X, y = [], []
for cls, words in ADJ_CLASSES.items():
    for w in words:
        X.append(vec(w)); y.append(cls)
for w in negatives:
    X.append(vec(w)); y.append("none")

clf = LogisticRegression(max_iter=2000, C=1.0, class_weight="balanced")
clf.fit(np.array(X), y)

out = {
    "dim": 256,
    "classes": [str(c) for c in clf.classes_],
    "W": clf.coef_.astype(np.float32).tolist(),
    "b": clf.intercept_.astype(np.float32).tolist(),
    "none_floor": 0.5,
    "lexicon": {w: [t.tolist() for t in token_vecs(w)] for w in LEXICON_WORDS},
}
with open("../attribute_model.json", "w") as f:
    json.dump(out, f)
print(f"attribute_model.json: {len(out['classes'])} classes, "
      f"{len(out['lexicon'])} input words")
