# Objnp pass (2026-10-12)

Two residuals the earlier objshape note named were real, and the committed
run-all.sh hid botech of them by omitting the objnp corpus from its pass count.

Residual 1: a-its-gate refused. The j-loop's plural-object guard (line 212)
called isp() on the word after a candidate verb, and a determiner ends in s:
"kept its gate held" made isp("its") true, so the search skipped the real
relative verb and the bounded accept was dropped. Fixed by refusing to consume
a determiner there (the guard attaches to a NP noun, not a determiner).

Residual 2: m-the-police and similar refused by accepting. The object-slot
checks keyed on the word right after a determiner or possessive, so
"kept the green tools failed" never reached the plural head "tools", and
"kept the police/sheep/cattle failed" failed because police has no s/es
suffix and was in none of the plural lists. Fixed by walking a determiner or
possessive plus any adjective chain to the NP head, then reading plurality by
shape OR a new invplural list (police cattle sheep offspring aircraft), and
refusing the bound when the head is plural and the next word is a shaped past
verb NOT in the base verb list (failed, leaked). The base-list carve-out keeps
resultatives "kept her children held" accepting.

Partial cut rejected: the first fix walked every NP head and said plural refused
unconditionally, which flipped herplural accepts (a-her-children). The
next-clause-predicate condition is what separates "kept her children held"
(accept) from "kept her children failed" (refuse), and the vb-list carve-out
carries it because failed/leaked are shaped-only, while held is a base verb.

Verification: run-all.sh pass=409 fail=0 with objnp in the corpus list.
Pre-fix observed 12/19 objnp rows mismatching (a-its-gate refused where accept,
the 11 plural-object rows accepted where refuse, now all pass).
