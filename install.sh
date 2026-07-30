#!/usr/bin/env bash
# gatelink: установка агента на компьютер, к которому нужно подключаться.
#
# Агент (frpc) держит одно исходящее соединение до сервера — через SOCKS
# вашего VPN-клиента, то есть внутри Reality. Никаких портов на этой машине
# наружу не открывается, проброс через роутер не нужен.
#
#   ./install-agent.sh <строка-подключения> [опции]
#
# Ничего не публикуется само: какие локальные порты станут доступны, задаётся
# флагами. Это осознанно — раньше SSH публиковался по умолчанию, и установка
# агента молча открывала доступ к нему.
#
# Опции:
#   --name ID          имя этой машины (по умолчанию — из строки подключения,
#                      а если её выдали без имени — hostname)
#   --mode РЕЖИМ       auto (по умолчанию) | vpn | direct
#                      vpn    — через SOCKS VPN-клиента;
#                      direct — websocket по HTTPS на :443, VPN не нужен;
#                      auto   — vpn, если найден SOCKS, иначе direct.
#   --direct           то же, что --mode direct
#   --ssh-port PORT    опубликовать SSH с этого локального порта (обычно 22)
#   --vnc-port PORT    добавить приватный туннель к VNC (например 5900)
#   --http PORT        опубликовать локальный веб-сервис на https://ID.<домен>
#   --socks HOST:PORT  адрес SOCKS вашего VPN-клиента, если не определился сам
#   --no-service       не ставить автозапуск, только конфигурацию
set -euo pipefail

# ── ниже вклеен lib/common.sh из приватного репозитория gatelink ──
# Версия frp зафиксирована намеренно. Раньше здесь запрашивался «latest» из
# GitHub API, и каждая машина получала то, что оказалось актуальным в момент
# установки: разные версии на разных машинах и молчаливое обновление до релиза,
# которого никто не смотрел. Обновление версии — осознанная правка этой строки.
GATELINK_FRP_VERSION_DEFAULT="0.70.1"

k_say()  { printf '\033[1;36m[gatelink]\033[0m %s\n' "$*"; }
k_warn() { printf '\033[1;33m[gatelink]\033[0m %s\n' "$*"; }
k_die()  { printf '\033[1;31m[gatelink] ОШИБКА:\033[0m %s\n' "$*" >&2; exit 1; }

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
	# Строка агента (enroll.py --agent) содержит имя машины и её персональный
	# секрет; строка клиента (enroll.py --client) — мастер-секрет, из которого
	# клиент выводит секрет любой машины сам. См. k_stcp_secret.
	K_NAME="$(_jget name)"
	K_MASTER="$(_jget master)"

	[[ -n "$K_TOKEN" ]] || k_die "в строке подключения нет token"
	[[ -n "$K_SERVER" || -n "$K_GATE" ]] || k_die "в строке подключения нет ни server, ни gate"
	: "${K_PORT:=7000}"
	: "${K_GATE_PORT:=443}"
	export K_SERVER K_PORT K_TOKEN K_SECRET K_SUB K_GATE K_GATE_PORT K_NAME K_MASTER
}

# ── секрет приватного туннеля ───────────────────────────────────────────
# Секрет у каждой машины свой и выводится из мастер-секрета:
#
#     secret(машина) = HMAC-SHA256(мастер, "gatelink-stcp-v1:" + имя_машины)
#
# Смысл: агент получает только свой секрет, поэтому украденная с одной машины
# конфигурация не открывает приватные туннели остальных. Мастер есть только на
# сервере и на машине-визиторе (той, С КОТОРОЙ подключаются), а она и так имеет
# доступ ко всем. Вывод детерминированный, поэтому визитору не нужен ни реестр
# секретов, ни обращение к серверу — он считает нужный секрет на месте.
#
# k_stcp_secret <мастер> <имя-машины>
k_stcp_secret() {
	local master="$1" name="$2" msg
	[[ -n "$master" ]] || k_die "внутренняя ошибка: k_stcp_secret без мастер-секрета"
	[[ -n "$name" ]]   || k_die "внутренняя ошибка: k_stcp_secret без имени машины"
	msg="gatelink-stcp-v1:$name"
	if command -v openssl >/dev/null 2>&1; then
		printf '%s' "$msg" | openssl dgst -sha256 -hmac "$master" | awk '{print $NF}'
	elif command -v python3 >/dev/null 2>&1; then
		python3 -c 'import hmac,hashlib,sys;print(hmac.new(sys.argv[1].encode(),sys.argv[2].encode(),hashlib.sha256).hexdigest())' \
			"$master" "$msg"
	else
		k_die "нужен openssl или python3, чтобы вывести секрет туннеля"
	fi
}

# Имя машины из имени туннеля: `home-ssh` → `home`. Секрет привязан к машине,
# а не к отдельному сервису, поэтому все туннели одной машины делят один секрет.
k_machine_of() {
	local name="$1"
	if [[ "$name" == *-* ]]; then printf '%s' "${name%-*}"; else printf '%s' "$name"; fi
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
#   export GATELINK_SOCKS=127.0.0.1:10808
#
# Важно: через найденный прокси пойдёт управляющий канал с токеном, а TLS до
# frps идёт без проверки сертификата сервера (frps отдаёт самоподписанный).
# То есть любой локальный процесс, успевший занять один из этих портов, увидит
# токен. На машине, где могут работать чужие программы, порт лучше задавать
# явно через GATELINK_SOCKS, а не полагаться на автоопределение.
k_socks_detect() {
	if [[ -n "${GATELINK_SOCKS:-}" ]]; then
		printf '%s' "$GATELINK_SOCKS"
		return 0
	fi
	local p
	for p in 10808 2080 12334 7890 1080 1081 10801 20170; do
		if k_port_open 127.0.0.1 "$p"; then
			k_warn "SOCKS найден автоопределением на 127.0.0.1:$p." >&2
			k_warn "Через него пойдёт токен — если на машине бывают чужие процессы, задайте порт явно (GATELINK_SOCKS)." >&2
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
# Считает sha256 файла тем, что есть в системе (GNU coreutils, BSD/macOS, или
# openssl как последний вариант).
k_sha256() {
	local f="$1"
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$f" | awk '{print $1}'
	elif command -v shasum >/dev/null 2>&1; then
		shasum -a 256 "$f" | awk '{print $1}'
	elif command -v openssl >/dev/null 2>&1; then
		openssl dgst -sha256 "$f" | awk '{print $NF}'
	else
		return 1
	fi
}

# k_install_frpc <куда_положить_бинарь> [socks_для_загрузки]
#
# Версия фиксирована (GATELINK_FRP_VERSION_DEFAULT), архив сверяется с
# frp_sha256_checksums.txt из того же релиза. HTTPS сам по себе гарантирует
# только «файл пришёл от github», а не «файл тот, который мы ожидали»: без
# проверки суммы подменённый или битый архив ставится молча.
k_install_frpc() {
	local dest="$1" socks="${2:-}" ver url sums_url tmp archive want got

	k_detect_platform

	if [[ -x "$dest" && -z "${GATELINK_FORCE_DOWNLOAD:-}" ]]; then
		k_say "frpc уже установлен: $dest ($("$dest" --version 2>/dev/null || echo '?'))"
		return 0
	fi

	ver="${GATELINK_FRP_VERSION:-$GATELINK_FRP_VERSION_DEFAULT}"
	archive="frp_${ver}_${K_OS}_${K_ARCH}.tar.gz"
	url="https://github.com/fatedier/frp/releases/download/v${ver}/${archive}"
	sums_url="https://github.com/fatedier/frp/releases/download/v${ver}/frp_sha256_checksums.txt"
	tmp="$(mktemp -d)"

	# Загрузка одного URL: сначала напрямую, при неудаче — через VPN, если он есть.
	_fetch() {
		local out="$1" src="$2"
		curl -fsSL --max-time 180 -o "$out" "$src" && return 0
		if [[ -n "$socks" ]]; then
			k_warn "напрямую не скачалось, пробую через VPN ($socks)"
			curl -fsSL --max-time 240 --proxy "socks5h://$socks" -o "$out" "$src" && return 0
		fi
		return 1
	}

	k_say "скачиваю frp $ver для ${K_OS}/${K_ARCH}"
	_fetch "$tmp/frp.tar.gz" "$url" || { rm -rf "$tmp"; k_die "не удалось скачать $url"; }
	_fetch "$tmp/sums.txt"   "$sums_url" \
		|| { rm -rf "$tmp"; k_die "не удалось скачать список контрольных сумм $sums_url"; }

	want="$(awk -v f="$archive" '$2 == f || $2 == "*" f {print $1; exit}' "$tmp/sums.txt")"
	got="$(k_sha256 "$tmp/frp.tar.gz")" \
		|| { rm -rf "$tmp"; k_die "нечем посчитать sha256 (нужен sha256sum, shasum или openssl)"; }
	if [[ -z "$want" ]]; then
		rm -rf "$tmp"
		k_die "в списке контрольных сумм нет строки для $archive — версия $ver собрана без этой платформы?"
	fi
	if [[ "$want" != "$got" ]]; then
		rm -rf "$tmp"
		k_die "контрольная сумма не совпала для $archive
  ожидалось: $want
  получено:  $got
Архив НЕ распакован. Это либо повреждённая загрузка, либо подмена файла."
	fi
	k_say "sha256 совпал"

	tar -xzf "$tmp/frp.tar.gz" -C "$tmp"
	install -m 0755 "$tmp/frp_${ver}_${K_OS}_${K_ARCH}/frpc" "$dest" \
		|| { rm -rf "$tmp"; k_die "не удалось положить frpc в $dest"; }
	rm -rf "$tmp"
	k_say "frpc установлен: $dest"
}


# Текст справки держим здесь, а не вырезаем из шапки файла: скрипт часто
# запускают как `curl … | bash`, и тогда файла, из которого можно читать, нет.
usage() {
	cat <<'USAGE'
gatelink: установка агента на компьютер, к которому нужно подключаться.

    install.sh <строка-подключения> [опции]

Без флагов публикации агент не публикует ничего: подключается к серверу и ждёт.
Какие локальные порты станут доступны — решаете вы.

    --name ID          имя этой машины (по умолчанию — из строки подключения)
    --mode РЕЖИМ       auto (по умолчанию) | vpn | direct
    --direct           то же, что --mode direct
    --ssh-port PORT    опубликовать SSH с этого локального порта (обычно 22)
    --public-ssh [П]   публичный адрес для SSH, как у ngrok: подключаться можно
                       обычным ssh без клиентской части. Без аргумента порт
                       выдаёт сервер, с аргументом — фиксированный
    --vnc-port PORT    добавить приватный туннель к VNC (например 5900)
    --http PORT        опубликовать локальный веб-сервис на https://ID.<домен>
    --socks HOST:PORT  адрес SOCKS вашего VPN-клиента, если не определился сам
    --no-service       не ставить автозапуск, только конфигурацию

Примеры:
    install.sh '<строка>' --ssh-port 22            приватный доступ по SSH
    install.sh '<строка>' --http 3000              веб-сервис наружу
USAGE
}

ENROLL=""
NAME=""
SSH_PORT=0
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
	CONF_DIR=/etc/gatelink
	LOG_FILE=/var/log/gatelink-agent.log
	SCOPE=system
else
	BIN_DIR="$HOME/.local/bin"
	CONF_DIR="$HOME/.config/gatelink"
	LOG_FILE="$HOME/.local/state/gatelink/agent.log"
	SCOPE=user
	k_warn "запуск без root: агент будет работать от вашего пользователя"
fi
mkdir -p "$BIN_DIR" "$CONF_DIR" "$(dirname "$LOG_FILE")"
chmod 700 "$CONF_DIR"

# ── имя машины ──────────────────────────────────────────────────────────
# Имя приходит в строке подключения: секрет этой машины выведен именно из него
# (HMAC от имени), поэтому переименовать машину на этой стороне нельзя — секрет
# перестанет совпадать с тем, что посчитает визитор. Нужно другое имя — новая
# строка подключения: server/enroll.py agent --name ДРУГОЕ-ИМЯ.
if [[ -n "$K_NAME" ]]; then
	if [[ -n "$NAME" && "$NAME" != "$K_NAME" ]]; then
		k_die "строка подключения выдана на имя «$K_NAME», а --name задаёт «$NAME».
Секрет этой машины выведен из имени, поэтому имя менять здесь нельзя.
Возьмите строку для нужного имени: server/enroll.py agent --name $NAME"
	fi
	NAME="$K_NAME"
else
	# Строка старого формата, одна на всех: имя выбирает сама машина.
	[[ -n "$NAME" ]] || NAME="$(hostname -s 2>/dev/null || hostname)"
	k_warn "строка подключения старого формата — секрет общий для всех машин."
	k_warn "Перевыпустите её на сервере: server/enroll.py agent --name ИМЯ"
fi
NAME="$(printf '%s' "$NAME" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-' '-' | sed 's/^-*//;s/-*$//')"
[[ -n "$NAME" ]] || k_die "не получилось определить имя машины, задайте --name"
[[ ${#NAME} -le 31 ]] || k_die "имя длиннее 31 символа: $NAME"
k_say "имя этой машины в туннелях: $NAME"

[[ -n "$K_SECRET" ]] || k_die "в строке подключения нет секрета приватных туннелей"

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
	echo "# Конфигурация агента gatelink. Сгенерирована install-agent.sh."
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

if [[ "$SSH_PORT" == "0" && -z "$PUBLIC_SSH" && -z "$VNC_PORT" && -z "$HTTP_PORT" ]]; then
	k_warn "не указано ни одного порта — агент подключится к серверу, но ничего не опубликует."
	k_warn "Чтобы открыть доступ по SSH, перезапустите с флагом: --ssh-port 22"
fi

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
Description=gatelink agent (frpc)
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
		printf '%s' "$UNIT_BODY" >/etc/systemd/system/gatelink-agent.service
		systemctl daemon-reload
		systemctl enable gatelink-agent.service
		# Именно restart, а не `enable --now`: при повторной установке сервис уже
		# запущен, `--now` его не трогает, и агент продолжает работать со старой
		# конфигурацией. Заодно снимается вторая копия, если она осталась.
		systemctl restart gatelink-agent.service
		sleep 2
		systemctl --no-pager --lines=10 status gatelink-agent.service || true
		k_say "сервис: systemctl status gatelink-agent"
	else
		mkdir -p "$HOME/.config/systemd/user"
		printf '%s' "$UNIT_BODY" >"$HOME/.config/systemd/user/gatelink-agent.service"
		systemctl --user daemon-reload
		systemctl --user enable gatelink-agent.service
		systemctl --user restart gatelink-agent.service
		loginctl enable-linger "$USER" >/dev/null 2>&1 || \
			k_warn "не удалось включить linger — агент остановится при выходе из сессии"
		sleep 2
		systemctl --user --no-pager --lines=10 status gatelink-agent.service || true
		k_say "сервис: systemctl --user status gatelink-agent"
	fi
else
	PLIST="$HOME/Library/LaunchAgents/tech.gatelink.agent.plist"
	mkdir -p "$(dirname "$PLIST")"
	cat >"$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key><string>tech.gatelink.agent</string>
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
	k_say "launchd: tech.gatelink.agent загружен"
fi

cat <<EOF

──────────────────────────────────────────────────────────────────────────
 Агент установлен. Что теперь доступно:

$( [[ "$SSH_PORT" != "0" ]] && echo "   SSH:   на машине-клиенте  ./client/gatelink.sh ssh $NAME" )
$( [[ -n "$PUBLIC_SSH" ]] && echo "   SSH (публичный): адрес и порт покажет веб-панель — подключаться
          обычным ssh, клиентская часть не нужна" )
$( [[ -n "$VNC_PORT" ]] && echo "   VNC:   ./client/gatelink.sh open $NAME-vnc 5900" )
$( [[ -n "$HTTP_PORT" ]] && echo "   Веб:   https://$NAME.$K_SUB" )

 Лог агента: $LOG_FILE
──────────────────────────────────────────────────────────────────────────
EOF
