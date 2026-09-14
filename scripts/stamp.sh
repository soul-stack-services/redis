#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
service_root=$(CDPATH= cd -- "$script_dir/.." && pwd)

# shellcheck source=scripts/tooling.sh
. "$script_dir/tooling.sh"

# schema.lock holds the top of the ladder plus a hash of the PARSED state_schema, so a
# comment or a reordered key does not move it. `validate-service` compares both on every
# run: a schema edited with no ladder rung behind it is caught by nothing else, online or
# offline. `schema-stamp` refuses to stamp a service that is red — a stamp claims the
# schema and the ladder agreed, which a broken tree has not established.
run_soul_lint schema-stamp "$service_root"
echo "stamp: migrations/schema.lock rewritten"
