#!/usr/bin/env bash
# Probe: source lint definitions, then for each clause of a fixture report
# which mechanism (bound_in / coref_ok / domain_self / bare_scope / none) decides it.
set -u
B="$(cd "$(dirname "$0")/.." && pwd)"
. "$B/adjudicate/lint-defs.sh"
for f in "$@"; do
  echo "===== $f"
  line=$(grep -viE '^(evidence|file |contains |absent |cmd )' "$f" | head -1)
  body=$(printf '%s\n' "$line" | sed -E 's/^[[:space:]]*(lesson|rule|habit|norm)[[:space:]]*:[[:space:]]*//I')
  while IFS= read -r sent; do
    [ -z "${sent//[[:space:]]/}" ] && continue
    clauses=$(printf '%s\n' "$sent" | sed -E 's/\bso far\b/SOFARBOUND/gI; s/\bfrom then on\b/FROMTHENONG/gI; s/\bso that\b/and/gI; s/\bso as\b/and/gI; s/[;,]/|/g; s/[[:space:]](and|but|or|nor)[[:space:]]/|/gI; s/ (so|then|while|whereas) (the|a|an|this|that|these|those|it|they|we|I|he|she|my|our|your|its|every|each|any|all|no|none|nothing|both) /|\2 /gI; s/[[:space:]](so|then|while|whereas)[[:space:]]/|/gI' | tr '|' '\n' | sed 's/SOFARBOUND/so far/g; s/FROMTHENONG/from then on/g')
    while IFS= read -r c; do
      [ -z "${c//[[:space:]]/}" ] && continue
      hits=$(hits_of "$c")
      [ -z "$hits" ] && continue
      tag="UNJUDGED (refuse)"
      bound_in "$c" && tag="bound_in"
      [ "$tag" = "UNJUDGED (refuse)" ] && coref_ok "$c" && tag="coref_ok"
      [ "$tag" = "UNJUDGED (refuse)" ] && domain_self "$c" && tag="domain_self-shape"
      [ "$tag" = "UNJUDGED (refuse)" ] && bare_scope "$c" && tag="bare_scope"
      relclause_ok "$c" && rc=yes || rc=no
      printf '  hits=%-8s relcl=%-3s %-22s | %s\n' "$hits" "$rc" "$tag" "$c"
    done <<CLAUSES
$clauses
CLAUSES
  done <<SENTS
$(printf '%s\n' "$body" | tr '.!?' '\n')
SENTS
done
