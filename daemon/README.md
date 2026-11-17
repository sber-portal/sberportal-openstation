# Демон `openstationd` для SberPortal

Демон не форкается целиком: используется upstream-репозиторий
[OPENSTATION](https://github.com/Olegu621/OPENSTATION) плюс патч из этого каталога.

## Применение патча

```sh
git clone https://github.com/Olegu621/OPENSTATION.git
cd OPENSTATION
git checkout 954c906            # v1.5.1, база патча
git apply /path/to/openstation-proxy-failover.patch
```

Патч делает две вещи: перебор прокси-хостов для Gemini Live и инструмент
`kinopoisk_control` для голосового запуска фильмов.

| файл | что делает |
| --- | --- |
| `daemon/src/config.hpp` | поле `gemini_proxy_hosts` в `AssistantConfig` |
| `daemon/src/config.cpp` | разбор/сериализация `assistant.geminiProxyHosts`, нормализация значений |
| `daemon/src/assistant/assistant_manager.cpp` | упорядоченные маршруты и перебор при сбое; объявление инструмента `kinopoisk_control` и правила для промпта |
| `daemon/src/main.cpp` | `geminiProxyHosts` в теле `POST /api/assistant/test`; реализация `kinopoisk_control` и резолвер названия в ID Кинопоиска |

## Инструмент `kinopoisk_control`

Голосовая команда «включи фильм …» превращается в открытие карточки фильма
в приложении Кинопоиска (`ru.kinopoisk`). Схема:

1. Gemini вызывает `kinopoisk_control(action="play", title="Дюна")`.
2. Демон ищет ID Кинопоиска через Wikidata: CirrusSearch по
   `"<название> haswbstatement:P2603"` (P2603 — Kinopoisk film ID), затем
   `wbgetclaims&property=P2603` у первого подходящего элемента.
3. Открывает `am start -a android.intent.action.VIEW -d kp://film/<id>` —
   приложение показывает карточку с автозапуском трейлера.
4. Если ID не нашёлся — открывает вкладку поиска `kp://search` и говорит об этом.

Действия инструмента: `play` (по названию), `open` (просто открыть приложение),
`search` (вкладка поиска), `play_pause` (keyevent 85), `stop` (`am force-stop`).

Почему Wikidata, а не поиск Кинопоиска: `www.kinopoisk.ru/index.php?kp_query=…`
отдаёт редирект в Яндекс SSO (антибот), а открытый API Кинопоиска требует ключа.
Wikidata доступна с домашних сетей РФ и не требует регистрации.

Проверено на портале: «Дюна» → `kp://film/409424`, «Ведьмак» → `kp://film/1044004`
(сериал 2019), «Смешарики» → `kp://film/256124`. Deep link `kp://film/<id>`
работает и для фильмов, и для сериалов.

Ограничение: сам просмотр требует входа в аккаунт Яндекса в приложении
(и подписки Плюс для большинства фильмов) — без логина Кинопоиск уводит
на экран `BouncerActivity`. Голосовая команда открывает карточку и трейлер,
дальше нужен тап по «Смотреть».

## Сборка под портал (`armeabi-v7a`)

```sh
cmake -S daemon -B build-v7 \
  -DCMAKE_TOOLCHAIN_FILE="$ANDROID_NDK/build/cmake/android.toolchain.cmake" \
  -DANDROID_ABI=armeabi-v7a \
  -DANDROID_PLATFORM=android-28 \
  -DCMAKE_BUILD_TYPE=Release
cmake --build build-v7 -j8
"$ANDROID_NDK/toolchains/llvm/prebuilt/*/bin/llvm-strip" --strip-unneeded build-v7/openstationd
```

Готовый бинарник — около 1.8 МБ. Зависимости (`libonnxruntime.so`,
`libsherpa-onnx-c-api.so`) берутся из upstream-релизов под `armeabi-v7a`
и кладутся в `/data/local/openstation/lib`.

## Установка на устройство

```sh
adb push build-v7/openstationd /data/local/openstation/openstationd.new
adb shell 'cd /data/local/openstation && \
  cp -f openstationd openstationd.bak && \
  cp -f openstationd.new openstationd && chmod 755 openstationd && \
  kill $(pidof openstationd)'
adb shell 'nohup setsid sh -c "exec env LD_LIBRARY_PATH=/data/local/openstation/lib:/vendor/lib:/system/lib \
  /data/local/openstation/openstationd >>/data/local/openstation/boot.log 2>&1" >/dev/null 2>&1 &'
```

После перезагрузки демон поднимает bootstarter (`bootstarter/`).

## Конфигурация

`/data/local/openstation/config.json`, секция `assistant`:

| ключ | смысл |
| --- | --- |
| `geminiApiKey` | ключ Gemini API (хранится только на устройстве) |
| `geminiModel` | модель Live, по умолчанию `gemini-3.8-live` |
| `geminiProxyHost` | одиночный прокси-хост (совместимость с upstream и веб-пультом) |
| `geminiProxyHosts` | упорядоченный список прокси-хостов (приоритет над одиночным) |
| `wakeWordEnabled` | офлайн-детектор фразы «Алиса» |
| `echoGuard` | подавление эха собственного голоса |

Применяется на лету:

```sh
curl -X POST http://127.0.0.1:8080/api/config \
  -H 'Content-Type: application/json' \
  -d '{"assistant":{"geminiProxyHosts":["proxy-a.example","proxy-b.example"]}}'
```

## Логика перебора маршрутов

Итоговый список попыток строится так:

1. если в прошлой сессии сработал прокси — сначала все прокси в порядке конфига,
   затем прямое подключение;
2. если прошлая сессия шла напрямую — сначала прямое подключение, затем прокси;
3. прямой маршрут всегда присутствует и всегда последний (если он не первый по п.2).

Хост, на котором handshake завершился успешно, сохраняется в `preferred_proxy_host_`
и при следующей сессии перемещается в начало списка. Плюс флаг `use_proxy_host_`
фиксирует, что рабочим был прокси (а не прямое подключение). Итог: после одного
медленного перебора следующие старты идут напрямую в рабочий узел.

Перебор запускается на:

- ошибке TCP/TLS при `connect`;
- ошибке отправки `BidiGenerateContentSetup`;
- ошибке до `setupComplete` с упоминанием `location`/`region`/`country`/`unavailable`;
- закрытии сокета кодами `1006`, `1007` или `0` до `setupComplete`;
- ошибке чтения до `setupComplete`;
- таймауте `setupComplete` (10 с).

В логах это выглядит так:

```
[W] Assistant: Gemini connect via 'proxy-a.example' failed (...); trying next route 'proxy-b.example'
[I] Assistant: Gemini Live setupComplete (via=proxy-b.example, voice=Aoede)
```

## Проверка

```sh
# установить соединение и получить setupComplete через конкретный хост
curl -X POST http://127.0.0.1:8080/api/assistant/test \
  -H 'Content-Type: application/json' -d '{"geminiProxyHost":"proxy-a.example"}'

# реальный ход через выбранный маршрут
curl -X POST http://127.0.0.1:8080/api/assistant/text \
  -H 'Content-Type: application/json' -d '{"text":"Ответь одним словом: проверка."}'
```

Ответ `{"ok":true,"via":"..."}` — соединение прошло; `code:1007` — геоблок,
значит маршрут не подходит.
