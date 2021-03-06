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

-module(oc_chef_policy_group).

-include("../../include/oc_chef_types.hrl").
-include_lib("mixer/include/mixer.hrl").

-behaviour(chef_object).

-mixin([{chef_object,[{default_fetch/2, fetch}]}]).

-export([
         parse_binary_json/1,
         flatten/1,
         delete/2,
         create_record/3
        ]).

%% chef_object behaviour callbacks
-export([
         id/1,
         authz_id/1,
         bulk_get_query/0,
         create_query/0,
         delete_query/0,
         ejson_for_indexing/2,
         fields_for_fetch/1,
         fields_for_update/1,
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
         update_from_ejson/2,
         update_query/0,
         update/2
        ]).

-define(VALIDATION_CONSTRAINTS,
        {[{<<"name">>, {string_match, chef_regex:regex_for(policy_file_name)}}]}).

id(#oc_chef_policy_group{id = Id}) ->
    Id.

name(#oc_chef_policy_group{name = Name}) ->
    Name.

org_id(#oc_chef_policy_group{org_id = OrgId}) ->
    OrgId.

type_name(#oc_chef_policy_group{}) ->
    policy.

authz_id(#oc_chef_policy_group{authz_id = AuthzId}) ->
    AuthzId.


create_query() ->
    insert_policy_group.

update_query() ->
    update_policy_group_by_id.

delete_query() ->
    delete_policy_group_by_id.

find_query() ->
    find_policy_group_by_orgid_name.

list_query() ->
    list_policy_groups_for_org.

bulk_get_query() ->
    %% TODO: do we need this?
    ok.

new_record(OrgId, AuthzId, Name) ->
    Id = chef_object_base:make_org_prefix_id(OrgId, Name),
    #oc_chef_policy_group{
        id = Id,
        authz_id = AuthzId,
        org_id = OrgId,
        name = Name}.

create_record(OrgId, Name, RequestingActorId) ->
    Policy = #oc_chef_policy_group{
                           org_id = OrgId,
                           name = Name},
    set_created(Policy, RequestingActorId).

set_created(#oc_chef_policy_group{} = Object, ActorId) ->
    Object#oc_chef_policy_group{last_updated_by = ActorId}.

set_updated(#oc_chef_policy_group{} = Object, ActorId) ->
    Object#oc_chef_policy_group{last_updated_by = ActorId}.

is_indexed() ->
    false.

ejson_for_indexing(#oc_chef_policy_group{}, _EjsonTerm) ->
   {[]}.

update_from_ejson(#oc_chef_policy_group{} = Policy, PolicyGroupData) ->
    Name = ej:get({<<"name">>}, PolicyGroupData, name(Policy)),
    Policy#oc_chef_policy_group{name = Name}.

fields_for_update(#oc_chef_policy_group{
                     id = Id,
                     last_updated_by = LastUpdatedBy
                                 } = PolicyGroup) ->
    [LastUpdatedBy, name(PolicyGroup), Id].


fields_for_fetch(#oc_chef_policy_group{org_id = OrgId} = PolicyGroup) ->
    [name(PolicyGroup), OrgId].

record_fields() ->
    record_info(fields, oc_chef_policy_group).

list(#oc_chef_policy_group{org_id = OrgId}, CallbackFun) ->
    CallbackFun({list_query(), [OrgId], rows}).

update(#oc_chef_policy_group{
                      org_id = _OrgId,
                      authz_id = _PolicyGroupAuthzId,
                      last_updated_by = _AuthzId
                     } = Record, CallbackFun) ->
	chef_object:default_update(Record, CallbackFun).


parse_binary_json(Bin) ->
    PolicyGroup = chef_json:decode_body(Bin),
    case ej:valid(?VALIDATION_CONSTRAINTS, PolicyGroup) of
        ok ->
			{ok, PolicyGroup};
        Bad ->
            throw(Bad)
    end.

flatten(#oc_chef_policy_group{
          id = Id,
          authz_id = AuthzId,
          org_id = OrgId,
          name = Name,
          last_updated_by = LastUpdatedBy}) ->
    [Id, AuthzId, OrgId, Name, LastUpdatedBy].


delete(ObjectRec = #oc_chef_policy_group{
                      org_id = OrgId,
                      last_updated_by = _AuthzId,
                      authz_id = _PolicyAuthzId
                     }, CallbackFun) ->
    CallbackFun({delete_query(), [name(ObjectRec), OrgId]}).

