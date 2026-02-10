#!/bin/sh
# Tailscale integration (userspace networking, no NET_ADMIN required)

set -eu

TAILSCALED_PID_FILE="/var/run/tailscaled.pid"

# ── Start ─────────────────────────────────────────────────────────────────

tailscale_start() {
  if [ "${TAILSCALE_ENABLED:-false}" != "true" ]; then
    return 0
  fi

  if [ -z "${TAILSCALE_AUTHKEY:-}" ]; then
    echo "[tailscale] ERROR: TAILSCALE_AUTHKEY is required when TAILSCALE_ENABLED=true" >&2
    return 1
  fi

  # Append ephemeral=true to OAuth keys to be explicit
  authkey="${TAILSCALE_AUTHKEY}"
  case "$authkey" in
    tskey-client-*)
      case "$authkey" in
        *ephemeral=*) ;;
        *"?"*) authkey="${authkey}&ephemeral=true" ;;
        *)     authkey="${authkey}?ephemeral=true" ;;
      esac
      ;;
  esac

  echo "[tailscale] starting tailscaled (userspace networking, ephemeral)..." >&2
  tailscaled --tun=userspace-networking --state=mem: >>/tmp/tailscaled.log 2>&1 &
  echo "$!" > "$TAILSCALED_PID_FILE"

  # Build a safe argv list for "tailscale up".
  set -- up "--authkey=${authkey}"
  if [ -n "${TAILSCALE_HOSTNAME:-}" ]; then
    set -- "$@" "--hostname=${TAILSCALE_HOSTNAME}"
  fi
  if [ -n "${TAILSCALE_LOGIN_SERVER:-}" ]; then
    echo "[tailscale] using custom control server: ${TAILSCALE_LOGIN_SERVER}" >&2
    set -- "$@" "--login-server=${TAILSCALE_LOGIN_SERVER}"
  fi
  if [ -n "${TAILSCALE_TAGS:-}" ]; then
    set -- "$@" "--advertise-tags=${TAILSCALE_TAGS}"
  fi
  if [ -n "${TAILSCALE_EXTRA_ARGS:-}" ]; then
    # Allow advanced users to pass additional args (word-splitting is intentional here).
    # shellcheck disable=SC2086
    set -- "$@" ${TAILSCALE_EXTRA_ARGS}
  fi

  echo "[tailscale] connecting to tailnet..." >&2
  retries=0
  while [ $retries -lt 30 ]; do
    if tailscale "$@" >/dev/null 2>&1; then
      break
    fi
    sleep 1
    retries=$((retries + 1))
  done
  if [ $retries -ge 30 ]; then
    echo "[tailscale] ERROR: failed to connect to tailnet after 30s" >&2
    return 1
  fi

  # Configure Serve / Funnel
  if [ -n "${TAILSCALE_SERVE_PORT:-}" ]; then
    serve_mode="${TAILSCALE_SERVE_MODE:-https}"

    if [ "${TAILSCALE_FUNNEL:-false}" = "true" ] && [ "$serve_mode" != "https" ]; then
      echo "[tailscale] ERROR: TAILSCALE_FUNNEL=true supports only TAILSCALE_SERVE_MODE=https" >&2
      return 1
    fi

    if [ "${TAILSCALE_FUNNEL:-false}" = "true" ]; then
      echo "[tailscale] enabling Funnel (HTTPS → localhost:${TAILSCALE_SERVE_PORT})" >&2
      tailscale funnel --bg "${TAILSCALE_SERVE_PORT}" || \
        echo "[tailscale] WARNING: funnel setup failed (check ACL policy)" >&2
    else
      case "$serve_mode" in
        tls-terminated-tcp)
          echo "[tailscale] enabling Serve (TLS-terminated TCP:443 → localhost:${TAILSCALE_SERVE_PORT})" >&2
          tailscale serve --bg --tls-terminated-tcp=443 "tcp://localhost:${TAILSCALE_SERVE_PORT}" || \
            echo "[tailscale] WARNING: serve setup failed" >&2
          ;;
        *)
          echo "[tailscale] enabling Serve (HTTPS → localhost:${TAILSCALE_SERVE_PORT})" >&2
          tailscale serve --bg "${TAILSCALE_SERVE_PORT}" || \
            echo "[tailscale] WARNING: serve setup failed" >&2
          ;;
      esac
    fi
  fi

  ts_ip=$(tailscale ip -4 2>/dev/null || echo "unknown")
  echo "[tailscale] connected (Tailscale IP: ${ts_ip})" >&2
}

# ── Stop ──────────────────────────────────────────────────────────────────

tailscale_stop() {
  if [ "${TAILSCALE_ENABLED:-false}" != "true" ]; then
    return 0
  fi

  echo "[tailscale] shutting down..." >&2
  tailscale funnel off 2>/dev/null || true
  tailscale serve off 2>/dev/null || true
  tailscale down 2>/dev/null || true

  if [ -f "$TAILSCALED_PID_FILE" ]; then
    pid=$(cat "$TAILSCALED_PID_FILE")
    if kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    fi
    rm -f "$TAILSCALED_PID_FILE"
  fi
}

# ── Health ────────────────────────────────────────────────────────────────

tailscale_healthy() {
  if [ "${TAILSCALE_ENABLED:-false}" != "true" ]; then
    return 0
  fi

  tailscale status >/dev/null 2>&1
}
