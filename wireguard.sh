#!/usr/bin/env bash
# Установка WireGuard в Docker и интерактивное управление клиентскими профилями.
# Запуск: sudo wg

set -Eeuo pipefail

BASE_DIR="/opt/wireguard"
SCRIPT_PATH="/usr/local/sbin/wireguard.sh"
WG_COMMAND="/usr/local/bin/wg"
COMPOSE_FILE="$BASE_DIR/compose.yaml"
ENV_FILE="$BASE_DIR/.env"
CONFIG_DIR="$BASE_DIR/config"
SERVICE="wireguard"
LOCK_FILE="/run/lock/wireguard-manager.lock"
WAIT_ATTEMPTS=45
WAIT_INTERVAL=1

die() {
  printf 'Ошибка: %s\n' "$*" >&2
  exit 1
}

require_root() {
  [[ "$EUID" -eq 0 ]] || die "запусти скрипт от root: sudo wg или sudo $SCRIPT_PATH"
}

install_wg_command() {
  local temporary
  local marker='# WireGuard manager launcher managed by wireguard.sh'

  if [[ ! -x "$SCRIPT_PATH" ]]; then
    printf 'Не удалось создать команду wg: установи скрипт в %s.\n' "$SCRIPT_PATH" >&2
    return 0
  fi

  if [[ -e "$WG_COMMAND" || -L "$WG_COMMAND" ]]; then
    if [[ -L "$WG_COMMAND" && "$(readlink -f "$WG_COMMAND" 2>/dev/null || true)" == "$(readlink -f "$SCRIPT_PATH")" ]]; then
      : # Replace an older direct symlink with the launcher below.
    elif grep -Fq "$marker" "$WG_COMMAND" 2>/dev/null; then
      return 0
    else
      printf 'Команда %s уже существует и не принадлежит этому скрипту. Оставляю её без изменений; запускай меню через sudo %s.\n' \
        "$WG_COMMAND" "$SCRIPT_PATH" >&2
      return 0
    fi
  fi

  install -d -o root -g root -m 0755 "$(dirname "$WG_COMMAND")"
  temporary="$(mktemp "$(dirname "$WG_COMMAND")/.wg.XXXXXX")"
  cat > "$temporary" <<EOF
#!/usr/bin/env bash
$marker
if ((\$# > 0)); then
  for candidate in /usr/bin/wg /bin/wg; do
    if [[ -x "\$candidate" ]]; then
      exec "\$candidate" "\$@"
    fi
  done
  printf 'Системная команда WireGuard wg не найдена.\n' >&2
  exit 127
fi
exec $SCRIPT_PATH
EOF
  chown root:root "$temporary"
  chmod 0755 "$temporary"

  if [[ -e "$WG_COMMAND" || -L "$WG_COMMAND" ]]; then
    mv -f -- "$temporary" "$WG_COMMAND"
  elif ! ln -- "$temporary" "$WG_COMMAND"; then
    rm -f -- "$temporary"
    printf 'Не удалось создать команду %s; запускай меню через sudo %s.\n' \
      "$WG_COMMAND" "$SCRIPT_PATH" >&2
    return 0
  else
    rm -f -- "$temporary"
  fi

  printf 'Команда для открытия меню: sudo wg.\n'
}

acquire_lock() {
  command -v flock >/dev/null 2>&1 || die "не найдена команда flock из пакета util-linux"
  exec 9>"$LOCK_FILE"
  flock -n 9 || die "уже запущен другой экземпляр wireguard.sh; дождись его завершения"
}

check_ubuntu_2404() {
  local ID VERSION_ID
  [[ -r /etc/os-release ]] || die "не удалось определить версию Linux"
  # shellcheck disable=SC1091
  . /etc/os-release
  [[ "${ID:-}" == ubuntu && "${VERSION_ID:-}" == "24.04" ]] || \
    die "первичная установка поддерживается этим скриптом на Ubuntu 24.04"
}

add_docker_repository() {
  local UBUNTU_CODENAME VERSION_CODENAME
  apt-get update
  apt-get install -y ca-certificates curl
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc

  # shellcheck disable=SC1091
  . /etc/os-release
  cat > /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
    Suites: ${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF
  apt-get update
}

installed_docker_conflicts() {
  local package status
  local -a conflicts=()
  local -a packages=(
    docker.io docker-compose docker-compose-v2 docker-doc
    docker-buildx podman-docker containerd runc
  )

  for package in "${packages[@]}"; do
    # Keep the dpkg format string literal; dpkg, not Bash, expands it.
    # shellcheck disable=SC2016
    status="$(dpkg-query -W -f='${db:Status-Status}' "$package" 2>/dev/null || true)"
    [[ "$status" == installed ]] && conflicts+=("$package")
  done

  (IFS=', '; printf '%s' "${conflicts[*]}")
}

refuse_conflicting_docker_packages() {
  local conflicts
  conflicts="$(installed_docker_conflicts)"
  [[ -z "$conflicts" ]] || die "обнаружены конфликтующие пакеты Docker: $conflicts. Скрипт не удаляет их автоматически, чтобы не остановить другие контейнеры. Проверь текущую установку Docker и устрани конфликт вручную, затем запусти скрипт снова"
}

install_docker_if_needed() {
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    printf 'Использую установленный Docker Engine и Compose.\n'
  elif command -v docker >/dev/null 2>&1; then
    refuse_conflicting_docker_packages
    printf 'Устанавливаю плагин Docker Compose...\n'
    add_docker_repository
    apt-get install -y docker-compose-plugin
  else
    refuse_conflicting_docker_packages
    printf 'Устанавливаю Docker Engine и Compose из официального репозитория Docker...\n'
    add_docker_repository
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  fi

  systemctl enable --now docker
  docker compose version >/dev/null 2>&1 || die "Docker Compose не установлен или не запускается"
}

get_peers() {
  [[ -f "$ENV_FILE" ]] || return 0
  awk -F= '$1 == "PEERS" { print substr($0, index($0, "=") + 1); exit }' "$ENV_FILE"
}

get_peer_dns() {
  [[ -f "$ENV_FILE" ]] || return 0
  awk -F= '$1 == "PEERDNS" { print substr($0, index($0, "=") + 1); exit }' "$ENV_FILE"
}

set_peer_dns() {
  local value="$1"
  local temporary
  touch "$ENV_FILE"
  temporary="$(mktemp "$BASE_DIR/.env.XXXXXX")"
  awk -v value="$value" '
    BEGIN { updated = 0 }
    /^PEERDNS=/ {
      if (!updated) print "PEERDNS=" value
      updated = 1
      next
    }
    { print }
    END { if (!updated) print "PEERDNS=" value }
  ' "$ENV_FILE" > "$temporary"
  chmod 600 "$temporary"
  mv -f "$temporary" "$ENV_FILE"
}

validate_peers() {
  local value="$1"
  local item
  local index previous_index
  local -a items=()

  [[ -n "$value" ]] || die "список клиентских профилей пуст"
  IFS=',' read -r -a items <<< "$value"
  for ((index = 0; index < ${#items[@]}; index++)); do
    item="${items[index]}"
    [[ "$item" =~ ^[a-zA-Z0-9]+$ ]] || die "имя '$item' должно содержать только латинские буквы и цифры"
    for ((previous_index = 0; previous_index < index; previous_index++)); do
      [[ "${items[previous_index]}" != "$item" ]] || die "имя '$item' повторяется"
    done
  done
  ((${#items[@]} > 0)) || die "список клиентских профилей пуст"
}

validate_peer_dns() {
  local value="$1"
  local item previous_index index
  local -a servers=()

  [[ "$value" == auto ]] && return 0
  IFS=',' read -r -a servers <<< "$value"
  if ((${#servers[@]} < 1 || ${#servers[@]} > 3)); then
    printf 'Укажи auto или от одного до трёх IPv4-адресов DNS через запятую.\n' >&2
    return 1
  fi

  for ((index = 0; index < ${#servers[@]}; index++)); do
    item="${servers[index]}"
    [[ "$item" =~ ^[0-9.]+$ ]] && is_valid_server_url "$item" && \
      [[ "$item" != 0.0.0.0 && "$item" != 255.255.255.255 ]] || {
      printf 'Некорректный IPv4-адрес DNS: %s\n' "$item" >&2
      return 1
    }
    for ((previous_index = 0; previous_index < index; previous_index++)); do
      if [[ "${servers[previous_index]}" == "$item" ]]; then
        printf 'DNS-адрес %s указан повторно.\n' "$item" >&2
        return 1
      fi
    done
  done
  return 0
}

is_valid_server_url() {
  local host="$1"
  local label octet
  local -a labels=() octets=()

  ((${#host} > 0 && ${#host} <= 253)) || return 1

  if [[ "$host" =~ ^[0-9.]+$ ]]; then
    IFS='.' read -r -a octets <<< "$host"
    ((${#octets[@]} == 4)) || return 1
    for octet in "${octets[@]}"; do
      [[ "$octet" =~ ^[0-9]{1,3}$ ]] || return 1
      ((10#$octet <= 255)) || return 1
    done
    return 0
  fi

  [[ "$host" != .* && "$host" != *. && "$host" != *..* ]] || return 1
  IFS='.' read -r -a labels <<< "$host"
  for label in "${labels[@]}"; do
    ((${#label} <= 63)) || return 1
    [[ "$label" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] || return 1
  done
}

set_peers() {
  local value="$1"
  local temporary
  touch "$ENV_FILE"
  temporary="$(mktemp "$BASE_DIR/.env.XXXXXX")"
  awk -v value="$value" '
    BEGIN { updated = 0 }
    /^PEERS=/ {
      if (!updated) print "PEERS=" value
      updated = 1
      next
    }
    { print }
    END { if (!updated) print "PEERS=" value }
  ' "$ENV_FILE" > "$temporary"
  chmod 600 "$temporary"
  mv -f "$temporary" "$ENV_FILE"
}

replace_compose_peers_reference() {
  local backup temporary
  grep -Eq '^[[:space:]]*PEERS:' "$COMPOSE_FILE" || \
    die "в compose.yaml нет параметра PEERS; проверь конфигурацию вручную"

  # Match the Compose interpolation literally; it must not expand in Bash.
  # shellcheck disable=SC2016
  if grep -F 'PEERS:' "$COMPOSE_FILE" | grep -Fq '${PEERS'; then
    return 0
  fi

  backup="$COMPOSE_FILE.bak.$(date +%Y%m%d%H%M%S)"
  cp -a "$COMPOSE_FILE" "$backup"
  temporary="$(mktemp "$BASE_DIR/compose.yaml.XXXXXX")"
  awk '
    /^[[:space:]]*PEERS:/ {
      match($0, /^[[:space:]]*/)
      print substr($0, RSTART, RLENGTH) "PEERS: \"${PEERS}\""
      next
    }
    { print }
  ' "$COMPOSE_FILE" > "$temporary"
  chmod 600 "$temporary"
  mv -f "$temporary" "$COMPOSE_FILE"
  printf 'Обновил PEERS в compose.yaml; резервная копия: %s\n' "$backup"
}

replace_compose_peer_dns_reference() {
  local backup temporary
  grep -Eq '^[[:space:]]*PEERDNS:' "$COMPOSE_FILE" || \
    die "в compose.yaml нет параметра PEERDNS; проверь конфигурацию вручную"

  # Keep the Compose interpolation literal so it is expanded from .env.
  # shellcheck disable=SC2016
  if grep -F 'PEERDNS:' "$COMPOSE_FILE" | grep -Fq '${PEERDNS'; then
    return 0
  fi

  backup="$COMPOSE_FILE.bak.peerdns.$(date +%Y%m%d%H%M%S)"
  cp -a "$COMPOSE_FILE" "$backup"
  temporary="$(mktemp "$BASE_DIR/compose.yaml.XXXXXX")"
  awk '
    /^[[:space:]]*PEERDNS:/ {
      match($0, /^[[:space:]]*/)
      print substr($0, RSTART, RLENGTH) "PEERDNS: \"${PEERDNS}\""
      next
    }
    { print }
  ' "$COMPOSE_FILE" > "$temporary"
  chmod 600 "$temporary"
  mv -f "$temporary" "$COMPOSE_FILE"
  printf 'Перевёл PEERDNS в compose.yaml на настройку из .env; резервная копия: %s\n' "$backup"
}

compose() {
  (cd "$BASE_DIR" && docker compose "$@")
}

compose_up() {
  compose up -d --force-recreate "$SERVICE"
}

rollback_peers() {
  local old_value="$1"
  printf 'Возвращаю прежний список клиентов...\n' >&2
  set_peers "$old_value"
  if ! compose_up || ! verify_wireguard; then
    printf 'Не удалось подтвердить восстановление прежнего состояния. Логи контейнера:\n' >&2
    show_wireguard_logs
  fi
}

wait_for_profile() {
  local name="$1"
  local attempt
  for ((attempt = 1; attempt <= WAIT_ATTEMPTS; attempt++)); do
    [[ -f "$CONFIG_DIR/peer_$name/peer_$name.conf" ]] && return 0
    sleep "$WAIT_INTERVAL"
  done
  return 1
}

verify_wireguard() {
  local attempt
  for ((attempt = 1; attempt <= WAIT_ATTEMPTS; attempt++)); do
    if compose exec -T "$SERVICE" wg show wg0 >/dev/null 2>&1; then
      return 0
    fi
    sleep "$WAIT_INTERVAL"
  done
  return 1
}

show_wireguard_logs() {
  compose logs --tail 80 "$SERVICE" >&2 || true
}

show_peer_qr() {
  local name="$1"
  compose exec "$SERVICE" /app/show-peer "$name"
}

list_peers() {
  local peers
  peers="$(get_peers)"
  validate_peers "$peers"
  printf 'Профили: %s\n' "${peers//,/  }"
}

add_peer() {
  local name old_value new_value item
  local -a current=()

  read -r -p 'Имя нового устройства (латиница и цифры): ' name
  [[ "$name" =~ ^[a-zA-Z0-9]+$ ]] || { printf 'Допустимы только латинские буквы и цифры.\n'; return; }
  old_value="$(get_peers)"
  validate_peers "$old_value"
  IFS=',' read -r -a current <<< "$old_value"
  for item in "${current[@]}"; do
    if [[ "$item" == "$name" ]]; then
      printf 'Профиль %s уже есть.\n' "$name"
      return
    fi
  done

  new_value="$old_value,$name"
  set_peers "$new_value"
  if ! compose_up; then
    rollback_peers "$old_value"
    return
  fi
  if ! verify_wireguard; then
    printf 'Интерфейс WireGuard не запустился после добавления профиля. Логи контейнера:\n' >&2
    show_wireguard_logs
    rollback_peers "$old_value"
    return
  fi
  if ! wait_for_profile "$name"; then
    printf 'Файл нового профиля не появился.\n' >&2
    rollback_peers "$old_value"
    return
  fi

  printf '\nПрофиль создан. Отсканируй QR-код приложением WireGuard.\n'
  printf 'Файл профиля: %s/peer_%s/peer_%s.conf\n' "$CONFIG_DIR" "$name" "$name"
  show_peer_qr "$name" || printf 'Не удалось вывести QR-код. Покажи его повторно пунктом 3 меню.\n' >&2
}

remove_peer() {
  local name old_value new_value item confirmation found=0
  local -a current=() remaining=()

  list_peers
  old_value="$(get_peers)"
  IFS=',' read -r -a current <<< "$old_value"
  if ((${#current[@]} <= 1)); then
    printf 'Нельзя удалить последний профиль. Для полного удаления выбери пункт 7.\n'
    return
  fi

  read -r -p 'Имя профиля для отзыва: ' name
  [[ "$name" =~ ^[a-zA-Z0-9]+$ ]] || { printf 'Недопустимое имя.\n'; return; }
  for item in "${current[@]}"; do
    if [[ "$item" == "$name" ]]; then found=1; else remaining+=("$item"); fi
  done
  if ((found == 0)); then
    printf 'Профиль %s не найден.\n' "$name"
    return
  fi

  read -r -p "Для отзыва профиля введи его имя '$name': " confirmation
  [[ "$confirmation" == "$name" ]] || { printf 'Отменено.\n'; return; }

  new_value="$(IFS=,; printf '%s' "${remaining[*]}")"
  set_peers "$new_value"
  if ! compose_up; then
    rollback_peers "$old_value"
    return
  fi
  if ! verify_wireguard; then
    printf 'Интерфейс WireGuard не запустился после отзыва профиля. Логи контейнера:\n' >&2
    show_wireguard_logs
    rollback_peers "$old_value"
    return
  fi

  rm -rf -- "$CONFIG_DIR/peer_$name"
  printf 'Профиль %s отозван и удалён с сервера. Его копия на устройстве останется, но подключиться по ней уже нельзя.\n' "$name"
}

show_existing_qr() {
  local name peers item found=0
  local -a items=()
  peers="$(get_peers)"
  validate_peers "$peers"
  printf 'Профили: %s\n' "${peers//,/  }"
  read -r -p 'Имя профиля для QR-кода: ' name
  IFS=',' read -r -a items <<< "$peers"
  for item in "${items[@]}"; do
    [[ "$item" == "$name" ]] && found=1
  done
  if ((found == 0)); then
    printf 'Профиль %s не найден.\n' "$name"
    return
  fi
  show_peer_qr "$name" || printf 'Не удалось вывести QR-код профиля %s.\n' "$name" >&2
}

configure_peer_dns() {
  local old_dns new_dns
  old_dns="$(get_peer_dns)"
  old_dns="${old_dns:-1.1.1.1,1.0.0.1}"

  read -r -p "DNS для клиентских профилей [$old_dns]: " new_dns
  new_dns="${new_dns:-$old_dns}"
  new_dns="${new_dns//[[:space:]]/}"
  if ! validate_peer_dns "$new_dns"; then
    printf 'DNS-настройка не изменена.\n' >&2
    return
  fi
  if [[ "$new_dns" == "$old_dns" ]]; then
    printf 'DNS не изменился.\n'
    return
  fi

  set_peer_dns "$new_dns"
  if ! compose config >/dev/null; then
    set_peer_dns "$old_dns"
    printf 'Новая DNS-настройка не прошла проверку Compose; оставил прежнюю настройку %s.\n' "$old_dns" >&2
    return
  fi
  if ! compose_up || ! verify_wireguard; then
    printf 'WireGuard не подтвердил запуск с новой DNS-настройкой. Возвращаю прежнюю настройку. Логи контейнера:\n' >&2
    show_wireguard_logs
    set_peer_dns "$old_dns"
    if ! compose_up || ! verify_wireguard; then
      printf 'Не удалось подтвердить восстановление прежней DNS-настройки. Проверь логи контейнера.\n' >&2
      show_wireguard_logs
    fi
    return
  fi

  printf 'DNS обновлён: %s. Контейнер перезапущен, клиентские конфиги обновлены с прежними ключами.\n' "$new_dns"
  printf 'Импортируй обновлённые конфиги на устройствах; QR-коды доступны в пункте 3 меню.\n'
}

remove_installation() {
  local confirmation
  printf 'Будут удалены контейнер, Compose-сеть, образ и все данные в %s.\n' "$BASE_DIR"
  printf 'Приватные ключи и профили будут удалены без возможности восстановления.\n'
  read -r -p 'Для полного удаления введи WIPE: ' confirmation
  [[ "$confirmation" == WIPE ]] || { printf 'Отменено.\n'; return; }

  compose down --rmi all --volumes --remove-orphans
  rm -rf -- "$BASE_DIR"
  printf 'Установка WireGuard удалена. Docker Engine, команда wg и файл скрипта (если он находится вне %s) остались.\n' "$BASE_DIR"
  printf 'Закрой настроенный UDP-порт WireGuard в панели firewall VPS, если он там открыт.\n'
  exit 0
}

update_wireguard_image() {
  if ! compose pull || ! compose up -d; then
    printf 'Не удалось обновить и запустить WireGuard. Логи контейнера:\n' >&2
    show_wireguard_logs
    return 1
  fi
  if ! verify_wireguard; then
    printf 'После обновления интерфейс WireGuard не запустился. Логи контейнера:\n' >&2
    show_wireguard_logs
    return 1
  fi
  printf 'Образ обновлён, интерфейс WireGuard работает.\n'
}

menu() {
  local choice
  while true; do
    printf '\n=== Управление WireGuard ===\n'
    printf '1) Добавить устройство и показать QR-код\n'
    printf '2) Отозвать и удалить профиль устройства\n'
    printf '3) Показать QR-код профиля\n'
    printf '4) Показать список профилей\n'
    printf '5) Показать состояние WireGuard\n'
    printf '6) Обновить Docker-образ WireGuard\n'
    printf '7) Полностью удалить WireGuard\n'
    printf '8) Изменить DNS в клиентских профилях\n'
    printf '0) Выход\n'
    read -r -p 'Выбери действие: ' choice || exit 0

    case "$choice" in
      1) add_peer ;;
      2) remove_peer ;;
      3) show_existing_qr ;;
      4) list_peers ;;
      5) compose exec -T "$SERVICE" wg show wg0 || printf 'Контейнер WireGuard или интерфейс wg0 не запущен.\n' ;;
      6) update_wireguard_image || true ;;
      7) remove_installation ;;
      8) configure_peer_dns ;;
      0) exit 0 ;;
      *) printf 'Нет такого пункта меню.\n' ;;
    esac
  done
}

setup_existing_installation() {
  local old_value default_value input_value
  local peer_dns dns_migrated=0
  [[ -f "$COMPOSE_FILE" ]] || die "не найден $COMPOSE_FILE"

  old_value="$(get_peers)"
  if [[ -z "$old_value" ]]; then
    default_value="$(awk '
      /^[[:space:]]*PEERS:/ {
        value = $0
        sub(/^[[:space:]]*PEERS:[[:space:]]*/, "", value)
        gsub(/\"/, "", value)
        if (index(value, "${PEERS:-") == 1) {
          value = substr(value, length("${PEERS:-") + 1)
          if (substr(value, length(value), 1) == "}") value = substr(value, 1, length(value) - 1)
        }
        if (value ~ /^[a-zA-Z0-9,]+$/) print value
        exit
      }
    ' "$COMPOSE_FILE")"
    default_value="${default_value:-phone,laptop}"
    read -r -p "Текущие имена профилей через запятую [$default_value]: " input_value
    input_value="${input_value:-$default_value}"
    input_value="${input_value//[[:space:]]/}"
    validate_peers "$input_value"
    set_peers "$input_value"
  else
    validate_peers "$old_value"
  fi

  peer_dns="$(get_peer_dns)"
  if [[ -z "$peer_dns" ]]; then
    peer_dns=1.1.1.1,1.0.0.1
    set_peer_dns "$peer_dns"
    dns_migrated=1
  fi
  validate_peer_dns "$peer_dns" || die "исправь параметр PEERDNS в $ENV_FILE"

  replace_compose_peers_reference
  replace_compose_peer_dns_reference
  chmod 600 "$ENV_FILE"
  compose config >/dev/null || die "Compose-файл не прошёл проверку"
  compose up -d || die "не удалось запустить WireGuard; проверь логи контейнера"
  if ! verify_wireguard; then
    printf 'Интерфейс WireGuard не запустился. Логи контейнера:\n' >&2
    show_wireguard_logs
    die "проверь ошибки выше"
  fi
  printf 'Нашёл существующую конфигурацию WireGuard в %s.\n' "$BASE_DIR"
  if ((dns_migrated == 1)); then
    printf 'Добавил резервный DNS 1.0.0.1. Клиентские профили обновлены с прежними ключами; импортируй обновлённые конфиги из меню или отсканируй их QR-коды заново.\n'
  fi
}

install_new_instance() {
  local server_url server_port peers_input first_peer puid pgid port_number peer_dns
  local compose_tmp

  check_ubuntu_2404
  [[ ! -e "$BASE_DIR" ]] || die "$BASE_DIR уже существует, но compose.yaml не найден. Сначала проверь этот каталог; скрипт его не перезапишет"
  install_docker_if_needed

  read -r -p 'Публичный IPv4 или домен сервера (без https://): ' server_url
  is_valid_server_url "$server_url" || die "введи корректный IPv4-адрес или доменное имя без протокола и пути"

  read -r -p 'UDP-порт WireGuard [51820]: ' server_port
  server_port="${server_port:-51820}"
  [[ "$server_port" =~ ^[0-9]{1,5}$ ]] || die "порт должен быть числом от 1 до 65535"
  port_number=$((10#$server_port))
  ((port_number >= 1 && port_number <= 65535)) || die "порт должен быть от 1 до 65535"
  server_port="$port_number"

  read -r -p 'Имена первых клиентских профилей через запятую [phone,laptop]: ' peers_input
  peers_input="${peers_input:-phone,laptop}"
  peers_input="${peers_input//[[:space:]]/}"
  validate_peers "$peers_input"

  read -r -p 'DNS для клиентов: auto или IPv4-адреса через запятую [1.1.1.1,1.0.0.1]: ' peer_dns
  peer_dns="${peer_dns:-1.1.1.1,1.0.0.1}"
  peer_dns="${peer_dns//[[:space:]]/}"
  validate_peer_dns "$peer_dns" || die "укажи корректный DNS-адрес"

  puid="${SUDO_UID:-1000}"
  pgid="${SUDO_GID:-1000}"
  [[ "$puid" =~ ^[0-9]+$ && "$pgid" =~ ^[0-9]+$ ]] || die "не удалось определить PUID/PGID"

  install -d -m 0755 "$BASE_DIR"
  install -d -m 0700 -o "$puid" -g "$pgid" "$CONFIG_DIR"
  printf 'PEERS=%s\nPEERDNS=%s\n' "$peers_input" "$peer_dns" > "$ENV_FILE"
  chmod 600 "$ENV_FILE"

  compose_tmp="$(mktemp "$BASE_DIR/compose.yaml.XXXXXX")"
  cat > "$compose_tmp" <<EOF
services:
  wireguard:
    image: lscr.io/linuxserver/wireguard:latest
    container_name: wireguard
    cap_add:
      - NET_ADMIN
    environment:
      PUID: "$puid"
      PGID: "$pgid"
      TZ: Europe/Moscow
      SERVERURL: "$server_url"
      SERVERPORT: "$server_port"
      PEERS: "\${PEERS}"
      PEERDNS: "\${PEERDNS}"
      INTERNAL_SUBNET: "10.13.13.0"
      ALLOWEDIPS: "0.0.0.0/0"
      LOG_CONFS: "false"
    volumes:
      - $CONFIG_DIR:/config
    ports:
      - "$server_port:$server_port/udp"
    sysctls:
      net.ipv4.conf.all.src_valid_mark: "1"
    restart: unless-stopped
EOF
  chmod 600 "$compose_tmp"
  mv -f "$compose_tmp" "$COMPOSE_FILE"

  compose config >/dev/null || die "сгенерированный Compose-файл не прошёл проверку"
  compose_up || die "не удалось запустить WireGuard; посмотри логи: cd $BASE_DIR && docker compose logs $SERVICE"

  first_peer="${peers_input%%,*}"
  if wait_for_profile "$first_peer"; then
    if ! verify_wireguard; then
      printf 'Профиль создан, но интерфейс WireGuard не запустился. Логи контейнера:\n' >&2
      show_wireguard_logs
      die "проверь ошибки выше"
    fi
    printf '\nУстановка завершена. Имя каждого профиля соответствует одному устройству.\n'
    printf 'Открой UDP-порт %s в firewall-панели VPS.\n' "$server_port"
    printf 'Если включён UFW, его обычные правила могут не фильтровать опубликованный Docker-порт; используй firewall провайдера или настрой цепочку DOCKER-USER.\n'
    printf 'Первый QR-код для импорта в WireGuard:\n'
    show_peer_qr "$first_peer"
  else
    printf 'Контейнер запущен, но профиль %s не появился. Логи:\n' "$first_peer" >&2
    show_wireguard_logs
    die "проверь ошибки выше"
  fi
}

main() {
  require_root
  acquire_lock
  install_wg_command
  if [[ -f "$COMPOSE_FILE" ]]; then
    install_docker_if_needed
    setup_existing_installation
  else
    install_new_instance
  fi
  menu
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  if [[ "$0" != "$SCRIPT_PATH" ]]; then
    require_root
    install -o root -g root -m 700 -- "$0" "$SCRIPT_PATH"
    exec "$SCRIPT_PATH" "$@"
  fi
  main "$@"
fi
