#!/usr/bin/env bash
# gatelink: полное удаление агента с этого компьютера.
#
# Снимает автозапуск, убивает процесс и стирает всё, что положил установщик:
# бинарь frpc, конфигурацию с секретами и логи. Ничего, кроме своего, не трогает.
#
#   ./uninstall-agent.sh            удалить
#   ./uninstall-agent.sh --dry-run  только показать, что будет удалено
#
# Скрипт намеренно самодостаточный: его запускают через `curl | bash` на
# машине, где от gatelink уже ничего не должно остаться.
set -euo pipefail

DRY=0
[[ "${1:-}" == "--dry-run" ]] && DRY=1

say()  { printf '\033[1;36m[gatelink]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[gatelink]\033[0m %s\n' "$*"; }

run() {
	if [[ $DRY -eq 1 ]]; then
		printf '   would: %s\n' "$*"
	else
		"$@" >/dev/null 2>&1 || true
	fi
}

drop() {
	local p="$1"
	# nullglob убирает только шаблоны, не нашедшие совпадений; обычный путь без
	# метасимволов остаётся в списке, даже если файла нет, — поэтому ниже ещё и
	# явная проверка существования, иначе скрипт «удалял» бы несуществующее.
	local matches=()
	shopt -s nullglob
	matches=($p)
	shopt -u nullglob
	local m
	for m in "${matches[@]}"; do
		[[ -e "$m" || -L "$m" ]] || continue
		if [[ $DRY -eq 1 ]]; then
			printf '   would remove: %s\n' "$m"
		else
			rm -rf "$m" && say "удалено: $m"
		fi
	done
}

[[ $DRY -eq 1 ]] && say "пробный запуск, ничего не удаляю"

# ── автозапуск ──────────────────────────────────────────────────────────
# Наличие сервиса проверяем по файлу юнита, а не через
# `systemctl list-unit-files | grep -q`: под `set -o pipefail` grep закрывает
# пайп на первом совпадении, systemctl получает SIGPIPE, и условие ложно
# ровно тогда, когда сервис есть.
SYS_UNIT=/etc/systemd/system/gatelink-agent.service
USER_UNIT="$HOME/.config/systemd/user/gatelink-agent.service"

if command -v systemctl >/dev/null 2>&1; then
	if [[ $EUID -eq 0 && -f "$SYS_UNIT" ]]; then
		say "снимаю системный сервис gatelink-agent"
		run systemctl disable --now gatelink-agent.service
		drop "$SYS_UNIT"
		run systemctl daemon-reload
		run systemctl reset-failed gatelink-agent.service
	fi
	if [[ -f "$USER_UNIT" ]]; then
		say "снимаю пользовательский сервис gatelink-agent"
		run systemctl --user disable --now gatelink-agent.service
		drop "$USER_UNIT"
		run systemctl --user daemon-reload
	fi
fi

PLIST="$HOME/Library/LaunchAgents/tech.gatelink.agent.plist"
if [[ -f "$PLIST" ]]; then
	say "снимаю launchd-агент"
	run launchctl unload "$PLIST"
	drop "$PLIST"
fi

# ── остатки процессов ───────────────────────────────────────────────────
# Установленный вручную второй экземпляр не знает ни про systemd, ни про
# launchd — снимаем по командной строке.
if pgrep -f 'frpc -c .*gatelink' >/dev/null 2>&1; then
	say "снимаю оставшиеся процессы frpc"
	run pkill -f 'frpc -c .*gatelink'
	sleep 1
	run pkill -9 -f 'frpc -c .*gatelink'
fi

# ── файлы ───────────────────────────────────────────────────────────────
drop /etc/gatelink
drop "$HOME/.config/gatelink"
drop "$HOME/.local/state/gatelink"
drop /usr/local/bin/frpc
drop "$HOME/.local/bin/frpc"
drop '/var/log/gatelink-agent.log*'

if [[ $DRY -eq 0 ]]; then
	if pgrep -f 'frpc -c .*gatelink' >/dev/null 2>&1; then
		warn "процесс frpc всё ещё жив — снимите вручную: pgrep -a frpc"
	else
		say "агент удалён полностью"
	fi
	cat <<'EOF'

Осталось необязательное:
  * туннели этой машины ещё показаны в панели, пока сервер не заметит обрыв —
    уберите их кнопкой «Убрать офлайн-туннели»;
  * если ради публичного SSH вы отключали вход по паролю или открывали
    доступ извне — верните настройки sshd, они не наши и не тронуты.
EOF
fi
