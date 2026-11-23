# MyRemote protocol v1

Контракт між Mac-агентом (`mac/`) і Android-клієнтом (`android/`). Обидві сторони
зобов'язані проходити контрактні тести на фікстурах із `protocol/fixtures/`.
Зміна цього файлу = зміна обох реалізацій.

## 1. Транспорт

- WebSocket поверх TLS (`wss://<host>:<port>/ws`), TLS 1.2+.
- Сервер — Mac-агент. Порт за замовчуванням `47110`; якщо зайнятий, агент бере
  будь-який вільний. Фактичний порт завжди є в Bonjour і в pairing URI.
- Сертифікат сервера самопідписаний і стабільний між запусками агента.
  Клієнт НЕ перевіряє ланцюжок і hostname, натомість закріплює (pin) відбиток:
  `fp` = SHA-256 від DER-кодування leaf-сертифіката, 64 символи lowercase hex.
  Невідповідність відбитка = з'єднання розривається до відправки будь-яких даних.
- Лише текстові фрейми. Один фрейм = один JSON-об'єкт UTF-8. Бінарні фрейми
  сервер ігнорує.

## 2. Виявлення (Bonjour / mDNS)

- Тип сервісу: `_myremote._tcp`, домен `local.`
- Ім'я сервісу: ім'я комп'ютера.
- TXT-записи: `v=1`, `id=<agentId>`.
- `agentId` — стабільний випадковий ідентифікатор агента (16 символів lowercase hex),
  генерується при першому запуску. Клієнт шукає свій спарений агент за `id`,
  а не за іменем чи IP.

## 3. Сполучення

Агент показує QR-код із pairing URI:

```
myremote://pair?v=1&host=<ipv4|hostname>&port=<port>&id=<agentId>&name=<percent-encoded>&fp=<64 hex>&token=<base64url без padding, 32 байти>
```

- Усі параметри обов'язкові. Порядок параметрів довільний. Невідомі параметри ігноруються.
- `v` мусить дорівнювати `1`, інакше клієнт відмовляє зі зрозумілою помилкою.
- `token` — спільний секрет, 32 випадкові байти, base64url без `=` (43 символи).
- Клієнт зберігає `id`, `name`, `fp`, `token`, останні `host`/`port`.
- Перепідключення: спершу mDNS за `id`, якщо за 3 с не знайдено — останні `host:port`.
- "Reset pairing" на агенті генерує новий `token` (сертифікат і `agentId` лишаються)
  і розриває всі активні з'єднання.

## 4. Повідомлення

Кожне повідомлення — JSON-об'єкт із рядковим полем `type`. Невідомі поля
ігноруються обома сторонами (forward compatibility). Невідомий `type` від клієнта —
сервер відповідає `error` з кодом `bad_request` і НЕ розриває з'єднання.
Невідомий `type` від сервера клієнт мовчки ігнорує.

Числа `dx`/`dy` — JSON numbers (можуть бути дробовими). `id`, `t`, `v` — цілі.

### 4.1 Рукостискання

Перше повідомлення клієнта мусить бути `hello`, не пізніше ніж за 5 с після
відкриття WebSocket. Будь-що інше до успішного `hello` → `error unauthorized` + закриття.

```json
{"type":"hello","v":1,"token":"<token>","device":"Galaxy S24"}
```

Відповідь при успіху:

```json
{"type":"welcome","v":1,"agent":{"id":"0123456789abcdef","name":"MacBook Pro"},"state":{ ...State... }}
```

Відповідь при помилці, після якої сервер закриває WebSocket:

| Ситуація | `code` | WS close code |
|---|---|---|
| невірний token / не `hello` першим / таймаут 5 с | `unauthorized` | 4401 |
| `v` не підтримується | `unsupported_version` | 4400 |

Порівняння токена — constant-time.

### 4.2 Клієнт → сервер

| `type` | Поля | Опис |
|---|---|---|
| `cmd` | `action` (string), `id` (int, optional) | Семантична команда плеєра |
| `key` | `key` (string), `id` (int, optional) | Натискання іменованої клавіші |
| `pointer` | `dx`, `dy` (number) | Відносний рух курсора в points екрана Mac |
| `click` | `button` (`left`\|`right`), `count` (1\|2) | Клік у поточній позиції курсора. `count: 2` — це повний подвійний клік (down/up/down/up); клієнт НЕ шле перед ним окремий `count: 1` |
| `scroll` | `dx`, `dy` (number) | Скрол у пікселях. Додатний `dy` = як колесо миші вниз (видно те, що нижче на сторінці); додатний `dx` = як колесо вправо |
| `text` | `text` (string), `id` (int, optional) | Набрати Unicode-текст |
| `ping` | `t` (int, мс клієнта) | Heartbeat |

Значення `cmd.action`:

`playPause`, `seekBackward`, `seekForward`, `volumeUp`, `volumeDown`, `toggleMute`,
`toggleFullscreen`, `nextItem`, `previousItem`, `skip`, `toggleSubtitles`

Значення `key.key`:

`up`, `down`, `left`, `right`, `enter`, `escape`, `space`, `tab`, `backspace`

Якщо в `cmd`/`key`/`text` є `id` — сервер зобов'язаний відповісти `ack` з тим самим `id`.
Без `id` відповіді немає. `pointer`/`click`/`scroll` ніколи не підтверджуються.

### 4.3 Сервер → клієнт

| `type` | Поля | Опис |
|---|---|---|
| `welcome` | `v`, `agent{id,name}`, `state` | Успішне рукостискання |
| `ack` | `id`, `ok` (bool), `error` (string, лише якщо `ok=false`) | Результат команди |
| `state` | `state` | Push при зміні стану |
| `pong` | `t` (те саме значення, що в `ping`) | Відповідь на heartbeat |
| `error` | `code`, `message` | Помилка протоколу |

`ack.error`:
- `accessibility_denied` — агент не має дозволу Accessibility, подію не надіслано;
- `unsupported` — у поточному профілі для цієї дії немає відповідника;
- `bad_request` — невідомий `action`/`key` або некоректні поля.

`error.code`: `unauthorized`, `unsupported_version`, `bad_request`.

### 4.4 State

```json
{
  "frontApp": {"bundleId": "com.google.Chrome", "name": "Google Chrome"},
  "profile": "youtube",
  "accessibility": true
}
```

- `frontApp` — може бути `null`, якщо невідомо.
- `profile` — `youtube` | `netflix` | `appletv` | `generic`.
- `accessibility` — чи має агент дозвіл на інжект подій.

Сервер шле `state` кожному автентифікованому клієнту, коли змінюється будь-яке з полів.

### 4.5 Heartbeat

Клієнт шле `ping` кожні 5 с. Якщо `pong` не прийшов за 10 с — клієнт вважає
з'єднання мертвим, закриває його і перепідключається з exponential backoff
(1 с, 2 с, 4 с … максимум 15 с). Сервер закриває з'єднання, якщо від клієнта
немає жодного повідомлення 30 с.

Таймаути на боці клієнта, які контракт лишає на розсуд реалізації: очікування
`welcome` (Android: 10 с) і очікування `ack` (Android: 3 с).

Після `unauthorized` чи `unsupported_version` клієнт НЕ перепідключається
(потрібне повторне сполучення). Після невідповідності відбитка сертифіката клієнт
продовжує спроби зі звичайним backoff, бо наступна спроба може потрапити на інший хост.

## 5. Профілі (відповідальність агента)

Агент визначає профіль за frontmost-застосунком:

- `com.apple.TV` → `appletv`
- браузер (Safari, Chrome, Arc, Firefox, Edge, Brave…), заголовок активного вікна
  містить `YouTube` → `youtube`; містить `Netflix` → `netflix`
- інакше → `generic`

Профіль перекладає `cmd.action` у конкретну дію (клавіша з модифікаторами або
системна медіа-клавіша). Якщо відповідника немає → `ack ok=false error=unsupported`.

## 6. CLI агента для інтеграційних тестів

Агент мусить підтримувати запуск без UI:

```
MyRemoteAgent --headless [--dry-run] [--loopback] [--port <n>] [--state-dir <path>]
```

- `--headless` — без menu bar UI, лише сервер.
- `--dry-run` — події НЕ інжектяться в систему; замість цього кожна дія, яку було б
  виконано, друкується в stdout одним рядком: `INJECT <json>`.
  `accessibility` у state при цьому `true`.
- `--state-dir` — де зберігати сертифікат, token, agentId (за замовчуванням
  `~/Library/Application Support/MyRemote`).
  Формат JSON: об'єкт із відсортованими ключами і полем `kind`:
  `key` (`key`, `keyCode`, `modifiers`), `mediaKey` (`key`), `pointer` (`dx`, `dy`),
  `click` (`button`, `count`), `scroll` (`dx`, `dy`), `text` (`text`).
  Відхилені та `unsupported` команди нічого не друкують.
- `--profile youtube|netflix|appletv|generic` — зафіксувати профіль (інакше він
  залежить від того, який застосунок зараз frontmost на машині; `frontApp` тоді `null`).
- `--no-bonjour` — не реєструвати mDNS-сервіс (щоб тести не викликали системний
  запит Local Network).
- `--loopback` — у pairing URI підставляється `host=127.0.0.1` замість LAN IPv4
  (сервер усе одно слухає на всіх інтерфейсах).
- `--port 0` — взяти будь-який вільний порт.
- Одразу після старту сервера агент друкує в stdout рядок `PAIRING <pairing-uri>`
  і робить flush stdout після кожного рядка (`PAIRING`, `INJECT`).
