# Questions for humans

Humans may look in every few days, but there is no guarantee. Every
question therefore carries a dated default (see "Questions and humans" in
charter.md). The runtime reads the header and the Default-by, Answer and
Resolution lines, so keep their format exact. It stamps a Q<n> id on each
new header. Humans see every open question in their status view, and
project/questions-summary.md lists the closed ones and how each was closed.

## Entry format
### YYYY-MM-DD — short title — STATUS: open | answered | defaulted | moot
Question: the specific thing you need answered, readable by someone who has not followed the project
Why it matters: what depends on it
Blocking: yes | no (yes means a named piece of work is parked on it)
Default: what you will assume and do if nobody answers, and the risk of it
Default-by: YYYY-MM-DD | never
Answer: (a human writes here, or runs: headlong-project answer <name> <Qn> "...". Never you.)
Resolution: (you write this when you close it: "YYYY-MM-DD human answer applied: ..." or "YYYY-MM-DD default applied: ..." or "YYYY-MM-DD moot: ...")

---
