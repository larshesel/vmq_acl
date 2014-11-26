%% Copyright 2014 Erlio GmbH Basel Switzerland (http://erl.io)
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.

-module(vmq_acl).

-export([init/0,
         load_from_file/1,
         load_from_list/1,
         check/4]).

-export([auth_on_subscribe/3,
         auth_on_publish/6]).

-import(emqtt_topic, [words/1, match/2]).

-define(INIT_ACL, {[],[],[],[],[],[]}).
-define(TABLES, [
                 vmq_acl_read_pattern,
                 vmq_acl_write_pattern,
                 vmq_acl_read_all,
                 vmq_acl_write_all,
                 vmq_acl_read_user,
                 vmq_acl_write_user
                ]).
-define(TABLE_OPTS, [public, named_table, {read_concurrency, true}]).

init() ->
    lists:foreach(fun(T) ->
                          case lists:member(T, ets:all()) of
                              true -> ok;
                              false ->
                                  ets:new(T, ?TABLE_OPTS)
                          end
                  end, ?TABLES).

auth_on_subscribe(_, _, []) -> ok;
auth_on_subscribe(User, ClientId, [{Topic, _Qos}|Rest]) ->
    case check(read, Topic, User, ClientId) of
        true ->
            auth_on_subscribe(User, ClientId, Rest);
        false ->
            next
    end.

auth_on_publish(User, ClientId, _, Topic, _, _) ->
    case check(write, Topic, User, ClientId) of
        true ->
            ok;
        false ->
            next
    end.

load_from_file(File) ->
    case file:open(File, [read, binary]) of
        {ok, Fd} ->
            F = fun(FF, read) -> {FF, rl(Fd)};
                   (_, close) -> file:close(Fd)
                end,
            age_entries(),
            parse_acl_line(F(F,read), all),
            del_aged_entries();
        {error, Reason} ->
            error_logger:error_msg("can't load acl file ~p due to ~p", [File, Reason]),
            ok
    end.

load_from_list(List) ->
    put(vmq_acl_list, List),
    F = fun(FF, read) ->
                case get(vmq_acl_list) of
                    [I|Rest] ->
                        put(vmq_acl_list, Rest),
                        {FF, I};
                    [] ->
                        {FF, eof}
                end;
           (_, close) ->
                put(vmq_acl_list, undefined),
                ok
        end,
    age_entries(),
    parse_acl_line(F(F, read), all),
    del_aged_entries().


parse_acl_line({F, <<"topic read ", Topic/binary>>}, User) ->
    in(read, User, Topic),
    parse_acl_line(F(F,read), User);
parse_acl_line({F, <<"topic write ", Topic/binary>>}, User) ->
    in(write, User, Topic),
    parse_acl_line(F(F,read), User);
parse_acl_line({F, <<"topic ", Topic/binary>>}, User) ->
    in(read, User, Topic),
    in(write, User, Topic),
    parse_acl_line(F(F,read), User);
parse_acl_line({F, <<"user ", User/binary>>}, _) ->
    SUser = string:substr(binary_to_list(User), 1, byte_size(User) -1),
    parse_acl_line(F(F,read), SUser);
parse_acl_line({F, <<"pattern read ", Topic/binary>>}, User) ->
    in(read, pattern, Topic),
    parse_acl_line(F(F,read), User);
parse_acl_line({F, <<"pattern write ", Topic/binary>>}, User) ->
    in(write, pattern, Topic),
    parse_acl_line(F(F,read), User);
parse_acl_line({F, <<"pattern ", Topic/binary>>}, User) ->
    in(read, pattern, Topic),
    in(write, pattern, Topic),
    parse_acl_line(F(F,read), User);
parse_acl_line({F, <<"\n">>}, User) ->
    parse_acl_line(F(F,read), User);
parse_acl_line({F, eof}, _User) ->
    F(F,close),
    ok.

check(Type, Topic, User, ClientId) ->
    WTopic = words(Topic),
    case check_all_acl(Type, WTopic) of
        true -> true;
        false when User == all -> false;
        false ->
            case check_user_acl(Type, User, WTopic) of
                true -> true;
                false -> check_pattern_acl(Type, WTopic, User, ClientId)
            end
    end.

check_all_acl(Type, TIn) ->
    {Tbl, _} = t(Type, all, TIn),
    iterate_until_true(Tbl, fun(T) -> match(TIn, words(T)) end).

check_user_acl(Type, User, TIn) ->
    {Tbl, _} = t(Type, User, TIn),
    iterate_until_true(ets:match(Tbl, {{User, '$1'}, '_'}),
                      fun([T]) -> match(TIn, words(T)) end).

check_pattern_acl(Type, TIn, User, ClientId) ->
    {Tbl, _} = t(Type, pattern, TIn),
    iterate_until_true(Tbl, fun(P) ->
                                    T = topic(User, ClientId, P),
                                    match(TIn, words(T))
                            end).

topic(User, ClientId, Topic) ->
    subst("%u", User, subst("%c", ClientId, Topic)).

subst(Pat, Subs, Topic) ->
    subst(string:str(Topic, Pat) > 0, Pat, Subs, Topic).

subst(true, Pat, Subs, Topic) ->
    re:replace(Topic, Pat, Subs, [{return, list}]);
subst(false, _, _, Topic) -> Topic.

in(Type, User, Topic) when is_binary(Topic) ->
    STopic = string:substr(binary_to_list(Topic), 1, byte_size(Topic) -1),
    in(Type, User, STopic);
in(Type, User, Topic) ->
    {Tbl, Obj} = t(Type, User, Topic),
    ets:insert(Tbl, Obj).

t(read, all, Topic) -> {vmq_acl_read_all, {Topic, 1}};
t(write, all, Topic) ->  {vmq_acl_write_all, {Topic, 1}};
t(read, pattern, Topic) ->  {vmq_acl_read_pattern, {Topic, 1}};
t(write, pattern, Topic) -> {vmq_acl_write_pattern, {Topic, 1}};
t(read, User, Topic) -> {vmq_acl_read_user, {{User, Topic}, 1}};
t(write, User, Topic) -> {vmq_acl_write_user, {{User, Topic}, 1}}.

iterate_until_true(T, Fun) when is_atom(T) ->
    iterate_ets_until_true(T, ets:first(T), Fun);
iterate_until_true(T, Fun) when is_list(T) ->
    iterate_list_until_true(T, Fun).

iterate_ets_until_true(_, '$end_of_table', _) -> false;
iterate_ets_until_true(Table, K, Fun) ->
    case Fun(K) of
        true -> true;
        false ->
            iterate_ets_until_true(Table, ets:next(Table, K), Fun)
    end.

iterate_list_until_true([], _) -> false;
iterate_list_until_true([T|Rest], Fun) ->
    case Fun(T) of
        true -> true;
        false ->
            iterate_list_until_true(Rest, Fun)
    end.

rl({ok, Data}) -> Data;
rl({error, Reason}) -> exit(Reason);
rl(eof) -> eof;
rl(Fd) ->
    rl(file:read_line(Fd)).


age_entries() ->
    lists:foreach(fun age_entries/1, ?TABLES).
age_entries(T) ->
    iterate(T, fun(K) -> ets:update_element(T, K, {2,2}) end).

del_aged_entries() ->
    lists:foreach(fun del_aged_entries/1, ?TABLES).
del_aged_entries(T) ->
    ets:match_delete(T, {'_', 2}).

iterate(T, Fun) ->
    iterate(T, Fun, ets:first(T)).
iterate(_, _, '$end_of_table') -> ok;
iterate(T, Fun, K) ->
    Fun(K),
    iterate(T, Fun, ets:next(T, K)).
