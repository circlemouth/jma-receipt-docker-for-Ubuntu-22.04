#!/usr/bin/env bash
set -euo pipefail

log() {
    printf '[%s] %s\n' "$(date --iso-8601=seconds)" "$*"
}

: "${ORCA_DB_HOST:=db}"
: "${ORCA_DB_PORT:=5432}"
: "${ORCA_DB_NAME:=orca}"
: "${ORCA_DB_USER:=orca}"
: "${ORCA_DB_PASS:=orca_password}"
: "${ORCA_DB_ENCODING:=UTF-8}"
: "${ORCA_DB_WAIT_SECONDS:=300}"
: "${RUN_SCHEMA_CHECK:=false}"
: "${ORMASTER_PASS:=}"
# superuser credentials for jma-setup (defaults to same as application user)
: "${ORCA_PG_SUPERUSER:=${ORCA_DB_USER}}"
: "${ORCA_PG_SUPERPASS:=${ORCA_DB_PASS}}"

DEFAULT_HTTP_LOG="/var/log/orca/http.log"
ORCA_LOG_ROOT="/opt/jma/weborca/log"

DB_CONF_PATH="/opt/jma/weborca/conf/db.conf"
STATE_DIR="/var/lib/orca"
SETUP_DONE_FLAG="${STATE_DIR}/.jma_setup_done"
PASSWD_DONE_FLAG="${STATE_DIR}/.ormaster_password_done"
SCHEMA_DONE_FLAG="${STATE_DIR}/.schema_checked"
TMP_DIR="/tmp/weborca"

mkdir -p "${STATE_DIR}" "${TMP_DIR}"

ensure_http_log_dir() {
    local link_dir="/var/log/orca"
    mkdir -p "${ORCA_LOG_ROOT}"
    if [[ -L "${link_dir}" ]]; then
        return
    fi
    if [[ -e "${link_dir}" ]]; then
        return
    fi
    ln -s "${ORCA_LOG_ROOT}" "${link_dir}"
}

prepare_redirect_log() {
    ensure_http_log_dir
    local target="${REDIRECTLOG:-$DEFAULT_HTTP_LOG}"
    local target_dir
    target_dir="$(dirname "${target}")"
    mkdir -p "${target_dir}"
    touch "${target}"
    chown orca:orca "${target_dir}" "${target}" 2>/dev/null || true
    if [[ "${target_dir}" == "/var/log/orca" ]]; then
        local link_target
        link_target="$(basename "${target}")"
        ln -sf "${link_target}" /var/log/orca/orca_http.log
    fi
    export REDIRECTLOG="${target}"
}

wait_for_db() {
    local elapsed=0
    log "Waiting for PostgreSQL at ${ORCA_DB_HOST}:${ORCA_DB_PORT} (timeout: ${ORCA_DB_WAIT_SECONDS}s)"
    until PGPASSWORD="${ORCA_DB_PASS}" pg_isready -h "${ORCA_DB_HOST}" -p "${ORCA_DB_PORT}" -U "${ORCA_DB_USER}" >/dev/null 2>&1; do
        sleep 5
        elapsed=$((elapsed + 5))
        if (( elapsed >= ORCA_DB_WAIT_SECONDS )); then
            log "PostgreSQL not reachable after ${ORCA_DB_WAIT_SECONDS}s"
            exit 1
        fi
    done
    log "PostgreSQL is reachable"
}

write_db_conf() {
    log "Rendering ${DB_CONF_PATH}"
    cat <<CONF > "${DB_CONF_PATH}"
DBHOST="${ORCA_DB_HOST}"
DBPORT="${ORCA_DB_PORT}"
DBNAME="${ORCA_DB_NAME}"
DBUSER="${ORCA_DB_USER}"
DBPASS="${ORCA_DB_PASS}"
DBENCODING="${ORCA_DB_ENCODING}"
PGUSER="${ORCA_PG_SUPERUSER}"
PGPASS="${ORCA_PG_SUPERPASS}"
CONF
    chown orca:orca "${DB_CONF_PATH}"
    chmod 600 "${DB_CONF_PATH}"
}

seed_pgpass_files() {
    local host="${ORCA_DB_HOST}"
    local port="${ORCA_DB_PORT}"
    local entries=("${host}:${port}:*:${ORCA_DB_USER}:${ORCA_DB_PASS}")
    if [[ "${ORCA_PG_SUPERUSER}:${ORCA_PG_SUPERPASS}" != "${ORCA_DB_USER}:${ORCA_DB_PASS}" ]]; then
        entries+=("${host}:${port}:*:${ORCA_PG_SUPERUSER}:${ORCA_PG_SUPERPASS}")
    fi

    for os_user in orca postgres; do
        local passwd_line
        passwd_line=$(getent passwd "${os_user}" || true)
        if [[ -z "${passwd_line}" ]]; then
            continue
        fi
        local home
        home=$(cut -d: -f6 <<<"${passwd_line}")
        if [[ -z "${home}" ]]; then
            continue
        fi
        local file="${home}/.pgpass"
        printf '%s\n' "${entries[@]}" > "${file}"
        chown "${os_user}:${os_user}" "${file}" || true
        chmod 600 "${file}"
    done
}

psql_exec() {
    PGPASSWORD="${ORCA_PG_SUPERPASS}" psql \
        -h "${ORCA_DB_HOST}" \
        -p "${ORCA_DB_PORT}" \
        -U "${ORCA_PG_SUPERUSER}" \
        -d "${ORCA_DB_NAME}" \
        "$@"
}

sql_escape_literal() {
    local input="${1-}"
    printf '%s' "${input//\'/''}"
}

run_jma_setup() {
    if [[ -f "${SETUP_DONE_FLAG}" ]]; then
        log "jma-setup already executed; skipping"
        return
    fi

    log "Running jma-setup to provision database (requires root)"
    if /opt/jma/weborca/app/bin/jma-setup; then
        touch "${SETUP_DONE_FLAG}"
        log "jma-setup completed"
    else
        log "jma-setup failed"
        exit 1
    fi
}

maybe_run_schema_check() {
    if [[ "${RUN_SCHEMA_CHECK}" != "true" ]]; then
        return
    fi
    if [[ -f "${SCHEMA_DONE_FLAG}" ]]; then
        log "Schema check already executed; skipping"
        return
    fi

    local workdir
    workdir=$(mktemp -d -p "${TMP_DIR}" schema-XXXX)
    pushd "${workdir}" >/dev/null
    log "Downloading schema check tool"
    wget -q https://ftp.orca.med.or.jp/pub/etc/jma-receipt-dbscmchk.tgz
    tar xzf jma-receipt-dbscmchk.tgz
    pushd jma-receipt-dbscmchk >/dev/null
    log "Executing jma-receipt-dbscmchk.sh"
    bash jma-receipt-dbscmchk.sh
    popd >/dev/null
    popd >/dev/null
    rm -rf "${workdir}"
    touch "${SCHEMA_DONE_FLAG}"
    log "Schema check completed"
}

maybe_set_ormaster_password() {
    if [[ -z "${ORMASTER_PASS}" ]]; then
        log "ORMASTER_PASS not provided; skipping password configuration"
        return
    fi
    if [[ -f "${PASSWD_DONE_FLAG}" ]]; then
        log "ormaster password already configured; skipping"
        return
    fi
    log "Configuring ormaster password via direct SQL"

    local tbl_exists
    if ! tbl_exists=$(psql_exec -At -c "SELECT to_regclass('tbl_passwd')"); then
        log "Failed to probe tbl_passwd"
        exit 1
    fi
    if [[ "${tbl_exists}" != "tbl_passwd" ]]; then
        log "tbl_passwd table not found; skipping password automation"
        return
    fi

    local hashed
    if ! hashed=$(md5pass "${ORMASTER_PASS}" 2>/dev/null); then
        log "Unable to hash ormaster password"
        exit 1
    fi
    hashed=${hashed//$'\n'/}
    local escaped
    escaped=$(sql_escape_literal "${hashed}")

    if psql_exec -v ON_ERROR_STOP=1 <<SQL; then
DELETE FROM tbl_passwd WHERE userid = 'ormaster';
INSERT INTO tbl_passwd (userid, password) VALUES ('ormaster', '${escaped}');
SQL
        touch "${PASSWD_DONE_FLAG}"
        log "ormaster password updated"
    else
        log "Failed to update ormaster password"
        exit 1
    fi
}

start_weborca() {
    log "Starting WebORCA middleware"
    local cmd
read -r -d '' cmd <<EOF || true
set -e
cd /opt/jma/weborca/mw/bin
set -a
source /opt/jma/weborca/app/etc/online.env
source /opt/jma/weborca/conf/jma-receipt.conf
set +a
export DBHOST='${ORCA_DB_HOST}'
export DBPORT='${ORCA_DB_PORT}'
export DBNAME='${ORCA_DB_NAME}'
export DBUSER='${ORCA_DB_USER}'
export DBPASS='${ORCA_DB_PASS}'
export DBENCODING='${ORCA_DB_ENCODING}'
export REDIRECTLOG='${REDIRECTLOG}'
exec /bin/bash -lc "set -euo pipefail; /opt/jma/weborca/mw/bin/weborca 2>&1 | tee -a '${REDIRECTLOG}'"
EOF
    exec su -s /bin/bash orca -c "${cmd}"
}

wait_for_db
write_db_conf
seed_pgpass_files
run_jma_setup
maybe_run_schema_check
maybe_set_ormaster_password
prepare_redirect_log
start_weborca
