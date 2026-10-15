set -u
W=/opt/shellm/app/.identities/audel/workdir
R=$W/scratch/lesson-derive-gate-2026-10-10
PRE=$R/irrverb/lint.pre-irrfix
POST=$W/bin/lesson-overreach-lint
cd $R
find . -name '*.md' -type f | grep -v '/irrverb/\|/probelex/\|/reduced/\|lint.pre' | sort > $R/irrverb/sweep2-files.txt
: > $R/irrverb/sweep-pre.txt
: > $R/irrverb/sweep-post.txt
while IFS= read -r f; do
  "$PRE" "$f" >/dev/null 2>&1; printf '%s %s\n' "$?" "$f" >> $R/irrverb/sweep-pre.txt
  "$POST" "$f" >/dev/null 2>&1; printf '%s %s\n' "$?" "$f" >> $R/irrverb/sweep-post.txt
done < $R/irrverb/sweep2-files.txt
diff $R/irrverb/sweep-pre.txt $R/irrverb/sweep-post.txt > $R/irrverb/sweep-changes.txt
echo DONE > $R/irrverb/sweep.status
