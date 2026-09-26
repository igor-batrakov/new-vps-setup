---
name: new-vps-setup
description: >
  Используй когда нужно настроить новый Ubuntu VPS под продакшн «с нуля», подготовить чистый
  сервер к боевой эксплуатации, сделать hardening, или дать новичку автономно поднять и
  поддерживать прод-сервер. Также когда сервер уже частично настроен или достался от другого
  админа: проверить существующий сервер, аудит настройки, «что тут уже сделано», довести до
  прода. Также при задачах: автообновления безопасности, настройка файрвола, бэкапы, защита SSH,
  чеклист готовности к проду, регулярное обслуживание сервера, потерян доступ по SSH,
  восстановление сервера из бэкапа.
  Ключевые слова: hardening Ubuntu, unattended-upgrades, Ubuntu Pro, UFW, fail2ban, SSH-ключи,
  restic, offsite, Docker, nginx, HTTPS, Let's Encrypt, мониторинг, healthchecks, восстановление
  из бэкапа, заперся на сервере, lynis, ssh-audit.
---

# Настройка нового VPS под продакшн (для новичка)

## Обзор

Этот скилл проводит **по шагам** через подготовку Ubuntu-сервера к продакшну так,
чтобы дальше он **обслуживался максимально автономно**. Аудитория — человек без опыта
системного администрирования. Поэтому:

- **Безопасные дефолты, а не «как у профи».** Никаких NOPASSWD-sudo, никаких отключённых
  проверок ради удобства. То, что упрощает жизнь эксперту, для новичка — мина.
- **Автономность через автоматику.** Обновления безопасности, бэкапы и мониторинг должны
  работать сами. Человек только реагирует на алерты.
- **Каждый шаг проверяется.** После изменения — проверка результата, и только потом следующий шаг.
- **Работает и с частично настроенным сервером.** Раздел 0 показывает, что уже сделано, и у
  каждого раздела есть проверка «уже сделано, если…» — тогда раздел пропускается.
- **Это уровни 1–2, не всё на свете.**

| Уровень | Разделы | Критерий «готово» | Время |
|---------|---------|-------------------|-------|
| **1. Сервер можно оставить включённым** | 0, 1, 2 | Вход только по ключу, root и пароль закрыты, UFW, автообновления, fail2ban | ~1 час, одна сессия, до того как на сервере появятся данные и трафик |
| **2. Это прод** | 3–9 | Бэкап с проверенным восстановлением и алертом, HTTPS, мониторинг, паспорт, контрольная перезагрузка | полдня настройки + неделя наблюдения за алертами |
| **3. По потребности** | не здесь | VPN, DOCKER-USER, смена порта SSH, апгрейд LTS, глубокий аудит, автообновление образов | скилл `ubuntu-server-admin` ([репо](https://github.com/igor-batrakov/ubuntu-server-admin)) |

Уровень 1 без уровня 2 — это «не взломают», но не «не потеряю данные». Словом «прод» сервер
называется только после уровня 2. Третий уровень сюда не тащи: для новичка сила этого скилла
в том, что здесь нет лишнего.

> **Целевая ОС (сервер):** Ubuntu 22.04 / 24.04 / 26.04 LTS — команды для других дистрибутивов отличаются.
> **Локальная машина — любая** (Linux / macOS / Windows): от неё зависят только клиентские
> команды для SSH-ключей (раздел 1.3), всё остальное выполняется на сервере и не зависит от твоей ОС.

> **Что изменилось в Ubuntu 26.04** (всё ниже работает как есть, но не пугайся):
> - `sudo` теперь `sudo-rs` (переписан на Rust): при вводе пароля **видны звёздочки** — это норма,
>   не ошибка. Читает те же `/etc/sudoers` и `/etc/sudoers.d/`.
> - Время синхронизирует `chrony` вместо `systemd-timesyncd` — команды проверки те же (`timedatectl`).
> - **`/tmp` — в оперативной памяти (tmpfs)** и очищается при перезагрузке. Не распаковывай туда
>   бэкапы и большие архивы — используй `/var/tmp` (на диске). В backups.md это уже учтено.
> - `apt` 3.1 умеет откатывать установки: `apt history-list`, `apt history-undo <ID>`.

## Золотые правила (перед ЛЮБЫМ изменением)

1. **Бэкап конфига:** `sudo cp /path/config /path/config.bak.$(date +%F-%H%M)`
2. **Проверь состояние:** `sudo systemctl status <service>` / `sudo docker ps`
3. **После изменения — проверь результат** (логи, статус, тестовое подключение).
4. **Никогда не закрывай текущую SSH-сессию**, пока в **новой** сессии не убедился, что
   доступ и sudo работают. Потеря SSH на удалённом сервере = выезд в консоль провайдера (VNC).
5. **Перед опасными шагами — гейт** (следующий раздел). Не прошёл гейт — не делай шаг.

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

## Правила для агента (обязательно, если сервер настраивает агент)

**1. Любая команда сложнее одной строки — только из файла.** Написать скрипт инструментом
Write, проверить `bash -n`, отправить на сервер, запустить оттуда:
```bash
bash -n s.sh                                   # синтаксис
scp s.sh <alias>:/tmp/s.sh                     # доставить
ssh <alias> 'bash /tmp/s.sh'                   # запустить (или sudo — см. п. 4)
```
Запрещено: heredoc внутри `ssh '...'`, `bash -c '...'` с вложенными кавычками, длинные
пайпы в одной строке с `$`, `!`, обратными кавычками. **Почему твёрдо:** сломанное
экранирование почти всегда проваливается **тихо** и выглядит как успех — heredoc закрывает
внешнюю кавычку и записывает файл с выеденными кусками, `grep -c` во вложенных кавычках даёт
«0» вместо реального числа, `tar` принимает имя за флаг и делает архив в 29 байт.

**2. Конфиги на сервер — тоже файлом, не `echo | tee`.** Написать локально Write → `scp` →
на сервере `sudo install -m 644 /tmp/x.conf /etc/<путь>` (для `sshd_config.d`, `jail.d`,
юнитов systemd, `daemon.json`). `echo 'текст' | sudo tee` допустим только для одной строки
без `$`, `!` и кавычек.

**3. Проверять по содержимому результата, не по коду возврата.** Гейт после команды смотрит
на число файлов, строк, байт или текст внутри: `sshd -T | grep passwordauthentication` должен
показать `no`, а не «команда завершилась без ошибки».

**4. `sudo` с паролем и агент — режим выбирает пользователь, один раз, в начале.** Инструмент
Bash не имеет терминала: `ssh <alias> sudo …` упадёт с «a terminal is required». Пока сервер
отдан как root по ключу (до раздела 1.4) — агент работает root'ом напрямую, вопроса нет.
Как только появился sudo-пользователь с паролем (1.2) — агент **честно предлагает два режима**
и не выбирает сам:

| | Режим A — безопасный | Режим B — быстрый |
|---|---|---|
| Как | Агент готовит скрипт, пользователь запускает его в своём терминале: в Claude Code набрать `! ssh -t <alias> sudo bash /tmp/s.sh`. Префикс `!` даёт TTY для пароля, вывод попадает агенту | Временный NOPASSWD для `<USERNAME>` отдельным файлом **с таймером самоудаления через 4 часа**. Агент выполняет `ssh <alias> sudo bash /tmp/s.sh` сам |
| Цена | Каждый sudo-шаг — руками, пароль вводить по нескольку раз за раздел. Медленнее в 2–3 раза | На время настройки ключ SSH = root без пароля. Ошибка агента или компрометация ноутбука в это окно не упрётся в барьер пароля |
| Кому | Первый раз; сервер с данными или трафиком; чужой сервер | Чистый сервер без данных, настройка в один присест, пользователь рядом |
| Конец | — | Снять до чеклиста 9.4; диагностика и чеклист ловят забытый файл |

Формулировка для пользователя: «Есть быстрый режим: временный sudo без пароля на время
настройки, снимается автоматически через 4 часа и вручную в конце. Удобнее, но на это время
ключ равен root без барьера. Есть безопасный: каждую sudo-команду запускаешь сам через `!`,
пароль остаётся у тебя, медленнее и больше ручной работы. Какой?» Без ответа — режим A.

**Режим B, включение** — единственный раз через `!`, дальше агент работает сам:
```bash
#!/bin/bash
# sudo-temp-on.sh <USERNAME> — временный NOPASSWD на время настройки, сам снимется через 4 часа
set -euo pipefail
U="${1:?пользователь}"
F=/etc/sudoers.d/90-setup-temp
printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$U" > /tmp/90-setup-temp
visudo -cf /tmp/90-setup-temp        # ОБЯЗАТЕЛЬНО: файл с ошибкой ломает sudo целиком
install -m 440 -o root -g root /tmp/90-setup-temp "$F"
systemctl stop sudo-temp-expire.timer 2>/dev/null || true
systemd-run --unit=sudo-temp-expire --on-active=4h /bin/rm -f "$F"
echo "NOPASSWD для $U включён, снимется сам в $(date -d '+4 hours' '+%H:%M')"
```
```
! ssh -t <alias> sudo bash /tmp/sudo-temp-on.sh <USERNAME>
```
Проверка агентом: `ssh <alias> 'sudo -n true && echo sudo-ok'` → `sudo-ok`. Если таймер
истёк посреди настройки — попросить включить снова, не продлевать молча.

**Режим B, выключение** — в конце уровня 2 (или уровня 1, если дальше не идёшь), до чеклиста:
```bash
sudo rm -f /etc/sudoers.d/90-setup-temp
sudo systemctl stop sudo-temp-expire.timer 2>/dev/null
sudo -k && sudo -n true 2>&1 | head -1     # ожидаемо: sudo: a password is required
```
Ожидаемый вывод последней строки — именно `a password is required`. Пустой вывод = NOPASSWD
ещё действует, искать другие файлы: `sudo grep -r NOPASSWD /etc/sudoers.d/`.

- Если доступ только по паролю (хостер не принял ключ) — шаги 1.2–1.3 пользователь делает по
  подготовленному скрипту через `!` в любом режиме.
- **Постоянный NOPASSWD «чтобы агенту было удобно» не предлагать.** Режим B — только с таймером,
  только отдельным файлом `90-setup-temp`, только до конца настройки.

**5. Опасные шаги — только через гейт** (следующий раздел). Если хотя бы один пункт гейта не
выполнен — остановиться и сказать пользователю, что именно не выполнено. Не «пробовать».

**6. После каждого раздела — обновлять паспорт сервера** (раздел 9.3) и сообщать
пользователю, что сделано и как проверено.

---

## Гейт от «я заперся» — обязателен перед опасными шагами

Опасные шаги: любая правка `sshd_config`/`sshd_config.d`, смена порта SSH, `AllowUsers`,
`PasswordAuthentication no`, `PermitRootLogin no`, `ufw enable`, `passwd -l`, удаление
пользователя, правка `ignoreip` в fail2ban. Перед **каждым** из них:

| # | Проверка | Как | Не выполнено → |
|---|----------|-----|----------------|
| 1 | **Консоль провайдера открыта** в браузере (VNC / Serial / Rescue) и ты знаешь пароль root или sudo-пользователя | Открыть вкладку панели хостера, проверить, что консоль показывает приглашение логина | СТОП. Найти консоль. Без неё ошибка = потеря сервера |
| 2 | **Вторая SSH-сессия открыта** и живёт | Второе окно терминала с `ssh <alias>` | СТОП. Открыть |
| 3 | **Вход по ключу проверен новой сессией** (для шагов, отключающих пароль) | `ssh -o BatchMode=yes -o IdentitiesOnly=yes -i ~/.ssh/<key> <USERNAME>@<SERVER_IP> 'id; sudo -n true 2>&1 \| head -1'` → видишь `uid=…` и `sudo: a password is required` (это норма, значит sudo есть; в режиме B вторая строка пустая) | СТОП. Ключ не работает — раздел 1.3 |
| 4 | **Бэкап конфигов** | `sudo cp -a /etc/ssh /etc/ssh.bak.$(date +%F-%H%M)`; для UFW: `sudo cp -a /etc/ufw /etc/ufw.bak.$(date +%F-%H%M)` | Сделать |
| 5 | **Таймер авто-отката взведён ДО копирования файла** | см. ниже. Под `ssh.socket` новый drop-in действует на **следующее подключение даже без restart** — значит, «положу файл, потом взведу» уже опасно | Взвести |
| 6 | **Синтаксис проверен сразу после копирования** | `sudo sshd -t` (пустой вывод = ОК). Ошибка → убрать файл немедленно, до любого restart | Чинить |
| 7 | **Новый порт / свой IP открыты заранее** | Смена порта: `sudo ufw allow <PORT>/tcp` до `restart ssh.socket`. fail2ban: свой IP в `ignoreip` (узнать: `curl -s ifconfig.me`) | Сделать |

**Таймер авто-отката** — страховка на случай, если новая сессия не откроется. Сначала таймер,
**потом** файл: если положить файл первым, окно между «применилось» и «таймер взведён» уже
может оказаться фатальным.

```bash
# Для правки sshd (откатит через 5 минут, если не отменить):
sudo systemd-run --unit=ssh-rollback --on-active=300 \
  /bin/sh -c 'rm -f /etc/ssh/sshd_config.d/99-hardening.conf; systemctl restart ssh.socket ssh.service'

# Для включения UFW:
sudo systemd-run --unit=ufw-rollback --on-active=300 /usr/sbin/ufw disable

# ... применить изменение, открыть НОВУЮ сессию, убедиться что вход и sudo работают ...

sudo systemctl stop ssh-rollback.timer     # отменить откат — только после успешной проверки
sudo systemctl stop ufw-rollback.timer
```

> Если `systemd-run` говорит `Unit ssh-rollback.timer already exists` — прошлый таймер ещё
> висит: `sudo systemctl stop ssh-rollback.timer` и взвести заново.
> `sshd -t` ловит синтаксис, но **не** ловит «ни один клиент не сможет договориться» (например,
> об алгоритмах) — таймер и консоль провайдера остаются последним рубежом.

**Что заперло доступ, если всё же случилось — раздел 10.**

---

## 0. Диагностика — что уже есть

**Выполни ПЕРВЫМ, и на чистом сервере, и на частично настроенном.** Хостеры отдают сервер с
частичной настройкой (cloud-init, ufw, дефолтный пользователь с NOPASSWD), а «наследственный»
сервер может быть настроен наполовину.

**Одним запуском** — скрипт `scripts/diagnose.sh` только читает и ничего не меняет. Каждой
проверке ставит `[OK]` / `[!!]` / `[..]` (справочно, в том числе «своя схема» на серверах,
настроенных не по этому скиллу), а в конце печатает план «что делать» двумя блоками: сначала
уровень 1, потом уровень 2, со ссылками на разделы:
```bash
scp scripts/diagnose.sh <USERNAME>@<SERVER_IP>:/tmp/
ssh -t <USERNAME>@<SERVER_IP> sudo bash /tmp/diagnose.sh
# пока сервер отдан как root: ssh root@<SERVER_IP> bash /tmp/diagnose.sh
```

**Или руками** — те же проверки:
```bash
# Система
lsb_release -a && uname -r
free -h && df -h && nproc
[ -f /var/run/reboot-required ] && echo 'нужна перезагрузка'

# Кто я и какие права
whoami && id

# Кому хостер уже дал sudo без пароля (cloud-init создаёт ubuntu/debian/admin с NOPASSWD)
sudo grep -rn NOPASSWD /etc/sudoers /etc/sudoers.d/ 2>/dev/null

# SSH-конфиг (эффективные значения, а не только файлы!)
# Если в конфиге есть блоки Match, sshd -T требует -C user=root,host=localhost,addr=127.0.0.1
sudo sshd -T | grep -iE 'permitrootlogin|passwordauthentication|pubkeyauthentication|^port '

# Файрвол
sudo ufw status verbose

# Что слушает порты
sudo ss -tlnp

# Автообновления (включены?) и Ubuntu Pro (ESM подключён?)
cat /etc/apt/apt.conf.d/20auto-upgrades 2>/dev/null
pro status 2>/dev/null | grep -E 'esm-apps|esm-infra'

# Время синхронизируется? (иначе сертификаты и логи «поедут»)
timedatectl | grep -iE 'synchronized|NTP service'

# Docker / fail2ban / бэкапы / упавшие сервисы
sudo docker ps 2>/dev/null
sudo fail2ban-client status 2>/dev/null
systemctl list-timers 'backup*' 'apt-daily*'
systemctl --failed
```

**Как читать результат — карта разделов:**

| Нашёл | Иди в раздел |
|-------|--------------|
| `PasswordAuthentication yes`, `PermitRootLogin yes`, нет `AllowUsers` | 1.3 → 1.4 |
| NOPASSWD у `ubuntu`/`debian`/`admin` | 1.2 |
| Нет `20auto-upgrades` или `Unattended-Upgrade "0"`; ESM не подключён | 1.5 |
| fail2ban не установлен / jail sshd не активен | 1.6 |
| `synchronized: no`, нет swap при RAM < 2 ГБ, journald без лимита | 1.7 |
| UFW `inactive` или `Default: allow (incoming)` | 2 |
| Порт БД (5432/3306/6379/27017) слушает на `0.0.0.0`; Docker без лог-ротации | 3 |
| Сайт без HTTPS | 4 |
| Нет таймера бэкапа, нет `backup-failed.service` | 5 |
| Нет `tg-alert`, нет `healthcheck` cron | 6 |
| Есть упавшие сервисы (`systemctl --failed`) | 8, потом `journalctl -u <unit>` |
| Есть `/root/server-notes.md` | прочитай его первым — там решения прошлого админа |

После диагностики **сообщи пользователю что найдено и не начинай настройку без подтверждения.**
Если есть `/root/server-notes.md` (паспорт сервера, раздел 9.3) — прочитай и учитывай.

---

## 1. Первичная настройка и безопасность — уровень 1

> Сверься с секцией 0 — часть может быть уже сделана. У каждого подраздела есть проверка
> «уже сделано, если…» — тогда его пропускай.

### 1.1 Обновление системы

```bash
sudo apt update && sudo apt upgrade -y
sudo apt autoremove -y
# Если ядро обновилось — потребуется reboot (см. вывод или /var/run/reboot-required).
# Перезагружай осознанно: sudo reboot   # и переподключись через ~30-60с
```

### 1.2 Отдельный sudo-пользователь (НЕ работаем под root)

**Уже сделано, если:** `getent group sudo` показывает твоего пользователя, и
`sudo grep -r NOPASSWD /etc/sudoers.d/` ничего не находит (кроме `90-setup-temp`, если ты
осознанно в режиме B из правил для агента, п. 4).

```bash
sudo adduser <USERNAME>            # задаст пароль — выбери надёжный, сохрани в менеджере паролей
sudo usermod -aG sudo <USERNAME>
```

> **Для новичка sudo оставляем с запросом пароля.** Это намеренно: NOPASSWD-sudo снимает
> последний барьер при компрометации ключа или сессии. Пароль sudo нужен и как fallback,
> если потеряется SSH-ключ (см. 1.3).

**Дефолтный пользователь хостера.** Если в диагностике `grep NOPASSWD` что-то нашёл (обычно
`/etc/sudoers.d/90-cloud-init-users` для пользователя `ubuntu`), у этого пользователя sudo
без пароля и, как правило, **пароля нет вообще**. Два варианта:

- **Заводишь нового пользователя** (рекомендуется) — после того, как в 1.3 проверил вход и sudo
  под новым (гейт, п. 3), дефолтного запри: `sudo passwd -l ubuntu` (блокирует пароль;
  `AllowUsers` в 1.4 закроет ему и SSH). Файл `90-cloud-init-users` можно удалить.
- **Оставляешь дефолтного** — сначала задай ему пароль (`sudo passwd ubuntu`), **проверь `sudo`
  в новой сессии**, и только потом убирай файл с NOPASSWD. Иначе останешься без sudo вообще.

### 1.3 SSH-ключи (вход без пароля по ключу)

**Уже сделано, если:** проверка из гейта (п. 3) проходит — `ssh -o BatchMode=yes …` под
твоим пользователем печатает `uid=…`.

Тип ключа — **ed25519** (не RSA). Имя — `<server>_<device>`, с passphrase.

**На локальной машине (Linux / macOS):**
```bash
ssh-keygen -t ed25519 -f ~/.ssh/<server>_<device> -C "<server>_<device>"
ssh-copy-id -i ~/.ssh/<server>_<device>.pub <USERNAME>@<SERVER_IP>
```

> **На Windows 10/11** OpenSSH-клиент встроен (`ssh`, `ssh-keygen` работают так же), но
> **`ssh-copy-id` там нет.** Два пути:
> - **Проще всего — WSL:** установи Ubuntu через WSL и выполняй команды как для Linux выше.
> - **Чистый PowerShell** — сгенерируй ключ и скопируй его на сервер вручную:
>   ```powershell
>   ssh-keygen -t ed25519 -f $env:USERPROFILE\.ssh\<server>_<device> -C "<server>_<device>"
>   Get-Content $env:USERPROFILE\.ssh\<server>_<device>.pub | ssh <USERNAME>@<SERVER_IP> "mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
>   ```
>   Файл конфига — `%USERPROFILE%\.ssh\config` (тот же формат, что ниже).

**Проверь вход по ключу в ОТДЕЛЬНОЙ сессии (старую не закрывай!):**
```bash
ssh -t -i ~/.ssh/<server>_<device> -o IdentitiesOnly=yes <USERNAME>@<SERVER_IP> 'whoami; sudo whoami'
```
Ожидаемый вывод: первая строка `<USERNAME>`, затем запрос пароля sudo, затем `root`.
`-t` обязателен: без терминала `sudo` не сможет спросить пароль и упадёт с «a terminal is required».

Удобный alias в `~/.ssh/config` на локальной машине:
```
Host <alias>
    HostName <SERVER_IP>
    User <USERNAME>
    IdentityFile ~/.ssh/<server>_<device>
    IdentitiesOnly yes
```

### 1.4 SSH hardening ⚠️ гейт обязателен

**Уже сделано, если:** `sudo sshd -T | grep -iE 'permitrootlogin|passwordauthentication'`
показывает обе строки со значением `no`.

**Пройди гейт** (все 7 пунктов), потом создай `/etc/ssh/sshd_config.d/99-hardening.conf`:
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
> `AllowUsers` — перечисли **всех**, кто должен входить (через пробел). Кого нет в списке —
> не войдёт, даже с ключом.

Примени и проверь:
```bash
sudo sshd -t                                              # синтаксис ОК? (пустой вывод = ОК)
sudo systemctl restart ssh
sudo sshd -T | grep -iE 'permitroot|passwordauth'         # эффективные значения
```
Ожидаемый вывод:
```
permitrootlogin no
passwordauthentication no
```
Теперь **новая сессия** → вход работает → `sudo systemctl stop ssh-rollback.timer`.

**Gotcha 1 — cloud-init перезаписывает hardening.** Файл `/etc/ssh/sshd_config.d/50-cloud-init.conf`
часто содержит `PasswordAuthentication yes` и в `sshd_config.d/` действует «first match wins».
Проверяй через `sudo sshd -T` (эффективные значения), а не только свой файл. Если перебивает —
поправь/удали строку в `50-cloud-init.conf`.

**Gotcha 2 — смена порта SSH под `ssh.socket` (Ubuntu 22.10+, включая 24.04 и 26.04).** sshd
запускается через systemd-сокет, но `Port` по-прежнему задаётся в `sshd_config` (или drop-in в
`sshd_config.d/`): генератор `sshd-socket-generator` читает его оттуда. Просто `restart ssh`
порт **не сменит** — нужно пересобрать сокет:
```bash
sudo ufw allow <PORT>/tcp comment 'SSH new port'   # если UFW уже включён — ДО смены порта
sudo systemctl daemon-reload && sudo systemctl restart ssh.socket
sudo ss -tlnp | grep sshd                          # слушает новый порт?
```
Проверь вход на новый порт в **новой** сессии, старую не закрывай. Старый совет «`ListenStream`
в override сокета» устарел: он был нужен только в 22.10–23.10.

### 1.5 Автоматические обновления безопасности ⭐ (ядро автономности)

**Уже сделано, если:** в `/etc/apt/apt.conf.d/20auto-upgrades` стоит
`Unattended-Upgrade "1"`, `systemctl list-timers 'apt-daily*'` показывает два активных таймера
и `pro status` показывает `esm-apps enabled`.

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
> (healthcheck из раздела 6 напомнит). Для одиночного прод-сервера новичку обычно лучше `true`.

**Ubuntu Pro (бесплатно для 5 машин) — без него половина автообновлений не работает.**
fail2ban, restic, certbot, nginx-модули живут в репозитории `universe`, а security-патчи для
`universe` на LTS приходят только через ESM Apps. Строки `ESMApps` в конфиге выше без подписки
ничего не дают. Токен — на https://ubuntu.com/pro/dashboard (личный аккаунт, бесплатно):
```bash
sudo pro attach <TOKEN>
pro status                       # esm-apps и esm-infra — enabled
```

Проверка — сухой прогон без установки:
```bash
sudo unattended-upgrade --dry-run --debug 2>&1 | tail -20
systemctl list-timers 'apt-daily*'   # таймеры активны?
```
Ожидаемый вывод `list-timers`: две строки, `apt-daily.timer` и `apt-daily-upgrade.timer`, у
обеих заполнено `NEXT`.

### 1.6 fail2ban (защита SSH от брутфорса)

**Уже сделано, если:** `sudo fail2ban-client status sshd` показывает jail и счётчики.

Базовой конфигурации достаточно — не усложняй recidive/nftables на старте.

```bash
sudo apt install fail2ban -y
```

`/etc/fail2ban/jail.d/sshd.local`:
```ini
[sshd]
enabled = true
# Читать логи из journald: на 24.04/26.04 без rsyslog нет /var/log/auth.log,
# и без этой строки fail2ban падает с «Have not found any log file for sshd jail»
backend = systemd
# port = <PORT>   # только если сменил порт SSH в 1.4
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
Ожидаемый вывод:
```
Status for the jail: sshd
|- Filter
|  |- Currently failed: 0
|  |- Total failed:     0
|  `- Journal matches:  _SYSTEMD_UNIT=ssh.service + _COMM=sshd
`- Actions
   |- Currently banned: 0
   ...
```
Если вместо этого `ERROR ... NOK: ('sshd',)` — jail не поднялся: `sudo journalctl -u fail2ban -n 20`.

### 1.7 Таймзона, лимит журнала и (для маленьких VPS) swap

**Уже сделано, если:** `timedatectl` показывает нужную зону и `synchronized: yes`,
`journalctl --disk-usage` ограничен, `swapon --show` не пуст (или RAM ≥ 2 ГБ).

```bash
sudo timedatectl set-timezone <Region/City>     # напр. Europe/Moscow или UTC

# Лимит системного журнала — иначе на маленьком диске journald разрастётся до гигабайт
sudo mkdir -p /etc/systemd/journald.conf.d
printf '[Journal]\nSystemMaxUse=200M\n' | sudo tee /etc/systemd/journald.conf.d/size.conf
sudo systemctl restart systemd-journald && journalctl --disk-usage

# Swap нужен на VPS с малым RAM (< 2 ГБ), чтобы OOM не убивал сервисы:
free -h
sudo fallocate -l 2G /swapfile && sudo chmod 600 /swapfile
sudo mkswap /swapfile && sudo swapon /swapfile
grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
echo 'vm.swappiness=10' | sudo tee /etc/sysctl.d/99-swap.conf && sudo sysctl --system
```

---

## 2. Файрвол UFW — уровень 1 ⚠️ гейт обязателен

**Уже сделано, если:** `sudo ufw status verbose` показывает `Status: active` и
`Default: deny (incoming), allow (outgoing)`.

Принцип: **закрыто всё, открыто только нужное.** Сначала разреши SSH, иначе запрёшь себя.
Перед `ufw enable` — гейт: вторая сессия, консоль провайдера, таймер `ufw-rollback`.

```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow 22/tcp comment 'SSH'      # ВАЖНО: до enable! Если порт сменил — свой порт
sudo ufw enable
sudo ufw status verbose
```
Ожидаемый вывод (начало):
```
Status: active
Logging: on (low)
Default: deny (incoming), allow (outgoing), disabled (routed)
```
Новая сессия входит → `sudo systemctl stop ufw-rollback.timer`.

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

**Уровень 1 пройден**, если чеклист 9.4 закрыт по пунктам «система обновлена», «sudo-пользователь»,
«вход по ключу», «PermitRootLogin no», «UFW», «fail2ban». Сервер можно оставить включённым.
Дальше — уровень 2: без него сервер защищён от взлома, но не от потери данных.

---

## 3. Docker — уровень 2 (опционально — если приложения в контейнерах)

**Уже сделано, если:** `docker --version` работает и `/etc/docker/daemon.json` содержит `max-size`.

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

### Контейнеры должны переживать перезагрузку
В `docker-compose.yml` у каждого сервиса `restart: unless-stopped` (или `--restart unless-stopped`
в `docker run`). Без этого после ночной автоперезагрузки (1.5) приложение не поднимется —
проверяется контрольной перезагрузкой в 9.2.

### ⚠️ Docker обходит UFW
Порт, проброшенный как `-p 8080:8080`, **доступен из интернета, даже если UFW его не разрешал.**
Безопасные варианты:
- Биндить только на localhost: `-p 127.0.0.1:8080:8080` (доступ только через nginx/SSH-туннель).
- Не пробрасывать порты БД наружу вообще — общаться по имени сервиса внутри docker-сети.

Проверка: `sudo ss -tlnp | grep -v 127.0.0.1` — в списке не должно быть портов приложения и БД.

---

## 4. nginx + HTTPS — уровень 2 (опционально — если есть веб-приложение и домен)

**Уже сделано, если:** `curl -sI https://<DOMAIN>` отвечает `HTTP/2 200` (или 301/302) и
`sudo certbot renew --dry-run` проходит.

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

## 5. Автоматические бэкапы (restic + offsite) — уровень 2, обязательно для «прода»

**Уже сделано, если:** `systemctl list-timers backup-daily.timer` показывает `NEXT`,
`backup-failed.service` существует, и тестовое восстановление (backups.md, раздел 7) проходило.

> **Полная инструкция (установка, репозиторий, скрипт, таймер, алерты, восстановление,
> сценарий «сервер умер»):** читай **references/backups.md** — там пошагово.

Ключевые принципы, которые НЕЛЬЗЯ нарушать:

1. **Бэкап обязан быть offsite.** Копия на том же сервере (или диске) не спасёт при гибели
   сервера/диска. Минимум — внешнее хранилище (S3-совместимое: Backblaze B2, rsync.net и т.п.).
2. **Пароль шифрования repo храни ВНЕ сервера** (менеджер паролей). Потерял пароль →
   все бэкапы навсегда нечитаемы. Это самый частый способ остаться без бэкапа.
3. **Бэкап без проверки восстановления — не бэкап.** Хотя бы раз сделай тестовый restore
   (см. backups.md, «Учебное восстановление»).
4. **Автоматизация:** ежедневный запуск через systemd timer + ротация старых снапшотов.
5. **Падение бэкапа должно быть заметно.** На свежем VPS нет почты, поэтому упавший таймер
   молчит месяцами. Нужны два сигнала: алерт при ошибке скрипта (`OnFailure` → Telegram) и
   dead-man's switch (healthchecks.io ждёт «я прошёл» и сам пишет, если пинга нет). Настраивается
   в backups.md, а канал Telegram (`tg-alert`) — в разделе 6.

### Что бэкапить

Думай **категориями**, а не отдельными путями — так ничего не забудешь:

| Категория | Примеры путей | Зачем |
|-----------|---------------|-------|
| **Конфиги системы** | `/etc` целиком | nginx, ssh, ufw, fail2ban, systemd-юниты — чтобы поднять сервер «как был» |
| **Данные приложения** | `/home/<USERNAME>/app/data`, `/var/lib/<service>` | то, что нельзя переустановить: пользовательский контент, загрузки |
| **Дампы БД** | `/var/backups/*.sql.gz` | дамп через `pg_dump`/`.backup` **перед** restic (живой файл БД может быть битым) |
| **Секреты** | `.env`, `/root/.config/*` | бэкапятся зашифрованно (restic шифрует repo). Пароль шифрования — **вне сервера** |
| **Паспорт сервера** | `/root/server-notes.md` | чтобы при восстановлении помнить, что и зачем было настроено |

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

## 6. Мониторинг — уровень 2 (узнавать о проблемах раньше пользователей)

**Уже сделано, если:** `sudo /usr/local/bin/tg-alert test` приходит в Telegram и есть
`/etc/cron.d/healthcheck`.

**Внешний uptime-мониторинг** (бесплатно): Better Stack / UptimeRobot / healthchecks.io — пингует
сайт/сервис снаружи и шлёт алерт (email/Telegram), если упал. Настраивается в их веб-панели.

**Канал алертов — Telegram.** Бот бесплатен и приходит мгновенно на телефон: заведи бота через
@BotFather, узнай свой `chat_id` (напиши боту, затем открой
`https://api.telegram.org/bot<BOT_TOKEN>/getUpdates`). Один скрипт-отправитель, его используют
и проверка ресурсов ниже, и алерт о падении бэкапа из backups.md.

`/usr/local/bin/tg-alert`:
```bash
#!/bin/bash
# Отправить сообщение в Telegram: tg-alert "текст"
TG_TOKEN="<BOT_TOKEN>"; TG_CHAT="<CHAT_ID>"
curl -fsS -m 10 "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
  -d chat_id="${TG_CHAT}" --data-urlencode text="$(hostname): $*" >/dev/null
```
```bash
sudo chmod 700 /usr/local/bin/tg-alert          # 700: внутри токен бота — не world-readable
sudo /usr/local/bin/tg-alert "test"             # сообщение пришло на телефон?
```

**Внутренние алерты** — cron-скрипт `/usr/local/bin/healthcheck.sh`. Четыре проверки: диск,
память, «нужна перезагрузка» (если автоперезагрузка в 1.5 выключена) и упавшие сервисы:
```bash
#!/bin/bash
# Раз в час. Диск > 85%, занято > 90% RAM (с учётом available), ждёт reboot, упавшие юниты → Telegram
A=/usr/local/bin/tg-alert
DISK=$(df / | awk 'END{print $5+0}')
MEM=$(free | awk '/Mem/{printf "%.0f", ($2-$7)/$2*100}')
[ "$DISK" -gt 85 ] && $A "ALERT: disk ${DISK}%"
[ "$MEM" -gt 90 ] && $A "ALERT: mem ${MEM}%"
[ -f /var/run/reboot-required ] && [ "$(date +%H)" = "09" ] && $A "reboot required (kernel updated)"
FAILED=$(systemctl --failed --no-legend --plain | awk '{print $1}' | tr '\n' ' ')
[ -n "$FAILED" ] && $A "FAILED units: $FAILED"
exit 0
```
```bash
sudo chmod 755 /usr/local/bin/healthcheck.sh
# cron каждый час:
echo '0 * * * * root /usr/local/bin/healthcheck.sh' | sudo tee /etc/cron.d/healthcheck
sudo /usr/local/bin/healthcheck.sh && echo OK    # прогон вручную: без алертов = всё в норме
```

> ⚠️ **Без рабочего `tg-alert` алертов не будет** — вывод cron уходит в почту root, которую на
> свежем VPS никто не доставляет (нет MTA). Либо настрой Telegram выше и проверь тестовым
> сообщением, либо полагайся на внешний uptime-мониторинг как основной.

---

## 7. Регламент регулярного обслуживания

Бо́льшую часть делает автоматика (раздел 1.5 и 5). Человеку остаётся немного:

| Когда | Что делать | Автоматизировано? |
|-------|-----------|-------------------|
| **Постоянно (само)** | Обновления безопасности (`unattended-upgrades` + ESM), ежедневный бэкап, алерт при его падении, мониторинг | ✅ Да |
| **Еженедельно (~5 мин)** | Глянуть алерты; `df -h` (диск); `sudo docker ps` или `systemctl --failed`; в healthchecks.io бэкап «зелёный» | Полуавтомат |
| **Ежемесячно (~15 мин)** | `sudo apt update && apt list --upgradable` (есть ли крупные апдейты вне security); `sudo fail2ban-client status sshd`; **тестовый restore одного файла из бэкапа** | Вручную |
| **Раз в полгода** | `scripts/diagnose.sh` — не «уехало» ли что-то; `sudo lynis audit system --quick`; проверить, не вышел ли новый Ubuntu LTS; обновить пароли/ротировать ключи при необходимости | Вручную |

**Главный принцип обслуживания:** реагируй на алерты, а не «заходи на всякий случай».
Если приходит алерт — есть проблема; если тихо — система здорова.

---

## 8. Pitfalls — чего НЕ делать

1. **Не закрывай SSH-сессию**, пока в новой не проверил вход по ключу + sudo.
2. **Не правь sshd и не включай UFW без гейта** — таймер отката взводится ДО применения.
3. **Не включай UFW** до `ufw allow 22/tcp` (или своего порта) — запрёшь себя.
4. **Не используй `ufw reset`** — сбросит SSH-правило.
5. **Не работай под root и не делай постоянный NOPASSWD-sudo** на проде «для удобства» — ни
   себе, ни агенту. Временный на время настройки — только по режиму B: отдельный файл, таймер,
   снятие до чеклиста.
6. **Не клади секреты в код/git** — только `.env` (и он в `.gitignore`).
7. **Не считай локальную копию бэкапом** — нужен offsite + проверка восстановления.
8. **Не теряй пароль шифрования restic** — без него бэкапы мертвы.
9. **Не оставляй debug-режим** (`DEBUG=True`, `NODE_ENV=development`) на сервере.
10. **Помни: Docker обходит UFW** — биндь чувствительные порты на `127.0.0.1`.
11. **Смена порта SSH под `ssh.socket`** — после правки `Port` нужен `daemon-reload` +
    `restart ssh.socket`, простой `restart ssh` порт не сменит (и не забудь UFW).
12. **Не оставляй дефолтного пользователя хостера с NOPASSWD-sudo** — запри его после проверки
    своего (раздел 1.2).
13. **Не восстанавливай бэкап в `/tmp`** — на 26.04 это оперативная память, восстанавливай в `/var/tmp`.
14. **Не считай бэкап настроенным, пока не проверил алерт о его падении** — иначе узнаешь о
    проблеме в день аварии.
15. **Не передавай агенту длинные команды в одну строку с кавычками** — только скриптом из
    файла (правила для агента, п. 1). Ломается тихо.

---

## 9. Финал уровня 2: аудит, контрольная перезагрузка, паспорт, чеклист

### 9.1 Аудит инструментами (объективная оценка вместо самопроверки)

```bash
sudo apt install ssh-audit lynis -y
ssh-audit -p <PORT> 127.0.0.1               # алгоритмы SSH: не должно быть строк (fail)
sudo lynis audit system --quick             # общий аудит; смотри Warnings и Suggestions
sudo grep -E '^(warning|suggestion)' /var/log/lynis-report.dat | head -30
```
Не гонись за «Hardening index 100»: lynis советует и то, что новичку не нужно. Разбирай только
`Warning`, из `Suggestion` — про SSH, обновления и права на файлы. Полезно и на «наследственном»
сервере как первый шаг: видно, что прошлый админ пропустил.

### 9.2 Контрольная перезагрузка (обязательно, один раз после настройки)

Забытый `enable` у сервиса или `restart: unless-stopped` у контейнера вылезает только здесь,
и лучше сейчас, чем при ночной автоперезагрузке.

```bash
sudo reboot
# подождать 30–60 с, войти новой сессией, затем:
sudo ufw status | head -1                  # Status: active
sudo fail2ban-client status sshd | head -1 # Status for the jail: sshd
swapon --show                              # swap на месте
systemctl list-timers 'backup*' 'apt-daily*'
sudo docker ps                             # все контейнеры Up
systemctl --failed                         # 0 loaded units listed
curl -sI https://<DOMAIN> | head -1        # HTTP/2 200
```

### 9.3 Паспорт сервера `/root/server-notes.md`

Через полгода никто не помнит, зачем открыт порт 8443 и где лежит пароль restic. Паспорт
читает и следующая сессия агента — вместо повторной диагностики. Обновляется **после каждого
раздела**, попадает в бэкап (раздел 5). Секретов в нём нет — только где они лежат.

```markdown
# <hostname> — паспорт сервера
Обновлено: <дата>. Хостер: <имя>, консоль: <ссылка на панель>.
ОС: Ubuntu <версия>. Пользователь: <USERNAME>. SSH-порт: <PORT>. Ключ: <server>_<device> (в менеджере паролей).
## Открытые порты и зачем
22/tcp SSH; 80,443/tcp nginx; <PORT> <зачем, для кого>
## Сервисы
<app> — docker compose в /home/<USERNAME>/app, порт 127.0.0.1:<APP_PORT>, за nginx.
## Бэкапы
restic → <хранилище>, ежедневно 03:00. Пароль repo и ключи хранилища — в менеджере паролей, запись «<имя>».
Последнее тестовое восстановление: <дата>.
## Алерты
Telegram-бот <имя> → чат <кто получает>. healthchecks.io check «<имя>».
## Решения и отклонения от скилла
<напр.: автоперезагрузка выключена, потому что …>
## История
<дата> — настроен по new-vps-setup, разделы 0–9.
```

### 9.4 Чеклист готовности к проду

- [ ] Система обновлена; `unattended-upgrades` включён и проверен (`--dry-run`); Ubuntu Pro подключён (`esm-apps enabled`).
- [ ] Работаем под отдельным sudo-пользователем (не root); sudo с паролем.
- [ ] Временный NOPASSWD режима B снят: файла `90-setup-temp` нет, таймер `sudo-temp-expire` не висит, `sudo -k && sudo -n true` отвечает `a password is required`.
- [ ] Дефолтный пользователь хостера заперт; `grep -r NOPASSWD /etc/sudoers.d/` пуст.
- [ ] Вход по SSH-ключу работает; `PasswordAuthentication no` (проверено через `sshd -T`).
- [ ] `PermitRootLogin no`; `AllowUsers` задан; cloud-init не перебивает hardening.
- [ ] Таймеры отката (`ssh-rollback`, `ufw-rollback`) остановлены, не висят.
- [ ] UFW включён: deny incoming, открыты только нужные порты; админки — за доверенными IP.
- [ ] fail2ban активен на sshd (`backend = systemd`); свой IP в `ignoreip`.
- [ ] Лимит журнала (`SystemMaxUse`) задан; на маленьком RAM есть swap; время синхронизировано.
- [ ] Все секреты в `.env`; `.env` в `.gitignore`; debug выключен (`NODE_ENV=production`).
- [ ] БД и внутренние сервисы не торчат в интернет (localhost / приватная сеть).
- [ ] Docker-логи ротируются; чувствительные порты на `127.0.0.1`; `restart: unless-stopped`.
- [ ] HTTPS работает; автопродление сертификата проверено (`certbot renew --dry-run`).
- [ ] Автобэкап (restic) ежедневно + offsite; пароль шифрования сохранён ВНЕ сервера.
- [ ] **Тестовое восстановление из бэкапа выполнено успешно.**
- [ ] **Алерт о падении бэкапа проверен** (`systemctl start backup-failed.service` → сообщение пришло); healthchecks.io ждёт ежедневный пинг.
- [ ] Внешний uptime-мониторинг и `healthcheck.sh` настроены; `tg-alert "test"` доходит.
- [ ] `ssh-audit` без fail; `lynis` без Warning.
- [ ] **Контрольная перезагрузка пройдена** — всё поднялось само.
- [ ] Паспорт сервера `/root/server-notes.md` заполнен и попадает в бэкап.

---

## 10. Runbook «Я заперся» — доступ по SSH потерян

Не паникуй и **не пересоздавай сервер**. Сначала определи симптом, потом действуй.

| Симптом | Причина | Что делать |
|---------|---------|------------|
| `Permission denied (publickey)` | Ключ не подходит, `AllowUsers` без тебя, или вошёл не тем пользователем | Проверь `ssh -v … 2>&1 \| grep -i 'offering\|denied'` — какой ключ предлагается. Если ключ верный — через консоль провайдера (ниже) |
| `Connection refused` | sshd не слушает: ошибка в конфиге или сменил порт | Попробуй старый и новый порт: `ssh -p <PORT>`. Иначе консоль |
| `Connection timed out` | UFW закрыл порт, или сервер лежит | `ping <SERVER_IP>`; панель хостера — сервер включён? Затем консоль |
| Входит, но `sudo` не работает | Удалил NOPASSWD у пользователя без пароля, или пользователь не в `sudo` | Консоль под root → `passwd <USERNAME>`; `usermod -aG sudo <USERNAME>` |
| `sudo: parse error in /etc/sudoers.d/…` | Файл в `sudoers.d` с ошибкой синтаксиса (положили без `visudo -cf`) — sudo отказывает всем | Консоль под root → `visudo -cf /etc/sudoers.d/<файл>`, удалить или исправить файл |
| Всё работало, отвалилось через 5 минут | Сработал таймер отката — и это хорошо: он вернул рабочий конфиг | Разбери, почему новая сессия не открылась, и повтори шаг с гейтом |

**Через консоль провайдера (VNC / Serial / Rescue):**
```bash
# 1. Войти root'ом или своим пользователем (пароль — из менеджера паролей)

# 2. Снять таймеры отката, если висят
systemctl stop ssh-rollback.timer ufw-rollback.timer 2>/dev/null

# 3. Что видит sshd на самом деле (при блоках Match добавь -C user=root,host=localhost,addr=127.0.0.1)
sshd -T | grep -iE 'port|permitroot|passwordauth|allowusers'
journalctl -u ssh -n 30 --no-pager          # ошибки конфига будут здесь

# 4. Вернуть SSH: убрать свой drop-in (или бэкап из гейта) и перезапустить
mv /etc/ssh/sshd_config.d/99-hardening.conf /root/99-hardening.conf.broken
sshd -t && systemctl daemon-reload && systemctl restart ssh.socket ssh.service

# 5. Если дело в UFW — временно разрешить SSH (не reset!)
ufw allow 22/tcp && ufw status
# крайний случай: ufw disable — и обратно enable сразу после починки

# 6. Если временно нужен вход по паролю — включить, войти, починить ключ, ВЫКЛЮЧИТЬ обратно
printf 'PasswordAuthentication yes\n' > /etc/ssh/sshd_config.d/00-temp.conf
systemctl restart ssh.socket ssh.service
# ... починил authorized_keys / AllowUsers ...
rm /etc/ssh/sshd_config.d/00-temp.conf && systemctl restart ssh.socket ssh.service
```

> **Права на ключи**, если `Permission denied` при верном ключе: `chmod 700 ~/.ssh`,
> `chmod 600 ~/.ssh/authorized_keys`, владелец — сам пользователь. sshd молча отвергает ключи,
> если каталог доступен на запись другим.

После восстановления доступа — запись в паспорт сервера (что случилось, что помогло), и
повторить шаг с полным гейтом.
