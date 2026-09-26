# Автоматические бэкапы через restic (для новичка)

Цель: ежедневный зашифрованный бэкап в **offsite**-хранилище, с ротацией старых копий,
проверкой целостности и **проверенным восстановлением**.

## Почему restic

- Шифрование «из коробки» (бэкап безопасно хранить у стороннего провайдера).
- Дедупликация — повторные бэкапы занимают мало места (хранятся только изменения).
- Один бинарь, простые команды, поддерживает много бэкендов (S3, Backblaze B2, SFTP, локально).

## Четыре железных правила

1. **Offsite обязателен.** Бэкап на том же сервере/диске не спасёт при гибели сервера.
2. **Пароль шифрования (`RESTIC_PASSWORD`) храни ВНЕ сервера** — в менеджере паролей.
   Потеряешь → бэкапы навсегда нечитаемы. Запиши его ДО первого бэкапа.
3. **Непроверенный бэкап — не бэкап.** Сделай тестовый restore (см. ниже) до того, как
   понадеешься на бэкап в реальной аварии.
4. **Молчащий бэкап — не бэкап.** Упавший таймер на VPS без почты никто не заметит. Раздел 6
   настраивает два сигнала: алерт при ошибке и dead-man's switch, если бэкап не запустился вовсе.

---

## 1. Установка

```bash
sudo apt install restic -y
restic version
```

## 2. Выбор offsite-хранилища

Для новичка проще всего S3-совместимое облако (дёшево, без своего железа):

| Вариант | Чем хорош |
|---------|-----------|
| **Backblaze B2** | Очень дёшево, нативная поддержка в restic, простая регистрация |
| **rsync.net** | Тариф «для borg/restic», доступ по SSH/SFTP |
| **Любой S3** (AWS/Wasabi/Hetzner) | Стандарт, restic умеет нативно |

> Не используй для прод-бэкапа Google Drive / Dropbox через костыли — ненадёжно.

## 3. Секреты — в защищённый файл (не в код, не в git)

`/root/.config/restic/env` (только root, `chmod 600`). Команда ниже — для человека в
терминале; агент пишет этот файл локально и доставляет через `scp` + `install -m 600`
(SKILL.md, правила для агента, п. 2):
```bash
sudo mkdir -p /root/.config/restic
sudo tee /root/.config/restic/env >/dev/null <<'EOF'
export RESTIC_REPOSITORY="b2:<BUCKET_NAME>:prod-backup"
export RESTIC_PASSWORD="<СГЕНЕРИРОВАННЫЙ_ПАРОЛЬ_ХРАНИ_В_МЕНЕДЖЕРЕ_ПАРОЛЕЙ>"
export B2_ACCOUNT_ID="<KEY_ID>"
export B2_ACCOUNT_KEY="<APPLICATION_KEY>"
# Dead-man's switch: заведи бесплатный check на https://healthchecks.io (период 1 day,
# grace 2 hours, алерт в Telegram/email) и вставь его ping-URL:
export HC_PING_URL="https://hc-ping.com/<UUID>"
EOF
sudo chmod 600 /root/.config/restic/env
```

Сгенерировать стойкий пароль repo: `openssl rand -base64 24` → **сразу сохрани его в менеджер паролей.**

## 4. Инициализация репозитория (один раз)

```bash
sudo bash -c 'source /root/.config/restic/env && restic init'
```

## 5. Скрипт бэкапа

`/usr/local/bin/backup-now` (`chmod +x`, владелец root):
```bash
#!/bin/bash
set -euo pipefail
source /root/.config/restic/env

# Для БД — делай дамп ПЕРЕД бэкапом (бэкап «живого» файла БД может быть битым).
# Дамп кладём в /var/backups, и этот путь ОБЯЗАТЕЛЬНО есть в PATHS ниже:
# mkdir -p /var/backups
# sudo -u postgres pg_dump mydb | gzip > /var/backups/mydb-$(date +%F).sql.gz
# для SQLite: sqlite3 /path/app.db ".backup /var/backups/app-$(date +%F).db"
# Чистим старые дампы локально (restic уже хранит историю):
# find /var/backups -name '*.sql.gz' -mtime +7 -delete

# СПИСОК ПУТЕЙ — подставь свои (см. SKILL.md, секция 5 «Что бэкапить»).
PATHS=(
  /etc                       # конфиги системы
  /root/server-notes.md      # паспорт сервера (SKILL.md, 9.3)
  /home/<USERNAME>/app       # код/данные приложения (НЕ node_modules/venv)
  /var/lib/<service>         # данные сервиса
  /var/backups               # дампы БД (если делаешь дамп выше)
)

restic backup "${PATHS[@]}" \
  --exclude-caches \
  --exclude '*/node_modules' --exclude '*/.venv' --exclude '*/venv'

# Ротация: храним 7 дней + 4 недели + 6 месяцев, остальное удаляем
restic forget --prune --keep-daily 7 --keep-weekly 4 --keep-monthly 6

# Проверка целостности: каждый запуск читает 1/30 данных → за месяц весь repo сверен
restic check --read-data-subset=1/30

# Dead-man's switch: сообщаем healthchecks.io «бэкап прошёл». Сюда доходим только если
# всё выше отработало (set -e). Нет пинга к сроку → healthchecks сам пришлёт алерт.
# Именно if, а не «[ ] && curl»: иначе при пустом HC_PING_URL скрипт завершится с кодом 1,
# systemd сочтёт бэкап упавшим и OnFailure пришлёт ложный «BACKUP FAILED».
if [ -n "${HC_PING_URL:-}" ]; then
  curl -fsS -m 10 --retry 3 "$HC_PING_URL" >/dev/null
fi
```

Запусти вручную первый раз и убедись, что прошло без ошибок, а в healthchecks.io check
стал зелёным:
```bash
sudo /usr/local/bin/backup-now
```

## 6. Автозапуск ежедневно (systemd timer — надёжнее cron) + алерт о падении

Нужен `/usr/local/bin/tg-alert` из SKILL.md, раздел 6 (сначала проверь, что `tg-alert "test"` доходит).

`/etc/systemd/system/backup-failed.service` — срабатывает, когда бэкап завершился ошибкой:
```ini
[Unit]
Description=Alert on restic backup failure
[Service]
Type=oneshot
ExecStart=/usr/local/bin/tg-alert "BACKUP FAILED. Смотри: journalctl -u backup-daily.service -n 50"
```

`/etc/systemd/system/backup-daily.service`:
```ini
[Unit]
Description=Daily restic backup
OnFailure=backup-failed.service
[Service]
Type=oneshot
ExecStart=/usr/local/bin/backup-now
```

> Два сигнала дополняют друг друга: `OnFailure` ловит **ошибку** скрипта (нет доступа к
> хранилищу, неверный пароль, кончилось место), healthchecks.io — ситуацию, когда скрипт
> **не запустился вовсе** (таймер выключен, сервер лежит). Одного недостаточно.

`/etc/systemd/system/backup-daily.timer`:
```ini
[Unit]
Description=Run restic backup daily
[Timer]
OnCalendar=*-*-* 03:00:00
Persistent=true
[Install]
WantedBy=timers.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now backup-daily.timer
systemctl list-timers backup-daily.timer

# Проверь, что алерт реально доходит — ДО того, как он понадобится:
sudo systemctl start backup-failed.service     # в Telegram пришло «BACKUP FAILED»?
```

> `Persistent=true` — если сервер был выключен в 03:00, бэкап догонится при старте.

---

## 7. Учебное восстановление (ОБЯЗАТЕЛЬНО)

Проверь, что бэкап реально восстанавливается. Делай это **сразу после настройки** и потом раз в месяц.

```bash
source /root/.config/restic/env   # под sudo -i

# Список снапшотов — видишь свежие даты?
restic snapshots --compact

# Восстановить ОДИН файл/папку в /var/tmp (не поверх боевых данных!):
restic restore latest --target /var/tmp/restore-test --include /etc/hostname
cat /var/tmp/restore-test/etc/hostname   # содержимое совпадает с реальным?
rm -rf /var/tmp/restore-test

# Полный restore конкретного снапшота (для реальной аварии):
# restic restore <SNAPSHOT_ID> --target /var/tmp/full-restore
```

> Именно `/var/tmp`, а не `/tmp`: на Ubuntu 26.04 `/tmp` живёт в оперативной памяти, полный
> restore туда съест RAM и пропадёт после перезагрузки.

Если файл восстановился и совпадает — бэкап рабочий. Если нет — чини, пока не авария.

## 8. Диагностика

```bash
# Бэкап не идёт — смотри лог сервиса
sudo journalctl -u backup-daily.service -n 50

# Repo доступен и не повреждён?
sudo bash -c 'source /root/.config/restic/env && restic check'

# Сколько занимает в облаке / сколько снапшотов
sudo bash -c 'source /root/.config/restic/env && restic stats'
```

**Типичные ошибки:**
- `Fatal: wrong password` — неверный `RESTIC_PASSWORD` (тот ли пароль из менеджера?).
- `unable to open repository` — неверные ключи доступа к хранилищу или имя bucket.
- Бэкап огромный — забыл исключить `node_modules`/`venv`/кэши/логи.
- Снапшоты старые — таймер не запускается (`systemctl list-timers`, проверь `enable`).
- Пришёл алерт от healthchecks.io, а от Telegram нет — скрипт не запускался: таймер выключен
  или сервер был недоступен. Смотри `systemctl status backup-daily.timer`.

---

## 9. Runbook «Сервер умер» — восстановление на новый VPS

Сценарий: диск погиб, хостер удалил сервер, или его взломали и проще пересоздать. Есть
offsite-репозиторий restic и пароль от него в менеджере паролей. Порядок:

**1. Новый чистый VPS** той же версии Ubuntu (см. паспорт сервера — он тоже в бэкапе).
Пройди SKILL.md разделы 1.1–1.4 и 2 (пользователь, ключи, hardening, UFW) — это быстрее и
безопаснее, чем тащить чужой `/etc` на новую систему.

**2. Подключи репозиторий** (секреты — из менеджера паролей, не из головы):
```bash
sudo apt install restic -y
sudo mkdir -p /root/.config/restic && sudo chmod 700 /root/.config/restic
# создай /root/.config/restic/env как в разделе 3 (те же RESTIC_REPOSITORY / PASSWORD / ключи)
sudo bash -c 'source /root/.config/restic/env && restic snapshots --compact'   # видишь снапшоты?
```
`Fatal: wrong password` → пароль не тот; `unable to open repository` → ключи хранилища или
имя bucket. Дальше не иди, пока список снапшотов не показался.

**3. Восстанови всё в отдельный каталог, не поверх системы:**
```bash
sudo mkdir -p /var/tmp/restore
sudo bash -c 'source /root/.config/restic/env && restic restore latest --target /var/tmp/restore'
sudo ls /var/tmp/restore            # etc/  home/  root/  var/
sudo cat /var/tmp/restore/root/server-notes.md   # паспорт: что и как было настроено
```

**4. Верни данные приложения и БД** — по паспорту сервера:
```bash
# данные приложения — на прежнее место
sudo rsync -a /var/tmp/restore/home/<USERNAME>/app/ /home/<USERNAME>/app/
sudo chown -R <USERNAME>:<USERNAME> /home/<USERNAME>/app
# БД — из дампа, а не из файлов БД
zcat /var/tmp/restore/var/backups/mydb-<дата>.sql.gz | sudo -u postgres psql mydb
# SQLite: cp /var/tmp/restore/var/backups/app-<дата>.db /path/app.db
```

**5. Конфиги из `/etc` — выборочно, файл за файлом.** Сравнивай с новой системой и переноси
только своё: `nginx/sites-available/<app>`, `fail2ban/jail.d/sshd.local`, юниты в
`systemd/system/`, `docker/daemon.json`, `letsencrypt/` (или просто перевыпусти сертификат).
```bash
diff /var/tmp/restore/etc/nginx/sites-available/<app> /etc/nginx/sites-available/<app>
```
> **Никогда не копируй `/etc` целиком поверх новой системы.** Там `fstab`, `machine-id`,
> `netplan`, `hostname`, ключи хоста sshd от старой машины — новая перестанет грузиться или
> потеряет сеть. `/etc` в бэкапе нужен как справочник, а не как образ.

**6. Подними приложение, проверь снаружи** (`curl -sI https://<DOMAIN>`), затем настрой
бэкап заново на **этом** сервере (разделы 5–6: тот же репозиторий, новый снапшот пойдёт в ту же
историю) и алерты (SKILL.md, раздел 6).

**7. Запиши в паспорт сервера** дату и причину восстановления, что пришлось делать руками —
это и есть список того, что в следующий раз надо положить в бэкап.

Время на всё при готовом бэкапе — час-два. Без учебного восстановления из раздела 7 те же
шаги растягиваются на день из-за сюрпризов, поэтому раздел 7 обязателен.
