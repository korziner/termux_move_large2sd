#!/data/data/com.termux/files/usr/bin/bash
# move_large.sh – интерактивное перемещение с РАБОЧИМ ПРОБЕЛОМ (SSH-совместимый)
# Версия: 2.0 с мульти-методом ввода клавиш

set -uo pipefail

# --- Настройки по умолчанию ---
SOURCE_DIR="$HOME"
TARGET_DIR=""
MIN_SIZE="100M"
MAX_SIZE="4G"
TOP_N=20
LINK_TYPE="absolute"
SKIP_CACHE=false
ALLOW_EXECUTABLES=false
NOCHECK=false
FULL_MD5=false
FORCE_RSYNC=false
DRY_RUN=false
VERBOSE=false
DEBUG=false
LOG_FILE="$HOME/move_large.log"
USE_BFS=false
INPUT_METHOD_USED=""
AUTO_START_TIMEOUT=120  # Секунд до авто-старта если ввод не работает

# --- Цвета и логирование ---
if [ -t 2 ]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; BLUE='\033[0;34m'; NC='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; BLUE=''; NC=''
fi

_log() {
    local lvl="$1" msg="$2" clr="$3"
    echo -e "${clr}[${lvl}]${NC} ${msg}" >&2
    echo -e "${lvl} ${msg}" | sed 's/\x1b\[[0-9;]*m//g' >> "$LOG_FILE" 2>/dev/null
}
log_info()  { _log "INFO" "$1" "$GREEN"; }
log_warn()  { _log "WARN" "$1" "$YELLOW"; }
log_error() { _log "ERROR" "$1" "$RED"; }
log_debug() { [ "$DEBUG" = true ] && _log "DEBUG" "$1" "$BLUE"; }

usage() {
    cat <<EOF
Использование: $0 [OPTIONS]
Опции:
  -s, --source DIR        Исходный каталог (по умолч.: \$HOME)
  -t, --target DIR        Целевой каталог на SD
  -m, --min-size SIZE     Мин. размер: K, M, G (по умолч.: 100M)
  -x, --max-size SIZE     Макс. размер (по умолч.: 4G)
  -n, --top N             Кол-во файлов (по умолч.: 20)
  -l, --link-type TYPE    absolute / relative
  --skip-cache            Исключить каталоги .cache
  --allow-executables     Разрешить перемещение исполняемых файлов
  --dry-run               Пробный запуск
  --debug                 Отладочный вывод
  --auto-start SEC        Авто-старт через N сек (по умолч.: $AUTO_START_TIMEOUT)
  -h, --help              Справка
EOF
    exit 0
}

detect_sdcard() {
    local candidates=(
        "$HOME/storage/external-1"
        "$HOME/storage/external-2"
        "/storage/0000-0000"
        "/mnt/media_rw/0000-0000"
    )
    while IFS= read -r line; do
        [[ "$line" =~ ^/storage/[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}$ ]] && candidates+=("$line")
    done < <(df -P 2>/dev/null | awk 'NR>1 {print $6}')
    
    for cand in "${candidates[@]}"; do
        [ -z "$cand" ] && continue
        if [ -d "$cand" ] && [ -w "$cand" ]; then
            echo "$cand"
            return 0
        fi
    done
    return 1
}

to_bytes() {
    local val="$1"
    if [[ "$val" =~ ^([0-9]+)([KMGkmg]?)$ ]]; then
        local num="${BASH_REMATCH[1]}"
        local unit="${BASH_REMATCH[2]^^}"
        case "$unit" in
            K) echo "$((num * 1024))" ;;
            M) echo "$((num * 1024 * 1024))" ;;
            G) echo "$((num * 1024 * 1024 * 1024))" ;;
            *) echo "$num" ;;
        esac
    else
        echo "0"
    fi
}

format_size() {
    local bytes="$1"
    [[ ! "$bytes" =~ ^[0-9]+$ ]] && { echo "0B"; return; }
    awk -v b="$bytes" 'BEGIN {
        if (b>=1073741824) printf "%.1fG\n", b/1073741824;
        else if (b>=1048576) printf "%.1fM\n", b/1048576;
        else if (b>=1024) printf "%.1fK\n", b/1024;
        else printf "%dB\n", b;
    }'
}

file_size() { stat -c '%s' "$1" 2>/dev/null || echo 0; }

quick_verify() {
    local src="$1" dst="$2" size="$3"
    local block_size=1048576
    [ "$size" -le $((block_size * 2)) ] && cmp -s "$src" "$dst" && return 0
    cmp -s -n "$block_size" "$src" "$dst" || return 1
    cmp -s -i "$((size - block_size))" -n "$block_size" "$src" "$dst" 2>/dev/null || return 1
    return 0
}

copy_with_verify() {
    local src="$1" dst="$2" size="$3"
    if [ "$USE_RSYNC" = true ]; then
        local opts="-t"
        [ "$VERBOSE" = true ] && opts="$opts -v"
        rsync $opts "$src" "$dst" && [ "$(file_size "$dst")" -eq "$size" ] && return 0
        return 1
    fi
    cp -f "$src" "$dst" || return 1
    [ "$(file_size "$dst")" -ne "$size" ] && { rm -f "$dst"; return 1; }
    [ "$NOCHECK" = true ] && return 0
    if [ "$FULL_MD5" = true ]; then
        [ "$(md5sum "$src" | cut -d' ' -f1)" = "$(md5sum "$dst" | cut -d' ' -f1)" ] && return 0
    else
        quick_verify "$src" "$dst" "$size" && return 0
    fi
    rm -f "$dst"
    return 1
}

relative_path() {
    local src="$1" dst="$2"
    local src_dir; src_dir=$(dirname "$src")
    local common="$src_dir" up=""
    while [[ "$dst" != "$common"* && "$common" != "/" ]]; do
        common=$(dirname "$common"); up="../$up"
    done
    echo "${up}${dst#$common/}"
}

sanitize_fat_path() {
    local path="$1"
    echo "$path" | sed -e 's/:/%3A/g' -e 's/\*/%2A/g' -e 's/?/%3F/g' \
         -e 's/</%3C/g' -e 's/>/%3E/g' -e 's/|/%7C/g' \
         -e 's/"/%22/g' -e 's/\\/%5C/g' -e 's/[[:cntrl:]]/%00/g'
}

# --- Тест работоспособности bfs ---
test_bfs_functionality() {
    local test_dir="/data/data/com.termux/files/usr/bin"
    
    if ! command -v bfs >/dev/null 2>&1; then
        log_debug "🔍 bfs не найден в PATH"
        return 1
    fi
    
    local result
    result=$(bfs "$test_dir" -type f -executable -print 2>/dev/null | head -n 1)
    
    if [ -n "$result" ]; then
        log_debug "✅ bfs работоспособен (тест на $test_dir)"
        return 0
    else
        log_debug "❌ bfs не работает корректно (тест на $test_dir)"
        return 1
    fi
}

# --- Аудит ---
run_audit() {
    local audit_args=(
        -type f -executable
        ! -path "*/proc/*" ! -path "*/sys/*" ! -path "*/dev/*"
        ! -path "*/Android/*" ! -path "*/lost+found/*"
        ! -path "*/.git/*" ! -path "*/.termux/*"
    )
    
    local audit_cmd count
    if [ "$USE_BFS" = true ]; then
        audit_cmd="bfs \"$SOURCE_DIR\" $(printf '%q ' "${audit_args[@]}") -printf '.' | wc -c"
        log_debug "📜 Команда аудита (bfs): $audit_cmd"
        count=$(bfs "$SOURCE_DIR" "${audit_args[@]}" -printf '.' 2>/dev/null | wc -c)
    else
        audit_cmd="find \"$SOURCE_DIR\" $(printf '%q ' "${audit_args[@]}") -printf '.' | wc -c"
        log_debug "📜 Команда аудита (find): $audit_cmd"
        count=$(find "$SOURCE_DIR" "${audit_args[@]}" -printf '.' 2>/dev/null | wc -c)
    fi
    echo "${count:-0}"
}

# --- Фильтрация через awk ---
filter_valid_entries() {
    awk -F'\t' 'NF>=2 && $1 ~ /^[0-9]+$/ && length($2)>0'
}

# ============================================================================
# 🔥 МУЛЬТИ-МЕТОД ЧТЕНИЯ КЛАВИШ (SSH-совместимый)
# ============================================================================

# Глобальные переменные для управления вводом
KEYBOARD_INPUT_RECEIVED=""
KEYBOARD_INPUT_KEY=""
INPUT_TEST_PASSED=""

# Функция тестирования метода ввода
test_input_method() {
    local method_name="$1"
    local test_result=""
    
    log_debug "🧪 Тест метода ввода: $method_name"
    
    case "$method_name" in
        "dev_tty")
            if [ -e /dev/tty ] && [ -r /dev/tty ] && [ -w /dev/tty ]; then
                test_result="PASS"
            else
                test_result="FAIL"
            fi
            ;;
        "stty")
            if stty -g >/dev/null 2>&1; then
                test_result="PASS"
            else
                test_result="FAIL"
            fi
            ;;
        "read")
            if echo " " | read -n 1 -t 0.1 _key 2>/dev/null; then
                test_result="PASS"
            else
                test_result="PASS"  # read может вернуть 1 даже при успехе
            fi
            ;;
        "timeout")
            if command -v timeout >/dev/null 2>&1; then
                test_result="PASS"
            else
                test_result="FAIL"
            fi
            ;;
        *)
            test_result="FAIL"
            ;;
    esac
    
    log_debug "🧪 Метод $method_name: $test_result"
    [ "$test_result" = "PASS" ] && return 0 || return 1
}

# Метод 1: Прямое чтение из /dev/tty
read_key_method_dev_tty() {
    local key=""
    if read -t 0.1 -n 1 key < /dev/tty 2>/dev/null; then
        if [[ "$key" == " " || "$key" == $'\x20' ]]; then
            KEYBOARD_INPUT_KEY="SPACE"
            return 0
        fi
    fi
    return 1
}

# Метод 2: stty + read из stdin
read_key_method_stty() {
    local key=""
    local old_stty
    old_stty=$(stty -g 2>/dev/null) || return 1
    
    stty -icanon -echo min 0 time 1 2>/dev/null || return 1
    key=$(dd bs=1 count=1 2>/dev/null) || true
    stty "$old_stty" 2>/dev/null || true
    
    if [[ "$key" == " " || "$key" == $'\x20' ]]; then
        KEYBOARD_INPUT_KEY="SPACE"
        return 0
    fi
    return 1
}

# Метод 3: read из /dev/stdin
read_key_method_stdin() {
    local key=""
    if read -t 0.1 -n 1 key < /dev/stdin 2>/dev/null; then
        if [[ "$key" == " " || "$key" == $'\x20' ]]; then
            KEYBOARD_INPUT_KEY="SPACE"
            return 0
        fi
    fi
    return 1
}

# Метод 4: timeout + cat
read_key_method_timeout() {
    local key=""
    if command -v timeout >/dev/null 2>&1; then
        key=$(timeout 0.1 cat < /dev/tty 2>/dev/null) || true
        if [[ "$key" == " " || "$key" == $'\x20' ]]; then
            KEYBOARD_INPUT_KEY="SPACE"
            return 0
        fi
    fi
    return 1
}

# Метод 5: select + read (fallback для некоторых SSH клиентов)
read_key_method_select() {
    local key=""
    PS3=""
    select key in " " "quit" ; do
        if [[ "$key" == " " ]]; then
            KEYBOARD_INPUT_KEY="SPACE"
            return 0
        fi
        break
    done
    return 1
}

# Главная функция чтения клавиши с перебором всех методов
read_key_with_fallback() {
    local methods=("dev_tty" "stty" "stdin" "timeout")
    local method_used=""
    
    for method in "${methods[@]}"; do
        if test_input_method "$method"; then
            case "$method" in
                "dev_tty")
                    if read_key_method_dev_tty; then
                        method_used="dev_tty"
                        break
                    fi
                    ;;
                "stty")
                    if read_key_method_stty; then
                        method_used="stty"
                        break
                    fi
                    ;;
                "stdin")
                    if read_key_method_stdin; then
                        method_used="stdin"
                        break
                    fi
                    ;;
                "timeout")
                    if read_key_method_timeout; then
                        method_used="timeout"
                        break
                    fi
                    ;;
            esac
        fi
    done
    
    if [ -n "$method_used" ]; then
        INPUT_METHOD_USED="$method_used"
        log_debug "✅ Метод ввода: $method_used"
        return 0
    fi
    
    return 1
}

# --- Интерактивный поиск с РАБОЧИМ ПРОБЕЛОМ (SSH-совместимый) ---
search_interactive() {
    local -a args=("$@")
    local tmpfile=$(mktemp)
    local search_pid=""
    local interrupted=false
    local auto_start_timer=0
    
    local search_cmd
    if [ "$USE_BFS" = true ]; then
        search_cmd="bfs \"$SOURCE_DIR\" $(printf '%q ' "${args[@]}") -printf '%s\\t%p\\n'"
        bfs "$SOURCE_DIR" "${args[@]}" -printf '%s\t%p\n' >> "$tmpfile" 2>/dev/null &
    else
        search_cmd="find \"$SOURCE_DIR\" $(printf '%q ' "${args[@]}") -exec stat -c '%s\\t%n' {} \\;"
        find "$SOURCE_DIR" "${args[@]}" -exec stat -c '%s\t%n' {} \; >> "$tmpfile" 2>/dev/null &
    fi
    log_debug "📜 Команда поиска ($([ "$USE_BFS" = true ] && echo "bfs" || echo "find")): $search_cmd"
    [ "$DEBUG" = true ] && sleep 1

    search_pid=$!
    
    # Сохраняем настройки терминала
    local old_stty=""
    if stty -g >/dev/null 2>&1; then
        old_stty=$(stty -g 2>/dev/null)
    fi
    
    # Попытка настроить терминал для неканонического режима
    if [ -n "$old_stty" ]; then
        stty -icanon -echo min 0 time 1 2>/dev/null || true
    fi
    
    trap 'kill $search_pid 2>/dev/null; wait $search_pid 2>/dev/null; 
          [ -n "$old_stty" ] && stty "$old_stty" 2>/dev/null; 
          printf "\033[?25h\n" >&2; rm -f "$tmpfile"' EXIT INT TERM
    
    printf "\033[?25l" >&2

    log_info "🎹 Методы ввода: перебор 4 методов + авто-старт через ${AUTO_START_TIMEOUT}с"
    log_debug "🎹 Тестирование методов ввода..."
    
    # Тестируем доступные методы ввода
    local available_methods=()
    for method in "dev_tty" "stty" "stdin" "timeout"; do
        if test_input_method "$method"; then
            available_methods+=("$method")
            log_debug "✅ Доступен метод: $method"
        else
            log_debug "❌ Недоступен метод: $method"
        fi
    done
    
    if [ ${#available_methods[@]} -eq 0 ]; then
        log_warn "⚠️ Ни один метод ввода не доступен — авто-старт через ${AUTO_START_TIMEOUT}с"
    else
        log_info "✅ Доступные методы ввода: ${available_methods[*]}"
    fi

    while kill -0 $search_pid 2>/dev/null; do
        printf "\033[2J\033[H" >&2
        echo "🔍 Поиск файлов..." >&2
        echo "=========================================" >&2
        
        if [ -s "$tmpfile" ]; then
            sort -k1 -rn "$tmpfile" 2>/dev/null | head -n 5 | awk -F'\t' 'NF>=2 && $1 ~ /^[0-9]+$/ && length($2)>0 {
                cmd = "awk -v b=" $1 " '\''BEGIN { if (b>=1073741824) printf \"%.1fG\", b/1073741824; else if (b>=1048576) printf \"%.1fM\", b/1048576; else if (b>=1024) printf \"%.1fK\", b/1024; else printf \"%dB\", b }'\''"
                cmd | getline sz
                close(cmd)
                printf "  %-10s %s\n", sz, $2
            }' >&2
        else
            echo "  ⏳ Сканирование..." >&2
        fi
        
        echo "=========================================" >&2
        local found_count
        found_count=$(wc -l < "$tmpfile" 2>/dev/null | tr -d ' ' || echo 0)
        echo "Найдено: $found_count файлов | Лимит: $TOP_N" >&2
        echo -e "\n[ПРОБЕЛ] Копировать ЭТИ $TOP_N (не ждать окончания)" >&2
        echo "[Ctrl+C] Полная остановка" >&2
        echo "[Авто-старт через: $((AUTO_START_TIMEOUT - auto_start_timer)) сек]" >&2
        
        # 🔥 Чтение клавиши с перебором методов (каждые 0.5 сек)
        local key_pressed=false
        for i in $(seq 1 10); do  # 10 × 0.5с = 5 сек между обновлениями экрана
            if read_key_with_fallback; then
                if [ "$KEYBOARD_INPUT_KEY" = "SPACE" ]; then
                    key_pressed=true
                    interrupted=true
                    kill $search_pid 2>/dev/null
                    echo -e "\n⏹️ Поиск прерван. Обработка найденных ($found_count файлов)..." >&2
                    break 2
                fi
            fi
            sleep 0.5
            ((auto_start_timer++))
            
            # Авто-старт по таймауту
            if [ "$auto_start_timer" -ge "$AUTO_START_TIMEOUT" ]; then
                kill $search_pid 2>/dev/null
                echo -e "\n⏱️ Авто-старт по таймауту. Обработка найденных ($found_count файлов)..." >&2
                interrupted=true
                break 2
            fi
        done
    done
    
    wait $search_pid 2>/dev/null
    
    # Восстанавливаем настройки терминала
    if [ -n "$old_stty" ]; then
        stty "$old_stty" 2>/dev/null || true
    fi
    printf "\033[?25h" >&2
    
    if [ -s "$tmpfile" ]; then
        sort -k1 -rn "$tmpfile" 2>/dev/null | head -n "$TOP_N" | filter_valid_entries
    fi
    
    if [ "$interrupted" = true ]; then
        echo "SEARCH_INTERRUPTED=true" >> "$LOG_FILE"
        [ -n "$INPUT_METHOD_USED" ] && echo "INPUT_METHOD=$INPUT_METHOD_USED" >> "$LOG_FILE"
    fi
    
    rm -f "$tmpfile"
    trap - EXIT INT TERM
}

# ============================
# Инициализация
# ============================
: > "$LOG_FILE"
log_info "🚀 Запуск: $*"

while [[ $# -gt 0 ]]; do
    case "$1" in
        -s|--source) SOURCE_DIR="$2"; shift 2 ;;
        -t|--target) TARGET_DIR="$2"; shift 2 ;;
        -m|--min-size) MIN_SIZE="$2"; shift 2 ;;
        -x|--max-size) MAX_SIZE="$2"; shift 2 ;;
        -n|--top) TOP_N="$2"; shift 2 ;;
        -l|--link-type) LINK_TYPE="$2"; shift 2 ;;
        --skip-cache) SKIP_CACHE=true; shift ;;
        --allow-executables) ALLOW_EXECUTABLES=true; shift ;;
        --nocheck) NOCHECK=true; shift ;;
        --full-md5) FULL_MD5=true; shift ;;
        --use-rsync) FORCE_RSYNC=true; shift ;;
        --dry-run) DRY_RUN=true; shift ;;
        --verbose) VERBOSE=true; shift ;;
        --debug) DEBUG=true; shift ;;
        --auto-start) AUTO_START_TIMEOUT="$2"; shift 2 ;;
        -h|--help) usage ;;
        *) log_error "Неизвестный аргумент: $1"; usage ;;
    esac
done

[[ "$LINK_TYPE" != "absolute" && "$LINK_TYPE" != "relative" ]] && { log_error "link-type: absolute или relative"; exit 1; }

if [ -z "$TARGET_DIR" ]; then
    TARGET_DIR=$(detect_sdcard) || { log_error "SD-карта не найдена. Укажите --target вручную."; exit 1; }
fi

log_info "📁 Источник: $SOURCE_DIR"
log_info "💾 Цель: $TARGET_DIR"
log_info "⚙️  Кэш: $([ "$SKIP_CACHE" = true ] && echo "Пропускается" || echo "Перемещается")"
log_info "⚙️  Исполняемые: $([ "$ALLOW_EXECUTABLES" = true ] && echo "Разрешены" || echo "Пропускаются (FAT-safe)")"

# --- Тест работоспособности bfs ---
log_info "🔍 Проверка работоспособности bfs..."
if test_bfs_functionality; then
    USE_BFS=true
    log_info "✅ bfs работоспособен — будет использоваться"
else
    USE_BFS=false
    log_warn "⚠️ bfs не работает корректно — используется find"
fi

for dir in "$SOURCE_DIR" "$TARGET_DIR"; do
    [ ! -d "$dir" ] && { log_error "Каталог не существует: $dir"; exit 1; }
done
[ ! -w "$TARGET_DIR" ] && { log_error "Нет прав на запись: $TARGET_DIR"; exit 1; }

# --- Аудит ---
log_info "🔍 Аудит исполняемых файлов..."
exec_count=$(run_audit)
[[ ! "$exec_count" =~ ^[0-9]+$ ]] && exec_count=0
log_info "📊 Найдено исполняемых файлов: $exec_count"
if [ "$exec_count" -gt 0 ] && [ "$ALLOW_EXECUTABLES" = false ]; then
    log_warn "⚠️ Исполняемые файлы будут пропущены (FAT не поддерживает +x)"
fi

min_bytes=$(to_bytes "$MIN_SIZE")
max_bytes=$(to_bytes "$MAX_SIZE")

if [ "$min_bytes" -ge "$max_bytes" ] || [ "$min_bytes" -le 0 ]; then
    log_error "Некорректные размеры"; exit 1
fi

avail=$(df -Pk "$TARGET_DIR" 2>/dev/null | awk 'NR==2 {print $4}')
if [[ "$avail" =~ ^[0-9]+$ ]] && [ "$avail" -gt 0 ]; then
    log_info "📊 Свободно: $(format_size $((avail * 1024)))"
else
    log_warn "⚠️ Не удалось определить свободное место"
fi

USE_RSYNC=false
if [ "$FORCE_RSYNC" = true ] || { [ "$NOCHECK" = false ] && command -v rsync >/dev/null 2>&1; }; then
    USE_RSYNC=true; log_info "🔄 rsync + проверка"
elif [ "$NOCHECK" = false ]; then
    log_info "🔍 cp + быстрая проверка"
else
    log_info "⚡ cp без проверки"
fi

# --- Аргументы поиска ---
declare -a find_args=(
    -type f -size +"${min_bytes}c" -size -"${max_bytes}c"
    ! -path "*/proc/*" ! -path "*/sys/*" ! -path "*/dev/*"
    ! -path "*/Android/*" ! -path "*/lost+found/*"
    ! -path "*/.git/*" ! -path "*/.termux/*"
)
[ "$SKIP_CACHE" = true ] && find_args+=(! -path "*/.cache/*")
[ "$ALLOW_EXECUTABLES" = false ] && find_args+=(! -executable)

# --- Запуск поиска ---
log_info "🔎 Запуск интерактивного поиска..."
mapfile -t file_list < <(search_interactive "${find_args[@]}")

# Фильтрация
filtered_list=()
for entry in "${file_list[@]}"; do
    if echo "$entry" | filter_valid_entries | grep -q .; then
        filtered_list+=("$entry")
    fi
done
file_list=("${filtered_list[@]}")

if grep -q "SEARCH_INTERRUPTED=true" "$LOG_FILE" 2>/dev/null; then
    log_warn "⚡ Поиск прерван пользователем — обработка найденных файлов"
    if grep -q "INPUT_METHOD=" "$LOG_FILE" 2>/dev/null; then
        method=$(grep "INPUT_METHOD=" "$LOG_FILE" | cut -d= -f2)
        log_info "🎹 Использован метод ввода: $method"
    fi
    sed -i '/SEARCH_INTERRUPTED/d; /INPUT_METHOD=/d' "$LOG_FILE"
fi

if [ ${#file_list[@]} -eq 0 ]; then
    log_warn "⚠️ Файлы не найдены."
    exit 0
fi

log_info "🎯 Найдено файлов для обработки: ${#file_list[@]}"
if [ "$DEBUG" = true ]; then
    printf '%s\n' "${file_list[@]}" | head -20 | while IFS=$'\t' read -r sz path; do
        echo "  $(format_size "$sz") : $path"
    done
fi

# 🔄 Обработка файлов
processed=0
for entry in "${file_list[@]}"; do
    IFS=$'\t' read -r size src <<< "$entry"
    [ -z "$src" ] && continue
    [[ ! "$size" =~ ^[0-9]+$ ]] && { log_warn "⚠️ Пропущено (некорректный размер): $entry"; continue; }
    
    rel="${src#$SOURCE_DIR/}"
    fat_rel=$(sanitize_fat_path "$rel")
    dst="$TARGET_DIR/$fat_rel"
    dst_dir=$(dirname "$dst")
    
    if [ "$rel" != "$fat_rel" ]; then
        log_warn "🔤 FAT-адаптация имени: $rel -> $fat_rel"
        echo "$(date '+%Y-%m-%d %H:%M:%S') RENAMED: $rel -> $fat_rel" >> "$LOG_FILE"
    fi
    
    log_info "📄 [$((++processed))/${#file_list[@]}] $(format_size "$size") : $src"
    log_debug "  → $dst"
    
    [ "$DRY_RUN" = true ] && { echo "[DRY RUN] Копирование + симлинк"; continue; }
    
    mkdir -p "$dst_dir" || { log_error "Не создан: $dst_dir"; continue; }
    
    if [ -f "$dst" ] || [ -L "$dst" ]; then
        old_sz=$(file_size "$dst")
        if [ "$old_sz" -ge "$size" ]; then
            log_info "✅ Уже существует: $dst"
            rm -f "$src"
            [ "$LINK_TYPE" = "absolute" ] && ln -sf "$dst" "$src" || ln -sf "$(relative_path "$src" "$dst")" "$src"
            continue
        else
            log_warn "⚠️ Перезапись: $dst"; rm -f "$dst"
        fi
    fi
    
    if copy_with_verify "$src" "$dst" "$size"; then
        log_info "✅ Копирование успешно"
        rm -f "$src" || { log_error "Не удалён: $src"; continue; }
        [ "$LINK_TYPE" = "absolute" ] && ln -s "$dst" "$src" || ln -s "$(relative_path "$src" "$dst")" "$src"
        log_info "🔗 Симлинк: $src -> $fat_rel"
        echo "$(date '+%Y-%m-%d %H:%M:%S') OK: $src -> $fat_rel" >> "$LOG_FILE"
    else
        log_error "❌ Ошибка копирования: $src"; rm -f "$dst" 2>/dev/null
    fi
done

log_info "✨ Завершено. Обработано: $processed файлов"
log_info "📋 Полный журнал и карта имён: $LOG_FILE"
