# Link & Bring Messenger

Исходники мобильного мессенджера для код-ревью. Здесь лежат Flutter-экраны чатов, опрос событий, Dart API переписки, SQL-миграция для PostgreSQL и тесты мессенджера.

## Что смотреть

- [Экраны, отправка и история](app/lib/messaging.dart)
- [Опрос входящих событий](app/lib/inbox_poller.dart)
- [Маршруты и транзакции](server/lib/messaging_api.dart)
- [Индекс для непрочитанных событий](server/sql/008_inbox_unread_index.sql)

## Проверка в мобильном приложении

Файлы мессенджера сняты с проверенного коммита интеграции `1fa8523`. Патч предназначен для исходного Link & Bring на коммите `2243ed6`. Он включает точечное подключение к существующей навигации и настройку тестового мок-клиента.

1. Скачайте [mobile-messenger.patch](mobile-messenger.patch) и в копии исходного Link & Bring выполните `git apply --check /path/to/mobile-messenger.patch`, затем `git apply /path/to/mobile-messenger.patch`.
2. Запустите штатный Dart API с PostgreSQL и примените миграции через `psql`, включая `008_inbox_unread_index.sql`.
3. В каталоге `app` выполните `flutter test` и `flutter build apk --debug`.

Проверки интеграции охватили сборку Android APK, Flutter-тесты и отправку, повтор и прочтение сообщений через штатный API с PostgreSQL.
