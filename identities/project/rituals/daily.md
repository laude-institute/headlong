Daily ritual for {{date}}. This is the one function of this wake, and it
outranks normal work. Carry out all four steps, in order:

1. Curate project/journal.md. Merge or trim redundant entries from today.
   For each entry marked done, check that it meets the definition of done
   for its kind of task (a sourced number, a checked calculation, a
   reviewed section, not just "wrote something"). Re-tag as blocked
   anything that is really blocked. Do not delete history: mark superseded
   entries superseded.
2. Curate project/questions.md. Close questions the project has moved
   past as moot. Apply any human answer, and any default whose date has
   passed, exactly as the charter describes, with a Resolution line. Check
   that every open question has a Default-by line and still reads clearly
   to a human who has not followed the project, since humans see it in
   their status view.
3. Curate project/skills/project/. For each skill ask: was it used this
   week? Is it still accurate? Cut skills that went unused or duplicate
   another, rather than piling them up. When you update a skill because a
   procedure failed, say what failed, not just what the new version is.
4. Write project/daily/{{date}}.md, answering each of these:
   1. What did I actually finish today, in checkable terms? Not "worked on
      X", but what is now true that was not true this morning.
   2. What in today's work am I least confident about, and why?
   3. Did I make any assumption today that is not yet logged in
      project-memory.md or questions.md? Log it now.
   4. Would a skeptical reviewer push back on anything I did today? Answer
      the pushback, or flag it.
   5. Compare today's output with spec.md. Is anything drifting from what
      was actually asked?
   6. Rate today 1 to 5 on "did I make real, checkable progress" (output,
      not effort).
   7. Does anything from today belong in addenda.md? (Usually not.)
   8. Does a crude end-to-end model exist that produces the headline
      number? If not, building it is tomorrow's first task. Is
      project/deliverable.md current with what I know tonight? If
      not, say what it is missing (and fold it in before the next ritual).
   9. The single most valuable next step for tomorrow, toward the
      deliverable, concretely.

The runtime counts the ritual as done when project/daily/{{date}}.md
exists, and commits project/ after the wake.
