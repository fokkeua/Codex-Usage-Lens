# Источники usage: реализация и границы

Дата проверки: 26 июля 2026 года.

## Реализованные источники

### 1. Codex app-server — официальный итог

Приложение находит локальный executable Codex, запускает
`codex app-server --stdio` и вызывает стабильный метод:

```json
{ "method": "account/usage/read", "id": 1 }
```

Метод возвращает `lifetimeTokens`, `peakDailyTokens` и дневные
`dailyUsageBuckets`. Используется текущая Codex-backed авторизация; приложение
не читает и не копирует `auth.json`. Клиент намеренно не запрашивает capability
`experimentalApi`: `account/usage/read` и `model/list` используются со
стабильной поверхностью протокола. Одновременно `model/list` получает список
доступных моделей.

Ограничение: account usage не содержит разбивку по модели, input, cache и
output. Поэтому он служит официальным итогом и контрольной суммой.

Источник: <https://learn.chatgpt.com/docs/app-server#7-token-usage-chatgpt>.

### 2. OpenTelemetry JSON — поддерживаемый live-источник

В приложение встроен OTLP/HTTP JSON receiver:

```text
http://127.0.0.1:4319/v1/logs
```

Он привязан только к loopback, принимает тело до 2 МиБ и извлекает только
timestamp, model и token breakdown из канонического завершённого события.
Receiver требует приватный случайный capability в HTTP-заголовке, ограничивает
заголовки, глубину/размер JSON, число записей и число одновременных соединений.
В настройках есть подтверждаемое действие, которое добавляет в пользовательский
`~/.codex/config.toml`:

```toml
[otel]
environment = "codex-usage-lens"
log_user_prompt = false
exporter = { otlp-http = { endpoint = "http://127.0.0.1:4319/v1/logs", protocol = "json", headers = { "x-codex-usage-lens-token" = "<сгенерированный capability>" } } }
```

Capability генерируется приложением и хранится локально с правами `0600`;
placeholder вручную не вводится. Для конкурентно-безопасного первого запуска
готовое 256-bit значение сначала записывается в приватный временный обычный
файл, синхронизируется и только затем атомарно публикуется под окончательным
именем. Поэтому другой экземпляр не может прочитать частично записанный
capability; symbolic links отвергаются. Если `[otel]` уже существует,
приложение ничего не перезаписывает и просит настроить секцию вручную. Точный
старый managed-блок самого Codex Usage Lens без capability тоже не
перезаписывается: его нужно удалить вручную, после чего повторить установку.
Detector разбирает TOML tables, dotted/inline assignments и escapes в quoted
keys. HTTP 200 возвращается только после durable atomic commit принятого
batch; retryable отказ получает 503, а превышение state/disk quota — 507.
После изменения Codex нужно полностью перезапустить.

Источник:
<https://learn.chatgpt.com/docs/config-file/config-advanced#observability-and-telemetry>.

### 3. Локальные rollout — исторический backfill (experimental)

Для истории приложение потоково сканирует
`~/.codex/sessions/**/*.jsonl`. Разбираются только:

- `turn_context.payload.model` и `service_tier`;
- `thread_settings_applied.thread_settings`;
- `token_count.info.last_token_usage`.

Строки сообщений, tool payloads, reasoning text и credentials не
десериализуются. Raw thread/source ID не сохраняются. Для каждого ответа
берётся `last_token_usage`, а не накопительный total. Точные повторы удаляются
по timestamp, модели, tier и token breakdown. Старые записи без модели остаются
`unknown`.

Это рабочий, но не заявленный как стабильный публичный контракт формат.
Поэтому источник в UI помечен как экспериментальный. Scanner принимает только
обычные файлы, не следует по symbolic links и ограничивает число файлов,
суммарный объём, длину строки и количество retained records. Первый полный
проход может быть долгим на большой истории; затем сохраняется watermark и
читаются файлы из небольшого bounded overlap-окна. Exact signatures удаляют
повторы, а overlap не даёт навсегда потерять append при грубой гранулярности
mtime или clock skew. Новый полный `turn_context` всегда сбрасывает прежние
model и service tier до разбора.

### 4. Импорт и demo

Как fallback остаются JSON, JSONL/NDJSON, OTLP JSON, CSV и
детерминированные демонстрационные данные. Импорт ограничен 64 МиБ,
1 МиБ на строку и 100 000 retained records; symbolic links, FIFO и другие
специальные файлы отвергаются.

Перед `JSONSerialization` выполняется единый линейный structural preflight
байтов. JSON принимается только как корректный UTF-8 без BOM; UTF-16/UTF-32
не угадываются и отклоняются. Ограничения применяются ко всему дереву, а не
только к ожидаемому `records`/`usage` envelope:

- каждый массив — не более 100 000 элементов;
- каждый объект — не более 256 полей;
- aggregate budget — не более 2 000 001 structural entry;
- глубина, строки и общий размер также bounded.

Это закрывает обходы через второй envelope key, `null` в первом key,
неиспользуемые и вложенные массивы. Та же проверка запускается для каждого
JSONL/NDJSON-документа и перед materialization распознаваемого embedded JSON в
OTel `body`/`body.stringValue`.

CSV допускает ровно один начальный UTF-8 BOM, строго проверяет quoted-field
state, escaped quotes и CR/LF/CRLF, а aggregate cell budget ограничивается до
создания массива строк. Все token counters и app-server JSON-RPC IDs
проверяются как точные целые лексемы: boolean, дробь, non-finite, overflow и
значение, которое стало целым только после Double rounding, не принимаются.

## Сверка

Дашборд показывает отдельно:

- официальный account usage;
- детализированный local/OTel usage;
- процент покрытия и разницу за доступный дневной bucket.

Расхождение ожидаемо: серверные bucket могут иметь другой timezone, задержку
обновления или более широкий охват, чем локальная история.

## Цены

Отдельного документированного machine-readable pricing API не найдено.
Приложение best effort загружает pricing-карточки официальных страниц Sol,
Terra и Luna, сохраняет URL и время обновления, а при изменении HTML оставляет
предыдущую таблицу. Неизвестные и внутренние модели не оцениваются автоматически.

Показатель всегда называется **API-equivalent**: это ориентир по публичным
API-ставкам, не фактический биллинг и не списание подписки.

Пересекающиеся шаблоны разрешаются одинаково во всём приложении: exact match,
затем самый длинный prefix wildcard, затем `*`; при равной специфичности
сохраняется порядок строк таблицы.

## Локальное хранение

`state.json` и `otel-capability` находятся в
`~/Library/Application Support/CodexUsageMenuBar/`. Каталог принудительно
ограничен правами `0700`, файлы — `0600`; чтение state ограничено 64 МиБ и не
следует по ссылкам. Повреждённый state переносится в quarantine, после чего UI
показывает пустое состояние вместо правдоподобных demo-данных.

`state.json` декодируется с лимитами до materialization элементов массива:
100 000 records, 4 096 цен, 100 известных моделей и 10 000 дневных account
bucket. Те же caps проверяются перед записью; encoded state не может превышать
64 МиБ. Явно сохранённый пустой массив цен round-trip остаётся пустым, а
default prices seed-ятся только при отсутствии state.

Persisted metadata также валидируется: schema version, обязательные поля
records, уникальные UUID цен, bounded model/filename strings, account
counters, уникальные `YYYY-MM-DD` bucket и правдоподобные timestamps. Любая
мутация, для которой быстрый верхний bound недостаточен, проходит
encode-and-atomic-write candidate до изменения in-memory state.

На весь срок жизни процесса только один экземпляр получает неблокирующий
exclusive writer lease. Второй экземпляр может безопасно загрузить обычный
state, но работает read-only, показывает причину в UI и не выполняет
quarantine, initial seed или последующую запись. Writer сохраняет
descriptor-relative: создаёт `O_NOFOLLOW` temporary regular file с `0600`,
выполняет `fsync`, атомарный `renameat` и затем `fsync` каталога. Каталог,
lease и state проверяются как ожидаемые типы файлов, поэтому symlink swap не
используется как путь записи. Bootstrap проходит каждый компонент пути через
descriptor-relative `openat`/`mkdirat`; intermediate symbolic links
отвергаются для state, capability и OTel config.

## Cross-source reconciliation

Точные повторы сначала схлопываются детерминированно, после чего local rollout
и OTel live сопоставляются one-to-one в ограниченном временном окне. Выбор
пары не зависит от входного порядка и не имеет квадратичной сложности.

Bounded in-memory ledger хранит value-signatures уже наблюдавшихся live
записей между последовательными callback, пересопоставляет всё окно при
out-of-order delivery и сохраняет global one-to-one независимо от порядка
batch. Он не содержит raw identifiers, ограничен 100 000 entries и намеренно
сбрасывается при перезапуске процесса.
