#!/usr/bin/env bash
set -euo pipefail

# Run from a normal user account. The saved key gives its holder a shell here.
umask 077

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
state_dir="$HOME/.local/state/tailcat-one-shot"
log_file="$state_dir/server.log"
address_file="$state_dir/address"
key_name=default
action=${1:-start}

say() { printf '%s\n' "$*"; }
die() { printf 'Error: %s\n' "$*" >&2; exit 1; }

platform() {
  case "$(uname -s)" in
    Darwin) printf 'macos\n' ;;
    Linux)
      if [[ -n ${WSL_DISTRO_NAME:-} ]] || grep -qi microsoft /proc/sys/kernel/osrelease 2>/dev/null; then
        printf 'wsl\n'
      else
        printf 'linux\n'
      fi ;;
    *) die 'Only macOS, Linux, and WSL are supported.' ;;
  esac
}

validate_input() {
  [[ $EUID -ne 0 ]] || die 'Do not run this as root: no-auth-ssh would grant a root shell.'
  [[ $key_name =~ ^[A-Za-z0-9_-]+$ ]] || die 'TAILCAT_KEY must contain only letters, digits, _ or -.'
  [[ $(id -un) =~ ^[A-Za-z0-9_.-]+$ ]] || die 'Unsupported user name for service label.'
}

prepare_state() {
  mkdir -p "$state_dir"
  chmod 700 "$state_dir"
}

extract_address() {
  local file=$1
  [[ -f $file ]] || return 1
  grep -Eo 'tc[A-Za-z0-9_-]{80,}' "$file" | tail -n 1
}

remember_address() {
  local value=$1
  printf '%s\n' "$value" > "$address_file"
  chmod 600 "$address_file"
}

show_address() {
  local source=${1:-$log_file} address=''
  address=$(extract_address "$source" || true)
  if [[ -z $address && -f $address_file ]]; then
    address=$(extract_address "$address_file" || true)
  fi
  if [[ -n $address ]]; then
    say "Tailcat address (SECRET): $address"
    say "Connect from another machine: tailcat ssh $address"
  else
    say "Address not in the log yet. Check $source, then run: bash serve.sh address"
  fi
}

wait_for_address() {
  local source=$1 attempt
  for attempt in {1..20}; do
    if [[ -f $source ]] && extract_address "$source" >/dev/null 2>&1; then
      show_address "$source"
      return
    fi
    sleep 1
  done
  die "Tailcat has not reported a listening address after 20 seconds. Check $source and the service status."
}

install_linux_binary() {
  local arch archive_name expected tmp
  case "$(uname -m)" in
    x86_64|amd64)
      arch=amd64
      expected=f3597a9ad02f5cca538f8f5a6f89123910bce3e9611d1e5a8e96d5f2d3cc90fd ;;
    aarch64|arm64)
      arch=arm64
      expected=fff48f25d223aea31f985bae8a2c01378b22e51e985e8c7d270e1a8586598506 ;;
    *) die "No pinned Tailcat release for architecture $(uname -m)." ;;
  esac
  for tool in curl tar sha256sum; do
    command -v "$tool" >/dev/null || die "Install $tool first."
  done
  archive_name="tailcat_0.6.0_linux_${arch}.tar.gz"
  tmp=$(mktemp -d)
  trap '[[ -z ${tmp:-} ]] || rm -r -- "$tmp"' EXIT
  say "Downloading Tailcat v0.6.0 ($arch)..."
  curl -fL --retry 3 --connect-timeout 10 --max-time 180 \
    -o "$tmp/$archive_name" \
    "https://github.com/tailscale/tailcat/releases/download/v0.6.0/$archive_name"
  printf '%s  %s\n' "$expected" "$tmp/$archive_name" | sha256sum -c - >/dev/null \
    || die 'Tailcat archive checksum did not match the official release.'
  tar -xzf "$tmp/$archive_name" -C "$tmp" tailcat
  mkdir -p "$HOME/.local/bin"
  install -m 700 "$tmp/tailcat" "$HOME/.local/bin/tailcat"
  tailcat_bin="$HOME/.local/bin/tailcat"
  trap - EXIT
  rm -r -- "$tmp"
}

find_or_install_binary() {
  if command -v tailcat >/dev/null 2>&1; then
    tailcat_bin=$(command -v tailcat)
  elif [[ $(platform) == macos ]]; then
    if command -v brew >/dev/null 2>&1; then
      brew install tailcat
      tailcat_bin="$(brew --prefix tailcat)/bin/tailcat"
    elif command -v go >/dev/null 2>&1; then
      go install github.com/tailscale/tailcat/cmd/tailcat@v0.6.0
      tailcat_bin="$(go env GOPATH)/bin/tailcat"
    else
      die 'Install Homebrew or Go first so Tailcat can be installed on macOS.'
    fi
  else
    install_linux_binary
  fi
  [[ -x $tailcat_bin ]] || die "Tailcat binary is not executable: $tailcat_bin"
  say "Using $tailcat_bin ($("$tailcat_bin" --version 2>&1 | head -n 1))"
}

ensure_saved_key() {
  if "$tailcat_bin" genkey --list 2>/dev/null | grep -Fx "$key_name" >/dev/null; then
    say "Reusing saved key '$key_name'; it will not be overwritten."
    return
  fi
  local output address
  output=$("$tailcat_bin" genkey --key="$key_name")
  address=$(printf '%s\n' "$output" | grep -Eo 'tc[A-Za-z0-9_-]{80,}' | tail -n 1 || true)
  [[ -n $address ]] || die 'Key was generated, but Tailcat did not print an address.'
  remember_address "$address"
  say "Created saved key '$key_name'."
}

build_tailcat_args() {
  if "$tailcat_bin" serve --help >/dev/null 2>&1; then
    tailcat_args=(serve "--key=$key_name" no-auth-ssh)
  else
    tailcat_args=("--serve=no-auth-ssh" "--key=$key_name")
  fi
}

refuse_duplicate_server() {
  if command -v pgrep >/dev/null 2>&1 &&
     pgrep -u "$(id -u)" -f '(^|/)tailcat (serve|--serve).*no-auth-ssh' >/dev/null; then
    die 'Another interactive Tailcat SSH server is running. Stop it locally before installing this service.'
  fi
}

xml_escape() {
  local value=$1
  value=${value//&/\&amp;}
  value=${value//</\&lt;}
  value=${value//>/\&gt;}
  value=${value//\"/\&quot;}
  printf '%s' "$value"
}

mac_label() { printf 'com.%s.tailcat-ssh' "$(id -un)"; }
mac_plist() { printf '%s/Library/LaunchAgents/%s.plist' "$HOME" "$(mac_label)"; }

render_mac_plist() {
  local arg
  printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>'
  printf '%s\n' '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
  printf '%s\n' '<plist version="1.0"><dict>'
  printf '  <key>Label</key><string>%s</string>\n' "$(xml_escape "$(mac_label)")"
  printf '%s\n' '  <key>ProgramArguments</key><array>'
  for arg in /usr/bin/caffeinate -is "$tailcat_bin" "${tailcat_args[@]}"; do
    printf '    <string>%s</string>\n' "$(xml_escape "$arg")"
  done
  printf '%s\n' '  </array>'
  printf '  <key>WorkingDirectory</key><string>%s</string>\n' "$(xml_escape "$HOME")"
  printf '  <key>EnvironmentVariables</key><dict><key>HOME</key><string>%s</string></dict>\n' "$(xml_escape "$HOME")"
  printf '%s\n' '  <key>KeepAlive</key><true/>'
  printf '%s\n' '  <key>Umask</key><integer>63</integer>'
  printf '  <key>StandardOutPath</key><string>%s</string>\n' "$(xml_escape "$log_file")"
  printf '  <key>StandardErrorPath</key><string>%s</string>\n' "$(xml_escape "$log_file")"
  printf '%s\n' '</dict></plist>'
}

mac_log_path() {
  local plist
  plist=$(mac_plist)
  if [[ -f $plist ]]; then
    plutil -extract StandardOutPath raw -o - "$plist" 2>/dev/null || printf '%s' "$log_file"
  else
    printf '%s' "$log_file"
  fi
}

start_macos() {
  local plist label service
  plist=$(mac_plist)
  label=$(mac_label)
  service="gui/$(id -u)/$label"
  mkdir -p "$HOME/Library/LaunchAgents"
  if [[ -f $plist ]]; then
    [[ $(plutil -extract Label raw -o - "$plist") == "$label" ]] \
      || die "Existing plist has a different label: $plist"
    plutil -p "$plist" | grep -F -- "--key=$key_name" >/dev/null \
      || die "Existing LaunchAgent does not use --key=$key_name: $plist"
    plutil -p "$plist" | grep -F '/usr/bin/caffeinate' >/dev/null \
      || die "Existing LaunchAgent does not use caffeinate: $plist"
    say "Existing LaunchAgent retained: $plist"
  else
    refuse_duplicate_server
    render_mac_plist > "$plist"
    chmod 600 "$plist"
    plutil -lint "$plist" >/dev/null || die "Invalid plist: $plist"
  fi
  if launchctl print "$service" >/dev/null 2>&1; then
    say 'Tailcat LaunchAgent is already loaded. Leaving this connection untouched.'
  else
    launchctl bootstrap "gui/$(id -u)" "$plist"
  fi
  launchctl print "$service" | grep 'state = running' >/dev/null \
    || die "LaunchAgent is not running. Check: launchctl print $service"
  say "LaunchAgent running: $service"
  wait_for_address "$(mac_log_path)"
}

linux_unit() { printf '%s/.config/systemd/user/tailcat-one-shot.service' "$HOME"; }

render_linux_unit() {
  local arg
  printf '%s\n' '# Managed by tailcat-one-shot'
  printf '%s\n' '[Unit]' 'Description=Tailcat no-auth SSH server'
  printf '%s\n' '[Service]' 'Type=simple'
  printf 'WorkingDirectory=%s\n' "$HOME"
  printf 'Environment=HOME=%s\n' "$HOME"
  printf 'ExecStart=%s' "$tailcat_bin"
  for arg in "${tailcat_args[@]}"; do printf ' %s' "$arg"; done
  printf '\n'
  printf '%s\n' 'Restart=always' 'RestartSec=5' 'UMask=0077'
  printf 'StandardOutput=append:%s\n' "$log_file"
  printf 'StandardError=append:%s\n' "$log_file"
  printf '%s\n' '[Install]' 'WantedBy=default.target'
}

start_linux() {
  local unit linger
  [[ $HOME != *' '* && $tailcat_bin != *' '* && $log_file != *' '* ]] \
    || die 'Linux service paths containing spaces are not supported.'
  command -v systemctl >/dev/null || die 'systemd is required on Linux.'
  command -v loginctl >/dev/null || die 'systemd-logind is required on Linux.'
  unit=$(linux_unit)
  mkdir -p "$(dirname "$unit")"
  if [[ -f $unit ]] && ! grep -Fxq '# Managed by tailcat-one-shot' "$unit"; then
    die "Refusing to overwrite unmanaged service: $unit"
  fi
  [[ -f $unit ]] || refuse_duplicate_server
  render_linux_unit > "$unit"
  chmod 600 "$unit"
  linger=$(loginctl show-user "$(id -un)" -p Linger --value 2>/dev/null || true)
  if [[ $linger != yes ]]; then
    say 'Enabling user lingering so the service survives logout (sudo may ask for a password).'
    command -v sudo >/dev/null || die 'Install sudo or ask an administrator to enable user lingering.'
    sudo loginctl enable-linger "$(id -un)"
    [[ $(loginctl show-user "$(id -un)" -p Linger --value) == yes ]] \
      || die 'User lingering is still disabled.'
  fi
  systemctl --user daemon-reload
  systemctl --user enable --now tailcat-one-shot.service
  systemctl --user is-active --quiet tailcat-one-shot.service \
    || die 'Tailcat systemd service is not active.'
  say 'systemd user service active, and lingering enabled.'
  wait_for_address "$log_file"
}

wsl_task() {
  local verb=$1 windows_script windows_appdata linux_appdata
  command -v powershell.exe >/dev/null || die 'WSL PowerShell interoperability is required.'
  command -v wslpath >/dev/null || die 'wslpath is required.'
  [[ ${WSL_DISTRO_NAME:-} =~ ^[A-Za-z0-9_.-]+$ ]] \
    || die 'WSL_DISTRO_NAME must contain only letters, digits, _, . or -.'
  windows_appdata=$(powershell.exe -NoProfile -Command '[Console]::Out.Write($env:LOCALAPPDATA)' | tr -d '\r')
  [[ -n $windows_appdata ]] || die 'Could not find the Windows LocalAppData directory.'
  linux_appdata=$(wslpath -u "$windows_appdata")
  mkdir -p "$linux_appdata/TailcatOneShot"
  install -m 600 "$repo_dir/wsl-task.ps1" "$linux_appdata/TailcatOneShot/wsl-task.ps1"
  windows_script=$(wslpath -w "$linux_appdata/TailcatOneShot/wsl-task.ps1")
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$windows_script" \
    -Action "$verb" -Distro "$WSL_DISTRO_NAME" -LinuxUser "$(id -un)" \
    -Runner "$HOME/.local/libexec/tailcat-one-shot/run.sh" | tr -d '\r'
}

wsl_runner_alive() {
  local runner_pid runner_command
  [[ -f $state_dir/runner.pid ]] || return 1
  read -r runner_pid < "$state_dir/runner.pid"
  [[ $runner_pid =~ ^[0-9]+$ ]] || return 1
  runner_command=$(ps -p "$runner_pid" -o args= 2>/dev/null || true)
  [[ $runner_command == *'tailcat-one-shot/run.sh'* ]]
}

start_wsl() {
  local attempt
  command -v flock >/dev/null || die 'Install flock (util-linux) in WSL first.'
  mkdir -p "$HOME/.local/bin" "$HOME/.local/libexec/tailcat-one-shot"
  if [[ $tailcat_bin != "$HOME/.local/bin/tailcat" && ! -e $HOME/.local/bin/tailcat ]]; then
    ln -s "$tailcat_bin" "$HOME/.local/bin/tailcat"
  fi
  install -m 700 "$repo_dir/wsl-run.sh" "$HOME/.local/libexec/tailcat-one-shot/run.sh"
  [[ -x $HOME/.local/bin/tailcat ]] || die 'WSL runner cannot find ~/.local/bin/tailcat.'
  if ! wsl_task Status >/dev/null 2>&1; then
    refuse_duplicate_server
  fi
  wsl_task Install
  for attempt in {1..20}; do
    if wsl_runner_alive; then break; fi
    sleep 1
  done
  wsl_runner_alive || die "Windows task did not start the WSL runner. Check: bash serve.sh status"
  wait_for_address "$log_file"
}

status() {
  local target
  case "$(platform)" in
    macos)
      target="gui/$(id -u)/$(mac_label)"
      launchctl print "$target" | grep -E 'state =|pid =|last exit code =|properties ='
      show_address "$(mac_log_path)" ;;
    linux)
      systemctl --user status --no-pager tailcat-one-shot.service | head -18
      show_address ;;
    wsl)
      wsl_task Status
      show_address ;;
  esac
}

stop_service() {
  local runner_pid
  case "$(platform)" in
    macos) launchctl bootout "gui/$(id -u)" "$(mac_plist)" ;;
    linux) systemctl --user disable --now tailcat-one-shot.service ;;
    wsl)
      wsl_task Stop
      if wsl_runner_alive; then
        read -r runner_pid < "$state_dir/runner.pid"
        kill "$runner_pid"
      fi ;;
  esac
  say 'Tailcat service stopped. The saved key was kept.'
}

main() {
  validate_input
  case $action in
    start)
      prepare_state
      find_or_install_binary
      ensure_saved_key
      build_tailcat_args
      case "$(platform)" in
        macos) start_macos ;;
        linux) start_linux ;;
        wsl) start_wsl ;;
      esac
      say 'Keep the address private: no-auth-ssh grants a shell to anyone who knows it.' ;;
    status) status ;;
    address)
      case "$(platform)" in
        macos) show_address "$(mac_log_path)" ;;
        *) show_address ;;
      esac ;;
    stop) stop_service ;;
    *) die 'Usage: bash serve.sh [start|status|address|stop]' ;;
  esac
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
