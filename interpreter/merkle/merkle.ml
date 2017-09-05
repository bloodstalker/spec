
(* interpreter with merkle proofs *)

open Ast
open Source
open Types
open Values

let trace name = if !Flags.trace then print_endline ("-- " ^ name)

(* perhaps we need to link the modules first *)

(* have a separate call stack? *)

(* perhaps the memory will include the stack? nope *)

type inst =
 | UNREACHABLE
 | NOP
 | JUMP of int
 | JUMPI of int
 | CALL of int
 | LABEL of int
 | PUSHBRK of int
(*
 | L_JUMP of int
 | L_JUMPI of int
 | L_CALL of int
 | L_LABEL of int
 | L_PUSHBRK of int
*)
 | POPBRK
 | BREAK
 | RETURN
 | LOAD of loadop
 | STORE of storeop
 | DROP
 | DUP of int
 | SWAP of int
 | LOADGLOBAL of int
 | STOREGLOBAL of int
 | CURMEM
 | GROW
 | POPI1 of int
 | POPI2 of int
 | BREAKTABLE
 | CALLI of int (* indirect call, check from table *)
 | PUSH of value                  (* constant *)
 | TEST of testop                    (* numeric test *)
 | CMP of relop                  (* numeric comparison *)
 | UNA of unop                     (* unary numeric operator *)
 | BIN of binop                   (* binary numeric operator *)
 | CONV of cvtop

type context = {
  ptr : int;
  bptr : int;
  label : int;
  f_types : (Int32.t, func_type) Hashtbl.t;
}

(* Push the break points to stack? they can have own stack, also returns will have the same *)

let rec compile ctx expr = compile' ctx expr.it
and compile' ctx = function
 | Unreachable ->
   ctx, [UNREACHABLE]
 | Nop ->
   ctx, [NOP]
 | Block (ty, lst) ->
   trace ("block start " ^ string_of_int ctx.ptr);
   let end_label = ctx.label in
   let ctx = {ctx with label=ctx.label+1; bptr=ctx.bptr+1} in
   let ctx, body = compile_block ctx lst in
   trace ("block end " ^ string_of_int ctx.ptr);
   {ctx with bptr=ctx.bptr-1}, [PUSHBRK end_label] @ body @ [LABEL end_label; POPBRK]
 | Const lit -> {ctx with ptr = ctx.ptr+1}, [PUSH lit.it]
 | Test t -> ctx, [TEST t]
 | Compare i ->
   trace "cmp";
   {ctx with ptr = ctx.ptr-1}, [CMP i]
 | Unary i -> ctx, [UNA i]
 | Binary i -> 
   trace "bin";
   {ctx with ptr = ctx.ptr-1}, [BIN i]
 | Convert i -> ctx, [CONV i]
 | Loop (_, lst) ->
   let start_label = ctx.label in
   let end_label = ctx.label+1 in
   let sptr = ctx.ptr in
   trace ("loop start " ^ string_of_int sptr);
   let ctx = {ctx with label=ctx.label+2; bptr=ctx.bptr+1} in
   let ctx, body = compile_block ctx lst in
   trace ("loop end " ^ string_of_int ctx.ptr);
   {ctx with bptr=ctx.bptr-1}, [LABEL start_label; PUSHBRK start_label] @ body @ [POPBRK; LABEL end_label]
 | If (ty, texp, fexp) ->
   trace ("if " ^ string_of_int ctx.ptr);
   let if_label = ctx.label in
   let end_label = ctx.label+1 in
   let a_ptr = ctx.ptr-1 in
   let ctx = {ctx with ptr=a_ptr; label=ctx.label+2} in
   (*
   let ctx, tbody = compile_block ctx texp in
   let ctx, fbody = compile_block {ctx with ptr=a_ptr} fexp in
   *)
   let ctx, tbody = compile' ctx (Block (ty, texp)) in
   let ctx, fbody = compile' {ctx with ptr=a_ptr} (Block (ty, fexp)) in
   ctx, [JUMPI if_label] @ fbody @ [JUMP end_label; LABEL if_label] @ tbody @ [LABEL end_label]
 | Br x -> compile_break ctx (Int32.to_int x.it)
 | BrIf x ->
   trace ("brif " ^ Int32.to_string x.it);
   let continue_label = ctx.label in
   let end_label = ctx.label+1 in
   let ctx = {ctx with label=ctx.label+2; ptr = ctx.ptr-1} in
   let ctx, rest = compile_break ctx (Int32.to_int x.it) in
   ctx, [JUMPI continue_label; JUMP end_label; LABEL continue_label] @ rest @ [LABEL end_label]
 | BrTable (tab, def) ->
   (* push the list there, then use a special instruction *)
   let lst = List.map (fun x -> PUSH (Values.I32 x.it)) (def::tab) in
   ctx, lst @ [DUP (List.length lst); POPI1 (List.length lst); POPI2 (List.length lst); BREAKTABLE]
 | Return ->  compile_break ctx ctx.bptr
 | Drop ->
    trace "drop";
    {ctx with ptr=ctx.ptr-1}, [DROP]
 | GrowMemory -> {ctx with ptr=ctx.ptr-1}, [GROW]
 | CurrentMemory -> {ctx with ptr=ctx.ptr+1}, [CURMEM]
 | GetGlobal x -> {ctx with ptr=ctx.ptr+1}, [LOADGLOBAL (Int32.to_int x.it)]
 | SetGlobal x ->
   trace "set global";
   {ctx with ptr=ctx.ptr-1}, [STOREGLOBAL (Int32.to_int x.it)]
 | Call v ->
   (* Will just push the pc *)
   let FuncType (par,ret) = Hashtbl.find ctx.f_types v.it in
   {ctx with ptr=ctx.ptr+List.length ret-List.length par}, [CALL (Int32.to_int v.it)]
 | CallIndirect v ->
   let FuncType (par,ret) = Hashtbl.find ctx.f_types v.it in
   {ctx with ptr=ctx.ptr+List.length ret-List.length par}, [CALLI 0]
 | Select ->
   trace "select";
   let else_label = ctx.label in
   let end_label = ctx.label+1 in
   let ctx = {ctx with ptr=ctx.ptr-2; label=ctx.label+2} in
   ctx, [JUMPI else_label; DROP; DROP; JUMP end_label; LABEL else_label; DUP 1; SWAP 2; DROP; DROP; DROP; LABEL end_label]
 (* Dup ptr will give local 0 *)
 | GetLocal v ->
   trace ("get local " ^ string_of_int (Int32.to_int v.it) ^ " from " ^  string_of_int (ctx.ptr - Int32.to_int v.it));
   {ctx with ptr=ctx.ptr+1}, [DUP (ctx.ptr - Int32.to_int v.it)]
 | SetLocal v ->
   trace "set local";
   {ctx with ptr=ctx.ptr-1}, [SWAP (ctx.ptr - Int32.to_int v.it); DROP]
 | TeeLocal v ->
   ctx, [SWAP (Int32.to_int v.it+ctx.ptr)]
 | Load op -> ctx, [LOAD op]
 | Store op ->
   trace "store";
   {ctx with ptr=ctx.ptr-2}, [STORE op]

and compile_break ctx = function
 | 0 -> ctx, [BREAK]
 | i ->
   let ctx, rest = compile_break ctx (i-1) in
   ctx, [POPBRK] @ rest

and compile_block ctx = function
 | [] -> ctx, []
 | a::tl ->
    let ctx, a = compile ctx a in
    let ctx, rest = compile_block ctx tl in
    ctx, a @ rest

let rec make a n = if n = 0 then [] else a :: make a (n-1) 

let compile_func ctx func =
  let FuncType (par,ret) = Hashtbl.find ctx.f_types func.it.ftype.it in
  trace ("---- function start params:" ^ string_of_int (List.length par) ^ " locals: " ^ string_of_int (List.length func.it.locals) ^ " type: " ^ Int32.to_string func.it.ftype.it);
  (* Just params are now in the stack *)
  let ctx, body = compile' {ctx with ptr=ctx.ptr+List.length par+List.length func.it.locals} (Block ([], func.it.body)) in
  trace ("---- function end " ^ string_of_int ctx.ptr);
  ctx,
  make (PUSH (I32 Int32.zero)) (List.length func.it.locals) @
  body @
  List.flatten (List.mapi (fun i _ -> [DUP (List.length ret - i); SWAP (ctx.ptr-i+1); DROP]) ret) @
  make DROP (List.length par + List.length func.it.locals) @
  [RETURN]

(* This resolves only one function, think more *)
let resolve_inst tab = function
 | LABEL _ -> NOP
 | JUMP l ->
   let loc = Hashtbl.find tab l in
   trace ("resolve jump " ^ string_of_int l ^ " -> " ^ string_of_int loc);
   JUMP loc
 | JUMPI l ->
   let loc = Hashtbl.find tab l in
   trace ("resolve jumpi " ^ string_of_int l ^ " -> " ^ string_of_int loc);
   JUMPI loc
(* | CALL l -> CALL (Hashtbl.find tab l) *)
 | PUSHBRK l -> PUSHBRK (Hashtbl.find tab l)
 | a -> a

let resolve_to n lst =
  let tab = Hashtbl.create 10 in
  List.iteri (fun i inst -> match inst with LABEL l -> (* trace ("label " ^ string_of_int l); *) Hashtbl.add tab l (i+n)| _ -> ()) lst;
  List.map (resolve_inst tab) lst

let resolve_inst2 tab = function
 | CALL l -> CALL (Hashtbl.find tab l)
 | a -> a

let compile_module m =
  let ftab = Hashtbl.create 10 in
  let ttab = Hashtbl.create 10 in
  List.iteri (fun i f -> Hashtbl.add ttab (Int32.of_int i) f.it) m.types;
  List.iteri (fun i f ->
    let ty = Hashtbl.find ttab f.it.ftype.it in
    Hashtbl.add ftab (Int32.of_int i) ty) m.funcs;
  let module_codes = List.map (compile_func {ptr=0; label=0; f_types=ftab; bptr=0}) m.funcs in
  let f_resolve = Hashtbl.create 10 in
  let rec build n acc = function
   | [] -> acc
   | (_,md)::tl ->
     let sz = List.length acc in
     Hashtbl.add f_resolve n sz;
     build (n+1) (acc@resolve_to sz md) tl in
  let flat_code = build 0 [] module_codes in
  List.map (resolve_inst2 f_resolve) flat_code

let compile_test m func vs =
  let ftab = Hashtbl.create 10 in
  let ttab = Hashtbl.create 10 in
  trace ("Function types: " ^ string_of_int (List.length m.types));
  trace ("Functions: " ^ string_of_int (List.length m.funcs));
  List.iteri (fun i f -> Hashtbl.add ttab (Int32.of_int i) f.it) m.types;
  let entry = ref 0 in
  List.iteri (fun i f ->
    if f = func then ( (* prerr_endline "found it" ; *) entry := i );
    let ty = Hashtbl.find ttab f.it.ftype.it in
    Hashtbl.add ftab (Int32.of_int i) ty) m.funcs;
  let module_codes = List.map (compile_func {ptr=0; label=0; f_types=ttab; bptr=0}) m.funcs in
  let f_resolve = Hashtbl.create 10 in
  let rec build n acc = function
   | [] -> acc
   | (_,md)::tl ->
     let sz = List.length acc in
     Hashtbl.add f_resolve n sz;
     build (n+1) (acc@resolve_to sz md) tl in
  let test_code = List.map (fun v -> PUSH v) vs @ [CALL !entry; UNREACHABLE] in
  let flat_code = build 0 test_code module_codes in
  List.map (resolve_inst2 f_resolve) flat_code

(* perhaps for now just make a mega module *)
let compile_modules lst =
  let mega = {empty_module with
     types=List.flatten (List.map (fun m -> m.types) lst);
     funcs=List.flatten (List.map (fun m -> m.funcs) lst);
  } in
  compile_module mega


