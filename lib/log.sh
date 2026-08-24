#!/usr/bin/env bash
# Sourced by setup.sh / teardown.sh / extras.sh. Requires $LOG_FILE to be set
# by the caller before use; falls back to /dev/null if it isn't.

LOG_FILE="${LOG_FILE:-/dev/null}"
VERBOSE="${VERBOSE:-0}"

_ts() { date '+%H:%M:%S'; }

log_step() {
  echo "[$(_ts)] ==> $*" | tee -a "$LOG_FILE"
}

log_ok() {
  echo "[$(_ts)]  ok  $*" | tee -a "$LOG_FILE"
}

log_warn() {
  echo "[$(_ts)] warn $*" | tee -a "$LOG_FILE" >&2
}

log_fail() {
  echo "[$(_ts)] FAIL $*" | tee -a "$LOG_FILE" >&2
}

# Runs a command, always appending its output to the log file.
# Echoes it live to the console too when VERBOSE=1.
log_run() {
  if [ "$VERBOSE" = "1" ]; then
    "$@" 2>&1 | tee -a "$LOG_FILE"
    return "${PIPESTATUS[0]}"
  else
    "$@" >>"$LOG_FILE" 2>&1
  fi
}
