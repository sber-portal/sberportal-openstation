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

Патч меняет четыре файла:

| файл | что делает |
| --- | --- |
| `daemon/src/config.hpp` | поле `gemini_proxy_hosts` в `AssistantConfig` |
| `daemon/src/config.cpp` | разбор/сериализация `assistant.geminiProxyHosts`, нормализация значений |
| `daemon/src/assistant/assistant_manager.cpp` | упорядоченные маршруты и перебор при сбое |
| `daemon/src/main.cpp` | `geminiProxyHosts` в теле `POST /api/assistant/test` |

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

Успешный маршрут запоминается (`use_proxy_host_`), поэтому следующая сессия начинается
с него и не платит таймаутом за заведомо мёртвый узел.

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
