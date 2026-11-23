#!/usr/bin/env bash
# ==============================================================================
# patch-node-site.sh — многофункциональный деплойер сайта для маскировки ВПН
# ==============================================================================
# Поддерживаемые режимы:
#   static  — статика (просто index.html + файлы)
#   spa     — SPA с fallback на index.html (Vite/CRA/Next static export)
#   ssr     — SSR-фреймворк (Next.js, Nuxt) или Node с build-шагом
#   node    — голый Node.js (server.js / index.js / app.js)
#   dummy   — заглушка (если ничего нет)
#   auto    — автоопределение по файлам проекта (по умолчанию)
#
# Запускать от root ПОСЛЕ setup.sh. Не трогает inbound'ы, БД 3x-ui, stream-слой.
# ==============================================================================
set -euo pipefail

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
CYAN=$'\033[0;36m'; BOLD=$'\033[1m'; DIM=$'\033[2m'; NC=$'\033[0m'
log(){  echo -e "${CYAN}[*]${NC} $*"; }
ok(){   echo -e "${GREEN}[+]${NC} $*"; }
warn(){ echo -e "${YELLOW}[!]${NC} $*"; }
die(){  echo -e "${RED}[x] $*${NC}" >&2; exit 1; }
has_cmd(){ command -v "$1" >/dev/null 2>&1; }

[[ $EUID -eq 0 ]] || die "Запускай от root."

usage() {
    cat <<EOF
Использование: $0 [ОПЦИИ]

Опции режима сайта:
  --mode=auto|static|spa|ssr|node|dummy   Режим (по умолчанию: auto)
  --dir=PATH                              Папка сайта (по умолчанию: /var/www/node-site)
  --port=PORT                             Порт Node (по умолчанию: 3000)
  --start=CMD                             Команда запуска (--mode=ssr|node)
  --domain=DOMAIN                         Домен (иначе автоопределение)
  --build                                 Форсировать сборку (npm ci && npm run build)
  --no-build                              Пропустить сборку (использовать готовые артефакты)
  --no-swap                               Не создавать swap при сборке
  --no-panel                              Не трогать путь панели 3x-ui
  --panel-path=PATH                       Задать свой путь панели
  --no-ufw                                Не менять правила UFW

Опции WebRTC / SFU:
  --webrtc                                Открыть UDP-порты для WebRTC RTP
  --sfu-range=MIN:MAX                     UDP-диапазон SFU (по умолчанию: 10000:20000)
  --turn                                  Открыть порты TURN (3478/udp, 5349/tcp)

Прочее:
  --dry-run                               Показать план, ничего не менять
  -h, --help                              Эта справка

Примеры:
  $0 --mode=spa --dir=/var/www/site
  $0 --mode=ssr --build --port=3000
  $0 --mode=spa --webrtc --sfu-range=40000:49999
  $0 --mode=ssr --build --webrtc --turn --domain=stream.example.com
EOF
}

# ============================ АРГУМЕНТЫ =====================================
MODE=auto
SITE_DIR=/var/www/node-site
SITE_PORT=3000
SITE_START=""
DOMAIN=""
PANEL_PATH_OVERRIDE=""
BUILD=auto
WEBRTC=0
SFU_RANGE="10000:20000"
TURN=0
NO_PANEL=0
NO_UFW=0
NO_SWAP=0
DRY_RUN=0

for arg in "$@"; do
    case "$arg" in
        --mode=*)       MODE="${arg#*=}" ;;
        --dir=*)        SITE_DIR="${arg#*=}" ;;
        --port=*)       SITE_PORT="${arg#*=}" ;;
        --start=*)      SITE_START="${arg#*=}" ;;
        --domain=*)     DOMAIN="${arg#*=}" ;;
        --panel-path=*) PANEL_PATH_OVERRIDE="${arg#*=}" ;;
        --build)        BUILD=yes ;;
        --no-build)     BUILD=no ;;
        --no-swap)      NO_SWAP=1 ;;
        --no-panel)     NO_PANEL=1 ;;
        --no-ufw)       NO_UFW=1 ;;
        --webrtc)       WEBRTC=1 ;;
        --sfu-range=*)  SFU_RANGE="${arg#*=}"; WEBRTC=1 ;;
        --turn)         TURN=1; WEBRTC=1 ;;
        --dry-run)      DRY_RUN=1 ;;
        -h|--help)      usage; exit 0 ;;
        *)              die "Неизвестный аргумент: $arg (--help)" ;;
    esac
done

case "$MODE" in
    auto|static|spa|ssr|node|dummy) ;;
    *) die "Неверный --mode=$MODE" ;;
esac

# ============================ СЛОВА ДЛЯ ПАНЕЛИ ===============================
WORDS=(river stone cloud maple tiger ember frost harbor echo lantern willow
       cedar falcon meadow silver amber velvet crystal shadow thunder whisper
       cosmic northern hidden sacred ancient silent blooming drifting fading
       granite marble copper iron jade pearl opal ruby sapphire topaz quartz
       onyx agate coral aqua azure cobalt crimson emerald golden indigo ivory
       birch pine oak ash elm aspen alder poplar magnolia cypress spruce)

pick_panel_path() {
    local a b
    while :; do
        a=${WORDS[$RANDOM % ${#WORDS[@]}]}
        b=${WORDS[$RANDOM % ${#WORDS[@]}]}
        [[ "$a" != "$b" ]] && break
    done
    echo "/${a}-${b}"
}

# ============================ ОПРЕДЕЛЕНИЕ РЕЖИМА =============================
detect_mode() {
    if [[ "$MODE" != "auto" ]]; then
        log "Режим задан вручную: $MODE"
        return 0
    fi
    if [[ ! -d "$SITE_DIR" ]]; then
        MODE=dummy
        warn "Папки $SITE_DIR нет → режим dummy"
        return 0
    fi
    # Next.js
    if compgen -G "$SITE_DIR/next.config.*" >/dev/null; then
        if [[ -d "$SITE_DIR/out" ]]; then
            MODE=spa; log "Обнаружен Next.js static export (out/)"; return 0
        elif [[ -d "$SITE_DIR/.next" ]]; then
            MODE=ssr; log "Обнаружен Next.js SSR (.next/)"; return 0
        else
            MODE=ssr; log "Обнаружен Next.js (нужна сборка)"; return 0
        fi
    fi
    # Vite
    if compgen -G "$SITE_DIR/vite.config.*" >/dev/null; then
        MODE=spa; log "Обнаружен Vite SPA"; return 0
    fi
    # Готовые артефакты SPA/static
    for d in out dist build public; do
        if [[ -f "$SITE_DIR/$d/index.html" ]]; then
            MODE=spa; log "Обнаружены готовые артефакты ($d/)"; return 0
        fi
    done
    # Голый index.html
    if [[ -f "$SITE_DIR/index.html" ]]; then
        MODE=static; log "Обнаружена статика (index.html)"; return 0
    fi
    # Голый Node
    if [[ -f "$SITE_DIR/package.json" ]]; then
        if [[ -f "$SITE_DIR/server.js" || -f "$SITE_DIR/index.js" || -f "$SITE_DIR/app.js" ]]; then
            MODE=node; log "Обнаружен голый Node.js"; return 0
        fi
        MODE=ssr; log "Обнаружен Node.js (package.json) — предполагаю SSR"; return 0
    fi
    MODE=dummy; warn "Проект не распознан → dummy"
}

# ============================ СБОРКА ========================================
detect_pkg_mgr() {
    if [[ -f "$SITE_DIR/pnpm-lock.yaml" ]]; then echo pnpm
    elif [[ -f "$SITE_DIR/yarn.lock" ]]; then echo yarn
    else echo npm
    fi
}

ensure_swap() {
    [[ "$NO_SWAP" -eq 1 ]] && return 0
    local swap_mb
    swap_mb=$(free -m | awk '/^Swap:/ {print $2+0}')
    if [[ "$swap_mb" -ge 512 ]]; then return 0; fi
    if [[ -f /swapfile ]]; then
        log "Активирую существующий /swapfile"
        swapon /swapfile 2>/dev/null || true
        return 0
    fi
    log "Создаю /swapfile 2GB (для сборки Next.js на слабом VPS)..."
    if fallocate -l 2G /swapfile 2>/dev/null \
        && chmod 600 /swapfile \
        && mkswap /swapfile >/dev/null 2>&1 \
        && swapon /swapfile 2>/dev/null; then
        ok "Swap 2GB активирован"
    else
        rm -f /swapfile 2>/dev/null || true
        warn "Не удалось создать swap — сборка может упасть по OOM"
    fi
}

build_site() {
    case "$MODE" in
        static|dummy) return 0 ;;
        spa)
            if [[ -d "$SITE_DIR/out" || -d "$SITE_DIR/dist" || -d "$SITE_DIR/build" ]]; then
                log "Артефакты уже есть, сборка пропущена"
                return 0
            fi
            [[ "$BUILD" == "auto" ]] && { warn "Артефактов нет. Укажи --build или собери локально"; return 0; }
            ;;
        ssr|node) ;;
    esac
    [[ "$BUILD" == "no" ]] && { log "Сборка пропущена (--no-build)"; return 0; }

    local mgr; mgr=$(detect_pkg_mgr)
    log "Сборка проекта ($mgr)..."
    ensure_swap

    if [[ "$DRY_RUN" -eq 1 ]]; then
        log "[DRY-RUN] пропускаю сборку"
        return 0
    fi

    case "$mgr" in
        pnpm)
            has_cmd pnpm || npm install -g pnpm >/dev/null 2>&1 || die "Не удалось поставить pnpm"
            ( cd "$SITE_DIR" && pnpm install --prod=false && pnpm build ) || die "pnpm build упал"
            ;;
        yarn)
            has_cmd yarn || npm install -g yarn >/dev/null 2>&1 || die "Не удалось поставить yarn"
            ( cd "$SITE_DIR" && yarn install && yarn build ) || die "yarn build упал"
            ;;
        *)
            ( cd "$SITE_DIR" && npm ci && npm run build ) || die "npm run build упал"
            ;;
    esac
    ok "Сборка завершена"
}

# ============================ САЙТ (systemd) ================================
setup_node_site() {
    # Для статики/SPA systemd не нужен
    case "$MODE" in
        static|spa) return 0 ;;
    esac

    if [[ ! -d "$SITE_DIR" ]]; then
        warn "Папки $SITE_DIR нет — создаю заглушку"
        mkdir -p "$SITE_DIR"
        cat > "$SITE_DIR/server.js" <<'EOF'
const http = require('http');
const port = process.env.PORT || 3000;
http.createServer((req, res) => {
  res.writeHead(200, {'Content-Type':'text/html; charset=utf-8'});
  res.end('<!doctype html><title>OK</title><h1>Site is ready</h1>');
}).listen(port, '127.0.0.1');
EOF
        MODE=node
        [[ -z "$SITE_START" ]] && SITE_START="node server.js"
    fi

    # Определяем дефолтную команду запуска
    if [[ -z "$SITE_START" ]]; then
        if [[ "$MODE" == "ssr" ]]; then
            SITE_START="npm start"
        elif [[ "$MODE" == "node" ]]; then
            if [[ -f "$SITE_DIR/server.js" ]]; then SITE_START="node server.js"
            elif [[ -f "$SITE_DIR/index.js" ]]; then SITE_START="node index.js"
            elif [[ -f "$SITE_DIR/app.js" ]]; then SITE_START="node app.js"
            else SITE_START="npm start"; fi
        fi
    fi

    if ! has_cmd node; then
        warn "Node.js не найден — устанавливаю через apt"
        apt-get update -qq && apt-get install -y nodejs npm || die "Node.js поставить не удалось"
    fi

    chown -R www-data:www-data "$SITE_DIR" 2>/dev/null || true

    if [[ "$DRY_RUN" -eq 1 ]]; then
        log "[DRY-RUN] создал бы systemd-юнит node-site.service с: $SITE_START"
        return 0
    fi

    log "Создаю systemd-юнит node-site.service (запуск: $SITE_START)"
    cat > /etc/systemd/system/node-site.service <<EOF
[Unit]
Description=Cover site for VPN mask
After=network.target

[Service]
Type=simple
WorkingDirectory=$SITE_DIR
ExecStart=/bin/bash -lc 'cd $SITE_DIR && $SITE_START'
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
    if systemctl is-active --quiet node-site.service; then
        ok "node-site.service активен (127.0.0.1:$SITE_PORT)"
    else
        warn "node-site.service НЕ активен. journalctl -u node-site -n 50"
    fi
}

# ============================ ПАНЕЛЬ 3X-UI =================================
setup_panel_path() {
    if [[ "$NO_PANEL" -eq 1 ]]; then
        log "Путь панели не трогаю (--no-panel)"
        [[ -f /etc/x-ui-panel-path.conf ]] && PANEL_PATH=$(awk -F= '/^PANEL_PATH=/{print $2; exit}' /etc/x-ui-panel-path.conf) || PANEL_PATH=""
        return 0
    fi

    local path_file=/etc/x-ui-panel-path.conf
    local old_path=""
    [[ -f "$path_file" ]] && old_path=$(awk -F= '/^PANEL_PATH=/{print $2; exit}' "$path_file" || true)

    local new_path
    if [[ -n "$PANEL_PATH_OVERRIDE" ]]; then
        new_path="/${PANEL_PATH_OVERRIDE#/}"
        log "Путь панели задан вручную: $new_path"
    elif [[ -n "$old_path" ]]; then
        new_path="$old_path"
        ok "Использую существующий путь: $new_path"
    else
        new_path=$(pick_panel_path)
        log "Сгенерирован путь панели: $new_path"
    fi
    new_path="${new_path%/}"

    [[ "$DRY_RUN" -eq 1 ]] && { PANEL_PATH="$new_path"; log "[DRY-RUN] панель была бы на $new_path"; return 0; }

    echo "PANEL_PATH=$new_path" > "$path_file"
    chmod 600 "$path_file"

    if has_cmd x-ui; then
        log "Применяю webBasePath в 3x-ui..."
        if x-ui setting -webBasePath "${new_path}/" 2>&1 | tee /tmp/xui-path.log; then
            systemctl restart x-ui 2>/dev/null || true
            sleep 1
            ok "3x-ui перезапущен, путь: ${new_path}/"
        else
            warn "x-ui setting не сработал — /tmp/xui-path.log"
        fi
    else
        warn "Команда x-ui не найдена — путь в nginx будет, но внутри 3x-ui останется старый"
    fi
    PANEL_PATH="$new_path"
}

# ============================ NGINX =========================================
find_nginx_conf_with_site() {
    local f
    for f in /etc/nginx/nginx.conf /etc/nginx/conf.d/*.conf; do
        [[ -f "$f" ]] || continue
        if grep -qE 'location[[:space:]]+/[[:space:]]*\{' "$f" 2>/dev/null; then
            echo "$f"
            return 0
        fi
    done
    return 1
}

ensure_ws_map() {
    # Проверяем, определён ли $connection_upgrade
    if grep -rqE 'map[[:space:]]+\$http_upgrade[[:space:]]+\$connection_upgrade' /etc/nginx/ 2>/dev/null; then
        echo '$connection_upgrade'
        return 0
    fi
    # Определяем
    if [[ "$DRY_RUN" -eq 0 ]]; then
        cat > /etc/nginx/conf.d/00-ws-map.conf <<'EOF'
# Managed by patch-node-site.sh — WebSocket upgrade map
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}
EOF
    fi
    echo '$connection_upgrade'
}

generate_location_block() {
    local mode="$1"
    local ws_conn="$2"
    case "$mode" in
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
            # Для Next static export папка = out/
            local root="$SITE_DIR"
            [[ -d "$SITE_DIR/out" ]] && root="$SITE_DIR/out"
            [[ -d "$SITE_DIR/dist" ]] && root="$SITE_DIR/dist"
            [[ -d "$SITE_DIR/build" ]] && root="$SITE_DIR/build"
            cat <<EOF
location / {
        root $root;
        index index.html;
        try_files \$uri \$uri/ /index.html;
        location ~* \\.(js|css|png|jpg|jpeg|gif|ico|svg|woff2?|ttf|eot)\$ {
            root $root;
            expires 7d;
            add_header Cache-Control "public, immutable";
        }
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
        proxy_set_header Connection $ws_conn;
        proxy_read_timeout 300s;
        proxy_buffering off;
    }
EOF
            ;;
    esac
}

# Заменяет location / на новый блок с корректным brace-matching
replace_location_slash() {
    local conf_file="$1"
    local new_block="$2"

    if [[ "$DRY_RUN" -eq 1 ]]; then
        log "[DRY-RUN] заменил бы location / в $conf_file на:"
        echo "$new_block" | sed 's/^/    /'
        return 0
    fi

    cp -a "$conf_file" "${conf_file}.bak.$(date +%s)" 2>/dev/null || true

    python3 - "$conf_file" <<PYEOF
import sys, re
path = sys.argv[1]
new_block = '''$new_block'''

with open(path, 'r', encoding='utf-8') as f:
    text = f.read()

# Ищем location / { с word-boundary — не задевая /api, /static и т.д.
# Регекс: location\s+/\s*\{   (не /что-то, ровно /)
matches = list(re.finditer(r'location\s+/\s*\{', text))
if not matches:
    print("[!] location / не найден", file=sys.stderr)
    sys.exit(1)

m = matches[0]
start = m.start()
i = m.end() - 1  # позиция {
depth = 0
end = None
while i < len(text):
    c = text[i]
    if c == '{':
        depth += 1
    elif c == '}':
        depth -= 1
        if depth == 0:
            end = i + 1
            break
    i += 1

if end is None:
    print("[!] Не найден закрывающий }", file=sys.stderr)
    sys.exit(1)

# Сохраняем отступ исходного location
indent = ' ' * (m.start() - text.rfind('\n', 0, m.start()) - 1)
block = new_block.rstrip()
# Применяем отступ к каждой строке нового блока
block = '\n'.join((indent + line) if idx > 0 else line for idx, line in enumerate(block.split('\n')))

new_text = text[:start] + block + text[end:]
with open(path, 'w', encoding='utf-8') as f:
    f.write(new_text)
print("[+] location / заменён")
PYEOF
}

patch_nginx() {
    has_cmd nginx || { warn "nginx не установлен — пропускаю HTTP-слой (у тебя Traefik?)"; return 0; }

    local conf_file
    if ! conf_file=$(find_nginx_conf_with_site); then
        warn "Не нашёл nginx.conf с location / — пропускаю"
        warn "Проверь вручную: grep -rn 'location /' /etc/nginx/"
        return 1
    fi
    log "Найден конфиг с location /: $conf_file"

    # Определяем $connection_upgrade
    local ws_conn
    ws_conn=$(ensure_ws_map)

    # Обновляем путь панели, если он есть
    if [[ -n "${PANEL_PATH:-}" ]]; then
        local old_panel_path
        old_panel_path=$(awk '/location \^~/{print $3; exit}' "$conf_file" 2>/dev/null || true)
        if [[ -n "$old_panel_path" && "$old_panel_path" != "${PANEL_PATH}/" ]]; then
            log "Заменяю путь панели в nginx: $old_panel_path → ${PANEL_PATH}/"
            [[ "$DRY_RUN" -eq 0 ]] && sed -i "s|${old_panel_path}|${PANEL_PATH}/|g" "$conf_file"
        fi
    fi

    local new_block
    new_block=$(generate_location_block "$MODE" "$ws_conn")
    replace_location_slash "$conf_file" "$new_block" || { warn "Не удалось заменить location /"; return 1; }

    if [[ "$DRY_RUN" -eq 1 ]]; then
        log "[DRY-RUN] nginx -t пропущен"
        return 0
    fi

    if nginx -t 2>/tmp/nginx-test.log; then
        systemctl reload nginx
        ok "nginx перезагружен"
    else
        warn "nginx -t упал:"
        sed 's/^/    /' /tmp/nginx-test.log
        local last_bak; last_bak=$(ls -1t "${conf_file}.bak."* 2>/dev/null | head -1)
        if [[ -n "$last_bak" ]]; then
            mv "$last_bak" "$conf_file"
            warn "Откатил $conf_file из бэкапа"
        fi
        return 1
    fi
}

# ============================ WEBRTC / SFU =================================
setup_webrtc() {
    [[ "$WEBRTC" -eq 0 ]] && return 0
    [[ "$NO_UFW" -eq 1 ]] && { warn "UFW не трогаю (--no-ufw), открой порты вручную"; return 0; }
    has_cmd ufw || { warn "ufw не найден — открой порты сам"; return 0; }

    log "Открываю UDP-порты для WebRTC RTP: $SFU_RANGE"
    if [[ "$DRY_RUN" -eq 0 ]]; then
        ufw allow "${SFU_RANGE}/udp" comment 'WebRTC RTP/SFU' 2>/dev/null || warn "ufw allow $SFU_RANGE/udp не сработал"
    fi

    if [[ "$TURN" -eq 1 ]]; then
        log "Открываю порты TURN (3478/udp, 5349/tcp)"
        if [[ "$DRY_RUN" -eq 0 ]]; then
            ufw allow 3478/udp comment 'TURN/STUN UDP' 2>/dev/null || true
            ufw allow 5349/tcp comment 'TURN over TLS' 2>/dev/null || true
        fi
    fi

    ok "Порты открыты"
    cat <<EOF

${DIM}─── Памятка по WebRTC/SFU ───${NC}
  • SFU должен слушать RTP на UDP ${SFU_RANGE}
  • Укажи в SFU его публичный IP (external-ip в конфиге mediasoup/LiveKit)
  • TURN на 443/TCP конфликтует с nginx — используй 5349/TCP или отдельный IP
  • Нагрузка: SFU ест CPU. Следи: ${CYAN}top${NC} / ${CYAN}htop${NC}
  • Zapret (NFQUEUE) чувствителен к CPU — при перегрузке будет терять пакеты ВПН
EOF
}

# ============================ UFW: закрыть панель ===========================
close_panel_port() {
    [[ "$NO_UFW" -eq 1 ]] && return 0
    has_cmd ufw || return 0
    if [[ "$DRY_RUN" -eq 1 ]]; then
        log "[DRY-RUN] закрыл бы 10443 снаружи"
        return 0
    fi
    log "Закрываю 10443 снаружи (панель только через nginx)"
    ufw --force delete allow 10443/tcp 2>/dev/null || true
    ufw deny 10443/tcp comment '[vpn-stack] panel via nginx only' 2>/dev/null || true
    ok "10443 закрыт снаружи"
}

# ============================ ПРОВЕРКА ====================================
verify() {
    [[ "$DRY_RUN" -eq 1 ]] && return 0
    log "Проверяю состояние..."
    local fail=0
    systemctl is-active --quiet x-ui && ok "x-ui активен" || { warn "x-ui НЕ активен"; fail=$((fail+1)); }
    nginx -t >/dev/null 2>&1 && ok "nginx конфиг валиден" || { warn "nginx конфиг невалиден"; fail=$((fail+1)); }
    case "$MODE" in
        ssr|node|dummy)
            systemctl is-active --quiet node-site && ok "node-site активен" || { warn "node-site НЕ активен"; fail=$((fail+1)); }
            ;;
        static|spa)
            ok "Сайт статический, systemd не требуется"
            ;;
    esac
    return 0
}

# ============================ MAIN ========================================
echo
echo -e "${BOLD}${CYAN}════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}${CYAN}  ПАТЧ: сайт + секретный путь панели + WebRTC-порты          ${NC}"
echo -e "${BOLD}${CYAN}════════════════════════════════════════════════════════════${NC}"
echo -e "  Папка:  ${YELLOW}$SITE_DIR${NC}"
echo -e "  Режим:  ${YELLOW}$MODE${NC}  (auto = автоопределение)"
echo -e "  Порт:   ${YELLOW}$SITE_PORT${NC}"
echo -e "  WebRTC: ${YELLOW}$([[ "$WEBRTC" -eq 1 ]] && echo "да, UDP $SFU_RANGE" || echo нет)${NC}"
echo -e "  TURN:   ${YELLOW}$([[ "$TURN" -eq 1 ]] && echo да || echo нет)${NC}"
echo -e "  DRY-RUN:${YELLOW}$([[ "$DRY_RUN" -eq 1 ]] && echo да || echo нет)${NC}"
echo

detect_mode
echo
build_site
echo
setup_node_site
echo
setup_panel_path
echo
patch_nginx
echo
setup_webrtc
echo
close_panel_port
echo
verify
echo

echo -e "${BOLD}${GREEN}Готово.${NC}"
case "$MODE" in
    static|spa) echo -e "  Сайт:  https://<домен>/  (статика из $SITE_DIR)" ;;
    ssr|node)   echo -e "  Сайт:  https://<домен>/  → proxy → 127.0.0.1:$SITE_PORT" ;;
    dummy)      echo -e "  Сайт:  https://<домен>/  (заглушка)" ;;
esac
[[ -n "${PANEL_PATH:-}" ]] && echo -e "  Панель: https://<домен>${PANEL_PATH}/"
echo -e "  Путь панели: /etc/x-ui-panel-path.conf"
echo
echo -e "${DIM}Логи сайта:  journalctl -u node-site -n 50${NC}"
echo -e "${DIM}Nginx:       nginx -t && systemctl reload nginx${NC}"
echo -e "${DIM}Панель 404:  nginx -T | grep -A3 '${PANEL_PATH:-/путь}'${NC}"