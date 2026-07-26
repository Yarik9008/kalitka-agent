# kalitka-agent

Агент [kalitka](https://github.com/Yarik9008/kalitka) — ставится на компьютер,
к которому нужно получать доступ снаружи.

Компьютер за NAT, без белого IP и без проброса портов на роутере становится
доступен по SSH, RDP или как обычный сайт. Агент держит одно **исходящее**
соединение до вашего сервера и ничего не слушает наружу.

Серверная часть в этот репозиторий не входит.

## Установка

Linux и macOS — одной командой:

```bash
curl -fsSL https://raw.githubusercontent.com/Yarik9008/kalitka-agent/main/install.sh \
  | bash -s -- '<строка-подключения>' --name имя-машины
```

Windows, PowerShell от администратора:

```powershell
irm https://raw.githubusercontent.com/Yarik9008/kalitka-agent/main/Install-Agent.ps1 -OutFile Install-Agent.ps1
.\Install-Agent.ps1 -Enroll '<строка-подключения>' -Name имя-машины
```

Строку подключения печатает установщик серверной части. В ней адрес сервера и
секреты — пересылать её лучше не мессенджером.

## Что делает установщик

1. Скачивает [frp](https://github.com/fatedier/frp) нужной версии и разрядности
   с GitHub Releases.
2. Пишет конфигурацию (права 600) и выбирает транспорт.
3. Ставит агента в автозапуск: systemd на Linux, launchd на macOS, планировщик
   задач на Windows. Агент переживает перезагрузки и обрывы связи.

Ничего, кроме `curl`/`tar` (или PowerShell на Windows), заранее не требуется.

## Два транспорта

Агент сам выбирает, как дойти до сервера:

| Режим | Нужен VPN-клиент | Как выглядит снаружи |
|---|---|---|
| `vpn` | да, с SOCKS на localhost | обычный трафик VPN |
| `direct` | **нет** | обычный HTTPS-запрос к сайту на :443 |

По умолчанию — `auto`: нашёлся SOCKS VPN-клиента (v2rayN — 10808, sing-box и
Nekoray — 2080, Hiddify — 12334, Clash — 7890) — идём через него; не нашёлся —
прямым режимом. Принудительно: `--direct` или `--mode vpn`.

Прямой режим не требует ни VPN, ни открытого порта: управляющий канал идёт
websocket'ом поверх обычного HTTPS.

## Опции

```
--name ID          имя машины в туннелях (по умолчанию — hostname)
--mode РЕЖИМ       auto | vpn | direct
--direct           то же, что --mode direct
--ssh-port PORT    какой порт публиковать как SSH (0 — не публиковать)
--vnc-port PORT    добавить приватный туннель к VNC
--http PORT        опубликовать веб-сервис на https://ID.<домен-туннелей>
--socks HOST:PORT  адрес SOCKS VPN-клиента, если не определился сам
--no-service       не ставить автозапуск, только конфигурацию
```

Windows: те же ключи в PowerShell-стиле (`-Name`, `-RdpPort`, `-HttpPort`, …),
по умолчанию публикуется RDP.

## Что публикуется

* **Приватные туннели** (`stcp`) — SSH, RDP, VNC. На сервере не открывается ни
  одного порта: он лишь сводит агента с тем, у кого совпал секрет. Подключиться
  без секрета нельзя, найти сканированием — тоже.
* **Публичный HTTP-туннель** (`--http`) — сервис становится доступен по адресу
  вида `https://имя.домен`. Это публичный адрес: считайте, что его знают все.

## Управление

```bash
# Linux (root)
systemctl status kalitka-agent
journalctl -u kalitka-agent -f
tail -f /var/log/kalitka-agent.log

# Linux (без root)
systemctl --user status kalitka-agent

# macOS
launchctl list | grep kalitka
```

```powershell
# Windows
Get-ScheduledTask kalitka-agent
Get-Content $env:ProgramData\kalitka\agent.log -Tail 20
```

## Удаление

```bash
sudo systemctl disable --now kalitka-agent
sudo rm -f /etc/systemd/system/kalitka-agent.service /usr/local/bin/frpc
sudo rm -rf /etc/kalitka
```

```powershell
Unregister-ScheduledTask kalitka-agent -Confirm:$false
Remove-Item -Recurse $env:ProgramData\kalitka
```

## Безопасность

Агент подключается только туда, куда указано в строке подключения, и публикует
только то, что перечислено в его конфигурации. Он не открывает портов на этой
машине и не принимает входящих соединений из интернета.

Файл конфигурации содержит токен сервера и секрет туннелей — он создаётся с
правами 600. Кто получит этот файл, тот сможет притвориться вашим агентом,
поэтому машины с общим доступом — плохое место для установки.

## Лицензия

MIT, см. [LICENSE](LICENSE).
