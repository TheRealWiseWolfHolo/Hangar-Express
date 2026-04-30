#!/bin/sh

set -eu

MODE="${1:-repo}"

forbidden_path_pattern='(^|/)(Packaging\.log|DistributionSummary\.plist|ExportOptions\.plist|embedded\.mobileprovision|.*\.ipa|.*\.mobileprovision|.*\.xcarchive(/.*)?)$'
forbidden_content_pattern='X-Apple-GS-Token|DSESSIONID|-----BEGIN (RSA |DSA |EC |OPENSSH )?PRIVATE KEY-----|BEGIN OPENSSH PRIVATE KEY|AuthKey_[A-Za-z0-9._-]+\.p8'

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT INT TERM

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

grep_excluding_hygiene_script() {
  grep -Ev '^scripts/check_repo_hygiene\.sh$'
}

find_forbidden_paths() {
  grep -En "$forbidden_path_pattern" "$1"
}

find_forbidden_content_in_file() {
  grep -En "$forbidden_content_pattern" "$1"
}

is_exempt_content_path() {
  [ "${1:-}" = "scripts/check_repo_hygiene.sh" ]
}

scan_repo() {
  tracked_list="$tmpdir/tracked.txt"
  git ls-files | grep_excluding_hygiene_script > "$tracked_list"

  forbidden_paths="$tmpdir/forbidden-paths.txt"
  if find_forbidden_paths "$tracked_list" > "$forbidden_paths"; then
    printf '%s\n' 'Forbidden tracked export or signing artifacts detected:' >&2
    cat "$forbidden_paths" >&2
    exit 1
  fi

  if git grep -n -I -e "$forbidden_content_pattern" -- . ':(exclude)scripts/check_repo_hygiene.sh' > "$tmpdir/forbidden-content.txt"; then
    printf '%s\n' 'Sensitive content markers detected in tracked files:' >&2
    cat "$tmpdir/forbidden-content.txt" >&2
    exit 1
  fi
}

scan_staged() {
  staged_list="$tmpdir/staged.txt"
  git diff --cached --name-only --diff-filter=ACMR > "$staged_list"

  [ -s "$staged_list" ] || exit 0

  forbidden_paths="$tmpdir/forbidden-staged-paths.txt"
  if find_forbidden_paths "$staged_list" > "$forbidden_paths"; then
    printf '%s\n' 'Forbidden export or signing artifacts are staged for commit:' >&2
    cat "$forbidden_paths" >&2
    exit 1
  fi

  while IFS= read -r path; do
    [ -n "$path" ] || continue
    if is_exempt_content_path "$path"; then
      continue
    fi
    staged_copy="$tmpdir/staged-file"
    git show ":$path" > "$staged_copy" 2>/dev/null || continue
    if find_forbidden_content_in_file "$staged_copy" > "$tmpdir/staged-hit.txt"; then
      printf '%s\n' "Sensitive content markers detected in staged file: $path" >&2
      cat "$tmpdir/staged-hit.txt" >&2
      exit 1
    fi
  done < "$staged_list"
}

case "$MODE" in
  repo)
    scan_repo
    ;;
  --staged|staged)
    scan_staged
    ;;
  *)
    fail "Unsupported mode: $MODE"
    ;;
esac

printf '%s\n' 'Repository hygiene check passed.'
