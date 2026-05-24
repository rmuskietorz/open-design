#!/bin/bash
# chmod +x od-claude.sh
#
# Helper fuer Open Design Server mit gebundeltem Claude CLI (Subscription/OAuth).
# Stil-Konvention identisch zu rm-picvault/helper.sh:
#   - TUI mit Multi-Select (Cursor + Space + Enter)
#   - Numerische Gruppen-Codes (1, 11, 12 / 2, 21, ...)
#   - Batch-Modus: bash od-claude.sh 1 21 22
#   - Sprache deutsch

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/colors.sh
. "$SCRIPT_DIR/lib/colors.sh"
# shellcheck source=lib/docker.sh
. "$SCRIPT_DIR/lib/docker.sh"

ask() {
    read -p "$1: " _answer
    echo "$_answer"
}

ask_secret() {
    read -s -p "$1: " _secret
    echo "" >&2
    echo "$_secret"
}

pick() {
    local prompt="$1"
    shift
    local options=("$@")
    echo ""
    for i in "${!options[@]}"; do
        echo "  $((i+1)). ${options[$i]}"
    done
    echo ""
    while true; do
        read -p "$prompt [1-${#options[@]}]: " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#options[@]}" ]; then
            echo "${options[$((choice-1))]}"
            return
        fi
        print_err "Bitte eine Zahl zwischen 1 und ${#options[@]} eingeben."
    done
}

# ─── TUI ──────────────────────────────────────────────────────────────────────

_MITEMS=(
  "G:Docker"
  "1:Container starten"
  "11:Container stoppen"
  "12:Image bauen"
  "13:Container neu starten"
  "14:Status / Health"
  "15:Logs (follow)"
  "16:Shell im Container"
  "17:Image aus Registry pullen"
  "G:Claude CLI"
  "2:Login (Subscription / OAuth)"
  "21:Login-Status pruefen"
  "22:Test-Prompt absetzen"
  "23:Logout (credentials.json loeschen)"
  "24:Claude CLI im Container updaten"
  "G:Konfiguration"
  "3:.env bearbeiten"
  "31:Compose-Konfig anzeigen"
  "39:Volumes + Container loeschen (DESTRUKTIV)"
)

declare -a _MK _ML _MG _MGN
_mgc=-1
for _me in "${_MITEMS[@]}"; do
  _mk="${_me%%:*}"; _mv="${_me#*:}"
  if [[ "$_mk" == "G" ]]; then
    ((_mgc++)); _MGN+=("$_mv")
  else
    _MK+=("$_mk"); _ML+=("$_mv"); _MG+=("$_mgc")
  fi
done
_MTN=${#_MK[@]}
declare -a _MSL
declare -a _MCLINES
for ((i=0;i<_MTN;i++)); do _MSL+=(0); done
_MSL_NEXT=1

_MCUR=0
_MNCOLS=1
_MRSZ=0
_MSEP='────────────────────────────────────────────────────────────────────────────'
trap '_MRSZ=1' SIGWINCH

_m_cols() {
  local c
  c=${COLUMNS:-0}
  (( c > 0 )) && { echo "$c"; return; }
  c=$(stty size 2>/dev/null | awk '{print $2}')
  [[ -n "$c" && "$c" -gt 0 ]] 2>/dev/null && { echo "$c"; return; }
  c=$(tput cols 2>/dev/null)
  [[ -n "$c" && "$c" -gt 0 ]] 2>/dev/null && { echo "$c"; return; }
  echo 80
}

_m_update_ncols() {
  local w; w=$(_m_cols)
  if   (( w >= 180 )); then _MNCOLS=3
  elif (( w >= 110 )); then _MNCOLS=2
  else _MNCOLS=1; fi
}

_m_item_col() {
  local g=${_MG[$1]}
  local gpc=$(( (${#_MGN[@]} + _MNCOLS - 1) / _MNCOLS ))
  _MITEMCOL=$(( g / gpc ))
  (( _MITEMCOL >= _MNCOLS )) && _MITEMCOL=$(( _MNCOLS - 1 ))
}

_m_nav_v() {
  local dir=$1
  _m_item_col $_MCUR; local curcol=$_MITEMCOL
  local i
  if (( dir > 0 )); then
    for ((i=_MCUR+1; i<_MTN; i++)); do
      _m_item_col $i; (( _MITEMCOL == curcol )) && { _MCUR=$i; return; }
    done
    for ((i=0; i<_MCUR; i++)); do
      _m_item_col $i; (( _MITEMCOL == curcol )) && { _MCUR=$i; return; }
    done
  else
    for ((i=_MCUR-1; i>=0; i--)); do
      _m_item_col $i; (( _MITEMCOL == curcol )) && { _MCUR=$i; return; }
    done
    for ((i=_MTN-1; i>_MCUR; i--)); do
      _m_item_col $i; (( _MITEMCOL == curcol )) && { _MCUR=$i; return; }
    done
  fi
}

_m_row_in_col() {
  local target=$1
  _m_item_col $target; local tcol=$_MITEMCOL
  local row=0 i
  for ((i=0; i<_MTN; i++)); do
    _m_item_col $i; (( _MITEMCOL != tcol )) && continue
    (( i == target )) && { echo $row; return; }
    ((row++))
  done
  echo 0
}

_m_item_at_row() {
  local col=$1 row=$2
  local r=0 last=-1 i
  for ((i=0; i<_MTN; i++)); do
    _m_item_col $i; (( _MITEMCOL != col )) && continue
    last=$i
    (( r == row )) && { echo $i; return; }
    ((r++))
  done
  (( last >= 0 )) && echo $last || echo 0
}

_m_nav_h() {
  local dir=$1
  _m_item_col $_MCUR; local curcol=$_MITEMCOL
  local tcol=$(( curcol + dir ))
  (( tcol < 0 || tcol >= _MNCOLS )) && return
  local currow; currow=$(_m_row_in_col $_MCUR)
  local target; target=$(_m_item_at_row $tcol $currow)
  _MCUR=$target
}

_m_render_col() {
  _MCLINES=()
  local cidx=$1 cw=$2
  local ng=${#_MGN[@]}
  local gpc=$(( (ng + _MNCOLS - 1) / _MNCOLS ))
  local gs=$(( cidx * gpc ))
  local ge=$(( gs + gpc - 1 ))
  (( ge >= ng )) && ge=$(( ng - 1 ))
  (( gs >= ng )) && return
  local last_g=-1 lbl_max=$(( cw - 11 )) i line pad_s
  for ((i=0; i<_MTN; i++)); do
    local g=${_MG[$i]}
    (( g < gs || g > ge )) && continue
    if (( g != last_g )); then
      [[ $last_g -ge 0 ]] && _MCLINES+=("")
      local gn="${_MGN[$g]}"
      (( ${#gn} > cw-5 )) && gn="${gn:0:$((cw-6))}…"
      local slen=$(( cw - ${#gn} - 4 ))
      (( slen < 1 )) && slen=1
      printf -v line "\033[36;1m── %s %s\033[0m" "$gn" "${_MSEP:0:$slen}"
      _MCLINES+=("$line")
      last_g=$g
    fi
    local key="${_MK[$i]}" lbl="${_ML[$i]}"
    (( ${#lbl} > lbl_max )) && lbl="${lbl:0:$((lbl_max-1))}…"
    local pad=$(( cw - 11 - ${#lbl} ))
    (( pad < 0 )) && pad=0
    local csr="  " chk="[ ]"
    (( i == _MCUR )) && csr=$'\033[1m\xe2\x96\xb6 \033[0m'
    local _ord=${_MSL[$i]}
    if   (( _ord == 0 ));  then chk="[ ]"
    elif (( _ord <= 9 ));  then chk=$'\033[32m['"$_ord"$']\033[0m'
    else                        chk=$'\033[32m[+]\033[0m'
    fi
    printf -v pad_s '%*s' $pad ''
    printf -v line "%s%s \033[33m%3s\033[0m  %s%s" "$csr" "$chk" "$key" "$lbl" "$pad_s"
    _MCLINES+=("$line")
  done
}

_m_draw() {
  _m_update_ncols
  local w; w=$(_m_cols)
  local cw=$(( (w - 2*(_MNCOLS-1)) / _MNCOLS ))
  (( cw < 28 )) && cw=28

  printf '\033[H'
  printf "\033[36;1m╔══════════════════════════════════════════╗\n"
  printf "║   Open Design — Claude CLI Helper        ║\n"
  printf "╚══════════════════════════════════════════╝\033[0m\n\n"

  declare -a _MC0 _MC1 _MC2
  _m_render_col 0 $cw; _MC0=("${_MCLINES[@]}")
  _MC1=(); _MC2=()
  (( _MNCOLS >= 2 )) && { _m_render_col 1 $cw; _MC1=("${_MCLINES[@]}"); }
  (( _MNCOLS >= 3 )) && { _m_render_col 2 $cw; _MC2=("${_MCLINES[@]}"); }

  local nrows=${#_MC0[@]}
  (( ${#_MC1[@]} > nrows )) && nrows=${#_MC1[@]}
  (( ${#_MC2[@]} > nrows )) && nrows=${#_MC2[@]}

  local row col line
  for ((row=0; row<nrows; row++)); do
    for ((col=0; col<_MNCOLS; col++)); do
      case $col in
        0) line="${_MC0[$row]:-}" ;;
        1) line="${_MC1[$row]:-}" ;;
        2) line="${_MC2[$row]:-}" ;;
      esac
      printf '%s' "$line"
      [[ -z "$line" ]] && printf '%*s' $cw ''
      (( col < _MNCOLS-1 )) && printf '  '
    done
    printf '\n'
  done

  printf '\n\033[36m──────────────────────────────────────────────────────\033[0m\n'
  printf ' \033[1m↑↓\033[0m/Pfeile: nav  \033[1mSpace\033[0m: auswählen'
  printf '  \033[1mEnter\033[0m: ausführen  \033[1ma\033[0m: alle  \033[1mn\033[0m: keine  \033[1mq\033[0m: Ende\n'
  printf '\033[J'
}

_m_drain() { while read -rsn1 -t 0 _mdrain 2>/dev/null; do :; done; }

_m_readkey() {
  _MKEY='IGNORE'
  local _buf _rest
  IFS= read -rsn1 _buf
  if [[ "$_buf" == $'\e' ]]; then
    IFS= read -rsn2 -t 1 _rest 2>/dev/null
    case "$_rest" in
      '[A'|'OA') _MKEY='UP'    ;;
      '[B'|'OB') _MKEY='DOWN'  ;;
      '[C'|'OC') _MKEY='RIGHT' ;;
      '[D'|'OD') _MKEY='LEFT'  ;;
    esac
    _m_drain
  elif [[ "$_buf" == ' ' || "$_buf" == '' || "$_buf" == [aAnNqQ] ]]; then
    _MKEY="$_buf"
  elif [[ "$_buf" =~ [0-9] ]]; then
    local _num="$_buf"
    IFS= read -rsn1 -t 0.5 _rest 2>/dev/null
    if [[ "$_rest" =~ [0-9] ]]; then
      _num+="$_rest"
    fi
    local _found=0
    for ((i=0;i<_MTN;i++)); do
      if [[ "${_MK[$i]}" == "$_num" ]]; then
        _MCUR=$i
        if (( ${_MSL[$_MCUR]} == 0 )); then
          _MSL[$_MCUR]=$_MSL_NEXT; ((_MSL_NEXT++))
        else
          local _rm=${_MSL[$_MCUR]}; _MSL[$_MCUR]=0
          for ((j=0;j<_MTN;j++)); do
            (( ${_MSL[$j]} > _rm )) && _MSL[$j]=$(( ${_MSL[$j]} - 1 ))
          done
          ((_MSL_NEXT--))
        fi
        _found=1; break
      fi
    done
    if (( !_found )); then _MKEY='IGNORE'; fi
  fi
  _m_drain
}

tui_menu() {
  local _stty_save; _stty_save=$(stty -g 2>/dev/null)
  tput smcup 2>/dev/null; tput civis 2>/dev/null; stty -echo 2>/dev/null
  local _done=0 _res=""
  tput clear 2>/dev/null
  while (( !_done )); do
    (( _MRSZ )) && { tput clear 2>/dev/null; _MRSZ=0; }
    _m_draw
    _m_readkey
    case "$_MKEY" in
      UP)    _m_nav_v -1 ;;
      DOWN)  _m_nav_v  1 ;;
      LEFT)  _m_nav_h -1 ;;
      RIGHT) _m_nav_h  1 ;;
      ' ')
        if (( ${_MSL[$_MCUR]} == 0 )); then
          _MSL[$_MCUR]=$_MSL_NEXT; ((_MSL_NEXT++))
        else
          local _rm=${_MSL[$_MCUR]}; _MSL[$_MCUR]=0
          for ((i=0;i<_MTN;i++)); do
            (( ${_MSL[$i]} > _rm )) && _MSL[$i]=$(( ${_MSL[$i]} - 1 ))
          done
          ((_MSL_NEXT--))
        fi ;;
      a|A)
        for ((i=0;i<_MTN;i++)); do _MSL[$i]=$((i+1)); done
        _MSL_NEXT=$((_MTN+1)) ;;
      n|N)
        for ((i=0;i<_MTN;i++)); do _MSL[$i]=0; done
        _MSL_NEXT=1 ;;
      '')
        _res=""
        for ((n=1; n<_MSL_NEXT; n++)); do
          for ((i=0;i<_MTN;i++)); do
            (( ${_MSL[$i]} == n )) && _res+="${_MK[$i]} "
          done
        done
        [[ -z "${_res// }" ]] && _res="${_MK[$_MCUR]}"
        _done=1 ;;
      q|Q) _res=""; _done=1 ;;
      IGNORE) ;;
    esac
  done
  tput cnorm 2>/dev/null
  [[ -n "$_stty_save" ]] && stty "$_stty_save" 2>/dev/null
  tput rmcup 2>/dev/null
  _TUIRES="${_res% }"
}

# ─── Parameteruebergabe oder interaktives Menue ───────────────────────────────

require_docker
ensure_env_file || exit 1

if [ $# -eq 0 ]; then
    _TUIRES=""
    tui_menu
    _OPTS="$_TUIRES"
    [ -z "$_OPTS" ] && exit 0
else
    _OPTS="$*"
fi

# ─── Aktionen ────────────────────────────────────────────────────────────────

for option in $_OPTS; do
echo ""
case $option in

    # ─── Docker ──────────────────────────────────────────────────────────────
    1)
        print_info "Container starten..."
        $COMPOSE up -d
        print_ok "Container gestartet"
        ;;
    11)
        print_info "Container stoppen..."
        $COMPOSE down
        print_ok "Container gestoppt"
        ;;
    12)
        print_info "Image bauen (Dockerfile.claude-cli)..."
        $COMPOSE build --pull
        print_ok "Build abgeschlossen"
        ;;
    13)
        print_info "Container neu starten..."
        $COMPOSE restart
        print_ok "Container neu gestartet"
        ;;
    14)
        print_header "Status / Health"
        print_sep
        $COMPOSE ps
        echo ""
        if container_running; then
            print_info "Healthcheck:"
            docker inspect --format \
                '  Status: {{.State.Status}}
  Health: {{if .State.Health}}{{.State.Health.Status}}{{else}}(kein Healthcheck){{end}}
  Started: {{.State.StartedAt}}' \
                "${CONTAINER}" 2>/dev/null || true
        else
            print_err "Container laeuft nicht."
        fi
        ;;
    15)
        print_info "Logs (Strg+C zum Beenden)..."
        $COMPOSE logs -f --tail=200
        ;;
    16)
        if ! container_running; then
            print_err "Container laeuft nicht. Erst Option 1 ausfuehren."
            continue
        fi
        print_info "Shell im Container (user: ${CLAUDE_USER}, exit zum Verlassen)..."
        $APP_TTY sh
        ;;
    17)
        print_info "Image aus Registry pullen..."
        $COMPOSE pull
        print_ok "Pull abgeschlossen"
        ;;

    # ─── Claude CLI ──────────────────────────────────────────────────────────
    2)
        if ! container_running; then
            print_err "Container laeuft nicht. Erst Option 1 ausfuehren."
            continue
        fi
        print_header "Claude CLI Login (Subscription / OAuth)"
        print_sep
        cat <<EOF

  ${BOLD}Ablauf:${RESET}
    1. Im Container wird 'claude setup-token' gestartet und gibt eine URL aus.
       Fallback: 'claude /login'.
    2. URL ${BOLD}auf deinem lokalen Rechner${RESET} im Browser oeffnen.
    3. Mit Claude Pro/Max Account einloggen.
    4. Zurueckgegebenen Code hier ins Terminal einfuegen.
    5. Credentials werden im Volume claude_home gespeichert
       (-> ${CLAUDE_HOME}/.credentials.json).

  ${YELLOW}${BOLD}Wichtig:${RESET} ANTHROPIC_API_KEY darf NICHT gesetzt sein, sonst
  laeuft Verbrauch ueber den API-Key statt ueber die Subscription.

EOF
        read -p "  Weiter? (y/n): " GO
        if [ "$GO" != "y" ]; then
            print_info "Abgebrochen."
            continue
        fi

        if $APP_TTY sh -c 'command -v claude >/dev/null && claude setup-token' 2>/dev/null; then
            print_ok "Login via 'claude setup-token' abgeschlossen"
        else
            print_info "'claude setup-token' nicht verfuegbar – versuche 'claude /login'..."
            $APP_TTY claude /login
        fi
        ;;
    21)
        if ! container_running; then
            print_err "Container laeuft nicht."
            continue
        fi
        print_header "Claude CLI Status"
        print_sep
        $APP sh -c '
            echo "  bin     : $(command -v claude)"
            echo "  version : $(claude --version 2>/dev/null || echo unbekannt)"
            if [ -f /home/open-design/.claude/.credentials.json ]; then
                echo "  creds   : vorhanden"
                stat -c "  mtime   : %y" /home/open-design/.claude/.credentials.json 2>/dev/null || true
            else
                echo "  creds   : NICHT gefunden – Login mit Option 2 noetig"
            fi
            if [ -n "$ANTHROPIC_API_KEY" ]; then
                echo "  WARNUNG : ANTHROPIC_API_KEY ist gesetzt – Subscription wird umgangen!"
            fi
        '
        ;;
    22)
        if ! container_running; then
            print_err "Container laeuft nicht."
            continue
        fi
        print_info "Sende Test-Prompt an Claude CLI..."
        if $APP claude -p "antworte nur mit OK" --output-format text; then
            echo ""
            print_ok "Test erfolgreich – CLI ist authentifiziert"
        else
            print_err "Test fehlgeschlagen. Pruefe Login (Option 21)."
        fi
        ;;
    23)
        if ! container_running; then
            print_err "Container laeuft nicht."
            continue
        fi
        print_header "Claude CLI Logout"
        echo ""
        echo -e "  ${YELLOW}${BOLD}Loescht .credentials.json im Volume claude_home.${RESET}"
        read -p "  Fortfahren? (y/n): " CONFIRM
        if [ "$CONFIRM" != "y" ]; then
            print_info "Abgebrochen."
            continue
        fi
        $APP sh -c 'rm -f /home/open-design/.claude/.credentials.json'
        print_ok "Credentials entfernt"
        ;;
    24)
        if ! container_running; then
            print_err "Container laeuft nicht."
            continue
        fi
        print_header "Claude CLI im Container updaten"
        echo ""
        echo -e "  ${YELLOW}Hinweis:${RESET} Update ist nicht persistent. Fuer dauerhaftes"
        echo "  Update das Image neu bauen (Option 12)."
        read -p "  Fortfahren? (y/n): " CONFIRM
        if [ "$CONFIRM" != "y" ]; then
            print_info "Abgebrochen."
            continue
        fi
        $APP_ROOT npm install -g @anthropic-ai/claude-code@latest
        $APP claude --version
        print_ok "CLI aktualisiert"
        ;;

    # ─── Konfiguration ───────────────────────────────────────────────────────
    3)
        print_info ".env bearbeiten: ${ENV_FILE}"
        "${EDITOR:-vi}" "${ENV_FILE}"
        ;;
    31)
        print_header "Compose-Konfiguration"
        print_sep
        $COMPOSE config
        ;;
    39)
        print_header "Volumes + Container loeschen"
        echo ""
        echo -e "  ${RED}${BOLD}ACHTUNG: Damit gehen alle OD-Projekte, Artefakte"
        echo -e "  und der Claude-Login VERLOREN.${RESET}"
        echo ""
        read -p "  Tippe 'JA' zum Bestaetigen: " CONFIRM
        if [ "$CONFIRM" != "JA" ]; then
            print_info "Abgebrochen."
            continue
        fi
        $COMPOSE down -v
        print_ok "Container + Volumes entfernt"
        ;;

    *)
        print_err "Unbekannte Option: $option"
        ;;
esac
done
