# cache-sql — исследование и брейншторм

_Дата: 2026-10-05. Статус: исследование + варианты, решение ещё не принято._

**Идея:** кэш в оперативной памяти с синтаксисом SQL, который берёт лучшее у классических СУБД (язык, планировщик, индексы, протокол, совместимость с драйверами) и у in-memory хранилищ (скорость, TTL, вытеснение, простая эксплуатация).

---

## 1. Карта существующих подходов

### 1.1 Классические дисковые СУБД (PostgreSQL, MySQL)

Архитектура выросла из предположения «данные на диске, RAM мала»:

- **Buffer pool** — страницы на диске, кэш страниц в памяти, доступ через page id → поиск в хэш-таблице → pin/latch.
- **B+-дерево** на страницах, **WAL + ARIES** (redo + undo), блокировки (2PL) или MVCC (PostgreSQL), латчи на страницах.
- **SQL-конвейер:** парсер → анализатор/каталог → оптимизатор (cost-based) → исполнитель (Volcano-итераторы).
- **Протокол** (pgwire / MySQL protocol) и экосистема драйверов, ORM, psql, BI-инструменты — огромная ценность, которую не нужно изобретать.

Ключевой урок — статья «OLTP Through the Looking Glass» (Harizopoulos, Stonebraker и др., SIGMOD 2008): даже если все данные лежат в RAM, классический движок тратит основную часть инструкций на buffer manager, блокировки, латчи и журнал; полезная работа — малая доля. Вывод: **просто положить Postgres в RAM недостаточно — нужна другая архитектура.**

Иллюстрация (любительский бенчмарк, не строгий): Postgres на точечных чтениях ~15 тыс. TPS при ~0.6–0.7 мс, Redis ~0.9 млн rps при p50 ~0.1 мс. Сравнение неравное (pgbench vs redis-benchmark, разная нагрузка), но порядок разницы показателен; unlogged-таблицы на чтение почти ничего не дают.

### 1.2 In-memory СУБД (полноценные, с SQL и транзакциями)

| Система | Что взять |
|---|---|
| **SQL Server Hekaton** | Lock/latch-free индексы (хэш + Bw-tree), оптимистичный MVCC с timestamp-интервалами версий, компиляция процедур в нативный код, **только redo-лог** (индексы не логируются, перестраиваются при восстановлении), кооперативный GC версий |
| **HyPer / Umbra (TUM)** | Компиляция запросов в машинный код (LLVM), снапшоты для OLAP поверх OLTP; Umbra/LeanStore/vmcache — buffer manager со скоростью in-memory (pointer swizzling, variable-size pages) |
| **VoltDB / H-Store** | Разбиение на партиции, **один поток на партицию** без блокировок, хранимые процедуры, долговечность через репликацию + command log |
| **MemSQL / SingleStore** (rowstore) | Lock-free skip lists вместо B-деревьев, MVCC с lock-free списком версий, кодогенерация + кэш планов для параметризованных запросов, групповой асинхронный commit, snapshots + log replay |
| **Tarantool** (memtx) | Однопоточный tx-поток на файберах, WAL + снапшоты, индексы TREE/HASH/RTREE/BITSET, SQL + Lua; отдельный дисковый движок vinyl (LSM) |
| **Apache Ignite / Hazelcast** | Распределённые data grid с SQL (Ignite 3 — на Apache Calcite); тяжёлые JVM-системы, сильные в кластеризации |
| **SQLite `:memory:` / DuckDB** | Встраиваемые: SQLite — построчный OLTP, DuckDB — колоночный векторизованный OLAP. Отличная база для прототипа, но нет TTL/вытеснения/сетевого сервера |

### 1.3 In-memory кэши и KV-хранилища

| Система | Архитектура и уроки |
|---|---|
| **Redis 8** (май 2025, снова open source под AGPLv3 как опция) | Однопоточное исполнение команд + I/O-потоки. В ядро влиты Query Engine (вторичные индексы на hash/JSON, поиск, векторы), JSON, TimeSeries, Bloom/Cuckoo/Top-k/t-digest. Query Engine — **не SQL**, свой синтаксис `FT.SEARCH`. Server-assisted client-side caching (`CLIENT TRACKING`): таблица key → client, режим broadcast по префиксам, OPTIN/OPTOUT, NOLOOP |
| **Valkey** (форк Redis 7.2.4, Linux Foundation, BSD) | 8.0: I/O-потоки разгружают главный поток, но исполнение команд остаётся однопоточным. 9.0: атомарная миграция слотов, expire для полей hash, несколько БД в кластере. AWS/GCP предлагают управляемый Valkey дешевле Redis |
| **Dragonfly** | Shared-nothing: данные разбиты на шарды, у каждого свой поток; stackful-файберы + io_uring; VLL — лёгкие блокировки для мульти-шардовых транзакций; снапшоты **без fork()** (версии записей + асинхронная сериализация — нет удвоения памяти); собственная хэш-таблица DashTable (до −40% памяти). Совместим по протоколу с Redis |
| **Microsoft Garnet** (MIT, C#/.NET) | Хранилище Tsavorite (наследник FASTER): основной store для строк + object store для сложных типов, общий лог операций; обработка на потоке завершения сетевого I/O без перекладывания между потоками; многоуровневое хранение RAM → SSD → облако; неблокирующие чекпоинты; p99.9 < 300 мкс |
| **Memcached** | Slab-аллокатор против фрагментации, LRU по классам слабов, максимально простая модель |

**Алгоритмы вытеснения:** SIEVE (NSDI'24) — проще LRU, на 1559 трассах лучший по miss ratio на >45% трасс, до −63% промахов против ARC; попадание в кэш не требует блокировки → вдвое выше пропускная способность, чем у оптимизированного LRU на 16 потоках. S3-FIFO (SOSP'23) — та же идея «FIFO-очереди достаточно». W-TinyLFU (Caffeine) — частотный фильтр-допуск.

### 1.4 Гибриды «SQL + кэш» (самые близкие к идее)

| Система | Как работает | Ограничения |
|---|---|---|
| **ReadySet** | Wire-совместимый прокси перед Postgres/MySQL. Выбранные SELECT кэшируются и **инкрементально обновляются из репликационного потока** (без ручной инвалидации). Наследник Noria: dataflow + частичная материализация (хранится только «горячая» часть, промахи добираются upquery). Сейчас — dataflow-кэш + TTL-«shallow» кэш | BSL 1.1 (Apache 2.0 через 4 года), eventual consistency, поддерживается подмножество SQL |
| **Noria** (MIT, OSDI'18) | Частично-stateful dataflow, вытеснение и пересчёт по запросу, на Lobsters в 5× быстрее MySQL, в 2–10× быстрее связки MySQL + memcached | Накладные расходы памяти ~3× от базовых таблиц, eventual consistency |
| **Materialize / RisingWave** | Стриминговые инкрементальные материализованные представления на SQL, совместимость с Postgres. Materialize — strict serializable, RisingWave — Apache 2.0 | Это стриминговые БД, а не лёгкий кэш |
| **pg_ivm** | Расширение Postgres для инкрементального обновления MV | Блокирует запись при обновлении, только self-managed |

Трудные для инкрементального поддержания операции: JOIN (нужно сопоставлять с другой таблицей целиком), `COUNT(DISTINCT)` при удалениях, оконные функции.

---

## 2. Белое пятно

```
                     Семантика кэша (TTL, вытеснение, лимит памяти)
                                       ↑
         Redis / Valkey / Dragonfly    |      ← cache-sql?
         Memcached / Garnet            |
  KV / свой синтаксис  ────────────────┼────────────────→  Полноценный SQL
         Redis Query Engine            |      Tarantool, SingleStore, Hekaton
                                       |      SQLite :memory:, DuckDB
                                       |      ReadySet (SQL, но прокси, BSL)
                                       ↓
                           Семантика БД (долговечность, транзакции)
```

Никто не делает **лёгкий open-source сервер с настоящим SQL (pgwire), где TTL, вытеснение и лимит памяти — сущности первого класса**, а не надстройка. Redis даёт кэш-семантику без SQL, Tarantool/SQLite — SQL без кэш-семантики, ReadySet — SQL-кэш, но только как прокси и под BSL.

---

## 3. Брейншторм: варианты продукта

1. **«Redis с таблицами»** — самостоятельный in-memory сервер, pgwire, приложение пишет в него само. `CREATE CACHE TABLE sessions (...) WITH (ttl = '30m', max_memory = '1GB', eviction = 'sieve')`.
2. **SQL-прокси read-through** (ReadySet-lite) — кэширует результаты нормализованных запросов, инвалидирует по logical replication.
3. **«Зеркало в RAM»** — подписка на logical replication Postgres, в память копируются выбранные таблицы/строки (`MIRROR orders WHERE created_at > now() - interval '7 days'`), по ним выполняется любой SELECT локально.
4. **Встраиваемая библиотека** — in-process SQL-кэш для Python/Node (как SQLite `:memory:`, но с TTL/вытеснением) — микросекунды, без сети.
5. **Наоборот — убрать новый движок:** расширение Postgres «cache tables» (unlogged + TTL + фоновое вытеснение). Дёшево, но упирается в оверхед классического движка (см. 1.1).
6. **Модуль Valkey/Redis**, дающий SQL поверх существующих hash/JSON — паразитировать на экосистеме.
7. **SQL client-side caching** — идея `CLIENT TRACKING`, но инвалидация по предикатам: сервер помнит, какой клиент читал `WHERE user_id = 42`, и шлёт инвалидацию при изменении.
8. **Убрать SQL:** может, реальная потребность — «кэш со вторичными индексами и range-запросами», и достаточно подмножества SQL (SELECT/WHERE/ORDER BY/LIMIT по индексам + простые JOIN).

**Мнение:** сильнейшая комбинация — **1 как MVP + 3 как дифференциатор**. Вариант 2 — территория ReadySet, и там самое сложное (корректная инкрементальная инвалидация) уже решено. Вариант 1 реалистичен для одного разработчика, а 3 даёт то, чего нет у Redis: кэш, который сам синхронизируется с Postgres, но позволяет делать произвольные SQL-запросы.

---

## 4. Что взять у каждой стороны

| Из in-memory кэшей | Из in-memory СУБД | Из классических СУБД | От чего отказаться |
|---|---|---|---|
| TTL: ленивое удаление + активная выборочная чистка (Redis) | Нет buffer pool — прямые указатели на строки | SQL-конвейер parse → bind → plan → execute | Страничное хранение и buffer manager |
| Вытеснение SIEVE / S3-FIFO, попадание без блокировки | Индексы: хэш (точечные) + ART/skip list/B+-дерево в памяти (диапазоны) | Протокол pgwire → psql, драйверы, ORM бесплатно | Undo-лог ARIES, 2PL |
| `maxmemory` и точный учёт памяти | Shared-nothing, поток на шард (Dragonfly, VoltDB) **или** MVCC + latch-free (Hekaton) | Prepared statements + кэш планов | Обязательную долговечность — по умолчанию volatile |
| Снапшоты без fork (Dragonfly) | Redo-only лог, индексы не логируются (Hekaton) | `EXPLAIN`, каталог, `information_schema` | Сложный cost-based оптимизатор на старте |
| Пайплайнинг, простая эксплуатация, один бинарник | Кодогенерация / векторизация — позже | Понятная модель изоляции (snapshot для чтения) | |
| Client tracking / инвалидация клиентам | | | |

---

## 5. Допущения и как их проверить

| Допущение | Риск | Самая дешёвая проверка |
|---|---|---|
| Разработчикам нужен SQL в кэше, а не KV | **Высокий** — Redis + ORM-кэш «достаточно хорошо» для многих | 5–10 разговоров с бэкенд-разработчиками: как кэшируют, где болит (инвалидация? сериализация? нет запросов по полям?) |
| SQL через pgwire можно сделать близким к Redis по скорости | **Высокий** — парсинг SQL и протокол дороже, чем RESP | Выходные: SQLite `:memory:` или DuckDB за pgwire (Rust-крейт `pgwire` или Python `riffq`) против Redis и Postgres на точечных чтениях. Цель: ≤2–3× от Redis |
| Синхронизация с Postgres (вариант 3) корректна | Средний — порядок событий, начальная загрузка, DELETE, рестарты | Прототип на `pgoutput` для одной таблицы |
| Одному разработчику по силам | Средний — SQL огромен | Жёстко зафиксировать подмножество SQL для v0.1 |

---

## 6. Возможный план

- **v0.1 (обучение + фундамент):** pgwire-сервер, `CREATE TABLE … WITH (ttl, max_memory)`, INSERT/UPSERT/DELETE, SELECT с WHERE по PK/индексу, ORDER BY + LIMIT; хэш- и упорядоченный индекс; SIEVE; бенчмарк против Redis и Postgres.
- **v0.2:** простые JOIN и агрегаты, prepared statements, кэш планов, снапшот на диск.
- **v0.3 (дифференциатор):** зеркалирование таблиц из Postgres через logical replication.
- **Позже:** шардирование по ядрам, client-side invalidation, кодогенерация.

**Варианты стека:** Rust (`sqlparser-rs`, `pgwire`, опционально DataFusion для планировщика) — быстрее всего до рабочего прототипа; C++ — максимальный контроль и учебная ценность; Go — проще всего, но GC мешает при больших кучах.

---

## 7. Принятые решения (2026-10-05)

- **Цель:** обучение и портфолио. Риск «нужен ли рынку SQL-кэш» уходит на второй план; главный риск теперь — раздутый объём и недоделанный проект.
- **Режим v1:** самостоятельный кэш, приложение пишет в него само. Зеркало Postgres — позже, как «звёздная» фича для портфолио.
- **Язык:** C++20. Ядро (парсер, планировщик, хранилище, протокол) пишется самостоятельно — в этом и учебная ценность. Внутри не используем SQLite/DuckDB.

### Стек
- CMake, C++20, Catch2 или GoogleTest, Google Benchmark, sanitizers (ASan/UBSan/TSan) в CI.
- Сеть: свой event loop на epoll (Linux) / kqueue (macOS) или standalone Asio; io_uring — позже.
- Протокол: pgwire вручную. Simple Query (`Q` → `T`/`D`/`C`/`Z`) — пара сотен строк; Extended Query (Parse/Bind/Execute) обязателен для драйверов вроде node-postgres и psycopg 3 с параметрами.
- Парсер: ручной рекурсивный спуск + Pratt-парсер выражений. Альтернатива для сравнения — libpg_query (настоящий парсер Postgres как C-библиотека).
- Память: учёт через собственный аллокатор/арены на таблицу или статистику jemalloc/mimalloc.

### Вехи
| Веха | Результат | Критерий готовности |
|---|---|---|
| M0 Каркас | Event loop, startup/auth (trust), Simple Query | `psql -h localhost -p 5433` → `SELECT 1` работает |
| M1 Таблицы | Каталог, `CREATE TABLE`, `INSERT`, `SELECT … WHERE pk = …`, хэш-индекс по PK; типы INT/BIGINT/DOUBLE/BOOL/TEXT/TIMESTAMP | Юнит-тесты + сценарий в psql |
| M2 Кэш-семантика | TTL на таблицу и строку, ленивое + активное истечение, `max_memory` + SIEVE, `UPDATE`/`DELETE` | Тест на вытеснение под нагрузкой, учёт памяти ±10% |
| M3 Диапазоны | Упорядоченный индекс (B+-дерево в памяти или skip list), `WHERE` с диапазонами, `ORDER BY … LIMIT`, `EXPLAIN` | Планировщик выбирает индекс вместо полного прохода |
| M4 Бенчмарк | pgbench с собственным скриптом против Postgres, redis-benchmark/memtier против Redis, flamegraph | README с графиками и разбором узких мест |
| M5 Драйверы | Extended Query, prepared statements, кэш планов | Работают psycopg 3 и node-postgres с параметрами |
| M6+ | Снапшоты на диск без остановки, shard-per-core, простые JOIN/агрегаты, зеркало Postgres через logical replication | — |

Однопоточное исполнение в стиле Redis на M0–M5, затем переход на shard-per-core (как в Dragonfly) с замером «до и после» — это сильная история для портфолио.

---

## Источники

- [Dragonfly — in-memory data landscape на конец 2025](https://www.dragonflydb.io/blog/in-memory-data-landscape-at-the-end-of-2025)
- [Dragonfly — сравнение архитектур Redis и Dragonfly](https://dragonflydb.io/blog/redis-and-dragonfly-architecture-comparison)
- [Redis 8 GA](https://redis.io/blog/redis-8-ga/)
- [Redis server-assisted client-side caching](https://redis.antirez.com/fundamental/client-side-caching.html)
- [Microsoft Garnet README](https://cdn.jsdelivr.net/gh/microsoft/garnet@main/README.md)
- [ReadySet на GitHub](https://github.com/readysettech/readyset) · [Thoughtworks Radar — ReadySet](https://thoughtworks.com/radar/tools/readyset)
- [Noria (разбор, The Morning Paper)](https://blog.acolyer.org/2018/10/29/noria-dynamic-partially-stateful-data-flow-for-high-performance-web-applications/) · [Noria, OSDI'18](https://www.usenix.org/conference/osdi18/presentation/gjengset)
- [Hekaton (разбор)](https://yizhang82.dev/hekaton) · [Hekaton paper](https://web.eecs.umich.edu/~mozafari/fall2015/eecs584/papers/hekaton.pdf)
- [HyPer paper](https://cs.uwaterloo.ca/~david/cs848/papers/HyPer:%20A%20Hybrid%20OLTP%20and%20OLAP%20Main%20Memory%20Database%20System%20Based%20on%20Virtual%20Memory%20Snapshots.pdf) · [vmcache](https://www.cs.cit.tum.de/fileadmin/w00cfj/dis/_my_direct_uploads/vmcache.pdf) · [LeanStore](https://github.com/leanstore/leanstore)
- [OLTP Through the Looking Glass (разбор)](https://sookocheff.com/post/databases/oltp-through-the-looking-glass/)
- [MemSQL architecture](https://highscalability.com/memsql-architecture-the-fast-mvcc-inmem-lockfree-codegen-and/)
- [Tarantool: memtx vs vinyl](https://www.tarantool.io/en/doc/latest/platform/engines/memtx_vinyl_diff/)
- [Apache Ignite 3: Calcite, Raft, LSM](https://www.gridgain.com/resources/blog/apache-ignite-3-alpha-3-apache-calcite-raft-and-lsm-tree)
- [SIEVE, NSDI'24](https://usenix.org/conference/nsdi24/presentation/zhang-yazhuo)
- [Инкрементальные материализованные представления (RisingWave)](https://risingwave.com/blog/incremental-materialized-views-complete-guide/)
- [Бенчмарк Redis vs Postgres для кэша](https://github.com/raphaeldelio/redis-postgres-cache-benchmark)
- [Крейт pgwire](https://docs.rs/crate/pgwire/) · [riffq (pgwire для Python)](https://pypi.org/project/riffq/)
- [DuckDB vs SQLite](https://motherduck.com/learn/duckdb-vs-sqlite-databases/)
