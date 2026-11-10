# peace

Replicated state machines for Erlang over **Flexible Paxos**.

The programming model is [ra](https://github.com/rabbitmq/ra)'s: you write a
deterministic state machine, start a cluster of servers that each run it, and
submit commands. peace agrees on one order for the commands and applies them,
in that order, on every server.

Where it differs from ra is the quorum. Raft needs a majority both to elect a
leader and to commit an entry. Flexible Paxos (Heidi Howard's thesis,
[docs/UCAM-CL-TR-935.pdf](docs/UCAM-CL-TR-935.pdf), chapter 4) shows that the
two only have to intersect each other, so a cluster can choose where to spend:

```erlang
%% Five members. Two acknowledgements commit a command; four elect a leader.
peace:start_cluster(Ids, Machine, #{quorum => {counting, 4, 2}}).
```

## A state machine

```erlang
-module(counter).
-behaviour(peace_machine).
-export([init/1, apply/3]).

init(_Args) -> 0.

apply(_Meta, {add, N}, Count) -> {Count + N, Count + N};
apply(_Meta, reset, Count) -> {0, Count}.
```

```erlang
{ok, _} = application:ensure_all_started(peace),
Ids = [{counter, N} || N <- ['a@host', 'b@host', 'c@host']],
{ok, _Started, []} = peace:start_cluster(Ids, {module, counter, []}, #{}),

{ok, 5, Leader} = peace:process_command(Ids, {add, 5}),
{ok, 5, _} = peace:consistent_query(Leader, fun(Count) -> Count end),
{ok, 5, _} = peace:local_query(hd(Ids), fun(Count) -> Count end).   %% may be stale
```

`apply/3` may also return effects, which only the leader performs
(`{send_msg, Dest, Msg}`, `{mod_call, M, F, A}`), and a machine may export
`state_enter/2` to react to becoming leader. See
[peace_machine](src/peace_machine.erl).

## Quorum systems

| `quorum` | Phase 1 (elect) | Phase 2 (commit) |
|---|---|---|
| `majority` (default) | more than half | more than half |
| `{counting, Q1, Q2}` | any `Q1` members | any `Q2` members, `Q1 + Q2 > N` |
| `{grid, Rows}` | one member from every row | every member of one row |
| `{module, Mod, Arg}` | yours | yours |

A server refuses to start on a quorum system whose phases do not intersect.
For up to 16 members that is checked by enumeration, custom modules included.
See [peace_quorum](src/peace_quorum.erl).

## Storage

An acceptor must remember what it promised and what it accepted.
`storage => {Module, Args}` chooses where:

- `{peace_storage_dets, #{dir => Dir}}`: one dets file per server, synced on
  every write. Durable and slow.
- `{peace_storage_mem, #{}}`: nothing survives the process. **This is the
  default**, and it is safe only if a server that restarts never rejoins
  under the same id.

Both are a [peace_storage](src/peace_storage.erl) behaviour of three
callbacks.

## Retries, snapshots, reads and elections

**Sessions.** A client that times out cannot know whether its command was
chosen. Submitted with `#{session => {ClientId, Seq}}`, a command is applied
at most once however often it is retried, and the retry gets the reply the
first application got. One command in flight per client, `Seq` increasing.

```erlang
{ok, Reply, _} = peace:process_command(Ids, Cmd, #{session => {my_id, 17}, timeout => 2000}).
```

**Snapshots.** Every `snapshot_interval` applied slots (default 4096) a
server stores its machine state and drops the log up to there. It restarts
from the snapshot, and a follower too far behind for the log is sent the
state. The snapshot is the machine state as an Erlang term, written and sent
in one piece.

**Read leases.** `consistent_query/2` normally puts a no-op through the log.
With `read_lease_ms` set, a leader answers from its own state while enough
servers are bound to it that the rest cannot elect anybody. With flexible
quorums that can be fewer than a majority: under `{counting, 4, 2}` over
five, the leader and one follower. Off by default, because it is the one
feature whose safety assumes something about clocks: that they run within
ten per cent of each other.

**Membership.** `peace:change_members(Servers, Members, Quorum)` moves the
cluster to any other configuration: other members, more, fewer, none in
common, or the same members under another quorum system. It passes through
a joint configuration in which a command needs a phase-2 quorum of the old
and of the new, so the two can never decide apart, and the change is in the
log, so it survives the leader that started it. A server to be added is
started first with `members` set to the cluster as it is, and waits.

```erlang
ok = peace:start_server(#{id => D, members => [A, B, C], machine => Machine}),
{ok, ok, _} = peace:change_members([A, B, C], [B, C, D], majority).
```

**Elections.** A follower asks before it raises its ballot (pre-vote), so a
server that was cut off does not depose a healthy leader on its return. A
leader that a phase-2 quorum has stopped answering steps down, so clients
are told instead of left to time out.

## How it is checked

Three layers, each covering what the one before cannot.

**TLA+ and TLC** ([formal/](formal/README.md)). The protocol as a model,
checked exhaustively at small bounds: agreement, and that everything a server
treats as decided really was chosen. The model has mutations that TLC must
find a counterexample for (quorums that do not intersect, an acceptor that
ignores its promise, a deposed leader that keeps advertising its commit
index, a candidate that leads from behind a snapshot) and reachability
checks, so a pass means something. Membership change has a model of its own,
written and checked before the code, with its own two mutations.

**Deterministic simulation** ([dst/](dst/peace_dst.erl)), with
[eta](https://github.com/jessestimpson/eta). The real `peace_server`
processes, one simulated node each, under a seeded scheduler, a virtual clock
and a network that drops and delays. The workload includes cutting servers
off, killing them and restarting them from their disks. Seven invariants are
checked after every step, among them agreement across the whole run, that
memory never runs ahead of disk, and that a linearizable read contains every
command acknowledged before it. A second workload goes after leadership
instead: forced elections, two-server splits and long-delayed `learned`
messages. Servers snapshot every five slots and clients retry under
sessions, so truncation, recovery and catching up by snapshot are in every
run. A third workload changes the membership as it goes, between five
configurations of five servers. Seven planted bugs prove the suite can fail:
quorums that do not intersect, a disk that forgets, the deposed leader and
the candidate behind a snapshot of the model's mutations, a lease nobody
honours, a change of membership with no joint step, and clients that retry
without a session.

**Ordinary tests** ([test/](test/)). The protocol core as a pure function,
including TLC's counterexample for the deposed leader replayed against the
code; quorum arithmetic; whole clusters on real processes; and the dets
backend against the contract the simulation assumes of a disk, through
closes and kills.

```
make test       # rebar3 eunit
make dst        # rebar3 as dst eunit, on one scheduler thread (about five minutes)
make tlc        # formal/check_all.sh quick  (a few minutes)
make tlc-long   # the configs with tens of millions of states
```

`make dst` needs eta. The `dst` profile names it as a git dependency; for
local work, link a checkout at `_checkouts/eta`.

## Layout

| | |
|---|---|
| [src/peace.erl](src/peace.erl) | the client API |
| [src/peace_core.erl](src/peace_core.erl) | the protocol, as a pure function from event and state to state and effects |
| [src/peace_server.erl](src/peace_server.erl) | the `gen_server` that performs those effects: storage, timers, sends |
| [src/peace_quorum.erl](src/peace_quorum.erl) | quorum systems and their validation |
| [src/peace_machine.erl](src/peace_machine.erl) | the behaviour you implement |
| [src/peace_storage.erl](src/peace_storage.erl) | the storage behaviour, and two backends beside it |
| [formal/FlexiblePaxos.tla](formal/FlexiblePaxos.tla) | the model; `peace_core` names the action each clause implements |
| [formal/Reconfig.tla](formal/Reconfig.tla) | the model of membership change |

## Not here yet

- **Snapshots in pieces.** A snapshot is one term in one message and one
  storage write, so the machine state has to be small enough for that.
- **Sessions that expire by time.** The table is bounded by `max_sessions`,
  oldest evicted first, not by how long a client has been silent.
- **The thesis beyond chapter 4.1.** Membership change is in the direction
  of revision B, quorums that vary by epoch, but is not that revision as
  written. Early completion of phase one (revision C) and quorum-based value
  selection (chapter 6) are not implemented.
