<p align="center">
  <b>RU</b> Русский | <b>EN</b> <a href="MULTIHOP.en.md">English</a>
</p>

# Multi-hop (каскад) из двух AmneziaWG-серверов

Простое руководство: как поднять цепочку из двух VPS, чтобы клиентский трафик заходил на одну ноду, а в интернет выходил через другую.

---

## Кто есть кто

У тебя два сервера:

- **Нода 1 (exit)** — та, через которую ты хочешь выходить в интернет (обычно заграничная). IP для примера: `198.51.100.20`.
- **Нода 2 (entry)** — к ней подключаются твои телефон/ноут. IP для примера: `203.0.113.10`.

Как пойдёт трафик: **телефон → Нода 2 → Нода 1 → интернет**.

---

## Один важный момент перед стартом

Обе ноды по умолчанию берут одну и ту же подсеть `10.9.9.0/24`. Работать будет, но отладка — боль. Задай разные через `--subnet=`:

- Нода 1 (exit)  → `10.9.0.1/24`
- Нода 2 (entry) → `10.8.0.1/24`

---

## Предварительно — клонирование форка на обе ноды

**Важно:** клонируй форк в путь **НЕ равный** `/root/awg` (это рабочая директория установщика). Стандартный вариант:

```bash
git clone --branch feat/v3 --single-branch https://github.com/SNPR/amneziawg-installer.git /root/amneziawg-installer
cd /root/amneziawg-installer
```

Установщик в шаге 5 обнаружит лежащие рядом `awg_common.sh` и `manage_amneziawg.sh`, скопирует их через staging и сверит оба с вшитыми SHA-256 — **без скачивания из апстрим-CDN**. На ноду попадёт согласованная пара с доработками `--role=entry` / `--egress=warp`.

## Нода 1 (exit) — «выходной» сервер

На exit-ноде можно использовать **оригинальный скрипт автора** ([bivlked/amneziawg-installer](https://github.com/bivlked/amneziawg-installer)) без наших модификаций — там нужен обычный AmneziaWG 2.0 сервер, ничего специфичного для каскада. Если предпочитаешь однородность — запускай наш форк с `--role=exit`, разницы в результирующем конфиге не будет (флаг `--role=exit` только маркирует ноду в `awgsetup_cfg.init` для документации).

**Шаг A.** Установка (одна команда из директории клона):

```bash
sudo bash install_amneziawg.sh \
  --role=exit \
  --subnet=10.9.0.1/24 \
  --yes
```

Если попросит перезагрузку (обычно 1–2 раза) — соглашайся, после ребута запусти **ту же команду** ещё раз, скрипт продолжит с того места, где остановился.

**Шаг B.** Создай «клиентский» конфиг, через который нода 2 будет цепляться к ноде 1:

```bash
sudo bash /root/awg/manage_amneziawg.sh add hop_to_entry
```

Появится файл `/root/awg/hop_to_entry.conf`.

**Шаг C.** Скопируй этот файл на ноду 2:

```bash
scp /root/awg/hop_to_entry.conf root@203.0.113.10:/root/
```

**Всё. На ноде 1 больше ничего делать не надо.**

---

## Нода 2 (entry) — сервер для клиентов

На entry-ноде **нужен именно наш скрипт** (этот форк) — только в нём есть флаги `--role=entry` и `--upstream-conf=`, которые поднимают второй интерфейс `awg1` и настраивают policy-routing.

Убедись, что `/root/hop_to_entry.conf` лежит на ноде 2 (от `scp` выше). Потом одна команда:

```bash
sudo bash install_amneziawg.sh \
  --role=entry \
  --upstream-conf=/root/hop_to_entry.conf \
  --subnet=10.8.0.1/24 \
  --yes
```

Та же история с ребутами: если просит — соглашайся и запусти эту же команду снова.

В конце скрипт сам:

- подымет `awg0` — сервер для твоих клиентов
- подымет `awg1` — скрытый туннель до ноды 1
- пропишет policy-routing, MASQUERADE и TCPMSS clamp (чтобы не рвались HTTPS-сайты)

---

## Как забрать клиентов

На ноде 2 лежат готовые конфиги:

- `/root/awg/my_phone.conf` + `my_phone.png` (QR)
- `/root/awg/my_laptop.conf` + `my_laptop.png`

Скачай их и импортируй в клиент Amnezia VPN ≥ 4.8.12.7. **Endpoint в этих конфигах — IP ноды 2** (не ноды 1), так и должно быть.

Добавить ещё клиента:

```bash
sudo bash /root/awg/manage_amneziawg.sh add vasya
```

---

## Как проверить что каскад работает

На ноде 2:

```bash
sudo bash /root/awg/manage_amneziawg.sh upstream show
# Должен показать handshake с нодой 1 (recent, секунды/минуты)

awg show
# Две секции: awg0 (твои клиенты) и awg1 (нода 1 как пир)
```

Подключись клиентом и на устройстве:

```bash
curl ifconfig.me
```

Если вернул **IP ноды 1** (`198.51.100.20` в примере), а не ноды 2 — каскад живой, всё работает.

---

## Повседневные команды на ноде 2

```bash
sudo bash /root/awg/manage_amneziawg.sh add <имя>        # добавить клиента
sudo bash /root/awg/manage_amneziawg.sh remove <имя>     # удалить
sudo bash /root/awg/manage_amneziawg.sh list             # список
sudo bash /root/awg/manage_amneziawg.sh restart          # перезапуск обоих туннелей
sudo bash /root/awg/manage_amneziawg.sh upstream up       # поднять только upstream
sudo bash /root/awg/manage_amneziawg.sh upstream down --yes  # fail-closed: сначала снять awg0
sudo bash /root/awg/manage_amneziawg.sh upstream restart # только каскад
sudo bash /root/awg/manage_amneziawg.sh upstream apply --yes # применить awg1.conf
sudo bash /root/awg/manage_amneziawg.sh upstream show    # статус каскада
sudo bash /root/awg/manage_amneziawg.sh upstream show --json # один JSON для бота
```

`down` не оставляет клиентский `awg0` без обязательного выхода: сначала
проверяется, что `awg0` действительно снят (включая интерфейс, поднятый вручную),
и лишь затем снимается upstream. `up`/`restart`/`apply` восстанавливают прежнее
активное состояние `awg0`; ошибка upstream приводит к fail-closed остановке.

---

## Если что-то не так

1. **Нет handshake на `awg1` (нода 2 не видит ноду 1)** → на ноде 1 проверь `ufw status` — должен быть `ALLOW 39743/udp` (или твой порт).
2. **Handshake есть, но клиент не выходит в интернет** → на ноде 2 глянь `iptables -L FORWARD -n -v` — нужны ACCEPT-правила `awg0 → awg1` и обратно.
3. **`curl ifconfig.me` показывает IP ноды 2, а не ноды 1** → на ноде 2 проверь `ip rule` — должна быть строка `from 10.8.0.0/24 lookup 123`.
4. **Хочешь начать заново** → `sudo bash install_amneziawg.sh --uninstall` на обеих нодах.

---

## Как это работает под капотом (кратко)

- На entry-ноде именно `awg0.conf` в своих `PostUp`/`PostDown` владеет policy-routing и fail-closed защитой: blackhole-default с metric `42760` в таблице `123`, source-rule `from 10.8.0.0/24 lookup 123 priority 456` и RPDB blackhole guard с приоритетом `457` (`P+1`). Там же живут `FORWARD` между `%i` и `awg1` и TCPMSS-clamp; `MASQUERADE` на `eth0` нет.
- `awg1.conf` содержит только поддержку выхода: `Table=123`, `FwMark=0xca6d`, дефолт `AllowedIPs = 0.0.0.0/0` (его `awg-quick` кладёт в таблицу `123`) и `MASQUERADE -o %i`. Source-rule и blackhole guard в `awg1.conf` не живут, поэтому исчезновение `awg1` не снимает fail-closed защиту, пока поднят `awg0`.
- Клиентский пакет: **src=10.8.0.5** → приходит на `awg0` → RPDB source-rule выбирает таблицу `123` → рабочий default через `awg1` выигрывает у blackhole по меньшей metric → затем `FORWARD → awg1` → `MASQUERADE` (src становится `10.9.0.2` — адрес entry на стороне exit) → шифрование → exit по UDP → на exit-ноде расшифровывается → `MASQUERADE` на его `eth0` → интернет. Если рабочего default через `awg1` нет, table-blackhole/guard не дают пакету провалиться в `main` и раскрыть прямой egress entry-ноды.
- Обратный пакет приходит на exit (dst=exit публичный IP), проходит DNAT через conntrack обратно к `10.9.0.2` (entry), шифруется в `awg0` exit-ноды, приходит на `awg1` entry-ноды, conntrack восстанавливает dst=`10.8.0.5` клиента, `FORWARD → awg0` → клиенту.

Проверяемые принимающей стороной параметры **должны совпадать между `awg1` (entry) и `awg0` (exit)**: `S1-S4 / H1-H4` и, если задан, `HeaderProtectionKey`. Рендерер также переносит `Jc/Jmin/Jmax` и `I1-I5` из `hop_to_entry.conf`, созданного на exit-ноде, хотя принимающая сторона их не сверяет.

---

## Опция: заворот трафика exit-ноды в Cloudflare WARP

Если хочется, чтобы внешние сайты видели **IP Cloudflare**, а не IP твоей exit-VPS, можно добавить третий хоп — Cloudflare WARP. Удобно когда IP exit-ноды уже в каком-нибудь blocklist'е, или просто чтобы замаскировать VPS-провайдера.

Ставится **только на exit-ноде** (или на single-сервере, без каскада). На entry-ноде флаг `--egress=warp` отвергается — WARP там был бы третьей обёрткой без смысла.

### Как включить

Добавь `--egress=warp` к установке exit-ноды:

```bash
sudo bash install_amneziawg.sh \
  --role=exit \
  --subnet=10.9.0.1/24 \
  --egress=warp \
  --yes
```

Или для одиночного (не-каскадного) сервера:

```bash
sudo bash install_amneziawg.sh --egress=warp --yes
```

Скрипт автоматически:

1. Скачает [wgcf](https://github.com/ViRb3/wgcf) (Cloudflare WARP WireGuard-клиент).
2. Зарегистрирует бесплатный WARP-аккаунт через `wgcf register --accept-tos`.
3. Сгенерирует `/etc/wireguard/wgcf.conf` и пропатчит его: `Table = off` (иначе дефолт-роут сервера уходит в WARP и SSH отваливается), удалит `DNS =`.
4. Включит `wg-quick@wgcf`.
5. В `awg0.conf` добавит транзакционные `PostUp`/`PostDown`: blackhole-default в таблице `2408`, рабочий default через `wgcf` с metric `10`, source-rule с приоритетом `P` (по умолчанию `789`) и RPDB blackhole guard с приоритетом `P+1`, а также `MASQUERADE -o wgcf` и TCPMSS clamp. Поэтому клиентский трафик уходит в `wgcf`, собственный трафик ноды (SSH, apt, handshake от entry) остаётся через `eth0`, а при исчезновении WARP клиентский поток не проваливается в `main`.

### Проверка

На exit-ноде:

```bash
# Интерфейс поднят и есть handshake с Cloudflare:
sudo wg show wgcf

# Правило policy-routing на месте:
ip rule | grep 2408
ip route show table 2408
```

С клиента (после подключения к VPN):

```bash
curl ifconfig.me
```

Должен вернуть **IP из диапазона Cloudflare** (`104.x` / `162.x`), не IP exit-ноды.

### Чем чревато

- **Free WARP тормозит** в пиковые часы. Если видишь просадки до 20-50 Мбит/с — это норма бесплатного тарифа Cloudflare.
- **IP Cloudflare могут быть заблокированы** некоторыми сайтами (банки, стриминг). Если после включения что-то перестало работать — это не каскад, это блоклисты.
- **Тройная инкапсуляция** (клиент→entry→exit→WARP) съедает MTU. Без TCPMSS clamp (который скрипт уже добавляет) часть HTTPS-сайтов будет виснуть на handshake.
- **`100.64.0.0/10`** — служебная подсеть WARP. Не используй её как `--subnet=` для AWG-клиентов.

### Тонкая настройка

```bash
--warp-table=N       # routing table (умолч. 2408)
--warp-priority=N    # приоритет P: 1..32764 (умолч. 789); P+1 занят blackhole guard
--warp-bypass=SPEC   # none | youtube | custom:<URL|/path>[,...]
```

`--warp-bypass` добавляет в WARP-таблицу более специфичные маршруты выбранных
назначений через основной NIC. Здесь «напрямую» означает **мимо Cloudflare WARP,
но всё ещё через exit-VPS**: благодаря отдельному MASQUERADE сайт видит публичный
IP этой VPS. Эти назначения намеренно исключены из WARP fail-closed; остальной
клиентский трафик по-прежнему защищён table-blackhole и guard `P+1`. Приоритет
`P` ограничен диапазоном `1..32764`, чтобы `P+1` оставался раньше системного
правила `main` с приоритетом `32766`.

Режимы WARP egress и entry/upstream взаимоисключающие, поэтому эти таблицы одновременно не используются.

### Отключение

Если передумал — просто `sudo bash install_amneziawg.sh --uninstall`. Скрипт удаляет сервис, конфиг, account-файл и бинарь `wgcf` только при наличии отдельного точного ownership-marker для соответствующего ресурса. Неоднозначный пустой marker старой версии не считается доказательством владения сервисом, поэтому существующий до установки wgcf сохраняется.
