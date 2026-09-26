#!/bin/bash
# set-passwords.sh <root@SERVER_IP | ssh-alias> <USERNAME> [--user-only]
#
# Запускается на ЛОКАЛЬНОЙ машине пользователем (в любом терминале), не агентом.
# 1. Если ~/.vps/<host>.env ещё нет — генерирует новые пароли root и <USERNAME> (права 600).
# 2. Ставит их на сервере через `chpasswd`, читающий пары user:password со stdin:
#    пароль не попадает ни в аргументы команды, ни в историю, ни в файл на сервере.
# 3. Печатает только статус — ни одного значения. Вывод безопасно показывать агенту.
# --user-only  — не трогать пароль root (сервер уже настроен, root заперт или пароль есть).
# Подключение root'ом — напрямую; обычным пользователем — через sudo -n (режим B или NOPASSWD).
# После: сохрани пароли из файла в менеджер паролей и удали файл.
set -euo pipefail

HOST="${1:?использование: set-passwords.sh root@SERVER_IP USERNAME [--user-only]}"
USER_="${2:?использование: set-passwords.sh root@SERVER_IP USERNAME [--user-only]}"
USER_ONLY=0; [ "${3:-}" = "--user-only" ] && USER_ONLY=1
DIR="$HOME/.vps"
ENV_FILE="$DIR/${HOST#*@}.env"
SSH="ssh -o BatchMode=yes -o ConnectTimeout=10 $HOST"

mkdir -p "$DIR" && chmod 700 "$DIR"
if [ ! -f "$ENV_FILE" ]; then
  umask 077
  printf 'ROOT_PASSWORD=%s\nUSER_PASSWORD=%s\n' "$(openssl rand -base64 18)" "$(openssl rand -base64 18)" > "$ENV_FILE"
  echo "создан $ENV_FILE — сохрани пароли в менеджер паролей, потом удали файл"
fi

ROOT_PW=$(grep '^ROOT_PASSWORD=' "$ENV_FILE" | cut -d= -f2-)
USER_PW=$(grep '^USER_PASSWORD=' "$ENV_FILE" | cut -d= -f2-)
if [ -z "$USER_PW" ] || { [ "$USER_ONLY" = 0 ] && [ -z "$ROOT_PW" ]; }; then
  echo "в $ENV_FILE нет ROOT_PASSWORD или USER_PASSWORD"; exit 1
fi

# По ключу, без терминала: если ключа ещё нет — сначала ssh-copy-id
if ! $SSH true 2>/dev/null; then
  echo "нет входа по ключу на $HOST — сначала: ssh-copy-id $HOST"; exit 1
fi
# root напрямую, иначе через sudo без пароля (режим B / NOPASSWD)
if [ "$($SSH id -un)" = root ]; then
  SUDO=""
elif $SSH sudo -n true 2>/dev/null; then
  SUDO="sudo -n"
else
  echo "на $HOST не root и sudo просит пароль — включи режим B или подключайся root'ом"; exit 1
fi
if ! $SSH "id -u $USER_" >/dev/null 2>&1; then
  echo "на сервере нет пользователя $USER_ — сначала раздел 1.2 (adduser)"; exit 1
fi

if [ "$USER_ONLY" = 1 ]; then
  printf '%s:%s\n' "$USER_" "$USER_PW" | $SSH "$SUDO chpasswd"
  WHO="$USER_"
else
  printf 'root:%s\n%s:%s\n' "$ROOT_PW" "$USER_" "$USER_PW" | $SSH "$SUDO chpasswd"
  WHO="root $USER_"
fi

# Проверка без раскрытия: P = пароль задан, L = заблокирован, NP = нет пароля
for u in $WHO; do
  $SSH "$SUDO passwd -S $u"
done | awk '{printf "  %s: %s\n", $1, ($2=="P" ? "пароль задан" : "НЕТ пароля (" $2 ")")}'
echo "готово: пароли установлены, в вывод не попали"
