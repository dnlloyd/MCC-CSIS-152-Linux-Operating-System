#!/usr/bin/env bash

#!/usr/bin/env bash
set -euo pipefail

# Your roster rule: local users with UID 1000-1099, excluding ec2-user and bastion
students=($(awk -F: '/:x:10[0-9][0-9]/ && $1 !~ /ec2-user|bastion/ {print $1}' /etc/passwd))

printf "%-18s %9s  %s\n" "STUDENT" "LOGGED_IN" "DETAILS"
printf "%-18s %9s  %s\n" "------------------" "---------" "----------------------------------------------"

for student in "${students[@]}"; do
  # lastlog prints a header + one line; take the last line only
  line="$(lastlog -u "$student" 2>/dev/null | tail -n 1 || true)"

  # If lastlog didn't return something sensible, treat as unknown
  if [[ -z "$line" ]]; then
    printf "%-18s %9s  %s\n" "$student" "UNKNOWN" "lastlog produced no output"
    continue
  fi

  if grep -q "Never logged in" <<<"$line"; then
    printf "%-18s %9s  %s\n" "$student" "NO" "-"
  else
    # Keep the full lastlog line as evidence
    printf "%-18s %9s  %s\n" "$student" "YES" "$line"
  fi
done
