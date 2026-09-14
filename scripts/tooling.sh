#!/bin/sh

# Finding the Soul Stack tools. An explicitly named binary wins, then PATH, then a core
# checkout under SOUL_STACK_ROOT. Nothing is downloaded.

# A built binary is used only if it is NOT OLDER than the sources. Otherwise
# `make validate` shows green against an engine hours out of date. `shared/` is compared
# too, not just the tool's own directory — a stale binary's blind spot has come from
# shared/config before.
fresh_enough() {
  bin="$1"; shift
  for src in "$@"; do
    [ -d "$src" ] || continue
    if [ -n "$(find "$src" -name '*.go' -newer "$bin" -print -quit 2>/dev/null)" ]; then
      return 1
    fi
  done
  return 0
}

# Binding a plugin's alias to its schema document — ONE place for both runs. An unbound
# module's params are not checked against anything, and the diagnostic stays a HINT
# (`plugin_params_unchecked`) that drowns in the output. The binding is MANDATORY, not
# best-effort: green has to mean "checked", and "could not check" is a reason to stop.
#
# Both aliases are bound, and both are the registration aliases this service's scenarios
# address — not names the artefacts carry. `vmlocal` is bound to whichever machine
# provider you point VMLOCAL_MODULE_SCHEMA at; that is the point of the alias.
plugin_modules_flag() {
  redis_schema=${REDIS_MODULE_SCHEMA:-${SOUL_STACK_ROOT:+$SOUL_STACK_ROOT/examples/module/redis/schema.json}}
  vm_schema=${VMLOCAL_MODULE_SCHEMA:-${SOUL_STACK_ROOT:+$SOUL_STACK_ROOT/examples/module/vmlocal/schema.json}}
  for pair in "redis:$redis_schema" "vmlocal:$vm_schema"; do
    path=${pair#*:}
    [ -n "$path" ] || {
      echo "neither ${pair%%:*} schema nor SOUL_STACK_ROOT is set — there is nothing to
    check plugin step params against, and unchecked must not be green" >&2
      return 2
    }
    [ -f "$path" ] || {
      echo "schema document for the ${pair%%:*} alias not found: $path" >&2
      return 2
    }
  done
  echo "--modules redis=$redis_schema --modules vmlocal=$vm_schema"
}

run_soul_lint() {
  if [ -n "${SOUL_LINT_BIN:-}" ]; then
    [ -x "$SOUL_LINT_BIN" ] || {
      echo "SOUL_LINT_BIN is not executable: $SOUL_LINT_BIN" >&2
      return 2
    }
    "$SOUL_LINT_BIN" "$@"
    return
  fi
  if command -v soul-lint >/dev/null 2>&1; then
    soul-lint "$@"
    return
  fi
  [ -n "${SOUL_STACK_ROOT:-}" ] || {
    echo "set SOUL_STACK_ROOT or SOUL_LINT_BIN" >&2
    return 2
  }
  if [ -x "$SOUL_STACK_ROOT/soul-lint/bin/soul-lint" ] &&
     fresh_enough "$SOUL_STACK_ROOT/soul-lint/bin/soul-lint" \
                  "$SOUL_STACK_ROOT/soul-lint" "$SOUL_STACK_ROOT/shared"; then
    "$SOUL_STACK_ROOT/soul-lint/bin/soul-lint" "$@"
    return
  fi
  [ -f "$SOUL_STACK_ROOT/soul-lint/go.mod" ] || {
    echo "SOUL_STACK_ROOT does not look like a core checkout: $SOUL_STACK_ROOT" >&2
    return 2
  }
  (
    cd "$SOUL_STACK_ROOT/soul-lint"
    go run ./cmd/soul-lint "$@"
  )
}

run_soul_trial() {
  if [ -n "${SOUL_TRIAL_BIN:-}" ]; then
    [ -x "$SOUL_TRIAL_BIN" ] || {
      echo "SOUL_TRIAL_BIN is not executable: $SOUL_TRIAL_BIN" >&2
      return 2
    }
    "$SOUL_TRIAL_BIN" "$@"
    return
  fi
  if command -v soul-trial >/dev/null 2>&1; then
    soul-trial "$@"
    return
  fi
  [ -n "${SOUL_STACK_ROOT:-}" ] || {
    echo "set SOUL_STACK_ROOT or SOUL_TRIAL_BIN" >&2
    return 2
  }
  if [ -x "$SOUL_STACK_ROOT/keeper/bin/soul-trial" ] &&
     fresh_enough "$SOUL_STACK_ROOT/keeper/bin/soul-trial" \
                  "$SOUL_STACK_ROOT/keeper" "$SOUL_STACK_ROOT/shared"; then
    "$SOUL_STACK_ROOT/keeper/bin/soul-trial" "$@"
    return
  fi
  [ -f "$SOUL_STACK_ROOT/keeper/go.mod" ] || {
    echo "SOUL_STACK_ROOT does not look like a core checkout: $SOUL_STACK_ROOT" >&2
    return 2
  }
  (
    cd "$SOUL_STACK_ROOT/keeper"
    go run ./cmd/soul-trial "$@"
  )
}
