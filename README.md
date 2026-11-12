# peace

peace is an Erlang library for replicated state machines. It implements
Flexible Paxos.

You write a deterministic state machine and start a cluster of servers that
each run it. Clients submit values. peace puts the values in one order and
applies them in that order on every server. The API is modelled on
[ra](https://github.com/rabbitmq/ra).

The difference from ra is the quorum rule. Raft requires a majority to elect
a leader and a majority to commit an entry. Flexible Paxos requires only
that every election quorum intersects every commit quorum, so the two sizes
can be set separately:

```erlang
%% Five members. Two acknowledgements commit a value. Four elect a leader.
peace:start_cluster(Ids, Machine, #{quorum => {counting, 4, 2}}).
```

Flexible Paxos is described in chapter 4 of Heidi Howard's thesis,
[Distributed consensus revised](docs/UCAM-CL-TR-935.pdf) (UCAM-CL-TR-935).

## Example

A state machine:

```erlang
-module(counter).
-behaviour(peace_machine).
-export([init/1, apply/3]).

init(_Args) -> 0.

apply(_Meta, {add, N}, Count) -> {Count + N, Count + N};
apply(_Meta, reset, Count) -> {0, Count}.
```

A cluster that runs it:

```erlang
{ok, _} = application:ensure_all_started(peace),
Ids = [{counter, N} || N <- ['a@host', 'b@host', 'c@host']],
{ok, _Started, []} = peace:start_cluster(Ids, {module, counter, []}, #{}),

{ok, 5, Leader} = peace:propose(Ids, {add, 5}),
{ok, 5, _} = peace:consistent_query(Leader, fun(Count) -> Count end),
{ok, 5, _} = peace:local_query(hd(Ids), fun(Count) -> Count end).   %% may be stale
```

`apply/3` can also return effects. Only the leader performs them. The
effects are `{send_msg, Dest, Msg}` and `{mod_call, M, F, A}`. A machine can
export `state_enter/2` to be called when its server changes role. See
[peace_machine](src/peace_machine.erl).

## Relation to the thesis

peace uses the terminology of the thesis. Section numbers in the code and in
this file refer to it.

| peace | Thesis |
|---|---|
| epoch, `{Round, ServerId}` | Epoch (§2.2). peace epochs are unique by construction. In §3.9 acceptors vote for an epoch. |
| `prepare`, `promise` | Phase one (§2.2) |
| `propose`, `accept` | Phase two (§2.2) |
| `nack` | NACKs (§3.1) |
| decided, learned | Decided, learning (§3.3) |
| leader, with one phase one for the whole sequence | Multi-Paxos (§3.6) |
| every server is a proposer and an acceptor | Co-located roles (§3.7) |
| phase-one and phase-two quorums | Revision A (§4.1), published as Flexible Paxos |
| `{counting, N, 1}`, `{counting, 1, N}` | Singleton Paxos, All aboard Paxos (§4.3.2) |
| `{counting, N div 2 + 1, N div 2}` | Even nodes optimisation (§4.3.3) |
| `{grid, Rows}` | Grid quorums (§4.1.3) |
| `propose_to => quorum` | Proposing to a phase-two quorum (§4.3.3) |
| value | Value |

These features are not in the thesis. peace uses the names from Raft and
Viewstamped Replication for them:

- pre-vote
- a leader stepping down when it loses its quorum
- commit index
- sessions
- snapshots
- read leases
- membership change through joint configurations

Membership change is related to revision B (§4.2) but does not implement it.

peace calls the thing a client submits a value, as the thesis does. ra calls
it a command.

## Quorum systems

| `quorum` | Phase one (elect) | Phase two (commit) |
|---|---|---|
| `majority` (default) | more than half | more than half |
| `{counting, Q1, Q2}` | any `Q1` members | any `Q2` members, with `Q1 + Q2 > N` |
| `{grid, Rows}` | one member from every row | every member of one row |
| `{module, Mod, Arg}` | defined by `Mod` | defined by `Mod` |

A server does not start if its quorum system has a phase-one quorum and a
phase-two quorum that do not intersect. For up to 16 members this is checked
by enumerating the quorums, including for custom modules. See
[peace_quorum](src/peace_quorum.erl).

## Storage

An acceptor must keep its promise and the proposals it has accepted across
restarts. The `storage => {Module, Args}` option selects the backend:

| Backend | Behaviour |
|---|---|
| `{peace_storage_mem, #{}}` | **Default.** Keeps state in memory. State is lost when the process stops. Safe only if a restarted server never rejoins under the same id. |
| `{peace_storage_dets, #{dir => Dir}}` | One dets file per server, synced on every write. Durable and slow. |

A backend implements the [peace_storage](src/peace_storage.erl) behaviour,
which has three callbacks.

## Features

### Sessions

A client whose request times out does not know whether its value was
decided. If the client submits the value with `#{session => {ClientId, Seq}}`,
peace applies it at most once regardless of how many times it is retried.
Each retry returns the reply from the first application. A client can have
one value in flight at a time, and `Seq` must increase.

```erlang
{ok, Reply, _} = peace:propose(Ids, Value, #{session => {my_id, 17}, timeout => 2000}).
```

### Snapshots

Every `snapshot_interval` applied indexes (default 4096), a server stores
its machine state and deletes the log up to that index. A restarted server
starts from its snapshot. A follower that needs log entries the leader has
deleted is sent the snapshot. The snapshot is the machine state as one
Erlang term. It is written in one storage write and sent in one message.

### Read leases

By default, `consistent_query/2` puts a no-op through the log. If
`read_lease_ms` is set, a leader answers from its own state while it holds
leases from enough servers that the remaining servers cannot form a
phase-one quorum. With flexible quorums this can be fewer than a majority.
Under `{counting, 4, 2}` over five servers it is the leader and one
follower.

Read leases are off by default. Their safety depends on clocks: server
clocks must run within ten per cent of each other's rate. No other feature
depends on clocks.

### Membership change

`peace:change_members(Servers, Members, Quorum)` moves the cluster to a new
configuration. The new configuration can have different members, more
members, fewer members, no members in common with the old one, or the same
members under a different quorum system.

The change goes through a joint configuration. While the joint configuration
is in force, a value needs a phase-two quorum of the old configuration and a
phase-two quorum of the new one. This prevents the two configurations from
deciding different values. The change is recorded in the log, so it
completes even if the leader that started it fails.

Start a new server before adding it, with `members` set to the current
cluster. It waits until a configuration includes it.

```erlang
ok = peace:start_server(#{id => D, members => [A, B, C], machine => Machine}),
{ok, ok, _} = peace:change_members([A, B, C], [B, C, D], majority).
```

### Proposing to a phase-two quorum

With `propose_to => quorum`, a leader sends each proposal to the smallest
set of peers that forms a phase-two quorum together with the leader (§4.3.3).
Under `{counting, 4, 2}` over five servers that is one peer per value
instead of four. If those peers do not accept within two heartbeats, the
leader sends the proposal to all peers. This option is off by default.

In the thesis, the servers outside the quorum hold no copy of the value. In
peace they learn each value one heartbeat later by requesting it. The option
reduces messages. It does not reduce storage.

### Elections

- **Pre-vote.** A follower asks its peers before it raises its epoch. A
  server that was disconnected and reconnects does not depose a working
  leader.
- **Quorum-loss step-down.** A leader steps down when a phase-two quorum
  stops answering it. Clients get an error instead of a timeout.

## Verification

peace is verified at four levels.

| Level | What it checks | Command | Time |
|---|---|---|---|
| Unit tests | The protocol core and the supporting modules | `make test` | seconds |
| Deterministic simulation | The real server processes under faults | `make dst` | about 8 minutes |
| Trace validation | That simulated runs are behaviours of the TLA+ model | `make trace` | about 4 minutes |
| Model checking | The TLA+ models of the protocol | `make tlc`, `make ind`, `make tlc-long` | minutes to hours |

Details of the models are in [formal/README.md](formal/README.md).

### Model checking

[formal/FlexiblePaxos.tla](formal/FlexiblePaxos.tla) is a TLA+ model of the
protocol. TLC checks it exhaustively for small clusters. The properties are
agreement, and that every value a server treats as decided was decided.

[formal/Reconfig.tla](formal/Reconfig.tla) is a separate model of membership
change. It was written and checked before the code.

Both models include:

- **Mutations.** Each mutation removes one safeguard. TLC must find a
  counterexample for each one. The mutations are: quorums that do not
  intersect, an acceptor that ignores its promise, a deposed leader that
  keeps sending its commit index, a candidate that leads while behind a
  snapshot, membership change without a joint configuration, and a candidate
  that asks only the configuration it has applied.
- **Reachability checks.** Each one confirms that the model can reach a
  state the properties depend on, such as a decided value.

[formal/FlexiblePaxosInd.tla](formal/FlexiblePaxosInd.tla) states an
inductive invariant for the protocol model.
[Apalache](https://apalache-mc.org) checks it symbolically. The check takes
8 seconds for a configuration that takes TLC 59 minutes, and it completes
for configurations TLC cannot finish, such as five acceptors with three
epochs and three indexes. The constants are fixed for each check, so this is
not a proof for all cluster sizes.

Writing the invariant found an error in the model: a rule that the code
implemented and the model did not. The code was not affected. See "A hole in
the model" in [formal/README.md](formal/README.md).

The TLC targets skip a config if its model and config files are unchanged
since the last successful run. Results are recorded in
[formal/checked.tsv](formal/checked.tsv). `FORCE=1` runs every config.

### Deterministic simulation

[dst/peace_dst.erl](dst/peace_dst.erl) runs the real `peace_server`
processes under [eta](https://github.com/jessestimpson/eta). Each server is
on its own simulated node. The scheduler is seeded, the clock is virtual,
and the network drops and delays messages. A run is reproducible from its
seed.

Workloads:

| Workload | What it does |
|---|---|
| Faults | Servers are disconnected, killed, and restarted from their disks |
| Churn | Forced elections, two-server partitions, and delayed `learned` messages |
| Membership | The cluster moves between five configurations of five servers |
| dets | The dets backend runs alongside the simulated disk, and the two are compared each time a server reopens its file |

In every workload, servers take a snapshot every five indexes and clients
retry with sessions. Read leases are also tested with two of three servers
running clocks six per cent fast.

Eight invariants are checked after every step. They include agreement across
the whole run, that a server's memory never holds state its disk does not,
and that a linearizable read returns every value acknowledged before it.

Nine planted bugs confirm that the suite can fail:

- quorums that do not intersect
- a disk that loses its contents on restart
- a dets backend that does not write promises
- a deposed leader that does not step down
- a candidate that leads while behind a snapshot
- acceptors that ignore read leases
- clocks that differ in rate by a factor of ten
- membership change without a joint configuration
- clients that retry without a session

Limitation: in the dets workload, dets calls go to eta's in-process
replacement for dets. It keeps the file contents but is not the real dets
implementation. The unit tests cover real dets.

### Trace validation

[dst/peace_dst_trace.erl](dst/peace_dst_trace.erl) converts a simulated run
into a sequence of actions of `FlexiblePaxos.tla`. TLC then checks two
things: that each action is permitted by the model at that point, and that
after each step the model's state equals the servers' state.

The actions are derived from changes to each server's durable state
(promise, log, snapshot) and from the messages it sent. They are not derived
from what the code reports about itself.

TLC takes about one second per run. Model checking does not need to be
repeated when the code changes, because trace validation checks the code
against the model directly.

Trace validation rejects some runs that pass the simulation's invariants:

| Planted bug | Rejected by the model | Caught by invariants |
|---|---|---|
| Quorums that do not intersect | 30 of 30 runs | 6 |
| Disk that loses its contents | 24 of 30 | 24 |
| No snapshot guard | 3 of 60 | 1 |
| Deposed leader does not step down | 3 of 60 | 0 |

Limitations:

- It covers only what `FlexiblePaxos.tla` models. Membership change, read
  leases and sessions are not covered.
- The model's message set contains every message sent. An action passes if
  the messages that justify it were sent, even if the server had not yet
  received them.

### Unit tests

The tests in [test/](test/) cover:

- the protocol core as a pure function, including a replay of TLC's
  counterexample for the deposed leader
- read leases with follower clocks ten per cent fast (safe) and 25 per cent
  fast (unsafe)
- quorum arithmetic
- whole clusters on real processes
- the dets backend on real dets, through closes and kills

### Test-only configuration

The configuration keys that plant bugs, and the hook that trace validation
uses, are compiled only when `TEST` is defined. `rebar3 eunit` defines it. A
release build ignores these keys, so configuration cannot disable a
safeguard.

### Commands

```
make test       # unit tests
make dst        # deterministic simulation, about 8 minutes
make trace      # trace validation, about 4 minutes
make tlc        # quick TLC configs, a few minutes
make ind        # inductive invariant with Apalache, about 3 minutes
make tlc-long   # TLC configs with tens of millions of states, about 2 hours
make tlc-soak   # the three-index membership config, about 8 hours
```

Requirements:

- `make dst` and `make trace` need eta. The `dst` profile declares it as a
  git dependency. For local development, link a checkout at
  `_checkouts/eta`.
- `make trace` and the TLC targets need Java 11 or later.
- `make ind` needs Apalache, which is not included in the repository. See
  [formal/README.md](formal/README.md).

## Source layout

| File | Contents |
|---|---|
| [src/peace.erl](src/peace.erl) | Client API |
| [src/peace_core.erl](src/peace_core.erl) | The protocol, as a pure function from an event and a state to a new state and a list of effects |
| [src/peace_server.erl](src/peace_server.erl) | The `gen_server` that performs the effects: storage writes, timers and sends |
| [src/peace_quorum.erl](src/peace_quorum.erl) | Quorum systems and their validation |
| [src/peace_machine.erl](src/peace_machine.erl) | The state machine behaviour |
| [src/peace_storage.erl](src/peace_storage.erl) | The storage behaviour. The two backends are in separate modules. |
| [formal/FlexiblePaxos.tla](formal/FlexiblePaxos.tla) | TLA+ model of the protocol. Comments in `peace_core` name the model action each clause implements. |
| [formal/FlexiblePaxosInd.tla](formal/FlexiblePaxosInd.tla) | The protocol model restated for Apalache, with the inductive invariant |
| [formal/Reconfig.tla](formal/Reconfig.tla) | TLA+ model of membership change |
| [formal/TraceFlexiblePaxos.tla](formal/TraceFlexiblePaxos.tla) | TLA+ spec used for trace validation |

## Limitations

peace is not ready for production use. [ROADMAP.md](ROADMAP.md) lists the
work required.

- **Snapshots are not chunked.** A snapshot is one Erlang term, sent in one
  message and stored in one write. The machine state must be small enough
  for that.
- **Sessions do not expire by time.** The session table is bounded by
  `max_sessions`. When it is full, the session with the oldest index is
  evicted.
- **Only §4.1 of the thesis is implemented.** The following are not:
  - Revision B (§4.2), quorums that vary by epoch. Membership change is
    related to it but does not implement it.
  - Revision C (chapter 5), early completion of phase one.
  - Quorum-based value selection (chapter 6).
  - The epoch allocation schemes of chapter 7 other than the first. peace
    pre-allocates epochs to proposers as `{Round, ServerId}`, which is the
    first of the five approaches in table 7.2. The other four (an allocator,
    value mapping, recovery, and the hybrids of §7.4) allow any proposer to
    decide a value in one round trip without a leader. peace uses a leader
    for this (§3.6).
