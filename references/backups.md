# Автоматические бэкапы через restic (для новичка)

Цель: ежедневный зашифрованный бэкап в **offsite**-хранилище, с ротацией старых копий,
проверкой целостности и **проверенным восстановлением**.

## Почему restic

- Шифрование «из коробки» (бэкап безопасно хранить у стороннего провайдера).
- Дедупликация — повторные бэкапы занимают мало места (хранятся только изменения).
- Один бинарь, простые команды, поддерживает много бэкендов (S3, Backblaze B2, SFTP, локально).

## Три железных правила

1. **Offsite обязателен.** Бэкап на том же сервере/диске не спасёт при гибели сервера.
2. **Пароль шифрования (`RESTIC_PASSWORD`) храни ВНЕ сервера** — в менеджере паролей.
   Потеряешь → бэкапы навсегда нечитаемы. Запиши его ДО первого бэкапа.
3. **Непроверенный бэкап — не бэкап.** Сделай тестовый restore (см. ниже) до того, как
   понадеешься на бэкап в реальной аварии.

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

`/root/.config/restic/env` (только root, `chmod 600`):
```bash
sudo mkdir -p /root/.config/restic
sudo tee /root/.config/restic/env >/dev/null <<'EOF'
export RESTIC_REPOSITORY="b2:<BUCKET_NAME>:prod-backup"
export RESTIC_PASSWORD="<СГЕНЕРИРОВАННЫЙ_ПАРОЛЬ_ХРАНИ_В_МЕНЕДЖЕРЕ_ПАРОЛЕЙ>"
export B2_ACCOUNT_ID="<KEY_ID>"
export B2_ACCOUNT_KEY="<APPLICATION_KEY>"
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

# СПИСОК ПУТЕЙ — подставь свои (см. SKILL.md, секция 5 «Что бэкапить»).
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
```

Запусти вручную первый раз и убедись, что прошло без ошибок:
```bash
sudo /usr/local/bin/backup-now
```

## 6. Автозапуск ежедневно (systemd timer — надёжнее cron)

`/etc/systemd/system/backup-daily.service`:
```ini
[Unit]
Description=Daily restic backup
[Service]
Type=oneshot
ExecStart=/usr/local/bin/backup-now
```

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
```

> `Persistent=true` — если сервер был выключен в 03:00, бэкап догонится при старте.

---

## 7. Учебное восстановление (ОБЯЗАТЕЛЬНО)

Проверь, что бэкап реально восстанавливается. Делай это **сразу после настройки** и потом раз в месяц.

```bash
source /root/.config/restic/env   # под sudo -i

# Список снапшотов — видишь свежие даты?
restic snapshots --compact

# Восстановить ОДИН файл/папку в /tmp (не поверх боевых данных!):
restic restore latest --target /tmp/restore-test --include /etc/hostname
cat /tmp/restore-test/etc/hostname   # содержимое совпадает с реальным?

# Полный restore конкретного снапшота (для реальной аварии):
# restic restore <SNAPSHOT_ID> --target /tmp/full-restore
```

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
