#!/usr/bin/env python3
"""Генерирует assets/demo.gif для new-vps-setup: схематичный прогон скилла в терминале.
Не запись реальной сессии. Pillow + Menlo. Строки появляются прогрессивно."""
from PIL import Image, ImageDraw, ImageFont
import os, sys

OUT = sys.argv[1] if len(sys.argv) > 1 else "assets/demo.gif"
FRAMES_DIR = sys.argv[2] if len(sys.argv) > 2 else None

W = 1040
FONT = ImageFont.truetype("/System/Library/Fonts/Menlo.ttc", 19)
FONT_B = ImageFont.truetype("/System/Library/Fonts/Menlo.ttc", 19, index=1)  # bold
LH = 29          # высота строки
PAD_X, PAD_TOP = 34, 74
BAR_H = 46

C = dict(
    bg="#0f1117", bar="#181b24", text="#d5d9e2", muted="#6b7280",
    green="#4ade80", red="#f87171", yellow="#fbbf24", blue="#60a5fa",
    cyan="#22d3ee", purple="#c084fc", white="#ffffff",
)

# Каждая строка — список сегментов (текст, цвет[, bold]). None = пустая строка.
# Группы: строки одной группы появляются одним кадром.
def seg(*parts):
    return [(p if isinstance(p, tuple) else (p, "text")) for p in parts]

SCRIPT = [
    # (строки группы, задержка кадра мс)
    ([seg(("$ ", "muted"), ("claude", "text"))], 500),
    ([seg(("> ", "muted"), ("Проверь мой сервер и доведи до прода", "blue"))], 900),
    ([None, seg(("● ", "text"), ("Using skill: ", "text"), ("new-vps-setup", "purple"))], 900),
    ([None, seg(("▶ 0 · Диагностика", "cyan", 1), ("   sudo bash /tmp/diagnose.sh   ", "muted"), ("read-only", "muted"))], 700),
    ([seg(("  [OK] ", "green"), ("Ubuntu 26.04.1 LTS · 2 vCPU · 4 ГБ · перезагрузка не требуется", "text"))], 450),
    ([seg(("  [!!] ", "red"), ("PasswordAuthentication yes · AllowUsers не задан", "text"), ("→ 1.4", "yellow"))], 450),
    ([seg(("  [!!] ", "red"), ("UFW не активен", "text"), ("→ 2", "yellow"))], 450),
    ([seg(("  [!!] ", "red"), ("бэкапов не видно · нет канала алертов", "text"), ("→ 5, 6", "yellow"))], 450),
    ([seg(("  Сначала — уровень 1: ", "muted"), ("1.4, 2", "yellow"), ("        Потом — уровень 2: ", "muted"), ("5, 6", "yellow"))], 1200),
    ([None, seg(("▶ Гейт от «я заперся»", "cyan", 1), ("   перед правкой sshd", "muted"))], 700),
    ([seg(("  ✓ ", "green"), ("консоль провайдера открыта", "text"), ("     ✓ ", "green"), ("вторая SSH-сессия жива", "text"))], 450),
    ([seg(("  ✓ ", "green"), ("вход по ключу: uid=1000", "text"), ("        ✓ ", "green"), ("бэкап /etc/ssh", "text"))], 450),
    ([seg(("  ✓ ", "green"), ("таймер отката взведён (5 мин)", "text"), (" — ДО копирования файла", "yellow"))], 1100),
    ([None, seg(("▶ 1 · Hardening", "cyan", 1))], 600),
    ([seg(("  ✓ ", "green"), ("99-hardening.conf → sshd -t ОК → ", "text"), ("новая сессия входит", "green"))], 450),
    ([seg(("  ✓ ", "green"), ("таймер отката снят · sshd -T: passwordauthentication ", "text"), ("no", "green"))], 450),
    ([seg(("  ✓ ", "green"), ("unattended-upgrades + Ubuntu Pro (ESM) · fail2ban (backend systemd)", "text"))], 450),
    ([seg(("▶ 2 · UFW", "cyan", 1), ("   ✓ ", "green"), ("deny incoming · 22, 80, 443 · таймер отката снят", "text"))], 800),
    ([seg(("  Уровень 1 пройден", "green", 1), (" — сервер можно оставить включённым", "text"))], 1300),
    ([None, seg(("▶ 5 · Бэкапы", "cyan", 1), ("   restic → B2 offsite · 03:00 · retention 7/4/6", "muted"))], 600),
    ([seg(("  ✓ ", "green"), ("учебное восстановление: /etc/hostname совпадает", "text"))], 450),
    ([seg(("  ✓ ", "green"), ("backup-failed.service → Telegram «BACKUP FAILED» пришёл", "text"))], 450),
    ([seg(("  ✓ ", "green"), ("healthchecks.io ждёт ежедневный пинг", "text"))], 450),
    ([seg(("▶ 6 · Мониторинг", "cyan", 1), ("   ✓ ", "green"), ("tg-alert test → телефон   ", "text"), ("✓ ", "green"), ("healthcheck.sh в cron", "text"))], 600),
    ([seg(("▶ 9 · Финал", "cyan", 1), ("   ✓ ", "green"), ("lynis   ", "text"), ("✓ ", "green"), ("контрольная перезагрузка   ", "text"), ("✓ ", "green"), ("паспорт сервера", "text"))], 900),
    ([None, seg(("✓ Уровень 2 пройден — это прод.", "green", 1), (" Дальше сервер обслуживает себя сам.", "text"))], 4000),
]

all_lines = [l for group, _ in SCRIPT for l in group]
H = PAD_TOP + LH * len(all_lines) + 40

def draw_frame(lines, cursor=True):
    im = Image.new("RGB", (W, H), C["bg"])
    d = ImageDraw.Draw(im)
    d.rectangle([0, 0, W, BAR_H], fill=C["bar"])
    for i, col in enumerate(("#ff5f57", "#febc2e", "#28c840")):
        d.ellipse([22 + i * 22, 16, 36 + i * 22, 30], fill=col)
    title = "new-vps-setup · демо"
    tw = d.textlength(title, font=FONT)
    d.text(((W - tw) / 2, 13), title, font=FONT, fill=C["muted"])
    y = PAD_TOP
    for ln in lines:
        if ln is not None:
            x = PAD_X
            for part in ln:
                text, color = part[0], part[1]
                bold = len(part) > 2 and part[2]
                f = FONT_B if bold else FONT
                if text.startswith("→ "):      # ссылка на раздел — фиксированная колонка
                    x = 760
                d.text((x, y), text, font=f, fill=C[color])
                x += d.textlength(text, font=f)
        y += LH
    if cursor:
        d.rectangle([PAD_X, y + 4, PAD_X + 11, y + LH - 6], fill=C["muted"])
    return im

frames, durations = [], []
shown = []
for group, delay in SCRIPT:
    shown = shown + group
    frames.append(draw_frame(shown, cursor=(group is not SCRIPT[-1][0])))
    durations.append(delay)
# мигание курсора на паузе после диагностики и финальный кадр без курсора
frames[-1] = draw_frame(shown, cursor=False)

# квантование в общую палитру, чтобы кадры не мерцали
pal = frames[-1].convert("P", palette=Image.ADAPTIVE, colors=64)
q = [f.quantize(palette=pal, dither=Image.NONE) for f in frames]
os.makedirs(os.path.dirname(OUT) or ".", exist_ok=True)
q[0].save(OUT, save_all=True, append_images=q[1:], duration=durations, loop=0, optimize=True, disposal=1)
print(f"{OUT}: {W}x{H}, {len(q)} кадров, {os.path.getsize(OUT)/1024:.0f} КБ, {sum(durations)/1000:.1f} с")

if FRAMES_DIR:
    os.makedirs(FRAMES_DIR, exist_ok=True)
    for i in (4, 12, len(frames) - 1):
        frames[i].save(f"{FRAMES_DIR}/frame_{i:02d}.png")
    print("превью:", FRAMES_DIR)
