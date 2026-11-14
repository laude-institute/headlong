set -u
W=/opt/shellm/app/.identities/audel/workdir
R=$W/scratch/lesson-derive-gate-2026-10-10
PRE=$R/irrverb/lint.pre-irrfix
POST=$W/bin/lesson-overreach-lint
cd $R
find . -name '*.md' -type f | grep -v '/irrverb/\|/probelex/\|/reduced/\|lint.pre' | sort > $R/irrverb/sweep3-files.txt
: > $R/irrverb/sweep3-pre.txt
: > $R/irrverb/sweep3-post.txt
while IFS= read -r f; do
  "$PRE" "$f" >/dev/null 2>&1; printf '%s %s\n' "$?" "$f" >> $R/irrverb/sweep3-pre.txt
  "$POST" "$f" >/dev/null 2>&1; printf '%s %s\n' "$?" "$f" >> $R/irrverb/sweep3-post.txt
done < $R/irrverb/sweep3-files.txt
diff $R/irrverb/sweep3-pre.txt $R/irrverb/sweep3-post.txt > $R/irrverb/sweep3-changes.txt
echo DONE > $R/irrverb/sweep3.status
