
#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

# ============================================================
# XRAY AUTO INSTALLER
# VLESS + ML-KEM-768 + REALITY + XHTTP + VISION
# Ubuntu / Debian / systemd
# ============================================================

XRAY_VERSION="${XRAY_VERSION:-26.10.31}"

SERVER_PORT="${SERVER_PORT:-443}"
REALITY_SNI="${REALITY_SNI:-github.com}"
REALITY_TARGET="${REALITY_TARGET:-${REALITY_SNI}:443}"
XHTTP_PATH="${XHTTP_PATH:-/Skalist222/kalach_baza}"

CONFIG_DIR="/usr/local/etc/xray"
CONFIG_PATH="${CONFIG_DIR}/config.json"
XRAY_BIN="/usr/local/bin/xray"

INSTALLER_URL="https://github.com/XTLS/Xray-install/raw/main/install-release.sh"

CREDENTIALS_PATH="/root/xray-client-credentials.json"
CLIENT_ENCRYPTION_PATH="/root/xray-client-encryption.txt"

log() {
    printf '\n[%s] %s\n' "$(date '+%H:%M:%S')" "$*"
}

die() {
    printf '\nERROR: %s\n' "$*" >&2
    exit 1
}

# ============================================================
# 1. SYSTEM CHECK
# ============================================================

[[ "${EUID}" -eq 0 ]] ||
    die "Запусти скрипт от root."

[[ -d /run/systemd/system ]] ||
    die "Не обнаружен systemd."

command -v apt-get >/dev/null ||
    die "Поддерживаются Ubuntu/Debian."

. /etc/os-release

case "${ID:-}" in
    ubuntu|debian) ;;
    *) die "Неподдерживаемая ОС: ${ID:-unknown}." ;;
esac

[[ "$SERVER_PORT" =~ ^[0-9]+$ ]] ||
    die "Некорректный порт."

(( SERVER_PORT >= 1 && SERVER_PORT <= 65535 )) ||
    die "Порт должен быть от 1 до 65535."

[[ "$XHTTP_PATH" =~ ^/[A-Za-z0-9._~/-]*$ ]] ||
    die "Некорректный XHTTP_PATH."

[[ "$REALITY_SNI" =~ ^[A-Za-z0-9.-]+$ ]] ||
    die "Некорректный SNI."

[[ "$REALITY_TARGET" =~ ^[A-Za-z0-9.-]+:[0-9]+$ ]] ||
    die "Некорректный REALITY target."

# Не допускаем случайную ротацию действующих ключей.

if [[ -f "$CONFIG_PATH" && "${FORCE_REPLACE:-0}" != "1" ]]; then
    die "Конфигурация уже существует.
Для осознанной замены запусти:
sudo env FORCE_REPLACE=1 bash $0"
fi

TMP_DIR="$(mktemp -d /tmp/xray-install.XXXXXX)"

cleanup() {
    rm -rf -- "$TMP_DIR"
}

trap cleanup EXIT

# ============================================================
# 2. DEPENDENCIES
# ============================================================

log "Установка системных зависимостей"

apt-get update

DEBIAN_FRONTEND=noninteractive apt-get install -y \
    curl \
    ca-certificates \
    openssl \
    python3 \
    unzip \
    util-linux

# ============================================================
# 3. XRAY INSTALLATION
# ============================================================

log "Установка Xray-core ${XRAY_VERSION}"

curl -fsSL "$INSTALLER_URL" \
    -o "$TMP_DIR/install-release.sh"

bash "$TMP_DIR/install-release.sh" \
    install --version "$XRAY_VERSION"

[[ -x "$XRAY_BIN" ]] ||
    die "Не найден исполняемый файл Xray."

systemctl cat xray >/dev/null 2>&1 ||
    die "Не создана служба xray.service."

XRAY_VERSION_LINE="$("$XRAY_BIN" version | head -n 1)"

echo "$XRAY_VERSION_LINE"

# ============================================================
# 4. GENERATE UUID
# ============================================================

log "Генерация UUID"

UUID_OUTPUT="$("$XRAY_BIN" uuid 2>&1)" ||
    die "Ошибка генерации UUID."

SERVER_UUID="$(
    printf '%s\n' "$UUID_OUTPUT" |
    grep -Eo '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}' |
    head -n 1 || true
)"

[[ "$SERVER_UUID" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] ||
    die "Не удалось получить корректный UUID."

# ============================================================
# 5. GENERATE REALITY KEYS
# ============================================================

log "Генерация REALITY X25519"

REALITY_OUTPUT="$("$XRAY_BIN" x25519 2>&1)" ||
    die "Ошибка генерации REALITY."

REALITY_PRIVATE_KEY="$(
    printf '%s\n' "$REALITY_OUTPUT" |
    awk -F': ' '$1 == "PrivateKey" {print $2; exit}' |
    tr -d '\r'
)"

REALITY_PUBLIC_KEY="$(
    printf '%s\n' "$REALITY_OUTPUT" |
    awk -F': ' '$1 == "Password (PublicKey)" {print $2; exit}' |
    tr -d '\r'
)"

[[ -n "$REALITY_PRIVATE_KEY" ]] ||
    die "REALITY PrivateKey не получен."

[[ -n "$REALITY_PUBLIC_KEY" ]] ||
    die "REALITY PublicKey не получен."

# ============================================================
# 6. GENERATE VLESS ENCRYPTION
# ============================================================

log "Генерация VLESS Encryption"

# Команда генерирует обе пары:
# X25519 и ML-KEM-768.
#
# Используем исключительно ML-KEM-768.
# Encryption и Decryption берём из одного запуска.

VLESSENC_OUTPUT="$("$XRAY_BIN" vlessenc 2>&1)" ||
    die "Ошибка выполнения xray vlessenc."

VLESS_PAIR_JSON="$(
    VLESSENC_OUTPUT="$VLESSENC_OUTPUT" python3 - <<'PY'
import json
import os
import re
import sys

text = os.environ.get("VLESSENC_OUTPUT", "")

text = re.sub(
    r"\x1b\[[0-?]*[ -/]*[@-~]",
    "",
    text
)

marker = re.search(
    r"Authentication:\s*ML-KEM-768,\s*Post-Quantum",
    text,
    flags=re.IGNORECASE
)

if not marker:
    sys.stderr.write(
        "Не найден ML-KEM-768 блок в xray vlessenc.\n"
    )
    sys.exit(2)

section = text[marker.end():]

values = {}

for field in ("decryption", "encryption"):

    match = re.search(
        r'"' + field + r'"\s*:\s*"([^"]+)"',
        section
    )

    if not match:
        sys.stderr.write(
            f"Не найдено поле {field}.\n"
        )
        sys.exit(3)

    values[field] = match.group(1)

if not values["decryption"].startswith(
    "mlkem768x25519plus.native.600s."
):
    sys.exit(4)

if not values["encryption"].startswith(
    "mlkem768x25519plus.native.0rtt."
):
    sys.exit(5)

json.dump(values, sys.stdout)
PY
)" || die "Не удалось получить согласованную ML-KEM-768 пару."

SERVER_DECRYPTION="$(
    printf '%s' "$VLESS_PAIR_JSON" |
    python3 -c 'import json,sys; print(json.load(sys.stdin)["decryption"])'
)"

CLIENT_ENCRYPTION="$(
    printf '%s' "$VLESS_PAIR_JSON" |
    python3 -c 'import json,sys; print(json.load(sys.stdin)["encryption"])'
)"

# ============================================================
# 7. GENERATE REALITY SHORT ID
# ============================================================

log "Генерация REALITY Short ID"

REALITY_SHORT_ID="$(openssl rand -hex 8)"

[[ "$REALITY_SHORT_ID" =~ ^[0-9a-f]{16}$ ]] ||
    die "Некорректный Short ID."

# ============================================================
# 8. DETERMINE XRAY SERVICE USER/GROUP
# ============================================================

SERVICE_USER="$(
    systemctl show xray -p User --value 2>/dev/null || true
)"

SERVICE_GROUP="$(
    systemctl show xray -p Group --value 2>/dev/null || true
)"

[[ -n "$SERVICE_USER" ]] ||
    SERVICE_USER="root"

[[ -n "$SERVICE_GROUP" ]] ||
    SERVICE_GROUP="$(id -gn "$SERVICE_USER")"

getent passwd "$SERVICE_USER" >/dev/null ||
    die "Не найден пользователь службы Xray."

getent group "$SERVICE_GROUP" >/dev/null ||
    die "Не найдена группа службы Xray."

log "Служба Xray работает от ${SERVICE_USER}:${SERVICE_GROUP}"

# ============================================================
# 9. BUILD SERVER CONFIGURATION
# ============================================================

log "Сборка server config.json"

install -d \
    -o root \
    -g "$SERVICE_GROUP" \
    -m 0750 \
    "$CONFIG_DIR"

TMP_CONFIG="$(mktemp "$CONFIG_DIR/config.json.tmp.XXXXXX")"

cat > "$TMP_CONFIG" <<JSON
{
  "log": {
    "loglevel": "info"
  },
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "type": "field",
        "domain": [
          "geosite:category-ads-all"
        ],
        "outboundTag": "block"
      }
    ]
  },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": ${SERVER_PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "email": "main",
            "id": "${SERVER_UUID}",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "${SERVER_DECRYPTION}"
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "target": "${REALITY_TARGET}",
          "xver": 0,
          "serverNames": [
            "${REALITY_SNI}"
          ],
          "privateKey": "${REALITY_PRIVATE_KEY}",
          "shortIds": [
            "${REALITY_SHORT_ID}"
          ]
        },
        "xhttpSettings": {
          "path": "${XHTTP_PATH}",
          "mode": "auto"
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls"
        ]
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    },
    {
      "protocol": "blackhole",
      "tag": "block"
    }
  ],
  "policy": {
    "levels": {
      "0": {
        "handshake": 3,
        "connIdle": 180
      }
    }
  }
}
JSON

chown root:"$SERVICE_GROUP" "$TMP_CONFIG"
chmod 0640 "$TMP_CONFIG"

# ============================================================
# 10. VALIDATE CONFIG
# ============================================================

log "Проверка JSON от имени пользователя службы"

if [[ "$SERVICE_USER" == "root" ]]; then

    XRAY_LOCATION_ASSET="/usr/local/share/xray" \
        "$XRAY_BIN" run -test -c "$TMP_CONFIG"

else

    runuser -u "$SERVICE_USER" -- \
        env XRAY_LOCATION_ASSET="/usr/local/share/xray" \
        "$XRAY_BIN" run -test -c "$TMP_CONFIG"

fi

# ============================================================
# 11. BACKUP AND INSTALL
# ============================================================

BACKUP_PATH=""

if [[ -f "$CONFIG_PATH" ]]; then

    BACKUP_PATH="${CONFIG_PATH}.backup.$(date -u +%Y%m%dT%H%M%SZ)"

    cp -a "$CONFIG_PATH" "$BACKUP_PATH"

    log "Создана резервная копия: $BACKUP_PATH"

fi

for FILE in "$CREDENTIALS_PATH" "$CLIENT_ENCRYPTION_PATH"; do

    if [[ -f "$FILE" ]]; then

        cp -a "$FILE" "${FILE}.backup.$(date -u +%Y%m%dT%H%M%SZ)"

    fi

done

install \
    -o root \
    -g "$SERVICE_GROUP" \
    -m 0640 \
    "$TMP_CONFIG" \
    "$CONFIG_PATH"

# ============================================================
# 12. START XRAY
# ============================================================

log "Запуск службы Xray"

systemctl daemon-reload

if ! systemctl restart xray; then

    echo "Ошибка запуска. Выполняю откат..." >&2

    if [[ -n "$BACKUP_PATH" && -f "$BACKUP_PATH" ]]; then

        install \
            -o root \
            -g "$SERVICE_GROUP" \
            -m 0640 \
            "$BACKUP_PATH" \
            "$CONFIG_PATH"

        systemctl restart xray || true

    else

        rm -f "$CONFIG_PATH"

    fi

    journalctl -u xray -n 80 --no-pager || true

    die "Xray не запустился."

fi

sleep 2

systemctl is-active --quiet xray ||
    die "Служба Xray не активна."

# ============================================================
# 13. SAVE CLIENT CREDENTIALS
# ============================================================

log "Сохранение клиентских параметров"

printf '%s\n' "$CLIENT_ENCRYPTION" \
    > "$CLIENT_ENCRYPTION_PATH"

chmod 0600 "$CLIENT_ENCRYPTION_PATH"

export SERVER_UUID SERVER_PORT CLIENT_ENCRYPTION
export REALITY_PUBLIC_KEY REALITY_SHORT_ID
export REALITY_SNI XHTTP_PATH

python3 - <<'PY'
import json
import os
from pathlib import Path

credentials = {
    "serverAddress": "",
    "port": int(os.environ["SERVER_PORT"]),
    "id": os.environ["SERVER_UUID"],
    "flow": "xtls-rprx-vision",
    "encryption": os.environ["CLIENT_ENCRYPTION"],
    "reality": {
        "serverName": os.environ["REALITY_SNI"],
        "fingerprint": "chrome",
        "publicKey": os.environ["REALITY_PUBLIC_KEY"],
        "shortId": os.environ["REALITY_SHORT_ID"],
        "spiderX": "/"
    },
    "xhttp": {
        "path": os.environ["XHTTP_PATH"],
        "mode": "packet-up"
    }
}

path = Path("/root/xray-client-credentials.json")

path.write_text(
    json.dumps(credentials, indent=2) + "\n",
    encoding="utf-8"
)

os.chmod(path, 0o600)
PY

# ============================================================
# 14. FIREWALL
# ============================================================

log "Проверка UFW"

if command -v ufw >/dev/null 2>&1 &&
   ufw status 2>/dev/null | grep -q "Status: active"; then

    ufw allow "${SERVER_PORT}/tcp"

else

    echo "UFW не активен. Проверь firewall VPS-провайдера."

fi

# ============================================================
# 15. FINAL CHECK
# ============================================================

log "Финальная проверка"

LISTENER="$(
    ss -H -lntp "sport = :${SERVER_PORT}" 2>/dev/null || true
)"

[[ -n "$LISTENER" ]] ||
    die "Порт ${SERVER_PORT} не находится в LISTEN."

echo
echo "========================================"
echo " XRAY INSTALLATION COMPLETED"
echo "========================================"

echo "Version: $XRAY_VERSION_LINE"
echo "Service: $(systemctl is-active xray)"
echo "Port: $SERVER_PORT"
echo "Transport: XHTTP"
echo "Security: REALITY"
echo "Flow: xtls-rprx-vision"
echo "VLESS Authentication: ML-KEM-768"

echo
echo "SERVER CONFIG:"
echo "$CONFIG_PATH"

echo
echo "CLIENT CREDENTIALS:"
echo "$CREDENTIALS_PATH"

echo
echo "CLIENT ENCRYPTION:"
echo "$CLIENT_ENCRYPTION_PATH"

echo
echo "Все UUID и ключи сгенерированы автоматически."
echo "Секретные файлы доступны только root."
echo
echo "Не забудь разрешить TCP $SERVER_PORT"
echo "в firewall панели VPS-провайдера."
install_server.sh
