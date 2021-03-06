(** Copyright (c) 2016-present, Facebook, Inc.

    This source code is licensed under the MIT license found in the
    LICENSE file in the root directory of this source tree. *)

open Core

open Analysis
open Ast
open Expression
open Pyre
open Statement
open Domains
open AccessPath


module type FixpointState = sig
  type t = { taint: BackwardState.t }
  [@@deriving show]

  include Fixpoint.State with type t := t

  val create: unit -> t
end


let initial_taint define =
  match List.rev define.Define.name with
  | Access.Identifier name :: _ when Identifier.show name = "__init__" ->
      begin
        (* Constructor. Make self the return value *)
        match define.Define.parameters with
        | { Node.value = { Parameter.name; _ }; _ } :: _ ->
            let result_taint = BackwardTaint.singleton Sinks.LocalReturn in
            BackwardState.assign
              ~root:(Root.Variable name)
              ~path:[]
              (BackwardState.create_leaf result_taint)
              BackwardState.empty
        | _ ->
            BackwardState.empty
      end
  | _ ->
      let result_taint = BackwardTaint.singleton Sinks.LocalReturn in
      BackwardState.assign
        ~root:Root.LocalResult
        ~path:[]
        (BackwardState.create_leaf result_taint)
        BackwardState.empty


module type FUNCTION_CONTEXT = sig
  val definition: Define.t Node.t
  val environment: (module Environment.Handler)
end


module AnalysisInstance(FunctionContext: FUNCTION_CONTEXT) = struct

  module rec FixpointState : FixpointState = struct

    type t = { taint: BackwardState.t }
    [@@deriving show]


    let create () =
      { taint = BackwardState.empty }


    let less_or_equal ~left:{ taint = left; _ } ~right:{ taint = right; _ } =
      BackwardState.less_or_equal ~left ~right


    let join { taint = left } { taint = right; _ } =
      let taint = BackwardState.join left right in
      { taint }


    let widen ~previous:{ taint = previous; _ } ~next:{ taint = next; _ } ~iteration =
      let taint = BackwardState.widen ~iteration ~previous ~next in
      { taint }


    let get_taint access_path { taint; _ } =
      match access_path with
      | None ->
          BackwardState.empty_tree
      | Some { root; path } ->
          BackwardState.read_access_path ~root ~path taint


    let store_weak_taint ~root ~path taint { taint = state_taint } =
      { taint = BackwardState.assign_weak ~root ~path taint state_taint }


    let store_weak_taint_option access_path taint state =
      match access_path with
      | None -> state
      | Some (root, path) -> store_weak_taint ~root ~path taint state


    let rec analyze_argument ~resolution taint { Argument.value = argument; _ } state =
      analyze_expression ~resolution taint argument state


    and apply_call_targets ~resolution location arguments state call_taint call_targets =
      let analyze_call_target call_target =
        let is_obscure, taint_model =
          match Model.get_callsite_model ~resolution ~call_target ~arguments with
          | None -> true, None
          | Some model ->
              model.is_obscure, Interprocedural.Result.get_model TaintResult.kind model
        in
        match taint_model with
        | Some { backward; _ } when not is_obscure ->
            let collapsed_call_taint = BackwardState.collapse call_taint in
            let sink_roots = BackwardState.keys backward.sink_taint in
            let sink_argument_matches = AccessPath.match_actuals_to_formals arguments sink_roots in
            let tito_roots = BackwardState.keys backward.taint_in_taint_out in
            let tito_argument_matches = AccessPath.match_actuals_to_formals arguments tito_roots in
            let combined_matches = List.zip_exn sink_argument_matches tito_argument_matches in
            let combine_sink_taint taint_tree { AccessPath.root; actual_path; formal_path; } =
              BackwardState.read_access_path
                ~root
                ~path:[]
                backward.sink_taint
              |> BackwardState.apply_call location ~callees:[ call_target ] ~port:root
              |> BackwardState.read_tree formal_path
              |> BackwardState.create_tree actual_path
              |> BackwardState.join_trees taint_tree
            in
            let combine_tito taint_tree { AccessPath.root; actual_path; formal_path; } =
              BackwardState.read_access_path
                ~root
                ~path:formal_path
                backward.taint_in_taint_out
              |> BackwardState.filter_map_tree ~f:(fun _ -> collapsed_call_taint)
              |> BackwardState.create_tree actual_path
              |> BackwardState.join_trees taint_tree
            in
            let analyze_argument state ((argument, sink_matches), (_dup, tito_matches)) =
              let sink_taint =
                List.fold sink_matches ~f:combine_sink_taint ~init:BackwardState.empty_tree
              in
              let taint_in_taint_out =
                List.fold tito_matches ~f:combine_tito ~init:BackwardState.empty_tree
              in
              let argument_taint = BackwardState.join_trees sink_taint taint_in_taint_out in
              analyze_unstarred_expression ~resolution argument_taint argument state
            in
            List.fold ~f:analyze_argument combined_matches ~init:state
        | _ ->
            (* obscure or no model *)
            List.fold_right ~f:(analyze_argument ~resolution call_taint) arguments ~init:state
      in
      match call_targets with
      | [] ->
          (* If we don't have a call target: propagate argument taint. *)
          List.fold_right ~f:(analyze_argument ~resolution call_taint) arguments ~init:state
      | call_targets ->
          List.map call_targets ~f:analyze_call_target
          |> List.fold ~init:(FixpointState.create ()) ~f:FixpointState.join

    and analyze_call ~resolution location ~callee arguments state taint =
      match callee with
      | Global access ->
          let access, extra_arguments =
            Interprocedural.CallResolution.normalize_global ~resolution access
          in
          let call_target = Interprocedural.Callable.create_real access in
          let arguments = extra_arguments @ arguments in
          apply_call_targets ~resolution location arguments state taint [call_target]

      | Access { expression = receiver; member = method_name} ->
          let state =
            let receiver = as_access receiver in
            let arguments =
              let receiver_argument_record =
                {
                  Argument.name = None;
                  value = Node.create ~location (Expression.Access receiver);
                }
              in
              receiver_argument_record :: arguments
            in
            Interprocedural.CallResolution.get_indirect_targets ~resolution ~receiver ~method_name
            |> apply_call_targets ~resolution location arguments state taint
          in
          state

      | _ ->
          (* TODO(T32198746): figure out the BW and TAINT_IN_TAINT_OUT model for
             whatever is called here.
             For now, we propagate taint to all args implicitly, and to the function. *)
          let state =
            List.fold_right
              arguments
              ~f:(analyze_argument ~resolution taint)
              ~init:state
          in
          analyze_normalized_expression ~resolution state taint callee


    and analyze_normalized_expression ~resolution state taint expression =
      Log.log
        ~section:`Taint
        "analyze_normalized_expression: %a"
        pp_normalized_expression expression;
      match expression with
      | Access { expression; member } ->
          let field = AccessPathTree.Label.Field member in
          let taint =
            BackwardState.assign_tree_path [field] ~tree:BackwardState.empty_tree ~subtree:taint
          in
          analyze_normalized_expression ~resolution state taint expression
      | Index { expression; index; _ } ->
          let taint = BackwardState.create_tree [index] taint in
          analyze_normalized_expression ~resolution state taint expression
      | Call { callee; arguments; } ->
          analyze_call ~resolution arguments.location ~callee arguments.value state taint
      | Expression expression ->
          analyze_expression ~resolution taint expression state
      | Global _ ->
          state
      | Local name ->
          store_weak_taint ~root:(Root.Variable name) ~path:[] taint state

    and analyze_dictionary_entry ~resolution taint state { Dictionary.key; value; } =
      let field_name = AccessPath.get_index key in
      let value_taint = BackwardState.read_tree [field_name] taint in
      analyze_expression ~resolution value_taint value state

    and analyze_reverse_list_element ~total ~resolution taint reverse_position state expression =
      let position = total - reverse_position - 1 in
      let index_name = AccessPathTree.Label.Field (Identifier.create (string_of_int position)) in
      let value_taint = BackwardState.read_tree [index_name] taint in
      analyze_expression ~resolution value_taint expression state

    and analyze_comprehension ~resolution taint { Comprehension.element; generators; _ } state =
      let element_taint = BackwardState.read_tree [AccessPathTree.Label.Any] taint in
      let state = analyze_expression ~resolution element_taint element state in
      let handle_generator state { Comprehension.target; iterator; _ } =
        let access_path = of_expression target in
        let bound_variable_taint = get_taint access_path state in
        let iterator_taint =
          BackwardState.create_tree
            [AccessPathTree.Label.Any]
            bound_variable_taint
        in
        analyze_expression ~resolution iterator_taint iterator state
      in
      List.fold ~f:handle_generator generators ~init:state

    (* Skip through * and **. Used at call sites where * and ** are handled explicitly *)
    and analyze_unstarred_expression ~resolution taint expression state =
      match expression.Node.value with
      | Starred (Starred.Once expression)
      | Starred (Starred.Twice expression) ->
          analyze_expression ~resolution taint expression state
      | _ ->
          analyze_expression ~resolution taint expression state

    and analyze_expression ~resolution taint { Node.value = expression; _ } state =
      Log.log ~section:`Taint "analyze_expression: %a" Expression.pp_expression expression;
      match expression with
      | Access access ->
          normalize_access access ~resolution
          |> analyze_normalized_expression ~resolution state taint
      | Await expression ->
          analyze_expression ~resolution taint expression state
      | BooleanOperator { left; operator = _; right }
      | ComparisonOperator { left; operator=_; right } ->
          analyze_expression ~resolution taint right state
          |> analyze_expression ~resolution taint left
      | Complex _ ->
          state
      | Dictionary dictionary ->
          List.fold ~f:(analyze_dictionary_entry ~resolution taint) dictionary.entries ~init:state
      | DictionaryComprehension _
      | Ellipses
      | False
      | Float _ ->
          state
      | Generator comprehension ->
          analyze_comprehension ~resolution taint comprehension state
      | Integer _ ->
          state
      | Lambda { parameters = _; body } ->
          (* Ignore parameter bindings and pretend body is inlined *)
          analyze_expression ~resolution taint body state
      | List list ->
          let total = List.length list in
          List.foldi
            list
            ~f:(analyze_reverse_list_element ~total ~resolution taint)
            ~init:state
      | ListComprehension comprehension ->
          analyze_comprehension ~resolution taint comprehension state
      | Set set ->
          let element_taint = BackwardState.read_tree [AccessPathTree.Label.Any] taint in
          List.fold
            set
            ~f:(Fn.flip (analyze_expression ~resolution element_taint))
            ~init:state
      | SetComprehension comprehension ->
          analyze_comprehension ~resolution taint comprehension state
      | Starred (Starred.Once expression)
      | Starred (Starred.Twice expression) ->
          let taint = BackwardState.create_tree [AccessPathTree.Label.Any] taint in
          analyze_expression ~resolution taint expression state
      | String _ ->
          state
      | Ternary { target; test; alternative } ->
          let state_then = analyze_expression ~resolution taint target state in
          let state_else = analyze_expression ~resolution taint alternative state in
          join state_then state_else
          |> analyze_expression ~resolution BackwardState.empty_tree test
      | True ->
          state
      | Tuple list ->
          let total = List.length list in
          List.foldi
            list
            ~f:(analyze_reverse_list_element ~total ~resolution taint)
            ~init:state
      | UnaryOperator { operator = _; operand } ->
          analyze_expression ~resolution taint operand state
      | Yield (Some expression) ->
          analyze_expression ~resolution taint expression state
      | Yield None ->
          state


    let analyze_definition ~define:_ state =
      state

    (* Returns the taint, and whether to collapse one level (due to star expression) *)
    let rec compute_assignment_taint target state =
      match target.Node.value with
      | Starred (Once target | Twice target) ->
          (* This is approximate. Unless we can get the tuple type on the right
             to tell how many total elements there will be, we just pick up the
             entire collection. *)
          let taint, _ = compute_assignment_taint target state in
          taint, true
      | List targets
      | Tuple targets ->
          let compute_tuple_target_taint position taint_accumulator target =
            let taint, collapse = compute_assignment_taint target state in
            let index_taint =
              if collapse then taint
              else
                let index_name =
                  AccessPathTree.Label.Field (Identifier.create (string_of_int position))
                in
                BackwardState.create_tree [index_name] taint
            in
            BackwardState.join_trees index_taint taint_accumulator
          in
          let taint =
            List.foldi
              targets
              ~f:compute_tuple_target_taint
              ~init:BackwardState.empty_tree
          in
          taint, false
      | _ ->
          let access_path = of_expression target in
          get_taint access_path state, false


    let analyze_statement ~resolution state statement =
      Log.log
        ~section:`Taint
        "State: %a\nStmt: %a"
        pp state
        Statement.pp_statement statement;
      match statement with
      | Assign { target; value; _ } ->
          let taint, _ = compute_assignment_taint target state in
          analyze_expression ~resolution taint value state
      | Assert _
      | Break
      | Class _
      | Continue ->
          state
      | Define define ->
          analyze_definition ~define state
      | Delete _ ->
          state
      | Expression expression ->
          analyze_expression ~resolution BackwardState.empty_tree expression state
      | For _
      | Global _
      | If _
      | Import _
      | Nonlocal _
      | Pass
      | Raise _ ->
          state
      | Return { expression = Some expression; _ } ->
          let access_path = { root = Root.LocalResult; path = [] } in
          let return_taint = get_taint (Some access_path) state in
          analyze_expression ~resolution return_taint expression state
      | Return { expression = None; _ }
      | Try _
      | With _
      | While _ ->
          state
      | Yield expression
      | YieldFrom expression ->
          let access_path = { root = Root.LocalResult; path = [] } in
          let return_taint = get_taint (Some access_path) state in
          analyze_expression ~resolution return_taint expression state


    let backward ?key state ~statement:({ Node.value = statement; _ }) =
      let resolution =
        ResolutionSharedMemory.resolution
          ~environment:FunctionContext.environment
          ~access:FunctionContext.definition.value.name
          ~key
      in
      analyze_statement ~resolution state statement


    let forward ?key:_ _ ~statement:_ =
      failwith "Don't call me"
  end


  and Analyzer : Fixpoint.Fixpoint with type state = FixpointState.t = Fixpoint.Make(FixpointState)

end


(* Split the inferred entry state into externally visible taint_in_taint_out
   parts and sink_taint. *)
let extract_tito_and_sink_models parameters entry_taint =
  let filter_to_local_return taint =
    BackwardTaint.partition_tf ~f:((=) Sinks.LocalReturn) taint
    |> fst
  in
  let normalized_parameters = AccessPath.Root.normalize_parameters parameters in
  let extract_taint_in_taint_out model (parameter, name, _annotation) =
    let taint_in_taint_out_taint =
      BackwardState.read (Root.Variable name) entry_taint
      |> BackwardState.filter_map_tree ~f:filter_to_local_return
    in
    if not (BackwardState.is_empty_tree taint_in_taint_out_taint) then
      BackwardState.assign ~root:parameter ~path:[] taint_in_taint_out_taint model
    else
      model
  in
  let filter_to_real_sinks taint =
    BackwardTaint.partition_tf ~f:((<>) Sinks.LocalReturn) taint
    |> fst
  in
  let extract_sink_taint model (parameter, name, _annotation) =
    let sink_taint =
      BackwardState.read (Root.Variable name) entry_taint
      |> BackwardState.filter_map_tree ~f:filter_to_real_sinks
    in
    if not (BackwardState.is_empty_tree sink_taint) then
      BackwardState.assign ~root:parameter ~path:[] sink_taint model
    else
      model
  in
  let taint_in_taint_out =
    List.fold normalized_parameters ~f:extract_taint_in_taint_out ~init:BackwardState.empty
  in
  let sink_taint =
    List.fold normalized_parameters ~f:extract_sink_taint ~init:BackwardState.empty
  in
  TaintResult.Backward.{ taint_in_taint_out; sink_taint; }


let run ~environment ~define:({ Node.value = { Define.parameters; name; _ }; _ } as define) =
  let module AnalysisInstance =
    AnalysisInstance(struct
      let definition = define
      let environment = environment
    end)
  in
  let open AnalysisInstance in
  let initial = FixpointState.{ taint = initial_taint define.Node.value } in
  let cfg = Cfg.create define.value in
  let entry_state =
    Analyzer.backward ~cfg ~initial
    |> Analyzer.entry
  in
  let () =
    match entry_state with
    | Some entry_state ->
        Log.log
          ~section:`Taint
          "Final state: %a"
          FixpointState.pp entry_state
    | None ->
        Log.log ~section:`Taint "No final state found"
  in
  let extract_model FixpointState.{ taint; _ } =
    let model = extract_tito_and_sink_models parameters taint in
    let () =
      Log.log
        ~section:`Taint
        "Callable: %a Models: %a"
        Access.pp name
        TaintResult.Backward.pp_model model
    in
    model
  in
  entry_state
  >>| extract_model
  |> Option.value ~default:TaintResult.Backward.empty
