# shellcheck shell=bash
# Docker / compose aliases fuer den Open-Design Claude-CLI Server.
# Sourced von od-claude.sh.

DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "${DEPLOY_DIR}/.." && pwd)"

COMPOSE_FILE_LOCAL="${DEPLOY_DIR}/docker-compose.claude-cli.yml"
COMPOSE_FILE_SERVER="${DEPLOY_DIR}/docker-compose.claude-cli.server.yml"
COMPOSE_FILE="${OD_COMPOSE_FILE:-$COMPOSE_FILE_LOCAL}"
ENV_FILE="${DEPLOY_DIR}/.env.claude-cli"
ENV_EXAMPLE="${DEPLOY_DIR}/.env.claude-cli.example"

SERVICE="open-design"
CONTAINER="open-design-claude"
CLAUDE_USER="open-design"
CLAUDE_HOME="/home/open-design/.claude"

# Compose-Alias incl. env-file und projektroot, damit Build-Context stimmt.
COMPOSE="docker compose --file ${COMPOSE_FILE} --env-file ${ENV_FILE} --project-directory ${REPO_ROOT}"

# Exec im Service als open-design User (CLI laeuft als dieser).
APP="$COMPOSE exec -u ${CLAUDE_USER} ${SERVICE}"
APP_TTY="$COMPOSE exec -it -u ${CLAUDE_USER} ${SERVICE}"
APP_ROOT="$COMPOSE exec -u root ${SERVICE}"

container_running() {
    docker ps --format '{{.Names}}' | grep -qx "${CONTAINER}"
}

compose_is_up() {
    [ -n "$($COMPOSE ps -q 2>/dev/null)" ]
}

ensure_env_file() {
    if [ ! -f "$ENV_FILE" ]; then
        if [ -f "$ENV_EXAMPLE" ]; then
            cp "$ENV_EXAMPLE" "$ENV_FILE"
            print_ok "Env-Datei angelegt: ${ENV_FILE} (aus .example kopiert)"
        else
            print_err "Weder ${ENV_FILE} noch ${ENV_EXAMPLE} gefunden."
            return 1
        fi
    fi
}

require_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        print_err "docker nicht im PATH."
        exit 1
    fi
    if ! docker compose version >/dev/null 2>&1; then
        print_err "'docker compose' nicht verfuegbar (Compose v2 noetig)."
        exit 1
    fi
}
