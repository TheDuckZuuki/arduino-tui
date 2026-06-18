#!/usr/bin/env bash
# ============================================================
#  arduino-tui  -  A dialog-based TUI for arduino-cli
# ============================================================

set -euo pipefail

# --- Config / state ------------------------------------------
TITLE="Arduino CLI TUI"
BACKTITLE="arduino-tui | arduino-cli wrapper"
LOG_FILE="/tmp/arduino-tui-$$.log"
STATE_FILE="$HOME/.arduino-tui.conf"
FQBN_CACHE_FILE="/tmp/arduino-tui-fqbn-cache-$$.txt"

# Persisted defaults
SKETCH_PATH=""
FQBN=""
PORT=""

# --- Helpers ---------------------------------------------------
load_state() {
  [[ -f "$STATE_FILE" ]] && source "$STATE_FILE" || true
}

save_state() {
  cat >"$STATE_FILE" <<EOF
SKETCH_PATH="${SKETCH_PATH}"
FQBN="${FQBN}"
PORT="${PORT}"
EOF
  # Keep the board choice with the sketch itself, as a leading comment
  # line, so it travels with the file rather than only living globally.
  if [[ -n "$SKETCH_PATH" && -n "$FQBN" ]]; then
    write_board_to_sketch "$SKETCH_PATH" "$FQBN" 2>/dev/null || true
  fi
}

BOARD_LINE_REGEX='^// *board: *(.+)$'

# Find the primary .ino file for a sketch directory.
# Arduino convention: the sketch's main file shares the folder's name.
find_main_ino() {
  local dir="$1"
  local base
  base="$(basename "$dir")"
  if [[ -f "$dir/$base.ino" ]]; then
    echo "$dir/$base.ino"
    return 0
  fi
  # Fallback: first .ino file found in the directory (not recursive)
  local first
  first=$(find "$dir" -maxdepth 1 -name '*.ino' | sort | head -1)
  [[ -n "$first" ]] && echo "$first"
}

# Read the FQBN stored on the first line of the sketch, if any.
# Expects a line like:  // board: arduino:avr:uno
read_board_from_sketch() {
  local sketch_dir="$1"
  local ino
  ino=$(find_main_ino "$sketch_dir") || return 1
  [[ -z "$ino" || ! -f "$ino" ]] && return 1

  local first_line
  first_line=$(head -n 1 "$ino")
  if [[ "$first_line" =~ $BOARD_LINE_REGEX ]]; then
    local val="${BASH_REMATCH[1]}"
    # trim trailing whitespace
    val="${val%%[[:space:]]}"
    echo "$val"
    return 0
  fi
  return 1
}

# Write/update the "// board: <fqbn>" line as the first line of the sketch.
# If the first line already holds a board comment, it's replaced in place.
# Otherwise a new line is prepended, leaving the rest of the file untouched.
write_board_to_sketch() {
  local sketch_dir="$1"
  local fqbn="$2"
  [[ -z "$sketch_dir" || -z "$fqbn" ]] && return 1

  local ino
  ino=$(find_main_ino "$sketch_dir") || return 1
  [[ -z "$ino" || ! -f "$ino" ]] && return 1

  local first_line
  first_line=$(head -n 1 "$ino" 2>/dev/null || echo "")
  local tmp
  tmp=$(mktemp)

  if [[ "$first_line" =~ $BOARD_LINE_REGEX ]]; then
    # Replace existing board line, keep everything else untouched
    { printf '// board: %s\n' "$fqbn"; tail -n +2 "$ino"; } > "$tmp"
  else
    # Prepend new board line
    { printf '// board: %s\n' "$fqbn"; cat "$ino"; } > "$tmp"
  fi

  mv "$tmp" "$ino"
}

require_arduino_cli() {
  if ! command -v arduino-cli &>/dev/null; then
    dialog --backtitle "$BACKTITLE" \
           --title "arduino-cli not found" \
           --msgbox "\narduino-cli is not installed or not in PATH.\n\nInstall it from:\n  https://arduino.github.io/arduino-cli/\n\nOr via curl:\n  curl -fsSL https://raw.githubusercontent.com/arduino/arduino-cli/master/install.sh | sh" \
           14 60
    return 1
  fi
}

show_log() {
  dialog --backtitle "$BACKTITLE" \
         --title "Output Log" \
         --textbox "$LOG_FILE" 24 90
}

# --- arduino-cli wrappers ---------------------------------------
detect_ports() {
  arduino-cli board list --format json 2>/dev/null \
    | python3 -c "
import sys, json
data = json.load(sys.stdin)
ports = data.get('detected_ports') or data  # handle both formats
for entry in ports:
    p = entry.get('port', entry)
    addr = p.get('address','')
    proto = p.get('protocol_label', p.get('protocol',''))
    boards = entry.get('matching_boards') or []
    name = boards[0]['name'] if boards else 'Unknown board'
    print(f'{addr}|{proto}|{name}')
" 2>/dev/null || true
}

list_installed_boards() {
  arduino-cli core list 2>/dev/null | tail -n +2
}

list_installed_libs() {
  arduino-cli lib list 2>/dev/null | tail -n +2
}

# Build/refresh a flat cache of "FQBN|Board Name" for every board
# provided by installed cores. Used to power FQBN autocomplete.
build_fqbn_cache() {
  arduino-cli board listall --format json 2>/dev/null \
    | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
boards = data.get('boards') or []
for b in boards:
    fqbn = b.get('fqbn', '')
    name = b.get('name', '')
    if fqbn:
        print(f'{fqbn}|{name}')
" 2>/dev/null > "$FQBN_CACHE_FILE" || true
}

# ---------------------------------------------------------------
# FQBN autocomplete picker.
# Lets the user type a search term, shows matching FQBNs in a menu,
# and loops back to the search box if they hit Back instead of
# picking something. Returns the chosen FQBN on stdout.
# ---------------------------------------------------------------
pick_fqbn_autocomplete() {
  [[ -s "$FQBN_CACHE_FILE" ]] || build_fqbn_cache

  local term="${1:-}"
  while true; do
    term=$(dialog --backtitle "$BACKTITLE" \
                  --title "FQBN Search" \
                  --ok-label "Search" \
                  --cancel-label "Back" \
                  --inputbox "\nType part of a board name or FQBN to filter\n(e.g. uno, esp32, nano, mega):" \
                  10 65 "$term" \
                  3>&1 1>&2 2>&3)
    local rc=$?
    [[ $rc -ne 0 ]] && return 1   # Back -> bail out of autocomplete

    if [[ -z "$term" ]]; then
      continue
    fi

    local matches
    matches=$(grep -i -- "$term" "$FQBN_CACHE_FILE" 2>/dev/null | head -100) || true

    if [[ -z "$matches" ]]; then
      dialog --backtitle "$BACKTITLE" \
             --title "No matches" \
             --msgbox "\nNo boards matched '${term}'.\n\nTry a shorter or different search term." \
             9 55
      continue
    fi

    local menu_items=() idx=1
    while IFS='|' read -r fqbn name; do
      menu_items+=("$idx" "${name}  -  ${fqbn}")
      (( idx++ ))
    done <<< "$matches"

    local sel
    sel=$(dialog --backtitle "$BACKTITLE" \
                 --title "Matching Boards (${term})" \
                 --ok-label "Select" \
                 --cancel-label "Back" \
                 --menu "\nSelect a board, or go Back to search again:" \
                 20 78 "$(( ${#menu_items[@]} / 2 > 15 ? 15 : ${#menu_items[@]} / 2 ))" \
                 "${menu_items[@]}" \
                 3>&1 1>&2 2>&3)
    rc=$?
    if [[ $rc -ne 0 ]]; then
      continue   # Back to search box
    fi

    local chosen_fqbn
    chosen_fqbn=$(echo "$matches" | sed -n "${sel}p" | cut -d'|' -f1)
    echo "$chosen_fqbn"
    return 0
  done
}

# --- Screens -----------------------------------------------------

# ---------- Select Sketch ----------
screen_select_sketch() {
  local path
  path=$(dialog --backtitle "$BACKTITLE" \
                --title "Select Sketch" \
                --ok-label "Set" \
                --cancel-label "Back" \
                --inputbox "\nEnter full path to your sketch (.ino file or sketch folder):" \
                10 70 "$SKETCH_PATH" \
                3>&1 1>&2 2>&3) || return
  [[ -z "$path" ]] && return
  path="${path/#\~/$HOME}"
  if [[ "$path" == *.ino ]]; then
    path="$(dirname "$path")"
  fi
  if [[ ! -d "$path" ]]; then
    dialog --backtitle "$BACKTITLE" \
           --title "Not found" \
           --msgbox "\nDirectory not found:\n  $path" 8 60
    return
  fi
  SKETCH_PATH="$path"

  # If the sketch already has a "// board: <fqbn>" line, load it so the
  # board travels with the sketch instead of staying on whatever was
  # last configured.
  local sketch_fqbn
  if sketch_fqbn=$(read_board_from_sketch "$SKETCH_PATH"); then
    FQBN="$sketch_fqbn"
    dialog --backtitle "$BACKTITLE" \
           --title "Board loaded from sketch" \
           --msgbox "\nFound board config in sketch:\n\n  $FQBN" \
           9 60
  fi

  save_state
}

# ---------- Select Board (FQBN) ----------
screen_select_board() {
  require_arduino_cli || return

  local choice
  choice=$(dialog --backtitle "$BACKTITLE" \
                  --title "Board Selection" \
                  --cancel-label "Back" \
                  --menu "\nHow would you like to set the FQBN?" \
                  13 62 3 \
                  1 "Search / autocomplete (all installed cores)" \
                  2 "Enter FQBN manually" \
                  3 "Auto-detect from connected board" \
                  3>&1 1>&2 2>&3) || return

  case "$choice" in
  1)
    local raw_cores
    raw_cores=$(arduino-cli core list 2>/dev/null | tail -n +2) || true
    if [[ -z "$raw_cores" ]]; then
      dialog --backtitle "$BACKTITLE" \
             --title "No cores installed" \
             --msgbox "\nNo board cores are installed yet.\nUse 'Board Manager' to install one first." \
             9 58
      return
    fi

    build_fqbn_cache
    local picked
    picked=$(pick_fqbn_autocomplete "") || return
    [[ -n "$picked" ]] && FQBN="$picked" && save_state
    ;;
  2)
    local fqbn
    fqbn=$(dialog --backtitle "$BACKTITLE" \
                  --title "Manual FQBN" \
                  --ok-label "Set" \
                  --cancel-label "Back" \
                  --inputbox "\nEnter the Fully Qualified Board Name:\n  (e.g. arduino:avr:uno)" \
                  9 65 "$FQBN" \
                  3>&1 1>&2 2>&3) || return
    [[ -n "$fqbn" ]] && FQBN="$fqbn" && save_state
    ;;
  3)
    dialog --backtitle "$BACKTITLE" \
           --title "Detecting boards..." \
           --infobox "\nScanning connected USB devices..." 6 45
    sleep 0.5
    local detected
    detected=$(detect_ports)
    if [[ -z "$detected" ]]; then
      dialog --backtitle "$BACKTITLE" \
             --title "No boards found" \
             --msgbox "\nNo boards detected on any port.\n\nMake sure your board is connected and drivers are installed." \
             9 60
      return
    fi
    local menu_items=() idx=1
    while IFS='|' read -r addr proto name; do
      menu_items+=("$idx" "${addr}  -  ${name}  (${proto})")
      (( idx++ ))
    done <<< "$detected"
    local sel
    sel=$(dialog --backtitle "$BACKTITLE" \
                 --title "Detected Boards" \
                 --cancel-label "Back" \
                 --menu "\nSelect a board to auto-fill FQBN and Port:" \
                 16 72 "${#menu_items[@]}" \
                 "${menu_items[@]}" \
                 3>&1 1>&2 2>&3) || return
    local chosen_addr
    chosen_addr=$(echo "$detected" | sed -n "${sel}p" | cut -d'|' -f1)
    PORT="$chosen_addr"

    local chosen_name
    chosen_name=$(echo "$detected" | sed -n "${sel}p" | cut -d'|' -f3)
    local auto_fqbn=""
    case "${chosen_name,,}" in
      *"uno"*)           auto_fqbn="arduino:avr:uno" ;;
      *"nano"*)          auto_fqbn="arduino:avr:nano" ;;
      *"mega"*)          auto_fqbn="arduino:avr:mega" ;;
      *"leonardo"*)      auto_fqbn="arduino:avr:leonardo" ;;
      *"micro"*)         auto_fqbn="arduino:avr:micro" ;;
      *"due"*)           auto_fqbn="arduino:sam:arduino_due_x" ;;
      *"mkr"*)           auto_fqbn="arduino:samd:mkr1000" ;;
      *"esp32"*)         auto_fqbn="esp32:esp32:esp32" ;;
      *"esp8266"*)       auto_fqbn="esp8266:esp8266:nodemcuv2" ;;
      *"pico"*)          auto_fqbn="rp2040:rp2040:rpipico" ;;
      *)                 auto_fqbn="$FQBN" ;;
    esac

    local fqbn
    fqbn=$(dialog --backtitle "$BACKTITLE" \
                  --title "Confirm FQBN" \
                  --ok-label "Set" \
                  --cancel-label "Back" \
                  --inputbox "\nDetected board: ${chosen_name}\nPort set to: ${PORT}\n\nConfirm / edit FQBN:" \
                  12 65 "$auto_fqbn" \
                  3>&1 1>&2 2>&3) || return
    [[ -n "$fqbn" ]] && FQBN="$fqbn"
    save_state
    ;;
  esac
}

# ---------- Select Port ----------
screen_select_port() {
  require_arduino_cli || return

  dialog --backtitle "$BACKTITLE" \
         --title "Scanning ports..." \
         --infobox "\nLooking for connected USB devices..." 6 45
  sleep 0.3

  local detected
  detected=$(detect_ports)

  local menu_items=()
  local idx=1
  if [[ -n "$detected" ]]; then
    while IFS='|' read -r addr proto name; do
      menu_items+=("$addr" "${name}  (${proto})")
      (( idx++ ))
    done <<< "$detected"
  fi
  menu_items+=("manual" "Enter port manually")

  local sel
  sel=$(dialog --backtitle "$BACKTITLE" \
               --title "Select Upload Port" \
               --cancel-label "Back" \
               --menu "\nAvailable serial / network ports:" \
               18 70 "$((${#menu_items[@]} / 2))" \
               "${menu_items[@]}" \
               3>&1 1>&2 2>&3) || return

  if [[ "$sel" == "manual" ]]; then
    local p
    p=$(dialog --backtitle "$BACKTITLE" \
               --title "Manual Port" \
               --ok-label "Set" \
               --cancel-label "Back" \
               --inputbox "\nEnter port path (e.g. /dev/ttyUSB0  or  /dev/ttyACM0):" \
               9 65 "$PORT" \
               3>&1 1>&2 2>&3) || return
    [[ -n "$p" ]] && PORT="$p"
  else
    PORT="$sel"
  fi
  save_state
}

# ---------- Compile ----------
screen_compile() {
  require_arduino_cli || return

  if [[ -z "$SKETCH_PATH" ]]; then
    dialog --backtitle "$BACKTITLE" --title "No sketch" \
           --msgbox "\nNo sketch selected. Please set a sketch path first." 8 55
    return
  fi
  if [[ -z "$FQBN" ]]; then
    dialog --backtitle "$BACKTITLE" --title "No board" \
           --msgbox "\nNo board (FQBN) selected. Please configure the board first." 8 60
    return
  fi

  dialog --backtitle "$BACKTITLE" \
         --title "Compile" \
         --yes-label "Compile" --no-label "Back" \
         --yesno "\nCompile sketch?\n\n  Sketch : $SKETCH_PATH\n  Board  : $FQBN" \
         11 68 || return

  : >"$LOG_FILE"
  arduino-cli compile \
    --fqbn "$FQBN" \
    --verbose \
    "$SKETCH_PATH" \
    2>&1 | tee "$LOG_FILE" &
  local pid=$!

  dialog --backtitle "$BACKTITLE" \
         --title "Compiling..." \
         --tailbox "$LOG_FILE" 22 84 &
  local dlg=$!
  wait "$pid"
  local rc=${PIPESTATUS[0]:-$?}
  sleep 0.5
  kill "$dlg" 2>/dev/null || true
  wait "$dlg" 2>/dev/null || true

  if [[ $rc -eq 0 ]]; then
    dialog --backtitle "$BACKTITLE" \
           --title "Compile successful" \
           --yes-label "View log" --no-label "Back" \
           --yesno "\nCompilation finished successfully!\n\nView full output log?" 9 55
    [[ $? -eq 0 ]] && show_log
  else
    dialog --backtitle "$BACKTITLE" \
           --title "Compile failed" \
           --yes-label "View log" --no-label "Back" \
           --yesno "\nCompilation FAILED (exit $rc).\n\nView error log?" 9 55
    [[ $? -eq 0 ]] && show_log
  fi
}

# ---------- Upload ----------
screen_upload() {
  require_arduino_cli || return

  if [[ -z "$SKETCH_PATH" ]]; then
    dialog --backtitle "$BACKTITLE" --title "No sketch" \
           --msgbox "\nNo sketch selected. Please set a sketch path first." 8 55
    return
  fi
  if [[ -z "$FQBN" ]]; then
    dialog --backtitle "$BACKTITLE" --title "No board" \
           --msgbox "\nNo board (FQBN) selected. Please configure the board first." 8 60
    return
  fi
  if [[ -z "$PORT" ]]; then
    dialog --backtitle "$BACKTITLE" --title "No port" \
           --msgbox "\nNo upload port selected. Please set the port first." 8 55
    return
  fi

  dialog --backtitle "$BACKTITLE" \
         --title "Upload" \
         --yes-label "Upload" --no-label "Back" \
         --yesno "\nUpload sketch?\n\n  Sketch : $SKETCH_PATH\n  Board  : $FQBN\n  Port   : $PORT" \
         13 68 || return

  : >"$LOG_FILE"
  arduino-cli upload \
    --fqbn "$FQBN" \
    --port "$PORT" \
    --verbose \
    "$SKETCH_PATH" \
    2>&1 | tee "$LOG_FILE" &
  local pid=$!

  dialog --backtitle "$BACKTITLE" \
         --title "Uploading..." \
         --tailbox "$LOG_FILE" 22 84 &
  local dlg=$!
  wait "$pid"
  local rc=${PIPESTATUS[0]:-$?}
  sleep 0.5
  kill "$dlg" 2>/dev/null || true
  wait "$dlg" 2>/dev/null || true

  if [[ $rc -eq 0 ]]; then
    dialog --backtitle "$BACKTITLE" \
           --title "Upload successful" \
           --yes-label "View log" --no-label "Back" \
           --yesno "\nSketch uploaded successfully!\n\nView full output log?" 9 55
    [[ $? -eq 0 ]] && show_log
  else
    dialog --backtitle "$BACKTITLE" \
           --title "Upload failed" \
           --yes-label "View log" --no-label "Back" \
           --yesno "\nUpload FAILED (exit $rc).\n\nView error log?" 9 55
    [[ $? -eq 0 ]] && show_log
  fi
}

# ---------- Compile + Upload ----------
screen_compile_and_upload() {
  require_arduino_cli || return

  if [[ -z "$SKETCH_PATH" || -z "$FQBN" || -z "$PORT" ]]; then
    dialog --backtitle "$BACKTITLE" --title "Incomplete config" \
           --msgbox "\nPlease configure all three before running:\n\n  Sketch : ${SKETCH_PATH:-<not set>}\n  Board  : ${FQBN:-<not set>}\n  Port   : ${PORT:-<not set>}" \
           12 65
    return
  fi

  dialog --backtitle "$BACKTITLE" \
         --title "Compile & Upload" \
         --yes-label "Go" --no-label "Back" \
         --yesno "\nCompile and upload sketch?\n\n  Sketch : $SKETCH_PATH\n  Board  : $FQBN\n  Port   : $PORT" \
         13 68 || return

  # --- Compile ---
  : >"$LOG_FILE"
  arduino-cli compile \
    --fqbn "$FQBN" \
    --verbose \
    "$SKETCH_PATH" \
    2>&1 | tee "$LOG_FILE" &
  local pid=$!

  dialog --backtitle "$BACKTITLE" \
         --title "Compiling..." \
         --tailbox "$LOG_FILE" 22 84 &
  local dlg=$!
  wait "$pid"
  local rc=${PIPESTATUS[0]:-$?}
  sleep 0.4
  kill "$dlg" 2>/dev/null || true
  wait "$dlg" 2>/dev/null || true

  if [[ $rc -ne 0 ]]; then
    dialog --backtitle "$BACKTITLE" \
           --title "Compile failed - upload aborted" \
           --yes-label "View log" --no-label "Back" \
           --yesno "\nCompilation FAILED. Upload was not attempted.\n\nView error log?" 9 60
    [[ $? -eq 0 ]] && show_log
    return
  fi

  # --- Upload ---
  echo "" >>"$LOG_FILE"
  echo "================ UPLOAD ================" >>"$LOG_FILE"
  arduino-cli upload \
    --fqbn "$FQBN" \
    --port "$PORT" \
    --verbose \
    "$SKETCH_PATH" \
    2>&1 | tee -a "$LOG_FILE" &
  local pid2=$!

  dialog --backtitle "$BACKTITLE" \
         --title "Uploading..." \
         --tailbox "$LOG_FILE" 22 84 &
  local dlg2=$!
  wait "$pid2"
  local rc2=${PIPESTATUS[0]:-$?}
  sleep 0.4
  kill "$dlg2" 2>/dev/null || true
  wait "$dlg2" 2>/dev/null || true

  if [[ $rc2 -eq 0 ]]; then
    dialog --backtitle "$BACKTITLE" \
           --title "Done" \
           --yes-label "View log" --no-label "Back" \
           --yesno "\nCompile & Upload completed successfully!" 9 55
    [[ $? -eq 0 ]] && show_log
  else
    dialog --backtitle "$BACKTITLE" \
           --title "Upload failed" \
           --yes-label "View log" --no-label "Back" \
           --yesno "\nUpload FAILED (exit $rc2).\n\nView error log?" 9 55
    [[ $? -eq 0 ]] && show_log
  fi
}

# ---------- Library Manager ----------
screen_library_manager() {
  require_arduino_cli || return

  local choice
  choice=$(dialog --backtitle "$BACKTITLE" \
                  --title "Library Manager" \
                  --cancel-label "Back" \
                  --menu "\nWhat would you like to do?" \
                  13 60 4 \
                  1 "Search & install a library" \
                  2 "Update all libraries" \
                  3 "List installed libraries" \
                  4 "Uninstall a library" \
                  3>&1 1>&2 2>&3) || return

  case "$choice" in
  1)
    local query
    query=$(dialog --backtitle "$BACKTITLE" \
                   --title "Search Library" \
                   --ok-label "Search" --cancel-label "Back" \
                   --inputbox "\nEnter library name or keyword to search:" \
                   9 60 "" \
                   3>&1 1>&2 2>&3) || return
    [[ -z "$query" ]] && return

    dialog --backtitle "$BACKTITLE" \
           --title "Searching..." \
           --infobox "\nSearching for '${query}'..." 6 50
    local results
    results=$(arduino-cli lib search "$query" 2>&1 | grep -E "^Name:" | \
      sed -E 's/^Name: "(.*)"/\1/' | head -30) || true

    if [[ -z "$results" ]]; then
      dialog --backtitle "$BACKTITLE" --title "No results" \
             --msgbox "\nNo libraries found matching '${query}'." 8 55
      return
    fi

    local menu_items=() idx=1
    while IFS= read -r lib; do
      menu_items+=("$idx" "$lib")
      (( idx++ ))
    done <<< "$results"

    local sel
    sel=$(dialog --backtitle "$BACKTITLE" \
                 --title "Search Results" \
                 --cancel-label "Back" \
                 --menu "\nSelect a library to install:" \
                 22 70 "${#menu_items[@]}" \
                 "${menu_items[@]}" \
                 3>&1 1>&2 2>&3) || return

    local lib_name
    lib_name=$(echo "$results" | sed -n "${sel}p")

    dialog --backtitle "$BACKTITLE" \
           --title "Installing..." \
           --infobox "\nInstalling '${lib_name}'..." 6 55

    : >"$LOG_FILE"
    arduino-cli lib install "$lib_name" 2>&1 | tee "$LOG_FILE"
    local rc=$?
    if [[ $rc -eq 0 ]]; then
      dialog --backtitle "$BACKTITLE" --title "Installed" \
             --msgbox "\n'${lib_name}' installed successfully!" 8 55
    else
      dialog --backtitle "$BACKTITLE" --title "Install failed" \
             --yes-label "View log" --no-label "Back" \
             --yesno "\nInstallation failed.\n\nView log?" 8 50
      [[ $? -eq 0 ]] && show_log
    fi
    ;;
  2)
    dialog --backtitle "$BACKTITLE" \
           --title "Updating all libraries..." \
           --infobox "\nUpdating library index and all installed libraries..." 7 55
    : >"$LOG_FILE"
    {
      arduino-cli lib update-index
      arduino-cli lib upgrade
    } 2>&1 | tee "$LOG_FILE"
    local rc=$?
    if [[ $rc -eq 0 ]]; then
      dialog --backtitle "$BACKTITLE" --title "Updated" \
             --yes-label "View log" --no-label "Back" \
             --yesno "\nAll libraries updated!\n\nView log?" 8 50
      [[ $? -eq 0 ]] && show_log
    else
      dialog --backtitle "$BACKTITLE" --title "Error" \
             --yes-label "View log" --no-label "Back" \
             --yesno "\nUpdate encountered errors.\n\nView log?" 8 50
      [[ $? -eq 0 ]] && show_log
    fi
    ;;
  3)
    local libs
    libs=$(list_installed_libs)
    if [[ -z "$libs" ]]; then
      dialog --backtitle "$BACKTITLE" --title "Installed Libraries" \
             --msgbox "\nNo libraries installed." 8 45
      return
    fi
    dialog --backtitle "$BACKTITLE" \
           --title "Installed Libraries" \
           --textbox /dev/stdin 22 90 <<< "$libs"
    ;;
  4)
    local libs
    libs=$(arduino-cli lib list 2>/dev/null | tail -n +2 | awk '{print NR, $1}')
    if [[ -z "$libs" ]]; then
      dialog --backtitle "$BACKTITLE" --title "No libraries" \
             --msgbox "\nNo libraries installed." 8 45
      return
    fi
    local menu_items=()
    while read -r idx name; do
      menu_items+=("$idx" "$name")
    done <<< "$libs"

    local sel
    sel=$(dialog --backtitle "$BACKTITLE" \
                 --title "Uninstall Library" \
                 --cancel-label "Back" \
                 --menu "\nSelect a library to uninstall:" \
                 22 65 "${#menu_items[@]}" \
                 "${menu_items[@]}" \
                 3>&1 1>&2 2>&3) || return

    local lib_name
    lib_name=$(arduino-cli lib list 2>/dev/null | tail -n +2 | awk "NR==$sel{print \$1}")
    dialog --backtitle "$BACKTITLE" \
           --title "Confirm" \
           --yes-label "Uninstall" --no-label "Back" \
           --yesno "\nUninstall library '${lib_name}'?" 8 50 || return

    arduino-cli lib uninstall "$lib_name" 2>&1
    dialog --backtitle "$BACKTITLE" --title "Removed" \
           --msgbox "\n'${lib_name}' has been uninstalled." 8 50
    ;;
  esac
}

# ---------- Board Manager ----------
screen_board_manager() {
  require_arduino_cli || return

  local choice
  choice=$(dialog --backtitle "$BACKTITLE" \
                  --title "Board Manager" \
                  --cancel-label "Back" \
                  --menu "\nWhat would you like to do?" \
                  13 62 4 \
                  1 "Install a board core" \
                  2 "Update all cores" \
                  3 "List installed cores" \
                  4 "Add additional board manager URL" \
                  3>&1 1>&2 2>&3) || return

  case "$choice" in
  1)
    local query
    query=$(dialog --backtitle "$BACKTITLE" \
                   --title "Search Board Core" \
                   --ok-label "Search" --cancel-label "Back" \
                   --inputbox "\nEnter board name / platform to search for:\n(e.g. arduino avr, esp32, rp2040)" \
                   10 65 "" \
                   3>&1 1>&2 2>&3) || return
    [[ -z "$query" ]] && return

    dialog --backtitle "$BACKTITLE" \
           --title "Searching..." \
           --infobox "\nSearching board index for '${query}'..." 6 55
    arduino-cli core update-index &>/dev/null || true

    local results
    results=$(arduino-cli core search "$query" 2>/dev/null | tail -n +2 | head -20) || true

    if [[ -z "$results" ]]; then
      dialog --backtitle "$BACKTITLE" --title "No results" \
             --msgbox "\nNo board cores found matching '${query}'.\n\nTip: You may need to add a custom board manager URL first." \
             10 60
      return
    fi

    local menu_items=() idx=1
    while IFS= read -r line; do
      local core_id core_ver
      core_id=$(echo "$line" | awk '{print $1}')
      core_ver=$(echo "$line" | awk '{print $2}')
      menu_items+=("$idx" "${core_id}  v${core_ver}")
      (( idx++ ))
    done <<< "$results"

    local sel
    sel=$(dialog --backtitle "$BACKTITLE" \
                 --title "Available Cores" \
                 --cancel-label "Back" \
                 --menu "\nSelect a core to install:" \
                 22 72 "${#menu_items[@]}" \
                 "${menu_items[@]}" \
                 3>&1 1>&2 2>&3) || return

    local core_id
    core_id=$(echo "$results" | sed -n "${sel}p" | awk '{print $1}')

    : >"$LOG_FILE"
    arduino-cli core install "$core_id" 2>&1 | tee "$LOG_FILE" &
    local pid=$!

    dialog --backtitle "$BACKTITLE" \
           --title "Installing core ${core_id}..." \
           --tailbox "$LOG_FILE" 22 84 &
    local dlg=$!
    wait "$pid"
    local rc=${PIPESTATUS[0]:-$?}
    sleep 0.4
    kill "$dlg" 2>/dev/null || true
    wait "$dlg" 2>/dev/null || true

    if [[ $rc -eq 0 ]]; then
      dialog --backtitle "$BACKTITLE" --title "Installed" \
             --msgbox "\nCore '${core_id}' installed successfully!" 8 58
      # Refresh the FQBN cache since a new core just landed
      build_fqbn_cache
    else
      dialog --backtitle "$BACKTITLE" --title "Install failed" \
             --yes-label "View log" --no-label "Back" \
             --yesno "\nInstallation failed.\n\nView log?" 8 50
      [[ $? -eq 0 ]] && show_log
    fi
    ;;
  2)
    : >"$LOG_FILE"
    arduino-cli core update-index 2>&1 | tee "$LOG_FILE"
    arduino-cli core upgrade 2>&1 | tee -a "$LOG_FILE"
    build_fqbn_cache
    dialog --backtitle "$BACKTITLE" --title "Updated" \
           --yes-label "View log" --no-label "Back" \
           --yesno "\nAll cores updated!\n\nView log?" 8 50
    [[ $? -eq 0 ]] && show_log
    ;;
  3)
    local cores
    cores=$(list_installed_boards)
    if [[ -z "$cores" ]]; then
      dialog --backtitle "$BACKTITLE" --title "No cores installed" \
             --msgbox "\nNo board cores are installed." 8 45
      return
    fi
    dialog --backtitle "$BACKTITLE" \
           --title "Installed Board Cores" \
           --textbox /dev/stdin 22 90 <<< "$cores"
    ;;
  4)
    local preset
    preset=$(dialog --backtitle "$BACKTITLE" \
                    --title "Add Board Manager URL" \
                    --cancel-label "Back" \
                    --menu "\nChoose a preset URL or enter custom:" \
                    16 78 5 \
                    1 "ESP32            https://raw.githubusercontent.com/espressif/arduino-esp32/gh-pages/package_esp32_index.json" \
                    2 "ESP8266          https://arduino.esp8266.com/stable/package_esp8266com_index.json" \
                    3 "RP2040 (Earle)   https://github.com/earlephilhower/arduino-pico/releases/download/global/package_rp2040_index.json" \
                    4 "STM32 (STM)      https://github.com/stm32duino/BoardManagerFiles/raw/main/package_stmicroelectronics_index.json" \
                    5 "Enter custom URL" \
                    3>&1 1>&2 2>&3) || return

    local url=""
    case "$preset" in
      1) url="https://raw.githubusercontent.com/espressif/arduino-esp32/gh-pages/package_esp32_index.json" ;;
      2) url="https://arduino.esp8266.com/stable/package_esp8266com_index.json" ;;
      3) url="https://github.com/earlephilhower/arduino-pico/releases/download/global/package_rp2040_index.json" ;;
      4) url="https://github.com/stm32duino/BoardManagerFiles/raw/main/package_stmicroelectronics_index.json" ;;
      5)
        url=$(dialog --backtitle "$BACKTITLE" \
                     --title "Custom URL" \
                     --ok-label "Add" --cancel-label "Back" \
                     --inputbox "\nEnter the board manager URL:" \
                     9 80 "" \
                     3>&1 1>&2 2>&3) || return
        ;;
    esac
    [[ -z "$url" ]] && return

    local current_urls
    current_urls=$(arduino-cli config get board_manager.additional_urls 2>/dev/null | \
      grep -oP '".*?"' | tr -d '"' | tr '\n' ',') || true
    current_urls="${current_urls}${url}"
    current_urls="${current_urls%,}"

    IFS=',' read -ra url_arr <<< "$current_urls"
    local unique_urls
    unique_urls=$(printf '%s\n' "${url_arr[@]}" | sort -u | tr '\n' ',' | sed 's/,$//')

    arduino-cli config set board_manager.additional_urls "$unique_urls" 2>&1
    arduino-cli core update-index 2>&1 | tee "$LOG_FILE"

    dialog --backtitle "$BACKTITLE" --title "URL added" \
           --msgbox "\nBoard manager URL added and index updated!\n\nYou can now search and install cores from that platform." \
           11 65
    ;;
  esac
}

# ---------- Status Screen ----------
screen_status() {
  local arduino_ver=""
  if command -v arduino-cli &>/dev/null; then
    arduino_ver=$(arduino-cli version 2>/dev/null | head -1) || arduino_ver="(error)"
  else
    arduino_ver="NOT INSTALLED"
  fi

  local cores_count=0 libs_count=0
  if command -v arduino-cli &>/dev/null; then
    cores_count=$(arduino-cli core list 2>/dev/null | tail -n +2 | wc -l)
    libs_count=$(arduino-cli lib list 2>/dev/null | tail -n +2 | wc -l)
  fi

  dialog --backtitle "$BACKTITLE" \
         --title "Status & Configuration" \
         --msgbox "\
Current Settings
----------------
  Sketch  : ${SKETCH_PATH:-<not set>}
  FQBN    : ${FQBN:-<not set>}
  Port    : ${PORT:-<not set>}

  (FQBN is also saved as a '// board:' comment
   on line 1 of the sketch's .ino file)

arduino-cli
-----------
  ${arduino_ver}
  Installed cores    : ${cores_count}
  Installed libraries: ${libs_count}" \
         18 62
}

# --- Main Menu ----------------------------------------------------
main_menu() {
  while true; do
    local sketch_disp fqbn_disp port_disp
    sketch_disp="${SKETCH_PATH:-<not set>}"
    fqbn_disp="${FQBN:-<not set>}"
    port_disp="${PORT:-<not set>}"

    local choice
    choice=$(dialog --backtitle "$BACKTITLE" \
                    --title "$TITLE" \
                    --cancel-label "Back" \
                    --menu "\n  Sketch : ${sketch_disp}\n  Board  : ${fqbn_disp}\n  Port   : ${port_disp}\n" \
                    23 72 10 \
                    1 "Set Sketch Path" \
                    2 "Configure Board (FQBN)" \
                    3 "Select Upload Port" \
                    4 "Compile Only" \
                    5 "Upload Only" \
                    6 "Compile & Upload" \
                    7 "Library Manager" \
                    8 "Board Manager" \
                    9 "Status & Configuration" \
                    0 "Quit" \
                    3>&1 1>&2 2>&3)
    local rc=$?

    # Cancel/Esc on the main menu = "Back" has nowhere to go, so just
    # loop again (re-show the main menu) instead of exiting.
    if [[ $rc -ne 0 ]]; then
      continue
    fi

    case "$choice" in
      1) screen_select_sketch ;;
      2) screen_select_board ;;
      3) screen_select_port ;;
      4) screen_compile ;;
      5) screen_upload ;;
      6) screen_compile_and_upload ;;
      7) screen_library_manager ;;
      8) screen_board_manager ;;
      9) screen_status ;;
      0)
        dialog --backtitle "$BACKTITLE" \
               --title "Quit" \
               --yes-label "Quit" --no-label "Back" \
               --yesno "\nQuit arduino-tui?" 7 40
        [[ $? -eq 0 ]] && break
        ;;
    esac
  done
}

# --- Entry Point ----------------------------------------------------
cleanup() {
  rm -f "$LOG_FILE" "$FQBN_CACHE_FILE"
  clear
}
trap cleanup EXIT INT TERM

clear
load_state
main_menu
