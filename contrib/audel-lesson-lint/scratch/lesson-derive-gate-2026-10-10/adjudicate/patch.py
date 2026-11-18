import pathlib, sys
p = pathlib.Path('bin/lesson-overreach-lint')
s = p.read_text()
edits = []
def rep(label, old, new):
    n = s.count(old)
    if n != 1:
        print(f"MISMATCH {label}: count={n}"); sys.exit(1)
    edits.append((label, old, new))

# M1: predicate word used as noun modifier must name the domain
rep("M1 modifier-reading",
"""    if printf '%s\\n' "$res" | grep -qiE "$coref_self"; then return 0; fi
    printf '%s\\n' "$c" | grep -qiE "^(all|none|nothing|both)\\b[[:space:]]+${predre}\\b" || return 0""",
"""    if printf '%s\\n' "$res" | grep -qiE "$coref_self"; then return 0; fi
    # Adjudication 2026-10-11 (adjrel m-adjkept/known/made/set, lexedge
    # m-{built,read,sent,shown}-* and m-known-rules): a predicate-list word used
    # as a noun modifier ("all kept records failed") matched the bare-predicate
    # test below, so the clause skipped as coreferential and the universal went
    # unjudged. When the word is followed by a plural noun it is the modifier
    # reading: the noun names the domain and the clause is judged on its own.
    if printf '%s\\n' "$res" | grep -qiE "^(${predre})[[:space:]]+(${plnoun})\\b"; then return 0; fi
    printf '%s\\n' "$c" | grep -qiE "^(all|none|nothing|both)\\b[[:space:]]+${predre}\\b" || return 0""")

# M2: bothre misses irregular plurals and caps the modifier chain at three
rep("M2 plnoun irregulars",
"plnoun='([a-z]+(s|es)|people|children|men|women)'",
"plnoun='([a-z]+(s|es)|people|children|men|women|corpora|curricula|criteria|phenomena|analyses|theses|indices|matrices)'")
rep("M2 bothre chain cap",
"[[:space:]]+([a-z]+[[:space:]]+){0,3}('\"$plnoun\"')\\b'",
"[[:space:]]+([a-z]+[[:space:]]+){0,6}('\"$plnoun\"')\\b'")

# M4: s-final singular noun in the subject chain read as a plural object
rep("M4 isp function",
'''    vshape="ed$"
  }
  {''',
'''    vshape="ed$"
  }
  # Adjudication 2026-10-11 (adjrel a-relcl-produced): the plural test was any
  # word ending in s or es, so an s-final singular in the relative subject ("the
  # harness produced") read as a plural object and the bound was dropped. A
  # plural is s-final but not ss/us/is/ics-final.
  function isp(x) { return (x ~ "^(" plural ")$" && x !~ /(ss|us|is|ics)$/) }
  {''')
rep("M4 object-noun check",
'        if (j+1<=n && w[j+1] ~ "^(" plural ")$") continue',
'        if (j+1<=n && isp(w[j+1])) continue')
rep("M4 chain plural check",
'          if (w[k] ~ "^(" plural ")$") npl=1',
'          if (isp(w[k])) npl=1')

# M5: stop list ate possessive and demonstrative determiners in the subject chain
rep("M5 det in chain",
'          if (w[k] ~ stop) continue',
'          if (w[k] ~ stop && w[k] !~ "^(" det ")$") continue')

# M3: the verb search scanned every noun, binding the wrong head
rep("M3 head restriction",
'''    n=0
    for (i=1;i<=NF;i++) { t=tolower($i); gsub(/[^a-z]/,"",t); if (t!="") w[++n]=t }
    for (i=1;i<=n;i++) {
      if (w[i] ~ stop) continue
      if (w[i] !~ "^(" noun ")$") continue''',
'''    n=0
    # Adjudication 2026-10-11 (adjrel m-objrel): the search started at every
    # noun, so a verb inside a later noun owning the relative clause ("all runs
    # failed the checks the log read") bound the wrong head and the universal
    # over the first noun went unbounded. A relative bound attaches to the
    # universal domain noun, the clause first noun, so only that noun heads
    # a search.
    fi=0
    for (q=1;q<=n;q++) { if (w[q] ~ stop) continue; if (w[q] ~ "^(" noun ")$") { fi=q; break } }
    for (i=1;i<=n;i++) {
      if (i != fi) continue
      if (w[i] ~ stop) continue
      if (w[i] !~ "^(" noun ")$") continue''')
rep("M3 modifier cap general",
'''        if (isverb==2) {
          if (first ~ "^(" prep ")$") continue
          if (npl) continue
          if (nf>3) continue
          if (first !~ "^(" det "|" pron "|" noun ")$") continue
        }''',
'''        # Adjudication 2026-10-11 (adjrel m-objrel): the chain-length cap
        # applied only to shape verbs, so a listed verb five words deep bound the
        # head. The cap is general now.
        if (nf>3) continue
        if (isverb==2) {
          if (first ~ "^(" prep ")$") continue
          if (npl) continue
          if (first !~ "^(" det "|" pron "|" noun ")$") continue
        }''')

# M6: shared-VP continuation keeps the sibling's subject
rep("M6 trailing bare universal",
'      if [ "$sibbound" -eq 1 ] && coref_ok "$c"; then continue; fi',
'''      if [ "$sibbound" -eq 1 ] && coref_ok "$c"; then continue; fi
      # Adjudication 2026-10-11 (sharedvp a1/a2/a4, softspot a-andverb): a
      # continuation clause made by the seam split keeps its subject from the
      # sibling ("the 3 fixtures I built and re-ran all pass"), so a bare
      # universal with a listed predicate ending that clause ranges over the
      # sibling's checked set and is not a fresh claim. A widening quantifier
      # ("and re-ran never pass") is not this shape and stays judged.
      if [ "$sibbound" -eq 1 ] && printf '%s\\n' "$c" | grep -qiE "[[:space:]](none|both|nothing|all)[[:space:]]+($predre)[[:space:]]*$"; then continue; fi''')

# predre gains the bare predicate "pass"
rep("predre pass",
"predre='(failed|passed|broke|",
"predre='(failed|passed|pass|broke|")

for label, old, new in edits:
    s = s.replace(old, new, 1)
p.write_text(s)
print("patched:", ", ".join(l for l, _, _ in edits))
