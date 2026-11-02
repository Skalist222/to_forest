# to_forest

Автоматический установщик Xray-core.

**VLESS + ML-KEM-768 + REALITY + XHTTP + Vision**

## Что делает установщик?

1. Устанавливает Xray-core версии 26.10.31.
2. Автоматически генерирует UUID.
3. Генерирует REALITY X25519 Private Key и Public Key.
4. Генерирует согласованную пару VLESS Encryption (ML-KEM-768).
5. Генерирует REALITY Short ID.
6. Создаёт серверный JSON.
7. Проверяет конфигурацию.
8. Запускает Xray через systemd.
9. Сохраняет клиентские параметры.

## Что появится после установки?

| Файл | Назначение |
|---|---|
| `/usr/local/etc/xray/config.json` | Серверная конфигурация |
| `/root/xray-client-credentials.json` | Клиентские параметры |
| `/root/xray-client-encryption.txt` | VLESS Encryption |

## Требования

- Ubuntu / Debian
- systemd
- Root-доступ
- Открытый TCP-порт 443
- Доступ к GitHub

## Установка глобальной команды

Устанавливаем загрузчик:

```bash
apt-get update
apt-get install -y curl

TMP_FILE=$(mktemp)

curl -fsSL \
"https://raw.githubusercontent.com/Skalist222/to_forest/main/install.sh" \
-o "$TMP_FILE"

install -m 0755 "$TMP_FILE" /usr/local/bin/to_forest

rm -f "$TMP_FILE"
```

## Запуск установки

```bash
to_forest
```

## Повторная установка

Если серверная конфигурация уже существует, установщик остановится для защиты действующих ключей.

Для принудительной генерации новой конфигурации:

```bash
env FORCE_REPLACE=1 to_forest
```

**Внимание:** при этом старые клиентские ключи перестанут работать.

## Проверка работы

```bash
systemctl status xray
```

Проверка конфигурации:

```bash
xray run -test -c /usr/local/etc/xray/config.json
```

Просмотр журнала:

```bash
journalctl -u xray -f
```

## Firewall

Необходимо разрешить входящие TCP-соединения на порт 443 в firewall VPS-провайдера.

## Репозиторий

https://github.com/Skalist222/to_forest

---

*Проект находится в разработке. Перед использованием на производственных серверах рекомендуется проверять актуальность установщика и тестировать его на чистом VPS.*
