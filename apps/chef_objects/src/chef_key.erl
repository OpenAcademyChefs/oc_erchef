%% -*- erlang-indent-level: 4;indent-tabs-mode: nil -*-
%% ex: ts=4 sw=4 et
%% @author Tyler Cloke <tyler@chef.io>
%% @author Marc Paradise <marc@chef.io>
%% Copyright 2015 Chef Software, Inc. All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%

-module(chef_key).

-behaviour(chef_object).

-export([authz_id/1,
         is_indexed/0,
         ejson_for_indexing/2,
         update_from_ejson/2,
         set_created/2,
         fields_for_update/1,
         fields_for_fetch/1,
         ejson_from_list/2,
         ejson_from_key/1,
         record_fields/0,
         list/2,
         set_updated/2,
         new_record/3,
         name/1,
         id/1,
         org_id/1,
         type_name/1,
         delete/2,
         parse_binary_json/2,
         flatten/1
        ]).

%% database named queries
-export([
         create_query/0,
         update_query/0,
         delete_query/0,
         find_query/0,
         bulk_get_query/0,
         list_query/0
        ]).

-include_lib("mixer/include/mixer.hrl").
-mixin([{chef_object,[
                     {default_fetch/2, fetch},
                     {default_update/2, update}
                    ]}]).

-ifdef(TEST).
-compile(export_all).
-endif.

-include("../../include/chef_types.hrl").

authz_id(#chef_key{}) ->
    undefined.

is_indexed() ->
    false.

ejson_for_indexing(#chef_key{}, _) ->
    error(not_indexed).

-spec update_from_ejson(#chef_key{}, ejson_term()) -> #chef_key{}.
update_from_ejson(#chef_key{key_name = OldName, key_version = OldPubKeyVersion,
                            public_key = OldPubKey, expires_at = OldExpirationDate} = Key, EJ) ->
  {NewVersion, NewPubKey} = case ej:get({<<"public_key">>}, EJ) of
                              undefined ->
                                {OldPubKeyVersion, OldPubKey};
                              PK ->
                                {safe_key_version(PK), PK}
                            end,
  NewExpiration = case ej:get({<<"expiration_date">>}, EJ) of
                    undefined ->
                      OldExpirationDate;
                    Exp ->
                      chef_object_base:parse_date(Exp)
                  end,
  Key#chef_key{key_name = ej:get({<<"name">>}, EJ, OldName),
               key_version = NewVersion,
               public_key = NewPubKey,
               expires_at = NewExpiration,
               % We need to preserve the old name for any update to be applied
               old_name = OldName}.

set_created(#chef_key{} = Key, ActorId) ->
    Now = chef_object_base:sql_date(now),
    Key#chef_key{created_at = Now, updated_at = Now, last_updated_by = ActorId}.

set_updated(#chef_key{} = Key, ActorId) ->
    Now = chef_object_base:sql_date(now),
    Key#chef_key{updated_at = Now, last_updated_by = ActorId}.

fields_for_update(#chef_key{id = Id, key_name = NewName, old_name = OldName,
                            key_version = PubKeyVersion, public_key = PublicKey,
                            expires_at = ExpirationDate, updated_at = UpdatedAt,
                            last_updated_by = ActorId}) ->
  [Id, OldName, NewName, PublicKey, PubKeyVersion, ExpirationDate, ActorId, UpdatedAt].


fields_for_fetch(#chef_key{id = Id, key_name = KeyName}) ->
  [Id, KeyName].

record_fields() ->
  record_info(fields, chef_key).

ejson_from_list(KeysList, URIDecorator) ->
  [ {[{<<"uri">>, URIDecorator(Name)},
      {<<"name">>, Name},
      {<<"expired">>, Expired}]} || [Name, Expired] <- KeysList ].

ejson_from_key(#chef_key{key_name = Name, public_key = PublicKey, expires_at = UnparsedExpirationDate}) ->
    ExpirationDate = case UnparsedExpirationDate of
        ?INFINITY_TIMESTAMP -> <<"infinity">>;
        _ -> list_to_binary(ec_date:format("Y-m-dTH:i:sZ", UnparsedExpirationDate))
    end,
    {[{<<"name">>, Name},
      {<<"public_key">>, PublicKey},
      {<<"expiration_date">>, ExpirationDate}]}.

list(#chef_key{id = Id}, CallbackFun) when is_binary(Id) ->
    CallbackFun({list_query(), [Id], rows}).

find_query() ->
    find_key_by_id_and_name.

new_record(_OrgId, _AuthzId, {Id, KeyData}) ->
    PubKey = ej:get({<<"public_key">>}, KeyData),
    %% return a more useful error if key_version fails
    PubKeyVersion = safe_key_version(PubKey),
    Expires = chef_object_base:parse_date(ej:get({<<"expiration_date">>}, KeyData)),
    #chef_key{ id = Id, key_name = ej:get({<<"name">>}, KeyData),
               public_key = PubKey, key_version = PubKeyVersion,
               expires_at = Expires}.

safe_key_version(PublicKey) ->
    try chef_object_base:key_version(PublicKey) of
        Result -> Result
    catch
        _:_ -> throw(invalid_public_key)
    end.

name(#chef_key{key_name = KeyName}) ->
    KeyName.

id(#chef_key{id = Id}) ->
    Id.

org_id(#chef_key{}) ->
    undefined.

type_name(#chef_key{}) ->
    key.

list_query() ->
    list_keys_for_actor.

create_query() ->
    insert_key_for_actor.

parse_binary_json(Bin, update) ->
  EJ = chef_json:decode(Bin),
  % At least one field must be present:
  OneOf = [<<"expiration_date">>, <<"public_key">>, <<"name">>],
  case lists:filter(fun(X) -> X =/= undefined end, [ej:get({Field}, EJ) || Field <- OneOf]) of
      [] ->
          throw(missing_required_field);
      _ ->
          chef_object_base:validate_ejson(EJ, name_and_public_key_validation_spec(opt)),
          validate_expiration_date(opt, EJ)
  end;
parse_binary_json(Bin, create) ->
  EJ = chef_json:decode(Bin),
  chef_object_base:validate_ejson(EJ, name_and_public_key_validation_spec(req)),
  validate_expiration_date(req, EJ).

validate_expiration_date(Required, EJ) ->
  case {Required, ej:get({<<"expiration_date">>}, EJ)} of
    {opt, undefined} -> EJ;
    _ -> chef_object_base:validate_date_field(EJ, <<"expiration_date">>)
  end.

name_and_public_key_validation_spec(Req) ->
  {[ chef_object_base:public_key_spec(Req),
     {{Req, <<"name">>}, {string_match, chef_regex:regex_for(key_name)}} ]}.

update_query() ->
  update_key_by_id_and_name.

delete_query() ->
  delete_key_by_id_and_name.

delete(#chef_key{id = Id, key_name = Name}, CallbackFun) ->
    CallbackFun({delete_query(), [Id, Name]}).

flatten(#chef_key{} = Key) ->
    %% Drop off the first and last fielFirst is record name, and
    %% last is one that isn't in the DB (for internal use)
    [_|Tail] = tuple_to_list(Key),
    lists:reverse(tl(lists:reverse(Tail))).

bulk_get_query() ->
    error(unsupported).

