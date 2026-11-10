# peace

Replicated state machines for Erlang over **Flexible Paxos**.

The programming model is [ra](https://github.com/rabbitmq/ra)'s: you write a
deterministic state machine, start a cluster of servers that each run it, and
submit values. peace agrees on one order for the values and applies them,
in that order, on every server.

Where it differs from ra is the quorum. Raft needs a majority both to elect a
leader and to commit an entry. Flexible Paxos (Heidi Howard's thesis,
[docs/UCAM-CL-TR-935.pdf](docs/UCAM-CL-TR-935.pdf), chapter 4) shows that the
two only have to intersect each other, so a cluster can choose where to spend:

```erlang
%% Five members. Two acknowledgements commit a value; four elect a leader.
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

{ok, 5, Leader} = peace:propose(Ids, {add, 5}),
{ok, 5, _} = peace:consistent_query(Leader, fun(Count) -> Count end),
{ok, 5, _} = peace:local_query(hd(Ids), fun(Count) -> Count end).   %% may be stale
```

`apply/3` may also return effects, which only the leader performs
(`{send_msg, Dest, Msg}`, `{mod_call, M, F, A}`), and a machine may export
`state_enter/2` to react to becoming leader. See
[peace_machine](src/peace_machine.erl).

## The thesis

peace follows Heidi Howard's thesis,
[Distributed consensus revised](docs/UCAM-CL-TR-935.pdf) (UCAM-CL-TR-935),
and uses its words. Section numbers in the code and in this file are to it.

| Here | Thesis |
|---|---|
| epoch, `{Round, ServerId}` | epoch (§2.2); unique by construction, where §3.9 has acceptors vote for one |
| `prepare`, `promise` | phase one (§2.2) |
| `propose`, `accept` | phase two (§2.2) |
| `nack` | NACKs (§3.1) |
| decided, learned | decided; learning (§3.3) |
| leader, one phase one for the whole sequence | Multi-Paxos (§3.6) |
| every server a proposer and an acceptor | roles (§3.7) |
| phase-one and phase-two quorums | revision A (§4.1), published as Flexible Paxos |
| `{counting, N, 1}`, `{counting, 1, N}` | Singleton Paxos, All aboard Paxos (§4.3.2) |
| `{counting, N div 2 + 1, N div 2}` | the even nodes optimisation (§4.3.3) |
| `{grid, Rows}` | the grid of §4.1.3 |
| `propose_to => quorum` | proposing to a phase-two quorum (§4.3.3) |
| value, what a machine applies | value |

Not in the thesis, and named as Raft and Viewstamped Replication name them:
the pre-vote, a leader standing down for want of a quorum, the commit index,
sessions, snapshots, read leases, and membership change by joint
configurations. Membership change is in the direction of revision B (§4.2)
but is not that revision. The programming model is
[ra](https://github.com/rabbitmq/ra)'s, except that ra's command is a value
here.

## Quorum systems

| `quorum` | Phase one (elect) | Phase two (commit) |
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

**Sessions.** A client that times out cannot know whether its value was
decided. Submitted with `#{session => {ClientId, Seq}}`, a value is applied
at most once however often it is retried, and the retry gets the reply the
first application got. One value in flight per client, `Seq` increasing.

```erlang
{ok, Reply, _} = peace:propose(Ids, Value, #{session => {my_id, 17}, timeout => 2000}).
```

**Snapshots.** Every `snapshot_interval` applied indexes (default 4096) a
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
a joint configuration in which a value needs a phase-two quorum of the old
and of the new, so the two can never decide apart, and the change is in the
log, so it survives the leader that started it. A server to be added is
started first with `members` set to the cluster as it is, and waits.

```erlang
ok = peace:start_server(#{id => D, members => [A, B, C], machine => Machine}),
{ok, ok, _} = peace:change_members([A, B, C], [B, C, D], majority).
```

**Proposing to a phase-two quorum** (§4.3.3). With `propose_to => quorum`
a leader sends each proposal to the fewest peers that make a phase-two quorum
with it. Under `{counting, 4, 2}` over five that is one peer per value, not
four. A proposal those peers do not accept within two heartbeats goes to
everybody. Off by default. The thesis's standbys hold no copy of the value;
peace's are a heartbeat behind and learn by asking, so the saving is in
messages, not storage.

**Elections.** A follower asks before it raises its epoch (pre-vote), so a
server that was cut off does not depose a healthy leader on its return. A
leader that a phase-two quorum has stopped answering steps down, so clients
are told instead of left to time out.

## How it is checked

Three layers, each covering what the one before cannot.

**TLA+ and TLC** ([formal/](formal/README.md)). The protocol as a model,
checked exhaustively at small bounds: agreement, and that everything a server
treats as decided really was decided. The model has mutations that TLC must
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
value acknowledged before it. A second workload goes after leadership
instead: forced elections, two-server splits and long-delayed `learned`
messages. Servers snapshot every five indexes and clients retry under
sessions, so truncation, recovery and catching up by snapshot are in every
run. A third workload changes the membership as it goes, between five
configurations of five servers. A fourth puts the shipped dets backend
behind the simulation's own disk and compares the two whenever a server
reopens its file; its dets calls go to eta's stand-in, which keeps the file
but is not dets. Leases are also run with two servers in three on clocks
six per cent fast. Nine planted bugs prove the suite can fail: quorums that
do not intersect, a disk that forgets, a dets backend that loses promises,
the deposed leader and the candidate behind a snapshot of the model's
mutations, a lease nobody honours, clocks ten times apart, a change of
membership with no joint step, and clients that retry without a session.

The switches that plant those bugs are compiled in only when `TEST` is
defined, as `rebar3 eunit` defines it. A shipped build does not read them:
no configuration can turn a safeguard off.

**Ordinary tests** ([test/](test/)). The protocol core as a pure function,
including TLC's counterexample for the deposed leader replayed against the
code; a lease with followers' clocks a tenth fast, which holds, and a
quarter fast, which does not; quorum arithmetic; whole clusters on real
processes; and the dets backend, on real dets, against the contract the
simulation assumes of a disk, through closes and kills.

```
make test       # rebar3 eunit
make dst        # rebar3 as dst eunit, on one scheduler thread (about eight minutes)
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
  selection (chapter 6) are not implemented. Nor is chapter 7: peace's epochs
  are pre-allocated to proposers, `{Round, ServerId}`, the first of the five
  approaches in table 7.2. The others (an allocator, value mapping, recovery,
  and the hybrids of §7.4 that generalise Fast Paxos) let any proposer decide
  in one round trip without a leader; peace has a leader for that (§3.6).
