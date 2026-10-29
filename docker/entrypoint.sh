#!/usr/bin/env bash
# Entrypoint shared by authserver/worldserver/tool containers.
set -euo pipefail

AC_HOME=/azerothcore
CONF_DIR="${AC_HOME}/etc"
ROLE="${1:-worldserver}"
shift || true

DB_HOST="${DB_HOST:-db}"
DB_PORT="${DB_PORT:-3306}"
DB_USER="${DB_USER:-root}"
DB_PASS="${DB_PASS:-azerothcore}"
ELUNA_ENABLED="${ELUNA_ENABLED:-1}"

sed_escape() {
    printf '%s' "$1" | sed -e 's/[\/&]/\\&/g'
}

# docker-compose mounts ./docker/etc on top of /azerothcore/etc, which hides the
# authserver.conf.dist / worldserver.conf.dist files baked into the image. Reseed them
# from the backup taken at build time (etc.dist-backup) the first time the volume is empty.
seed_etc_dir() {
    mkdir -p "${CONF_DIR}"
    if [ ! -f "${CONF_DIR}/worldserver.conf.dist" ] || [ ! -f "${CONF_DIR}/authserver.conf.dist" ]; then
        echo "[entrypoint] Populando ${CONF_DIR} com os templates padrao..."
        cp -r --update=none "${AC_HOME}/etc.dist-backup/." "${CONF_DIR}/"
    fi
}

# Generates etc/<name>.conf from <name>.conf.dist on first run, wiring it up for Docker
# (DB host/credentials, built-in DB auto-updater, Eluna). Never touches an existing conf,
# so user edits made through the mounted volume always survive a container restart/rebuild.
bootstrap_conf() {
    local name="$1"
    local conf="${CONF_DIR}/${name}.conf"
    local dist="${conf}.dist"

    if [ -f "${conf}" ]; then
        return 0
    fi
    if [ ! -f "${dist}" ]; then
        echo "[entrypoint] ERRO: ${dist} nao encontrado (imagem corrompida?)." >&2
        exit 1
    fi

    echo "[entrypoint] Criando ${conf} a partir do template padrao."
    cp "${dist}" "${conf}"

    local h p u pw
    h=$(sed_escape "${DB_HOST}")
    p=$(sed_escape "${DB_PORT}")
    u=$(sed_escape "${DB_USER}")
    pw=$(sed_escape "${DB_PASS}")

    # Use "#" as the sed delimiter below: AC_HOME and the mysql path both contain "/",
    # which would otherwise collide with the usual "/" delimiter.
    sed -i \
        -e "s/127\.0\.0\.1;3306;root;root;/${h};${p};${u};${pw};/g" \
        -e "s#^SourceDirectory[[:space:]]*=.*#SourceDirectory = \"${AC_HOME}\"#" \
        -e "s#^MySQLExecutable[[:space:]]*=.*#MySQLExecutable = \"/usr/bin/mysql\"#" \
        "${conf}"

    if [ "${name}" = "authserver" ]; then
        sed -i \
            -e "s/^Updates\.EnableDatabases[[:space:]]*=.*/Updates.EnableDatabases = 1/" \
            -e "s/^Updates\.AutoSetup[[:space:]]*=.*/Updates.AutoSetup = 1/" \
            "${conf}"
    else
        sed -i \
            -e "s/^Updates\.EnableDatabases[[:space:]]*=.*/Updates.EnableDatabases = 7/" \
            -e "s/^Updates\.AutoSetup[[:space:]]*=.*/Updates.AutoSetup = 1/" \
            -e "s/^Eluna\.Enabled[[:space:]]*=.*/Eluna.Enabled = ${ELUNA_ENABLED}/" \
            -e "s/^ThreadPool[[:space:]]*=.*/ThreadPool = 4/" \
            "${conf}"
    fi
}

wait_for_db() {
    echo "[entrypoint] Aguardando MySQL em ${DB_HOST}:${DB_PORT}..."
    until mysqladmin ping -h"${DB_HOST}" -P"${DB_PORT}" -u"${DB_USER}" -p"${DB_PASS}" --silent >/dev/null 2>&1; do
        sleep 2
    done
    echo "[entrypoint] MySQL disponivel."
}

sql_scalar() {
    mysql -h"${DB_HOST}" -P"${DB_PORT}" -u"${DB_USER}" -p"${DB_PASS}" -N -B -e "$1" 2>/dev/null
}

# Some world.sql releases for this project ship without rows in `updates_include` (the base
# auth/characters dumps have them baked in, see sql/base/characters.sql, but the external
# world dump isn't built by this repo). Without that row the built-in updater's
# GetFileList() silently finds zero files to apply (no error!) and the schema stays stuck on
# whatever the dump shipped, even though 50+ files in sql/updates/<db>/ are pending. Self-heal
# it here so a fresh dump import doesn't require manually patching the DB by hand.
fix_updates_include() {
    local db="$1" dirName="$2"
    local tableExists
    tableExists=$(sql_scalar "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${db}' AND table_name='updates_include';")
    [ "${tableExists}" = "1" ] || return 0

    local rowCount
    rowCount=$(sql_scalar "SELECT COUNT(*) FROM ${db}.updates_include;")
    if [ "${rowCount}" = "0" ]; then
        echo "[entrypoint] ${db}.updates_include esta vazia; inserindo includes padrao (\$/sql/updates/${dirName})."
        sql_scalar "INSERT INTO ${db}.updates_include (path, state) VALUES ('\$/sql/archive/${dirName}','ARCHIVED'), ('\$/sql/updates/${dirName}','RELEASED');" >/dev/null
    fi
}

case "${ROLE}" in
    authserver|worldserver)
        seed_etc_dir
        bootstrap_conf "${ROLE}"
        wait_for_db
        if [ "${ROLE}" = "worldserver" ]; then
            fix_updates_include world world
            fix_updates_include characters characters
        else
            fix_updates_include auth auth
        fi

        RUN_DIR="${AC_HOME}/run/${ROLE}"
        mkdir -p "${RUN_DIR}/Logs"
        if [ "${ROLE}" = "worldserver" ]; then
            mkdir -p "${RUN_DIR}/Data" "${RUN_DIR}/lua_scripts"
        fi
        cd "${RUN_DIR}"

        echo "[entrypoint] Iniciando ${ROLE}..."
        if [ "${ROLE}" = "worldserver" ] && [ "$(sql_scalar "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='world';")" != "0" ]; then
            # world DB already bootstrapped: safe to let the CLI console thread block on
            # stdin (docker-compose sets stdin_open on this service) instead of spinning
            # at 100% CPU calling readline() -> instant EOF -> repeat, forever, which is
            # what happens with a closed stdin.
            exec "${AC_HOME}/bin/${ROLE}" -c "${CONF_DIR}/${ROLE}.conf" "$@"
        else
            # Fresh/empty DB (or authserver, which has no CLI spin issue): keep stdin
            # closed so the DB auto-setup "create it? [yes/no]" prompt gets instant EOF
            # and defaults to yes, instead of hanging forever on an open-but-silent stdin.
            exec "${AC_HOME}/bin/${ROLE}" -c "${CONF_DIR}/${ROLE}.conf" "$@" < /dev/null
        fi
        ;;
    mapextractor|vmap4extractor|vmap4assembler|mmaps_generator)
        exec "${AC_HOME}/bin/${ROLE}" "$@"
        ;;
    bash|sh|shell)
        exec /bin/bash
        ;;
    *)
        exec "${ROLE}" "$@"
        ;;
esac
