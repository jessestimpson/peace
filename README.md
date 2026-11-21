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
{ok, _Formed, []} = peace:start_cluster(Ids, {module, counter, []}, #{}),

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
| `{peace_storage_wal, #{dir => Dir}}` | **Default.** A write-ahead log with a checksum on every record. Durable. The default `Dir` is the application environment variable `data_dir` of `peace`, which defaults to `"peace_data"`. |
| `{peace_storage_dets, #{dir => Dir}}` | One dets file per server. Durable and slower than the write-ahead log. |
| `{peace_storage_mem, #{}}` | Stores nothing. State is lost when the process stops. A restarted server has a new incarnation and is no longer a member. See "Member identity". For tests. |

A backend implements the [peace_storage](src/peace_storage.erl) behaviour.
The behaviour has three callbacks, and two optional callbacks that store a
snapshot in steps.

A server handles the events that are waiting in its mailbox as a group and
sends one storage write for the group to its storage process,
[peace_writer](src/peace_writer.erl). The storage process merges the writes
that are waiting in its mailbox into one call to the backend. A backend
that syncs once per call therefore performs group commit. The server
handles further events while a write is in progress.

Both durable backends sync every write that contains a promise, a proposal
or a snapshot. A server does not wait for the write of a snapshot. A write
that contains only `learned` entries is not synced.
A `learned` entry records that an index is decided. The decision is already
durable, because a phase-two quorum has stored its acceptances.

A server performs an effect only after every storage write that the effect
depends on has returned:

- An `accept` message waits for the write that stores the proposal.
- A server waits for a write that contains a promise before it does
  anything else.
- A leader sends a proposal without waiting for its own write. The leader
  counts its own acceptance towards a phase-two quorum only after that
  write has returned.
- A leader answers a client when a phase-two quorum has stored the value.

A client that writes to a durable cluster therefore waits for one sync on a
phase-two quorum. Sending a proposal before the write of the leader is the
optimisation of section 10.2.1 of the Raft dissertation (Ongaro, 2014). It
is not in the thesis. See `perform/2` in
[peace_server](src/peace_server.erl) and "The acceptance of the leader" in
[peace_core](src/peace_core.erl).

If a storage write fails, the storage process and the server stop before
the server sends any message that depends on the write. The server is not restarted. If the write-ahead log
finds a damaged record that is not a torn write at the end of the log, the
server does not start. In both cases an operator must decide what to do
with the member.

## Features

### Sessions

A client whose request times out does not know whether its value was
decided. A value that is submitted under a session is applied at most once,
regardless of how many times the client submits it.

A session process submits values under one session:

```erlang
{ok, S} = peace:open_session(Ids, #{window => 64}),

%% Waits for the reply. Several processes can use S.
{ok, Reply} = peace:call(S, Value),

%% Does not wait for the reply. The reply arrives as a message.
Ref = peace:cast(S, Value),
receive {peace_reply, Ref, Result} -> Result end,

ok = peace:close_session(S).
```

- The values of one session process are applied in the order in which the
  session process received them.
- A session process has up to `window` values undecided at one time
  (default 64). While `window` values have no reply, `call` and `cast`
  wait.
- A session process finds the leader, and submits a value again until the
  value has a reply. A call that times out leaves its value in the session.
- The servers keep the last `session_window` replies of each session
  (default 64). `window` must be at most `session_window`.

A client can also assign the sequence numbers itself, with
`peace:propose(Ids, Value, #{session => {ClientId, Seq}})`. `Seq` starts at
1 and increases by 1. The servers answer three errors:

| Reply | Meaning |
|---|---|
| `{error, {session_gap, Last}}` | The value was not applied, because the value with the previous `Seq` is not applied. `Last` is the highest `Seq` applied. The client submits the values from `Last + 1` again. |
| `{error, {session_superseded, Last}}` | The value is a copy of a value that was applied. The servers no longer hold the reply. |
| `{error, {session_gap, 0}}`, for a client that has received a reply | The cluster evicted the session. See `max_sessions`. |

The rules are in "Sessions" in [peace_core](src/peace_core.erl). The session
process is [peace_session](src/peace_session.erl).

### Snapshots

Once in every `snapshot_interval` indexes (default 4096), a server stores
its machine state and deletes the log up to its commit index. A restarted
server starts from its snapshot. A follower that needs log entries the
leader has deleted is sent the snapshot. The snapshot is the machine state,
the session table and the applied configuration.

A snapshot is sent and stored in chunks:

- **Transfer.** The sender encodes the snapshot into chunks, in a separate
  process. The receiver asks for one chunk at a time. A chunk holds at
  most `snapshot_chunk_bytes` bytes (default 262,144). At most one chunk
  per receiver is on the network, so the other messages of the sender,
  which include its heartbeats, are not delayed by more than one chunk.
  See [peace_transfer](src/peace_transfer.erl).
- **Storage.** The write-ahead log writes a snapshot as one record per
  chunk of 1,048,576 bytes and syncs each chunk. The storage process
  performs the other writes of the server between two chunks. See "Writes
  during a checkpoint" in [peace_storage_wal](src/peace_storage_wal.erl).
  The dets backend stores a snapshot in one write.

With a machine state of 1000 MB on the benchmark machine, the longest put
was 8 to 57 ms while a follower received a snapshot, and 111 to 122 ms
while every server stored a snapshot at the same index. See "Large
snapshots" in [bench/README.md](bench/README.md).

The servers of a cluster take their snapshots at different indexes. The
index of a server is set by a hash of the server id, or by the option
`snapshot_offset`. A snapshot of a large state keeps the storage of a
server busy, and the other servers can still form a phase-two quorum.

### Overload

A leader holds at most `max_pending` undecided values (default 8192). A
leader that holds this many answers a further value or consistent query
with `{error, overloaded}`. The value was not proposed, and the caller can
submit it again later. A value that is sent with `peace:propose_async/2`
has no caller to answer, and is dropped.

A server holds at most `max_mailbox` client requests that it has not
handled (default 16,384). A client request is a value or a consistent
query. A server that holds more keeps the oldest requests and refuses the
newest. A leader refuses with `{error, overloaded}`. Another server refuses
with `{error, {not_leader, Leader}}`. While a server holds requests that it
took from its mailbox, it handles the messages of the other servers first.
See "The mailbox limit" in [peace_server](src/peace_server.erl).

A client that submits a refused value again adds load to a leader that is
overloaded. A client that calls `peace:propose/3` must wait for a random
time before it submits the value again. A session process does this, and
also lowers the number of values that it sends:

- The delay before a session process submits values again is random,
  between 25 and 50 ms after the first error. The range doubles with each
  further error, up to `retry_ms`.
- The first `{error, overloaded}` of a round halves the number of values
  that the session process sends without a reply. Each reply adds 1, up to
  `window`.

The measurements are in "Overload" in [bench/README.md](bench/README.md).

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

Start a new server before adding it. A server that starts without stored
state has no configuration. It waits until a configuration includes it.

```erlang
ok = peace:start_server(#{id => D, machine => Machine}),
{ok, ok, _} = peace:change_members([A, B, C], [B, C, D], majority).
```

### Member identity

A server is addressed by `{Name, Node}`. A member of a cluster is identified
by `{Name, Node, Incarnation}`. The API takes and returns addresses.

| Rule | Detail |
|---|---|
| Creation | A server creates its incarnation when it starts and recovers no stored state. The incarnation is 16 random bytes, unless the storage backend supplies one. |
| Storage | The incarnation is stored with the acceptor state, before the server handles any message. |
| Messages | Every message between servers names the incarnation of the sender and of the destination. A server drops a message for another incarnation. |
| Quorums | A configuration names incarnations. A leader counts an answer only from an incarnation that the configuration names. |

A server that has lost its stored state therefore never answers as the
member that it was. The thesis assumes that the persistent state of a
participant is unchanged after a restart (section 1.6). For a server that
has lost its state, peace uses the fail-stop model of section 3.12 of the
thesis: the acceptor that failed does not return, and a membership change
restores the fault tolerance.

Formation is separate from start:

| Function | Effect |
|---|---|
| `peace:start_server(Config)` | Starts a server. With stored state, the server continues as the member that it was. Without stored state, the server has a new incarnation and no configuration. |
| `peace:form_cluster(Servers, Quorum)` | Asks every server for its incarnation and stores the first configuration on every server. Every server must be running. A server stores the configuration only if it has none. |
| `peace:start_cluster(Servers, Machine, Opts)` | Starts the servers and calls `form_cluster`. |

A server does not take its first configuration from its start arguments. A
server that restarts with the same arguments and without its stored state
would otherwise answer as a member without the promises of that member.

`peace:replace_member(Servers, Address)` replaces the member at an address
with the server that now runs at that address. The new server keeps the
position of the member in the quorum system, for example its row in a
grid. The change goes through a joint configuration.

```erlang
%% The server at B lost its disk. It starts with a new incarnation.
ok = peace:start_server(#{id => B, machine => Machine}),
{ok, ok, _} = peace:replace_member([A, C], B).
```

A server that is started with `rejoin => Servers` and without stored state
asks for the replacement itself. The leader sends a challenge to the
incarnation that asked and replaces the member only after that incarnation
answers. A delayed request of an incarnation that no longer runs therefore
replaces no member. `rejoin` is off by default: a disk that is not mounted
when a node starts looks like lost state, and several servers with that
fault would each replace their member and leave their data unused.

Extension points for an application that keeps a record of the members
outside the cluster:

| Extension point | Effect |
|---|---|
| The key `incarnation` in the result of `open/2` of a storage backend | A server that recovers no stored state uses the value as its incarnation. The backend guarantees that the value is never used a second time at the address after the stored state was lost. |
| `peace:form_cluster(Servers, Quorum, #{members => Members})` | Forms a cluster from members whose incarnations the caller knows. The function does not ask the servers, and `Servers` can be a part of the cluster. |
| `peace:form_cluster(Servers, Quorum, #{machine_state => State})` | Forms a cluster whose machine state is `State` and not the result of `init/1`. The state is the state as of index 1, and the first value is decided at index 2. A server that joins later receives the state from the leader. |
| `passive => true` in the configuration of a server, and `peace:activate(Server)` | A passive server receives decided values and sends no message of the protocol: it does not promise, does not accept a proposal and does not campaign. `activate/1` makes it an ordinary member. The activation is stored. |

| `gate => {Module, Function, Args}` in the configuration of a server | The server calls the function before it handles an event, and before it sends a message that states a promise, an acceptance or a proposal. While the function returns `false`, the server behaves as a passive server and sends none of those messages. A leader steps down. An example is a lease that the server holds from a system outside the cluster. |

A passive server is an acceptor that takes no step. A server whose gate is
closed is the same. The other servers
cannot distinguish it from a member that is not reachable. Every behaviour
with a passive server is therefore a behaviour of the protocol, and the
models need no change. These extension points are not in the thesis.

Limitations of member identity:

- A machine state that is given to `form_cluster` stays in the stored
  identity of each server for the lifetime of the server. A server holds
  that state in memory and in storage in addition to its present machine
  state.
- Every call of `form_cluster` for one cluster must give the same machine
  state. peace does not compare the states of different servers.
- A passive member does not count towards a quorum. A configuration needs
  its quorums among the other members.
- A server calls its gate when it handles an event and when it sends a
  message. A server that handles no event does not learn that its gate
  has closed. It sends no message of the protocol in that time, because
  the gate is called before each such message.
- A message that was sent while the gate was open can arrive after the
  gate has closed.

- A replacement needs a leader. The old configuration must still have a
  phase-one quorum and a phase-two quorum without the member that is
  replaced. Under `{counting, 4, 2}` over 5 servers, the loss of the state
  of the leader and of one other server stops the cluster.
- A data directory that is restored from a backup keeps its incarnation and
  has lost the promises made after the backup. peace does not detect this.
- A server does not start on stored state that was written before this
  version, because that state has no incarnation.
- `form_cluster` is not atomic. Two calls at the same time must use the
  same quorum system.
- A founder can lack the configuration that forms the cluster: the call
  did not reach the server, or the server stopped before the write of the
  configuration returned. Such a server accepts the proposals of a leader
  and asks the leader for the configuration. It cannot campaign before
  it holds the configuration. A founder that the other founders cannot
  reach, and a cluster without a leader, do not complete this exchange.

### Versions

`peace:versions()` returns three numbers. All are 1.

| Number | What it covers | Where it is |
|---|---|---|
| Latest message version (`message`) | Every message between servers, the entries in it and the chunks of a snapshot | In the envelope of each message |
| Earliest message version (`message_min`) | The earliest message version that this version of peace handles | In the envelope of each message, with the latest version |
| Stored format (`stored`) | All data that a server stores: the promise, the entries, the snapshot and the identity | Stored once, with the identity of the server |

A server handles every message version from the earliest to the latest.
The envelope of a message names the version of the message and the range
of the server that sent it. The envelope is the same in every version.

| Case | Behaviour |
|---|---|
| A message to a server whose range is known | The sender uses the latest version that both servers handle. |
| A message to a server whose range is not known | The sender uses its earliest version. |
| A message of a version outside the range of the receiver | The receiver drops it, sends its range to the sender, and logs a warning once for each node and version. |
| Stored data of a later format | The server does not start. |
| Stored data without a format | The data has format 1. |

A server learns the range of another server from each message that it
receives. The ranges are not stored. `peace:overview/1` shows them under
`message_versions`. `peace_wire` describes the rules for a later version
of peace that changes the messages.

All stored data of a server has one format. A later version of peace that
changes the format converts the data of an earlier format and writes all
of it back in one atomic batch before the server handles a message.

The write-ahead log also has a format version in the header of each file.
That version covers the layout of the file.

### Upgrading a running cluster

Two versions of peace can run in one cluster when their ranges of message
versions have a common version.

1. Check that every member runs the same version of peace and that the
   cluster has a leader.
2. Stop one server, install the later version of peace and start the
   server.
3. Wait until `peace:overview/1` of the leader shows that server with the
   range of the later version under `message_versions`, and until the
   server has applied the values that the cluster decided.
4. Repeat steps 2 and 3 for every other member.

No step switches the cluster to the later message version. Each pair of
servers uses the later version from the first message after both servers
handle it.

A server can be started again with the earlier version of peace while its
stored data has the format of the earlier version.

Limitations of versions and upgrades:

- Only version 1 of the messages exists. The upgrade procedure is tested
  with message versions that exist only in a test build. Those versions
  wrap the message of version 1.
- The choice of a version covers the encoding of a message. peace has no
  cluster-wide switch for a change of behaviour that every member must
  make at the same time. A later version of peace sends a message that
  exists only in the later version only to a server that handles it.
- After a restart, a server sends its earliest version to each server
  until it receives a message from that server. If the receiver no longer
  handles that version, the first message is dropped and is sent again
  after the receiver has answered with its range.
- A version of peace that changes the stored format cannot be replaced by
  the earlier version on the converted data.
- No format has changed yet. The conversion of stored data is a rule and
  not code.
- The upgrade is not in the Jepsen test.
- The requests of a client have no version.
- The code of a state machine has no version. An upgrade that changes the
  result of `apply/3` is not supported.
- Stored data that a version of peace before 2026-11-14 wrote has no
  identity, and a server does not start on it.

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

peace is verified at six levels.

| Level | What it checks | Command | Time |
|---|---|---|---|
| Unit tests | The protocol core and the supporting modules | `make test` | seconds |
| Deterministic simulation | The real server processes under faults | `make dst` | about 60 minutes |
| Trace validation | That simulated runs are behaviours of the TLA+ model | `make trace` | about 7 minutes |
| Linearizability checking | The client histories of simulated runs, with Porcupine | `make porcupine` | about 11 minutes |
| Jepsen test | A key-value store on five Docker nodes under partitions, kills, pauses and membership changes | `make jepsen` | minutes per run |
| Model checking | The TLA+ models of the protocol | `make tlc`, `make ind`, `make tlc-long` | minutes to hours |

The extension points of member identity are not in the TLA+ models. The
table gives the level at which each one is checked.

| Extension point | Unit tests | Simulation | Trace validation | Linearizability checking |
|---|---|---|---|---|
| Incarnation from the storage backend | 1 test | 80 runs of the storage loss workload | no | no |
| Formation with known members | 1 test | The runs that form one founder of the cluster. They call the servers directly and not `peace:form_cluster/3`. | no | no |
| Formation with a machine state | 2 tests | 500 runs, with restarts, lost disks and membership changes, and 1 planted bug | no | 160 runs |
| Passive server | 2 tests | 400 runs and 1 planted bug | 100 runs | 100 runs |
| Gate | 3 tests | 500 runs and 1 planted bug | 140 runs | 200 runs |

- Trace validation checks the claim that a passive server, and a server
  whose gate is closed, is an acceptor that takes no step of the model
  except that it learns decided values. Every one of the 200 runs is a
  behaviour of `FlexiblePaxos.tla`.
- Trace validation does not cover formation with a machine state. The
  model has no machine state, and a server that is formed in this way
  starts with snapshot index 1 without an action of the model.
- The simulation found one fault in the gate: a server whose gate closed
  during a pre-vote started a campaign when the answers arrived. The fault
  is corrected, and a unit test covers it.
- No extension point is in the Jepsen test.

Details of the models are in [formal/README.md](formal/README.md). Details
of the Jepsen test, its results and its limitations are in
[jepsen/README.md](jepsen/README.md).

### Model checking

[formal/FlexiblePaxos.tla](formal/FlexiblePaxos.tla) is a TLA+ model of the
protocol. TLC checks it exhaustively for small clusters. The properties are
agreement, and that every value a server treats as decided was decided.

[formal/Reconfig.tla](formal/Reconfig.tla) is a separate model of membership
change. It was written and checked before the code.

[formal/Replace.tla](formal/Replace.tla) extends the membership model with
acceptors that lose their state and with the replace request and its
challenge. The model was written after the code.

The models include:

- **Mutations.** Each mutation removes one safeguard. TLC must find a
  counterexample for each one. The mutations are: quorums that do not
  intersect, an acceptor that ignores its promise, a deposed leader that
  keeps sending its commit index, a candidate that leads while behind a
  snapshot, membership change without a joint configuration, a candidate
  that asks only the configuration it has applied, an acceptor that loses
  its state and keeps its identity, and a leader that replaces a member
  without a challenge.
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
| Write-ahead log | The write-ahead log backend runs in the same way, on eta's simulated disk. A killed node loses the file data and the directory operations that it did not sync. |
| Storage loss | Every restart of a server loses the disk of the server. The server starts with a new incarnation and asks to replace the member that it was. The runs also deliver replace requests of incarnations that no longer run. In 80 of the runs, the storage backend supplies the incarnation. |
| Gates | Every server has a gate. The harness closes the gate of a server and opens every gate, at any time. |
| Passive servers | A server that restarts after the cluster was formed is passive until a client activates it. The server keeps its stored state, so it is a member that takes no part. |
| Formation with a machine state | The cluster is formed with a machine state, on every founder or on the first founder only. In the second case, every other server receives the configuration and the machine state from the leader. |
| Upgrade | The harness kills a server and starts it again with a later or an earlier range of message versions, one server at a time. The ranges of two servers differ by at most one step. A server stops handling version 1 470 times in the 500 runs. 200 of the runs have no other fault and end with the check that every server holds every decided value. |

Every run forms its cluster inside the simulation: the first operation
starts the servers, and the second operation collects the incarnations and
stores the configuration, while faults occur. The operation then asks one
server to campaign, so that the first election does not wait for an
election timeout.

In every workload, servers take a snapshot every five indexes and clients
retry with sessions. A server sends a snapshot in chunks of 48 bytes and
stores a snapshot in at least two steps, so faults and other writes occur
between the chunks of a snapshot. Read leases are also tested with two of three servers
running clocks six per cent fast.

Three further tests replace the client. Each client starts a session
process and submits three values that are undecided at the same time. The
tests run the faults workload, the faults workload with a leader that holds
at most two undecided values, and the churn workload.

One test runs the faults workload with `max_mailbox` set to 2, with both
kinds of client. The test also runs session processes with `max_mailbox`
set to 1 and in the churn workload, because a leader refuses a value of a
session process more often in those runs. A server reads the length of its mailbox from the Erlang
runtime system, which the simulation does not replace. The test therefore
also checks that three runs of one seed produce the same trace.

Eleven invariants are checked after every step. They include agreement
across the whole run, that a server's memory never holds state its disk
does not, that a linearizable read returns every value acknowledged before
it, that the values of a session process are applied in the order of
submission, that a leader accepts a replacement only from a server that
ran after the leader started its epoch, and that a server promises and
accepts nothing while it is passive or its gate is closed.

Seventeen planted bugs confirm that the suite can fail:

- a founder without the configuration that forms the cluster, which does
  not ask the leader for the configuration
- servers that send every message in their latest version, while the
  harness upgrades the cluster
- servers that are started without a gate, while the harness closes gates
- a server that is started without `passive`, while the harness expects a
  passive server
- a machine state that forms a cluster as the state of index 0

- quorums that do not intersect
- a server that loses its disk on restart and keeps its incarnation
- a leader that replaces a member without a challenge
- a dets backend that does not write promises
- a write-ahead log that never syncs
- a deposed leader that does not step down
- a candidate that leads while behind a snapshot
- acceptors that ignore read leases
- clocks that differ in rate by a factor of ten
- membership change without a joint configuration
- clients that retry without a session
- servers that apply a value of a session before the previous value of
  that session

Limitations:

- In the dets workload, dets calls go to eta's in-process replacement for
  dets. It keeps the file contents but is not the real dets implementation.
  The unit tests cover real dets.
- The invariant for a passive server and for a closed gate does not
  compare with the state of the server at the moment when the harness
  closes the gate. A server can be handling a group of events at that
  moment, and an event that the server began earlier has passed the gate.
  The invariant compares with the next state that the server publishes.
  A promise or an acceptance in that one group of events is not detected.
- The simulation does not make storage operations fail. Failed writes,
  failed syncs and damaged records are covered by unit tests.

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

The suite validates 250 runs: 20 of the faults workload, 20 of the churn
workload, 10 with `{counting, 4, 2}`, 100 with gates and 100 with passive
servers. In a run with gates or passive servers, a server stops and starts
taking part at any time. Every such run is a behaviour of the model, which
has no gate and no passive server.

Trace validation rejects some runs that pass the simulation's invariants:

| Planted bug | Rejected by the model | Caught by invariants |
|---|---|---|
| Quorums that do not intersect | 30 of 30 runs | 9 |
| Server that loses its disk and keeps its incarnation | 22 of 30 | 22 |
| No snapshot guard | 13 of 60 | 10 |
| Deposed leader does not step down | 3 of 60 | 0 |

Limitations:

- It covers only what `FlexiblePaxos.tla` models. Membership change, read
  leases, sessions, the formation of a cluster and the replacement of a
  member are not covered. The trace names a member by its address.
- It cannot reject a server that takes part while its gate is closed,
  because that server is an acceptor of the model. The invariant of the
  simulation detects it.
- The model's message set contains every message sent. An action passes if
  the messages that justify it were sent, even if the server had not yet
  received them.
- It does not cover storage writes that are in progress. A server in a
  traced run waits for every write. The model has no state for an entry
  that a server holds in memory and has not stored. The simulation and the
  Jepsen test cover such writes.

### Linearizability checking

The simulation checks linearizability with invariants that are part of
peace. [dst/peace_dst_porcupine_tests.erl](dst/peace_dst_porcupine_tests.erl)
checks the same runs with
[Porcupine](https://github.com/anishathalye/porcupine), a linearizability
checker that shares no code with peace.

1. [dst/peace_dst_history.erl](dst/peace_dst_history.erl) exports the
   client history of a run: the invocation and the result of each append
   and each read, in the order in which they happened.
2. [dst/porcupine/main.go](dst/porcupine/main.go) checks the history
   against a model of the simulated machine, which is a log of values.

Porcupine uses only what the clients observed. The invariants of the
simulation also read the state of the servers.

Results:

| Workload | Runs | Operations checked | Result |
|---|---|---|---|
| Faults, 3 servers | 40 | 2,281 | linearizable |
| Churn, 5 servers | 30 | 1,321 | linearizable |
| `{counting, 4, 2}`, 5 servers | 30 | 1,642 | linearizable |
| Read leases, clocks 6% fast | 30 | 1,136 | linearizable |
| Membership change | 30 | 1,052 | linearizable |
| Gates | 100 | 3,981 | linearizable |
| Passive servers and gates | 100 | 2,962 | linearizable |
| Formation with a machine state, on the first founder | 100 | 4,594 | linearizable |
| Formation with a machine state, with membership change | 60 | 2,153 | linearizable |

Three planted bugs confirm that Porcupine can reject a history:

| Planted bug | Result |
|---|---|
| Clients retry without a session | rejected at seed 10 |
| Acceptors ignore read leases | rejected at seed 18 |
| Quorums that do not intersect | rejected at seed 6 |

Limitations:

- The model of the machine is part of this repository. Porcupine is
  independent of peace. The model is not.
- The model fixes the order of the values from the reads and the indexes
  before Porcupine searches. The comment at the top of
  [dst/porcupine/main.go](dst/porcupine/main.go) gives the argument that
  this accepts the same histories. Without it, Porcupine did not finish
  within 60 seconds on some histories.
- An append with an unknown outcome is checked only if a read returned its
  value.
- The histories come from the simulation, not from real nodes.
- Porcupine has a time limit of 60 seconds for one history. The test
  repeats a check that does not finish with a limit of 600 seconds. One
  history of the `{counting, 4, 2}` workload needed 191 seconds. In that
  run many operations overlap, because clients submitted them before the
  first leader was elected.

### Unit tests

The tests in [test/](test/) cover:

- the protocol core as a pure function, including a replay of TLC's
  counterexample for the deposed leader
- read leases with follower clocks ten per cent fast (safe) and 25 per cent
  fast (unsafe)
- quorum arithmetic
- whole clusters on real processes
- the dets backend and the write-ahead log backend on real files, through
  closes and kills
- the write-ahead log under injected faults: failed sync, short write, full
  disk, torn write, damaged record, damaged header, damaged checkpoint and
  failed checkpoint
- the write-ahead log with a checkpoint in several chunks: writes between
  two chunks, and a stop during the checkpoint
- the transfer of a snapshot in chunks: a lost request, a repeated chunk, a
  damaged chunk and a transfer that replaces another transfer
- the session rules: values decided out of order, copies inside and outside
  the reply window, and a session table stored by an earlier version
- the session process: a full window, a gap, a change of leader, a server
  that does not answer, an eviction and a refusing leader
- the session process and a leader that answers `overloaded`: the delay
  that doubles, and the number of values sent that halves
- the mailbox limit: the oldest requests are kept in order, the newest are
  refused, and the kept values of a session are a prefix
- a server whose storage write fails: the server stops, sends nothing and is
  not restarted
- member identity: formation, a server without a configuration, a
  replacement that keeps a grid row, the replace request and its challenge,
  a request of an incarnation that no longer runs, a message for another
  incarnation, and stored state that a server refuses to start on
- versions: a message of a version outside the range of the server and a
  message without a version are dropped, the format is stored with the
  identity, data of a later format stops a server from starting, and data
  without a format is read as format 1
- the choice of a message version: the version for each pair of ranges,
  the answer of a server that drops a message, a server that answers in
  the latest common version, and a body that is not of its version
- an upgrade of a cluster of three servers on real processes through three
  ranges of message versions, one server at a time, and one server that is
  started again with the earlier range
- the extension points of member identity: an incarnation that the storage
  backend supplies, formation with known members, formation with a
  machine state and a server that joins such a cluster later, a passive
  server before and after its activation, a server whose gate closes and
  opens, and a gate that closes during a pre-vote

### Test-only configuration

The configuration keys that plant bugs, and the hook that trace validation
uses, are compiled only when `TEST` is defined. `rebar3 eunit` defines it. A
release build ignores these keys, so configuration cannot disable a
safeguard.

### Commands

```
make test       # unit tests
make bench      # benchmarks on separate Erlang nodes, about 20 minutes
make dst        # deterministic simulation, about 60 minutes
make trace      # trace validation, about 7 minutes
make porcupine  # linearizability checking with Porcupine, about 11 minutes
make tlc        # quick TLC configs, a few minutes
make ind        # inductive invariant with Apalache, about 3 minutes
make tlc-long   # TLC configs with tens of millions of states, about 2.5 hours
make tlc-soak   # the three-index membership config, about 8 hours
```

Requirements:

- `make dst` and `make trace` need eta. The `dst` profile declares it as a
  git dependency. For local development, link a checkout at
  `_checkouts/eta`.
- `make trace` and the TLC targets need Java 11 or later.
- `make porcupine` needs eta and Go 1.19 or later. The first run downloads
  Porcupine as a Go module.
- `make ind` needs Apalache, which is not included in the repository. See
  [formal/README.md](formal/README.md).

## Source layout

| File | Contents |
|---|---|
| [src/peace.erl](src/peace.erl) | Client API |
| [src/peace_core.erl](src/peace_core.erl) | The protocol, as a pure function from an event and a state to a new state and a list of effects |
| [src/peace_server.erl](src/peace_server.erl) | The `gen_server` that performs the effects: storage writes, timers and sends |
| [src/peace_writer.erl](src/peace_writer.erl) | The storage process of a server. It calls the storage backend. |
| [src/peace_transfer.erl](src/peace_transfer.erl) | The transfer of a snapshot between two servers, in chunks |
| [src/peace_session.erl](src/peace_session.erl) | The client process that submits values under one session |
| [src/peace_quorum.erl](src/peace_quorum.erl) | Quorum systems and their validation |
| [src/peace_machine.erl](src/peace_machine.erl) | The state machine behaviour |
| [src/peace_storage.erl](src/peace_storage.erl) | The storage behaviour. The three backends are in separate modules. |
| [bench/](bench/README.md) | A key-value state machine, a benchmark harness and the benchmark results |
| [formal/FlexiblePaxos.tla](formal/FlexiblePaxos.tla) | TLA+ model of the protocol. Comments in `peace_core` name the model action each clause implements. |
| [formal/FlexiblePaxosInd.tla](formal/FlexiblePaxosInd.tla) | The protocol model restated for Apalache, with the inductive invariant |
| [formal/Reconfig.tla](formal/Reconfig.tla) | TLA+ model of membership change |
| [formal/Replace.tla](formal/Replace.tla) | TLA+ model of the replacement of a member that lost its state |
| [formal/TraceFlexiblePaxos.tla](formal/TraceFlexiblePaxos.tla) | TLA+ spec used for trace validation |

## Limitations

peace is not ready for production use. [ROADMAP.md](ROADMAP.md) lists the
work required.

- **A snapshot must fit in memory more than once.** The machine state is
  one Erlang term. A snapshot is sent and stored in chunks, which bounds
  the size of one message and of one write. It does not bound the memory:
  - To send or store a snapshot, a server encodes the whole term. The
    encoding refers to the binaries of more than 64 bytes in the term and
    copies everything else.
  - To receive a snapshot, a server holds every chunk and then joins the
    chunks into one binary.
  - The write-ahead log reads the whole checkpoint when it opens.
- **A server that receives a large snapshot is busy.** The receiver joins
  and decodes the chunks in the server process. The allocation of one
  large binary stops every process of the node for a time that grows with
  the size. `term_to_binary/1` of 1000 MB stopped the node for 30 to 70 ms
  on the benchmark machine. The join was not measured separately.
- **Large snapshots were measured only with a machine state of large
  binaries.** A machine state of small terms is copied when a server
  starts to send it or to store it, and was not measured.
- **Sessions do not expire by time.** The session table is bounded by
  `max_sessions`. When it is full, the session with the oldest index is
  evicted. A session process answers the values that have no reply at that
  time with `{error, session_evicted}`. A copy of the first value of an
  evicted session that is decided later is applied again.
- **A value of a session cannot be withdrawn.** A session process submits a
  value until the value has a reply, and the later values of the session
  wait for it.
- **A session does not survive its session process.** A client that must
  continue a session after a restart assigns and stores the sequence
  numbers itself.
- **A refusal costs leader time.** At 3 times the rate that a leader can
  decide, the benchmark leader applied 34,229 puts per second, against
  about 81,000 just above that rate.
- **The mailbox limit is approximate.** A server counts every message in
  its mailbox, and reads the count once for each group of events. Messages
  that have not yet arrived at the server are not counted.
- **The throughput of one session process was not measured.** The
  benchmark measures 100 to 1,600 session processes together.
- **Every member must run the same version of the session rules.** Earlier
  versions applied a value with any higher sequence number. A cluster
  with both versions would apply different values.
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
