#!/usr/bin/env bash
# Fixture-based tests for scripts/resolve-versions.sh.
# Runs fully offline: every upstream endpoint is pointed at a local file or a
# local git repository via the *_URL environment overrides.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$here/resolve-versions.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

pass=0
fail=0

# --- fixtures -----------------------------------------------------------------
cat > "$tmp/release.json" <<'JSON'
{"tag_name": "v1.104.5", "prerelease": false}
JSON

# go.dev/dl/?mode=json shape: newest first, release candidates are stable=false.
cat > "$tmp/go-dl.json" <<'JSON'
[
  {"version": "go1.28rc1", "stable": false},
  {"version": "go1.27.3", "stable": true},
  {"version": "go1.26.10", "stable": true}
]
JSON

cat > "$tmp/go.mod" <<'GOMOD'
module tailscale.com

go 1.27.1

require (
	filippo.io/mkcert v1.4.4
)
GOMOD

cat > "$tmp/go-toolchain.mod" <<'GOMOD'
module tailscale.com

go 1.27.1

toolchain go1.27.9
GOMOD

# A tiny git repo with an annotated tag so `git ls-remote` returns a peeled ref.
git init -q "$tmp/repo"
git -C "$tmp/repo" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m init
git -C "$tmp/repo" -c user.name=t -c user.email=t@example.com tag -a v1.104.5 -m v1.104.5
expected_commit="$(git -C "$tmp/repo" rev-parse v1.104.5^{commit})"

# --- helpers ------------------------------------------------------------------
run_script() {
  # Everything the script needs is passed via env; $@ are extra env overrides.
  env -i PATH="$PATH" HOME="$HOME" \
    TS_RELEASE_URL="file://$tmp/release.json" \
    TS_GOMOD_URL="file://$tmp/go.mod" \
    TS_GIT_URL="$tmp/repo" \
    GO_DL_URL="file://$tmp/go-dl.json" \
    "$@" bash "$script"
}

get() { # get <key> <output>
  printf '%s\n' "$2" | sed -n "s/^$1=//p"
}

check() { # check <name> <expected> <actual>
  if [ "$2" = "$3" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf 'FAIL %s: expected %q, got %q\n' "$1" "$2" "$3" >&2
  fi
}

# --- tests --------------------------------------------------------------------
out="$(run_script)"
check "latest release tag"            "v1.104.5"          "$(get ts_version "$out")"
check "minor tag"                     "v1.104"            "$(get ts_minor "$out")"
check "peeled tag commit"             "$expected_commit"  "$(get ts_commit "$out")"
check "go.mod minimum"                "1.27.1"            "$(get go_min "$out")"
check "latest stable go (rc ignored)" "1.27.3"            "$(get go_latest "$out")"
check "chosen go = latest stable"     "1.27.3"            "$(get go_version "$out")"
check "image tag"                     "v1.104.5-go1.27.3" "$(get image_tag "$out")"

out="$(run_script TS_GOMOD_URL="file://$tmp/go-toolchain.mod")"
check "toolchain directive raises min" "1.27.9" "$(get go_min "$out")"
check "chosen go never below minimum" "1.27.9" "$(get go_version "$out")"

out="$(run_script TS_VERSION_OVERRIDE=v1.104.5 GO_VERSION_OVERRIDE=1.26.10)"
check "go override wins"               "1.26.10"            "$(get go_version "$out")"
check "image tag with override"        "v1.104.5-go1.26.10" "$(get image_tag "$out")"

out="$(run_script TS_VERSION_OVERRIDE=1.104.5)"
check "override without v prefix is normalised" "v1.104.5" "$(get ts_version "$out")"

if run_script TS_VERSION_OVERRIDE='v1.104.5; rm -rf /' >/dev/null 2>&1; then
  check "malformed tailscale version rejected" "exit!=0" "exit=0"
else
  pass=$((pass + 1))
fi

if run_script GO_VERSION_OVERRIDE='latest' >/dev/null 2>&1; then
  check "malformed go version rejected" "exit!=0" "exit=0"
else
  pass=$((pass + 1))
fi

# GITHUB_OUTPUT gets the same key=value lines.
run_script GITHUB_OUTPUT="$tmp/gh-output" >/dev/null
check "GITHUB_OUTPUT written" "v1.104.5-go1.27.3" "$(get image_tag "$(cat "$tmp/gh-output")")"

echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
