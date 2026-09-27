#!/bin/sh
# ===========================================================================
# Paperless-ngx for TOS 7 - container entrypoint
# ===========================================================================
# The upstream image already runs everything as the unprivileged "paperless"
# user (uid 1000) through s6-overlay, which TOS can start directly. What this
# wrapper adds is what the image refuses to invent for you - the two secrets a
# fresh installation needs - plus a supported way to change the many
# environment-only settings:
#
#   1. PAPERLESS_SECRET_KEY. The image refuses to start with the shipped
#      default ("change-me") and every installation needs its own key: it signs
#      sessions and, together with the database, protects stored data. The key
#      is generated once with the CSPRNG and kept in the application data
#      volume, so it survives restarts, updates and re-installs.
#
#   2. The first administrator. Paperless has no sign-up flow, and without a
#      superuser nobody can log in. A random password is generated once and
#      kept in the data volume (the account is only created while no superuser
#      exists, so changing the password later is safe).
#
#   3. data/extra-env.txt - a plain KEY=VALUE file in the application data
#      volume. Paperless is configured exclusively through environment
#      variables (OCR language, public URL, mail, ...), which a TOS user
#      otherwise cannot reach without editing the compose file. The file is
#      created on the first start with commented examples.
#
# Afterwards the unchanged upstream init (/init) takes over.
#
# MAINTAINERS: this file is embedded verbatim into docker-compose.yml by
# scripts/build.sh, which indents it and escapes every dollar sign (docker
# compose interpolates ${VAR} / $VAR in compose files). Edit THIS file only.
# ===========================================================================
set -u

log() { printf '[paperless-app] %s\n' "$*"; }

DATA_DIR=/usr/src/paperless/data

# The data directory is a bind mount; the TOS installer chowns it to the
# application user. If that has not happened yet, fall back to a container-local
# directory so the application starts instead of restarting in a loop - the
# warning tells the administrator what to fix.
if ! { mkdir -p "$DATA_DIR" 2>/dev/null && : > "$DATA_DIR/.write-test" 2>/dev/null; }; then
    log "WARNING: $DATA_DIR is not writable - using /tmp instead"
    log "WARNING: documents, the database and the secret key will be lost on restart"
    DATA_DIR=/tmp/paperless-data
    mkdir -p "$DATA_DIR"
fi
rm -f "$DATA_DIR/.write-test" 2>/dev/null || true

KEY_FILE="$DATA_DIR/secret-key"
ENV_FILE="$DATA_DIR/extra-env.txt"
ADMIN_FILE="$DATA_DIR/admin-password.txt"

# --------------------------------------------------------------- extra settings
# Seeded with comments only, so it is discoverable but changes nothing until the
# administrator uncomments a line. Never overwritten afterwards.
if [ ! -e "$ENV_FILE" ]; then
    cat > "$ENV_FILE" <<'TPL_EXTRA_ENV'
# Paperless-ngx settings for TOS - one KEY=VALUE per line.
#
# Paperless is configured through environment variables. Anything set here is
# applied when the application starts, and it survives updates because this file
# lives in the application data folder. Lines starting with # are ignored.
# After a change, restart Paperless-ngx from the TOS App Center.
#
# OCR: the image ships the languages eng, deu, ita, spa and fra. To add more,
# install them with PAPERLESS_OCR_LANGUAGES and pick the one used for scanning
# with PAPERLESS_OCR_LANGUAGE, for example:
#
#   PAPERLESS_OCR_LANGUAGES=chi_sim chi_tra
#   PAPERLESS_OCR_LANGUAGE=chi_sim+eng
#
# Public address: used in e-mails and in links that Paperless generates for
# you (default is http://localhost:8000, which no other device can open):
#
#   PAPERLESS_URL=http://192.168.1.10:8011
#
# Incoming mail, notifications and the other options are documented at
# https://docs.paperless-ngx.com/configuration/
TPL_EXTRA_ENV
    log "created $ENV_FILE (commented examples for OCR language and public URL)"
fi

if [ -f "$ENV_FILE" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            ''|\#*) continue ;;
        esac
        key=${line%%=*}
        case "$key" in
            *[!A-Za-z0-9_]*|'') log "WARNING: ignoring malformed line in extra-env.txt: $line"; continue ;;
        esac
        export "$key=${line#*=}"
        log "extra-env: $key applied"
    done < "$ENV_FILE"
fi

# ---------------------------------------------------------------- the secret key
# Read first so a value set above can never replace an existing key. Generated
# only when the file is missing or empty.
if [ ! -s "$KEY_FILE" ]; then
    if python3 -c 'import secrets,sys; sys.stdout.write(secrets.token_urlsafe(64))' \
           > "$KEY_FILE" 2>/dev/null && [ -s "$KEY_FILE" ]; then
        chmod 600 "$KEY_FILE" 2>/dev/null || true
        log "generated a new PAPERLESS_SECRET_KEY in $KEY_FILE"
        log "keep this file: a restore without it invalidates every session"
    else
        rm -f "$KEY_FILE" 2>/dev/null || true
        log "ERROR: could not generate PAPERLESS_SECRET_KEY - refusing to start with an insecure default"
        exit 1
    fi
fi

PAPERLESS_SECRET_KEY="$(cat "$KEY_FILE")"
export PAPERLESS_SECRET_KEY

# ------------------------------------------------------------ first administrator
# Generated once and kept in the data volume. An explicit PAPERLESS_ADMIN_PASSWORD
# (from extra-env.txt) wins, so an administrator who set their own password is
# never overridden.
if [ ! -s "$ADMIN_FILE" ]; then
    if python3 -c 'import secrets,sys; sys.stdout.write(secrets.token_urlsafe(12))' \
           > "$ADMIN_FILE" 2>/dev/null && [ -s "$ADMIN_FILE" ]; then
        chmod 600 "$ADMIN_FILE" 2>/dev/null || true
        log "created the first administrator in $ADMIN_FILE"
    else
        rm -f "$ADMIN_FILE" 2>/dev/null || true
        log "ERROR: could not generate the administrator password"
        exit 1
    fi
fi

: "${PAPERLESS_ADMIN_USER=admin}"
if [ -z "${PAPERLESS_ADMIN_PASSWORD-}" ]; then
    PAPERLESS_ADMIN_PASSWORD="$(cat "$ADMIN_FILE")"
fi
export PAPERLESS_ADMIN_USER PAPERLESS_ADMIN_PASSWORD
if [ -s "$ADMIN_FILE" ] && [ "$PAPERLESS_ADMIN_PASSWORD" = "$(cat "$ADMIN_FILE")" ]; then
    log "first sign-in: user $PAPERLESS_ADMIN_USER, password $PAPERLESS_ADMIN_PASSWORD"
fi

log "starting the upstream init (/init) as uid $(id -u)"
exec /init
