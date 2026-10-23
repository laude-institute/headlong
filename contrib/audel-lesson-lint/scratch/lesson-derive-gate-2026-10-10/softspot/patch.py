p = '../../bin/lesson-overreach-lint'
s = open(p).read()

old_count = r"""countre='\b([0-9]+|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|dozen)\b'"""
new_count = r"""# Count bound (soft-spot fix 2026-10-10): a number only bounds a quantifier
# when it counts the things checked. "PR 156", "step 3", "2026-10-03", "in
# 2026" and the "one" inside "no one" are not counts of checked things and no
# longer bound anything, while "the 35 fixtures all pass" and "the ten
# fixtures I built all pass" still do. The count comes first and a plural
# check noun must follow it within at most three short modifier words, and the
# noun must be plural, because "step 3" names a location and not a count of
# steps checked. Residual shapes this misses, named in the note for
# 2026-10-10: a count trailing its noun ("the fixtures, 35 of them, all
# pass"), and a count-noun pair with an unlisted modifier between them.
numre='([0-9]{1,3}|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|dozen)'
nounplre='(cases|fixtures|samples|runs|steps|checks|instances|windows|builds|machines|branches|tests|readings|days|attempts|examples|records|sessions|files|notes|papers|mutants|drafts|lines|claims|items|entries|rounds|fixes|games|tasks|rows|sends|probes|evidence|verdicts|sentences|sections|findings|loops|rules|lessons|skills|messages|commits|pulls|requests|windows)'
modre='(of|in|from|among|the|a|an|my|our|these|those|new|fresh|total|green|checked|verified|ran|saw|read|built|recorded|named|listed|individual|separate|distinct|full|whole|evidence|deepen|folded|real|extra)'
countre='\b'"$numre"'\b([[:space:]]+'"$modre"'){0,3}[[:space:]]+\b'"$nounplre"'\b'
"""

old_cl = r"""clauses=$(printf '%s\n' "$sent" | tr ',;' '\n')"""
new_cl = r"""clauses=$(printf '%s\n' "$sent" | sed -E 's/[;,]/|/g; s/ (and|but|or|so|then|while|whereas) (the|a|an|this|that|these|those|it|they|we|I|he|she|my|our|your|its|every|each|any|all|no|none|nothing|both|each) /|\2 /gI' | tr '|' '\n')"""

old_soft = r"""# Known soft spots (named in the note for 2026-10-10): the count whitelist is
# open-ended, the bare-scope test is a filler-word strip rather than a parse,
# and the clause split is punctuation-only, so "X and Y holds" with no comma
# is judged as one clause."""
new_soft = r"""# Deepened a third time on 2026-10-10 (soft-spot pass): a count only bounds
# when it counts the things checked (see countre below), and the clause split
# also breaks at a coordinating conjunction when what follows starts with a
# subject, so "in the 2 cases I checked the gate refused and the fix always
# holds" is judged as two clauses. Residual soft spots (note for 2026-10-10):
# the bare-scope test is a filler-word strip rather than a parse, the clause
# split is punctuation and subject-start only so a conjunction joining two
# verb phrases with an unlisted subject is still judged as one clause, and a
# count trailing its noun is not read as a count."""

for anchor, new, tag in ((old_count, new_count, 'countre'),
                         (old_cl, new_cl, 'clauses'),
                         (old_soft, new_soft, 'softspots')):
    n = s.count(anchor)
    assert n == 1, '%s anchor count=%d' % (tag, n)
    s = s.replace(anchor, new)

open(p, 'w').write(s)
print('patched ok')
