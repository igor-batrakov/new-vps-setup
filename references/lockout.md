# Runbook «Я заперся» — доступ по SSH потерян

Справочник к SKILL.md, раздел 10. Читать, когда доступ уже потерян; гейт в SKILL.md
существует, чтобы сюда не попадать.


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
mv /etc/ssh/sshd_config.d/00-hardening.conf /root/00-hardening.conf.broken
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
