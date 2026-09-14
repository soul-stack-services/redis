#!/bin/sh
set -eu

# Everything this service needs from a local stand that the engine's own dev stand does
# not already provide. It does NOT bring the stand up — that is `make dev-up` and
# `make dev-stand` in the core repo — and it deliberately stops before editing
# keeper.yml or calling the operator API: it prints those, because a script that edits an
# operator's config and mints grants behind their back is not an example of anything.
#
# What it does:
#   1. mints the SSH material — the key the Keeper authenticates WITH and the host
#      certificate it verifies a machine BY;
#   2. renders the cloud-init user-data that puts both on every machine;
#   3. writes all of it into Vault, at the paths vars/50-machines.yaml names;
#   4. builds, stamps and publishes the machine provider and the SSH provider as git
#      repos of BUILT artifacts, which is the only form keeper resolves;
#   5. serves the soul binary on the libvirt bridge, because the machines fetch it.
#
# Run from the service root. Env:
#   SOUL_STACK_ROOT  core checkout (required)
#   STAND_DIR        the stand's dev dir, default /tmp/keeper-dev
#   WORK_DIR         where the SSH material is kept, default $STAND_DIR/redis-example
#   STAND_VAULT_ADDR  default http://127.0.0.1:8200
#   STAND_VAULT_TOKEN default root
#   BRIDGE_IP        libvirt bridge address, default 192.168.122.1
#   SERVE_PORT       port the soul binary is served on, default 8099
#   SSH_STATIC_SRC   checkout of the ssh-static provider (required)

: "${SOUL_STACK_ROOT:?set SOUL_STACK_ROOT to a core checkout}"
: "${SSH_STATIC_SRC:?set SSH_STATIC_SRC to a checkout of the ssh-static SshProvider}"
STAND_DIR=${STAND_DIR:-/tmp/keeper-dev}
WORK_DIR=${WORK_DIR:-$STAND_DIR/redis-example}
# ★ Deliberately NOT ${VAULT_ADDR:-…}. This script writes secrets, and an operator's shell
# very often already carries a PRODUCTION Vault address and token — inheriting them here
# aims those writes at production. This cost nothing only because the production Vault
# answered 403. `dev/keeper-run.sh` forces VAULT_TOKEN=root for the same reason. Override
# with STAND_VAULT_ADDR / STAND_VAULT_TOKEN, which nothing else sets by accident.
VAULT_ADDR=${STAND_VAULT_ADDR:-http://127.0.0.1:8200}
VAULT_TOKEN=${STAND_VAULT_TOKEN:-root}
BRIDGE_IP=${BRIDGE_IP:-192.168.122.1}
SERVE_PORT=${SERVE_PORT:-8099}

log() { printf '[local-stand] %s\n' "$*"; }
fail() { printf '[local-stand] %s\n' "$*" >&2; exit 1; }

case "$VAULT_ADDR" in
  http://127.0.0.1:*|http://localhost:*|http://[::1]:*) ;;
  *) [ "${STAND_VAULT_ALLOW_REMOTE:-}" = "1" ] ||
       fail "STAND_VAULT_ADDR is $VAULT_ADDR, which is not loopback. This script writes a
  private SSH key and a machine's host key into Vault; a stand's Vault is local. Set
  STAND_VAULT_ALLOW_REMOTE=1 if you really mean a remote one." ;;
esac

[ -s "$STAND_DIR/tls/vault-ca.crt" ] ||
  fail "no $STAND_DIR/tls/vault-ca.crt — bring the stand up first, and re-provision it with
  DEV_KEEPER_EXTRA_IP=$BRIDGE_IP so the keeper certificate carries the bridge address in
  its SANs. Without that SAN a machine cannot verify the bootstrap channel."
openssl x509 -in "$STAND_DIR/tls/keeper.crt" -noout -ext subjectAltName 2>/dev/null | grep -q "$BRIDGE_IP" ||
  fail "the keeper certificate has no $BRIDGE_IP in its SANs. Re-provision the stand with
  DEV_KEEPER_EXTRA_IP=$BRIDGE_IP — a machine dials the keeper at the bridge address and
  pins it to the keeper CA, so a missing SAN fails the bootstrap channel, not the dial."

# ── 1. SSH material ──────────────────────────────────────────────────────────────────
mkdir -p "$WORK_DIR"
if [ ! -s "$WORK_DIR/client_ed25519" ]; then
  log "minting SSH material into $WORK_DIR"
  ssh-keygen -q -t ed25519 -N '' -C 'keeper-push' -f "$WORK_DIR/client_ed25519"
  ssh-keygen -q -t ed25519 -N '' -C 'host-ca'     -f "$WORK_DIR/host_ca"
  ssh-keygen -q -t ed25519 -N '' -C 'vm-host'     -f "$WORK_DIR/vm_host_ed25519"
  # ★ A host certificate with NO principals. For a host cert an empty principal list
  # means "valid for any host", and that is what a DHCP-assigned address needs: the
  # Keeper dials an address the machine only learns at boot, and ssh.CertChecker verifies
  # principals against the address it dialed. One certificate for the batch is the
  # trade-off a local stand makes; a fleet mints one per machine.
  ssh-keygen -q -s "$WORK_DIR/host_ca" -I local-stand -h -V -5m:+52w "$WORK_DIR/vm_host_ed25519.pub"
  chmod 0600 "$WORK_DIR/client_ed25519" "$WORK_DIR/host_ca" "$WORK_DIR/vm_host_ed25519"
else
  log "SSH material already present in $WORK_DIR — reusing"
fi

# ── 2 & 3. user-data + Vault ─────────────────────────────────────────────────────────
log "rendering cloud-init user-data and writing Vault"
VAULT_ADDR="$VAULT_ADDR" VAULT_TOKEN="$VAULT_TOKEN" \
python3 - "$WORK_DIR" "$STAND_DIR" <<'PY'
import json, os, pathlib, sys, textwrap, urllib.request

work, stand = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
rd = lambda n: (work / n).read_text().strip()

user_data = f"""#cloud-config
# Written by scripts/local-stand.sh.
#
# Two things, and both are what lets a Keeper reach a machine that has no agent on it
# yet: the key it authenticates WITH, and the host certificate it verifies the machine
# BY. The direct transport refuses to connect without a host certificate signed by a CA
# it holds — an empty CA set is an error, never a blind connect.
disable_root: false
ssh_pwauth: false
ssh_authorized_keys:
  - {rd('client_ed25519.pub')}
ssh_keys:
  ed25519_private: |
{textwrap.indent(rd('vm_host_ed25519'), '    ')}
  ed25519_public: {rd('vm_host_ed25519.pub')}
  ed25519_certificate: {rd('vm_host_ed25519-cert.pub')}
"""
(work / "user-data.yaml").write_text(user_data)

addr, token = os.environ["VAULT_ADDR"], os.environ["VAULT_TOKEN"]
def put(path, data):
    req = urllib.request.Request(
        f"{addr}/v1/secret/data/{path}",
        data=json.dumps({"data": data}).encode(),
        headers={"X-Vault-Token": token, "Content-Type": "application/json"},
        method="POST")
    with urllib.request.urlopen(req) as r:
        print(f"[local-stand]   vault secret/{path} -> {r.status}")

# The keeper CA a machine pins its bootstrap channel to. On this stand the bootstrap
# listener's certificate is issued by the Vault PKI root, so that root is the CA.
put("keeper/bootstrap-ca", {"ca": (stand / "tls" / "vault-ca.crt").read_text()})
# The PUBLIC half of the host CA. keeper.yml::push.host_ca_refs[] points here, and the
# field name `public_key` is what LoadHostCA reads.
put("keeper/ssh-host-ca", {"public_key": rd("host_ca.pub")})
put("soul-stack-services/redis/machine", {
    # For vmlocal this is the libvirt connection URI, and it is the only connection
    # value there is: a local libvirtd authenticates by the permissions on its socket,
    # so vmlocal declares no credential and refuses one (NIM-873).
    "endpoint":  "qemu:///system",
    "user_data": user_data,
})
PY

# ── 4. publish the two keeper-side plugins ───────────────────────────────────────────
# A plugin reaches keeper as a git repo of a BUILT, STAMPED artifact, never as source:
# the resolver neither compiles nor executes, it takes the ONE executable in dist/ and
# reads the plugin's disclosure from a trailer on it. Both guards below are one chmod
# away from being needed, and both mistakes leave keeper green with the plugin silently
# absent.
publish() {  # <srcdir> <binary> <alias>
  src=$1; bin=$2; alias=$3
  dest="$STAND_DIR/plugin-repos/$alias"
  [ -f "$src/schema.json" ] || fail "no schema document beside $src — an unstamped artifact is refused per-entry, and a per-entry refusal is only a warning"
  tmp=$(mktemp -d)
  ( cd "$src" && GOWORK=off CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
      go build -trimpath -ldflags "-buildid=" -o "$tmp/$bin" . ) ||
    { rm -rf "$tmp"; fail "go build failed: $src"; }
  # -trimpath and an empty buildid keep the sha256 reproducible: otherwise a repeat
  # publish changes the binary and invalidates the Sigil grant already issued for it.
  ( cd "$SOUL_STACK_ROOT" && GOWORK= go run ./dev/stamp-artifact.go "$tmp/$bin" "$src/schema.json" ) ||
    { rm -rf "$tmp"; fail "stamping failed: $src"; }
  rm -rf "$dest"; mkdir -p "$dest/dist"
  cp "$tmp/$bin" "$dest/dist/$bin"; chmod 0755 "$dest/dist/$bin"
  cp "$src/schema.json" "$dest/dist/schema.json"; chmod 0644 "$dest/dist/schema.json"
  rm -rf "$tmp"
  git -C "$dest" init -q -b main
  git -C "$dest" add -A
  git -C "$dest" -c commit.gpgsign=false commit -q -m "$alias artifact snapshot (local-stand)"
  git -C "$dest" -c tag.gpgsign=false tag -f v1.0.0 >/dev/null
  mode=$(git -C "$dest" ls-files -s "dist/$bin" | cut -d' ' -f1)
  [ "$mode" = "100755" ] ||
    fail "git recorded dist/$bin as ${mode:-nothing}, not 100755 — the resolver would find no executable in dist/ and $alias would silently never arrive"
  execs=$(git -C "$dest" ls-files -s dist/ | grep -c '^100755 ' || true)
  [ "$execs" = "1" ] ||
    fail "dist/ carries $execs executables, not exactly 1 — the resolver cannot tell which is the artifact"
  log "published $alias -> $dest (sha256 $(sha256sum "$dest/dist/$bin" | cut -c1-16)…)"
}
publish "$SOUL_STACK_ROOT/examples/module/vmlocal" vmlocal vmlocal
publish "$SSH_STATIC_SRC" soul-ssh-static ssh-static

# ── 5. serve the soul binary ─────────────────────────────────────────────────────────
# The engine knows nothing about where a machine fetches the agent from — that address is
# the site's. Here it is a directory served on the libvirt bridge.
mkdir -p "$STAND_DIR/serve"
[ -x "$SOUL_STACK_ROOT/soul/bin/soul" ] ||
  fail "no $SOUL_STACK_ROOT/soul/bin/soul — run 'make build-soul' in the core repo"
cp "$SOUL_STACK_ROOT/soul/bin/soul" "$STAND_DIR/serve/soul"
chmod 0755 "$STAND_DIR/serve/soul"
if curl -fsI "http://$BRIDGE_IP:$SERVE_PORT/soul" >/dev/null 2>&1; then
  log "soul binary already served at http://$BRIDGE_IP:$SERVE_PORT/soul"
else
  ( cd "$STAND_DIR/serve" && nohup python3 -m http.server "$SERVE_PORT" --bind "$BRIDGE_IP" \
      > "$STAND_DIR/serve.log" 2>&1 & )
  sleep 2
  curl -fsI "http://$BRIDGE_IP:$SERVE_PORT/soul" >/dev/null ||
    fail "the soul binary is not reachable at http://$BRIDGE_IP:$SERVE_PORT/soul"
  log "serving the soul binary at http://$BRIDGE_IP:$SERVE_PORT/soul"
fi

cat <<EOF

[local-stand] done. What is left is the operator's, and is printed rather than done:

1. keeper.yml — add the two catalog entries and the host CA, and bind the gRPC listeners
   where vars/50-machines.yaml says a machine will dial them:

  plugins:
    soul_modules:
      - { name: vmlocal, source: "file://$STAND_DIR/plugin-repos/vmlocal", ref: "v1.0.0" }
    ssh_providers:
      - { name: static,  source: "file://$STAND_DIR/plugin-repos/ssh-static", ref: "v1.0.0" }
  push:
    transport: direct
    host_ca_refs:
      - { name: local, ref: "vault:secret/keeper/ssh-host-ca" }

   ⚠ The push dispatcher spawns every ssh_providers[] entry AT STARTUP and keeper exits
   if the spawn is refused — so an entry whose Sigil grant does not exist yet stops the
   Keeper from coming up at all. Bring it up once with the entry parked under
   soul_modules[], issue the grant, then move it to ssh_providers[] and restart.

2. The Vault PKI role has to allow the machines' names. SID is the hostname, the machines
   are called <incarnation-id>-<n>, and a bare name outside the role's domains is refused
   when the seed CSR is signed — which surfaces as a failing 'soul init', several steps
   after the name was chosen:

   vault write pki/roles/soul-seed allowed_domains=…,<incarnation-id>-* \\
     allow_subdomains=true allow_bare_domains=true allow_glob_domains=true \\
     allow_localhost=true max_ttl=720h

3. Grants and rows, against the running Keeper (TOKEN = an Archon JWT):

   POST /v1/plugins/sigils   {"alias":"vmlocal","source":"file://$STAND_DIR/plugin-repos/vmlocal","ref":"v1.0.0"}
   POST /v1/plugins/sigils   {"alias":"static","source":"file://$STAND_DIR/plugin-repos/ssh-static","ref":"v1.0.0"}
   POST /v1/push-providers   {"id":"static","params":{"key_path":"$WORK_DIR/client_ed25519"}}
   POST /v1/services         {"id":"redis-machines","git":"file://\$PWD","ref":"main"}

   The provider's id must be 'static': the params reach the plugin through
   SOUL_SSH_<UPPER_SNAKE(id)>_PARAMS, and this provider reads SOUL_SSH_STATIC_PARAMS.

   A grant pins the artifact's sha256, so after every rebuild DELETE the sigil and POST
   it again — a second POST alone answers 409.

4. Keeper must run where it can reach libvirt and the bridge: a HOST process, in the
   libvirt group ('sg libvirt -c …'). From inside a Docker Desktop container nothing
   routes to the bridge network.
EOF
