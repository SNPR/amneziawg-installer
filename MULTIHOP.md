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

## Нода 1 (exit) — «выходной» сервер

На exit-ноде можно использовать **оригинальный скрипт автора** ([bivlked/amneziawg-installer](https://github.com/bivlked/amneziawg-installer)) без наших модификаций — там нужен обычный AmneziaWG 2.0 сервер, ничего специфичного для каскада. Если предпочитаешь однородность — запускай наш форк с `--role=exit`, разницы в результирующем конфиге не будет (флаг `--role=exit` только маркирует ноду в `awgsetup_cfg.init` для документации).

**Шаг A.** Установка (одна команда):

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
sudo bash /root/awg/manage_amneziawg.sh upstream restart # только каскад
sudo bash /root/awg/manage_amneziawg.sh upstream show    # статус каскада
```

---

## Если что-то не так

1. **Нет handshake на `awg1` (нода 2 не видит ноду 1)** → на ноде 1 проверь `ufw status` — должен быть `ALLOW 39743/udp` (или твой порт).
2. **Handshake есть, но клиент не выходит в интернет** → на ноде 2 глянь `iptables -L FORWARD -n -v` — нужны ACCEPT-правила `awg0 → awg1` и обратно.
3. **`curl ifconfig.me` показывает IP ноды 2, а не ноды 1** → на ноде 2 проверь `ip rule` — должна быть строка `from 10.8.0.0/24 lookup 123`.
4. **Хочешь начать заново** → `sudo bash install_amneziawg.sh --uninstall` на обеих нодах.

---

## Как это работает под капотом (кратко)

- На entry-ноде `awg0.conf` не делает `MASQUERADE` на `eth0`, а только пускает `FORWARD` между `%i` и `awg1` + TCPMSS-clamp на SYN.
- `awg1.conf` получает параметры `Table=123` и `FwMark=0xca6d`, плюс `PostUp`: `ip rule add from 10.8.0.0/24 table 123 priority 456` и `MASQUERADE -o %i`.
- Клиентский пакет: **src=10.8.0.5** → попадает на `awg0` → `FORWARD → awg1` → `ip rule` ловит по src → таблица 123 → дефолт через `awg1` → `MASQUERADE` (src становится `10.9.0.2` — адрес entry на стороне exit) → шифрование → exit по UDP → на exit-ноде расшифровывается → `MASQUERADE` на его `eth0` → интернет.
- Обратный пакет приходит на exit (dst=exit публичный IP), проходит DNAT через conntrack обратно к `10.9.0.2` (entry), шифруется в `awg0` exit-ноды, приходит на `awg1` entry-ноды, conntrack восстанавливает dst=`10.8.0.5` клиента, `FORWARD → awg0` → клиенту.

Нужные для жизни каскада параметры **должны совпадать между `awg1` (entry) и `awg0` (exit)**: `Jc / Jmin / Jmax / S1-S4 / H1-H4`. Скрипт берёт их из `hop_to_entry.conf`, созданного на exit-ноде — совпадение гарантировано.

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
5. В `awg0.conf` добавит `PostUp`: `ip rule from <подсеть> table 2408`, `ip route default dev wgcf table 2408`, `MASQUERADE -o wgcf`, `TCPMSS clamp` — чтобы клиентский трафик уходил в `wgcf`, а собственный трафик ноды (SSH, apt, handshake от entry) оставался через `eth0`.

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
--warp-priority=N    # приоритет ip rule (умолч. 789)
```

Коллизия с `--upstream-table` (123) проверяется на валидации.

### Отключение

Если передумал — просто `sudo bash install_amneziawg.sh --uninstall`. Скрипт аккуратно снесёт `wg-quick@wgcf`, `wgcf.conf`, account-файл и сам бинарь `wgcf` — но только если WARP поднимался именно нашим инсталлятором (маркер `.wgcf_enabled_by_installer`). Если wgcf у тебя был до установки — uninstall его не трогает.
