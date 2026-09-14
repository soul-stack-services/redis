#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/.." && pwd)

# shellcheck source=scripts/tooling.sh
. "$script_dir/tooling.sh"

[ -n "${SOUL_STACK_ROOT:-}" ] || {
  echo "test-l0: SOUL_STACK_ROOT is required for hermetic destiny fixtures" >&2
  exit 2
}
[ -d "$SOUL_STACK_ROOT/examples/destiny" ] || {
  echo "test-l0: examples/destiny is missing under SOUL_STACK_ROOT" >&2
  exit 2
}

# The same binding validate.sh uses. Without it the plugin steps' params are checked
# against nothing in L0 and the diagnostic stays a hint in the general output. The guard
# below proves the flag actually reaches the run.
modules_flag=$(plugin_modules_flag) || {
  echo "test-l0: the plugin schema documents are not bound — see above" >&2
  exit 2
}

tmp_root=$(mktemp -d)
cleanup() { rm -rf "$tmp_root"; }
trap cleanup EXIT HUP INT TERM

# A hermetic bundle: a copy of the service beside a symlink to the core's destiny bricks.
# Prints the path to the copy — mutating it does not touch the repository.
build_bundle() {
  bundle_root="$1"
  service_copy="$bundle_root/service/redis"
  mkdir -p "$service_copy"
  cp -R "$repo_root/." "$service_copy/"
  rm -rf "$service_copy/.git"
  ln -s "$SOUL_STACK_ROOT/examples/destiny" "$bundle_root/destiny"
  echo "$service_copy"
}

# The ONLY place the run is assembled: the guard below goes through the same call, or it
# would be guarding itself — a flag dropped from the real run would go unnoticed.
l0_run() {
  # shellcheck disable=SC2086 # modules_flag is a flag with an argument; the split is wanted
  run_soul_trial run "$1" $modules_flag
}

# The service root, not scenario/: the same pass picks up migration tests
# (migrations/<NNN>_<slug>/tests/*.yml). As a separate command they would be forgotten.
l0_run "$(build_bundle "$tmp_root/bundle")"
echo "test-l0: the service's scenarios and migrations passed"

# A guard on the binding itself. Without it the run went green on any plugin step param,
# and the only way to notice was a hint in the output — that is, no way. The subject is
# checked by MUTATION, not by reading this script: a copy gets a broken param on a plugin
# step and is run TWICE — unbound and bound. The double run is the point: one failure is
# not enough, because the `unknown_param` diagnostic looks the same for a core step, which
# is always checked, and for a plugin step, which without a binding is checked against
# nothing. So the mutation must PASS unbound and FAIL bound — then it is the binding that
# catches it.
guard_copy=$(build_bundle "$tmp_root/guard")
guard_target="$guard_copy/scenario/provision.yml"
# `userdata` and not one of the other params on purpose: the mutation has to be invisible
# to everything EXCEPT the binding, and every other param of that step is named in a
# `params_subset` assertion, which would fail the unbound run for its own reason.
sed 's/^\( *\)userdata: "\${ vault(vars\.machine_userdata_ref) }"$/\1userdatas: "${ vault(vars.machine_userdata_ref) }"/' \
  "$guard_target" >"$tmp_root/mutated.yml"
# The file must CHANGE: grepping for the new key would say "present" on a file that had it
# before the mutation too, i.e. the guard would be checking itself. `cmp`'s exit code is
# read exactly: 0 — the files matched (the mutation did not apply), 1 — they differ, 2+ —
# cmp itself could not read them, and treating that as "differ" means carrying on with an
# unverified mutation.
mutation_rc=0
cmp -s "$guard_target" "$tmp_root/mutated.yml" || mutation_rc=$?
[ "$mutation_rc" -eq 1 ] || {
  if [ "$mutation_rc" -eq 0 ]; then
    echo "test-l0: the mutation did not apply — no plugin step with that param was found,
    so the guard would be watching the wrong thing" >&2
  else
    echo "test-l0: cmp could not compare the copy with the mutation (code $mutation_rc)" >&2
  fi
  exit 2
}
cp "$tmp_root/mutated.yml" "$guard_target"

unbound_log="$tmp_root/guard-unbound.log"
if ! run_soul_trial run "$guard_copy" >"$unbound_log" 2>&1; then
  echo "test-l0: the mutated copy fails WITHOUT the binding too — so what broke is not a
    plugin step param, and the guard would be watching something other than the binding.
    Last lines:" >&2
  tail -20 "$unbound_log" >&2
  exit 2
fi

guard_log="$tmp_root/guard.log"
if l0_run "$guard_copy" >"$guard_log" 2>&1; then
  echo "test-l0: a run with a bad plugin step param passed — plugin step params are not
    being checked, and green here means nothing" >&2
  exit 1
fi
grep -q 'unknown_param' "$guard_log" || {
  echo "test-l0: the run with a bad plugin step param failed, but not on it — there is no
    unknown_param in the output. Last lines:" >&2
  tail -20 "$guard_log" >&2
  exit 1
}
echo "test-l0: plugin step params are checked in the run"
