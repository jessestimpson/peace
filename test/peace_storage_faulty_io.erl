%% A replacement for the `file' functions that `peace_storage_wal' uses to
%% write. A test arms one fault in the process dictionary with `arm/1'. The
%% fault stays armed until `disarm/0'.
%%
%% The faults are:
%%   - `{sync, Reason}': every sync fails.
%%   - `{write, N, Reason}': every write stores only the first `N' bytes
%%     and fails. With `N' = 0 this is a full disk. With `N' > 0 this is a
%%     short write.
%%   - `{rename, Reason}': every rename fails.
-module(peace_storage_faulty_io).

-export([arm/1, disarm/0]).
-export([open/2, write/2, datasync/1, rename/2]).

arm(Fault) ->
    put(?MODULE, Fault),
    ok.

disarm() ->
    erase(?MODULE),
    ok.

open(File, Modes) ->
    file:open(File, Modes).

write(Fd, Data) ->
    case get(?MODULE) of
        {write, N, Reason} ->
            <<Prefix:N/binary, _/binary>> = iolist_to_binary(Data),
            ok = file:write(Fd, Prefix),
            {error, Reason};
        _ ->
            file:write(Fd, Data)
    end.

datasync(Fd) ->
    case get(?MODULE) of
        {sync, Reason} -> {error, Reason};
        _ -> file:datasync(Fd)
    end.

rename(From, To) ->
    case get(?MODULE) of
        {rename, Reason} -> {error, Reason};
        _ -> file:rename(From, To)
    end.
