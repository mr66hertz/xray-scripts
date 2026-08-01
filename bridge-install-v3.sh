#!/usr/bin/env bash
#
# bridge-install-v3.sh — установка RU→EU моста (Xray VLESS + nginx-цель REALITY)
#                        схема "один Domestic → один или несколько Foreign"
#
# ВХОД: домен этого сервера + одна или несколько vless://-ссылок на Foreign,
#       как аргументы командной строки. Возвращает удобство one-liner'а.
#
#   ./bridge-install-v3.sh <domestic_domain> "<vless://...>" ["<vless://...>" ...]
#
# One-liner (как в исходном скрипте):
#   bash -c "$(curl -L <URL>/bridge-install-v3.sh)" -- domestic.net "vless://..."
#
# Проверка без изменений в системе (первым аргументом --dry-run):
#   ./bridge-install-v3.sh --dry-run domestic.net "vless://..."
#

set -euo pipefail

GRN='\033[1;32m'; RED='\033[1;31m'; YEL='\033[1;33m'; CYA='\033[1;36m'; NC='\033[0m'
DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && { DRY_RUN=true; shift; }

err() { echo -e "${RED}ОШИБКА: $*${NC}" >&2; exit 1; }
inf() { echo -e "${GRN}$*${NC}"; }
wrn() { echo -e "${YEL}$*${NC}"; }
hdr() { echo -e "\n${CYA}=== $* ===${NC}"; }

trap 'echo -e "\n${RED}Прервано на строке $LINENO. Система могла остаться в промежуточном состоянии.${NC}" >&2' ERR

# ------------------------------------------------------------------ аргументы

DOMAIN="${1:-}"; shift || true
VLESS_URLS=("$@")

[[ -n "$DOMAIN" ]] || err "не задан домен.
Использование: $0 [--dry-run] <domestic_domain> \"<vless://...>\" [...]"
[[ ${#VLESS_URLS[@]} -gt 0 ]] || err "не задано ни одной vless://-ссылки на Foreign."
$DRY_RUN || [[ $EUID -eq 0 ]] || err "нужны права root."

COUNT=${#VLESS_URLS[@]}
SERVER_PORT=443
XRAY_CONF="/usr/local/etc/xray/config.json"

# ------------------------------------------------------------ разбор ссылок
# Парсер идентичен рабочему bridge-stealing.sh: network берётся из type,
# extra — как есть. Никаких дефолтов-на-raw и форсов tcp→raw.

urldecode() { local d="${1//+/ }"; printf '%b' "${d//%/\\x}"; }

declare -a N_NAME N_ADDR N_PORT N_UUID N_NET N_SEC N_PATH N_MODE N_EXTRA \
           N_SNI N_FP N_PBK N_SID N_SPX
for (( i=0; i<COUNT; i++ )); do
    url="${VLESS_URLS[$i]}"
    [[ "$url" == vless://* ]] || err "неверный формат ссылки #$((i+1)): $url"

    body="${url#vless://}"
    name_enc="${body##*#}"; N_NAME[$i]="$(urldecode "$name_enc")"
    [[ -n "${N_NAME[$i]}" && "${N_NAME[$i]}" != "$body" ]] || N_NAME[$i]="Foreign.$((i+1))"

    body="${body%%#*}"
    N_UUID[$i]="${body%@*}"
    hostpart="${body#*@}"
    N_ADDR[$i]="${hostpart%%:*}"
    rest="${hostpart#*:}"
    N_PORT[$i]="${rest%%\?*}"
    query="${rest#*\?}"

    unset params; declare -A params
    IFS='&' read -ra pairs <<< "$query"
    for pair in "${pairs[@]}"; do
        params["${pair%%=*}"]="$(urldecode "${pair#*=}")"
    done

    # network — ПРЯМО из type (tcp — синоним raw в старых ссылках)
    N_NET[$i]="${params[type]:-raw}"
    [[ "${N_NET[$i]}" == "tcp" ]] && N_NET[$i]="raw"
    N_SEC[$i]="${params[security]:-reality}"
    N_PATH[$i]="${params[path]:-}"
    N_MODE[$i]="${params[mode]:-stream-one}"
    N_EXTRA[$i]="${params[extra]:-}"
    N_SNI[$i]="${params[sni]:-${N_ADDR[$i]}}"
    N_FP[$i]="${params[fp]:-firefox}"
    N_PBK[$i]="${params[pbk]:-}"
    N_SID[$i]="${params[sid]:-}"
    N_SPX[$i]="${params[spx]:-/}"

    [[ -n "${N_PBK[$i]}" ]] || err "нода #$((i+1)): в ссылке нет pbk (публичного ключа)."
    inf "  ${N_NAME[$i]}: ${N_ADDR[$i]}:${N_PORT[$i]} (${N_NET[$i]}${N_PATH[$i]:+ ${N_PATH[$i]}})"
done

inf "Domestic домен: $DOMAIN"
inf "Зарубежных нод: $COUNT"
$DRY_RUN && wrn "DRY-RUN: система не изменяется."

# ------------------------------------------------------- установка ПО

if ! $DRY_RUN; then
    hdr "Пакеты"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y curl jq dnsutils openssl nginx certbot wget tar qrencode

    hdr "BBR и лимиты"
    if [[ "$(sysctl -n net.ipv4.tcp_congestion_control)" != "bbr" ]]; then
        printf 'net.core.default_qdisc=fq\nnet.ipv4.tcp_congestion_control=bbr\n' > /etc/sysctl.d/999-bridge.conf
        sysctl --system >/dev/null; inf "BBR включён"
    else inf "BBR уже активен"; fi
    printf '*\tsoft\tnofile\t1048576\n*\thard\tnofile\t1048576\n' > /etc/security/limits.d/99-bridge.conf

    hdr "Сертификат Let's Encrypt"
    systemctl enable --now nginx; mkdir -p /var/www/html
    if [[ -f /etc/nginx/sites-available/default ]]; then NGINX_CONF="/etc/nginx/sites-available/default"
    else NGINX_CONF="/etc/nginx/conf.d/default.conf"; fi
    cat > "$NGINX_CONF" <<EOF
server {
    listen 80 default_server; server_name _;
    location /.well-known/acme-challenge/ { root /var/www/html; allow all; }
    location / { return 301 https://\$host\$request_uri; }
}
EOF
    nginx -t && systemctl reload nginx
    certbot certonly --webroot -w /var/www/html -d "$DOMAIN" \
        -m "mail@$DOMAIN" --agree-tos --non-interactive --keep-until-expiring \
        --deploy-hook "systemctl reload nginx" \
        || err "certbot не выпустил сертификат. Проверь A-запись $DOMAIN и порт 80."

    hdr "Xray"
    bash -c "$(curl -sL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
fi

# ------------------------------------------------------- секреты

hdr "Ключи"
if $DRY_RUN; then
    xray_privateKey="DRYRUN_PRIV"; xray_publicKey="DRYRUN_PUB"
else
    ko=$(xray x25519)
    xray_privateKey=$(echo "$ko" | awk -F': ' '/PrivateKey|Private key/{print $2}' | head -1)
    xray_publicKey=$(echo "$ko"  | awk -F': ' '/Password|Public key/{print $2}'   | head -1)
    [[ -n "$xray_privateKey" && -n "$xray_publicKey" ]] || err "не разобрать xray x25519."
fi
xray_shortId=$(openssl rand -hex 8)
path_xhttp=$(openssl rand -base64 15 | tr -dc 'a-z0-9' | head -c 6)
path_subpage=$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 20)
socksUser=$(openssl rand -base64 16 | tr -dc 'A-Za-z0-9' | head -c 8)
socksPasw=$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | head -c 20)

# ------------------------------------------------------- сборка config.json

hdr "config.json"

# extra по умолчанию — если в ссылке его нет. Тот же набор, что в исходных
# скриптах (маскировка паттерна под HTTP/2). Если extra есть в ссылке —
# используется он (as-is), а этот дефолт как fallback.
read -r -d '' XHTTP_EXTRA_DEFAULT <<'EOF' || true
{
  "xmux": { "cMaxReuseTimes": "1000-3000", "maxConcurrency": "3-5", "maxConnections": 0,
            "hKeepAlivePeriod": 0, "hMaxRequestTimes": "400-700", "hMaxReusableSecs": "1200-1800" },
  "headers": {}, "noGRPCHeader": false, "xPaddingBytes": "400-800",
  "scMaxEachPostBytes": 1500000, "scMinPostsIntervalMs": 20, "scStreamUpServerSecs": "60-240"
}
EOF

# --- аутбаунды: для каждой ноды корректный блок под её транспорт
OUTBOUNDS=""
for (( i=0; i<COUNT; i++ )); do
    if [[ "${N_NET[$i]}" == "raw" ]]; then
        # RAW+REALITY: flow=vision, никакого xhttpSettings
        STREAM=$(cat <<EOF
      "streamSettings": {
        "network": "raw",
        "security": "${N_SEC[$i]}",
        "realitySettings": {
          "show": false, "fingerprint": "${N_FP[$i]}",
          "serverName": "${N_SNI[$i]}", "password": "${N_PBK[$i]}",
          "shortId": "${N_SID[$i]}", "spiderX": "${N_SPX[$i]}"
        }
      }
EOF
)
        USERS="{ \"id\": \"${N_UUID[$i]}\", \"encryption\": \"none\", \"flow\": \"xtls-rprx-vision\" }"
    else
        # XHTTP+REALITY: extra из ссылки (или дефолт), path/mode, БЕЗ flow
        EX="${N_EXTRA[$i]}"; [[ -n "$EX" ]] || EX="$XHTTP_EXTRA_DEFAULT"
        STREAM=$(cat <<EOF
      "streamSettings": {
        "network": "xhttp",
        "security": "${N_SEC[$i]}",
        "xhttpSettings": { "mode": "${N_MODE[$i]}", "path": "${N_PATH[$i]}", "extra": $EX },
        "realitySettings": {
          "show": false, "fingerprint": "${N_FP[$i]}",
          "serverName": "${N_SNI[$i]}", "password": "${N_PBK[$i]}",
          "shortId": "${N_SID[$i]}", "spiderX": "${N_SPX[$i]}"
        }
      }
EOF
)
        USERS="{ \"id\": \"${N_UUID[$i]}\", \"encryption\": \"none\" }"
    fi
    OUTBOUNDS+=$(cat <<EOF
    {
      "tag": "proxy-$i",
      "protocol": "vless",
      "mux": { "enabled": false },
      "settings": { "vnext": [ { "address": "${N_ADDR[$i]}", "port": ${N_PORT[$i]}, "users": [ $USERS ] } ] },
$STREAM
    },
EOF
)
done

# --- клиенты входа: свой email на ноду (для привязки при нескольких выходах)
CLIENTS_RAW=""; CLIENTS_XHTTP=""; USER_RULES=""
# при нескольких нодах по умолчанию — общий UUID (failover через балансировщик);
# привязка «UUID→нода» здесь не включается, т.к. несовместима с failover.
CLIENT_UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "11111111-1111-1111-1111-111111111111")
CLIENTS_RAW="{ \"id\": \"$CLIENT_UUID\", \"flow\": \"xtls-rprx-vision\", \"email\": \"cli-raw@bridge\" }"
CLIENTS_XHTTP="{ \"id\": \"$CLIENT_UUID\", \"email\": \"cli-xh@bridge\" }"

# --- балансировщик только при 2+ нодах
OBSERVATORY=""; BALANCERS=""; DEFAULT_OUT="\"outboundTag\": \"proxy-0\""
if [[ $COUNT -gt 1 ]]; then
    OBSERVATORY='  "burstObservatory": { "subjectSelector": [ "proxy-" ], "pingConfig": { "destination": "https://cp.cloudflare.com/generate_204", "connectivity": "", "interval": "10s", "sampling": 5, "timeout": "8s" } },'
    BALANCERS='    "balancers": [ { "tag": "bal-proxy", "selector": [ "proxy-" ], "strategy": { "type": "leastLoad", "settings": { "expected": 1, "maxRTT": "3s", "tolerance": 0.3, "baselines": [ "1500ms" ] } } } ],'
    DEFAULT_OUT="\"balancerTag\": \"bal-proxy\""
fi

# --- домены, обязанные резолвиться напрямую (иначе цикл на старте)
BOOTSTRAP="\"domain:$DOMAIN\""
for (( i=0; i<COUNT; i++ )); do
    [[ "${N_ADDR[$i]}" =~ ^[0-9.]+$ ]] || BOOTSTRAP+=", \"domain:${N_ADDR[$i]}\""
done

CONFIG=$(cat <<EOF
{
  "log": { "loglevel": "warning", "dnsLog": false, "access": "/var/log/xray/access.log", "error": "/var/log/xray/error.log" },

$OBSERVATORY
  "dns": {
    "tag": "dns-internal",
    "queryStrategy": "UseIPv4",
    "disableFallbackIfMatch": true,
    "servers": [
      { "address": "https+local://77.88.8.8/dns-query", "domains": [ "geosite:category-ru", "geosite:yandex", "geosite:vk", $BOOTSTRAP ], "skipFallback": true },
      "https://1.1.1.1/dns-query",
      "https://8.8.8.8/dns-query",
      "localhost"
    ]
  },

  "inbounds": [
    {
      "tag": "bridge-raw",
      "listen": "0.0.0.0", "port": $SERVER_PORT, "protocol": "vless",
      "settings": { "clients": [ $CLIENTS_RAW ], "decryption": "none", "fallbacks": [ { "dest": "3333", "xver": 2 } ] },
      "streamSettings": {
        "network": "raw", "security": "reality", "sockopt": { "acceptProxyProtocol": false },
        "realitySettings": { "show": false, "xver": 2, "target": "/dev/shm/nginx.sock", "spiderX": "/", "shortIds": [ "$xray_shortId" ], "privateKey": "$xray_privateKey", "serverNames": [ "$DOMAIN" ] }
      },
      "sniffing": { "enabled": true, "destOverride": [ "http", "tls", "quic" ] }
    },
    {
      "tag": "bridge-xhttp",
      "listen": "127.0.0.1", "port": 3333, "protocol": "vless",
      "settings": { "clients": [ $CLIENTS_XHTTP ], "decryption": "none" },
      "streamSettings": { "network": "xhttp", "security": "none", "sockopt": { "acceptProxyProtocol": true }, "xhttpSettings": { "mode": "stream-one", "path": "/$path_xhttp", "acceptProxyProtocol": false } },
      "sniffing": { "enabled": true, "destOverride": [ "http", "tls", "quic" ] }
    },
    {
      "tag": "local-socks",
      "listen": "127.0.0.1", "port": 10443, "protocol": "mixed",
      "settings": { "udp": true, "auth": "password", "accounts": [ { "user": "$socksUser", "pass": "$socksPasw" } ] }
    }
  ],

  "outbounds": [
$OUTBOUNDS
    { "tag": "direct", "protocol": "freedom", "settings": { "domainStrategy": "ForceIPv4" } },
    { "tag": "block",  "protocol": "blackhole" }
  ],

  "routing": {
    "domainMatcher": "hybrid",
    "domainStrategy": "IPIfNonMatch",
$BALANCERS
    "rules": [
      { "inboundTag": [ "dns-internal" ], $DEFAULT_OUT },
      { "ip": [ "geoip:private" ], "outboundTag": "block" },
      { "port": "25", "outboundTag": "block" },
      { "protocol": [ "bittorrent" ], "outboundTag": "block" },
      { "domain": [ "geosite:category-ads", "geosite:win-spy", "geosite:private" ], "outboundTag": "block" },
      { "domain": [ $BOOTSTRAP ], "outboundTag": "direct" },
      { "domain": [ "geosite:category-ru", "geosite:yandex", "geosite:vk", "testipv6.net" ], "outboundTag": "direct" },
      { "ip": [ "geoip:ru" ], "outboundTag": "direct" },
      { "network": "tcp,udp", $DEFAULT_OUT }
    ]
  }
}
EOF
)

json_check() {
    if command -v jq >/dev/null 2>&1; then jq empty "$1"
    elif command -v python3 >/dev/null 2>&1; then python3 -c "import json,sys;json.load(open(sys.argv[1]))" "$1"
    else wrn "нет jq/python3 — JSON не проверен"; return 0; fi
}

if $DRY_RUN; then
    echo "$CONFIG" > ./config.dryrun.json
    json_check ./config.dryrun.json || err "JSON невалиден, смотри config.dryrun.json"
    inf "JSON валиден: ./config.dryrun.json"; inf "Dry-run завершён."; exit 0
fi

mkdir -p /usr/local/etc/xray /var/log/xray
[[ -f "$XRAY_CONF" ]] && cp "$XRAY_CONF" "$XRAY_CONF.bak-$(date +%Y%m%d-%H%M%S)"
echo "$CONFIG" > "$XRAY_CONF"
json_check "$XRAY_CONF" || err "сгенерированный JSON невалиден."

# ------------------------------------------------------- nginx (цель REALITY)

hdr "nginx (цель REALITY)"
WEB_PATH="/var/www/$DOMAIN"; mkdir -p "$WEB_PATH"
cat > "$NGINX_CONF" <<EOF
server {
    server_name $DOMAIN;
    listen unix:/dev/shm/nginx.sock ssl http2 proxy_protocol;
    set_real_ip_from unix:; real_ip_header proxy_protocol;
    root $WEB_PATH; index index.html;
    ssl_protocols TLSv1.2 TLSv1.3; ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_certificate     "/etc/letsencrypt/live/$DOMAIN/fullchain.pem";
    ssl_certificate_key "/etc/letsencrypt/live/$DOMAIN/privkey.pem";
    location ~ /\.ht { deny all; }
}
server {
    listen 80; server_name $DOMAIN;
    location /.well-known/acme-challenge/ { root /var/www/html; }
    location / { return 301 https://\$host\$request_uri; }
}
EOF

# --- маскировочный фейк-логин на корне (форма ничего не отправляет)
HEADERS=("Welcome to FileShare" "Login to Your CloudBox" "Enter Your Secure Vault" "Access Your DataVault" "Sign in to EasyFiles")
BTNS=("Sign In" "Log In" "Access Account" "Continue" "Secure Sign In")
ERRS=("Invalid username or password." "Connection timeout. Please try again." "Access denied by security policy." "Session expired. Please refresh.")
ACCENTS=("#2563eb" "#059669" "#dc2626" "#7c3aed" "#0891b2" "#ea580c")
H=${HEADERS[$RANDOM % ${#HEADERS[@]}]}; BT=${BTNS[$RANDOM % ${#BTNS[@]}]}
ER=${ERRS[$RANDOM % ${#ERRS[@]}]}; AC=${ACCENTS[$RANDOM % ${#ACCENTS[@]}]}
cat > "$WEB_PATH/index.html" <<EOF
<!DOCTYPE html><html lang="en"><head><meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>$H</title>
<style>*{box-sizing:border-box;margin:0;padding:0}body{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;min-height:100vh;display:flex;align-items:center;justify-content:center;background:linear-gradient(135deg,#eff6ff,#fff);padding:1rem}.card{width:100%;max-width:400px;padding:2rem;border-radius:12px;background:#fff;border:1px solid #cbd5e1;box-shadow:0 10px 40px rgba(0,0,0,.12)}.logo{width:48px;height:48px;margin:0 auto 1rem;border-radius:12px;background:$AC;display:flex;align-items:center;justify-content:center}.logo svg{width:26px;height:26px;stroke:#fff;fill:none;stroke-width:2}h1{font-size:1.4rem;text-align:center;margin-bottom:.4rem}.sub{text-align:center;color:#64748b;font-size:.85rem;margin-bottom:1.6rem}label{display:block;font-size:.7rem;text-transform:uppercase;letter-spacing:.05em;color:#64748b;font-weight:600;margin-bottom:.4rem}.field{margin-bottom:1.1rem}input{width:100%;padding:.7rem .9rem;border-radius:8px;border:1px solid #cbd5e1;outline:none}input:focus{border-color:$AC}button{width:100%;padding:.75rem;font-weight:600;color:#fff;background:$AC;border:none;border-radius:8px;cursor:pointer;display:flex;align-items:center;justify-content:center;gap:.5rem}.err{display:none;margin-bottom:1rem;padding:.7rem .9rem;border-radius:8px;font-size:.82rem;background:rgba(220,38,38,.1);border:1px solid rgba(220,38,38,.3);color:#dc2626}.err.show{display:block}.spin{width:15px;height:15px;border:2px solid rgba(255,255,255,.4);border-top-color:#fff;border-radius:50%;animation:sp .6s linear infinite}@keyframes sp{to{transform:rotate(360deg)}}@keyframes sh{25%{transform:translateX(-6px)}75%{transform:translateX(6px)}}.shake{animation:sh .4s}</style></head>
<body><div class="card" id="card"><div class="logo"><svg viewBox="0 0 24 24" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="11" width="18" height="11" rx="2"/><path d="M7 11V7a5 5 0 0 1 10 0v4"/></svg></div>
<h1>$H</h1><div class="sub">Sign in to continue</div><div class="err" id="err">$ER</div>
<form id="f" autocomplete="off"><div class="field"><label>Email</label><input type="email" id="u" required placeholder="user@domain.com"></div>
<div class="field"><label>Password</label><input type="password" id="p" required placeholder="Password"></div>
<button type="submit" id="b"><span id="bt">$BT</span></button></form></div>
<script>document.getElementById("f").addEventListener("submit",function(e){e.preventDefault();var b=document.getElementById("b"),bt=document.getElementById("bt"),er=document.getElementById("err"),c=document.getElementById("card"),o=bt.textContent;er.classList.remove("show");b.disabled=true;bt.innerHTML='<span class="spin"></span> Authenticating...';setTimeout(function(){b.disabled=false;bt.textContent=o;er.classList.add("show");c.classList.add("shake");setTimeout(function(){c.classList.remove("shake")},400);document.getElementById("p").value=""},600+Math.random()*900)});</script></body></html>
EOF
printf 'User-agent: *\nDisallow: /\n' > "$WEB_PATH/robots.txt"
nginx -t && systemctl restart nginx

# ------------------------------------------------------- geodata runetfreedom

hdr "geodata (runetfreedom)"
cat > /usr/local/bin/update-xray-geo.sh <<'GEOEOF'
#!/usr/bin/env bash
set -euo pipefail
DP="/usr/local/share/xray"; BASE="https://github.com/runetfreedom/russia-v2ray-rules-dat/releases/latest/download"
PROXY="${PROXY:-}"; log(){ echo "[$(date +%FT%T)] $*"; }
fetch(){ local a=(-fsSL --retry 5 --retry-delay 10 -H 'Cache-Control: no-cache' -o "$2"); [ -n "$PROXY" ] && a+=(-x "$PROXY"); curl "${a[@]}" "$1"; }
[ "$(id -u)" -eq 0 ] || { log "нужен root"; exit 1; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
for f in geoip.dat geosite.dat; do fetch "$BASE/$f" "$T/$f"; fetch "$BASE/$f.sha256sum" "$T/$f.sha256sum"; done
cd "$T"; for f in geoip.dat geosite.dat; do echo "$(awk '{print $1}' "$f.sha256sum")  $f" | sha256sum -c - || { log "хэш $f не сошёлся"; exit 1; }; done
install -d "$DP/backup"; for f in geoip.dat geosite.dat; do [ -f "$DP/$f" ] && cp -f "$DP/$f" "$DP/backup/$f.prev"; install -m644 "$T/$f" "$DP/$f"; done
if ! xray run -test -config /usr/local/etc/xray/config.json >/dev/null 2>&1; then
  log "конфиг не проходит проверку — откат"; for f in geoip.dat geosite.dat; do [ -f "$DP/backup/$f.prev" ] && cp -f "$DP/backup/$f.prev" "$DP/$f"; done; exit 1; fi
systemctl -q is-active xray && systemctl restart xray && log "xray перезапущен"; log "готово"
GEOEOF
chmod +x /usr/local/bin/update-xray-geo.sh
cat > /etc/systemd/system/geodata-update.service <<'EOF'
[Unit]
Description=Update Xray geodata (runetfreedom)
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/local/bin/update-xray-geo.sh
EOF
cat > /etc/systemd/system/geodata-update.timer <<'EOF'
[Unit]
Description=Weekly Xray geodata update
[Timer]
OnCalendar=weekly
Persistent=true
RandomizedDelaySec=2h
[Install]
WantedBy=timers.target
EOF
/usr/local/bin/update-xray-geo.sh || wrn "первое обновление geodata не удалось — запусти вручную позже"

# ------------------------------------------------------- systemd, логи

hdr "systemd и логи"
mkdir -p /etc/systemd/system/xray.service.d
printf '[Unit]\nAfter=nginx.service\nWants=nginx.service\n' > /etc/systemd/system/xray.service.d/10-after-nginx.conf
cat > /etc/logrotate.d/xray <<'EOF'
/var/log/xray/*.log { daily rotate 7 size 50M missingok notifempty compress delaycompress copytruncate }
EOF
systemctl daemon-reload
systemctl enable --now geodata-update.timer
xray run -test -config "$XRAY_CONF" || err "конфиг не прошёл проверку Xray."
systemctl enable xray; systemctl restart xray; sleep 2
systemctl -q is-active xray || err "Xray не запустился. journalctl -u xray -n 50"

# ------------------------------------------------------- ссылки + QR

hdr "Готово"
LINKS_FILE="/root/bridge-links.txt"
LINKS_PAGE="$WEB_PATH/$path_subpage.html"
{
  echo "# Мост $DOMAIN — $(date +%F' '%T)"
  echo "# Страница: https://$DOMAIN/$path_subpage.html"
  echo "# SOCKS диагностики: 127.0.0.1:10443  user=$socksUser pass=$socksPasw"
  echo; echo "## RAW REALITY VISION"
  echo "vless://$CLIENT_UUID@$DOMAIN:$SERVER_PORT?security=reality&type=tcp&flow=xtls-rprx-vision&sni=$DOMAIN&fp=firefox&pbk=$xray_publicKey&sid=$xray_shortId&spx=%2F#${DOMAIN}_raw"
  echo; echo "## XHTTP REALITY"
  echo "vless://$CLIENT_UUID@$DOMAIN:$SERVER_PORT?security=reality&type=xhttp&mode=stream-one&path=%2F$path_xhttp&sni=$DOMAIN&fp=firefox&pbk=$xray_publicKey&sid=$xray_shortId&spx=%2F#${DOMAIN}_xhttp"
} > "$LINKS_FILE"
chmod 600 "$LINKS_FILE"

{
echo '<!DOCTYPE html><html lang="ru"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="robots" content="noindex"><title>configs</title>'
echo '<style>body{font-family:ui-monospace,Menlo,Consolas,monospace;background:#121212;color:#e0e0e0;padding:14px;max-width:920px;margin:0 auto}h2{color:#c3e88d;font-size:15px;margin:14px 0 10px}.row{background:#1e1e1e;border:1px solid #333;border-radius:8px;padding:10px;margin-bottom:10px}.top{display:flex;align-items:center;gap:8px;flex-wrap:wrap}.label{background:#2c2c2c;color:#82aaff;padding:5px 10px;border-radius:5px;font-weight:700;font-size:12px}.code{flex:1;min-width:180px;overflow-x:auto;padding:7px 9px;background:#121212;border-radius:5px;color:#c3e88d;font-size:11px;white-space:nowrap}.btn{border:1px solid #555;background:#333;color:#e0e0e0;padding:6px 12px;border-radius:5px;cursor:pointer;font-weight:700;font-size:12px;font-family:inherit}.btn:hover{background:#c3e88d;color:#121212}.qr{margin-top:10px;display:none;text-align:center}.qr.show{display:block}.qr svg{width:220px;height:220px;background:#fff;padding:10px;border-radius:8px}</style></head><body><h2>Конфигурации подключения</h2>'
j=0
for pair in "RAW REALITY VISION|vless://$CLIENT_UUID@$DOMAIN:$SERVER_PORT?security=reality&type=tcp&flow=xtls-rprx-vision&sni=$DOMAIN&fp=firefox&pbk=$xray_publicKey&sid=$xray_shortId&spx=%2F#${DOMAIN}_raw" \
            "XHTTP REALITY|vless://$CLIENT_UUID@$DOMAIN:$SERVER_PORT?security=reality&type=xhttp&mode=stream-one&path=%2F$path_xhttp&sni=$DOMAIN&fp=firefox&pbk=$xray_publicKey&sid=$xray_shortId&spx=%2F#${DOMAIN}_xhttp"; do
    lbl="${pair%%|*}"; url="${pair#*|}"
    esc=$(printf '%s' "$url" | sed 's/&/\&amp;/g')
    qr=$(printf '%s' "$url" | qrencode -t SVG -m 1 --inline -o - 2>/dev/null)
    echo "<div class=\"row\"><div class=\"top\"><span class=\"label\">$lbl</span><span class=\"code\" id=\"c$j\">$esc</span><button class=\"btn\" onclick=\"cp('c$j',this)\">Copy</button><button class=\"btn\" onclick=\"document.getElementById('q$j').classList.toggle('show')\">QR</button></div><div class=\"qr\" id=\"q$j\">$qr</div></div>"
    j=$((j+1))
done
echo '<script>function cp(i,b){var t=document.getElementById(i).innerText,o=b.innerText;navigator.clipboard.writeText(t).then(function(){b.innerText="OK";setTimeout(function(){b.innerText=o},1200)})}</script></body></html>'
} > "$LINKS_PAGE"
chmod 644 "$LINKS_PAGE"

cat "$LINKS_FILE"
echo
inf "Страница со ссылками и QR: https://$DOMAIN/$path_subpage.html"
inf "SOCKS для зонда: user=$socksUser pass=$socksPasw"
echo
wrn "Проверка звена B (должен вернуть IP+страну Foreign-сервера):"
echo "  curl -s --max-time 12 --socks5-hostname 127.0.0.1:10443 --proxy-user '$socksUser:$socksPasw' https://ipinfo.io/json | jq '{ip,country}'"
