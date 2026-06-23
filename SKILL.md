---
name: new-vps-setup
description: >
  Используй когда нужно настроить новый Ubuntu VPS под продакшн «с нуля», подготовить чистый
  сервер к боевой эксплуатации, сделать hardening, или дать новичку автономно поднять и
  поддерживать прод-сервер. Также при задачах: автообновления безопасности, настройка файрвола,
  бэкапы, защита SSH, чеклист готовности к проду, регулярное обслуживание сервера.
  Ключевые слова: hardening Ubuntu, unattended-upgrades, UFW, fail2ban, SSH-ключи, restic, offsite,
  Docker, nginx, HTTPS, Let's Encrypt, мониторинг, восстановление из бэкапа.
---

# Настройка нового VPS под продакшн (для новичка)

## Обзор

Этот скилл проводит **по шагам** через подготовку чистого Ubuntu-сервера к продакшну так,
чтобы дальше он **обслуживался максимально автономно**. Аудитория — человек без опыта
системного администрирования. Поэтому:

- **Безопасные дефолты, а не «как у профи».** Никаких NOPASSWD-sudo, никаких отключённых
  проверок ради удобства. То, что упрощает жизнь эксперту, для новичка — мина.
- **Автономность через автоматику.** Обновления безопасности, бэкапы и мониторинг должны
  работать сами. Человек только реагирует на алерты.
- **Каждый шаг проверяется.** После изменения — проверка результата, и только потом следующий шаг.

> **Целевая ОС:** Ubuntu 22.04 / 24.04 LTS. Команды для других дистрибутивов отличаются.

## Золотые правила (перед ЛЮБЫМ изменением)

1. **Бэкап конфига:** `sudo cp /path/config /path/config.bak.$(date +%F-%H%M)`
2. **Проверь состояние:** `sudo systemctl status <service>` / `sudo docker ps`
3. **После изменения — проверь результат** (логи, статус, тестовое подключение).
4. **Никогда не закрывай текущую SSH-сессию**, пока в **новой** сессии не убедился, что
   доступ и sudo работают. Потеря SSH на удалённом сервере = выезд в консоль провайдера (VNC).

**Принципы безопасности прода (соблюдай на всех шагах):**

- Секреты (API-ключи, токены, пароли) — только в `.env` или переменных окружения, **никогда в коде**.
- `.env` — обязательно в `.gitignore` (иначе секреты утекут в git при первом коммите).
- Базы данных не торчат в интернет — только localhost или через приватную сеть/VPN.
- На сервере нет debug-режима: `DEBUG=False`, `NODE_ENV=production`.
- Приложения не запускаются от root — отдельный пользователь/контейнер.
- Нет лишних открытых портов (админки, дашборды, метрики — закрыты или за доверенными IP).
- Не отключай проверки безопасности ради удобства (`verify=False`, `allowAll` — только локально).
- SSH — только по ключам, не по паролю.

---

## 0. Диагностика — что уже есть

**Выполни ПЕРВЫМ.** Хостеры часто отдают сервер с частичной настройкой (cloud-init, ufw, и т.п.).

```bash
# Система
lsb_release -a && uname -r
free -h && df -h && nproc

# Кто я и какие права
whoami && id

# SSH-конфиг (эффективные значения, а не только файлы!)
sudo sshd -T | grep -iE 'permitrootlogin|passwordauthentication|pubkeyauthentication|^port '

# Файрвол
sudo ufw status verbose

# Что слушает порты
sudo ss -tlnp

# Автообновления (включены?)
systemctl status unattended-upgrades 2>/dev/null | head -5
cat /etc/apt/apt.conf.d/20auto-upgrades 2>/dev/null

# Docker / fail2ban
sudo docker ps 2>/dev/null
sudo fail2ban-client status 2>/dev/null
```

После диагностики **сообщи пользователю что найдено и не начинай настройку без подтверждения.**

---

## 1. Первичная настройка и безопасность

> Сверься с секцией 0 — часть может быть уже сделана. Не делай дважды.

### 1.1 Обновление системы

```bash
sudo apt update && sudo apt upgrade -y
sudo apt autoremove -y
# Если ядро обновилось — потребуется reboot (см. вывод). Перезагружай осознанно:
# sudo reboot   # и переподключись через ~30-60с
```

### 1.2 Отдельный sudo-пользователь (НЕ работаем под root)

```bash
sudo adduser <USERNAME>            # задаст пароль — выбери надёжный, сохрани в менеджере паролей
sudo usermod -aG sudo <USERNAME>
```

> **Для новичка sudo оставляем с запросом пароля.** Это намеренно: NOPASSWD-sudo снимает
> последний барьер при компрометации ключа или сессии. Пароль sudo нужен и как fallback,
> если потеряется SSH-ключ (см. 1.3).

### 1.3 SSH-ключи (вход без пароля по ключу)

Тип ключа — **ed25519** (не RSA). Имя — `<server>_<device>`, с passphrase.

**На локальной машине:**
```bash
ssh-keygen -t ed25519 -f ~/.ssh/<server>_<device> -C "<server>_<device>"
ssh-copy-id -i ~/.ssh/<server>_<device>.pub <USERNAME>@<SERVER_IP>
```

**Проверь вход по ключу в ОТДЕЛЬНОЙ сессии (старую не закрывай!):**
```bash
ssh -i ~/.ssh/<server>_<device> -o IdentitiesOnly=yes <USERNAME>@<SERVER_IP> 'whoami; sudo whoami'
```

Удобный alias в `~/.ssh/config` на локальной машине:
```
Host <alias>
    HostName <SERVER_IP>
    User <USERNAME>
    IdentityFile ~/.ssh/<server>_<device>
    IdentitiesOnly yes
```

### 1.4 SSH hardening

Создай `/etc/ssh/sshd_config.d/99-hardening.conf`:
```
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
MaxAuthTries 3
AllowTcpForwarding local
ClientAliveInterval 300
ClientAliveCountMax 2
AllowUsers <USERNAME>
```

> `AllowTcpForwarding local` разрешает локальный проброс (`ssh -L` — заглянуть в сервис на
> `127.0.0.1` до настройки домена) и запрещает удалённый (`-R`). Если форвардинг не нужен
> вообще — ставь `no`.

Примени и проверь:
```bash
sudo sshd -t                                              # синтаксис ОК?
sudo systemctl restart ssh
sudo sshd -T | grep -iE 'permitroot|passwordauth'         # эффективные значения = no
```

**Gotcha 1 — cloud-init перезаписывает hardening.** Файл `/etc/ssh/sshd_config.d/50-cloud-init.conf`
часто содержит `PasswordAuthentication yes` и в `sshd_config.d/` действует «first match wins».
Проверяй через `sudo sshd -T` (эффективные значения), а не только свой файл. Если перебивает —
поправь/удали строку в `50-cloud-init.conf`.

**Gotcha 2 — Ubuntu 24.04 использует `ssh.socket`.** `Port` в `sshd_config` игнорируется. Чтобы
сменить порт SSH: `sudo systemctl edit ssh.socket` → добавить `ListenStream=<PORT>` (и убрать
дефолтный). **Проверяй через консоль провайдера** — ошибка тут запирает доступ.

### 1.5 Автоматические обновления безопасности ⭐ (ядро автономности)

Это самый важный шаг для «сервер обслуживает себя сам». Без него дыры в пакетах копятся.

```bash
sudo apt install unattended-upgrades apt-listchanges -y
sudo dpkg-reconfigure -plow unattended-upgrades   # выбери "Yes" — создаст 20auto-upgrades
```

Проверь `/etc/apt/apt.conf.d/20auto-upgrades`:
```
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
```

В `/etc/apt/apt.conf.d/50unattended-upgrades` (раскомментируй/настрой ключевые строки):
```
// Ставить обновления безопасности (включено по умолчанию):
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
    "${distro_id}ESMApps:${distro_codename}-apps-security";
    "${distro_id}ESM:${distro_codename}-infra-security";
};
Unattended-Upgrade::Remove-Unused-Dependencies "true";
// Автоперезагрузка, если обновление её требует (ядро). Выбери окно с минимумом нагрузки:
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "04:00";
```

> **Решение «автоперезагрузка»:** `true` = сервер сам перезагрузится ночью при обновлении ядра
> (безопаснее, но возможен короткий даунтайм). `false` = ядро обновится, но reboot ждёт тебя
> (нужно следить). Для одиночного прод-сервера новичку обычно лучше `true` + ночное окно.

Проверка — сухой прогон без установки:
```bash
sudo unattended-upgrade --dry-run --debug 2>&1 | tail -20
systemctl list-timers 'apt-daily*'   # таймеры активны?
```

### 1.6 fail2ban (защита SSH от брутфорса)

Базовой конфигурации достаточно — не усложняй recidive/nftables на старте.

```bash
sudo apt install fail2ban -y
```

`/etc/fail2ban/jail.d/sshd.local`:
```ini
[sshd]
enabled = true
bantime = 1h
findtime = 30m
maxretry = 4
# Не забанить себя: добавь СВОИ статические IP (узнай: curl ifconfig.me)
ignoreip = 127.0.0.1/8 ::1 <YOUR_HOME_IP>
```

```bash
sudo systemctl enable --now fail2ban
sudo fail2ban-client status sshd
```

### 1.7 Таймзона и (для маленьких VPS) swap

```bash
sudo timedatectl set-timezone <Region/City>     # напр. Europe/Moscow или UTC

# Swap нужен на VPS с малым RAM (< 2 ГБ), чтобы OOM не убивал сервисы:
free -h
sudo fallocate -l 2G /swapfile && sudo chmod 600 /swapfile
sudo mkswap /swapfile && sudo swapon /swapfile
grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
echo 'vm.swappiness=10' | sudo tee /etc/sysctl.d/99-swap.conf && sudo sysctl --system
```

---

## 2. Файрвол UFW

Принцип: **закрыто всё, открыто только нужное.** Сначала разреши SSH, иначе запрёшь себя.

```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow 22/tcp comment 'SSH'      # ВАЖНО: до enable!
sudo ufw enable
sudo ufw status verbose
```

Для веб-сервера добавь HTTP/HTTPS:
```bash
sudo ufw allow 80/tcp comment 'HTTP'
sudo ufw allow 443/tcp comment 'HTTPS'
```

**Админки/дашборды/метрики — только доверенным IP, не «всем»:**
```bash
sudo ufw allow from <TRUSTED_IP> to any port <ADMIN_PORT> proto tcp comment 'admin panel'
```

> **Никогда не используй `sudo ufw reset`** — он сбросит все правила, включая SSH.

---

## 3. Docker (опционально — если приложения в контейнерах)

### Установка
```bash
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker <USERNAME>      # перелогинься, чтобы группа применилась
```

> Членство в группе `docker` фактически равно root (через `docker run -v /:/host`). Это
> приемлемо для одного администратора, но не давай эту группу пользователям, которым не
> доверяешь полный доступ к серверу.

### Лог-ротация (обязательно — иначе логи съедят диск)
`/etc/docker/daemon.json`:
```json
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" }
}
```
```bash
sudo systemctl restart docker
```

### ⚠️ Docker обходит UFW
Порт, проброшенный как `-p 8080:8080`, **доступен из интернета, даже если UFW его не разрешал.**
Безопасные варианты:
- Биндить только на localhost: `-p 127.0.0.1:8080:8080` (доступ только через nginx/SSH-туннель).
- Не пробрасывать порты БД наружу вообще — общаться по имени сервиса внутри docker-сети.

---

## 4. nginx + HTTPS (опционально — если есть веб-приложение и домен)

nginx как reverse proxy перед приложением (приложение слушает `127.0.0.1`, наружу — только nginx).

```bash
sudo apt install nginx -y
```

`/etc/nginx/sites-available/<app>`:
```nginx
server {
    listen 80;
    server_name <DOMAIN>;
    location / {
        proxy_pass http://127.0.0.1:<APP_PORT>;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```
```bash
sudo ln -s /etc/nginx/sites-available/<app> /etc/nginx/sites-enabled/
sudo nginx -t && sudo systemctl reload nginx
```

**HTTPS бесплатно через Let's Encrypt (certbot сам выпустит и настроит автопродление):**
```bash
sudo apt install certbot python3-certbot-nginx -y
sudo certbot --nginx -d <DOMAIN>
# Автопродление уже настроено таймером. Проверка:
sudo certbot renew --dry-run
```

Защита: добавь `server_tokens off;` в `/etc/nginx/nginx.conf` (скрыть версию nginx) и
security-заголовки (`Strict-Transport-Security`, `X-Content-Type-Options nosniff`).

---

## 5. Автоматические бэкапы (restic + offsite)

> **Полная инструкция (установка, репозиторий, скрипт, таймер, восстановление):**
> читай **references/backups.md** — там пошагово.

Ключевые принципы, которые НЕЛЬЗЯ нарушать:

1. **Бэкап обязан быть offsite.** Копия на том же сервере (или диске) не спасёт при гибели
   сервера/диска. Минимум — внешнее хранилище (S3-совместимое: Backblaze B2, rsync.net и т.п.).
2. **Пароль шифрования repo храни ВНЕ сервера** (менеджер паролей). Потерял пароль →
   все бэкапы навсегда нечитаемы. Это самый частый способ остаться без бэкапа.
3. **Бэкап без проверки восстановления — не бэкап.** Хотя бы раз сделай тестовый restore
   (см. backups.md, «Учебное восстановление»).
4. **Автоматизация:** ежедневный запуск через systemd timer + ротация старых снапшотов.

### Что бэкапить

Думай **категориями**, а не отдельными путями — так ничего не забудешь:

| Категория | Примеры путей | Зачем |
|-----------|---------------|-------|
| **Конфиги системы** | `/etc` целиком | nginx, ssh, ufw, fail2ban, systemd-юниты — чтобы поднять сервер «как был» |
| **Данные приложения** | `/home/<USERNAME>/app/data`, `/var/lib/<service>` | то, что нельзя переустановить: пользовательский контент, загрузки |
| **Дампы БД** | `/var/backups/*.sql.gz` | дамп через `pg_dump`/`.backup` **перед** restic (живой файл БД может быть битым) |
| **Секреты** | `.env`, `/root/.config/*` | бэкапятся зашифрованно (restic шифрует repo). Пароль шифрования — **вне сервера** |

**Что НЕ бэкапить** (переустанавливается, только раздувает бэкап):
`node_modules`, `.venv`/`venv`, Docker-образы (`docker pull`), системные пакеты (`apt`),
кэши, `/var/log`, `/tmp`. Эти пути уже в `--exclude` скрипта (см. backups.md).

### Сколько хранить (retention) — выбери политику

restic хранит дедуплицированные снапшоты, поэтому «больше копий» стоит дёшево по месту.
Команда: `restic forget --prune --keep-daily N --keep-weekly N --keep-monthly N`.

| Политика | Команда | Кому подходит | Обоснование |
|----------|---------|---------------|-------------|
| **Базовая** *(дефолт)* | `--keep-daily 7 --keep-weekly 4 --keep-monthly 6` | Большинство прод-серверов | Откат на любой из 7 дней + история до полугода. Ловит и свежую ошибку, и «когда же это сломалось». Уже стоит в `backups.md`. |
| **Лёгкая** | `--keep-daily 7 --keep-weekly 4` | Сайты/боты без ценных накопительных данных | ~1 месяц истории. Минимум места, проще. Подходит, если потеря старых данных некритична. |
| **Долгая** | `--keep-daily 14 --keep-weekly 8 --keep-monthly 12` | БД с важными данными, финансы, юр.требования | Год истории + 2 недели по дням. Дороже по месту, но защищает от «тихой» порчи данных, замеченной не сразу. |

> **Рекомендация для новичка:** начни с **Базовой** — она покрывает оба сценария (быстрый
> откат и долгая история) при копеечной стоимости хранения. Перейти на Долгую можно в любой
> момент, просто поменяв числа в `forget` — старые снапшоты не теряются задним числом.

> **Важно про БД:** retention бессмыслен, если бэкапишь «живой» файл БД — он может быть
> повреждён. Всегда сначала делай дамп (`pg_dump` / SQLite `.backup`), а restic бэкапит дамп.

---

## 6. Мониторинг (узнавать о проблемах раньше пользователей)

**Внешний uptime-мониторинг** (бесплатно): Better Stack / UptimeRobot / healthchecks.io — пингует
сайт/сервис снаружи и шлёт алерт (email/Telegram), если упал. Настраивается в их веб-панели.

**Внутренние алерты по ресурсам** — простой cron-скрипт `/usr/local/bin/healthcheck.sh`.
Telegram-бот бесплатен и приходит мгновенно на телефон — заведи бота через @BotFather,
узнай `chat_id` и подставь токен/чат:

```bash
#!/bin/bash
# Диск > 85% или RAM > 90% → алерт в Telegram
TG_TOKEN="<BOT_TOKEN>"; TG_CHAT="<CHAT_ID>"
alert() { curl -s "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
            -d chat_id="${TG_CHAT}" -d text="$(hostname): $1" >/dev/null; }

DISK=$(df / | awk 'END{print $5+0}')
MEM=$(free | awk '/Mem/{printf "%.0f", $3/$2*100}')
[ "$DISK" -gt 85 ] && alert "ALERT: disk ${DISK}%"
[ "$MEM" -gt 90 ] && alert "ALERT: mem ${MEM}%"
```
```bash
sudo chmod 700 /usr/local/bin/healthcheck.sh   # 700: внутри токен бота — не world-readable
# cron каждый час:
echo '0 * * * * root /usr/local/bin/healthcheck.sh' | sudo tee /etc/cron.d/healthcheck
```

> ⚠️ **Без заполненных `TG_TOKEN`/`TG_CHAT` алертов не будет** — `echo` в cron уходит в
> почту root, которую на свежем VPS никто не доставляет (нет MTA). Либо настрой канал
> уведомления (Telegram выше), либо полагайся на внешний uptime-мониторинг как основной.

---

## 7. Регламент регулярного обслуживания

Бо́льшую часть делает автоматика (раздел 1.5 и 5). Человеку остаётся немного:

| Когда | Что делать | Автоматизировано? |
|-------|-----------|-------------------|
| **Постоянно (само)** | Обновления безопасности (`unattended-upgrades`), ежедневный бэкап, мониторинг | ✅ Да |
| **Еженедельно (~5 мин)** | Глянуть алерты; `df -h` (диск); `sudo docker ps` или `systemctl --failed`; убедиться, что последний бэкап свежий | Полуавтомат |
| **Ежемесячно (~15 мин)** | `sudo apt update && apt list --upgradable` (есть ли крупные апдейты вне security); `sudo fail2ban-client status sshd`; **тестовый restore одного файла из бэкапа** | Вручную |
| **Раз в полгода** | Проверить, не вышел ли новый Ubuntu LTS; обновить пароли/ротировать ключи при необходимости | Вручную |

**Главный принцип обслуживания:** реагируй на алерты, а не «заходи на всякий случай».
Если приходит алерт — есть проблема; если тихо — система здорова.

---

## 8. Pitfalls — чего НЕ делать

1. **Не закрывай SSH-сессию**, пока в новой не проверил вход по ключу + sudo.
2. **Не включай UFW** до `ufw allow 22/tcp` — запрёшь себя.
3. **Не используй `ufw reset`** — сбросит SSH-правило.
4. **Не работай под root и не делай NOPASSWD-sudo** на проде «для удобства».
5. **Не клади секреты в код/git** — только `.env` (и он в `.gitignore`).
6. **Не считай локальную копию бэкапом** — нужен offsite + проверка восстановления.
7. **Не теряй пароль шифрования restic** — без него бэкапы мертвы.
8. **Не оставляй debug-режим** (`DEBUG=True`, `NODE_ENV=development`) на сервере.
9. **Помни: Docker обходит UFW** — биндь чувствительные порты на `127.0.0.1`.
10. **Ubuntu 24.04 ssh.socket** — `Port` в sshd_config не работает, меняй через socket override.

---

## 9. Финальный чеклист готовности к проду

- [ ] Система обновлена; `unattended-upgrades` включён и проверен (`--dry-run`).
- [ ] Работаем под отдельным sudo-пользователем (не root); sudo с паролем.
- [ ] Вход по SSH-ключу работает; `PasswordAuthentication no` (проверено через `sshd -T`).
- [ ] `PermitRootLogin no`; cloud-init не перебивает hardening.
- [ ] UFW включён: deny incoming, открыты только нужные порты; админки — за доверенными IP.
- [ ] fail2ban активен на sshd; свой IP в `ignoreip`.
- [ ] Все секреты в `.env`; `.env` в `.gitignore`; debug выключен (`NODE_ENV=production`).
- [ ] БД и внутренние сервисы не торчат в интернет (localhost / приватная сеть).
- [ ] Docker-логи ротируются; чувствительные порты на `127.0.0.1`.
- [ ] HTTPS работает; автопродление сертификата проверено (`certbot renew --dry-run`).
- [ ] Автобэкап (restic) ежедневно + offsite; пароль шифрования сохранён ВНЕ сервера.
- [ ] **Тестовое восстановление из бэкапа выполнено успешно.**
- [ ] Внешний uptime-мониторинг и алерты по диску/памяти настроены.
