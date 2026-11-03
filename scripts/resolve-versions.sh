#!/usr/bin/env bash
# resolve-versions.sh — decide which Tailscale and Go versions to build.
#
# Prints key=value lines to stdout and, when GITHUB_OUTPUT is set, appends the
# same lines there so a workflow job can expose them as outputs.
#
#   ts_version  Tailscale git tag to build, e.g. v1.104.5 (latest GitHub release)
#   ts_minor    floating tag, e.g. v1.104
#   ts_commit   commit the tag points at (peeled if annotated)
#   go_min      minimum Go required by that tag's go.mod (go / toolchain directive)
#   go_latest   newest stable Go release according to go.dev
#   go_version  Go version to build with: max(go_latest, go_min) unless overridden
#   image_tag   "<ts_version>-go<go_version>", the unique key of one build
#
# Overrides (empty = auto):
#   TS_VERSION_OVERRIDE  e.g. v1.104.5 (a leading "v" is added if missing)
#   GO_VERSION_OVERRIDE  e.g. 1.27.3
#
# Endpoint overrides exist so the script can be tested offline:
#   TS_RELEASE_URL  JSON with .tag_name   (default: GitHub "latest release" API)
#   TS_GOMOD_URL    raw go.mod            (default: raw.githubusercontent.com at the tag;
#                                          a literal %s is replaced by the tag)
#   TS_GIT_URL      git remote for ls-remote
#   GO_DL_URL       go.dev/dl JSON
set -euo pipefail

TS_REPO="${TS_REPO:-tailscale/tailscale}"
TS_RELEASE_URL="${TS_RELEASE_URL:-https://api.github.com/repos/${TS_REPO}/releases/latest}"
TS_GOMOD_URL="${TS_GOMOD_URL:-https://raw.githubusercontent.com/${TS_REPO}/%s/go.mod}"
TS_GIT_URL="${TS_GIT_URL:-https://github.com/${TS_REPO}.git}"
GO_DL_URL="${GO_DL_URL:-https://go.dev/dl/?mode=json}"
TS_VERSION_OVERRIDE="${TS_VERSION_OVERRIDE:-}"
GO_VERSION_OVERRIDE="${GO_VERSION_OVERRIDE:-}"

ts_re='^v[0-9]+\.[0-9]+\.[0-9]+$'
go_re='^[0-9]+\.[0-9]+(\.[0-9]+)?$'

die() { echo "resolve-versions: $*" >&2; exit 1; }

fetch() {
  local url="$1"
  local -a auth=()
  # Authenticate GitHub API calls when a token is available (higher rate limit).
  if [[ "$url" == https://api.github.com/* && -n "${GITHUB_TOKEN:-}" ]]; then
    auth=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
  fi
  curl -fsSL --retry 3 --retry-delay 2 "${auth[@]}" "$url"
}

# max_version a b -> the larger of two dotted versions
max_version() { printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1; }

# --- Tailscale version --------------------------------------------------------
if [[ -n "$TS_VERSION_OVERRIDE" ]]; then
  ts_version="$TS_VERSION_OVERRIDE"
  [[ "$ts_version" == v* ]] || ts_version="v${ts_version}"
else
  ts_version="$(fetch "$TS_RELEASE_URL" | jq -r '.tag_name // empty')"
  [[ -n "$ts_version" ]] || die "could not read tag_name from ${TS_RELEASE_URL}"
fi
[[ "$ts_version" =~ $ts_re ]] || die "unexpected Tailscale version '${ts_version}'"
ts_minor="${ts_version%.*}"

# Commit the tag points at. Annotated tags also list a peeled "^{}" line; prefer it.
refs="$(git ls-remote --tags "$TS_GIT_URL" "refs/tags/${ts_version}" "refs/tags/${ts_version}^{}")"
ts_commit="$(printf '%s\n' "$refs" | awk '$2 ~ /\^\{\}$/ {print $1}' | head -n1)"
if [[ -z "$ts_commit" ]]; then
  ts_commit="$(printf '%s\n' "$refs" | awk '{print $1}' | head -n1)"
fi
[[ "$ts_commit" =~ ^[0-9a-f]{40}$ ]] || die "could not resolve commit for tag ${ts_version}"

# --- Go version ---------------------------------------------------------------
# shellcheck disable=SC2059 # the URL template intentionally carries a %s
gomod="$(fetch "$(printf "$TS_GOMOD_URL" "$ts_version")")"
go_directive="$(printf '%s\n' "$gomod" | awk '$1 == "go" {print $2; exit}')"
toolchain_directive="$(printf '%s\n' "$gomod" | awk '$1 == "toolchain" {sub(/^go/, "", $2); print $2; exit}')"
[[ -n "$go_directive" ]] || die "no 'go' directive found in go.mod for ${ts_version}"
go_min="$go_directive"
if [[ -n "$toolchain_directive" ]]; then
  go_min="$(max_version "$go_min" "$toolchain_directive")"
fi

go_latest="$(fetch "$GO_DL_URL" | jq -r '[.[] | select(.stable == true)][0].version // empty')"
go_latest="${go_latest#go}"
[[ "$go_latest" =~ $go_re ]] || die "unexpected latest Go version '${go_latest}' from ${GO_DL_URL}"

if [[ -n "$GO_VERSION_OVERRIDE" ]]; then
  go_version="$GO_VERSION_OVERRIDE"
else
  go_version="$(max_version "$go_latest" "$go_min")"
fi
[[ "$go_version" =~ $go_re ]] || die "unexpected Go version '${go_version}'"

image_tag="${ts_version}-go${go_version}"

# --- output -------------------------------------------------------------------
emit() {
  printf '%s=%s\n' "$1" "$2"
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    printf '%s=%s\n' "$1" "$2" >> "$GITHUB_OUTPUT"
  fi
}
emit ts_version "$ts_version"
emit ts_minor "$ts_minor"
emit ts_commit "$ts_commit"
emit go_min "$go_min"
emit go_latest "$go_latest"
emit go_version "$go_version"
emit image_tag "$image_tag"
