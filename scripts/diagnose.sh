#!/bin/bash
# diagnose.sh — read-only диагностика Ubuntu VPS с вердиктами (раздел 0 SKILL.md).
# Ничего не меняет: только читает конфиги и статусы. Запуск: sudo bash diagnose.sh
# Вывод: [OK] сделано, [!!] надо делать (с номером раздела SKILL.md), [..] справочно.
# Сервер, настроенный не по этому скиллу, получает [..] «своя схема», а не ложные [!!].
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
ind()  { sed 's/^/       /'; }

# ---------------------------------------------------------------- система
h "Система"
info "$(lsb_release -ds 2>/dev/null || head -1 /etc/os-release), ядро $(uname -r), $(uptime -p 2>/dev/null)"
info "CPU: $(nproc), RAM: $(free -h | awk '/Mem/{print $2}'), диск /: $(df -h / | awk 'END{print $4 " свободно из " $2}')"
if [ -f /var/run/reboot-required ]; then bad "ждёт перезагрузки (ядро обновлено)" "1.1"; else ok "перезагрузка не требуется"; fi

# ---------------------------------------------------------------- пользователи
h "Пользователи и sudo"
info "скрипт запустил: ${SUDO_USER:-root}"
SUDOERS=$(getent group sudo | cut -d: -f4)
if [ -n "$SUDOERS" ]; then ok "в группе sudo: $SUDOERS"; else bad "нет ни одного sudo-пользователя, работа только под root (если это осознанная схема — зафиксируй в паспорте)" "1.2"; fi
NP=$(grep -rn NOPASSWD /etc/sudoers /etc/sudoers.d/ 2>/dev/null | grep -vE ':[[:space:]]*#')
if [ -n "$NP" ]; then
  NPFILE=$(echo "$NP" | head -1 | cut -d: -f1)
  NPUSER=$(echo "$NP" | head -1 | cut -d: -f3- | awk '{print $1}')
  if echo "$NPFILE" | grep -q '90-setup-temp'; then
    EXP=$(systemctl list-timers sudo-temp-expire.timer --no-legend --no-pager 2>/dev/null | awk '{print $1, $2, $3}')
    if [ -n "$EXP" ]; then
      info "режим B: временный NOPASSWD активен до $EXP — снять до чеклиста 9.4 (правила для агента, п. 5)"
    else
      bad "временный NOPASSWD режима B остался ($NPFILE), а таймер снятия НЕ ВИСИТ (перезагрузка?) — снять руками" "1.2"
    fi
  elif echo "$NPFILE" | grep -q cloud-init || echo "$NPUSER" | grep -qE '^(ubuntu|debian|admin|root)$'; then
    bad "дефолтный пользователь хостера с sudo без пароля: $NPUSER ($NPFILE)" "1.2"
  else
    bad "sudo без пароля у $NPUSER ($NPFILE). Если это осознанное решение — зафиксируй в паспорте; скилл рекомендует sudo с паролем" "1.2"
  fi
else
  ok "NOPASSWD в sudoers нет"
fi
info "пароль root: $(passwd -S root 2>/dev/null | awk '{print $2}')  (L = заблокирован, P = задан, NP = нет)"
for f in /root/.ssh/authorized_keys /home/*/.ssh/authorized_keys; do
  [ -f "$f" ] && info "$f: $(grep -c . "$f") ключ(ей)"
done

# ---------------------------------------------------------------- ssh
h "SSH (эффективные значения, sshd -T)"
# -C нужен: при любом Match в конфиге sshd -T без него завершается с ошибкой и пустым выводом
SSHT=$(sshd -T -C user=root,host=localhost,addr=127.0.0.1,lport=22 2>/dev/null)
if [ -z "$SSHT" ]; then
  bad "sshd -T не сработал — конфиг сломан? смотри journalctl -u ssh" "10"
else
  val() { echo "$SSHT" | awk -v k="$1" '$1==k{print $2}'; }
  info "порт: $(val port | paste -sd ' ')"
  PRL=$(val permitrootlogin)
  case "$PRL" in
    no) ok "PermitRootLogin no" ;;
    prohibit-password) bad "PermitRootLogin prohibit-password — root входит по ключу (если это осознанная схема — зафиксируй в паспорте)" "1.4" ;;
    *) bad "PermitRootLogin $PRL — root входит по паролю" "1.4" ;;
  esac
  if [ "$(val passwordauthentication)" = "no" ]; then ok "PasswordAuthentication no"; else bad "PasswordAuthentication $(val passwordauthentication) — вход по паролю открыт" "1.4"; fi
  AU=$(echo "$SSHT" | awk '$1=="allowusers"{print $2}' | paste -sd ' ')
  if [ -n "$AU" ]; then ok "AllowUsers: $AU"; else bad "AllowUsers не задан" "1.4"; fi
fi
info "активация: ssh.socket=$(systemctl is-active ssh.socket 2>/dev/null) ssh.service=$(systemctl is-active ssh.service 2>/dev/null)"
# Чужие drop-in с опасными значениями: если эффективное значение другое, защита держится только на порядке имён файлов
LOOSE=$(grep -HsiE '^\s*(PasswordAuthentication|PermitRootLogin)\s+yes' /etc/ssh/sshd_config.d/*.conf 2>/dev/null | sed 's|/etc/ssh/sshd_config.d/||')
if [ -n "$LOOSE" ]; then
  if echo "$SSHT" | grep -qE '^(passwordauthentication|permitrootlogin) yes'; then
    bad "drop-in с yes действует: $(echo "$LOOSE" | paste -sd ';')" "1.4"
  else
    info "drop-in с yes перебит порядком файлов (first match wins), держится на именах: $(echo "$LOOSE" | paste -sd ';')"
  fi
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
  RULES=$(echo "$UFWS" | grep -E 'ALLOW|DENY|REJECT|LIMIT' | grep -v '(v6)')
  F2B=$(echo "$RULES" | grep -c 'by Fail2Ban')
  RULES=$(echo "$RULES" | grep -v 'by Fail2Ban')
  info "правил: $(echo "$RULES" | grep -c .) (IPv6-дубли скрыты; временных банов fail2ban: $F2B)"
  echo "$RULES" | ind
  have docker && info "Docker публикует порты в обход UFW — смотри раздел «Открытые порты» и цепочку DOCKER-USER"
else
  bad "ufw не установлен" "2"
fi

# ---------------------------------------------------------------- порты
h "Открытые порты (слушают не на loopback; снаружи доступны, если пропускает UFW/DOCKER-USER)"
PUB=$(ss -tlnpH 2>/dev/null | awk '$4 !~ /^(127\.|\[::1\])/ {print $4, $6}' | sed 's/users:(("//; s/",.*//' | sort -u)
if [ -n "$PUB" ]; then echo "$PUB" | ind; else info "вне loopback ничего не слушает"; fi
for port in 5432 3306 6379 27017 9200; do
  if echo "$PUB" | grep -qE '^(0\.0\.0\.0|\[::\]|\*):'"$port "; then bad "порт БД $port слушает на всех интерфейсах (должен быть на 127.0.0.1)" "3"; fi
done

# ---------------------------------------------------------------- обновления
h "Автообновления"
# Три условия сразу: пакет реально установлен (образы хостеров бывают с "deinstall ok config-files"
# при лежащем конфиге), оба таймера apt включены, конфиг говорит "1"
UU_PKG=$(dpkg-query -W -f='${Status}' unattended-upgrades 2>/dev/null)
UU_T1=$(systemctl is-enabled apt-daily.timer 2>/dev/null)
UU_T2=$(systemctl is-enabled apt-daily-upgrade.timer 2>/dev/null)
if [ "$UU_PKG" = "install ok installed" ] && [ "$UU_T1" = enabled ] && [ "$UU_T2" = enabled ] \
   && grep -qs 'Unattended-Upgrade "1"' /etc/apt/apt.conf.d/20auto-upgrades; then
  ok "unattended-upgrades установлен, таймеры apt-daily* enabled, конфиг \"1\""
else
  bad "автообновления не работают: пакет «${UU_PKG:-нет}», apt-daily.timer «${UU_T1:-нет}», apt-daily-upgrade.timer «${UU_T2:-нет}»" "1.5"
fi
AR=$(grep -E '^Unattended-Upgrade::Automatic-Reboot ' /etc/apt/apt.conf.d/50unattended-upgrades 2>/dev/null | grep -o '"[a-z]*"')
info "автоперезагрузка: ${AR:-не задана (по умолчанию false)}"
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
    ok "jail sshd работает: $(fail2ban-client status sshd 2>/dev/null | grep -E 'Currently banned' | sed 's/^ *[|`]*- *//')"
  else
    bad "fail2ban установлен, но jail sshd не работает — проверь backend = systemd (journalctl -u fail2ban)" "1.6"
  fi
else
  bad "fail2ban не установлен" "1.6"
fi

# ---------------------------------------------------------------- диск / журнал / swap
h "Диск, журнал, swap"
df -h -x tmpfs -x devtmpfs -x squashfs -x overlay 2>/dev/null | ind
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
  docker ps --format '{{.Names}}  {{.Ports}}' 2>/dev/null | ind
  if grep -qs 'max-size' /etc/docker/daemon.json; then ok "лог-ротация настроена"; else bad "daemon.json без max-size — логи контейнеров съедят диск" "3"; fi
  NR=$(docker ps -q 2>/dev/null | xargs -r docker inspect --format '{{.Name}} {{.HostConfig.RestartPolicy.Name}}' 2>/dev/null | grep -vE ' (unless-stopped|always)$')
  [ -n "$NR" ] && bad "контейнеры без restart-политики (не поднимутся после reboot): $(echo "$NR" | awk '{print $1}' | tr -d / | tr '\n' ' ')" "3"
else
  info "не установлен"
fi

# ---------------------------------------------------------------- бэкапы и алерты
h "Бэкапы и алерты"
# Схема скилла: restic + backup-daily.timer + backup-failed.service + HC_PING_URL + tg-alert + healthcheck cron.
# Другая схема: любые таймеры/крон с backup|dump|health|heartbeat|notify|alert в имени → [..], не [!!].
# Системные dpkg-db-backup.timer, cron.daily/dpkg и logrotate есть на любом Ubuntu — это не бэкап, исключаем,
# иначе голый сервер получит ложное «своя схема» вместо [!!].
TIMERS=$(systemctl list-timers --all --no-legend --no-pager 2>/dev/null | awk '{print $(NF-1)}' \
  | grep -iE 'backup|dump|restic|borg|snapshot|health|heartbeat|notify|alert|resource|check|monitor' \
  | grep -vE '^(dpkg-db-backup|logrotate|man-db|e2scrub|fstrim|apt-daily|snapd|ua-|ubuntu-advantage|motd)' | sort -u | paste -sd ' ')
CRONS=$(grep -rlisE 'backup|dump|restic|borg|rclone|health|notify|alert' /etc/cron.d /etc/cron.daily /etc/cron.hourly /etc/cron.weekly /var/spool/cron/crontabs 2>/dev/null \
  | grep -vE '/(dpkg|logrotate|man-db|apt-compat|e2scrub_all|sysstat)$' | paste -sd ' ')
TOOLS=$(for t in restic borg rclone duplicity; do have $t && printf '%s ' "$t"; done)
NOTIFIERS=$(find /usr/local/bin /usr/local/sbin -maxdepth 1 -type f -perm -u+x -iregex '.*\(alert\|notify\|tg-\|telegram\|ntfy\).*' \
  -not -name '*.bak*' -not -name '*~' -not -name '*.orig' -not -name '*.old' -printf '%f ' 2>/dev/null)
# Push-мониторинг (heartbeat в Gatus/healthchecks/ntfy вместо локального отправителя): ищем по содержимому
PUSH_ALL=$(grep -rlisE 'gatus|heartbeat|healthchecks|hc-ping|api\.telegram\.org|ntfy\.sh|pushover' \
  --exclude='*.bak*' --exclude='*~' --exclude='*.orig' --exclude='*.old' \
  /usr/local/bin /usr/local/sbin /etc/systemd/system /etc/restic /root/.config/restic 2>/dev/null | sed 's|.*/||' | sort -u)
PUSH_N=$(echo "$PUSH_ALL" | grep -c .)
PUSH=$(echo "$PUSH_ALL" | head -10 | paste -sd ' ')
[ "$PUSH_N" -gt 10 ] && PUSH="$PUSH … и ещё $((PUSH_N - 10))"

if have restic && systemctl is-enabled backup-daily.timer >/dev/null 2>&1; then
  ok "схема скилла: restic + backup-daily.timer ($(systemctl list-timers backup-daily.timer --no-legend --no-pager 2>/dev/null | awk '{print "следующий", $1, $2, $3}'))"
  if systemctl cat backup-failed.service >/dev/null 2>&1; then ok "backup-failed.service есть"; else bad "нет алерта о падении бэкапа (backup-failed.service)" "5"; fi
  # Непустое значение с https://, а не наличие строки: шаблон env кладёт HC_PING_URL='' и у пропустивших
  HC=$(grep -s '^export HC_PING_URL=' /root/.config/restic/env | cut -d= -f2- | tr -d "'\"" )
  if printf '%s' "$HC" | grep -q '^https://'; then ok "healthchecks.io ping задан"; else info "dead-man's switch (healthchecks.io) не настроен — пропуск бэкапа заметишь только по тишине (backups.md, раздел 3)"; fi
elif [ -n "$TIMERS$CRONS$TOOLS" ]; then
  info "своя схема бэкапов — таймеры: ${TIMERS:-нет}; cron: ${CRONS:-нет}; инструменты: ${TOOLS:-нет}"
  info "сверь с принципами раздела 5: offsite, проверенное восстановление, алерт при падении, dead-man's switch"
else
  bad "бэкапов не видно: нет restic/borg/rclone и ни одного таймера или cron с backup в имени" "5"
fi

if [ -x /usr/local/bin/tg-alert ] && [ -s /root/.config/tg-alert/env ]; then
  ok "tg-alert настроен (/root/.config/tg-alert/env)"
elif [ -x /usr/local/bin/tg-alert ]; then
  bad "tg-alert есть, но /root/.config/tg-alert/env пуст — токен не настроен (scripts/tg-setup.sh)" "6"
elif [ -n "$NOTIFIERS" ]; then
  info "свой канал алертов: ${NOTIFIERS% } — проверь, что тестовое сообщение доходит"
elif [ -n "$PUSH" ]; then
  info "push-мониторинг (heartbeat/telegram в скриптах и юнитах): $PUSH — проверь, что пропуск heartbeat даёт алерт"
else
  bad "нет канала алертов (tg-alert или аналог)" "6"
fi
if [ -f /etc/cron.d/healthcheck ]; then
  ok "healthcheck.sh в cron есть"
elif echo "$TIMERS $CRONS" | grep -qiE 'health|resource|monitor'; then
  info "своя проверка ресурсов: $(echo "$TIMERS $CRONS" | tr ' ' '\n' | grep -iE 'health|resource|monitor' | paste -sd ' ')"
else
  bad "нет проверки ресурсов (healthcheck.sh) — диск/память/упавшие сервисы никто не заметит" "6"
fi

# ---------------------------------------------------------------- сервисы / веб
h "Упавшие сервисы"
FAILED=$(systemctl --failed --no-pager --no-legend --plain 2>/dev/null | awk '{print $1}' | tr '\n' ' ')
if [ -n "$FAILED" ]; then bad "упавшие юниты: $FAILED (journalctl -u <unit>)" "8"; else ok "упавших сервисов нет"; fi

h "Веб и HTTPS"
if have nginx; then
  info "$(nginx -v 2>&1), sites-enabled: $(ls /etc/nginx/sites-enabled/ 2>/dev/null | tr '\n' ' ')"
  # Сертификаты — из полного конфига nginx -T (раскрывает include и симлинки sites-enabled),
  # независимо от того, кто их выпустил (certbot, acme.sh, вручную)
  NGT=$(nginx -T 2>/dev/null)
  if [ -z "$NGT" ]; then bad "nginx -T не сработал — конфиг с ошибкой? (nginx -t)" "4"; fi
  CERTS=$(echo "$NGT" | grep -E '^\s*ssl_certificate\s' | awk '{print $2}' | tr -d ';' | sort -u)
  if [ -n "$CERTS" ]; then
    NOW=$(date +%s)
    while IFS= read -r c; do
      [ -f "$c" ] || { bad "ssl_certificate $c не найден на диске" "4"; continue; }
      END=$(openssl x509 -in "$c" -noout -enddate 2>/dev/null | cut -d= -f2)
      ENDS=$(date -d "$END" +%s 2>/dev/null || echo 0)
      DAYS=$(( (ENDS - NOW) / 86400 ))
      if [ "$DAYS" -lt 14 ]; then bad "сертификат $c истекает через $DAYS дн. — автопродление не работает?" "4"; else ok "сертификат $(basename "$(dirname "$c")")/$(basename "$c"): ещё $DAYS дн."; fi
    done <<< "$CERTS"
    ISS=""
    have certbot && ISS="certbot"
    [ -d /root/.acme.sh ] && ISS="${ISS:+$ISS + }acme.sh"
    case "$ISS" in
      "") info "выпуск: не certbot и не acme.sh — проверь, кто продлевает" ;;
      *+*) info "выпуск: $ISS — два продлевателя; убедись, что они не выпускают одни и те же домены" ;;
      *) info "выпуск: $ISS" ;;
    esac
  else
    bad "nginx без ssl_certificate — HTTPS не настроен?" "4"
  fi
else
  info "nginx не установлен"
fi

# ---------------------------------------------------------------- паспорт
h "Паспорт сервера"
if [ -f /root/server-notes.md ]; then
  ok "/root/server-notes.md есть (обновлён $(date -r /root/server-notes.md +%F)) — прочитай его перед настройкой"
else
  bad "паспорта сервера нет (если карточка сервера ведётся вне сервера — это допустимо, отметь в ней)" "9.3"
fi

# ---------------------------------------------------------------- итог
# Уровень 1 («сервер можно оставить включённым») — разделы 0–2, гейт и runbook 10;
# уровень 2 («это прод») — разделы 3–9.
h "Итог: что делать (по разделам SKILL.md)"
if [ "${#TODO[@]}" -eq 0 ]; then
  echo "  Всё проверенное в порядке. Осталось пройти чеклист 9.4 руками."
else
  L1=$(printf '%s\n' "${TODO[@]}" | awk -F'|' '$1 ~ /^(1(\.[0-9]+)?|2|10|гейт)$/' | sort -t'|' -k1,1V)
  L2=$(printf '%s\n' "${TODO[@]}" | awk -F'|' '$1 !~ /^(1(\.[0-9]+)?|2|10|гейт)$/' | sort -t'|' -k1,1V)
  if [ -n "$L1" ]; then
    echo "  Сначала — уровень 1, сервер нельзя оставлять включённым, пока это не закрыто:"
    echo "$L1" | awk -F'|' '{printf "    %-6s %s\n", $1, $2}'
  fi
  if [ -n "$L2" ]; then
    echo "  Потом — уровень 2, без этого сервер не «прод»:"
    echo "$L2" | awk -F'|' '{printf "    %-6s %s\n", $1, $2}'
  fi
fi
printf '\nГотово. Скрипт ничего не менял.\n'
