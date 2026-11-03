#!/bin/sh
# Entrypoint for the derper image.
#
#   no arguments          -> run derper configured from DERP_* environment variables
#   arguments starting -  -> environment-derived flags first, then yours (yours win)
#   anything else         -> executed as-is (e.g. `sh`, `derper --version`)
set -eu

case "${1:-}" in
  "" | -*) ;;
  derper) shift; exec /usr/local/bin/derper "$@" ;;
  *) exec "$@" ;;
esac

# DERP_DOMAIN is accepted as an alias of DERP_HOSTNAME for compatibility with
# other popular derper images.
hostname="${DERP_HOSTNAME:-${DERP_DOMAIN:-}}"

set -- \
  -c "${DERP_CONFIG:-/var/lib/derper/derper.key}" \
  -a "${DERP_ADDR:-:443}" \
  --http-port "${DERP_HTTP_PORT:-80}" \
  --stun="${DERP_STUN:-true}" \
  --stun-port "${DERP_STUN_PORT:-3478}" \
  --certmode "${DERP_CERT_MODE:-letsencrypt}" \
  --certdir "${DERP_CERT_DIR:-/app/certs}" \
  --verify-clients="${DERP_VERIFY_CLIENTS:-false}" \
  "$@"

[ -n "$hostname" ]                    && set -- --hostname "$hostname" "$@"
[ -n "${DERP_VERIFY_CLIENT_URL:-}" ]  && set -- --verify-client-url "$DERP_VERIFY_CLIENT_URL" "$@"
[ -n "${DERP_MESH_WITH:-}" ]          && set -- --mesh-with "$DERP_MESH_WITH" "$@"
[ -n "${DERP_MESH_PSK_FILE:-}" ]      && set -- --mesh-psk-file "$DERP_MESH_PSK_FILE" "$@"
[ -n "${DERP_ACME_EMAIL:-}" ]         && set -- --acme-email "$DERP_ACME_EMAIL" "$@"
[ -n "${DERP_HOME:-}" ]               && set -- --home "$DERP_HOME" "$@"

# DERP_EXTRA_ARGS is split on whitespace, for flags without a dedicated variable.
if [ -n "${DERP_EXTRA_ARGS:-}" ]; then
  # shellcheck disable=SC2086
  set -- "$@" ${DERP_EXTRA_ARGS}
fi

exec /usr/local/bin/derper "$@"
