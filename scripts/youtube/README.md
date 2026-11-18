# YouTube на SberPortal

YouTube на этом подключении недоступен целиком: провайдер подменяет DNS-ответы
для Google (`www.youtube.com` → заблокированный адрес, `*.googlevideo.com` →
`0.0.0.0`) и рвёт TLS-рукопожатие, если в SNI стоит YouTube.

## Откуда берётся рабочий маршрут

В прошивке уже лежит **StarTube** (`ru.sberdevices.startube`) — форк SmartTube
от Сбера. У него внутри сконфигурирован обход: `stunnel` на
`127.0.0.1:11086` поднимает TLS-PSK-туннель к прокси Сбера
(`st-ru1.sbrdvc.ru:4433`), а удалённая сторона сама резолвит адрес и открывает
SOCKS5. То есть наружу уходит только TLS с PSK на адрес Сбера — SNI YouTube в
сети провайдера не появляется.

Проблема в том, что приложение запускает свой stunnel и **сразу его убивает**
(гонка в `ProxyUpdater`), после чего прокси отвечает `ECONNREFUSED`. Поэтому
сам StarTube показывает «Нет доступа к сервису YouTube».

Решение: держать такой же stunnel запущенным **снаружи** приложения, из его же
конфига и PSK, и дать этот маршрут остальным приложениям через локальный
HTTP-прокси.

## Из чего состоит

| файл | что делает |
| --- | --- |
| `stube_tunnel_start.sh` | читает PSK/таргет/порт из `APP_PREFS.xml` StarTube и поднимает `stube_tunnel` на `127.0.0.1:11086` |
| `ytproxy.c` | локальный HTTP-прокси `127.0.0.1:11088`: YouTube и Google — через SOCKS5-туннель, всё остальное — напрямую |
| `youtube_watchdog.sh` | каждые 5 с проверяет туннель, прокси и системную настройку `http_proxy`, поднимает упавшее |
| `install-youtube.sh` | раскладывает всё по порталу, ставит системный прокси, цепляет watchdog к `sber_guard.sh` (автозапуск от bootstarter) |
| `build.sh` | сборка `ytproxy` под `armeabi-v7a` |

Схема:

```
приложение → 127.0.0.1:11088 (ytproxy)
                 ├─ youtube.com / googlevideo.com / *.googleapis.com … → 127.0.0.1:11086 (stunnel, TLS-PSK) → st-ru1.sbrdvc.ru:4433 → SOCKS5 → Интернет
                 └─ всё остальное                                        → прямое TCP-соединение
```

Прокси ставится системным (`settings put global http_proxy 127.0.0.1:11088`),
поэтому им пользуются все приложения, которые вообще уважают системный прокси
(OkHttp, HttpURLConnection, Chromium/WebView). Ничего не пересобирается и не
патчится, сертификаты проверяются как обычно — трафик не расшифровывается.

## Установка

```sh
ANDROID_NDK=~/Library/Android/sdk/ndk/27.1.12297006 ./build.sh
D=127.0.0.1:15555 ./install-youtube.sh ./ytproxy
```

Проверка:

```sh
adb shell 'pidof stube_tunnel; settings get global http_proxy'   # pid и 127.0.0.1:11088
adb shell 'tail -3 /data/local/openstation/yt/ytproxy.log'
```

В логе прокси видно маршрутизацию:

```
proxy: CONNECT www.youtube.com:443 via tunnel
proxy: CONNECT ya.ru:443 via direct
```

## Что проверено на портале

- SmartTube (`org.smarttube.stable`): главная с рекомендациями, поиск, воспроизведение
  (`googlevideo.com` идёт через туннель, звук — `AudioTrack … CONTENT_TYPE_MOVIE`).
- Кинопоиск продолжает работать: его хосты идут «напрямую», плеер открывается.
- StarTube: сеть через туннель работает, но лента пустая — приложение 2023 года
  не разбирает текущие ответы YouTube. Маршрут для него можно не включать.

## Откат

```sh
adb shell 'settings delete global http_proxy'
adb shell 'settings put global http_proxy :0'
adb shell 'kill $(pidof ytproxy); kill $(pidof stube_tunnel)'
adb shell 'sed -i "/youtube_watchdog/d" /data/local/tmp/sber_guard.sh'
```

## Ограничения

- Пока системный прокси включён, весь HTTP(S) приложений идёт через локальный
  процесс. Он не расшифровывает трафик, но если процесс упал — сеть пропадает на
  время до перезапуска watchdog (≤5 с).
- Приложения, которые сами игнорируют системный прокси, идут напрямую как раньше:
  для них ничего не меняется (и YouTube в них не заработает).
- Параметры туннеля (PSK, адрес, порт) берутся из данных StarTube. Если Сбер их
  сменит, скрипт подхватит новые значения при следующем запуске; при смене схемы
  конфиг может потребовать правки. Рабочий адрес можно закрепить в
  `/data/local/openstation/yt/target` (формат `host:port`).
- Рекомендации YouTube зависят от того, откуда выходит прокси Сбера, — логин и
  поиск работают как обычно.
