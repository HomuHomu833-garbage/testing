#!/usr/bin/env bash
# report.sh NAME: copy this job's results file to results-NAME.txt and add it to the job summary
n=$1; out="results-$n.txt"
f=$(ls "${RUNNER_TEMP:-/tmp}"/w/results-*.txt 2>/dev/null | head -n1)
if [ -n "$f" ]; then cp "$f" "$out"; else : > "$out"; fi
grep -q '^\(OK\|SKIP\)' "$out" || echo "FAIL  [$n] no results (the test did not run or stopped before its first check)" >> "$out"
{
  echo "### $n"
  echo "OK=$(grep -c '^OK' "$out") FAIL=$(grep -c '^FAIL' "$out") SKIP=$(grep -c '^SKIP' "$out")"
  echo '```'; grep -E '^(FAIL|SKIP)' "$out" | cut -c1-300; echo '```'
} >> "${GITHUB_STEP_SUMMARY:-/dev/stdout}"
! grep -q '^FAIL' "$out"
