"""
Finales lexikon: 11 buckets (10 + notify). token-weise, wortart-gefiltert.
Generiert priv/semantic/verb_model.json reproduzierbar.
"""
import re, json, numpy as np
from collections import Counter
from model2vec import StaticModel
m=StaticModel.from_pretrained("minishlab/potion-multilingual-128M")
emb,tok=m.embedding,m.tokenizer

PROTO = {
    "fetch":     ["fetch","get","list","load","find","retrieve","query","reload","return","read"],
    "build":     ["build","create","make","construct","assemble","prepare","generate","produce"],
    "validate":  ["validate","check","verify","ensure","assert","confirm","guard"],
    "format":    ["format","render","humanize","display","stringify","print"],
    "normalize": ["normalize","trim","clean","sanitize","canonicalize","finalize","tokenize","escape"],
    "compute":   ["compute","calculate","sum","aggregate","summarize","total","tally","count","accumulate","consolidate","analyze","reduce","measure"],
    "filter":    ["filter","reject","exclude","keep","prune","select","drop","remove","delete"],
    "group":     ["group","partition","bucket","cluster","chunk","split","batch"],
    "extract":   ["extract","parse","decode","pluck","capture","encode"],
    "update":    ["update","merge","replace","insert","assign","patch","apply","set","expand","attach"],
    "notify":    ["notify","send","broadcast","publish","emit","dispatch","deliver","announce","inform"],
}
def tv(w): return [emb[i].astype(np.float32) for i in tok.encode(w).ids]
PW={w for ws in PROTO.values() for w in ws}; lexnp={w:tv(w) for w in PW}
def pvec(ws):
    v=[]; [v.extend(lexnp[w]) for w in ws]; a=np.mean(v,axis=0); return a/(np.linalg.norm(a)+1e-9)
proto={k:pvec(ws) for k,ws in PROTO.items()}; pn=list(proto); P=np.stack([proto[n] for n in pn])
T,M,ADMIT=0.35,0.08,0.45
NOUN=("tion","sion","ment","ness","ity","ance","ence","ation")
STOP={"block","blocks","input","dump","builtin","item","items","row","rows","node","nodes","value","values","name","names","type","types","label","key","keys","body","status","error","errors","total","totals","count","counts","patch","patches","param","params","text","var","vars","module","field","fields","clause","clauses","picker","mass","unit","brand","asset"}
def verbish(w):
    if w in PW: return True
    if w in STOP: return False
    if w.endswith(("?","!")): return False
    if w.endswith("ed") and len(w)>5: return False
    if w.endswith("s") and not w.endswith("ss"): return False
    if any(w.endswith(s) for s in NOUN): return False
    return True
def cls(w,t):
    z=tv(w)
    if not z: return None
    v=np.mean(z,axis=0); v=v/(np.linalg.norm(v)+1e-9); s=P@v; o=np.argsort(-s)
    return pn[o[0]] if s[o[0]]>=t and s[o[0]]-s[o[1]]>=M else None
import glob
names=[l.strip() for l in open("fn_names.txt") if l.strip()]
SKIP={"do","maybe","__","built","in"}
def cand(n): return [w for w in re.split(r"[_]+",n.split(".")[-1]) if w and w not in SKIP and len(w)>2]
freq=Counter(w for n in names for w in cand(n)); kept={}
for w,c in freq.items():
    if c<2 or not verbish(w): continue
    b=cls(w,ADMIT)
    if b: kept[w]=b
allw=sorted(PW|set(kept))
lexicon={w:[v.tolist() for v in tv(w)] for w in allw}
out={"dim":256,"lexicon":lexicon,"prototypes":{k:v.tolist() for k,v in proto.items()},"thresh":T,"margin":M}
json.dump(out, open("/Users/andreassolleder/dev/n42-refactors/priv/semantic/verb_model.json","w"))
print(f"11-bucket: {len(lexicon)} wörter, {len(pn)} buckets, {len(json.dumps(out))/1e6:.2f} MB")
print(f"buckets: {pn}")
print(f"notify-wörter: {sorted(w for w,b in kept.items() if b=='notify')}")
# sanity für tests
for w in ["broadcast_changes","dispatch_event","accumulate_rows","do_thing"]:
    print(f"  {w} -> {cls(w.split('_')[0] if False else w, T)}")
