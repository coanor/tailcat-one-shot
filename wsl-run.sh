#!/usr/bin/env bash
set -u
umask 077

state_dir="$HOME/.local/state/tailcat-one-shot"
log_file="$state_dir/server.log"
pid_file="$state_dir/runner.pid"
tailcat_bin="$HOME/.local/bin/tailcat"
mkdir -p "$state_dir"
chmod 700 "$state_dir"

if [[ ! -x $tailcat_bin ]]; then
  printf 'Tailcat binary missing: %s\n' "$tailcat_bin" >> "$log_file"
  exit 1
fi

# The periodic Windows trigger must not start a second server with the same key.
if command -v flock >/dev/null 2>&1; then
  exec 9>"$state_dir/runner.lock"
  flock -n 9 || exit 0
fi

printf '%s\n' "$$" > "$pid_file"
child=''
cleanup() {
  trap - INT TERM
  if [[ -n $child ]]; then
    kill "$child" 2>/dev/null || true
    wait "$child" 2>/dev/null || true
  fi
  unlink "$pid_file" 2>/dev/null || true
  exit 0
}
trap cleanup INT TERM

if "$tailcat_bin" serve --help >/dev/null 2>&1; then
  args=(serve --key=default no-auth-ssh)
else
  args=(--serve=no-auth-ssh --key=default)
fi

while :; do
  "$tailcat_bin" "${args[@]}" >> "$log_file" 2>&1 &
  child=$!
  wait "$child" || true
  child=''
  printf 'Tailcat exited at %s; retrying in 5 seconds.\n' "$(date -Is)" >> "$log_file"
  sleep 5
done
