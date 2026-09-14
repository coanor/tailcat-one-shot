#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$repo_dir/serve.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

address_fixture=$(mktemp)
trap 'rm -f -- "$address_fixture"' EXIT
printf 'tcp listener\nServer listening: tc%s\nnew tcp connection\n' \
  "$(printf 'A%.0s' {1..100})" > "$address_fixture"
[[ $(extract_address "$address_fixture") == "tc$(printf 'A%.0s' {1..100})" ]] \
  || fail 'address parsing ignores unrelated tcp log lines'

[[ $(xml_escape 'A&B<C>D"E') == 'A&amp;B&lt;C&gt;D&quot;E' ]] \
  || fail 'XML escaping'

tailcat_bin="$repo_dir/tests/fixtures/legacy-tailcat"
build_tailcat_args
[[ ${tailcat_args[*]} == '--serve=no-auth-ssh --key=default' ]] \
  || fail 'v0.3 legacy CLI arguments'

tailcat_bin="$repo_dir/tests/fixtures/modern-tailcat"
build_tailcat_args
[[ ${tailcat_args[*]} == 'serve --key=default no-auth-ssh' ]] \
  || fail 'v0.6 CLI arguments'

mac_plist_text=$(render_mac_plist)
[[ $mac_plist_text == *'<string>/usr/bin/caffeinate</string>'* ]] \
  || fail 'macOS service wraps Tailcat with caffeinate'
[[ $mac_plist_text == *'<string>--key=default</string>'* ]] \
  || fail 'macOS service keeps the saved key'
if command -v plutil >/dev/null 2>&1; then
  printf '%s\n' "$mac_plist_text" | plutil -lint - >/dev/null \
    || fail 'macOS plist syntax'
fi

linux_unit_text=$(render_linux_unit)
[[ $linux_unit_text == *'Restart=always'* ]] \
  || fail 'Linux service restarts after failure'
[[ $linux_unit_text == *'serve --key=default no-auth-ssh'* ]] \
  || fail 'Linux service command'
[[ $linux_unit_text == *'UMask=0077'* ]] \
  || fail 'Linux service private log permissions'

bash -n "$repo_dir/serve.sh" "$repo_dir/wsl-run.sh"
printf 'PASS: address, XML, both Tailcat CLIs, launchd, systemd, Bash syntax\n'
