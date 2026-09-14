#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
default_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
service_root=${1:-$default_root}

# shellcheck source=scripts/tooling.sh
. "$script_dir/tooling.sh"

fail() {
  echo "validate: $*" >&2
  exit 1
}

[ -f "$service_root/service.yml" ] || fail "no service.yml"
[ -f "$service_root/types.yml" ] || fail "no types.yml"
[ -f "$service_root/scenario-create.yml" ] || fail "no scenario-create.yml"
ls "$service_root"/vars/*.yaml >/dev/null 2>&1 || fail "vars/ holds no layer"

# The migration ladder is checked by the ENGINE (NIM-736): the `<NNN>_<slug>/main.yml`
# layout, gaps, the half-applied shape and a file named like a rung. There is no copy of
# that rule here — two copies of one rule eventually hold two different truths.

# Read INSIDE the named block, not across the whole file. Since NIM-829 a `modules[]`
# record is an artefact alias and its line is word for word the shape of a `destiny[]`
# one, so a whole-file check would go green on a removed destiny.
manifest_block() {
  awk -v key="$1" '$0 == key ":" { f = 1; next } /^[a-z_]+:/ { f = 0 } f' "$service_root/service.yml"
}

# The alias in a record, in any spelling YAML considers the same name: flow
# `{ name: redis, ... }`, block `- name: redis` at end of line, and quoted. The guard has
# to catch the RECORD, not one of its spellings.
block_has_alias() {
  manifest_block "$1" | grep -Eq "name: *\"?'?$2\"?'?([,[:space:]]|$)"
}

block_has_alias destiny redis ||
  fail "service.yml::destiny[] does not name redis — the rollout has no brick to apply"
block_has_alias modules redis ||
  fail "service.yml::modules[] does not name redis — the PING gate and the ACL step
  address redis.*, and without the record the plugin never reaches the hosts"

# ★ The machine provider is keeper-side. A record in modules[] synthesises a Soul-side
# `core.module.installed` (ADR-065) that would be scheduled before any machine exists —
# on a roster of zero. The operator registers it in `keeper.yml::plugins.soul_modules[]`.
for side in destiny modules; do
  block_has_alias "$side" vmlocal &&
    fail "service.yml::$side[] names vmlocal. A machine provider is keeper-side: the
    record here would synthesise a Soul-side install standing in front of machine
    creation, with no hosts to install onto. Register it in
    keeper.yml::plugins.soul_modules[] instead."
done

# A floating ref would mean the stand and production run different install code.
manifest_block destiny | grep -q 'ref: *v' ||
  fail "the destiny ref is not pinned to a tag in service.yml::destiny[]"
manifest_block modules | grep -q 'ref: *v' ||
  fail "the module ref is not pinned to a tag in service.yml::modules[]"

# Every guard below matches in KEY POSITION and drops whole-line comments first. A plain
# substring search over scenario YAML counts prose as keys, and these files describe the
# very mistakes they forbid — the first version of this guard failed on its own comment.
# The cost is that a predicate written as a block scalar would slip past; nobody writes
# `until:` that way, and stating the hole is better than a regex that pretends to close it.
uncommented() { grep -vE '^[[:space:]]*#' "$1"; }

# ★ A plugin failure carries NO Output, so an `until:`/`failed_when:` predicate reading
# `register.self.*` fails with `no such key` and kills the retry on exactly the failure it
# was written for. `core.exec.run` has no such hole, which is why a step ported from a
# shell breaks silently — and L0 cannot see it.
if grep -rnE '^[[:space:]]*(-[[:space:]]+)?(until|failed_when):.*register\.self' \
     "$service_root/scenario" >&2; then
  fail "a retry predicate reads register.self — on a plugin step the failure carries no
  Output, the predicate fails with no such key, and the retry dies on the very failure it
  exists for. Use a bare retry."
fi

# ★ A keeper task is rendered ONCE per run: there is no `${ host.* }` root, and `loop:` on
# `on: keeper` does not exist. Both would render, and then do the wrong thing on every
# host but the first.
keeper_files=$(grep -rlE '^[[:space:]]*on: *keeper[[:space:]]*$' "$service_root/scenario" || true)
for f in $keeper_files; do
  uncommented "$f" | grep -q '\${ *host\.' &&
    fail "$f addresses \${ host.* } — a keeper task is rendered once per run and has no
    such root. Name the FIELD of the host record (stdin_from:) instead."
  uncommented "$f" | grep -qE '^[[:space:]]*loop:' &&
    fail "$f carries loop: in a file that has an on: keeper task — loop: on a keeper task
    does not exist."
done

# ★ "running" is a claim about a fact. The reference to the PING register is what moves
# the write into a later Passage; without it the task lands in Passage 0 and records
# "running" before a single node answered, with the run still green.
grep -q 'register\.hosts\.alive' "$service_root/scenario/state.yml" ||
  fail "scenario/state.yml no longer refers to register.hosts.alive — the
  operational_status write falls back into Passage 0 and records running before the PING
  gate ran."

modules_flag=$(plugin_modules_flag) || {
  echo "validate: the plugin schema documents are not bound — see above" >&2
  exit 2
}

# shellcheck disable=SC2086 # modules_flag is a flag with an argument; the split is wanted
run_soul_lint validate-service-tree "$service_root" --service-name redis $modules_flag
echo "validate: manifest, types and every scenario passed"
