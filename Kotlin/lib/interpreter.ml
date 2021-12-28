open Base
open Utils
open Parser
open Ast

module Interpret (M : MONAD_FAIL) = struct
  open M

  type scope_type =
    | Initialize
    | Function
    | DereferencedObject of object_t ref
    | PrivateInObject of object_t ref
    | Method of object_t ref
    | AnonymousFunction of scope_type

  type context =
    { environment : record_t list
    ; checked_not_null_values : record_t list
    ; last_eval_expression : value
    ; last_return_value : value
    ; last_derefered_variable : record_t option
    ; scope : scope_type
    }

  let check_typename_value_correspondance = function
    | Dynamic, _ -> true
    | FunctionType _, Ast.AnonymousFunction _ -> true
    | (Int | Nullable Int), IntValue _ -> true
    | (String | Nullable String), StringValue _ -> true
    | (Boolean | Nullable Boolean), BooleanValue _ -> true
    | Nullable _, NullValue -> true
    | Unit, Unitialized -> true
    | _, _ -> false
  ;;

  let check_record_is_private rc =
    Option.is_some
      (List.find_map rc.modifiers ~f:(function
          | Private -> Some Private
          | _ -> None))
  ;;

  let check_record_is_protected rc =
    Option.is_some
      (List.find_map rc.modifiers ~f:(function
          | Protected -> Some Protected
          | _ -> None))
  ;;

  let check_record_is_open rc =
    Option.is_some
      (List.find_map rc.modifiers ~f:(function
          | Open -> Some Open
          | _ -> None))
  ;;

  let check_record_is_override rc =
    Option.is_some
      (List.find_map rc.modifiers ~f:(function
          | Override -> Some Override
          | _ -> None))
  ;;

  let rec check_record_accessible_in_ctx ctx rc =
    match ctx.scope with
    | PrivateInObject _ | Method _ -> true
    | AnonymousFunction outer_scope ->
      check_record_accessible_in_ctx { ctx with scope = outer_scope } rc
    | _ ->
      if check_record_is_protected rc || check_record_is_private rc then false else true
  ;;

  let get_var_from_env env name =
    let filtered_env =
      List.filter env ~f:(fun r ->
          match r.content with
          | Variable _ -> true
          | _ -> false)
    in
    List.find_map filtered_env ~f:(fun r ->
        if String.equal r.name name then Some r else None)
  ;;

  let get_function_or_class_from_env env name =
    let filtered_env =
      List.filter env ~f:(fun r ->
          match r.content with
          | Function _ -> true
          | Class _ -> true
          | _ -> false)
    in
    List.find_map filtered_env ~f:(fun r ->
        if String.equal r.name name then Some r else None)
  ;;

  let get_class_from_env env name =
    let filtered_env =
      List.filter env ~f:(fun r ->
          match r.content with
          | Class _ -> true
          | _ -> false)
    in
    List.find_map filtered_env ~f:(fun r ->
        if String.equal r.name name then Some r else None)
  ;;

  let define_in_ctx ctx rc =
    match rc.content with
    | Variable _ ->
      let var_names =
        List.filter_map ctx.environment ~f:(function rc ->
            (match rc.content with
            | Variable _ -> Some rc.name
            | _ -> None))
      in
      if not (List.mem var_names rc.name ~equal:String.equal)
      then (
        let new_environment = rc :: ctx.environment in
        rc.clojure := new_environment;
        Some { ctx with environment = new_environment })
      else None
    | Function _ ->
      let func_names =
        List.filter_map ctx.environment ~f:(function rc ->
            (match rc.content with
            | Function _ -> Some rc.name
            | _ -> None))
      in
      if not (List.mem func_names rc.name ~equal:String.equal)
      then (
        let new_environment = rc :: ctx.environment in
        rc.clojure := new_environment;
        Some { ctx with environment = new_environment })
      else None
    | Class _ ->
      let cls_names =
        List.filter_map ctx.environment ~f:(function rc ->
            (match rc.content with
            | Class _ -> Some rc.name
            | _ -> None))
      in
      if not (List.mem cls_names rc.name ~equal:String.equal)
      then (
        let new_environment = rc :: ctx.environment in
        rc.clojure := new_environment;
        Some { ctx with environment = new_environment })
      else None
  ;;

  let set_var_in_ctx ctx name value =
    match get_var_from_env ctx.environment name with
    | None -> None
    | Some rc ->
      (match rc.content with
      | Variable content ->
        content.value := value;
        Some rc
      | _ -> failwith "Should not reach here")
  ;;

  let rec get_field_from_object obj name =
    match
      List.find_map obj.fields ~f:(fun r ->
          if String.equal r.name name then Some r else None)
    with
    | Some r -> Some r
    | None ->
      (match obj.super with
      | None -> None
      | Some super ->
        (match get_field_from_object super name with
        | None -> None
        | Some r_super -> if check_record_is_private r_super then None else Some r_super))
  ;;

  let rec get_method_from_object obj name =
    match
      List.find_map obj.methods ~f:(fun r ->
          if String.equal r.name name then Some r else None)
    with
    | Some r -> Some r
    | None ->
      (match obj.super with
      | None -> None
      | Some super ->
        (match get_method_from_object super name with
        | None -> None
        | Some r_super -> if check_record_is_private r_super then None else Some r_super))
  ;;

  let define_in_object obj rc =
    let rec iter_from_obj_to_super (cur : object_t option) func =
      match cur with
      | None -> []
      | Some o -> func o @ iter_from_obj_to_super o.super func
    in
    match rc.content with
    | Variable _ ->
      let defined_fields =
        iter_from_obj_to_super (Some obj) (fun o ->
            List.map o.fields ~f:(fun o -> o.name))
      in
      if not (List.mem defined_fields rc.name ~equal:String.equal)
      then (
        let new_fields = rc :: obj.fields in
        Some { obj with fields = new_fields })
      else (
        let declared_field = Option.value_exn (get_field_from_object obj rc.name) in
        if check_record_is_open declared_field && check_record_is_override rc
        then (
          let open_rc = { rc with modifiers = Open :: rc.modifiers } in
          let new_fields = open_rc :: obj.fields in
          Some { obj with fields = new_fields })
        else None)
    | Function _ ->
      let defined_methods =
        iter_from_obj_to_super (Some obj) (fun o ->
            List.map o.methods ~f:(fun o -> o.name))
      in
      if not (List.mem defined_methods rc.name ~equal:String.equal)
      then (
        let new_methods = rc :: obj.methods in
        Some { obj with methods = new_methods })
      else (
        let declared_method = Option.value_exn (get_method_from_object obj rc.name) in
        if check_record_is_open declared_method && check_record_is_override rc
        then (
          let open_rc = { rc with modifiers = Open :: rc.modifiers } in
          let new_fields = open_rc :: obj.fields in
          Some { obj with fields = new_fields })
        else None)
    | Class _ -> failwith "Not supported"
  ;;

  let last_identity = ref 0

  let get_unique_identity_code () =
    let code = !last_identity in
    last_identity := code + 1;
    code
  ;;

  let rec run (ctx : context) statement = interpret_statement ctx statement

  and interpret_statement ctx stat =
    match stat with
    | Block statements ->
      List.fold statements ~init:(M.return ctx) ~f:(fun monadic_ctx stat ->
          monadic_ctx
          >>= fun checked_ctx ->
          interpret_statement checked_ctx stat
          >>= fun stat_eval_ctx ->
          (match stat with
          | Expression _ ->
            (match ctx.scope with
            | AnonymousFunction _ ->
              M.return
                { stat_eval_ctx with
                  last_return_value = stat_eval_ctx.last_eval_expression
                }
            | _ -> M.return stat_eval_ctx)
          | _ -> M.return stat_eval_ctx)
          >>= fun eval_ctx ->
          match eval_ctx.last_return_value with
          | Unitialized ->
            (match stat with
            | Block _ -> M.return checked_ctx
            | _ -> M.return eval_ctx)
          | _ ->
            (match checked_ctx.scope with
            | Function | Method _ | AnonymousFunction _ -> M.return eval_ctx
            | _ -> M.fail ReturnNotInFunction))
    | InitializeBlock statements ->
      List.fold statements ~init:(M.return ctx) ~f:(fun monadic_ctx stat ->
          monadic_ctx
          >>= fun checked_ctx ->
          match stat with
          | VarDeclaration _ | FunDeclaration _ | ClassDeclaration _ ->
            interpret_statement checked_ctx stat
          | _ -> M.fail (NotAllowedStatementThere stat))
    | AnonymousFunctionDeclarationStatement (arguments, statement) ->
      let func =
        { identity_code = get_unique_identity_code ()
        ; fun_typename = Dynamic
        ; arguments
        ; statement
        }
      in
      M.return { ctx with last_eval_expression = AnonymousFunction func }
    | Return expression ->
      interpret_expression ctx expression
      >>= fun ret_ctx ->
      M.return { ctx with last_return_value = ret_ctx.last_eval_expression }
    | Expression expression -> interpret_expression ctx expression
    | ClassDeclaration
        (modifiers, name, constructor_args, super_call_option, class_statement) ->
      (match class_statement with
      | Block statements -> M.return statements
      | _ -> M.fail ClassBodyExpected)
      >>= fun statements ->
      let super_call =
        match super_call_option with
        | None when not (String.equal name "Any") -> Some (FunctionCall ("Any", []))
        | _ -> super_call_option
      in
      (match
         define_in_ctx
           ctx
           { name
           ; modifiers
           ; clojure = ref ctx.environment
           ; content = Class { constructor_args; super_call; statements }
           }
       with
      | None -> M.fail (Redeclaration name)
      | Some new_ctx -> M.return new_ctx)
    | FunDeclaration (modifiers, name, arguments, fun_typename, fun_statement) ->
      (match fun_statement with
      | Block _ -> M.return fun_statement
      | _ -> M.fail FunctionBodyExpected)
      >>= fun statement ->
      (match
         define_in_ctx
           ctx
           { name
           ; modifiers
           ; clojure = ref ctx.environment
           ; content =
               Function
                 { identity_code = get_unique_identity_code ()
                 ; fun_typename
                 ; arguments
                 ; statement
                 }
           }
       with
      | None -> M.fail (Redeclaration name)
      | Some new_ctx -> M.return new_ctx)
    | VarDeclaration (modifiers, var_modifier, name, var_typename, init_expression) ->
      (match init_expression with
      | None -> M.return Unitialized
      | Some expr ->
        interpret_expression ctx expr
        >>= fun interpreted_ctx -> M.return interpreted_ctx.last_eval_expression)
      >>= fun value ->
      (match
         define_in_ctx
           ctx
           { name
           ; modifiers
           ; clojure = ref ctx.environment
           ; content =
               Variable
                 { var_typename; mutable_status = var_modifier == Var; value = ref value }
           }
       with
      | None -> M.fail (Redeclaration name)
      | Some new_ctx -> M.return new_ctx)
    | Assign (var_identifier_expression, assign_expression) ->
      interpret_expression ctx var_identifier_expression
      >>= fun identifier_ctx ->
      (match identifier_ctx.last_derefered_variable with
      | None -> M.fail ExpectedVarIdentifer
      | Some rc ->
        (match rc.content with
        | Variable v -> M.return v
        | _ -> failwith "should not reach here")
        >>= fun var ->
        interpret_expression ctx assign_expression
        >>= fun assign_value_ctx ->
        if var.mutable_status
           && check_typename_value_correspondance
                (var.var_typename, assign_value_ctx.last_eval_expression)
        then (
          rc.clojure := identifier_ctx.environment;
          var.value := assign_value_ctx.last_eval_expression;
          M.return assign_value_ctx)
        else
          M.fail
            (VariableValueTypeMismatch
               (rc.name, var.var_typename, assign_value_ctx.last_eval_expression)))
    | If (log_expr, if_statement, else_statement) ->
      interpret_expression ctx log_expr
      >>= fun eval_ctx ->
      (match eval_ctx.last_eval_expression with
      | BooleanValue log_val ->
        if log_val
        then interpret_statement ctx if_statement
        else (
          match else_statement with
          | None -> M.return ctx
          | Some stat -> interpret_statement ctx stat)
      | _ -> M.fail ExpectedBooleanValue)
    | While (log_expr, while_statement) ->
      interpret_expression ctx log_expr
      >>= fun eval_ctx ->
      (match eval_ctx.last_eval_expression with
      | BooleanValue log_val ->
        if log_val
        then
          interpret_statement ctx while_statement
          >>= fun eval_while_ctx -> interpret_statement eval_while_ctx stat
        else M.return eval_ctx
      | _ -> M.fail ExpectedBooleanValue)

  and interpret_expression ctx expr =
    let eval_bin_args l r =
      interpret_expression ctx l
      >>= fun l_ctx ->
      interpret_expression ctx r
      >>= fun r_ctx -> return (l_ctx.last_eval_expression, r_ctx.last_eval_expression)
    in
    let eval_un_arg x =
      interpret_expression ctx x >>= fun x_ctx -> return x_ctx.last_eval_expression
    in
    match expr with
    | Println print_expr ->
      interpret_expression ctx print_expr
      >>= fun eval_ctx ->
      (match eval_ctx.last_eval_expression with
      | IntValue v -> print_endline (Int.to_string v)
      | StringValue v -> print_endline v
      | BooleanValue v -> print_endline (if v then "true" else "false")
      | NullValue | Unitialized -> print_endline "null"
      | Object obj -> Stdlib.Printf.printf "%s@%x\n" obj.classname obj.identity_code
      | _ -> failwith "Unsupported argument for println");
      M.return { ctx with last_eval_expression = NullValue }
    | AnonymousFunctionDeclaration stat -> interpret_statement ctx stat
    | FunctionCall (identifier, arg_expressions) ->
      let define_args args_ctx args exprs =
        List.fold2
          args
          exprs
          ~init:(M.return args_ctx)
          ~f:(fun monadic_ctx (arg_name, arg_typename) arg_expr ->
            monadic_ctx
            >>= fun monadic_ctx ->
            interpret_expression ctx arg_expr
            >>= fun eval_expr_ctx ->
            if check_typename_value_correspondance
                 (arg_typename, eval_expr_ctx.last_eval_expression)
            then (
              match
                define_in_ctx
                  monadic_ctx
                  { name = arg_name
                  ; modifiers = []
                  ; clojure = ref ctx.environment
                  ; content =
                      Variable
                        { var_typename = arg_typename
                        ; mutable_status = false
                        ; value = ref eval_expr_ctx.last_eval_expression
                        }
                  }
              with
              | None -> M.fail (Redeclaration arg_name)
              | Some ctx -> M.return ctx)
            else M.fail (VariableTypeMismatch arg_name))
      in
      let eval_function new_ctx func =
        match define_args new_ctx func.arguments arg_expressions with
        | Ok fun_ctx ->
          fun_ctx
          >>= fun fun_ctx ->
          interpret_statement fun_ctx func.statement
          >>= fun func_eval_ctx ->
          if check_typename_value_correspondance
               (func.fun_typename, func_eval_ctx.last_return_value)
          then
            M.return { ctx with last_eval_expression = func_eval_ctx.last_return_value }
          else
            M.fail
              (FunctionReturnTypeMismatch
                 (identifier, func.fun_typename, func_eval_ctx.last_return_value))
        | _ -> M.fail FunctionArgumentsCountMismatch
      in
      (match ctx.scope with
      | DereferencedObject obj | PrivateInObject obj | Method obj ->
        (match get_method_from_object !obj identifier with
        | None ->
          (match get_field_from_object !obj identifier with
          | None ->
            (match ctx.scope with
            | PrivateInObject _ | Method _ ->
              interpret_expression { ctx with scope = Initialize } expr
            | _ -> M.fail (UnknownMethod (!obj.classname, identifier)))
          | Some rc ->
            if check_record_accessible_in_ctx ctx rc
            then (
              match rc.content with
              | Variable content ->
                (match !(content.value) with
                | AnonymousFunction f -> M.return f
                | _ -> M.fail (UnknownFunction identifier))
                >>= fun func ->
                let new_ctx =
                  { ctx with
                    environment = !(rc.clojure)
                  ; scope = AnonymousFunction ctx.scope
                  }
                in
                eval_function new_ctx func
              | _ -> failwith "should not reach here")
            else M.fail (PrivateAccessError (!obj.classname, rc.name)))
        | Some meth ->
          let meth_content =
            match meth.content with
            | Function f -> f
            | _ -> failwith "should not reach here"
          in
          if check_record_accessible_in_ctx ctx meth
          then (
            let new_ctx =
              { ctx with environment = !(meth.clojure); scope = Method obj }
            in
            eval_function new_ctx meth_content)
          else M.fail (PrivateAccessError (!obj.classname, meth.name)))
      | _ ->
        (match get_function_or_class_from_env ctx.environment identifier with
        | None ->
          (match get_var_from_env ctx.environment identifier with
          | None -> M.fail (UnknownFunction identifier)
          | Some rc ->
            (match rc.content with
            | Variable content ->
              (match !(content.value) with
              | AnonymousFunction f -> M.return f
              | _ -> M.fail (UnknownFunction identifier))
              >>= fun func ->
              let new_ctx =
                { ctx with
                  environment = !(rc.clojure)
                ; scope = AnonymousFunction ctx.scope
                }
              in
              eval_function new_ctx func
            | _ -> failwith "should not reach here"))
        | Some rc ->
          (match rc.content with
          | Variable _ -> failwith "should not reach here"
          | Class class_data ->
            let new_object =
              ref
                { identity_code = get_unique_identity_code ()
                ; classname = rc.name
                ; super = None
                ; obj_class = class_data
                ; fields = []
                ; methods = []
                }
            in
            let new_ctx = { ctx with environment = !(rc.clojure); scope = Function } in
            (match define_args new_ctx class_data.constructor_args arg_expressions with
            | Ok constructor_ctx ->
              constructor_ctx
              >>= fun class_ctx ->
              (match class_data.super_call with
              | None -> M.return class_ctx
              | Some expr ->
                (match expr with
                | FunctionCall (identifier, _) ->
                  (match get_class_from_env ctx.environment identifier with
                  | Some rc ->
                    if check_record_is_open rc
                    then M.return expr
                    else M.fail (ClassNotOpen identifier)
                  | None -> M.fail (UnknownFunction identifier))
                | _ -> M.fail ClassSuperConstructorNotValid)
                >>= fun _ ->
                interpret_expression class_ctx expr
                >>= fun sup_ctx ->
                M.return sup_ctx.last_eval_expression
                >>= (function
                | Object super_object ->
                  new_object := { !new_object with super = Some super_object };
                  M.return class_ctx
                | _ -> M.fail ClassSuperConstructorNotValid))
              >>= fun evaluated_constructor_ctx ->
              M.return
                { evaluated_constructor_ctx with scope = PrivateInObject new_object }
              >>= fun class_inner_ctx ->
              List.fold
                class_data.statements
                ~init:(M.return class_inner_ctx)
                ~f:(fun acc stat ->
                  acc
                  >>= fun _ ->
                  match stat with
                  | VarDeclaration
                      (modifiers, var_modifier, name, var_typename, init_expression) ->
                    (match init_expression with
                    | None -> M.return Unitialized
                    | Some expr ->
                      interpret_expression class_inner_ctx expr
                      >>= fun interpreted_ctx ->
                      M.return interpreted_ctx.last_eval_expression)
                    >>= fun value ->
                    (match
                       define_in_object
                         !new_object
                         { name
                         ; modifiers
                         ; clojure = ref ctx.environment
                         ; content =
                             Variable
                               { var_typename
                               ; mutable_status = var_modifier == Var
                               ; value = ref value
                               }
                         }
                     with
                    | None -> M.fail (Redeclaration name)
                    | Some updated_obj ->
                      new_object := updated_obj;
                      M.return class_inner_ctx)
                  | FunDeclaration
                      (modifiers, name, arguments, fun_typename, fun_statement) ->
                    (match fun_statement with
                    | Block _ -> M.return fun_statement
                    | _ -> M.fail FunctionBodyExpected)
                    >>= fun statement ->
                    (match
                       define_in_object
                         !new_object
                         { name
                         ; modifiers
                         ; clojure = ref ctx.environment
                         ; content =
                             Function
                               { identity_code = get_unique_identity_code ()
                               ; fun_typename
                               ; arguments
                               ; statement
                               }
                         }
                     with
                    | None -> M.fail (Redeclaration name)
                    | Some updated_obj ->
                      new_object := updated_obj;
                      M.return class_inner_ctx)
                  | _ -> M.fail (IllegalKindOfStatementInsideClass stat))
              >>= fun _ -> M.return { ctx with last_eval_expression = Object !new_object }
            | _ -> M.fail FunctionArgumentsCountMismatch)
          | Function func ->
            let new_ctx = { ctx with environment = !(rc.clojure); scope = Function } in
            eval_function new_ctx func)))
    | Const x -> M.return { ctx with last_eval_expression = x }
    | VarIdentifier identifier ->
      (match ctx.scope with
      | DereferencedObject obj | PrivateInObject obj | Method obj ->
        if String.equal identifier "this"
        then M.return { ctx with last_eval_expression = Object !obj }
        else (
          match get_field_from_object !obj identifier with
          | None -> interpret_expression { ctx with scope = Initialize } expr
          | Some rc ->
            if check_record_accessible_in_ctx ctx rc
            then (
              let field_content =
                match rc.content with
                | Variable v -> v
                | _ -> failwith "should not reach here"
              in
              M.return
                { ctx with
                  last_eval_expression = !(field_content.value)
                ; last_derefered_variable = Some rc
                })
            else M.fail (PrivateAccessError (!obj.classname, rc.name)))
      | _ ->
        (match get_var_from_env ctx.environment identifier with
        | None -> M.fail (UnknownVariable identifier)
        | Some rc ->
          (match rc.content with
          | Variable var ->
            M.return
              { ctx with
                last_eval_expression = !(var.value)
              ; last_derefered_variable = Some rc
              }
          | _ -> failwith "should not reach here")))
    | Dereference (obj_expression, der_expression)
    | ElvisDereference (obj_expression, der_expression) ->
      interpret_expression ctx obj_expression
      >>= fun eval_ctx ->
      (match eval_ctx.last_eval_expression with
      | Object obj ->
        let scope =
          match ctx.scope with
          | DereferencedObject sc_obj | PrivateInObject sc_obj | Method sc_obj ->
            if !sc_obj == obj
            then PrivateInObject (ref obj)
            else DereferencedObject (ref obj)
          | _ -> DereferencedObject (ref obj)
        in
        let obj_ctx = { ctx with scope } in
        (match der_expression with
        | VarIdentifier _ | FunctionCall _ | Dereference _ ->
          interpret_expression obj_ctx der_expression
        | _ -> M.fail DereferenceError)
      | NullValue ->
        (match expr with
        | ElvisDereference _ -> M.return { ctx with last_eval_expression = NullValue }
        | _ -> M.fail ExprectedObjectToDereference)
      | _ -> M.fail ExprectedObjectToDereference)
    | Add (l, r) ->
      eval_bin_args l r
      >>= (function
      | IntValue x, IntValue y ->
        M.return { ctx with last_eval_expression = IntValue (x + y) }
      | StringValue x, StringValue y ->
        M.return { ctx with last_eval_expression = StringValue (x ^ y) }
      | _ -> M.fail (UnsupportedOperandTypes expr))
    | Mul (l, r) ->
      eval_bin_args l r
      >>= (function
      | IntValue x, IntValue y ->
        M.return { ctx with last_eval_expression = IntValue (x * y) }
      | _ -> M.fail (UnsupportedOperandTypes expr))
    | Sub (l, r) ->
      eval_bin_args l r
      >>= (function
      | IntValue x, IntValue y ->
        M.return { ctx with last_eval_expression = IntValue (x - y) }
      | _ -> M.fail (UnsupportedOperandTypes expr))
    | And (l, r) ->
      eval_bin_args l r
      >>= (function
      | BooleanValue x, BooleanValue y ->
        M.return { ctx with last_eval_expression = BooleanValue (x && y) }
      | _ -> M.fail (UnsupportedOperandTypes expr))
    | Or (l, r) ->
      eval_bin_args l r
      >>= (function
      | BooleanValue x, BooleanValue y ->
        M.return { ctx with last_eval_expression = BooleanValue (x || y) }
      | _ -> M.fail (UnsupportedOperandTypes expr))
    | Not x ->
      eval_un_arg x
      >>= (function
      | BooleanValue x ->
        M.return { ctx with last_eval_expression = BooleanValue (not x) }
      | _ -> M.fail (UnsupportedOperandTypes expr))
    | Equal (l, r) ->
      eval_bin_args l r
      >>= (function
      | IntValue x, IntValue y ->
        M.return { ctx with last_eval_expression = BooleanValue (x = y) }
      | StringValue x, StringValue y ->
        M.return { ctx with last_eval_expression = BooleanValue (String.equal x y) }
      | BooleanValue x, BooleanValue y ->
        M.return
          { ctx with
            last_eval_expression = BooleanValue ((x && y) || ((not x) && not y))
          }
      | AnonymousFunction x, AnonymousFunction y ->
        M.return
          { ctx with
            last_eval_expression = BooleanValue (x.identity_code == y.identity_code)
          }
        (* FIXME: Кажется, что так сравнивать не верно, так как тут мы хотим узнать, что x и y - это один и тот же (а не структурно одинаковый) объект *)
      | Object x, Object y ->
        M.return
          { ctx with
            last_eval_expression = BooleanValue (x.identity_code == y.identity_code)
          }
      | NullValue, NullValue
      | NullValue, Unitialized
      | Unitialized, NullValue
      | Unitialized, Unitialized ->
        M.return { ctx with last_eval_expression = BooleanValue true }
      | NullValue, _ | _, NullValue ->
        M.return { ctx with last_eval_expression = BooleanValue false }
      | _ -> M.return { ctx with last_eval_expression = BooleanValue false })
    | Less (l, r) ->
      eval_bin_args l r
      >>= (function
      | IntValue x, IntValue y ->
        M.return { ctx with last_eval_expression = BooleanValue (x < y) }
      | _ -> M.fail (UnsupportedOperandTypes expr))
    | Div (l, r) ->
      eval_bin_args l r
      >>= (function
      | IntValue x, IntValue y ->
        M.return { ctx with last_eval_expression = IntValue (x / y) }
      | _ -> M.fail (UnsupportedOperandTypes expr))
    | Mod (l, r) ->
      eval_bin_args l r
      >>= (function
      | IntValue x, IntValue y ->
        M.return { ctx with last_eval_expression = IntValue (x % y) }
      | _ -> M.fail (UnsupportedOperandTypes expr))
  ;;

  let load_standard_classes ctx =
    List.fold
      Std.standard_classes
      ~init:(M.return ctx)
      ~f:(fun monadic_ctx class_string ->
        monadic_ctx
        >>= fun cur_ctx ->
        let class_statement =
          Base.Option.value_exn (apply_parser Parser.Statement.statement class_string)
        in
        interpret_statement cur_ctx class_statement)
  ;;
end

let parse_and_run input =
  let open Statement in
  let open Interpret (Result) in
  let ctx =
    { environment = []
    ; checked_not_null_values = []
    ; last_eval_expression = Unitialized
    ; last_return_value = Unitialized
    ; last_derefered_variable = None
    ; scope = Initialize
    }
  in
  let ctx_with_standard_classes =
    Base.Option.value_exn (Base.Result.ok (load_standard_classes ctx))
  in
  match apply_parser initialize_block_statement input with
  | None -> Error EmptyProgram
  | Some statement ->
    (match interpret_statement ctx_with_standard_classes statement with
    | Error err -> Error err
    | Ok init_ctx ->
      let main_call =
        Base.Option.value_exn (apply_parser Parser.Expression.expression "main()")
      in
      interpret_expression init_ctx main_call)
;;
