%% -*- erlang-indent-level: 4;indent-tabs-mode: nil; fill-column: 92 -*-
%% ex: ts=4 sw=4 et
%% @author Oliver Ferrigni <oliver@chef.io>
%% @author Jean Rouge <jean@chef.io>
%% Copyright 2013-2015 Chef Software, Inc. All Rights Reserved.

-module(oc_chef_wm_named_policy).

-include("../../include/oc_chef_wm.hrl").

%% Webmachine resource callbacks
-mixin([{oc_chef_wm_base, [content_types_accepted/2,
                           content_types_provided/2,
                           finish_request/2,
                           malformed_request/2,
                           ping/2,
                           forbidden/2,
                           is_authorized/2,
                           service_available/2]}]).

-export([allowed_methods/2,
         delete_resource/2,
         from_json/2,
         resource_exists/2,
         to_json/2,
         create_path/2]).

%% chef_wm behavior callbacks
-behaviour(chef_wm).
-export([auth_info/2,
         init/1,
         init_resource_state/1,
         malformed_request_message/3,
         request_type/0,
         validate_request/3,
         conflict_message/1]).

-ifdef(TEST).
-compile([export_all]).
-endif.

init(Config) ->
    oc_chef_wm_base:init(?MODULE, Config).

init_resource_state(_Config) ->
    {ok, #policy_state{}}.

request_type() ->
    "policies".

allowed_methods(Req, State) ->
    {['GET', 'PUT', 'DELETE'], Req, State}.

create_path(Req, State) ->
    Name = wrq:path_info(policy_name, Req),
    {Name, Req, State}.

validate_request(Method, Req,
                 State = #base_state{organization_guid = OrgId})
  when Method == 'GET'; Method == 'DELETE' ->
    Name = wrq:path_info(policy_name, Req),
    Group = wrq:path_info(policy_group, Req),
    {Req, State#base_state{superuser_bypasses_checks = true,
               resource_state = #policy_state{
                     oc_chef_policy_group_revision_association = create_input_pgr_assoc_record(OrgId, Name, Group)
                     }
              }
    };
validate_request('PUT', Req, #base_state{organization_guid = OrgId,
                                              resource_state = PolicyState
                                             } = State) ->
    Name = wrq:path_info(policy_name, Req),
    Group = wrq:path_info(policy_group, Req),
    Body = wrq:req_body(Req),
    PolicyRevision = validate_json(Body, Name),
    {Req, State#base_state{
            superuser_bypasses_checks = true,
            resource_state = PolicyState#policy_state{
                oc_chef_policy_group_revision_association = create_input_pgr_assoc_record(OrgId, Name, Group),
                policy_data = PolicyRevision}}}.

create_input_pgr_assoc_record(OrgID, PolicyName, GroupName) ->
    #oc_chef_policy_group_revision_association{
        org_id = OrgID,
        policy_revision_name = PolicyName,
        policy_group_name = GroupName,
        policy = #oc_chef_policy{org_id = OrgID, name = PolicyName },
        policy_group = #oc_chef_policy_group{org_id = OrgID, name = GroupName }
        }.


validate_json(Body, NameFromReq) ->
    {ok, Policy} = oc_chef_policy_revision:parse_binary_json(Body),
    ok = validate_name(NameFromReq, Policy),
	Policy.

validate_name(NameFromReq, Policy) ->
    NameFromJson = erlang:binary_to_list(ej:get({<<"name">>}, Policy)),
    case ibrowse_lib:url_encode(NameFromJson) =:= ibrowse_lib:url_encode(NameFromReq) of
        true ->
            ok;
        false ->
            erlang:throw({mismatch, {<<"name">>, NameFromJson, NameFromReq}})
    end.

%% TODO: may be easier to just define forbidden/3 ourselves and go straight to
%% muli_auth_check (which probably needs to be exported). That should make it
%% simpler to invoke a cleanup for orphaned authz_ids if we hit an error in the
%% process.
auth_info(Req, #base_state{chef_db_context = DbContext,
                           resource_state = #policy_state{oc_chef_policy_group_revision_association = QueryRecord} = PolicyState
                           } = State) ->
    %% for GET and DELETE we want to save the serialized object in here.
    PolicyAssoc = oc_chef_policy_group_revision_association:find_policy_revision_by_orgid_name_group_name(QueryRecord, DbContext),
    StateWithResponse = case PolicyAssoc of
        #oc_chef_policy_group_revision_association{serialized_object = Object} ->
            PolicyStateWithResponseData = PolicyState#policy_state{policy_data_for_response = Object},
            State#base_state{resource_state = PolicyStateWithResponseData};
        _Any -> State
    end,

    %% TODO: need to store whether the pgra exists, so we know if we're updating
    %% TODO: it's possible that the policy and group exist but there's no assoc
    %% record. b/c we denormalize authz ids, in the case of PUT we must know
    %% what the prereq objects are so we can store their authz_ids
    PermissionsObjects = policy_permissions_objects(wrq:method(Req), PolicyAssoc, QueryRecord, DbContext),
    StateWithAuthzIDs = stash_permissions_objects_authz_ids(PermissionsObjects, StateWithResponse),
    PermissionsListOrHalt = permissions_with_actions(PermissionsObjects, Req),

    case PermissionsListOrHalt of
        {halt, 404, Message} ->
            ReqWithBody = chef_wm_util:set_json_body(Req, Message),
            {{halt, 404}, ReqWithBody, StateWithAuthzIDs#base_state{log_msg = policy_not_found}};
        PermissionsList ->
            %% TODO: code path for oc_chef_wm_base:forbidden will go to
            %% multi_auth_check when we return a list. That function doesn't support
            %% create_in_container, which we need. Also, create_in_container isn't set
            %% up to support multiple creates; we need to set different fields in our
            %% resource state for each authzid so we can tell them apart.
            {PermissionsList, Req, StateWithAuthzIDs}
    end.

stash_permissions_objects_authz_ids(Halt, State) when is_tuple(Halt) ->
    State;
stash_permissions_objects_authz_ids([], State) ->
    State;
stash_permissions_objects_authz_ids([{create_in_container, _C}|Rest], State) ->
    stash_permissions_objects_authz_ids(Rest, State);
stash_permissions_objects_authz_ids([{policy_group,AzID}|Rest], #base_state{resource_state = PolicyState} = State) ->
    UpdatedPolicyState = PolicyState#policy_state{policy_group_authz_id = AzID},
    UpdatedBaseState = State#base_state{resource_state = UpdatedPolicyState},
    stash_permissions_objects_authz_ids(Rest, UpdatedBaseState);
stash_permissions_objects_authz_ids([{policy,AzID}|Rest], #base_state{resource_state = PolicyState} = State) ->
    UpdatedPolicyState = PolicyState#policy_state{policy_authz_id = AzID},
    UpdatedBaseState = State#base_state{resource_state = UpdatedPolicyState},
    stash_permissions_objects_authz_ids(Rest, UpdatedBaseState).




permissions_with_actions(Halt, _Req) when is_tuple(Halt) ->
    Halt;
permissions_with_actions(PermissionsList, Req) when is_list(PermissionsList) ->
    [ permission_with_action_for_object(Permission, Req) || Permission <- PermissionsList].

permission_with_action_for_object({create_in_container, Container}, _Req) ->
    {create_in_container, Container};
permission_with_action_for_object({_ObjectName, AuthzID}, Req) ->
    {object, AuthzID, oc_chef_wm_base:http_method_to_authz_perm(Req)}.

%% Returns a list items to be consulted to run authz checks for the request,
%% depending on whether the policy_group and policy referenced in the request
%% exist and the HTTP method. When the prerequsite objects exist (and are
%% needed to authz the request), they are returned as 2-tuples of
%% {policy|policy_group, AuthzID}, so they can be stored in the request state
%% for later. Note that oc_chef_wm_base:multi_auth expects tuples like
%% {object, AuthzID}, use format_permissions_for_multi_auth/1 to convert.
policy_permissions_objects(_AnyMethod,
                   #oc_chef_policy_group_revision_association{
                        policy_authz_id = PolicyAuthzId, policy_group_authz_id = PolicyGroupAuthzID},
                   _QueryRecord, _DbContext) ->
    %% This means that delete will need delete on the policy and group, even
    %% though you're not deleting anything.
    [{policy, PolicyAuthzId}, {policy_group, PolicyGroupAuthzID}];
policy_permissions_objects('PUT', not_found, QueryRecord, DbContext) ->
    PrereqObjects = oc_chef_policy_group_revision_association:fetch_prereq_objects(QueryRecord, DbContext),
    prereq_objects_to_permissions(PrereqObjects);
policy_permissions_objects(_GetOrDelete, not_found,
                   #oc_chef_policy_group_revision_association{
                        policy_revision_name = PolicyName,
                        policy_group_name = PolicyGroupName},
                   _DbContext) ->
    Message = chef_wm_util:error_message_envelope(
                iolist_to_binary(["Cannot load policy ", PolicyName, " in policy group ", PolicyGroupName])),
    {halt, 404, Message}.

prereq_objects_to_permissions(PrereqObjects) ->
    prereq_objects_to_permissions(PrereqObjects, []).

prereq_objects_to_permissions([], PermissionsList) ->
    PermissionsList;
prereq_objects_to_permissions([PrereqObject|Rest], PermissionsList) ->
    RequiredPermission = prereq_object_permission(PrereqObject),
    UpdatedPermissionList = [RequiredPermission | PermissionsList ],
    prereq_objects_to_permissions(Rest, UpdatedPermissionList).

prereq_object_permission({policy, not_found}) ->
    {create_in_container, policies};
prereq_object_permission({policy, #oc_chef_policy{authz_id = AuthzID}}) ->
    {policy, AuthzID};
prereq_object_permission({policy_group, not_found}) ->
    {create_in_container, policy_groups};
prereq_object_permission({policy_group, #oc_chef_policy_group{authz_id = AuthzID}}) ->
    {policy_group, AuthzID}.

resource_exists(Req, State) ->
    {true, Req, State}.

to_json(Req, #base_state{resource_state = #policy_state{policy_data_for_response = PolicyData}} = State) ->
    {jiffy:encode(PolicyData), Req, State}.

%% TODO: needs to handle the update case.
from_json(Req, #base_state{organization_guid = OrgID,
                           chef_db_context = DbContext,
                           requestor_id = RequestorId,
                           resource_state = #policy_state{policy_data = PolicyData,
                                                          policy_authz_id = PolicyAuthzID,
                                                          policy_group_authz_id = PolicyGroupAuthzID
                                                         }} = State) ->

    PolicyName = iolist_to_binary(wrq:path_info(policy_name, Req)),
    PolicyGroupName = iolist_to_binary(wrq:path_info(policy_group, Req)),
    CreateRecord =  oc_chef_policy_group_revision_association:new_record(OrgID,
                                                                         PolicyName,
                                                                         PolicyAuthzID,
                                                                         PolicyGroupName,
                                                                         PolicyGroupAuthzID,
                                                                         PolicyData),

    Result = oc_chef_policy_group_revision_association:insert_association(CreateRecord, DbContext, RequestorId),
    case Result of
        ok ->
            %% Not strictly true...
            LogMsg = {created, PolicyName},
            Uri = oc_chef_wm_routes:route(policy, Req, [{name, PolicyName}]),
            ReqWithURI = chef_wm_util:set_uri_of_created_resource(Uri, Req),
            ReqWithBody = chef_wm_util:set_json_body(ReqWithURI, PolicyData),
            {true, ReqWithBody, State#base_state{log_msg = LogMsg}}
        %% TODO: {conflict, _} ->
    end.


conflict_message(Name) ->
    {[{<<"error">>, list_to_binary("Policy already exists " ++ Name)}]}.


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% TODO!!! set back to real functionality
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

delete_resource(Req, State) ->
    {true, Req, State}.

%%%% delete_resource(Req, #base_state{
%%%%                         organization_name = OrgName,
%%%%                         chef_db_context = DbContext,
%%%%                         requestor_id = RequestorId,
%%%%                         resource_state = #policy_state{
%%%%                                             oc_chef_policy = InputPolicy }
%%%%                        } = State) ->
%%%%     Group = wrq:path_info(policy_group, Req),
%%%%     Policy = InputPolicy#oc_chef_policy{
%%%%                last_updated_by = RequestorId,
%%%%                policy_group = Group
%%%%               },
%%%%     ok = oc_chef_wm_base:delete_object(DbContext, Policy, RequestorId),
%%%%     Ejson = oc_chef_policy:assemble_policy_ejson(Policy, OrgName),
%%%%     {true, chef_wm_util:set_json_body(Req, Ejson), State}.

malformed_request_message(Any, _Req, _state) ->
    error({unexpected_malformed_request_message, Any}).
