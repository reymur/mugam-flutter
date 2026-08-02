# Сироты в Storage — список к удалению

Режим прогона: **только отчёт, до удаления**

Сохранено до удаления, чтобы через месяц было с чем сверяться, если
окажется, что что-то пропало. Сирота здесь — объект, на который не
ссылается ни один документ во всей базе и который старше окна
ожидания (24 ч). Как это считается — см. functions/src/orphanSweep.ts.

| Показатель | Значение |
|---|---|
| Объектов в подметаемых префиксах | 76 |
| Документов просмотрено (вся база) | 805 |
| Ссылок на объекты найдено | 47 |
| Пропущено как моложе окна | 2 |
| Сирот | 36 на 112.3 МБ |
| Всего в бакете на момент прогона | 82 объектов, 160.0 МБ |

| Создан | Размер | Путь |
|---|---|---|
| 2026-07-31T09:18:20.652Z | 2.1 МБ | `chats/1IBr5oqcHCUZRpkpE4lGyPAKBNn2_6s4Ffvkh8zQJDnxFakJJMfpmqLG3/ZBUgZNagvVxMdKMSNVIS.mp4` |
| 2026-07-16T07:37:33.966Z | 4.8 МБ | `statuses/1IBr5oqcHCUZRpkpE4lGyPAKBNn2/1784187133230324_0.mp4` |
| 2026-07-16T07:37:51.335Z | 4.8 МБ | `statuses/1IBr5oqcHCUZRpkpE4lGyPAKBNn2/1784187459493354_30000.mp4` |
| 2026-07-16T07:38:34.669Z | 4.8 МБ | `statuses/1IBr5oqcHCUZRpkpE4lGyPAKBNn2/1784187510843951_60000.mp4` |
| 2026-07-16T07:38:52.599Z | 4.8 МБ | `statuses/1IBr5oqcHCUZRpkpE4lGyPAKBNn2/1784187528692164_0.mp4` |
| 2026-07-16T07:38:59.569Z | 4.8 МБ | `statuses/1IBr5oqcHCUZRpkpE4lGyPAKBNn2/1784187535041922_30000.mp4` |
| 2026-07-16T07:39:09.676Z | 4.8 МБ | `statuses/1IBr5oqcHCUZRpkpE4lGyPAKBNn2/1784187541346015_60000.mp4` |
| 2026-07-16T08:48:05.283Z | 4.8 МБ | `statuses/1IBr5oqcHCUZRpkpE4lGyPAKBNn2/1784191665728972_30000.mp4` |
| 2026-07-16T08:48:00.087Z | 2.0 МБ | `statuses/1IBr5oqcHCUZRpkpE4lGyPAKBNn2/1784191666951377_60000.mp4` |
| 2026-07-16T08:47:52.541Z | 4.8 МБ | `statuses/1IBr5oqcHCUZRpkpE4lGyPAKBNn2/1784191668466186_0.mp4` |
| 2026-07-16T09:22:27.604Z | 4.8 МБ | `statuses/1IBr5oqcHCUZRpkpE4lGyPAKBNn2/1784193744256241_0.mp4` |
| 2026-07-16T09:22:28.959Z | 4.8 МБ | `statuses/1IBr5oqcHCUZRpkpE4lGyPAKBNn2/1784193745739820_30000.mp4` |
| 2026-07-16T09:22:30.770Z | 4.8 МБ | `statuses/1IBr5oqcHCUZRpkpE4lGyPAKBNn2/1784193747228449_60000.mp4` |
| 2026-07-16T09:22:32.249Z | 4.8 МБ | `statuses/1IBr5oqcHCUZRpkpE4lGyPAKBNn2/1784193748702480_90000.mp4` |
| 2026-07-16T09:22:34.175Z | 4.8 МБ | `statuses/1IBr5oqcHCUZRpkpE4lGyPAKBNn2/1784193750189188_120000.mp4` |
| 2026-07-16T09:22:35.479Z | 3.3 МБ | `statuses/1IBr5oqcHCUZRpkpE4lGyPAKBNn2/1784193751245124_150000.mp4` |
| 2026-07-16T09:45:40.483Z | 4.8 МБ | `statuses/1IBr5oqcHCUZRpkpE4lGyPAKBNn2/1784195135263838_0.mp4` |
| 2026-07-16T09:45:43.774Z | 4.8 МБ | `statuses/1IBr5oqcHCUZRpkpE4lGyPAKBNn2/1784195136751680_30000.mp4` |
| 2026-07-16T09:45:53.338Z | 4.8 МБ | `statuses/1IBr5oqcHCUZRpkpE4lGyPAKBNn2/1784195138240987_60000.mp4` |
| 2026-07-16T09:45:55.602Z | 3.3 МБ | `statuses/1IBr5oqcHCUZRpkpE4lGyPAKBNn2/1784195143669530_150000.mp4` |
| 2026-07-16T09:47:37.677Z | 4.8 МБ | `statuses/1IBr5oqcHCUZRpkpE4lGyPAKBNn2/1784195252541851_90000.mp4` |
| 2026-07-16T09:47:39.491Z | 4.8 МБ | `statuses/1IBr5oqcHCUZRpkpE4lGyPAKBNn2/1784195254030602_120000.mp4` |
| 2026-07-16T10:08:56.746Z | 4.8 МБ | `statuses/1IBr5oqcHCUZRpkpE4lGyPAKBNn2/1784196526537804_90000.mp4` |
| 2026-07-23T20:43:04.944Z | 4.8 МБ | `statuses/6s4Ffvkh8zQJDnxFakJJMfpmqLG3/1784839366206990_0.mp4` |
| 2026-07-23T20:44:30.931Z | 4.8 МБ | `statuses/6s4Ffvkh8zQJDnxFakJJMfpmqLG3/1784839396342115_150000.mp4` |
| 2026-07-14T07:02:40.823Z | 0.1 МБ | `statuses/LPSnzpV63mgrNc93sKilVpoUvdq2/1784012558095528.jpg` |
| 2026-07-14T07:02:52.119Z | 0.1 МБ | `statuses/LPSnzpV63mgrNc93sKilVpoUvdq2/1784012569206890.jpg` |
| 2026-07-14T07:03:01.274Z | 0.1 МБ | `statuses/LPSnzpV63mgrNc93sKilVpoUvdq2/1784012579033277.jpg` |
| 2026-07-14T07:09:23.737Z | 0.0 МБ | `statuses/LPSnzpV63mgrNc93sKilVpoUvdq2/1784012961071421.jpg` |
| 2026-07-14T07:09:31.900Z | 0.0 МБ | `statuses/LPSnzpV63mgrNc93sKilVpoUvdq2/1784012969868341.jpg` |
| 2026-07-14T07:09:36.502Z | 0.0 МБ | `statuses/LPSnzpV63mgrNc93sKilVpoUvdq2/1784012974417317.jpg` |
| 2026-07-14T07:09:45.876Z | 0.0 МБ | `statuses/LPSnzpV63mgrNc93sKilVpoUvdq2/1784012982758918.jpg` |
| 2026-07-14T07:13:19.905Z | 0.0 МБ | `statuses/LPSnzpV63mgrNc93sKilVpoUvdq2/1784013197359692.jpg` |
| 2026-07-14T07:13:25.873Z | 0.0 МБ | `statuses/LPSnzpV63mgrNc93sKilVpoUvdq2/1784013203579005.jpg` |
| 2026-07-14T07:13:30.178Z | 0.0 МБ | `statuses/LPSnzpV63mgrNc93sKilVpoUvdq2/1784013208157701.jpg` |
| 2026-07-14T07:13:53.092Z | 0.1 МБ | `statuses/LPSnzpV63mgrNc93sKilVpoUvdq2/1784013231177692.jpg` |
## Итог прогона 02.08

Удалены все 36 объектов, ошибок удаления — 0.

| | До | После |
|---|---|---|
| Объектов в бакете | 82 | 46 |
| Объём | 160.0 МБ | 47.7 МБ |

Освобождено 112.3 МБ — 70% всего Storage проекта.

Повторный полный прогон сразу после удаления: сирот 0, документов
просмотрено те же 805, ссылок 47. Два объекта моложе суток остались
неотсмотренными по возрасту — это штатно, их разберёт следующий прогон.

Durable-след обоих прогонов (до и после) лежит в
`maintenance/orphanSweep/runs` со всеми 36 путями — Cloud Logging хранит
записи 30 дней, а этот файл и та коллекция живут столько же, сколько
проект.
