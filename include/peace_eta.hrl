%% The opt-in to deterministic simulation testing with eta.
%%
%% Modules that are part of the system under simulation include this. Under
%% the `dst` profile (which defines DST) it brings in eta's parse transform,
%% which points timers, clock reads, spawns, sends and `rand` at eta's virtual
%% counterparts. In every other build it contributes nothing, and eta does not
%% have to be resolvable.
-ifndef(PEACE_ETA_HRL).
-define(PEACE_ETA_HRL, true).

-ifdef(DST).
-include_lib("eta/include/eta.hrl").
-else.
%% Neither evaluates its argument. Anything logged must be free of side
%% effects, and a variable used only here must be underscore-prefixed.
-define(ETA_LABEL(Label), ok).
-define(ETA_LOG(Event), 0).
-endif.

-endif.
