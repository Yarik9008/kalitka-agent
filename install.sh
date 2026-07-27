#!/usr/bin/env bash
# kalitka: установка агента на компьютер, к которому нужно подключаться.
#
# Агент (frpc) держит одно исходящее соединение до сервера — через SOCKS
# вашего VPN-клиента, то есть внутри Reality. Никаких портов на этой машине
# наружу не открывается, проброс через роутер не нужен.
#
#   ./install-agent.sh <строка-подключения> [опции]
#
# Опции:
#   --name ID          имя этой машины в туннелях (по умолчанию — hostname)
#   --mode РЕЖИМ       auto (по умолчанию) | vpn | direct
#                      vpn    — через SOCKS VPN-клиента;
#                      direct — websocket по HTTPS на :443, VPN не нужен;
#                      auto   — vpn, если найден SOCKS, иначе direct.
#   --direct           то же, что --mode direct
#   --ssh-port PORT    какой локальный порт публиковать как SSH (0 — не публиковать)
#   --vnc-port PORT    добавить приватный туннель к VNC (например 5900)
#   --http PORT        опубликовать локальный веб-сервис на https://ID.<домен>
#   --socks HOST:PORT  адрес SOCKS вашего VPN-клиента, если не определился сам
#   --no-service       не ставить автозапуск, только конфигурацию
set -euo pipefail

# ── ниже вклеен lib/common.sh из приватного репозитория kalitka ──
KALITKA_FRP_VERSION_FALLBACK="0.70.1"

k_say()  { printf '\033[1;36m[kalitka]\033[0m %s\n' "$*"; }
k_warn() { printf '\033[1;33m[kalitka]\033[0m %s\n' "$*"; }
k_die()  { printf '\033[1;31m[kalitka] ОШИБКА:\033[0m %s\n' "$*" >&2; exit 1; }

# ── платформа ───────────────────────────────────────────────────────────
k_detect_platform() {
	case "$(uname -s)" in
		Linux)  K_OS=linux ;;
		Darwin) K_OS=darwin ;;
		*) k_die "неподдерживаемая ОС: $(uname -s). Для Windows используйте PowerShell-скрипты." ;;
	esac
	case "$(uname -m)" in
		x86_64|amd64)  K_ARCH=amd64 ;;
		aarch64|arm64) K_ARCH=arm64 ;;
		armv7l)        K_ARCH=arm ;;
		*) k_die "неподдерживаемая архитектура: $(uname -m)" ;;
	esac
	export K_OS K_ARCH
}

# ── base64 (GNU и BSD ведут себя по-разному) ────────────────────────────
k_b64d() {
	if base64 --decode </dev/null >/dev/null 2>&1; then
		base64 --decode
	else
		base64 -D
	fi
}

# ── разбор строки подключения ───────────────────────────────────────────
# Строку печатает server/install.sh; внутри — компактный JSON в base64.
k_enroll_decode() {
	local raw json
	raw="$1"
	[[ -n "$raw" ]] || k_die "пустая строка подключения"
	json="$(printf '%s' "$raw" | tr -d '[:space:]' | k_b64d 2>/dev/null)" \
		|| k_die "строка подключения не разбирается — скопирована не целиком?"

	_jget() {
		printf '%s' "$json" | sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p"
	}
	K_SERVER="$(_jget server)"
	K_PORT="$(_jget port)"
	K_TOKEN="$(_jget token)"
	K_SECRET="$(_jget secret)"
	K_SUB="$(_jget sub)"
	# Вход для машин без VPN: websocket по HTTPS на обычный :443.
	K_GATE="$(_jget gate)"
	K_GATE_PORT="$(_jget gatePort)"

	[[ -n "$K_TOKEN" ]] || k_die "в строке подключения нет token"
	[[ -n "$K_SERVER" || -n "$K_GATE" ]] || k_die "в строке подключения нет ни server, ни gate"
	: "${K_PORT:=7000}"
	: "${K_GATE_PORT:=443}"
	export K_SERVER K_PORT K_TOKEN K_SECRET K_SUB K_GATE K_GATE_PORT
}

# ── выбор транспорта ────────────────────────────────────────────────────
# vpn    — через SOCKS VPN-клиента, управляющий порт на лупбэке сервера;
# direct — websocket по HTTPS на :443, VPN не нужен вовсе.
# auto   — vpn, если найден SOCKS, иначе direct.
k_resolve_mode() {
	local want="$1" socks="$2"
	case "$want" in
		vpn)
			[[ -n "$socks" ]] || k_die "режим vpn выбран, но SOCKS-прокси не найден"
			[[ -n "$K_SERVER" ]] || k_die "в строке подключения нет адреса для режима vpn"
			printf 'vpn' ;;
		direct)
			[[ -n "$K_GATE" ]] || k_die "в строке подключения нет gate — прямой режим недоступен"
			printf 'direct' ;;
		auto)
			if [[ -n "$socks" && -n "$K_SERVER" ]]; then printf 'vpn'
			elif [[ -n "$K_GATE" ]]; then printf 'direct'
			else k_die "не нашёл ни SOCKS для режима vpn, ни gate для прямого режима"; fi ;;
		*) k_die "неизвестный режим: $want (vpn | direct | auto)" ;;
	esac
}

# Печатает общую для агента и клиента шапку конфигурации frpc.
# Аргументы: <режим> <socks> <путь к логу>
k_frpc_header() {
	local mode="$1" socks="$2" logpath="$3"
	if [[ "$mode" == direct ]]; then
		cat <<EOF
# Прямой режим: управляющий канал идёт как websocket поверх обычного HTTPS
# на :443 и приходит на сервер через тот же Caddy, что обслуживает сайт.
# VPN не нужен; снаружи это неотличимо от запроса к сайту.
serverAddr = "$K_GATE"
serverPort = $K_GATE_PORT
transport.protocol = "wss"
EOF
	else
		cat <<EOF
# Режим через VPN: соединение идёт SOCKS-прокси VPN-клиента. Адрес
# $K_SERVER резолвится не здесь, а на стороне сервера — правило роутинга
# Xray перенаправляет его на управляющий порт frps, висящий на лупбэке.
serverAddr = "$K_SERVER"
serverPort = $K_PORT
transport.proxyURL = "socks5://$socks"
EOF
	fi
	cat <<EOF

auth.method = "token"
auth.token = "$K_TOKEN"

transport.tls.enable = true
transport.heartbeatInterval = 20
transport.heartbeatTimeout = 60

# Сеть дома и в дороге пропадает регулярно — переподключаемся без сдачи.
loginFailExit = false

log.to = "$logpath"
log.level = "info"
log.maxDays = 7
EOF
}

# ── поиск SOCKS-прокси VPN-клиента ──────────────────────────────────────
# Порт зависит от приложения: v2rayN/v2rayNG — 10808, Nekoray и sing-box — 2080,
# Hiddify — 12334, Clash — 7890. Пробуем по очереди, можно задать вручную:
#   export KALITKA_SOCKS=127.0.0.1:10808
k_socks_detect() {
	if [[ -n "${KALITKA_SOCKS:-}" ]]; then
		printf '%s' "$KALITKA_SOCKS"
		return 0
	fi
	local p
	for p in 10808 2080 12334 7890 1080 1081 10801 20170; do
		if k_port_open 127.0.0.1 "$p"; then
			printf '127.0.0.1:%s' "$p"
			return 0
		fi
	done
	return 1
}

k_port_open() {
	local host="$1" port="$2"
	if command -v nc >/dev/null 2>&1; then
		nc -z -w 2 "$host" "$port" >/dev/null 2>&1 && return 0
		return 1
	fi
	# без nc — пробуем через /dev/tcp (bash)
	(exec 3<>"/dev/tcp/$host/$port") >/dev/null 2>&1 && { exec 3<&- 3>&-; return 0; }
	return 1
}

# ── загрузка frpc ───────────────────────────────────────────────────────
k_frp_latest_version() {
	local v
	v="$(curl -fsSL --max-time 10 \
		https://api.github.com/repos/fatedier/frp/releases/latest 2>/dev/null \
		| sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"v\([^"]*\)".*/\1/p' | head -1)"
	printf '%s' "${v:-$KALITKA_FRP_VERSION_FALLBACK}"
}

# k_install_frpc <куда_положить_бинарь> [socks_для_загрузки]
k_install_frpc() {
	local dest="$1" socks="${2:-}" ver url tmp curl_opts=()
	k_detect_platform

	if [[ -x "$dest" && -z "${KALITKA_FORCE_DOWNLOAD:-}" ]]; then
		k_say "frpc уже установлен: $dest ($("$dest" --version 2>/dev/null || echo '?'))"
		return 0
	fi

	ver="${KALITKA_FRP_VERSION:-$(k_frp_latest_version)}"
	url="https://github.com/fatedier/frp/releases/download/v${ver}/frp_${ver}_${K_OS}_${K_ARCH}.tar.gz"
	tmp="$(mktemp -d)"

	k_say "скачиваю frp $ver для ${K_OS}/${K_ARCH}"
	if ! curl -fsSL --max-time 120 -o "$tmp/frp.tar.gz" "$url"; then
		if [[ -n "$socks" ]]; then
			k_warn "напрямую не скачалось, пробую через VPN ($socks)"
			curl -fsSL --max-time 180 --proxy "socks5h://$socks" -o "$tmp/frp.tar.gz" "$url" \
				|| k_die "не удалось скачать frp ни напрямую, ни через VPN"
		else
			k_die "не удалось скачать $url"
		fi
	fi

	tar -xzf "$tmp/frp.tar.gz" -C "$tmp"
	install -m 0755 "$tmp/frp_${ver}_${K_OS}_${K_ARCH}/frpc" "$dest" \
		|| k_die "не удалось положить frpc в $dest"
	rm -rf "$tmp"
	k_say "frpc установлен: $dest"
}


# Текст справки держим здесь, а не вырезаем из шапки файла: скрипт часто
# запускают как `curl … | bash`, и тогда файла, из которого можно читать, нет.
usage() {
	cat <<'USAGE'
kalitka: установка агента на компьютер, к которому нужно подключаться.

    install.sh <строка-подключения> [опции]

    --name ID          имя этой машины в туннелях (по умолчанию — hostname)
    --mode РЕЖИМ       auto (по умолчанию) | vpn | direct
    --direct           то же, что --mode direct
    --ssh-port PORT    какой локальный порт публиковать как SSH (0 — не публиковать)
    --public-ssh [П]   публичный адрес для SSH, как у ngrok: подключаться можно
                       обычным ssh без клиентской части. Без аргумента порт
                       выдаёт сервер, с аргументом — фиксированный
    --vnc-port PORT    добавить приватный туннель к VNC (например 5900)
    --http PORT        опубликовать локальный веб-сервис на https://ID.<домен>
    --socks HOST:PORT  адрес SOCKS вашего VPN-клиента, если не определился сам
    --no-service       не ставить автозапуск, только конфигурацию
USAGE
}

ENROLL=""
NAME=""
SSH_PORT=22
PUBLIC_SSH=""
VNC_PORT=""
HTTP_PORT=""
SOCKS_OVERRIDE=""
INSTALL_SERVICE=1
MODE=auto

while [[ $# -gt 0 ]]; do
	case "$1" in
		--name)       NAME="$2"; shift 2 ;;
		--mode)       MODE="$2"; shift 2 ;;
		--direct)     MODE=direct; shift ;;
		--ssh-port)   SSH_PORT="$2"; shift 2 ;;
		--public-ssh)
			# Аргумент необязателен: без него порт выберет сервер (remotePort = 0).
			if [[ "${2:-}" =~ ^[0-9]+$ ]]; then PUBLIC_SSH="$2"; shift 2
			else PUBLIC_SSH=0; shift; fi ;;
		--vnc-port)   VNC_PORT="$2"; shift 2 ;;
		--http)       HTTP_PORT="$2"; shift 2 ;;
		--socks)      SOCKS_OVERRIDE="$2"; shift 2 ;;
		--no-service) INSTALL_SERVICE=0; shift ;;
		-h|--help)    usage; exit 0 ;;
		*)            ENROLL="$1"; shift ;;
	esac
done

if [[ -z "$ENROLL" ]]; then
	printf 'Вставьте строку подключения (её печатает server/install.sh): '
	read -r ENROLL
fi
k_enroll_decode "$ENROLL"

k_detect_platform

# ── куда ставить ────────────────────────────────────────────────────────
if [[ $EUID -eq 0 ]]; then
	BIN_DIR=/usr/local/bin
	CONF_DIR=/etc/kalitka
	LOG_FILE=/var/log/kalitka-agent.log
	SCOPE=system
else
	BIN_DIR="$HOME/.local/bin"
	CONF_DIR="$HOME/.config/kalitka"
	LOG_FILE="$HOME/.local/state/kalitka/agent.log"
	SCOPE=user
	k_warn "запуск без root: агент будет работать от вашего пользователя"
fi
mkdir -p "$BIN_DIR" "$CONF_DIR" "$(dirname "$LOG_FILE")"
chmod 700 "$CONF_DIR"

# ── имя машины ──────────────────────────────────────────────────────────
if [[ -z "$NAME" ]]; then
	NAME="$(hostname -s 2>/dev/null || hostname)"
fi
NAME="$(printf '%s' "$NAME" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-' '-' | sed 's/^-*//;s/-*$//')"
[[ -n "$NAME" ]] || k_die "не получилось определить имя машины, задайте --name"
k_say "имя этой машины в туннелях: $NAME"

# ── SOCKS VPN-клиента ───────────────────────────────────────────────────
SOCKS="${SOCKS_OVERRIDE:-$(k_socks_detect || true)}"
MODE="$(k_resolve_mode "$MODE" "$SOCKS")"
if [[ "$MODE" == vpn ]]; then
	k_say "режим: через VPN (SOCKS $SOCKS)"
else
	k_say "режим: прямой — websocket по HTTPS на $K_GATE:$K_GATE_PORT, VPN не нужен"
fi

# ── frpc ────────────────────────────────────────────────────────────────
k_install_frpc "$BIN_DIR/frpc" "$SOCKS"

# ── конфигурация ────────────────────────────────────────────────────────
CONF="$CONF_DIR/frpc.toml"
{
	echo "# Конфигурация агента kalitka. Сгенерирована install-agent.sh."
	echo "# Содержит секреты — права 600, в репозиторий не класть."
	echo
	k_frpc_header "$MODE" "$SOCKS" "$LOG_FILE"
	echo "transport.poolCount = 3"

	if [[ "$SSH_PORT" != "0" ]]; then
		cat <<EOF

# Приватный туннель к SSH. Тип stcp: на сервере не открывается ни один порт,
# подключиться может только тот, у кого есть secretKey.
[[proxies]]
name = "$NAME-ssh"
type = "stcp"
secretKey = "$K_SECRET"
localIP = "127.0.0.1"
localPort = $SSH_PORT
EOF
	fi

	if [[ -n "$PUBLIC_SSH" ]]; then
		cat <<EOF

# Публичный SSH — модель ngrok: сервер открывает порт в интернет, и
# подключиться можно обычным ssh, без клиентской части. Обратная сторона —
# ваш sshd становится виден снаружи, так что вход по паролю лучше отключить.
# remotePort = 0 означает «пусть порт выберет сервер».
[[proxies]]
name = "$NAME-pubssh"
type = "tcp"
localIP = "127.0.0.1"
localPort = $SSH_PORT
remotePort = $PUBLIC_SSH
EOF
	fi

	if [[ -n "$VNC_PORT" ]]; then
		cat <<EOF

[[proxies]]
name = "$NAME-vnc"
type = "stcp"
secretKey = "$K_SECRET"
localIP = "127.0.0.1"
localPort = $VNC_PORT
EOF
	fi

	if [[ -n "$HTTP_PORT" ]]; then
		cat <<EOF

# Публичный HTTP-туннель: https://$NAME.$K_SUB
# Виден всем, кто знает адрес — прикройте basic_auth в Caddy, если нужно.
[[proxies]]
name = "$NAME-web"
type = "http"
subdomain = "$NAME"
localIP = "127.0.0.1"
localPort = $HTTP_PORT
EOF
	fi
} >"$CONF"
chmod 600 "$CONF"
k_say "конфигурация: $CONF"

# ── автозапуск ──────────────────────────────────────────────────────────
start_manually() {
	cat <<EOF

Автозапуск не ставился. Запускать вручную:
    $BIN_DIR/frpc -c $CONF
EOF
}

if [[ $INSTALL_SERVICE -eq 0 ]]; then
	start_manually
	exit 0
fi

if [[ "$K_OS" == linux ]]; then
	UNIT_BODY="[Unit]
Description=kalitka agent (frpc)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$BIN_DIR/frpc -c $CONF
Restart=always
RestartSec=10
# Сеть или VPN могут быть не готовы в момент старта — это норма, просто ждём.
StartLimitIntervalSec=0

[Install]
WantedBy=$( [[ $SCOPE == system ]] && echo multi-user.target || echo default.target )
"
	if [[ $SCOPE == system ]]; then
		printf '%s' "$UNIT_BODY" >/etc/systemd/system/kalitka-agent.service
		systemctl daemon-reload
		systemctl enable --now kalitka-agent.service
		sleep 2
		systemctl --no-pager --lines=10 status kalitka-agent.service || true
		k_say "сервис: systemctl status kalitka-agent"
	else
		mkdir -p "$HOME/.config/systemd/user"
		printf '%s' "$UNIT_BODY" >"$HOME/.config/systemd/user/kalitka-agent.service"
		systemctl --user daemon-reload
		systemctl --user enable --now kalitka-agent.service
		loginctl enable-linger "$USER" >/dev/null 2>&1 || \
			k_warn "не удалось включить linger — агент остановится при выходе из сессии"
		sleep 2
		systemctl --user --no-pager --lines=10 status kalitka-agent.service || true
		k_say "сервис: systemctl --user status kalitka-agent"
	fi
else
	PLIST="$HOME/Library/LaunchAgents/tech.kalitka.agent.plist"
	mkdir -p "$(dirname "$PLIST")"
	cat >"$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key><string>tech.kalitka.agent</string>
	<key>ProgramArguments</key>
	<array>
		<string>$BIN_DIR/frpc</string>
		<string>-c</string>
		<string>$CONF</string>
	</array>
	<key>RunAtLoad</key><true/>
	<key>KeepAlive</key><true/>
	<key>StandardErrorPath</key><string>$LOG_FILE</string>
</dict>
</plist>
EOF
	launchctl unload "$PLIST" >/dev/null 2>&1 || true
	launchctl load "$PLIST"
	k_say "launchd: tech.kalitka.agent загружен"
fi

cat <<EOF

──────────────────────────────────────────────────────────────────────────
 Агент установлен. Что теперь доступно:

   SSH:   на машине-клиенте  ./client/kalitka.sh ssh $NAME
$( [[ -n "$PUBLIC_SSH" ]] && echo "   SSH (публичный): адрес и порт покажет веб-панель — подключаться
          обычным ssh, клиентская часть не нужна" )
$( [[ -n "$VNC_PORT" ]] && echo "   VNC:   ./client/kalitka.sh open $NAME-vnc 5900" )
$( [[ -n "$HTTP_PORT" ]] && echo "   Веб:   https://$NAME.$K_SUB" )

 Лог агента: $LOG_FILE
──────────────────────────────────────────────────────────────────────────
EOF
