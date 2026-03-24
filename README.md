<a id="top"></a>
<p align="center">
  <b>RU</b> Русский | <b>EN</b> <a href="README.en.md">English</a>
</p>

<p align="center">
  <img src="logo.jpg" alt="AmneziaWG 2.0 Installer" width="600">
</p>

<p align="center">
  <strong>Набор Bash-скриптов для быстрой, безопасной и удобной установки,<br>
  настройки и управления VPN-сервером AmneziaWG 2.0 на Ubuntu (24.04 LTS / 25.10) и Debian (12 / 13)</strong>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Ubuntu-24.04_|_25.10-orange" alt="Ubuntu 24.04 | 25.10">
  <img src="https://img.shields.io/badge/Debian-12_|_13-A81D33" alt="Debian 12 | 13">
  <a href="https://github.com/bivlked/amneziawg-installer/blob/main/LICENSE"><img src="https://img.shields.io/github/license/bivlked/amneziawg-installer" alt="License"></a>
  <img src="https://img.shields.io/badge/Status-Stable-success" alt="Status">
  <a href="https://github.com/bivlked/amneziawg-installer/releases"><img src="https://img.shields.io/badge/Installer_Version-5.7.7-blue" alt="Version"></a>
  <img src="https://img.shields.io/badge/AmneziaWG-2.0-blueviolet" alt="AWG 2.0">
  <a href="https://github.com/bivlked/amneziawg-installer/actions/workflows/shellcheck.yml"><img src="https://github.com/bivlked/amneziawg-installer/actions/workflows/shellcheck.yml/badge.svg" alt="ShellCheck"></a>
  <a href="https://github.com/bivlked/amneziawg-installer/stargazers"><img src="https://img.shields.io/github/stars/bivlked/amneziawg-installer?style=flat" alt="Stars"></a>
  <a href="https://github.com/bivlked/amneziawg-installer/network/members"><img src="https://img.shields.io/github/forks/bivlked/amneziawg-installer?style=flat" alt="Forks"></a>
  <img src="https://img.shields.io/github/last-commit/bivlked/amneziawg-installer" alt="Last commit">
</p>

<p align="center">
  <a href="#zachem">Зачем это нужно</a> •
  <a href="#quickstart">Быстрый старт</a> •
  <a href="#vozmozhnosti">Что умеет</a> •
  <a href="#trebovaniya">Требования</a> •
  <a href="#recomend-hosting">Хостинг</a> •
  <a href="#ustanovka">Установка</a> •
  <a href="#posle-ustanovki">После установки</a> •
  <a href="#upravlenie">Управление</a> •
  <a href="#dopolnitelno">Дополнительно</a> •
  <a href="#faq-main">FAQ</a> •
  <a href="#licenziya">Лицензия</a>
</p>

<a id="zachem"></a>
## 💡 Зачем это нужно

[AmneziaWG](https://github.com/amnezia-vpn) — форк WireGuard с обфускацией трафика. Системы DPI не могут отличить его от обычного шума, поэтому подключение не блокируется.

Этот набор скриптов превращает чистый VPS в готовый VPN-сервер. Не нужны знания Linux — скрипт сам настроит firewall, оптимизирует систему, создаст конфиги и QR-коды для клиентов.

Работает на Ubuntu 24.04/25.10 и Debian 12/13. Хватит любого дешёвого VPS с 1 ГБ RAM.

---

<a id="quickstart"></a>
## 🚀 Быстрый старт

```bash
wget https://raw.githubusercontent.com/bivlked/amneziawg-installer/main/install_amneziawg.sh
chmod +x install_amneziawg.sh
sudo bash ./install_amneziawg.sh
```

> 3 команды для запуска. 2 перезагрузки по ходу. Около 20 минут до готового VPN. [Подробнее →](#ustanovka)

<details>
<summary><strong>Неинтерактивная установка (для автоматизации)</strong></summary>

```bash
sudo bash ./install_amneziawg.sh --yes --route-all
```

Все параметры принимаются автоматически. Подробнее: [ADVANCED.md#cli-params-adv](ADVANCED.md#cli-params-adv)
</details>

---

<a id="vozmozhnosti"></a>
## ✨ Что умеет

* **Обход блокировок** — AmneziaWG 2.0 с обфускацией трафика. DPI не детектирует подключение
* **Одна команда — готовый VPN** — от чистого VPS до работающего сервера с клиентскими конфигами и QR-кодами
* **Безопасность из коробки** — UFW, Fail2Ban, sysctl hardening, строгие права доступа (600/700)
* **Удобное управление** — добавление/удаление клиентов, временные клиенты с авто-удалением, статистика, бэкапы
* **4 операционные системы** — Ubuntu 24.04, Ubuntu 25.10, Debian 12, Debian 13

<details>
<summary><strong>Все возможности</strong></summary>

* Нативная генерация ключей и конфигов через `awg` — без Python и внешних зависимостей
* Hardware-aware оптимизация: swap, NIC offloads, сетевые буферы на основе характеристик сервера
* DKMS — автоматическая пересборка модуля ядра при обновлении
* `vpn://` URI для импорта в Amnezia Client одним тапом (`.vpnuri` файлы)
* Статистика трафика по клиентам (`stats`, `stats --json`)
* Временные клиенты с авто-удалением (`--expires=1h`, `7d`, `4w` и др.)
* Диагностический отчёт (`--diagnostic`) и полная деинсталляция (`--uninstall`)
* Логирование всех действий в `/root/awg/`
* Возобновление установки после перезагрузки — скрипт продолжит с нужного шага
* Выбор порта, подсети, режима IPv6 и маршрутизации. Поддержка `--endpoint` для серверов за NAT
</details>

---

<a id="trebovaniya"></a>
## 🖥️ Требования

* **ОС:** **Чистая** установка **Ubuntu Server 24.04 LTS** / **Ubuntu 25.10** (⚠️) / **Debian 12** / **Debian 13** Minimal
* **Доступ:** Права `root` (через `sudo`)
* **Интернет:** Стабильное подключение
* **Ресурсы:** ~1 ГБ ОЗУ (рекомендуется 2+ ГБ), минимум ~2 ГБ диска (рекомендуется 3+ ГБ)
* **SSH:** Доступ по SSH

**Совместимость ОС:**

| ОС | Статус | Примечание |
|----|--------|------------|
| Ubuntu 24.04 LTS | ✅ Полная поддержка | Рекомендуется |
| Ubuntu 25.10 | ⚠️ Экспериментально | Может потребоваться сборка модуля из исходников |
| Debian 12 (bookworm) | ✅ Поддержка | Протестировано. PPA через маппинг codename на focal |
| Debian 13 (trixie) | ✅ Поддержка | Протестировано. PPA через маппинг codename на noble, DEB822 |

> ⚠️ **Нестандартный порт SSH:** Если SSH работает не на порту 22, выполните `sudo ufw allow ВАШ_ПОРТ/tcp` **до** запуска установки, иначе вы потеряете доступ к серверу.

**Клиенты:**
* **Все платформы:** [Amnezia VPN](https://github.com/amnezia-vpn/amnezia-client/releases) **>= 4.8.12.7** — полнофункциональный VPN-клиент с AWG 2.0. Импорт через `vpn://` URI
* **Windows:** [AmneziaWG](https://github.com/amnezia-vpn/amneziawg-windows-client/releases) **>= 2.0.0** — легковесный tunnel manager с AWG 2.0. Импорт через `.conf` файлы

> [Полная таблица совместимости клиентов →](ADVANCED.md#client-compat-adv)

---

<a id="recomend-hosting"></a>
## 🚀 Рекомендация хостинга

Для стабильной работы VPN-сервера с высокой пропускной способностью важен надежный хостинг с хорошим каналом.

Мы протестировали и рекомендуем [**FreakHosting**](https://freakhosting.com/clientarea/aff.php?aff=392). В частности, их линейку **BUDGET VPS** предлагающую отличное соотношение цены и качества.

Их IP-адреса не идентифицируются, как адреса датацентров и через них прекрасно работают такие сервисы, как Claude Desktop и другие (в отличие, например, от Azure, чьи адреса Claude теперь блокирует).

* **Рекомендуемый тариф:** **BVPS-2**
* **Характеристики:** 2 vCPU, 2 GB RAM, 40 GB NVMe SSD.
* **Ключевое преимущество:** порт **10 Gbps** с **неограниченным трафиком**. Идеально для VPN!
* **Цена:** Всего **€25 в год** (около 2200 руб.).

Этой конфигурации более чем достаточно для комфортной работы AmneziaWG с большим количеством подключений и высоким трафиком.

---

<a id="ustanovka"></a>
## 🔧 Установка (Рекомендуемый способ)

Этот метод установки гарантирует корректную работу интерактивных запросов и цветного вывода в вашем терминале.

1.  **Подключитесь** к **чистому** серверу (Ubuntu 24.04 / Ubuntu 25.10 / Debian 12 / Debian 13) по SSH.
    > **Совет:** После создания сервера подождите 5-10 минут, чтобы завершились все фоновые процессы инициализации системы, прежде чем запускать установку.

2.  **Скачайте скрипт:**
    ```bash
    wget https://raw.githubusercontent.com/bivlked/amneziawg-installer/main/install_amneziawg.sh
    # или: curl -fLo install_amneziawg.sh https://raw.githubusercontent.com/bivlked/amneziawg-installer/main/install_amneziawg.sh
    ```
3.  **Сделайте его исполняемым:**
    ```bash
    chmod +x install_amneziawg.sh
    ```
4.  **Запустите с `sudo`:**
    ```bash
    sudo bash ./install_amneziawg.sh
    ```
    *(Вы также можете передать параметры командной строки, см. `sudo bash ./install_amneziawg.sh --help` или [ADVANCED.md#cli-params-adv](ADVANCED.md#cli-params-adv))*

    > **English version:** Для вывода на английском используйте `install_amneziawg_en.sh`:
    > ```bash
    > wget https://raw.githubusercontent.com/bivlked/amneziawg-installer/main/install_amneziawg_en.sh
    > sudo bash ./install_amneziawg_en.sh
    > ```
    > Английская версия функционально идентична; только сообщения и логи на английском.
    > После перезагрузки продолжайте тем же файлом: `sudo bash ./install_amneziawg_en.sh`

5.  **Начальная настройка:** Скрипт интерактивно запросит:
    * **UDP порт:** Порт для подключения клиентов (1024-65535). По умолчанию: `39743`.
    * **Подсеть туннеля:** Внутренняя сеть для VPN. По умолчанию: `10.9.9.1/24`.
    * **Отключение IPv6:** Рекомендуется отключить (`Y`) для избежания утечек трафика.
    * **Режим маршрутизации:** Определяет, какой трафик пойдет через VPN. По умолчанию `2` (Список Amnezia+DNS) - рекомендуется для лучшей совместимости и обхода блокировок.

    Параметры AWG 2.0 (Jc, S1-S4, H1-H4, I1) генерируются **автоматически** — никаких действий не требуется.

6.  **Перезагрузки:** Потребуется **ДВЕ** перезагрузки. Скрипт запросит подтверждение `[y/N]`. Введите `y` и нажмите Enter.

7.  **Продолжение:** После каждой перезагрузки **снова запустите скрипт** той же командой:
    ```bash
    sudo bash ./install_amneziawg.sh
    ```
    Скрипт автоматически продолжит с нужного шага **без повторных запросов**.

8.  **Завершение:** После второй перезагрузки и третьего запуска скрипта вы увидите сообщение:
    `Установка и настройка AmneziaWG 2.0 УСПЕШНО ЗАВЕРШЕНА!`

---

<a id="posle-ustanovki"></a>
## 📦 После установки

**Где найти файлы клиентов:**

| Файл | Путь | Назначение |
|------|------|------------|
| `.conf` | `/root/awg/имя.conf` | Конфигурация для импорта в клиент |
| `.png` | `/root/awg/имя.png` | QR-код для мобильных устройств |
| `.vpnuri` | `/root/awg/имя.vpnuri` | `vpn://` URI для Amnezia Client |

**Скачать конфиг на компьютер:**

```bash
scp root@IP_СЕРВЕРА:/root/awg/my_phone.conf .
```

<details>
<summary><strong>Импорт в Amnezia VPN (телефон) через vpn:// URI</strong></summary>

1. На сервере выполните: `cat /root/awg/my_phone.vpnuri`
2. Скопируйте текст и отправьте себе (Telegram, почта и т.д.)
3. На телефоне: Amnezia VPN → «Добавить VPN» → «Вставить из буфера»
</details>

<details>
<summary><strong>Импорт через QR-код</strong></summary>

1. Скачайте QR-код: `scp root@IP_СЕРВЕРА:/root/awg/my_phone.png .`
2. Откройте файл на экране компьютера
3. На телефоне: Amnezia VPN → «Добавить VPN» → «Сканировать QR-код»
</details>

<details>
<summary><strong>Импорт в AmneziaWG for Windows</strong></summary>

1. Скачайте `.conf` файл на компьютер через `scp` или `sftp`
2. AmneziaWG → Import tunnel(s) from file → выберите `.conf` файл
</details>

**Другие файлы на сервере:**

* Конфигурация сервера: `/etc/amnezia/amneziawg/awg0.conf`
* Настройки скрипта: `/root/awg/awgsetup_cfg.init`
* Скрипт управления: `/root/awg/manage_amneziawg.sh`
* Общие функции: `/root/awg/awg_common.sh`
* Данные истечения клиентов: `/root/awg/expiry/`
* Логи: `/root/awg/*.log`

---

<a id="upravlenie"></a>
## 👥 Управление клиентами (`manage_amneziawg.sh`)

Скрипт `manage_amneziawg.sh` для управления пользователями скачивается автоматически.

**Использование:**

```bash
sudo bash /root/awg/manage_amneziawg.sh <команда> [аргументы]
```

**Основные команды:** (Полный список см. `... help` или [ADVANCED.md#manage-commands-adv](ADVANCED.md#manage-commands-adv))

| Команда   | Аргументы              | Описание                     | Перезапуск? |
| :-------- | :--------------------- | :--------------------------- | :-----------: |
| `add`     | `<имя> [--expires=ВРЕМЯ]` | Добавить клиента (опц. с истечением) | Нет (авто) |
| `remove`  | `<имя_клиента>`        | Удалить клиента              |  Нет (авто) |
| `list`    | `[-v]`                 | Список клиентов (`-v` детали) |       Нет     |
| `regen`   | `[имя_клиента]`        | Переген. файлы (всех/одного) |       Нет     |
| `modify`  | `<имя> <пар> <зн>`     | Изменить параметр клиента    |       Нет     |
| `backup`  |                        | Создать резервную копию      |       Нет     |
| `restore` | `[файл]`               | Восстановить из резервной копии |    Нет     |
| `stats`   | `[--json]`                | Статистика трафика по клиентам       | Нет     |
| `show`    |                        | Статус `awg show`            |       Нет     |
| `check`   |                        | Проверка состояния сервера     |       Нет     |
| `restart` |                        | Перезапуск сервиса AmneziaWG   |       -       |

> **💡 Примечание:** Команды `add` и `remove` автоматически применяют изменения через `awg syncconf` — перезапуск сервиса не требуется.

### 📌 Краткая справка

```bash
# Установка (русский)
wget https://raw.githubusercontent.com/bivlked/amneziawg-installer/main/install_amneziawg.sh
sudo bash ./install_amneziawg.sh          # Запуск (+ 2 перезагрузки)

# Установка (English)
wget https://raw.githubusercontent.com/bivlked/amneziawg-installer/main/install_amneziawg_en.sh
sudo bash ./install_amneziawg_en.sh       # Запуск (+ 2 перезагрузки)

# Управление клиентами
sudo bash /root/awg/manage_amneziawg.sh add my_phone       # Добавить
sudo bash /root/awg/manage_amneziawg.sh remove my_phone    # Удалить
sudo bash /root/awg/manage_amneziawg.sh list                # Список
sudo bash /root/awg/manage_amneziawg.sh regen               # Перегенерация

# Временный клиент (7 дней)
sudo bash /root/awg/manage_amneziawg.sh add guest --expires=7d

# Статистика трафика
sudo bash /root/awg/manage_amneziawg.sh stats
sudo bash /root/awg/manage_amneziawg.sh stats --json

# Обслуживание
sudo bash /root/awg/manage_amneziawg.sh check               # Диагностика
sudo bash /root/awg/manage_amneziawg.sh backup               # Бэкап
sudo bash /root/awg/manage_amneziawg.sh restart              # Перезапуск
```

---

<a id="dopolnitelno"></a>
## ℹ️ Дополнительная информация

Более подробную информацию о деталях конфигурации, настройках безопасности, параметрах AWG 2.0, дополнительных командах управления, технических деталях и ответах на другие вопросы вы можете найти в файле **[ADVANCED.md](ADVANCED.md)**.

Историю изменений смотрите в **[CHANGELOG.md](CHANGELOG.md)**.

---

<a id="faq-main"></a>
## ❓ FAQ (Основные вопросы)

<details>
  <summary><strong>В: Будет ли работать после обновления ядра?</strong></summary>
  <b>О:</b> Да, DKMS должен автоматически пересобрать модуль. Проверьте <code>dkms status</code>.
</details>

<details>
  <summary><strong>В: Как полностью удалить AmneziaWG?</strong></summary>
  <b>О:</b> Скачайте скрипт установки (если его нет) и запустите: <code>sudo bash ./install_amneziawg.sh --uninstall</code>.
</details>

<details>
  <summary><strong>В: Клиенты не подключаются, что делать?</strong></summary>
  <b>О:</b> 1. Проверьте статус: <code>sudo bash /root/awg/manage_amneziawg.sh check</code>. 2. Проверьте фаервол: <code>sudo ufw status verbose</code>. 3. Проверьте конфиг клиента. 4. Проверьте логи: <code>sudo journalctl -u awg-quick@awg0 -n 50</code>. 5. Убедитесь, что клиент поддерживает AWG 2.0: Amnezia VPN <b>>= 4.8.12.7</b> или AmneziaWG <b>>= 2.0.0</b>.
</details>

<details>
  <summary><strong>В: Можно ли использовать с AWG 1.x клиентами?</strong></summary>
  <b>О:</b> Нет. AWG 2.0 несовместим с AWG 1.x. Все клиенты должны поддерживать протокол 2.0. Для AWG 1.x используйте ветку <a href="https://github.com/bivlked/amneziawg-installer/tree/legacy/v4">legacy/v4</a>.
</details>

<details>
  <summary><strong>В: Ошибка импорта конфига «Неверный ключ: s3» — что делать?</strong></summary>
  <b>О:</b> Вы используете устаревшую версию <code>amneziawg-windows-client</code> (< 2.0.0). Обновите до <a href="https://github.com/amnezia-vpn/amneziawg-windows-client/releases"><b>версии 2.0.0+</b></a>, которая поддерживает AWG 2.0. Альтернатива — <a href="https://github.com/amnezia-vpn/amnezia-client/releases"><b>Amnezia VPN</b></a> >= 4.8.12.7.
</details>

<details>
  <summary><strong>В: Как обновить скрипты до новой версии?</strong></summary>
  <b>О:</b> Скачайте новый скрипт установки и замените скрипты управления на сервере:
  <pre>
  # Русская версия:
  wget -O /root/awg/manage_amneziawg.sh https://raw.githubusercontent.com/bivlked/amneziawg-installer/main/manage_amneziawg.sh
  wget -O /root/awg/awg_common.sh https://raw.githubusercontent.com/bivlked/amneziawg-installer/main/awg_common.sh
  chmod 700 /root/awg/manage_amneziawg.sh /root/awg/awg_common.sh

  # Английская версия:
  wget -O /root/awg/manage_amneziawg.sh https://raw.githubusercontent.com/bivlked/amneziawg-installer/main/manage_amneziawg_en.sh
  wget -O /root/awg/awg_common.sh https://raw.githubusercontent.com/bivlked/amneziawg-installer/main/awg_common_en.sh
  chmod 700 /root/awg/manage_amneziawg.sh /root/awg/awg_common.sh
  </pre>
  Переустановка сервера не требуется.
</details>

<details>
  <summary><strong>В: Какое максимальное количество клиентов?</strong></summary>
  <b>О:</b> Подсеть <code>/24</code> позволяет до 253 клиентов (.2 — .254), что достаточно для большинства сценариев.
</details>

<details>
  <summary><strong>В: Какой хостинг подходит?</strong></summary>
  <b>О:</b> Любой VPS с Ubuntu 24.04 / Ubuntu 25.10 (⚠️) / Debian 12 / Debian 13, root-доступом и минимум 1 ГБ RAM. Рекомендуем хостинги с незаблокированными IP и неограниченным трафиком. См. <a href="#recomend-hosting">рекомендацию</a>.
</details>

<details>
  <summary><strong>В: Как перенести VPN на другой сервер?</strong></summary>
  <b>О:</b> 1. Создайте бэкап: <code>sudo bash /root/awg/manage_amneziawg.sh backup</code>. 2. Скопируйте архив из <code>/root/awg/backups/</code> на новый сервер. 3. Установите AmneziaWG на новом сервере. 4. Восстановите: <code>sudo bash /root/awg/manage_amneziawg.sh restore</code> (интерактивный выбор из списка, или укажите полный путь к архиву). 5. Перегенерируйте конфиги с новым IP: <code>sudo bash /root/awg/manage_amneziawg.sh regen</code>.
</details>

<details>
  <summary><strong>В: Как создать временного клиента?</strong></summary>
  <b>О:</b> <code>sudo bash /root/awg/manage_amneziawg.sh add guest --expires=7d</code>. Форматы: <code>1h</code>, <code>12h</code>, <code>1d</code>, <code>7d</code>, <code>30d</code>, <code>4w</code>. Cron проверяет каждые 5 минут и автоматически удаляет истёкших клиентов.
</details>

<details>
  <summary><strong>В: Что такое файлы .vpnuri?</strong></summary>
  <b>О:</b> Файлы <code>.vpnuri</code> содержат <code>vpn://</code> URI для импорта конфигурации в Amnezia Client одним тапом. Скопируйте содержимое файла → откройте Amnezia Client → «Добавить VPN» → «Вставить из буфера».
</details>

<details>
  <summary><strong>В: Почему порт 39743?</strong></summary>
  <b>О:</b> Это случайный порт из верхнего диапазона, выбранный как дефолт. Можно изменить при установке: <code>--port=XXXXX</code> (любой порт 1024-65535).
</details>

<details>
  <summary><strong>В: Нужен ли Perl на сервере?</strong></summary>
  <b>О:</b> Perl используется опционально для генерации <code>vpn://</code> URI (<code>.vpnuri</code> файлов). Если Perl отсутствует, <code>.conf</code> файлы создаются как обычно — ими можно пользоваться через импорт файла или QR-код. На Ubuntu и Debian Perl установлен по умолчанию.
</details>

> Больше ответов и решений см. в **[ADVANCED.md](ADVANCED.md)**.

---

## 🛠️ Устранение неполадок

1.  **Логи:** `/root/awg/install_amneziawg.log`, `/root/awg/manage_amneziawg.log`
2.  **Статус сервиса:** `sudo systemctl status awg-quick@awg0`
3.  **Статус AmneziaWG:** `sudo awg show`
4.  **Статус UFW:** `sudo ufw status verbose`
5.  **Диагностический отчет:** `sudo bash ./install_amneziawg.sh --diagnostic`
    Подробное описание содержимого отчета см. в [ADVANCED.md](ADVANCED.md#diagnostic-report-adv).

---

## 🔗 Полезные инструменты

| Проект | Описание |
|--------|----------|
| [Junker](https://spatiumstas.github.io/junker/) | Веб-генератор подписей AmneziaWG от @spatiumstas — для ручной настройки без установочного скрипта |
| [Amnezia VPN Client](https://github.com/amnezia-vpn/amnezia-client) | Официальный клиент с поддержкой AWG 2.0 (>= 4.8.12.7) |
| [AmneziaWG for Windows](https://github.com/amnezia-vpn/amneziawg-windows-client) | Легковесный tunnel manager для Windows с AWG 2.0 (>= 2.0.0) |
| [AmneziaWG-Architect](https://vadim-khristenko.github.io/AmneziaWG-Architect/) | Веб-генератор CPS/мимикрии для AWG 2.0 от @Vadim-Khristenko ([GitHub](https://github.com/Vadim-Khristenko/AmneziaWG-Architect)) |

---

<a id="licenziya"></a>
## 📝 Лицензия и Автор

* **Автор скриптов:** @bivlked - [GitHub](https://github.com/bivlked)
* **Лицензия:** MIT License (см. файл `LICENSE` в репозитории)

---

<p align="center">
  <a href="#top">↑ К началу</a>
</p>
