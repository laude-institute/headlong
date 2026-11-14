p = '../../bin/lesson-overreach-lint'
s = open(p).read()

anchor = r"""bare_scope() {"""
add = r"""# Coreference (soft-spot fix 2026-10-10, follow-on): a coordinated clause
# whose only universal is a bare pronoun and that names no domain of its own
# ranges over the domain of its sibling clause, so it inherits that clause's
# bound ("all three sources were checked and none failed" is bounded over the
# three sources). Anything that widens the domain ("else", "ever", "anywhere",
# "everywhere", "again") or names its own domain ("every later build") is not
# coreferential and is judged on its own.
corefre='^[[:space:]]*(and|but|or|nor|so|then|while|whereas)?[[:space:]]*(none|both|nothing|all)([[:space:]]+(failed|passed|broke|worked|held|moved|changed|stopped|stuck|landed|merged|sent|arrived|ran|went|came|did|was|were|got|made|took|kept|left|fell|rose|cleared|clean|green|red|fine|broken|fixed|open|closed|stale|new|old|slow|fast|wrong|right|late|early|quiet|loud|clear|fuzzy|stable|stuck))([[:space:]]+[a-z]+){0,6}[[:space:]]*$'
coref_widen='(^|[[:space:],])(else|other|others|anywhere|everywhere|ever|again|alike|instead|excluded|exempt)([[:space:],]|$)'
coref_self='\b(every|each|any|none|nothing|all|no)[[:space:]]+[a-z]+'
coref_ok() {
  printf '%s\n' "$1" | grep -qiE "$corefre" || return 1
  printf '%s\n' "$1" | grep -qiE "$coref_widen" && return 1
  printf '%s\n' "$1" | sed -E "s/^[[:space:]]*(and|but|or|nor|so|then|while|whereas)?[[:space:]]*(none|both|nothing|all)\\b/I" | grep -qiE "$coref_self" && return 1
  return 0
}
bare_scope() {"""
assert s.count(anchor) == 1, 'bare_scope anchor count=%d' % s.count(anchor)
s = s.replace(anchor, add, 1)

anchor2 = r"""    clauses=$(printf '%s\n' "$sent" | sed -E 's/[;,]/|/g; s/ (and|but|or|so|then|while|whereas) (the|a|an|this|that|these|those|it|they|we|I|he|she|my|our|your|its|every|each|any|all|no|none|nothing|both|each) /|\2 /gI' | tr '|' '\n')"""
add2 = anchor2 + r"""
    sibbound=0
    while IFS= read -r c || [ -n "$c" ]; do
      [ -z "${c//[[:space:]]/}" ] && continue
      if bound_in "$c"; then sibbound=1; fi
    done <<CLAUSES
$clauses
CLAUSES"""
assert s.count(anchor2) == 1, 'clauses anchor count=%d' % s.count(anchor2)
s = s.replace(anchor2, add2, 1)

anchor3 = r"""      [ "$bare" -eq 1 ] && continue"""
add3 = r"""      [ "$bare" -eq 1 ] && continue
      if [ "$sibbound" -eq 1 ] && coref_ok "$c"; then continue; fi"""
assert s.count(anchor3) == 1, 'judgment anchor count=%d' % s.count(anchor3)
s = s.replace(anchor3, add3, 1)

open(p, 'w').write(s)
print('patched ok')
