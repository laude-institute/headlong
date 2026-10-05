Final ritual: the run's end date has passed. This is the one function of
this wake (or of several, if it needs them), and it outranks everything
except a human answer. The runtime counts it done when
project/reports/final.md exists.

1. Final cold-eyes review. If project/reviews/final.md does not exist,
   create it with:
       blind --role coldeyes --out project/reviews/final.md
2. Fix what the review found, where you can do so honestly in a wake or
   two. Mark everything else as a caveat in the deliverable.
3. Finalize project/deliverable.md. Every number sourced or marked as a
   placeholder, every default applied without a human named as such, and
   a Status section that says plainly what is solid and what is not.
4. Write project/reports/final.md for the humans who asked:
   - The answer, in three to five plain sentences, with its uncertainty.
   - What was completed, pointing at the deliverable and the journal.
   - Every question and how it closed (human answer, default or moot),
     and every question still open (project/questions-summary.md has
     the list).
   - The final cold-eyes review result, including anything you disagree
     with and why.
   - What remains undone, and what you would do next with more time.
5. Set STATE to done: printf 'done\nRun ended; final report written.\n' > project/STATE
