# redis — a service that raises its own machines

`create` provisions virtual machines through a machine provider, installs the Soul agent
on them, and rolls out one standalone Redis per machine: the path from no machines at all
to a Redis answering `PING`. Two scenarios stand beside it — one that deploys onto
machines somebody else raised, and one day-2 operation.

```
create            ─┬─ provision.yml ── vm.created → bootstrap.issued → ssh.run → soul.registered
                   └─ deploy.yml ───── state.present ×2 → apply destiny:redis → instance.pinged → user.present
create_from_souls  ─── deploy.yml       (the same rollout; the roster is given, not built)
add_user           ─── state.set ×2 → apply destiny:redis → user.present
```

`create_from_souls` exists because the machine half and the Redis half fail for different
reasons and a run that does both can only be debugged from one end. It declares its roster
with `source: { roster: true }` ([ADR-0081](https://github.com/soul-stack/soul-stack/blob/main/docs/adr/0081-roster-at-create.md)),
which is what lets `POST /v1/incarnations` bind the hosts before the run starts.

## Status: a debugging tool for the site, and the engine's gate subject

Decided 2026-09-14, in two steps on the same day.

This repository is kept for **cheap engine debugging** — a whole `create` on a workstation
instead of a billed VM per cycle — and it is published as a worked reference rather than
grown into a product. Site acceptance runs remotely, against the services that already
exist and the provider that already serves them; a local stand cannot see what is
site-specific (teleport instead of a static key, a closed cloud-init, resource-manager ids,
profiles), so anything that breaks only there is green here. **Locally, engine defects;
remotely, acceptance.** The one defect this repository has already found —
[a missing bounded retry on the direct SSH transport](#three-things-a-live-run-cost) —
could not have been found in the cloud, because the cloud path is teleport and teleport's
dialer retries. It cost forty minutes and no hardware.

Then NIM-876 gave it a second duty: **the engine's blocking pre-tag gate runs this
repository.** `make e2e-live-gate` clones it at a commit the engine pins, registers it as a
service and drives `create_from_souls` and `add_user` against a live Redis in a container.
What that buys the engine is a subject with a real `state_schema`, declared secrets, a
destiny brick and a plugin — which is what a green gate has to mean, because the engine cut
its own bundled redis example in NIM-871 and everything a service proved left with it.

Two consequences for anyone editing here. A change that breaks `create_from_souls` or
`add_user` breaks the engine's release gate, so those two are load-bearing and not
examples. And the gate follows a **pinned commit**, so a change reaches it only when
someone bumps the pin in `tests/e2e-live/harness/servicecatalog.go` — a fix here is not
live over there until then, deliberately, so that a push cannot red somebody's release.

## Why this exists after the engine cut its own redis example

The engine used to ship [`examples/service/redis`](https://github.com/soul-stack/soul-stack/tree/main/examples/service/redis)
— a different subject, not an earlier draft of this one:

| | subject | machines |
|---|---|---|
| the engine's former `examples/service/redis` | the depth of the service DSL — `state_schema`, a fifteen-rung migration ladder, twelve scenarios, day-2 operations, ~180 L0 cases | roll onto an existing roster |
| this repository | the bootstrap path, end to end | **created by the run** |

**That example is gone** (NIM-871, 2026-09-14): a service is its own repository, and
bundling one made the engine's gate depend on a service's lifecycle. So the division above
is history, and the part of it that mattered to the engine — a live service being created
and then operated — is what `create_from_souls` and `add_user` here now carry.

Topology is still deliberately absent: replication, sentinel and cluster belong to a
service whose subject they are, and this repository's subject is the bootstrap path.

What is copied from over there rather than reinvented: the `redis` destiny brick and the
`redis` plugin. This repository holds a service, not a role.

## Running this against a cloud

The machine provider is addressed by its **registration alias**:

```yaml
- name: Create the machines
  on: keeper
  module: vmlocal.vm.created
```

A plugin artefact carries no name of its own. Address level 1 — the `vmlocal` above — is
whatever an operator writes in `keeper.yml::plugins.soul_modules[].name`, and it appears
nowhere in the artefact's bytes. This service names `vmlocal` because that is the provider
it was written against and run against.

So there are two ways to point it elsewhere, and both are one line:

- register a cloud provider that speaks the same `vm` object and the same
  `created/destroyed/probed/resized` actions **under the alias `vmlocal`** — this
  repository does not change at all;
- or change that one `module:` line and the matching alias in `keeper.yml`.

What must NOT change for either to work is the parameter surface: param-level strictness
refuses a call carrying a key the state does not declare. `vmlocal` holds itself to the WB
cloud's surface key for key, and a test in that artefact reddens when the two drift.

The values in [`vars/50-machines.yaml`](vars/50-machines.yaml) do change — `endpoint`
becomes a compute API rather than a libvirt URI, the profile's `network_id` becomes a
cloud network. That file is site data: a fleet forks this repository and edits it
([ADR-0082](https://github.com/soul-stack/soul-stack/blob/main/docs/adr/0082-service-vars.md)).

## What the stand has to supply

The engine gives you a transport to a machine with no agent on it (`core.ssh.run`) and
nothing else — **what** to install is the service's policy, and **how to be let in** is
the site's. Four things have to exist before a run:

1. **An SSH key the Keeper authenticates with.** The `static` SshProvider hands the Keeper
   a long-lived private key; the public half reaches every machine through cloud-init.
2. **A host CA the Keeper verifies machines by.** `push.transport: direct` refuses to
   connect to a host that does not present a certificate signed by a CA in
   `push.host_ca_refs[]` — an empty CA set is an error, never a blind connect, and there
   is no trust-on-first-use. Every machine therefore boots with a host key and a
   certificate, both delivered by cloud-init. The certificate carries **no principals**,
   which for a host certificate means "valid for any host": the Keeper dials an address
   the machine only learns from DHCP.
3. **Somewhere to fetch the `soul` binary from.** `vars.soul_binary_url` — on a local
   stand, a directory served on the libvirt bridge.
4. **A Vault PKI role that allows the machines' names.** SID is the hostname and the
   machines are called `<incarnation-id>-<n>`; a bare name outside the role's domains is
   refused when the seed CSR is signed, and that surfaces as a failing `soul init` several
   steps after the name was chosen.

`scripts/local-stand.sh` mints (1) and (2), renders the cloud-init document, writes all of
it to the Vault paths `vars/50-machines.yaml` names, publishes the two keeper-side plugins
as git repos of built artefacts, and sets up (3). It stops before editing `keeper.yml` or
issuing grants, and prints those instead.

```sh
SOUL_STACK_ROOT=../../soul-stack \
SSH_STATIC_SRC=../../soul-stack-plugin/ssh-static \
STAND_DIR=/tmp/keeper-dev \
  ./scripts/local-stand.sh
```

⚠ Re-provision the stand with `DEV_KEEPER_EXTRA_IP=192.168.122.1` first. A machine dials
the Keeper at the bridge address and pins it to the keeper CA, so without that address in
the certificate's SANs the bootstrap channel fails — the dial succeeds and the handshake
does not.

## Checks

```sh
make validate   # manifest, types, every scenario (soul-lint)
make test       # validate + the L0 runs
make stamp      # rewrite migrations/schema.lock after a state_schema edit
```

Both need `SOUL_STACK_ROOT` pointing at a core checkout — for the linter, for the destiny
bricks the L0 runs render against, and for the two plugin schema documents the plugin
steps' params are checked against. That binding is **mandatory**: without it an unknown
param on a plugin step passes silently and the diagnostic stays a hint. `test-l0.sh`
proves the binding is live by mutating a param and requiring the run to pass unbound and
fail bound.

`make validate` also carries the guards this service's own defects paid for — a plugin
step's `retry:` with no `register.self` predicate, no `${ host.* }` and no `loop:` in a
file holding an `on: keeper` task, the machine provider staying out of `service.yml`'s
`modules[]`, and the `operational_status` write keeping its reference to the PING register.

⚠ A green `make validate` proves nothing about the steps inside `provision.yml` and
`deploy.yml`: the linter walks the tasks in the document it was handed and does not follow
`include:` — silently, without the hint that exists for that case. The L0 run does see
them.

## Three things a live run cost

Each of these was green in tests and red on a machine.

- **A lease is not a booted machine.** A VM is reported ready when it takes a DHCP lease
  carrying an address and a hostname — the cloud's own predicate, and the earliest moment
  a machine can be named — but sshd comes up later in the boot. `core.ssh.run` on the
  direct transport has no bounded retry of its own (the teleport path does), so the first
  connect failed the whole run with `connection refused` about ten seconds after the
  lease. The wait is a bare `retry:` on that step.
- **A bare `retry:`, never `until:`.** A plugin failure carries no Output, so a predicate
  reading `register.self.*` fails with `no such key` and kills the retry on exactly the
  failure it was written for. `core.exec.run` has no such hole, which is what makes a step
  ported from a shell break silently.
- **The image prepares nothing.** `soul.yml`, the keeper CA and the systemd unit are laid
  down by the install commands, before `soul init`. From the image this service needs
  systemd, curl and SSH access, and nothing else.

## What this service does not do

No day-2 scenarios, no migration ladder (the schema is at version 1), no TLS, no
replication, no `destroy`. Each of those is a real thing a service needs and each would
have made the create path harder to read, which is the one thing this repository is for.
