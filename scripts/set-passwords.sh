#!/bin/bash
# set-passwords.sh <root@SERVER_IP | ssh-alias с User root> <USERNAME>
#
# Запускается на ЛОКАЛЬНОЙ машине пользователем (в любом терминале), не агентом.
# 1. Если ~/.vps/<host>.env ещё нет — генерирует новые пароли root и <USERNAME> (права 600).
# 2. Ставит их на сервере через `chpasswd`, читающий пары user:password со stdin:
#    пароль не попадает ни в аргументы команды, ни в историю, ни в файл на сервере.
# 3. Печатает только статус — ни одного значения. Вывод безопасно показывать агенту.
# После: сохрани оба пароля из файла в менеджер паролей и удали файл.
set -euo pipefail

HOST="${1:?использование: set-passwords.sh root@SERVER_IP USERNAME}"
USER_="${2:?использование: set-passwords.sh root@SERVER_IP USERNAME}"
DIR="$HOME/.vps"
ENV_FILE="$DIR/${HOST#*@}.env"

mkdir -p "$DIR" && chmod 700 "$DIR"
if [ ! -f "$ENV_FILE" ]; then
  umask 077
  printf 'ROOT_PASSWORD=%s\nUSER_PASSWORD=%s\n' "$(openssl rand -base64 18)" "$(openssl rand -base64 18)" > "$ENV_FILE"
  echo "создан $ENV_FILE — сохрани оба пароля в менеджер паролей, потом удали файл"
fi

ROOT_PW=$(grep '^ROOT_PASSWORD=' "$ENV_FILE" | cut -d= -f2-)
USER_PW=$(grep '^USER_PASSWORD=' "$ENV_FILE" | cut -d= -f2-)
if [ -z "$ROOT_PW" ] || [ -z "$USER_PW" ]; then
  echo "в $ENV_FILE нет ROOT_PASSWORD или USER_PASSWORD"; exit 1
fi

# По ключу, без терминала: если ключа root ещё нет — сначала ssh-copy-id root@SERVER_IP
if ! ssh -o BatchMode=yes -o ConnectTimeout=10 "$HOST" true 2>/dev/null; then
  echo "нет входа по ключу на $HOST — сначала: ssh-copy-id $HOST"; exit 1
fi
if ! ssh -o BatchMode=yes "$HOST" "id -u $USER_" >/dev/null 2>&1; then
  echo "на сервере нет пользователя $USER_ — сначала раздел 1.2 (adduser)"; exit 1
fi

printf 'root:%s\n%s:%s\n' "$ROOT_PW" "$USER_" "$USER_PW" | ssh -o BatchMode=yes "$HOST" chpasswd

# Проверка без раскрытия: P = пароль задан, L = заблокирован, NP = нет пароля
ssh -o BatchMode=yes "$HOST" "passwd -S root; passwd -S $USER_" \
  | awk '{printf "  %s: %s\n", $1, ($2=="P" ? "пароль задан" : "НЕТ пароля (" $2 ")")}'
echo "готово: пароли установлены, в вывод не попали"
