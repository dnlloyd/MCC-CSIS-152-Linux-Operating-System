#!/usr/bin/env bash
# grade_history_json.sh
#
# Grades student shell history against required commands defined in JSON.
# Total score is always 25 points, regardless of command count.
#
# Safe on GNU bash 5.2.x:
# - Parses JSON without stdin-drain traps
# - Avoids set -e "silent exits" for expected non-zero commands (compgen, getent, etc.)
# - Always prints a row per student, even if history is missing
#
# Usage:
#   sudo ./grade_history_json.sh 01-Introduction-to-Linux.json
#
# JSON format:
# [
#   {"slide": 9, "command": "systemctl list-units --type=service --all"},
#   {"slide": 14, "command": "uname -r"}
# ]

set -euo pipefail

if [[ -t 1 && "${NO_COLOR:-}" != "1" ]]; then
  BOLD=$'\e[1m'
  ITALIC=$'\e[3m'
  BLUE=$'\e[94m'
  RESET=$'\e[0m'
else
  BOLD=''
  RESET=''
  ITALIC=''
  BLUE=''
fi

# ITALIC="\e[3m"
# BOLD=$'\e[1m'
# RESET="\e[0m"

TOTAL_POINTS=25

usage() {
  echo "Usage: sudo $0 required_commands.json" >&2
  exit 2
}

[[ $# -eq 1 ]] || usage
JSON_ARG="$1"

if [[ -f "$JSON_ARG" ]]; then
  JSON_FILE="$JSON_ARG"
else
  JSON_FILE="/usr/local/share/cli_grader/${JSON_ARG}.json"
fi

[[ -f "$JSON_FILE" ]] || { echo "ERROR: File not found: $JSON_FILE" >&2; exit 2; }

command -v jq >/dev/null 2>&1 || { echo "ERROR: jq is required but not installed." >&2; exit 2; }

# Validate JSON shape early (top-level must be a non-empty array)
jq -e 'type == "array" and length > 0' "$JSON_FILE" >/dev/null || {
  echo "ERROR: JSON must be a non-empty array of {slide, command} objects." >&2
  exit 2
}

# ---- Parse JSON safely (no stdin-drain risks) ----
slides=()
commands=()

# Slurp jq output first, then parse each TSV row via here-string.
mapfile -t rows < <(jq -r '.[] | [.slide, .command] | @tsv' "$JSON_FILE")

for row in "${rows[@]}"; do
  IFS=$'\t' read -r slide cmd <<<"$row"
  [[ -n "${slide:-}" && -n "${cmd:-}" ]] || {
    echo "ERROR: Bad row in JSON (expected slide+command): $row" >&2
    exit 2
  }
  slides+=("$slide")
  commands+=("$cmd")
done

NUM_CMDS="${#commands[@]}"
[[ $NUM_CMDS -gt 0 ]] || { echo "ERROR: No commands parsed from JSON." >&2; exit 2; }

# Helpful debug (you can remove later)
# echo "Parsed ${#slides[@]} items:"
# for i in "${!slides[@]}"; do
#   printf '  slide %s => %s\n' "${slides[$i]}" "${commands[$i]}"
# done

# ---- Scoring math ----
base_points=$(( TOTAL_POINTS / NUM_CMDS ))
remainder=$(( TOTAL_POINTS - (base_points * NUM_CMDS) ))

# Regex helper (whitespace tolerant, regex-escaped)
to_fuzzy_regex() {
  local s="$1"
  s="$(printf '%s' "$s" | sed -E 's/[][(){}.+*?^$|\\]/\\&/g')"
  s="$(printf '%s' "$s" | sed -E 's/[[:space:]]+/\\s+/g')"
  printf '%s' "$s"
}

# ---- Student list (use your exact rule) ----
students=($(awk -F: '/:x:10[0-9][0-9]/ && $1 !~ /ec2-user|bastion/ {print $1}' /etc/passwd))

# echo "Students matched: ${#students[@]}"
if [[ ${#students[@]} -eq 0 ]]; then
  echo "No students matched your /etc/passwd UID filter." >&2
  exit 1
fi

# ---- Output header ----
printf "%s%-18s %7s %7s  %s%s\n" "$BLUE" "STUDENT" "FOUND" "POINTS" "SLIDE FOR MISSING COMMAND" "$RESET"

printf "%s%-18s %7s %7s  %s%s\n" "$BLUE" "------------------" "-----" "------" "------------------------------" "$RESET"


# ---- Grade each student ----
for user in "${students[@]}"; do
  # Resolve home directory; never let failure exit the script
  pwent="$(getent passwd "$user" || true)"
  if [[ -z "$pwent" ]]; then
    printf "%-18s %7s %7s  %s\n" "$user" "0/$NUM_CMDS" "0" "no passwd entry"
    continue
  fi
  home="$(cut -d: -f6 <<<"$pwent")"

  history_files=()

  # Primary history file
  [[ -f "$home/.bash_history" ]] && history_files+=("$home/.bash_history")

  # Rotated history files (guard compgen so set -e doesn't kill the script)
  if compgen -G "$home/.bash_history.*" >/dev/null 2>&1; then
    for f in "$home"/.bash_history.*; do
      [[ -f "$f" ]] && history_files+=("$f")
    done
  fi

  if [[ ${#history_files[@]} -eq 0 ]]; then
    printf "%-18s %7s %7s  %s\n" "$user" "0/$NUM_CMDS" "0" "no history files"
    continue
  fi

  # Read history; never allow failures to exit the script
  # Strip bash timestamp lines like "#1700000000"
  history="$(cat "${history_files[@]}" 2>/dev/null | sed -E '/^#[0-9]{9,}$/d' || true)"

  found_flags=()
  found_count=0

  for cmd in "${commands[@]}"; do
    rx="$(to_fuzzy_regex "$cmd")"
    # Use a here-string so grep never reads the script's stdin
    if grep -Pq -- "(^|[;[:space:]])${rx}([;[:space:]]|\$)" <<<"$history" 2>/dev/null; then
      found_flags+=(1)
      found_count=$((found_count + 1))   # SAFE under set -e
    else
      found_flags+=(0)
    fi
  done

  # Integer scoring with remainder distributed across earliest-found commands
  points=$((found_count * base_points))
  extra=0
  for i in "${!found_flags[@]}"; do
    (( extra >= remainder )) && break
    if [[ ${found_flags[$i]} -eq 1 ]]; then
      points=$((points + 1))
      extra=$((extra + 1))
    fi
  done

  # Missing list with slide numbers
  missing=()
  for i in "${!commands[@]}"; do
    if [[ ${found_flags[$i]} -eq 0 ]]; then
      missing+=("slide ${slides[$i]}")
    fi
  done

  if [[ ${#missing[@]} -eq 0 ]]; then
    missing_str="(none)"
  else
    missing_str="${missing[0]}"
    for ((j=1; j<${#missing[@]}; j++)); do
      missing_str+=" | ${missing[$j]}"
    done
  fi

  printf "%-18s %7s %7s  %s\n" \
    "$user" \
    "${found_count}/${NUM_CMDS}" \
    "$points" \
    "$missing_str"
done

echo
echo -e "${ITALIC}Be sure to run the command below after each command line attempt:${RESET}"
echo -e "${ITALIC}history -w${RESET}"

# echo
# echo "Be sure to run the command below after each new command line attempt:"
# echo "history -w"

# echo
# echo "Notes:"
# echo "- Total points = $TOTAL_POINTS"
# echo "- Commands sourced from JSON with slide metadata"
# echo "- Whitespace-tolerant command matching"
# echo "- For best results, configure bash to append history each prompt:"
# echo "    shopt -s histappend"
# echo "    PROMPT_COMMAND='history -a'"
