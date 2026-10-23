W=/opt/shellm/app/.identities/audel/workdir
R=$W/scratch/lesson-derive-gate-2026-10-10
bash $R/run-all.sh > $R/irrverb/suite.txt 2>&1
echo $? > $R/irrverb/suite.rc
