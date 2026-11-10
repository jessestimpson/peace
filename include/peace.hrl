-ifndef(PEACE_HRL).
-define(PEACE_HRL, true).

%% The ballot nobody has promised yet. Sorts below every real ballot.
-define(NO_BALLOT, {0, none}).

-define(DEFAULT_ELECTION_TIMEOUT_MS, 1000).
-define(DEFAULT_CALL_TIMEOUT_MS, 5000).
-define(DEFAULT_SNAPSHOT_INTERVAL, 4096).
-define(DEFAULT_MAX_SESSIONS, 10000).

-endif.
