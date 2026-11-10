-ifndef(PEACE_HRL).
-define(PEACE_HRL, true).

%% The epoch nobody has promised yet. Sorts below every real epoch.
-define(NO_EPOCH, {0, none}).

-define(DEFAULT_ELECTION_TIMEOUT_MS, 1000).
-define(DEFAULT_CALL_TIMEOUT_MS, 5000).
-define(DEFAULT_SNAPSHOT_INTERVAL, 4096).
-define(DEFAULT_MAX_SESSIONS, 10000).

%% Planted bugs. A test build can switch a safeguard off, to show that the
%% check which depends on it can fail. In any other build the key is not read
%% and the safeguard cannot be switched off.
-ifdef(TEST).
-define(PLANTED(Key, Config), (maps:get(Key, Config, false) =:= true)).
-else.
-define(PLANTED(Key, Config), false).
-endif.

-endif.
