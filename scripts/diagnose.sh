#!/bin/bash
# diagnose.sh — read-only диагностика Ubuntu VPS с вердиктами (раздел 0 SKILL.md).
# Ничего не меняет: только читает конфиги и статусы. Запуск: sudo bash diagnose.sh
# Вывод: [OK] сделано, [!!] надо делать (с номером раздела SKILL.md), [..] справочно.
set -u

if [ "$(id -u)" -ne 0 ]; then
  echo "Нужны права root для sshd -T / ufw / sudoers. Запусти: sudo bash $0"
  exit 1
fi

TODO=()
ok()   { printf '  [OK] %s\n' "$1"; }
bad()  { printf '  [!!] %s  -> раздел %s\n' "$1" "$2"; TODO+=("$2|$1"); }
info() { printf '  [..] %s\n' "$1"; }
h()    { printf '\n=== %s ===\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------- система
h "Система"
info "$(lsb_release -ds 2>/dev/null || head -1 /etc/os-release), ядро $(uname -r), $(uptime -p 2>/dev/null)"
info "CPU: $(nproc), RAM: $(free -h | awk '/Mem/{print $2}'), диск /: $(df -h / | awk 'END{print $4 " свободно из " $2}')"
if [ -f /var/run/reboot-required ]; then bad "ждёт перезагрузки (ядро обновлено)" "1.1"; else ok "перезагрузка не требуется"; fi

# ---------------------------------------------------------------- пользователи
h "Пользователи и sudo"
info "скрипт запустил: ${SUDO_USER:-root}"
SUDOERS=$(getent group sudo | cut -d: -f4)
if [ -n "$SUDOERS" ]; then ok "в группе sudo: $SUDOERS"; else bad "нет ни одного sudo-пользователя, работа только под root" "1.2"; fi
NP=$(grep -rn NOPASSWD /etc/sudoers /etc/sudoers.d/ 2>/dev/null | grep -v '^\s*#' | grep -v ':#')
if [ -n "$NP" ]; then
  bad "sudo без пароля (дефолтный пользователь хостера?): $(echo "$NP" | head -1 | cut -c1-70)" "1.2"
else
  ok "NOPASSWD в sudoers нет"
fi
info "пароль root: $(passwd -S root 2>/dev/null | awk '{print $2}')  (L = заблокирован, P = задан, NP = нет)"
for f in /root/.ssh/authorized_keys /home/*/.ssh/authorized_keys; do
  [ -f "$f" ] && info "$f: $(grep -c . "$f") ключ(ей)"
done

# ---------------------------------------------------------------- ssh
h "SSH (эффективные значения, sshd -T)"
SSHT=$(sshd -T 2>/dev/null)
if [ -z "$SSHT" ]; then
  bad "sshd -T не сработал — конфиг сломан? смотри journalctl -u ssh" "10"
else
  val() { echo "$SSHT" | awk -v k="$1" '$1==k{print $2}'; }
  P=$(val port); info "порт: $P"
  if [ "$(val permitrootlogin)" = "no" ]; then ok "PermitRootLogin no"; else bad "PermitRootLogin $(val permitrootlogin)" "1.4"; fi
  if [ "$(val passwordauthentication)" = "no" ]; then ok "PasswordAuthentication no"; else bad "PasswordAuthentication $(val passwordauthentication) — вход по паролю открыт" "1.4"; fi
  AU=$(echo "$SSHT" | awk '$1=="allowusers"{print $2}' | tr '\n' ' ')
  if [ -n "$AU" ]; then ok "AllowUsers: $AU"; else bad "AllowUsers не задан" "1.4"; fi
fi
info "активация: ssh.socket=$(systemctl is-active ssh.socket 2>/dev/null) ssh.service=$(systemctl is-active ssh.service 2>/dev/null)"
if grep -qsi '^PasswordAuthentication yes' /etc/ssh/sshd_config.d/50-cloud-init.conf; then
  bad "50-cloud-init.conf содержит PasswordAuthentication yes (перебивает hardening)" "1.4"
fi
for t in ssh-rollback ufw-rollback; do
  systemctl is-active "$t.timer" >/dev/null 2>&1 && bad "висит таймер отката $t.timer — отмени после проверки входа" "гейт"
done

# ---------------------------------------------------------------- ufw
h "Файрвол"
if have ufw; then
  UFWS=$(ufw status verbose 2>/dev/null)
  if echo "$UFWS" | grep -q '^Status: active'; then ok "UFW активен"; else bad "UFW не активен" "2"; fi
  if echo "$UFWS" | grep -q 'Default: deny (incoming)'; then ok "по умолчанию входящие закрыты"; else bad "входящие по умолчанию НЕ закрыты" "2"; fi
  echo "$UFWS" | grep -E '^[0-9]|ALLOW|DENY' | sed 's/^/       /' | head -20
else
  bad "ufw не установлен" "2"
fi

# ---------------------------------------------------------------- порты
h "Открытые порты (слушают на всех интерфейсах = доступны снаружи)"
PUB=$(ss -tlnpH 2>/dev/null | awk '$4 !~ /^(127\.|\[::1\])/ {print $4, $6}' | sed 's/users:(("//; s/",.*//' | sort -u)
if [ -n "$PUB" ]; then echo "$PUB" | sed 's/^/       /'; else info "снаружи ничего не слушает"; fi
for port in 5432 3306 6379 27017 9200 8080 3000 5000; do
  if echo "$PUB" | grep -qE ":$port "; then bad "порт $port открыт наружу (БД/приложение должно быть на 127.0.0.1)" "3"; fi
done

# ---------------------------------------------------------------- обновления
h "Автообновления"
if dpkg -s unattended-upgrades >/dev/null 2>&1 && grep -qs 'Unattended-Upgrade "1"' /etc/apt/apt.conf.d/20auto-upgrades; then
  ok "unattended-upgrades включён"
else
  bad "unattended-upgrades не установлен или не включён" "1.5"
fi
AR=$(grep -E '^Unattended-Upgrade::Automatic-Reboot ' /etc/apt/apt.conf.d/50unattended-upgrades 2>/dev/null | grep -o '"[a-z]*"')
info "автоперезагрузка: ${AR:-не задана (по умолчанию false)}"
if have pro; then
  if timeout 15 pro status 2>/dev/null | grep -qE '^esm-apps +yes +enabled'; then
    ok "Ubuntu Pro: esm-apps enabled"
  else
    bad "Ubuntu Pro не подключён — security-патчи для universe (fail2ban, restic, certbot) не приходят" "1.5"
  fi
fi
info "доступно обновлений (локальный кэш apt): $(apt list --upgradable 2>/dev/null | grep -c upgradable)"

# ---------------------------------------------------------------- время
h "Время"
TD=$(timedatectl 2>/dev/null)
info "зона: $(echo "$TD" | awk -F': ' '/Time zone/{print $2}')"
if echo "$TD" | grep -qi 'synchronized: yes'; then ok "часы синхронизированы"; else bad "часы НЕ синхронизированы" "1.7"; fi

# ---------------------------------------------------------------- fail2ban
h "fail2ban"
if have fail2ban-client; then
  if fail2ban-client status sshd >/dev/null 2>&1; then
    ok "jail sshd активен: $(fail2ban-client status sshd 2>/dev/null | grep -E 'Currently banned' | sed 's/^ *[|`]*- *//')"
  else
    bad "fail2ban установлен, но jail sshd не работает (journalctl -u fail2ban)" "1.6"
  fi
  if grep -rqs '^backend *= *systemd' /etc/fail2ban/jail.d/; then ok "backend = systemd"; else bad "backend = systemd не задан в jail.d (на 24.04+ без rsyslog jail упадёт)" "1.6"; fi
else
  bad "fail2ban не установлен" "1.6"
fi

# ---------------------------------------------------------------- диск / журнал / swap
h "Диск, журнал, swap"
df -h -x tmpfs -x devtmpfs -x squashfs -x overlay 2>/dev/null | sed 's/^/       /'
DU=$(df / | awk 'END{print $5+0}')
if [ "$DU" -gt 85 ]; then bad "диск / занят на ${DU}%" "6"; fi
info "journald: $(journalctl --disk-usage 2>/dev/null | sed 's/Archived and active journals take up //')"
if grep -rqs '^SystemMaxUse' /etc/systemd/journald.conf /etc/systemd/journald.conf.d/; then ok "лимит журнала задан"; else bad "SystemMaxUse не задан — журнал не ограничен" "1.7"; fi
RAM_MB=$(free -m | awk '/Mem/{print $2}')
if [ -n "$(swapon --show --noheadings 2>/dev/null)" ]; then
  ok "swap: $(swapon --show --noheadings 2>/dev/null | awk '{print $1, $3}' | head -1)"
elif [ "$RAM_MB" -lt 2048 ]; then
  bad "swap нет при RAM ${RAM_MB} МБ — OOM убьёт сервисы" "1.7"
else
  info "swap нет, RAM ${RAM_MB} МБ — допустимо"
fi
info "/tmp: $(findmnt -no FSTYPE /tmp 2>/dev/null || echo 'на корневом диске')"

# ---------------------------------------------------------------- docker
h "Docker"
if have docker; then
  info "$(docker --version 2>/dev/null)"
  docker ps --format '       {{.Names}}  {{.Ports}}' 2>/dev/null
  if grep -qs 'max-size' /etc/docker/daemon.json; then ok "лог-ротация настроена"; else bad "daemon.json без max-size — логи контейнеров съедят диск" "3"; fi
  NR=$(docker ps -q 2>/dev/null | xargs -r docker inspect --format '{{.Name}} {{.HostConfig.RestartPolicy.Name}}' 2>/dev/null | grep -vE ' (unless-stopped|always)$')
  [ -n "$NR" ] && bad "контейнеры без restart-политики (не поднимутся после reboot): $(echo "$NR" | awk '{print $1}' | tr -d / | tr '\n' ' ')" "3"
else
  info "не установлен"
fi

# ---------------------------------------------------------------- бэкапы и алерты
h "Бэкапы и алерты"
if have restic; then ok "restic: $(restic version 2>/dev/null | awk '{print $2}')"; else bad "restic не установлен" "5"; fi
if systemctl is-enabled backup-daily.timer >/dev/null 2>&1; then
  ok "backup-daily.timer включён: $(systemctl list-timers backup-daily.timer --no-legend --no-pager 2>/dev/null | awk '{print "следующий", $1, $2, $3}')"
else
  bad "таймер backup-daily.timer не настроен" "5"
fi
if systemctl cat backup-failed.service >/dev/null 2>&1; then ok "backup-failed.service есть"; else bad "нет алерта о падении бэкапа (backup-failed.service)" "5"; fi
if grep -qs 'HC_PING_URL=' /root/.config/restic/env; then ok "healthchecks.io ping задан"; else bad "нет dead-man's switch (HC_PING_URL)" "5"; fi
if [ -x /usr/local/bin/tg-alert ]; then ok "tg-alert есть"; else bad "нет tg-alert (канал алертов)" "6"; fi
if [ -f /etc/cron.d/healthcheck ]; then ok "healthcheck cron есть"; else bad "нет healthcheck.sh в cron" "6"; fi

# ---------------------------------------------------------------- сервисы / веб
h "Упавшие сервисы"
FAILED=$(systemctl --failed --no-pager --no-legend --plain 2>/dev/null | awk '{print $1}' | tr '\n' ' ')
if [ -n "$FAILED" ]; then bad "упавшие юниты: $FAILED (journalctl -u <unit>)" "8"; else ok "упавших сервисов нет"; fi

h "Веб"
if have nginx; then
  info "$(nginx -v 2>&1), sites-enabled: $(ls /etc/nginx/sites-enabled/ 2>/dev/null | tr '\n' ' ')"
  if have certbot; then
    certbot certificates 2>/dev/null | grep -E 'Certificate Name|Expiry' | sed 's/^ */       /'
  else
    bad "nginx есть, certbot нет — HTTPS не настроен?" "4"
  fi
else
  info "nginx не установлен"
fi

# ---------------------------------------------------------------- паспорт
h "Паспорт сервера"
if [ -f /root/server-notes.md ]; then
  ok "/root/server-notes.md есть (обновлён $(date -r /root/server-notes.md +%F)) — прочитай его перед настройкой"
else
  bad "паспорта сервера нет" "9.3"
fi

# ---------------------------------------------------------------- итог
h "Итог: что делать (по разделам SKILL.md)"
if [ "${#TODO[@]}" -eq 0 ]; then
  echo "  Всё проверенное в порядке. Осталось пройти чеклист 9.4 руками."
else
  printf '%s\n' "${TODO[@]}" | sort -t'|' -k1,1V | awk -F'|' '{printf "  %-6s %s\n", $1, $2}'
fi
printf '\nГотово. Скрипт ничего не менял.\n'
