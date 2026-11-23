#!/usr/bin/env bash
# ==============================================================================
# deploy-site.sh — интерактивный деплой сайта для маскировки ВПН
# ==============================================================================
# Папка проектов: /opt/sites/
# Каждый проект = подпапка: /opt/sites/имя-проекта/
# Активный проект помечается симлинком /opt/sites/_active
# ==============================================================================
set -euo pipefail

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
CYAN=$'\033[0;36m'; BOLD=$'\033[1m'; DIM=$'\033[2m'; NC=$'\033[0m'
log(){  echo -e "${CYAN}[*]${NC} $*"; }
ok(){   echo -e "${GREEN}[+]${NC} $*"; }
warn(){ echo -e "${YELLOW}[!]${NC} $*"; }
die(){  echo -e "${RED}[x] $*${NC}" >&2; exit 1; }
has_cmd(){ command -v "$1" >/dev/null 2>&1; }

[[ $EUID -eq 0 ]] || die "Запускай от root (sudo)."

SITES_ROOT="/opt/sites"
ACTIVE_LINK="$SITES_ROOT/_active"
PANEL_PATH_FILE="/etc/x-ui-panel-path.conf"
SITE_PORT_DEFAULT=3000

mkdir -p "$SITES_ROOT"

# ============================================================================
# ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ
# ============================================================================

ask() {
    # ask "вопрос" "дефолт"
    local q="$1" def="${2:-}" ans=""
    if [[ -n "$def" ]]; then
        read -rp "$(echo -e "${CYAN}?${NC} $q ${DIM}[$def]${NC}: ")" ans || true
        echo "${ans:-$def}"
    else
        read -rp "$(echo -e "${CYAN}?${NC} $q: ")" ans || true
        echo "$ans"
    fi
}

ask_yesno() {
    # ask_yesno "вопрос" "y|n"
    local q="$1" def="${2:-y}" ans=""
    while :; do
        read -rp "$(echo -e "${CYAN}?${NC} $q ${DIM}(y/n) [$def]${NC}: ")" ans || true
        ans="${ans:-$def}"
        case "${ans,,}" in
            y|yes|д|да) return 0 ;;
            n|no|н|нет) return 1 ;;
            *) echo "  ответь y или n" ;;
        esac
    done
}

ask_menu() {
    # ask_menu "заголовок" option1 option2 ... -> печатает выбранный номер (с 0)
    local title="$1"; shift
    local opts=("$@")
    echo -e "${BOLD}$title${NC}"
    local i=0
    for o in "${opts[@]}"; do
        echo -e "  ${CYAN}$i)${NC} $o"
        i=$((i+1))
    done
    local choice=""
    while :; do
        read -rp "$(echo -e "${CYAN}?${NC} Выбор ${DIM}[0]${NC}: ")" choice || true
        choice="${choice:-0}"
        if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -lt "$i" ]]; then
            echo "$choice"
            return 0
        fi
        echo "  введи число от 0 до $((i-1))"
    done
}

# Определение режима по содержимому папки
detect_mode() {
    local dir="$1"
    [[ -d "$dir" ]] || { echo "dummy"; return; }

    if compgen -G "$dir/next.config.*" >/dev/null 2>&1; then
        if [[ -d "$dir/out" ]]; then echo "spa"; return; fi
        if [[ -d "$dir/.next" ]]; then echo "ssr"; return; fi
        echo "ssr"; return
    fi
    if compgen -G "$dir/vite.config.*" >/dev/null 2>&1; then
        echo "spa"; return
    fi
    for d in out dist build public; do
        if [[ -f "$dir/$d/index.html" ]]; then echo "spa"; return; fi
    done
    if [[ -f "$dir/index.html" ]]; then echo "static"; return; fi
    if [[ -f "$dir/package.json" ]]; then
        if [[ -f "$dir/server.js" || -f "$dir/index.js" || -f "$dir/app.js" ]]; then
            echo "node"; return
        fi
        echo "ssr"; return
    fi
    echo "dummy"
}

mode_human() {
    case "$1" in
        static) echo "статика (HTML/CSS/JS, без сборки)" ;;
        spa)    echo "SPA (React/Vue/Next static, отдаётся как файлы)" ;;
        ssr)    echo "SSR (Next.js/Nuxt — нужен Node-сервер)" ;;
        node)   echo "голый Node.js (server.js)" ;;
        dummy)  echo "заглушка (пусто)" ;;
        *)      echo "неизвестно" ;;
    esac
}

# ============================================================================
# ШАГ 1: выбор проекта
# ============================================================================

select_project() {
    echo
    echo -e "${BOLD}${CYAN}══ ШАГ 1: Выбор проекта ══${NC}"
    echo -e "  Папка проектов: ${YELLOW}$SITES_ROOT${NC}"
    echo -e "  ${DIM}Кидай проекты сюда, каждый в отдельной подпапке${NC}"
    echo

    local projects=()
    local names=()
    local modes=()
    local active_name=""
    [[ -L "$ACTIVE_LINK" ]] && active_name=$(basename "$(readlink "$ACTIVE_LINK")")

    local d
    for d in "$SITES_ROOT"/*/; do
        [[ -d "$d" ]] || continue
        local name; name=$(basename "$d")
        [[ "$name" == "_active" ]] && continue
        projects+=("$d")
        names+=("$name")
        modes+=("$(detect_mode "$d")")
    done

    if [[ ${#projects[@]} -eq 0 ]]; then
        warn "В $SITES_ROOT нет ни одного проекта."
        echo
        echo "Создать новый проект? (папка будет создана, файлы положишь сам)"
        local newname
        newname=$(ask "Имя нового проекта (например my-streaming)")
        [[ -n "$newname" ]] || die "Имя не может быть пустым"
        mkdir -p "$SITES_ROOT/$newname"
        ok "Создана папка $SITES_ROOT/$newname"
        echo
        echo -e "  ${YELLOW}Положи туда файлы проекта и запусти скрипт снова.${NC}"
        echo -e "  ${DIM}Или прямо сейчас — скрипт создаст заглушку.${NC}"
        echo
        if ! ask_yesno "Продолжить с пустой папкой (создам заглушку)?" "n"; then
            exit 0
        fi
        SITE_DIR="$SITES_ROOT/$newname"
        SITE_NAME="$newname"
        DETECTED_MODE="dummy"
        return 0
    fi

    # Список проектов
    local i=0
    for name in "${names[@]}"; do
        local mark=""
        [[ "$name" == "$active_name" ]] && mark=" ${GREEN}← активен${NC}"
        local m; m=$(mode_human "${modes[$i]}")
        echo -e "  ${CYAN}$((i+1)))${NC} ${BOLD}$name${NC}  ${DIM}($m)${NC}$mark"
        i=$((i+1))
    done
    echo -e "  ${CYAN}0)${NC} создать новый проект"
    echo

    local choice
    while :; do
        read -rp "$(echo -e "${CYAN}?${NC} Номер проекта: ")" choice || true
        if [[ "$choice" == "0" ]]; then
            local newname
            newname=$(ask "Имя нового проекта")
            [[ -n "$newname" ]] || { echo "  пустое имя"; continue; }
            mkdir -p "$SITES_ROOT/$newname"
            SITE_DIR="$SITES_ROOT/$newname"
            SITE_NAME="$newname"
            DETECTED_MODE="dummy"
            ok "Создана $SITE_DIR"
            return 0
        fi
        if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 ]] && [[ "$choice" -le ${#names[@]} ]]; then
            local idx=$((choice-1))
            SITE_DIR="$SITES_ROOT/${names[$idx]}"
            SITE_NAME="${names[$idx]}"
            DETECTED_MODE="${modes[$idx]}"
            ok "Выбран: $SITE_NAME (определён как: $(mode_human "$DETECTED_MODE"))"
            return 0
        fi
        echo "  введи число из списка"
    done
}

# ============================================================================
# ШАГ 2: режим работы
# ============================================================================

select_mode() {
    echo
    echo -e "${BOLD}${CYAN}══ ШАГ 2: Режим работы ══${NC}"
    echo -e "  Автоопределение: ${YELLOW}$(mode_human "$DETECTED_MODE")${NC}"
    echo

    local choice
    choice=$(ask_menu "Что делать?" \
        "Авто (использовать определённый: $(mode_human "$DETECTED_MODE"))" \
        "Статика (HTML/CSS/JS, nginx отдаёт файлы)" \
        "SPA (собранные файлы: dist/out/build, fallback на index.html)" \
        "SSR (Node-сервер: Next.js/Nuxt, сборка + запуск)" \
        "Голый Node.js (server.js)" \
        "Заглушка (просто 'Site is ready')")

    case "$choice" in
        0) MODE="$DETECTED_MODE" ;;
        1) MODE=static ;;
        2) MODE=spa ;;
        3) MODE=ssr ;;
        4) MODE=node ;;
        5) MODE=dummy ;;
    esac
    ok "Режим: $MODE ($(mode_human "$MODE"))"

    # Порт для SSR/node
    SITE_PORT="$SITE_PORT_DEFAULT"
    if [[ "$MODE" == "ssr" || "$MODE" == "node" ]]; then
        echo
        local p
        p=$(ask "Порт для Node-сервера" "$SITE_PORT_DEFAULT")
        if [[ "$p" =~ ^[0-9]+$ ]]; then
            SITE_PORT="$p"
        fi
        ok "Порт: $SITE_PORT"
    fi
}

# ============================================================================
# ШАГ 3: сборка
# ============================================================================

select_build() {
    BUILD=no
    if [[ "$MODE" != "ssr" && "$MODE" != "node" && "$MODE" != "spa" ]]; then
        return 0
    fi

    # Для SPA: если артефакты уже есть — можно не собирать
    if [[ "$MODE" == "spa" ]]; then
        if [[ -d "$SITE_DIR/out" || -d "$SITE_DIR/dist" || -d "$SITE_DIR/build" ]]; then
            ok "Артефакты уже есть — сборка не нужна"
            return 0
        fi
    fi

    if [[ "$MODE" == "node" ]]; then
        # Для голого Node: проверим node_modules
        if [[ -d "$SITE_DIR/node_modules" ]]; then
            ok "node_modules есть — сборка не нужна"
            return 0
        fi
    fi

    echo
    echo -e "${BOLD}${CYAN}══ ШАГ 3: Сборка ══${NC}"
    echo -e "  ${DIM}Сборка на сервере может съесть 1–2 GB RAM.${NC}"
    echo -e "  ${DIM}Если мало RAM — собери локально и залей артефакты.${NC}"
    echo
    if ask_yesno "Собрать сейчас (npm ci + npm run build)?" "y"; then
        BUILD=yes
    fi
}

# ============================================================================
# ШАГ 4: панель 3x-ui
# ============================================================================

select_panel() {
    echo
    echo -e "${BOLD}${CYAN}══ ШАГ 4: Панель 3x-ui ══${NC}"

    local current=""
    [[ -f "$PANEL_PATH_FILE" ]] && current=$(awk -F= '/^PANEL_PATH=/{print $2; exit}' "$PANEL_PATH_FILE" || true)

    if [[ -n "$current" ]]; then
        echo -e "  Текущий путь панели: ${YELLOW}$current${NC}"
    else
        echo -e "  ${DIM}Путь панели ещё не настроен${NC}"
    fi
    echo

    local choice
    choice=$(ask_menu "Что делать с путём панели?" \
        "Оставить как есть (${current:-сгенерировать})" \
        "Сгенерировать новый из слов" \
        "Задать свой путь вручную" \
        "Не трогать панель вообще")

    case "$choice" in
        0) PANEL_MODE=keep ;;
        1) PANEL_MODE=generate ;;
        2) PANEL_MODE=manual ;;
        3) PANEL_MODE=skip ;;
    esac

    if [[ "$PANEL_MODE" == "manual" ]]; then
        local p
        p=$(ask "Свой путь (без слешей, например secret-login)")
        p="${p#/}"; p="${p%/}"
        [[ -n "$p" ]] || die "Пустой путь"
        PANEL_PATH_OVERRIDE="/$p"
        ok "Путь: $PANEL_PATH_OVERRIDE"
    elif [[ "$PANEL_MODE" == "skip" ]]; then
        ok "Панель не трогаю"
    fi
}

# ============================================================================
# ШАГ 5: WebRTC / SFU
# ============================================================================

select_webrtc() {
    echo
    echo -e "${BOLD}${CYAN}══ ШАГ 5: WebRTC / SFU ══${NC}"
    echo -e "  ${DIM}Нужно только если у тебя стриминг аудио/видео через WebRTC${NC}"
    echo

    WEBRTC=0
    TURN=0
    SFU_RANGE="10000:20000"

    if ! ask_yesno "Есть WebRTC/SFU (медиа по UDP)?" "n"; then
        return 0
    fi

    WEBRTC=1
    echo
    local r
    r=$(ask "UDP-диапазон для RTP (MEDIA)" "$SFU_RANGE")
    [[ "$r" =~ ^[0-9]+:[0-9]+$ ]] && SFU_RANGE="$r"
    ok "UDP-диапазон: $SFU_RANGE"

    echo
    if ask_yesno "Нужен TURN-сервер (coturn уже стоит)?" "n"; then
        TURN=1
    fi
}

# ============================================================================
# ШАГ 6: подтверждение
# ============================================================================

confirm() {
    echo
    echo -e "${BOLD}${CYAN}══ ИТОГ ══${NC}"
    echo -e "  Проект:  ${YELLOW}$SITE_NAME${NC}"
    echo -e "  Папка:   ${YELLOW}$SITE_DIR${NC}"
    echo -e "  Режим:   ${YELLOW}$MODE${NC} ($(mode_human "$MODE"))"
    [[ "$MODE" == "ssr" || "$MODE" == "node" ]] && echo -e "  Порт:    ${YELLOW}$SITE_PORT${NC}"
    echo -e "  Сборка:  ${YELLOW}$([[ "$BUILD" == "yes" ]] && echo да || echo нет)${NC}"
    case "$PANEL_MODE" in
        keep)     echo -e "  Панель:  ${YELLOW}оставить как есть${NC}" ;;
        generate) echo -e "  Панель:  ${YELLOW}новый из слов${NC}" ;;
        manual)   echo -e "  Панель:  ${YELLOW}$PANEL_PATH_OVERRIDE${NC}" ;;
        skip)     echo -e "  Панель:  ${YELLOW}не трогать${NC}" ;;
    esac
    echo -e "  WebRTC:  ${YELLOW}$([[ "$WEBRTC" -eq 1 ]] && echo "да, UDP $SFU_RANGE" || echo нет)${NC}"
    echo -e "  TURN:    ${YELLOW}$([[ "$TURN" -eq 1 ]] && echo да || echo нет)${NC}"
    echo
    if ! ask_yesno "Применить?" "y"; then
        echo "Отменено."
        exit 0
    fi
}

# ============================================================================
# ДЕПЛОЙ
# ============================================================================

pick_panel_path() {
    local WORDS=(river stone cloud maple tiger ember frost harbor echo lantern
                 willow cedar falcon meadow silver amber velvet crystal shadow
                 thunder whisper cosmic northern hidden sacred ancient silent
                 blooming drifting fading granite marble copper iron jade pearl
                 opal ruby sapphire topaz quartz onyx agate coral aqua azure)
    local a b
    while :; do
        a=${WORDS[$RANDOM % ${#WORDS[@]}]}
        b=${WORDS[$RANDOM % ${#WORDS[@]}]}
        [[ "$a" != "$b" ]] && break
    done
    echo "/${a}-${b}"
}

ensure_swap() {
    local swap_mb
    swap_mb=$(free -m | awk '/^Swap:/ {print $2+0}')
    [[ "$swap_mb" -ge 512 ]] && return 0
    if [[ -f /swapfile ]]; then
        swapon /swapfile 2>/dev/null || true
        return 0
    fi
    log "Создаю swap 2GB (нужен для сборки)..."
    fallocate -l 2G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=2048 2>/dev/null
    chmod 600 /swapfile
    mkswap /swapfile >/dev/null 2>&1
    swapon /swapfile 2>/dev/null && ok "Swap активирован" || warn "Swap не активировался"
}

do_build() {
    [[ "$BUILD" == "yes" ]] || return 0
    [[ -f "$SITE_DIR/package.json" ]] || { warn "package.json нет — сборку пропускаю"; return 0; }
    ensure_swap

    local mgr=npm
    [[ -f "$SITE_DIR/pnpm-lock.yaml" ]] && mgr=pnpm
    [[ -f "$SITE_DIR/yarn.lock" ]] && [[ "$mgr" == "npm" ]] && mgr=yarn

    log "Сборка ($mgr)..."
    case "$mgr" in
        pnpm)
            has_cmd pnpm || npm install -g pnpm >/dev/null 2>&1
            ( cd "$SITE_DIR" && pnpm install --prod=false && pnpm build ) || die "pnpm build упал"
            ;;
        yarn)
            has_cmd yarn || npm install -g yarn >/dev/null 2>&1
            ( cd "$SITE_DIR" && yarn install && yarn build ) || die "yarn build упал"
            ;;
        *)
            ( cd "$SITE_DIR" && npm ci && npm run build ) || die "npm run build упал"
            ;;
    esac
    ok "Сборка завершена"
}

setup_node_service() {
    [[ "$MODE" == "ssr" || "$MODE" == "node" || "$MODE" == "dummy" ]] || return 0

    if ! has_cmd node; then
        log "Node.js не найден — ставлю"
        apt-get update -qq && apt-get install -y nodejs npm || die "Node.js не поставился"
    fi
    chown -R www-data:www-data "$SITE_DIR" 2>/dev/null || true

    local start=""
    if [[ "$MODE" == "ssr" ]]; then
        start="npm start"
    elif [[ "$MODE" == "node" ]]; then
        if [[ -f "$SITE_DIR/server.js" ]]; then start="node server.js"
        elif [[ -f "$SITE_DIR/index.js" ]]; then start="node index.js"
        elif [[ -f "$SITE_DIR/app.js" ]]; then start="node app.js"
        else start="npm start"; fi
    else
        # dummy
        if [[ ! -f "$SITE_DIR/server.js" ]]; then
            cat > "$SITE_DIR/server.js" <<'EOF'
const http = require('http');
const port = process.env.PORT || 3000;
http.createServer((req, res) => {
  res.writeHead(200, {'Content-Type':'text/html; charset=utf-8'});
  res.end('<!doctype html><title>OK</title><h1>Site is ready</h1>');
}).listen(port, '127.0.0.1');
EOF
        fi
        start="node server.js"
    fi

    log "Создаю node-site.service (запуск: $start)"
    cat > /etc/systemd/system/node-site.service <<EOF
[Unit]
Description=Cover site for VPN mask
After=network.target

[Service]
Type=simple
WorkingDirectory=$SITE_DIR
ExecStart=/bin/bash -lc 'cd $SITE_DIR && $start'
Environment=PORT=$SITE_PORT
Environment=NODE_ENV=production
Environment=HOST=127.0.0.1
Restart=always
RestartSec=3
User=www-data
Group=www-data
NoNewPrivileges=yes
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable node-site.service >/dev/null 2>&1 || true
    systemctl restart node-site.service || warn "node-site не запустился — journalctl -u node-site -n 50"
    sleep 1
    systemctl is-active --quiet node-site.service && ok "node-site активен (127.0.0.1:$SITE_PORT)" || warn "node-site НЕ активен"
}

apply_panel_path() {
    [[ "$PANEL_MODE" == "skip" ]] && return 0

    local new_path=""
    case "$PANEL_MODE" in
        keep)
            [[ -f "$PANEL_PATH_FILE" ]] && new_path=$(awk -F= '/^PANEL_PATH=/{print $2; exit}' "$PANEL_PATH_FILE")
            [[ -z "$new_path" ]] && new_path=$(pick_panel_path)
            ;;
        generate) new_path=$(pick_panel_path) ;;
        manual)   new_path="$PANEL_PATH_OVERRIDE" ;;
    esac
    new_path="${new_path%/}"

    log "Путь панели: $new_path"
    echo "PANEL_PATH=$new_path" > "$PANEL_PATH_FILE"
    chmod 600 "$PANEL_PATH_FILE"

    if has_cmd x-ui; then
        x-ui setting -webBasePath "${new_path}/" 2>&1 | tee /tmp/xui-path.log >/dev/null || \
            warn "x-ui setting не сработал — /tmp/xui-path.log"
        systemctl restart x-ui 2>/dev/null || true
        sleep 1
        ok "3x-ui перезапущен на ${new_path}/"
    else
        warn "Команда x-ui не найдена — путь в nginx, но внутри 3x-ui останется старый"
    fi
    PANEL_PATH="$new_path"
}

ensure_ws_map() {
    if ! grep -rqE 'map[[:space:]]+\$http_upgrade[[:space:]]+\$connection_upgrade' /etc/nginx/ 2>/dev/null; then
        cat > /etc/nginx/conf.d/00-ws-map.conf <<'EOF'
# Managed by deploy-site.sh — WebSocket upgrade
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}
EOF
        log "Добавил /etc/nginx/conf.d/00-ws-map.conf"
    fi
}

generate_location_block() {
    case "$MODE" in
        static)
            cat <<EOF
location / {
        root $SITE_DIR;
        index index.html;
        try_files \$uri \$uri/ =404;
    }
EOF
            ;;
        spa)
            local root="$SITE_DIR"
            [[ -d "$SITE_DIR/out" ]]   && root="$SITE_DIR/out"
            [[ -d "$SITE_DIR/dist" ]]  && root="$SITE_DIR/dist"
            [[ -d "$SITE_DIR/build" ]] && root="$SITE_DIR/build"
            cat <<EOF
location / {
        root $root;
        index index.html;
        try_files \$uri \$uri/ /index.html;
    }
    location ~* \\.(js|css|png|jpg|jpeg|gif|ico|svg|woff2?|ttf)\$ {
        root $root;
        expires 7d;
        add_header Cache-Control "public, immutable";
    }
EOF
            ;;
        ssr|node|dummy)
            cat <<EOF
location / {
        proxy_pass http://127.0.0.1:$SITE_PORT;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_read_timeout 300s;
        proxy_buffering off;
    }
EOF
            ;;
    esac
}

replace_location_slash() {
    local conf_file="$1"
    local new_block="$2"

    cp -a "$conf_file" "${conf_file}.bak.$(date +%s)" 2>/dev/null || true

    python3 - "$conf_file" <<PYEOF
import sys, re
path = sys.argv[1]
new_block = '''$new_block'''

with open(path, 'r', encoding='utf-8') as f:
    text = f.read()

matches = list(re.finditer(r'location\s+/\s*\{', text))
if not matches:
    print("[!] location / не найден", file=sys.stderr)
    sys.exit(1)

m = matches[0]
start = m.start()
i = m.end() - 1
depth = 0
end = None
while i < len(text):
    c = text[i]
    if c == '{': depth += 1
    elif c == '}':
        depth -= 1
        if depth == 0:
            end = i + 1
            break
    i += 1

if end is None:
    print("[!] Закрывающий } не найден", file=sys.stderr)
    sys.exit(1)

indent = ' ' * (m.start() - text.rfind('\n', 0, m.start()) - 1)
block = new_block.rstrip()
block = '\n'.join((indent + line) if idx > 0 else line for idx, line in enumerate(block.split('\n')))

with open(path, 'w', encoding='utf-8') as f:
    f.write(text[:start] + block + text[end:])
print("[+] location / заменён")
PYEOF
}

patch_nginx() {
    has_cmd nginx || { warn "nginx не установлен — пропускаю"; return 0; }
    ensure_ws_map

    local conf_file=""
    local f
    for f in /etc/nginx/nginx.conf /etc/nginx/conf.d/*.conf; do
        [[ -f "$f" ]] || continue
        if grep -qE 'location[[:space:]]+/[[:space:]]*\{' "$f" 2>/dev/null; then
            conf_file="$f"
            break
        fi
    done

    if [[ -z "$conf_file" ]]; then
        warn "Не нашёл nginx.conf с location / — пропускаю"
        return 1
    fi
    log "Правлю $conf_file"

    # Путь панели
    if [[ -n "${PANEL_PATH:-}" ]]; then
        local old_pp
        old_pp=$(awk '/location \^~/{print $3; exit}' "$conf_file" 2>/dev/null || true)
        if [[ -n "$old_pp" && "$old_pp" != "${PANEL_PATH}/" ]]; then
            log "Путь панели в nginx: $old_pp → ${PANEL_PATH}/"
            sed -i "s|${old_pp}|${PANEL_PATH}/|g" "$conf_file"
        fi
    fi

    local block; block=$(generate_location_block)
    replace_location_slash "$conf_file" "$block" || { warn "Замена не удалась"; return 1; }

    if nginx -t 2>/tmp/nginx-test.log; then
        systemctl reload nginx
        ok "nginx перезагружен"
    else
        warn "nginx -t упал:"
        sed 's/^/    /' /tmp/nginx-test.log
        local last_bak; last_bak=$(ls -1t "${conf_file}.bak."* 2>/dev/null | head -1)
        [[ -n "$last_bak" ]] && mv "$last_bak" "$conf_file" && warn "Откатил из бэкапа"
        return 1
    fi
}

open_ports() {
    [[ "$WEBRTC" -eq 1 ]] || return 0
    has_cmd ufw || { warn "ufw нет — открой порты сам"; return 0; }

    log "Открываю UDP $SFU_RANGE"
    ufw allow "${SFU_RANGE}/udp" comment 'WebRTC RTP' 2>/dev/null || true
    if [[ "$TURN" -eq 1 ]]; then
        log "Открываю TURN (3478/udp, 5349/tcp)"
        ufw allow 3478/udp comment 'TURN/STUN' 2>/dev/null || true
        ufw allow 5349/tcp comment 'TURN TLS' 2>/dev/null || true
    fi
    ok "Порты открыты"
}

mark_active() {
    rm -f "$ACTIVE_LINK" 2>/dev/null || true
    ln -s "$SITE_DIR" "$ACTIVE_LINK" 2>/dev/null || true
    ok "Активный проект: $SITE_NAME"
}

# ============================================================================
# MAIN
# ============================================================================

echo
echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${CYAN}║        ИНТЕРАКТИВНЫЙ ДЕПЛОЙ САЙТА ДЛЯ МАСКИРОВКИ         ║${NC}"
echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════════╝${NC}"

select_project
select_mode
select_build
select_panel
select_webrtc
confirm

echo
log "Деплой $SITE_NAME..."
do_build
setup_node_service
apply_panel_path
patch_nginx
open_ports
mark_active

echo
echo -e "${BOLD}${GREEN}════ ГОТОВО ════${NC}"
echo -e "  Проект:  ${YELLOW}$SITE_NAME${NC} ($MODE)"
echo -e "  Сайт:    https://<домен>/"
[[ -n "${PANEL_PATH:-}" ]] && echo -e "  Панель:  https://<домен>${PANEL_PATH}/"
echo -e "  Активный: $ACTIVE_LINK"
echo
echo -e "${DIM}Логи сайта: journalctl -u node-site -n 50${NC}"
echo -e "${DIM}Другой проект: просто запусти скрипт снова${NC}"
echo