#!/usr/bin/env bash

# Script de control DDC/CI vía ddcutil con menú rofi por monitor.
# Requisitos: ddcutil, rofi.

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/waybar-ddcutil"
mkdir -p "$STATE_DIR"

MON_FILE="$STATE_DIR/current_monitor"

MON_LABEL_FILE="$STATE_DIR/current_monitor_label"

VCP_FILE="$STATE_DIR/vcp_list"

ROFI_LINES="${ROFI_LINES:-15}"

DEBUG_LOG="$STATE_DIR/rofi-menu.log"

debug_log() {
  [ -n "$ROFI_DEBUG" ] || return
  local msg="$*"
  printf '%s %s\n' "$(date +'%F %T')" "$msg" >> "$DEBUG_LOG"
}

debug_dump() {
  [ -n "$ROFI_DEBUG" ] || return
  printf '%s\n' "$1" >> "$DEBUG_LOG"
}

# VCP por defecto que se usarán y que se podrán editar
# code;nombre;min;max
DEFAULT_VCP_LIST=$(cat <<'EOF'
10;Brightness;0;100
12;Contrast;0;100
18;Red gain;0;100
1A;Green gain;0;100
1C;Blue gain;0;100
60;Input source;1;15
EOF
)

ensure_vcp_file() {
  if [ ! -f "$VCP_FILE" ]; then
    printf '%s\n' "$DEFAULT_VCP_LIST" > "$VCP_FILE"
  fi
}

load_vcp_list() {
  ensure_vcp_file
  VCP_LIST=$(cat "$VCP_FILE")
}

write_vcp_list() {
  local content="$1"
  local tmp="$VCP_FILE.tmp"
  printf '%s\n' "$content" > "$tmp" && mv "$tmp" "$VCP_FILE"
}

trim() {
  local s="$1"
  s=${s#"${s%%[![:space:]]*}"}
  s=${s%"${s##*[![:space:]]}"}
  printf '%s' "$s"
}

normalize_vcp_code() {
  # Acepta: 10, 0x10, 1a, 0X1A
  local c
  c=$(printf '%s' "$1" | tr -d '[:space:]')
  c=${c#0x}
  c=${c#0X}
  c=$(printf '%s' "$c" | tr '[:lower:]' '[:upper:]')
  # Validar hex (1-2 dígitos) y normalizar a 2 dígitos
  if ! printf '%s' "$c" | grep -Eq '^[0-9A-F]{1,2}$'; then
    return 1
  fi
  printf '%02s' "$c" | tr ' ' '0'
}

# ================== Helpers ddcutil ==================

get_monitors() {
  # Devuelve IDs numéricos de ddcutil (1, 2, 3...)
  ddcutil detect 2>/dev/null | awk '/Display [0-9]+/ {print $2}'
}

monitor_label() {
  local id="$1"
  # Nombre amigable a partir de `ddcutil detect`
  ddcutil detect 2>/dev/null |
    awk -v id="$id" '
      $1=="Display" && $2==id {in_block=1; next}
      /^$/ {in_block=0}
      in_block && /Model:/ {line=$0; sub(/.*Model:[[:space:]]*/,"",line); model=line}
      END {
        if (model!="") {
          print id " - " model
        } else {
          print id
        }
      }'
}

monitor_prompt() {
  local id="$1"
  if [ -f "$MON_LABEL_FILE" ]; then
    local cached
    cached=$(cat "$MON_LABEL_FILE")
    if printf '%s' "$cached" | grep -qE "^${id}[[:space:]]"; then
      printf '%s' "$cached"
      return
    fi
  fi
  printf '%s' "$id"
}

get_vcp_value() {
  local mon="$1"
  local vcp="$2"
  ddcutil --display "$mon" getvcp "$vcp" 2>/dev/null | \
    awk -F'current value = ' 'NF>1{print $2}' | \
    awk '{print $1}' | \
    tr -cd '0-9'
}

set_vcp_value() {
  local mon="$1"
  local vcp="$2"
  local val="$3"
  ddcutil --display "$mon" setvcp "$vcp" "$val" >/dev/null 2>&1
}

# ================== Menús rofi ==================

rofi_menu() {
  local prompt="$1"
  rofi -dmenu -i -p "$prompt" -l "$ROFI_LINES"
}

rofi_input() {
  local prompt="$1"
  rofi -dmenu -i -p "$prompt" -l 0
}

capabilities_vcp_lines() {
  local mon="$1"
  # Extrae pares (código, nombre) desde `ddcutil capabilities`.
  # Formato típico: "Feature: 10 (Brightness)"
  ddcutil --display "$mon" capabilities 2>/dev/null |
    awk '
      {
        if (match($0, /Feature:[[:space:]]*([0-9A-Fa-f]{2})[[:space:]]*\(([^)]*)\)/, m)) {
          code=toupper(m[1]); name=m[2];
          gsub(/[[:space:]]+$/, "", name);
          print "0x" code " | " name;
        }
      }'
}

import_vcps_from_monitor() {
  local mon="$1"
  local prompt
  prompt=$(monitor_prompt "$mon")

  local list
  list=$(capabilities_vcp_lines "$mon")
  if [ -z "$list" ]; then
    notify-send "DDC" "No pude leer capacidades del monitor"
    return 1
  fi

  # Multi-selección opcional: Shift+Enter marca filas.
  local chosen
  debug_log "import_vcps_from_monitor prompt=Importar ($prompt)"
  debug_dump "$list"
  chosen=$(printf '%s\n' "$list" | rofi -dmenu -i -p "Importar ($prompt)" -l "$ROFI_LINES" -multi-select)
  [ -z "$chosen" ] && return 0

  load_vcp_list
  local updated="$VCP_LIST"

  local line
  while IFS= read -r line; do
    line=$(trim "$line")
    [ -z "$line" ] && continue
    local code name
    code=$(printf '%s' "$line" | awk -F'|' '{gsub(/0x/,"",$1); gsub(/ /,"",$1); print $1}')
    name=$(printf '%s' "$line" | awk -F'|' '{gsub(/^ +| +$/,"",$2); print $2}')
    code=$(normalize_vcp_code "$code" 2>/dev/null) || continue
    name=$(printf '%s' "$name" | tr -d '\n\r' | sed 's/;/ /g')

    # Si ya existe (aunque esté desactivado), no duplicar.
    if printf '%s\n' "$updated" | sed 's/^# *//' | awk -F';' '{gsub(/ /, "", $1); print toupper($1)}' | grep -qx "$code"; then
      continue
    fi
    updated+=$'\n'
    updated+=$(printf "%s;%s;0;100" "$code" "$name")
  done <<< "$chosen"

  updated=$(printf '%s\n' "$updated" | sed '/^\s*$/d')
  write_vcp_list "$updated"
  notify-send "DDC" "Características importadas"
}

edit_vcp_menu() {
  while true; do
    load_vcp_list

    local menu_lines=()
    menu_lines+=("Añadir característica...")
    menu_lines+=("Importar desde monitor...")
    menu_lines+=("Borrar característica...")
    menu_lines+=("Restaurar por defecto")
    menu_lines+=("Volver")

    local line code name min max raw disabled norm
    while IFS= read -r raw; do
      raw=$(trim "$raw")
      [ -z "$raw" ] && continue

      disabled=0
      if printf '%s' "$raw" | grep -qE '^#'; then
        disabled=1
        raw=${raw#\#}
        raw=$(trim "$raw")
      fi

      IFS=';' read -r code name min max <<< "$raw"
      code=$(trim "$code")
      name=$(trim "$name")
      min=$(trim "$min")
      max=$(trim "$max")
      [ -z "$code" ] && continue

      norm=$(normalize_vcp_code "$code" 2>/dev/null) || continue

      if [ "$disabled" -eq 1 ]; then
        menu_lines+=("[ ] 0x$norm | $name | $min-$max")
      else
        menu_lines+=("[x] 0x$norm | $name | $min-$max")
      fi
    done <<< "$VCP_LIST"

    local menu_payload
    menu_payload=$(printf '%s\n' "${menu_lines[@]}")
    local chosen
    debug_log "edit_vcp_menu prompt=Características"
    debug_dump "$menu_payload"
    chosen=$(printf '%s' "$menu_payload" | rofi_menu "Características")
    [ -z "$chosen" ] && return 0

    case "$chosen" in
      "Volver")
        return 0
        ;;
      "Restaurar por defecto")
        write_vcp_list "$DEFAULT_VCP_LIST"
        notify-send "DDC" "Lista de características restaurada"
        continue
        ;;
      "Importar desde monitor...")
        local mon
        mon=$(current_monitor)
        import_vcps_from_monitor "$mon"
        ;;
      "Añadir característica...")
        local in_code in_name in_min in_max
        in_code=$(printf '' | rofi_menu "Código VCP (ej: 10 o 0x10)")
        [ -z "$in_code" ] && continue
        in_code=$(normalize_vcp_code "$in_code" 2>/dev/null) || { notify-send "DDC" "Código VCP inválido"; continue; }

        in_name=$(printf '' | rofi_menu "Nombre")
        [ -z "$in_name" ] && continue
        in_name=$(printf '%s' "$in_name" | tr -d '\n\r' | sed 's/;/ /g')

        in_min=$(printf '0' | rofi_menu "Mínimo")
        in_min=$(printf '%s' "$in_min" | tr -cd '0-9')
        [ -z "$in_min" ] && in_min=0

        in_max=$(printf '100' | rofi_menu "Máximo")
        in_max=$(printf '%s' "$in_max" | tr -cd '0-9')
        [ -z "$in_max" ] && in_max=100

        # Reemplazar si existe el código; si no, añadir.
        local out="" found=0 r
        while IFS= read -r r; do
          local rr cc
          rr=$(trim "$r")
          if [ -z "$rr" ]; then
            out+=$'\n'
            continue
          fi
          if printf '%s' "$rr" | grep -qE '^#'; then
            rr=${rr#\#}
            rr=$(trim "$rr")
          fi
          IFS=';' read -r cc _ <<< "$rr"
          cc=$(trim "$cc")
          cc=$(normalize_vcp_code "$cc" 2>/dev/null) || { out+="$r"$'\n'; continue; }
          if [ "$cc" = "$in_code" ]; then
            out+=$(printf "%s;%s;%s;%s\n" "$in_code" "$in_name" "$in_min" "$in_max")
            found=1
          else
            out+="$r"$'\n'
          fi
        done <<< "$VCP_LIST"
        if [ "$found" -eq 0 ]; then
          out+=$(printf "%s;%s;%s;%s\n" "$in_code" "$in_name" "$in_min" "$in_max")
        fi
        out=$(printf '%s' "$out" | sed '/^$/d')
        write_vcp_list "$out"
        notify-send "DDC" "Característica 0x$in_code guardada"
        continue
        ;;
      "Borrar característica...")
        local list_lines=() r2 rr2 code2 name2 disabled3 norm2
        while IFS= read -r r2; do
          rr2=$(trim "$r2")
          [ -z "$rr2" ] && continue
          disabled3=0
          if printf '%s' "$rr2" | grep -qE '^#'; then
            disabled3=1
            rr2=${rr2#\#}
            rr2=$(trim "$rr2")
          fi
          IFS=';' read -r code2 name2 _ _ <<< "$rr2"
          code2=$(trim "$code2")
          name2=$(trim "$name2")
          norm2=$(normalize_vcp_code "$code2" 2>/dev/null) || continue
          if [ "$disabled3" -eq 1 ]; then
            list_lines+=("0x$norm2 | $name2 (desactivado)")
          else
            list_lines+=("0x$norm2 | $name2")
          fi
        done <<< "$VCP_LIST"
        local del
        debug_log "edit_vcp_menu borrar prompt=Borrar"
        local list_payload
        list_payload=$(printf '%s\n' "${list_lines[@]}")
        debug_dump "$list_payload"
        del=$(printf '%s' "$list_payload" | rofi_menu "Borrar")
        [ -z "$del" ] && continue
        local del_code
        del_code=$(printf '%s' "$del" | awk -F'|' '{gsub(/0x/,"",$1); gsub(/ /,"",$1); print $1}')
        del_code=$(normalize_vcp_code "$del_code" 2>/dev/null) || continue

        local out2="" r3
        while IFS= read -r r3; do
          local rr3 cc3
          rr3=$(trim "$r3")
          [ -z "$rr3" ] && continue
          if printf '%s' "$rr3" | grep -qE '^#'; then
            rr3=${rr3#\#}
            rr3=$(trim "$rr3")
          fi
          IFS=';' read -r cc3 _ <<< "$rr3"
          cc3=$(trim "$cc3")
          cc3=$(normalize_vcp_code "$cc3" 2>/dev/null) || continue
          if [ "$cc3" != "$del_code" ]; then
            out2+="$r3"$'\n'
          fi
        done <<< "$VCP_LIST"
        out2=$(printf '%s' "$out2" | sed '/^$/d')
        write_vcp_list "$out2"
        notify-send "DDC" "Característica 0x$del_code borrada"
        continue
        ;;
    esac

    # Toggle de entrada [x]/[ ]
    if printf '%s' "$chosen" | grep -qE '^\[[ x]\]'; then
      local tcode
      tcode=$(printf '%s' "$chosen" | grep -oE '0x[0-9A-Fa-f]{1,2}' | head -n1 | sed 's/^0x//')
      tcode=$(normalize_vcp_code "$tcode" 2>/dev/null) || continue

      local out3="" r4
      while IFS= read -r r4; do
        local rr4 disabled5 cc4
        rr4=$(trim "$r4")
        if [ -z "$rr4" ]; then
          out3+=$'\n'
          continue
        fi
        disabled5=0
        if printf '%s' "$rr4" | grep -qE '^#'; then
          disabled5=1
          rr4=${rr4#\#}
          rr4=$(trim "$rr4")
        fi
        IFS=';' read -r cc4 _ <<< "$rr4"
        cc4=$(trim "$cc4")
        cc4=$(normalize_vcp_code "$cc4" 2>/dev/null) || { out3+="$r4"$'\n'; continue; }

        if [ "$cc4" = "$tcode" ]; then
          if [ "$disabled5" -eq 1 ]; then
            out3+="$rr4"$'\n'
          else
            out3+="# $rr4"$'\n'
          fi
        else
          out3+="$r4"$'\n'
        fi
      done <<< "$VCP_LIST"
      out3=$(printf '%s' "$out3" | sed '/^$/d')
      write_vcp_list "$out3"
      notify-send "DDC" "Característica 0x$tcode actualizada"
      continue
    fi
  done
}

choose_monitor() {
  local mons
  mons=$(get_monitors)
  [ -z "$mons" ] && notify-send "DDC" "No se han detectado monitores DDC/CI" && exit 1

  local menu_lines=()
  local m
  for m in $mons; do
    menu_lines+=("$(monitor_label "$m")")
  done

  local chosen
  local menu_payload
  menu_payload=$(printf '%s\n' "${menu_lines[@]}")
  debug_log "choose_monitor prompt=Monitor"
  debug_dump "$menu_payload"
  chosen=$(printf '%s' "$menu_payload" | rofi_menu "Monitor")
  [ -z "$chosen" ] && exit 1

  local id
  id=$(printf '%s' "$chosen" | awk '{print $1}')
  echo "$id" > "$MON_FILE"
  monitor_label "$id" > "$MON_LABEL_FILE" 2>/dev/null || true
  echo "$id"
}

current_monitor() {
  if [ -f "$MON_FILE" ]; then
    cat "$MON_FILE"
  else
    choose_monitor
  fi
}

choose_property() {
  local mon="$1"

  load_vcp_list

  local prompt
  prompt=$(monitor_prompt "$mon")

  local menu_lines=()
  menu_lines+=("Cambiar monitor...")
  menu_lines+=("Editar características...")

  local code name min max raw disabled norm
  while IFS=';' read -r code name min max; do
    raw=$(trim "$code")
    [ -z "$raw" ] && continue

    disabled=0
    if printf '%s' "$raw" | grep -qE '^#'; then
      # Por si el archivo tiene formato "#10;..." (comentario en el campo code)
      continue
    fi

    norm=$(normalize_vcp_code "$raw" 2>/dev/null) || continue
    name=$(trim "$name")
    menu_lines+=("0x$norm | $name")
  done <<< "$(printf '%s\n' "$VCP_LIST" | grep -vE '^\s*#' | sed '/^\s*$/d')"

  local menu_payload
  menu_payload=$(printf '%s\n' "${menu_lines[@]}")
  debug_log "choose_property prompt=$prompt"
  debug_dump "$menu_payload"
  printf '%s' "$menu_payload" | rofi_menu "$prompt"
}

ask_value() {
  local prompt="$1"
  local current="$2"
  echo "$current" | rofi_input "$prompt"
}

# ================== Flujo principal ==================

main_menu() {
  while true; do
    local mon
    mon=$(current_monitor)

    local line
    line=$(choose_property "$mon")
    [ -z "$line" ] && exit 0

    case "$line" in
      "Cambiar monitor...")
        choose_monitor >/dev/null
        continue
        ;;
      "Editar características...")
        edit_vcp_menu
        continue
        ;;
    esac

    local code_hex name cur
    code_hex=$(printf '%s' "$line" | awk -F'|' '{gsub(/0x/,"",$1); gsub(/ /,"",$1); print $1}')
    name=$(printf '%s' "$line" | awk -F'|' '{gsub(/^ +| +$/,"",$2); print $2}')
    code_hex=$(normalize_vcp_code "$code_hex" 2>/dev/null) || continue

    load_vcp_list

    local min max
    while IFS=';' read -r c n mi ma; do
      c=$(trim "$c")
      c=$(normalize_vcp_code "$c" 2>/dev/null) || continue
      [ "$c" = "$code_hex" ] && { min="$mi"; max="$ma"; break; }
    done <<< "$(printf '%s\n' "$VCP_LIST" | grep -vE '^\s*#' | sed '/^\s*$/d')"

    [ -z "$min" ] && min=0
    [ -z "$max" ] && max=100

    cur=$(get_vcp_value "$mon" "$code_hex")
    [ -z "$cur" ] && cur="$min"

    local new
    new=$(ask_value "$name [$min-$max]" "$cur")
    [ -z "$new" ] && continue

    new=$(printf '%s' "$new" | tr -cd '0-9')

    if [ -z "$new" ]; then
      notify-send "DDC" "Valor vacío para $name"
      continue
    fi

    if [ "$new" -lt "$min" ]; then
      new="$min"
    fi

    set_vcp_value "$mon" "$code_hex" "$new"
    notify-send "DDC" "$(monitor_label "$mon"): $name → $new"
  done
}

main_menu
