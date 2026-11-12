-ifndef(PEACE_HRL).
-define(PEACE_HRL, true).

%% The placeholder epoch that means no epoch has been promised yet. This
%% epoch sorts below every real epoch.
-define(NO_EPOCH, {0, none}).

-define(DEFAULT_ELECTION_TIMEOUT_MS, 1000).
-define(DEFAULT_CALL_TIMEOUT_MS, 5000).
-define(DEFAULT_SNAPSHOT_INTERVAL, 4096).
-define(DEFAULT_MAX_SESSIONS, 10000).

%% Planted bugs. A test build can switch off a safeguard, to show that the
%% check that depends on the safeguard can fail. Every other build does not
%% read the key, so the safeguard cannot be switched off.
-ifdef(TEST).
-define(PLANTED(Key, Config), (maps:get(Key, Config, false) =:= true)).
-else.
-define(PLANTED(Key, Config), false).
-endif.

-endif.
