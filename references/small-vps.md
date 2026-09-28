# Лишнее на маленьком VPS

Для виртуалки с диском ≤ 20 ГБ. Образ хостера обычно собран «на всё железо»: метапакет
ядра `linux-generic` тянет прошивки, `ubuntu-server` — диагностику ядра, kdump и демоны
для модемов, дисков и батарей. На виртуалке всё это не работает, а место и память занимает.
На образе VDSina с Ubuntu 26.04 и 10-ГБ диском чистка освободила ~1.5 ГБ: занятость упала
с 76% до 48% (вместе с уменьшением swap из 1.7).

**Агент предлагает, пользователь решает.** Перед каждым `purge` агент прогоняет его через
`apt-get -s`, показывает список на удаление и сверяет с гейтами ниже. Реальную команду —
только после этого.

## 0. Условия и замер

```bash
systemd-detect-virt      # kvm, qemu, vmware… Если none — это железо, прошивки ему нужны: стоп
df -h /
dpkg-query -Wf '${Installed-Size}\t${Package}\n' | sort -n | tail -25   # крупнейшие пакеты, КБ
snap list 2>/dev/null    # есть snap-пакеты — snapd не трогать
dkms status 2>/dev/null  # есть DKMS-модули (AmneziaWG и т.п.) — см. ловушку 2
```

## 1. Прошивки: сменить метапакет ядра, а не удалять прошивки

`linux-image-generic` зависит от `linux-firmware*` (~750 МБ). Удалить прошивки напрямую
значит снести `linux-generic` и `linux-image-generic` без замены: текущее ядро останется, но
новые перестанут ставиться, и сервер тихо застрянет на старом ядре без исправлений.

Правильно — сначала поставить `linux-virtual`: он тянет то же ядро (`linux-image-virtual`
зависит от того же `linux-image-<версия>-generic`), но без прошивок и микрокода.

```bash
sudo apt install linux-virtual -y
sudo apt-get -s purge linux-generic linux-image-generic 'linux-firmware*' firmware-sof-signed | grep -E '^(Purg|Remv)'
```

**Гейт по списку `-s`:** в нём НЕ должно быть `linux-virtual`, `linux-image-virtual`,
`linux-headers-virtual`, `linux-headers-generic` и `linux-image-$(uname -r)`. Есть хоть
один — не запускать, разбираться.

```bash
sudo apt-get purge -y linux-generic linux-image-generic 'linux-firmware*' firmware-sof-signed
dpkg -l linux-virtual linux-image-virtual linux-headers-virtual | grep '^ii'   # три строки
```

**Ловушка 1.** `linux-headers-generic` в список не добавлять: `linux-headers-virtual` зависит
от него, и apt снесёт `linux-virtual` целиком — вернулись к застрявшему ядру.

**Ловушка 2.** Если на сервере есть DKMS-модуль (`dkms status` не пуст), `gcc`, `make`, `dkms`
и заголовки ядра обязательны. Без них после ночного обновления ядра модуль не соберётся, и
сервис на нём (VPN) не поднимется после перезагрузки.

## 2. Диагностика ядра, kdump, десктопные демоны

| Пакеты | Откуда | Почему лишнее |
|---|---|---|
| `bpftrace bpfcc-tools python3-bpfcc linux-perf` (+ LLVM через autoremove, ~450 МБ) | Recommends `ubuntu-kernel-accessories` | инструменты трассировки ядра, новичку не нужны |
| `python3-boto3` | Recommends `sos` | загрузка отчётов sos в S3 |
| `kdump-tools` | образ хостера | при RAM < 2 ГБ `crashkernel=2G-4G:…` ничего не резервирует, `cat /sys/kernel/kexec_crash_size` = 0: kdump мёртвый |
| `modemmanager fwupd udisks2 upower` | образ хостера (`fwupd` — Recommends `ubuntu-server`) | модемы, прошивки железа, диски, батареи — на виртуалке их нет, а демоны едят RAM |
| `snapd` | Recommends `ubuntu-server` | только если `snap list` пуст |

`ubuntu-server`, `sos` и `ubuntu-kernel-accessories` при этом остаются: эти пакеты у них в
Recommends, не в Depends. Гейт по списку `-s` это подтверждает.

```bash
sudo apt-get -s purge bpftrace bpfcc-tools python3-bpfcc linux-perf python3-boto3 kdump-tools \
  modemmanager fwupd udisks2 upower | grep -E '^(Purg|Remv)'
# гейт: в списке нет ubuntu-server, sos, linux-virtual, linux-image-*, openssh-server
sudo apt-get purge -y bpftrace bpfcc-tools python3-bpfcc linux-perf python3-boto3 kdump-tools \
  modemmanager fwupd udisks2 upower
sudo apt-get purge -y snapd          # если snap list пуст
```

## 3. autoremove и запасное ядро

```bash
sudo apt-get -s autoremove --purge | grep -E '^(Purg|Remv)'
# гейт: в списке нет linux-image-$(uname -r) и заголовков текущего ядра
sudo apt-get autoremove --purge -y
df -h /                              # записать в паспорт
```

apt держит **два ядра**: текущее и предыдущее, на случай если новое не загрузится. Старое ядро
вручную не удалять, даже если оно выглядит «старым пакетом» в списке `dpkg -l`. Если уже
удалил и возвращаешь (`apt install linux-image-<версия>-generic linux-modules-<версия>-generic`),
учти: установка ядра создаёт `/var/run/reboot-required`, и ночная автоперезагрузка из 1.5
перезагрузит сервер. Загрузится он в новейшее ядро, так что это безвредно, но лучше
перезагрузить самому в удобное время и пройти проверку из 9.2.

## 4. Проверка

```bash
dpkg -l linux-virtual | grep '^ii'                  # метапакет ядра на месте
apt-get -s dist-upgrade | grep -E '^(Inst|Remv)'    # ничего неожиданного в очереди
dkms status                                         # если был DKMS: модуль installed для uname -r
```
После ближайшего обновления ядра — `dkms status` снова: модуль должен собраться и под новое.
Контрольная перезагрузка из 9.2 проверяет, что всё поднялось.

Запиши в паспорт, что снято и сколько места освободилось: следующий админ не будет искать
пропавший `snapd` или kdump.
