#!/bin/bash
# restic-env.sh — создать /root/.config/restic/env с паролем репозитория, сгенерированным НА СЕРВЕРЕ.
# Запускает пользователь в отдельном окне терминала (агент пароль не видит):
#   scp scripts/restic-env.sh <alias>:/tmp/ && ssh -t <alias> sudo bash /tmp/restic-env.sh
# Пароль показывается ОДИН раз, здесь. Без него бэкапы нечитаемы навсегда — сохрани в менеджер
# паролей до того, как нажмёшь «да». Ключи хранилища вводятся скрыто.
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "нужен root: sudo bash $0"; exit 1; }
ENV_FILE=/root/.config/restic/env
if [ -f "$ENV_FILE" ]; then
  echo "$ENV_FILE уже есть — не перезаписываю: пароль существующего репозитория терять нельзя"; exit 1
fi

echo "Куда бэкапить (RESTIC_REPOSITORY). Примеры:"
echo "  b2:<bucket>:prod-backup            Backblaze B2 (нужны Key ID и Application Key)"
echo "  sftp:user@host:/path               rsync.net или свой сервер по SSH"
echo "  s3:https://<endpoint>/<bucket>     любой S3 (ключи — как AWS_ACCESS_KEY_ID/SECRET)"
echo "  /var/backups/restic-test           локально: только для учебного прогона, это НЕ бэкап"
read -rp "RESTIC_REPOSITORY: " REPO
[ -n "$REPO" ] || { echo "пусто"; exit 1; }

KID=""; KSEC=""
case "$REPO" in
  b2:*|s3:*)
    read -rsp "Ключ доступа к хранилищу — ID (ввод скрыт): " KID; echo
    read -rsp "Ключ доступа к хранилищу — секрет (ввод скрыт): " KSEC; echo
    [ -n "$KID" ] && [ -n "$KSEC" ] || { echo "для b2:/s3: нужны оба ключа"; exit 1; } ;;
esac
read -rp "healthchecks.io ping-URL (Enter — пропустить dead-man's switch): " HC

PW=$(openssl rand -base64 24)
install -d -m 700 /root/.config/restic
umask 077
{
  printf 'export RESTIC_REPOSITORY=%q\n' "$REPO"
  printf 'export RESTIC_PASSWORD=%q\n' "$PW"
  case "$REPO" in
    b2:*) printf 'export B2_ACCOUNT_ID=%q\nexport B2_ACCOUNT_KEY=%q\n' "$KID" "$KSEC" ;;
    s3:*) printf 'export AWS_ACCESS_KEY_ID=%q\nexport AWS_SECRET_ACCESS_KEY=%q\n' "$KID" "$KSEC" ;;
  esac
  printf 'export HC_PING_URL=%q\n' "$HC"
} > "$ENV_FILE"
chmod 600 "$ENV_FILE"

echo
echo "================================================================================"
echo "ПАРОЛЬ РЕПОЗИТОРИЯ restic — показан ОДИН раз. Сохрани в менеджер паролей СЕЙЧАС:"
echo
echo "    $PW"
echo
echo "Это третий секрет сервера (первые два — пароли root и sudo). Без него все бэкапы"
echo "нечитаемы навсегда. На сервере он лежит только в $ENV_FILE (600)."
echo "================================================================================"
read -rp "Сохранил в менеджер паролей? (напиши: да) " OK
if [ "$OK" != "да" ]; then
  rm -f "$ENV_FILE"
  echo "не подтверждено — файл удалён, запусти скрипт заново"; exit 1
fi
echo "готово: $ENV_FILE записан. Дальше — restic init (backups.md, раздел 4)"
