%% -*- erlang-indent-level: 4;indent-tabs-mode: nil; fill-column: 92 -*-
%% ex: ts=4 sw=4 et
%% @author Daniel DeLeo <dan@chef.io>
%% Copyright 2012-2015 Opscode, Inc. All Rights Reserved.
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

-module(oc_chef_policy_revision).

-include("../../include/oc_chef_types.hrl").
-include_lib("mixer/include/mixer.hrl").

-behaviour(chef_object).

-mixin([{chef_object,[{default_fetch/2, fetch}]}]).

-export([
         parse_binary_json/1,
         flatten/1,
         delete/2,
         create_record/3,
         decompress_record/1
        ]).

%% chef_object behaviour callbacks
-export([
         id/1,
         bulk_get_query/0,
         create_query/0,
         delete_query/0,
         ejson_for_indexing/2,
         fields_for_fetch/1,
         find_query/0,
         is_indexed/0,
         list/2,
         list_query/0,
         name/1,
         new_record/3,
         org_id/1,
         record_fields/0,
         set_created/2,
         set_updated/2,
         type_name/1,

         %% Unused stubs:

         authz_id/1,
         fields_for_update/1,
         update/2,
         update_from_ejson/2,
         update_query/0
        ]).

-define(VALIDATION_CONSTRAINTS,
        {[{<<"revision_id">>, {string_match, chef_regex:regex_for(policy_file_revision_id)}},

          {<<"name">>, {string_match, chef_regex:regex_for(policy_file_name)}},

          {<<"run_list">>, chef_json_validator:policy_run_list_spec()},

          {<<"cookbook_locks">>,
           {object_map, {
              {keys, {string_match, chef_regex:regex_for(cookbook_name)}},
              {values,
               %% apparently there's no cleaner way to do that with `ej:valid' (??)
               {fun_match, {fun valid_cookbook_lock/1, object,
                            <<"Invalid cookbook_lock constraint">>}}}}}}
         ]}).

-define(COOKBOOK_LOCK_VAIDATION_CONSTRAINTS,
        {[{<<"identifier">>,
           {string_match, chef_regex:regex_for(policy_identifier)}},

          {{opt, <<"dotted_decimal_identifier">>},
           valid_cookbook_version_spec(<<"Field 'dotted_decimal_identifier' is not a valid version">>)},

          {<<"version">>,
           valid_cookbook_version_spec(<<"Field 'version' is not a valid version">>)}]}).

valid_cookbook_version_spec(Message) ->
    {fun_match, {fun chef_cookbook_version:valid_cookbook_constraint/1, string,
                 Message}}.


valid_cookbook_lock(CookbookLockJson) ->
    case ej:valid(?COOKBOOK_LOCK_VAIDATION_CONSTRAINTS, CookbookLockJson) of
        ok -> ok;
        Bad -> throw(Bad)
    end.

%%%%%%%%%%%%%%%%%%%%
%% Unused chef_object behavior callbacks
%%
%% Revisions cannot be updated and have no authz_id of their own.
%%%%%%%%%%%%%%%%%%%%


authz_id(#oc_chef_policy_revision{}) ->
    error(not_implemented).

fields_for_update(#oc_chef_policy_revision{}) ->
    error(not_implemented).

update(#oc_chef_policy_revision{}, _CallbackFun) ->
    error(not_implemented).

update_from_ejson(#oc_chef_policy_revision{}, _Data) ->
    error(not_implemented).

update_query() ->
    error(not_implemented).

id(#oc_chef_policy_revision{id = Id}) ->
    Id.

name(#oc_chef_policy_revision{name = Name}) ->
    Name.

org_id(#oc_chef_policy_revision{org_id = OrgId}) ->
    OrgId.

type_name(#oc_chef_policy_revision{}) ->
    policy.

create_query() ->
    insert_policy_revision.

delete_query() ->
    delete_policy_revision_by_id.

find_query() ->
    find_policy_revision_by_orgid_name_revision_id.

list_query() ->
    list_policy_revisions_by_orgid_name.

bulk_get_query() ->
    %% TODO: do we need this?
    ok.

new_record(OrgId, PolicyAuthzID, PolicyData) ->
    Name = ej:get({<<"name">>}, PolicyData),
    RevisionId = ej:get({<<"revision_id">>}, PolicyData),
    Id = chef_object_base:make_org_prefix_id(OrgId, <<Name/binary, RevisionId/binary>>),
    #oc_chef_policy_revision{
        id = Id,
        org_id = OrgId,
        policy_authz_id = PolicyAuthzID,
        name = Name,
        revision_id = RevisionId,
        serialized_object = ej:delete({<<"policy_group">>}, PolicyData)}.

create_record(OrgId, Name, RequestingActorId) ->
    Policy = #oc_chef_policy_revision{
                           org_id = OrgId,
                           name = Name},
    set_created(Policy, RequestingActorId).

set_created(#oc_chef_policy_revision{} = Object, ActorId) ->
    Object#oc_chef_policy_revision{last_updated_by = ActorId}.

set_updated(#oc_chef_policy_revision{} = Object, ActorId) ->
    Object#oc_chef_policy_revision{last_updated_by = ActorId}.

is_indexed() ->
    false.

ejson_for_indexing(#oc_chef_policy_revision{}, _EjsonTerm) ->
   {[]}.

fields_for_fetch(#oc_chef_policy_revision{org_id = OrgId, name = Name, revision_id = RevisionId}) ->
    [Name, OrgId, RevisionId].

record_fields() ->
    record_info(fields, oc_chef_policy_revision).

list(#oc_chef_policy_revision{org_id = OrgId, name = Name}, CallbackFun) ->
    CallbackFun({list_query(), [Name, OrgId], rows}).

parse_binary_json(Bin) ->
    PolicyRevision = chef_json:decode_body(Bin),
    case ej:valid(?VALIDATION_CONSTRAINTS, PolicyRevision) of
        ok ->
			{ok, PolicyRevision};
        Bad ->
            throw(Bad)
    end.

flatten(#oc_chef_policy_revision{
                id = Id,
                org_id = OrgId,
                revision_id = RevisionId,
                name = Name,
                policy_authz_id = PolicyAuthzID,
                last_updated_by = LastUpdatedBy,
                serialized_object = SerializedObject}) ->
	Compressed = chef_db_compression:compress(oc_chef_policy_revision, jiffy:encode(SerializedObject)),
    [Id, OrgId, RevisionId, Name, PolicyAuthzID, Compressed, LastUpdatedBy].


decompress_record(#oc_chef_policy_revision{
                serialized_object = CompressedSerializedObject
                } = Revision) ->
    SerializedObject = jiffy:decode(chef_db_compression:decompress(CompressedSerializedObject)),
    Revision#oc_chef_policy_revision{serialized_object = SerializedObject}.

delete(ObjectRec = #oc_chef_policy_revision{
                      org_id = OrgId,
                      last_updated_by = _AuthzId
                     }, CallbackFun) ->
    CallbackFun({delete_query(), [name(ObjectRec), OrgId]}).
