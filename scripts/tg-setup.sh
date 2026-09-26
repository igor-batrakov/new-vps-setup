#!/bin/bash
# tg-setup.sh — подключить Telegram-алерты. Выполняется НА СЕРВЕРЕ под root,
# запускает пользователь в отдельном окне терминала (токен вводится скрыто, агент его не видит):
#   scp scripts/tg-setup.sh <alias>:/tmp/ && ssh -t <alias> sudo bash /tmp/tg-setup.sh
# Результат: /root/.config/tg-alert/env (600) с TG_TOKEN, TG_CHAT, TG_NAME. Его читает tg-alert.
# До запуска: создай бота у @BotFather (получишь токен) и напиши боту любое сообщение —
# по нему скрипт сам определит chat_id. Если на сервере уже есть tg-alert старого формата —
# сначала замени его на новый (SKILL.md, раздел 5), иначе тестовое сообщение уйдёт в старом виде.
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "нужен root: sudo bash $0"; exit 1; }
ENV_FILE=/root/.config/tg-alert/env

read -rsp "Токен бота от @BotFather (ввод скрыт, символы не видны): " TOKEN; echo
[ -n "$TOKEN" ] || { echo "пустой токен"; exit 1; }
API="https://api.telegram.org/bot${TOKEN}"

ME=$(curl -fsS -m 10 "$API/getMe" 2>/dev/null | sed -n 's/.*"username":"\([^"]*\)".*/\1/p' || true)
[ -n "$ME" ] || { echo "Telegram не принял токен (getMe). Проверь его у @BotFather и запусти снова"; exit 1; }
echo "бот найден: @$ME"

read -rp "chat_id (Enter — определить автоматически по твоему сообщению боту): " CHAT
if [ -z "$CHAT" ]; then
  UPD=$(curl -fsS -m 10 "$API/getUpdates" 2>/dev/null || true)
  if printf '%s' "$UPD" | grep -q '"error_code":409'; then
    echo "у бота включён webhook, getUpdates недоступен. Узнай свой chat_id у @userinfobot и введи руками"; exit 1
  fi
  CHAT=$(printf '%s' "$UPD" | grep -o '"chat":{"id":-\?[0-9]*' | tail -1 | grep -o -- '-\?[0-9]*$' || true)
  [ -n "$CHAT" ] || { echo "сообщений боту нет. Напиши ему «привет» в Telegram и запусти скрипт снова"; exit 1; }
  echo "chat_id определён: $CHAT"
fi

echo "Имя сервера в алертах: короткое и понятное тебе, например ssh-alias. У хостеров hostname часто"
echo "это номер заказа вроде v1036565 — такое имя в 3 часа ночи ничего не скажет."
read -rp "Имя сервера для алертов [$(hostname -s)]: " NAME
NAME=${NAME:-$(hostname -s)}
NAME=${NAME//\'/}

install -d -m 700 /root/.config/tg-alert
umask 077
printf "TG_TOKEN='%s'\nTG_CHAT='%s'\nTG_NAME='%s'\n" "$TOKEN" "$CHAT" "$NAME" > "$ENV_FILE"
chmod 600 "$ENV_FILE"
echo "записан $ENV_FILE"

if [ -x /usr/local/bin/tg-alert ]; then
  /usr/local/bin/tg-alert "✅ Алерты подключены" "Сервер «$NAME» будет писать сюда о диске, памяти, перезагрузке, упавших сервисах и бэкапе."
  echo "тестовое сообщение отправлено — проверь Telegram"
else
  echo "теперь положи /usr/local/bin/tg-alert (SKILL.md, раздел 5) и проверь: sudo tg-alert '✅ Тест'"
fi
