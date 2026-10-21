#!/usr/bin/env bash
# One-time, explicitly approved setup on the selected publisher server.
# Registration token is read from stdin; SSH keys and existing services are untouched.
set -euo pipefail
set +x
base=/opt/hongputao-release-runner
account=hongputao-publisher
if [ "$(id -u)" != 0 ]; then echo 'Root is required for isolated service setup.' >&2; exit 1; fi
if [ -e "$base" ] || id "$account" >/dev/null 2>&1; then
  echo 'Publisher path or account already exists; refusing to overwrite.' >&2
  exit 1
fi
read -r registration_token
registration_token=${registration_token%$'\r'}
if [ -z "$registration_token" ]; then echo 'Missing one-time runner registration token.' >&2; exit 1; fi
for program in curl tar sha256sum useradd runuser systemctl git python3; do
  command -v "$program" >/dev/null || { echo "Required program missing: $program" >&2; exit 1; }
done
install -d -m 700 "$base" "$base/runner" "$base/bin" "$base/home" "$base/downloads"
curl -fSL --connect-timeout 20 --max-time 300 --retry 1 \
  https://github.com/actions/runner/releases/download/v2.338.0/actions-runner-linux-x64-2.338.0.tar.gz \
  -o "$base/downloads/runner.tar.gz"
echo 'af4b794c1bc41d73d40535e3fe092a39f9679cd8d965954c2aca25a05ca41d32'"  $base/downloads/runner.tar.gz" | sha256sum -c -
tar -xzf "$base/downloads/runner.tar.gz" -C "$base/runner"
curl -fSL --connect-timeout 20 --max-time 180 --retry 1 \
  https://github.com/cli/cli/releases/download/v2.102.1/gh_2.102.1_linux_amd64.tar.gz \
  -o "$base/downloads/gh.tar.gz"
echo '77b9e297e94c50336823d0f84de7ef1be60cba704601fa0d98f129f47a94987b'"  $base/downloads/gh.tar.gz" | sha256sum -c -
tar -xzf "$base/downloads/gh.tar.gz" -C "$base/downloads"
install -m 755 "$base/downloads/gh_2.102.1_linux_amd64/bin/gh" "$base/bin/gh"
useradd --system --user-group --no-create-home --home-dir "$base/home" --shell /usr/sbin/nologin "$account"
chown -R "$account:$account" "$base"
cd "$base/runner"
runuser -u "$account" -- env HOME="$base/home" DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1 \
  ./config.sh --unattended --url https://github.com/adoin/Hongguo-video-pack \
  --token "$registration_token" --name hongputao-gitee-publisher \
  --labels hongputao-gitee-publisher --work _work
unset registration_token
./svc.sh install "$account"
service_name=$(cat .service)
if [[ ! "$service_name" =~ ^actions\.runner\.[A-Za-z0-9_.-]+\.service$ ]]; then
  echo 'Unexpected service identity.' >&2; exit 1
fi
install -d -m 755 "/etc/systemd/system/$service_name.d"
cat > "/etc/systemd/system/$service_name.d/isolation.conf" <<EOF
[Service]
Environment=HOME=$base/home
Environment=PATH=$base/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
Environment=DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1
NoNewPrivileges=true
ProtectHome=true
ProtectSystem=strict
ReadWritePaths=$base
PrivateTmp=true
PrivateDevices=true
RestrictSUIDSGID=true
CapabilityBoundingSet=
UMask=0077
Nice=10
CPUWeight=20
MemoryMax=768M
EOF
systemctl daemon-reload
systemctl enable --now "$service_name"
systemctl is-active "$service_name"
echo 'Isolated repository publisher is running. No inbound listener was added.'
