(* Generate Target Code *)

functor CodeGenX86(structure BackendInfo : BACKEND_INFO
		   structure InstsX86 : INSTS_X86
		     sharing type InstsX86.label = BackendInfo.label 
		   structure JumpTables : JUMP_TABLES
		   structure Con : CON
		   structure Excon : EXCON
		   structure Lvars : LVARS
		   structure Lvarset : LVARSET
		     sharing type Lvarset.lvar = Lvars.lvar
		   structure Labels : ADDRESS_LABELS
		     sharing type Labels.label = BackendInfo.label
		   structure CallConv: CALL_CONV
		   structure LineStmt: LINE_STMT
 		   sharing type Con.con = LineStmt.con
		   sharing type Excon.excon = LineStmt.excon
		   sharing type Lvars.lvar = LineStmt.lvar = CallConv.lvar
                   sharing type Labels.label = LineStmt.label
		   sharing type CallConv.cc = LineStmt.cc
	           structure SubstAndSimplify: SUBST_AND_SIMPLIFY
                    where type ('a,'b,'c) LinePrg = ('a,'b,'c) LineStmt.LinePrg
		   sharing type SubstAndSimplify.lvar = LineStmt.lvar = InstsX86.lvar 
                   sharing type SubstAndSimplify.place = LineStmt.place
                   sharing type SubstAndSimplify.reg = InstsX86.reg
                   sharing type SubstAndSimplify.label = Labels.label
                   structure Effect : EFFECT
		   sharing type Effect.place = SubstAndSimplify.place
	           structure PP : PRETTYPRINT
		   sharing type PP.StringTree = LineStmt.StringTree
		   structure Flags : FLAGS
	           structure Report : REPORT
		   sharing type Report.Report = Flags.Report
		   structure Crash : CRASH) : CODE_GEN =       
struct

  structure I = InstsX86
  structure RI = I.RI (* RegisterInfo *)
  structure BI = BackendInfo
  structure SS = SubstAndSimplify
  structure LS = LineStmt

  val region_profiling : unit -> bool = Flags.is_on0 "region_profiling"

  type label = Labels.label
  type ('sty,'offset,'aty) LinePrg = ('sty,'offset,'aty) LineStmt.LinePrg
  type StoreTypeCO = SubstAndSimplify.StoreTypeCO
  type AtySS = SubstAndSimplify.Aty
  datatype reg = datatype I.reg
  datatype ea = datatype I.ea
  datatype lab = datatype I.lab
  type offset = int
  type AsmPrg = I.AsmPrg

  val tmp_reg0 = I.tmp_reg0
  val tmp_reg1 = I.tmp_reg1
  val caller_save_regs_ccall = map RI.lv_to_reg RI.caller_save_ccall_phregs (*caller_save_regs_ccall_as_lvs*)
  val all_regs = map RI.lv_to_reg (*RI.all_regs_as_lvs*) RI.all_regs

  (***********)
  (* Logging *)
  (***********)
  fun log s = TextIO.output(!Flags.log,s ^ "\n")
  fun msg s = TextIO.output(TextIO.stdOut, s)
  fun chat(s: string) = if !Flags.chat then msg (s) else ()
  fun die s  = Crash.impossible ("CodeGenX86." ^ s)
  fun not_impl n = die ("prim(" ^ n ^ ") not implemented")
  fun fast_pr stringtree = 
    (PP.outputTree ((fn s => TextIO.output(!Flags.log, s)) , stringtree, !Flags.colwidth);
     TextIO.output(!Flags.log, "\n"))

  fun display(title, tree) =
    fast_pr(PP.NODE{start=title ^ ": ",
		    finish="",
		    indent=3,
		    children=[tree],
		    childsep=PP.NOSEP
		    })

  (****************************************************************)
  (* Add Dynamic Flags                                            *)
  (****************************************************************)
  val _ = Flags.add_bool_entry {long="comments_in_x86_asmcode", short=NONE, item=ref false,
				menu=["Debug", "comments in x86 assembler code"], neg=false,
				desc="Insert comments in x86 assembler code."}

  val jump_tables = true
  val comments_in_asmcode = Flags.lookup_flag_entry "comments_in_x86_asmcode"
  val gc_p = Flags.is_on0 "garbage_collection"

  (**********************************
   * Some code generation utilities *
   **********************************)

  fun comment(str,C) = if !comments_in_asmcode then I.comment str :: C
		       else C
  fun comment_fn(f, C) = if !comments_in_asmcode then I.comment (f()) :: C
			 else C

  fun rem_dead_code nil = nil
    | rem_dead_code (C as i :: C') =
    case i 
      of I.lab _ => C
       | I.dot_long _ => C
       | I.dot_byte _ => C
       | I.dot_align _ => C
       | I.dot_globl _ => C
       | I.dot_text => C
       | I.dot_data => C
       | I.comment s => i :: rem_dead_code C'
       | _ => rem_dead_code C'

  (********************************)
  (* CG on Top Level Declarations *)
  (********************************)

  local

    (* Global Labels *)
    val exn_ptr_lab = NameLab "exn_ptr"
    val exn_counter_lab = NameLab "exnameCounter"
    val time_to_gc_lab = NameLab "time_to_gc"     (* Declared in GC.c *)
    val data_lab_ptr_lab = NameLab "data_lab_ptr" (* Declared in GC.c *)
    val stack_bot_gc_lab = NameLab "stack_bot_gc" (* Declared in GC.c *)
    val gc_stub_lab = NameLab "__gc_stub"
    val global_region_labs = 
      [(Effect.key_of_eps_or_rho Effect.toplevel_region_withtype_top, BI.toplevel_region_withtype_top_lab),
       (Effect.key_of_eps_or_rho Effect.toplevel_region_withtype_string, BI.toplevel_region_withtype_string_lab),
       (Effect.key_of_eps_or_rho Effect.toplevel_region_withtype_real, BI.toplevel_region_withtype_real_lab)]

    (* Labels Local To This Compilation Unit *)
    fun new_local_lab name = LocalLab (Labels.new_named name)
    local
      val counter = ref 0
      fun incr() = (counter := !counter + 1; !counter)
    in
      fun new_string_lab() : lab = DatLab(Labels.new_named ("StringLab" ^ Int.toString(incr())))
      fun new_float_lab() : lab = DatLab(Labels.new_named ("FloatLab" ^ Int.toString(incr())))
      fun new_num_lab() : lab = DatLab(Labels.new_named ("BoxedNumLab" ^ Int.toString(incr())))
      fun reset_label_counter() = counter := 0
    end

    (* Static Data inserted at the beginning of the code. *)
    local
      val static_data : I.inst list ref = ref []
    in
      fun add_static_data (insts) = (static_data := insts @ !static_data)
      fun reset_static_data () = static_data := []
      fun get_static_data C = !static_data @ C
    end

    (* giving numbers to registers---for garbage collection *)
    fun lv_to_reg_no lv = 
      case RI.lv_to_reg lv
	of eax => 0 | ebx => 1 | ecx => 2 | edx => 3
	 | esi => 4 | edi => 5 | ebp => 6 | esp => 7
	 | ah => die "lv_to_reg_no: ah"
	 | cl => die "lv_to_reg_no: cl"

    (* Convert ~n to -n; works for all int32 values including Int32.minInt *)
    fun intToStr (i : Int32.int) : string = 
      let fun tr s = case explode s
		       of #"~"::rest => implode (#"-"::rest)
			| _ => s
      in tr (Int32.toString i)
      end

    fun wordToStr (w : Word32.word) : string = intToStr(Word32.toLargeIntX w)
(*      "0x" ^ Word32.toString w *)

    (* Convert ~n to -n *)
    fun int_to_string i = if i >= 0 then Int.toString i
			  else "-" ^ Int.toString (~i)

    (* We make the offset base explicit in the following functions *)
    datatype Offset = 
        WORDS of int 
      | BYTES of int
      | IMMED of Int32.int

    fun copy(r1, r2, C) = if r1 = r2 then C
			  else I.movl(R r1, R r2) :: C

    (* Can be used to load from the stack or from a record *)     
    (* dst = base[x]                                       *)
    fun load_indexed(dst_reg:reg,base_reg:reg,offset:Offset,C) =
      let val x = case offset 
		    of BYTES x => x
		     | WORDS x => x*4
		     | _ => die "load_indexed: offset not in BYTES or WORDS"
      in I.movl(D(int_to_string x,base_reg), R dst_reg) :: C
      end

    (* Can be used to update the stack or store in a record *)
    (* base[x] = src                                        *)
    fun store_indexed(base_reg:reg,offset:Offset,src_reg:reg,C) =
      let val x = case offset 
		    of BYTES x => x
		     | WORDS x => x*4
		     | _ => die "store_indexed: offset not in BYTES or WORDS"
      in I.movl(R src_reg,D(int_to_string x,base_reg)) :: C
      end

    (* Calculate an address given a base and an offset *)
    (* dst = base + x                                  *)
    fun base_plus_offset(base_reg:reg,offset:Offset,dst_reg:reg,C) =
      let val x = case offset 
		    of BYTES x => x
		     | WORDS x => x*4
		     | _ => die "base_plus_offset: offset not in BYTES or WORDS"
      in if dst_reg = base_reg andalso x = 0 then C
	 else I.leal(D(int_to_string x, base_reg), R dst_reg) :: C
      end

    fun mkIntAty i = SS.INTEGER_ATY {value=Int32.fromInt i, 
				     precision=if BI.tag_integers() then 31 else 32}

    fun maybeTagInt {value: Int32.int, precision:int} : Int32.int =
      case precision
	of 31 => ((2 * value + 1)         (* use tagged-unboxed representation *)
		  handle Overflow => die "maybeTagInt.Overflow")
	 | 32 => value                    (* use untagged representation - maybe boxed *)
	 | _ => die "maybeTagInt"

    fun maybeTagWord {value: Word32.word, precision:int} : Word32.word =
      case precision
	of 31 =>                            (* use tagged representation *)
	  let val w = 0w2 * value + 0w1   
	  in if w < value then die "maybeTagWord.Overflow"
	     else w
	  end
	 | 32 => value                      (* use untagged representation - maybe boxed *)
	 | _ => die "maybeTagWord"

    (* formatting of immediate integer and word values *)
    fun fmtInt a : string = intToStr(maybeTagInt a)
    fun fmtWord a : string = wordToStr(maybeTagWord a)

    (* Load a constant *)
    (* dst = x         *)
    fun load_immed(IMMED x,dst_reg:reg,C) = 
      if x = 0 then I.xorl(R dst_reg, R dst_reg) :: C
      else I.movl(I (intToStr x), R dst_reg) :: C
      | load_immed _ = die "load_immed: immed not an IMMED"

    fun loadNum(x,dst_reg:reg,C) = 
      if x = "0" orelse x = "0x0" then I.xorl(R dst_reg, R dst_reg) :: C
      else I.movl(I x, R dst_reg) :: C

    fun loadNumBoxed(x,dst_reg:reg,C) = 
      if not(BI.tag_integers()) then die "loadNumBoxed.boxed integers/words necessary only when tagging is enabled"
      else 
	let val num_lab = new_num_lab()
	  val _ = add_static_data [I.dot_data,
				   I.dot_align 4,
				   I.lab num_lab,
				   I.dot_long(BI.pr_tag_w(BI.tag_word_boxed(true))),
				   I.dot_long x]
	in I.movl(LA num_lab, R dst_reg) :: C
	end

    (* returns true if boxed representation is used for 
     * integers of the given precision *)
    fun boxedNum (precision:int) : bool = 
      precision > 31 andalso BI.tag_integers()


    (* Find a register for aty and generate code to store into the aty *)
    fun resolve_aty_def(SS.STACK_ATY offset,t:reg,size_ff,C) = 
	 (t,store_indexed(esp,WORDS(size_ff-offset-1),t,C))       (*was ~size_ff+offset*)
      | resolve_aty_def(SS.PHREG_ATY phreg,t:reg,size_ff,C)  = (phreg,C)
      | resolve_aty_def(SS.UNIT_ATY,t:reg,size_ff,C)  = (t,C)
      | resolve_aty_def _ = die "resolve_aty_def: ATY cannot be defined"

    (* Make sure that the aty ends up in register dst_reg *)
    fun move_aty_into_reg(aty,dst_reg,size_ff,C) =
      case aty
	of SS.REG_I_ATY offset => 
	  base_plus_offset(esp,BYTES(size_ff*4-offset*4-4+BI.inf_bit),dst_reg,C)
	 | SS.REG_F_ATY offset =>
	  base_plus_offset(esp,WORDS(size_ff-offset-1),dst_reg,C)
	 | SS.STACK_ATY offset => 
	  load_indexed(dst_reg,esp,WORDS(size_ff-offset-1),C)
	 | SS.DROPPED_RVAR_ATY => C
	 | SS.PHREG_ATY phreg => copy(phreg,dst_reg,C)
	 | SS.INTEGER_ATY i => 
	  if boxedNum (#precision i) then loadNumBoxed(fmtInt i, dst_reg, C)
	  else loadNum(fmtInt i, dst_reg, C)
	 | SS.WORD_ATY w => 
	  if boxedNum (#precision w) then loadNumBoxed(fmtWord w, dst_reg, C)
	  else loadNum(fmtWord w, dst_reg, C)
	 | SS.UNIT_ATY => 
	    if BI.tag_integers() then 
	      load_immed(IMMED(Int32.fromInt BI.ml_unit),dst_reg,C) (* gc needs value! *)
	    else C
	 | SS.FLOW_VAR_ATY _ => die "move_aty_into_reg: FLOW_VAR_ATY cannot be moved"

    (* dst_aty = src_reg *)
    fun move_reg_into_aty(src_reg:reg,dst_aty,size_ff,C) =
      case dst_aty 
	of SS.PHREG_ATY dst_reg => copy(src_reg,dst_reg,C)
	 | SS.STACK_ATY offset => store_indexed(esp,WORDS(size_ff-offset-1),src_reg,C)    (*was ~size_ff+offset*) 
	 | SS.UNIT_ATY => C (* wild card definition - do nothing *)
 	 | _ => die "move_reg_into_aty: ATY not recognized"

    (* dst_aty = src_aty *)
    fun move_aty_to_aty(SS.PHREG_ATY src_reg,dst_aty,size_ff,C) = move_reg_into_aty(src_reg,dst_aty,size_ff,C)
      | move_aty_to_aty(src_aty,SS.PHREG_ATY dst_reg,size_ff,C) = move_aty_into_reg(src_aty,dst_reg,size_ff,C)
      | move_aty_to_aty(src_aty,dst_aty,size_ff,C) = 
      let val (reg_for_result,C') = resolve_aty_def(dst_aty,tmp_reg1,size_ff,C)
      in move_aty_into_reg(src_aty,reg_for_result,size_ff,C')
      end

    (* dst_aty = src_aty[offset] *)
    fun move_index_aty_to_aty(SS.PHREG_ATY src_reg,SS.PHREG_ATY dst_reg,offset:Offset,t:reg,size_ff,C) = 
          load_indexed(dst_reg,src_reg,offset,C)
      | move_index_aty_to_aty(SS.PHREG_ATY src_reg,dst_aty,offset:Offset,t:reg,size_ff,C) = 
	  load_indexed(t,src_reg,offset,
	  move_reg_into_aty(t,dst_aty,size_ff,C))
      | move_index_aty_to_aty(src_aty,dst_aty,offset,t:reg,size_ff,C) = (* can be optimised!! *)
	  move_aty_into_reg(src_aty,t,size_ff,
	  load_indexed(t,t,offset,
	  move_reg_into_aty(t,dst_aty,size_ff,C)))
		   
    (* dst_aty = &lab *)
    fun load_label_addr(lab,dst_aty,t:reg,size_ff,C) = 
      let val (reg_for_result,C') = resolve_aty_def(dst_aty,t,size_ff,C)
      in I.movl(LA lab, R reg_for_result) :: C'
      end

    (* dst_aty = lab[0] *)
    fun load_from_label(lab,dst_aty,t:reg,size_ff,C) =
      let val (reg_for_result,C') = resolve_aty_def(dst_aty,t,size_ff,C)
      in I.movl(L lab, R reg_for_result) :: C'
      end

    (* lab[0] = src_aty *)
    fun store_in_label(SS.PHREG_ATY src_reg,label,tmp1:reg,size_ff,C) =
      I.movl(R src_reg, L label) :: C
      | store_in_label(src_aty,label,tmp1:reg,size_ff,C) =
      move_aty_into_reg(src_aty,tmp1,size_ff,
			I.movl(R tmp1, L label) :: C)

    (* Generate a string label *)
    fun gen_string_lab str =
      let val string_lab = new_string_lab()

	  (* generate a .byte pseudo instuction for each character in
	   * the string and generate a .byte 0 instruction at the end. *)
	  val bytes =  
            foldr(fn (ch, acc) => I.dot_byte (Int.toString(ord ch)) :: acc)
	    [I.dot_byte "0"] (explode str)

	  val _ = add_static_data (I.dot_data ::
				   I.dot_align 4 ::
				   I.lab string_lab ::
				   I.dot_long(BI.pr_tag_w(BI.tag_string(true,size(str)))) ::
				   I.dot_long(Int.toString(size(str))) ::
				   I.dot_long "0" :: (* NULL pointer to next fragment. *)
				   bytes)
      in string_lab
      end

    (* Generate a Data label *)
    fun gen_data_lab lab = add_static_data [I.dot_data,
					    I.dot_align 4,
					    I.lab (DatLab lab),
					    I.dot_long (int_to_string BI.ml_unit)]  (* was "0" but use ml_unit instead for GC 2001-01-09, Niels *)

    (* Can be used to update the stack or a record when the argument is an ATY *)
    (* base_reg[offset] = src_aty *)
    fun store_aty_in_reg_record(SS.PHREG_ATY src_reg,t:reg,base_reg,offset:Offset,size_ff,C) =
          store_indexed(base_reg,offset,src_reg,C)
      | store_aty_in_reg_record(src_aty,t:reg,base_reg,offset:Offset,size_ff,C) =
	  move_aty_into_reg(src_aty,t,size_ff,
	  store_indexed(base_reg,offset,t,C))

    (* Can be used to load from the stack or a record when destination is an ATY *)
    (* dst_aty = base_reg[offset] *)
    fun load_aty_from_reg_record(SS.PHREG_ATY dst_reg,t:reg,base_reg,offset:Offset,size_ff,C) =
          load_indexed(dst_reg,base_reg,offset,C)
      | load_aty_from_reg_record(dst_aty,t:reg,base_reg,offset:Offset,size_ff,C) =
	  load_indexed(t,base_reg,offset,
	  move_reg_into_aty(t,dst_aty,size_ff,C))

    (* base_aty[offset] = src_aty *)
    fun store_aty_in_aty_record(src_aty,base_aty,offset:Offset,t1:reg,t2:reg,size_ff,C) =
      case (src_aty,base_aty) 
	of (SS.PHREG_ATY src_reg,SS.PHREG_ATY base_reg) => store_indexed(base_reg,offset,src_reg,C)
	 | (SS.PHREG_ATY src_reg,base_aty) => move_aty_into_reg(base_aty,t2,size_ff,  (* can be optimised *)
					      store_indexed(t2,offset,src_reg,C))
	 | (src_aty,SS.PHREG_ATY base_reg) => move_aty_into_reg(src_aty,t1,size_ff,
					      store_indexed(base_reg,offset,t1,C))
	 | (src_aty,base_aty) => move_aty_into_reg(src_aty,t1,size_ff, (* can be optimised *)
				 move_aty_into_reg(base_aty,t2,size_ff,
				 store_indexed(t2,offset,t1,C)))
	
    (* push(aty), i.e., esp-=4; esp[0] = aty (different than on hp) *)
    (* size_ff is for esp before esp is moved. *)
    fun push_aty(aty,t:reg,size_ff,C) = 
      let 
	fun default() = move_aty_into_reg(aty,t,size_ff,
			 I.pushl(R t) :: C)
      in case aty
	   of SS.PHREG_ATY aty_reg => I.pushl(R aty_reg) :: C
	    | SS.INTEGER_ATY i => 
	     if boxedNum (#precision i) then default()
	     else I.pushl(I (fmtInt i)) :: C
	    | SS.WORD_ATY w => 
	       if boxedNum (#precision w) then default()
	       else I.pushl(I (fmtWord w)) :: C
	    | _ => default()
      end

    (* pop(aty), i.e., aty=esp[0]; esp+=4 *)
    (* size_ff is for sp after pop *)
    fun pop_aty(SS.PHREG_ATY aty_reg,t:reg,size_ff,C) = I.popl(R aty_reg) :: C
      | pop_aty(aty,t:reg,size_ff,C) = (I.popl(R t) ::
					move_reg_into_aty(t,aty,size_ff,C))

    (* Returns a register with arg and a continuation function. *)
    fun resolve_arg_aty(arg:SS.Aty,t:reg,size_ff:int) : reg * (I.inst list -> I.inst list) =
      case arg
	of SS.PHREG_ATY r => (r, fn C => C)
	 | _ => (t, fn C => move_aty_into_reg(arg,t,size_ff,C))

    (* Push float on float stack *)
    fun push_float_aty(float_aty, t, size_ff) =       
      let val disp = if BI.tag_values() then "8" 
		     else "0"
      in fn C => case float_aty 
		   of SS.PHREG_ATY x => I.fldl(D(disp, x)) :: C
		    | _ => move_aty_into_reg(float_aty,t,size_ff,
			   I.fldl(D(disp, t)) :: C)
      end

    (* Pop float from float stack *)
    fun pop_store_float_reg(base_reg,t:reg,C) =
      if BI.tag_values() then 
	load_immed(IMMED (Word32.toLargeIntX(BI.tag_real false)),t,
	I.movl(R t,D("0",base_reg)) ::
	I.fstpl (D("8",base_reg)) :: C)
      else 
	I.fstpl (D("0",base_reg)) :: C


    (***********************)
    (* Calling C Functions *)
    (***********************)

    fun compile_c_call_prim(name: string,args: SS.Aty list,opt_ret: SS.Aty option,size_ff:int,tmp:reg,C) =
      let
	val (convert: bool,name: string) =
	  case explode name 
	    of #"@" :: rest => (BI.tag_integers(), implode rest)
	     | _ => (false, name)

	fun convert_int_to_c(reg,C) =
	  if convert then I.shrl(I "1", R reg) :: C
	  else C

	fun convert_int_to_ml(reg,C) =
	  if convert then (I.sall(I "1", R reg) ::
			   I.addl(I "1", R reg) :: C)
	  else C

	fun push_arg(aty,size_ff,C) =
	  if convert then
	    move_aty_into_reg(aty,tmp,size_ff,
	    convert_int_to_c(tmp,
	    I.pushl(R tmp) :: C))
	  else push_aty(aty,tmp,size_ff,C)

	(* size_ff increases when new arguments are pushed on the
         * stack!! The arguments are placed on the stack in reverse 
	 * order. *)

	fun push_args (args,C) =
	  let fun loop ([], _) = C
		| loop (aty :: rest, size_ff) = (push_arg(aty,size_ff, 
					         loop (rest, size_ff + 1)))
	  in loop(rev args, size_ff)
	  end

	fun pop_args C = 
	  case List.length args
	    of 0 => C
	     | n => I.addl(I (int_to_string (4*n)), R esp) :: C

	fun store_ret(SOME d,C) = convert_int_to_ml(eax,
				  move_reg_into_aty(eax,d,size_ff,C))
	  | store_ret(NONE,C) = C
      in
	push_args(args,
	I.call(NameLab name) ::
	pop_args(store_ret(opt_ret,C)))
      end

    (**********************)
    (* Garbage Collection *)
    (**********************)

    (* Put a bitvector into the code. *)
    fun gen_bv (ws,C) =
      let fun gen_bv'([],C) = C
	    | gen_bv'(w::ws,C) = gen_bv'(ws,I.dot_long ("0X"^Word32.fmt StringCvt.HEX w)::C)
      in if gc_p() then gen_bv'(ws,C)
	 else C
      end

    (* reg_map is a register map describing live registers at entry to the function       *)
    (* The stub requires reg_map to reside in tmp_reg1 and the return address in tmp_reg0 *)
    fun do_gc(reg_map: Word32.word,size_ccf,size_rcf,size_spilled_region_args,C) =
      if gc_p() then 
	let
	  val l = new_local_lab "return_from_gc_stub"
	  val reg_map_immed = "0X" ^ Word32.fmt StringCvt.HEX reg_map
	  val size_ff = 0 (*dummy*)
	in
	  load_label_addr(time_to_gc_lab,SS.PHREG_ATY tmp_reg1,tmp_reg1,size_ff, (* tmp_reg1 = &gc_flag *)
	  I.movl(D("0",tmp_reg1),R tmp_reg1) ::                       (* tmp_reg1 = gc_flag  *)
	  I.cmpl(I "1", R tmp_reg1) ::
	  I.jne l ::
	  I.movl(I reg_map_immed, R tmp_reg1) ::                    (* tmp_reg1 = reg_map  *)
	  load_label_addr(l,SS.PHREG_ATY tmp_reg0,tmp_reg0,size_ff, (* tmp_reg0 = return address *)
  I.pushl(I (int_to_string size_ccf)) ::
  I.pushl(I (int_to_string size_rcf)) ::
  I.pushl(I (int_to_string size_spilled_region_args)) ::
	  I.jmp(L gc_stub_lab) ::
	  I.lab l :: C))
	end
      else C

    (*********************)
    (* Allocation Points *)
    (*********************)

    (* Status Bits Are Not Cleared! We preserve the value in register t,
     * t may be used in a call to alloc. *)

    fun reset_region(t:reg,tmp:reg,size_ff,C) = 
      let val l = new_local_lab "return_from_alloc"
      in copy(t,tmp_reg1,
         I.pushl(LA l) ::
         I.jmp(L(NameLab "__reset_region")) ::
         I.lab l ::
         copy(tmp_reg1, t, C))
      end

    fun alloc_kill_tmp01(t:reg,n0:int,size_ff,pp:LS.pp,C) =
      let val n = if region_profiling() then n0 + BI.objectDescSizeP 
		  else n0
	  val l = new_local_lab "return_from_alloc"
	  fun post_prof C =
	    if region_profiling() then   (* tmp_reg1 now points at the object descriptor; initialize it *)
	      I.movl(I (int_to_string pp), D("0",tmp_reg1)) ::               (* first word is pp *)
	      I.movl(I (int_to_string n0), D("4",tmp_reg1)) ::               (* second word is object size *)
	      I.leal(D (int_to_string (4*BI.objectDescSizeP), tmp_reg1), R tmp_reg1) :: C  (* make tmp_reg1 point at object *)
	    else C
      in 
	copy(t,tmp_reg1,
	I.pushl(LA l) ::
	load_immed(IMMED (Int32.fromInt n), tmp_reg0, 
	I.jmp(L(NameLab "__allocate")) :: (* assumes args in tmp_reg1 and tmp_reg0; result in tmp_reg1 *)
        I.lab l ::
        post_prof
	(copy(tmp_reg1,t,C))))
      end

    fun set_atbot_bit(dst_reg:reg,C) =
      I.orl(I "2", R dst_reg) :: C
      
    fun clear_atbot_bit(dst_reg:reg,C) =
      I.btrl (I "1", R dst_reg) :: C

    fun set_inf_bit(dst_reg:reg,C) =
      I.orl(I "1", R dst_reg) :: C

    fun set_inf_bit_and_atbot_bit(dst_reg:reg,C) =
      I.orl(I "3", R dst_reg) :: C

    (* move_aty_into_reg_ap differs from move_aty_into_reg in the case where aty is a phreg! *)
    (* We must always make a copy of phreg because we may overwrite status bits in phreg.    *) 
    fun move_aty_into_reg_ap(aty,dst_reg,size_ff,C) =
      case aty 
	of SS.REG_I_ATY offset => base_plus_offset(esp,BYTES(size_ff*4-offset*4-4(*+BI.inf_bit*)),dst_reg,
						   set_inf_bit(dst_reg,C))
	 | SS.REG_F_ATY offset => base_plus_offset(esp,WORDS(size_ff-offset-1),dst_reg,C)
	 | SS.STACK_ATY offset => load_indexed(dst_reg,esp,WORDS(size_ff-offset-1),C)
	 | SS.PHREG_ATY phreg  => copy(phreg,dst_reg, C)
	 | _ => die "move_aty_into_reg_ap: ATY cannot be used to allocate memory"

    fun store_pp_prof (obj_ptr:reg, pp:LS.pp, C) =
      if false (*region_profiling() *) then 
	if pp < 2 then die ("store_pp_prof.pp (" ^ Int.toString pp ^ ") is less than two.")	  
	else I.movl(I(int_to_string pp), D("-8", obj_ptr)) :: C
      else C

    fun alloc_ap_kill_tmp01(sma, dst_reg:reg, n, size_ff, C) =
      case sma 
	of LS.ATTOP_LI(SS.DROPPED_RVAR_ATY,pp) => C
	 | LS.ATTOP_LF(SS.DROPPED_RVAR_ATY,pp) => C
	 | LS.ATTOP_FI(SS.DROPPED_RVAR_ATY,pp) => C
	 | LS.ATTOP_FF(SS.DROPPED_RVAR_ATY,pp) => C
	 | LS.ATBOT_LI(SS.DROPPED_RVAR_ATY,pp) => C
	 | LS.ATBOT_LF(SS.DROPPED_RVAR_ATY,pp) => C
	 | LS.SAT_FI(SS.DROPPED_RVAR_ATY,pp) => C
	 | LS.SAT_FF(SS.DROPPED_RVAR_ATY,pp) => C
	 | LS.IGNORE => C
	 | LS.ATTOP_LI(aty,pp) => move_aty_into_reg_ap(aty,dst_reg,size_ff,
                                   alloc_kill_tmp01(dst_reg,n,size_ff,pp,C))
	 | LS.ATTOP_LF(aty,pp) => move_aty_into_reg_ap(aty,dst_reg,size_ff,
                                   store_pp_prof(dst_reg,pp,C))
	 | LS.ATBOT_LF(aty,pp) => move_aty_into_reg_ap(aty,dst_reg,size_ff,    (* atbot bit not set; its a finite region *)
				   store_pp_prof(dst_reg,pp,C))
	 | LS.ATTOP_FI(aty,pp) => move_aty_into_reg_ap(aty,dst_reg,size_ff,
                                   alloc_kill_tmp01(dst_reg,n,size_ff,pp,C))
	 | LS.ATTOP_FF(aty,pp) => 
	  let val default_lab = new_local_lab "no_alloc"
	  in move_aty_into_reg_ap(aty,dst_reg,size_ff,
	     I.btl(I "0", R dst_reg) :: (* inf bit set? *)
	     I.jnc default_lab ::
	     alloc_kill_tmp01(dst_reg,n,size_ff,pp,
	     I.lab default_lab :: C))
	  end
	 | LS.ATBOT_LI(aty,pp) => 
	  move_aty_into_reg_ap(aty,dst_reg,size_ff,
	  reset_region(dst_reg,tmp_reg0,size_ff,     (* dst_reg is preserved for alloc *)
	  alloc_kill_tmp01(dst_reg,n,size_ff,pp,C)))
	 | LS.SAT_FI(aty,pp) => 
	  let val default_lab = new_local_lab "no_reset"
	  in move_aty_into_reg_ap(aty,dst_reg,size_ff,
	     I.btl(I "1", R dst_reg) ::     (* atbot bit set? *)
             I.jnc default_lab ::
	     reset_region(dst_reg,tmp_reg0,size_ff,
             I.lab default_lab ::         (* dst_reg is preverved over the call *)
	     alloc_kill_tmp01(dst_reg,n,size_ff,pp,C)))
	  end
	 | LS.SAT_FF(aty,pp) => 
	  let val finite_lab = new_local_lab "no_alloc"
	      val attop_lab = new_local_lab "no_reset"
	  in move_aty_into_reg_ap(aty,dst_reg,size_ff,
             I.btl (I "0", R dst_reg) ::  (* inf bit set? *)
             I.jnc finite_lab ::
             I.btl (I "1", R dst_reg) ::  (* atbot bit set? *)
             I.jnc attop_lab ::
	     reset_region(dst_reg,tmp_reg0,size_ff,  (* dst_reg is preserved over the call *)
             I.lab attop_lab ::  
	     alloc_kill_tmp01(dst_reg,n,size_ff,pp,
	     I.lab finite_lab :: C)))
	  end

    (* Set Atbot bits on region variables *)
    fun prefix_sm(sma,dst_reg:reg,size_ff,C) = 
      case sma 
	of LS.ATTOP_LI(SS.DROPPED_RVAR_ATY,pp) => die "prefix_sm: DROPPED_RVAR_ATY not implemented."
	 | LS.ATTOP_LF(SS.DROPPED_RVAR_ATY,pp) => die "prefix_sm: DROPPED_RVAR_ATY not implemented."
	 | LS.ATTOP_FI(SS.DROPPED_RVAR_ATY,pp) => die "prefix_sm: DROPPED_RVAR_ATY not implemented."
	 | LS.ATTOP_FF(SS.DROPPED_RVAR_ATY,pp) => die "prefix_sm: DROPPED_RVAR_ATY not implemented."
	 | LS.ATBOT_LI(SS.DROPPED_RVAR_ATY,pp) => die "prefix_sm: DROPPED_RVAR_ATY not implemented."
	 | LS.ATBOT_LF(SS.DROPPED_RVAR_ATY,pp) => die "prefix_sm: DROPPED_RVAR_ATY not implemented."
	 | LS.SAT_FI(SS.DROPPED_RVAR_ATY,pp) => die "prefix_sm: DROPPED_RVAR_ATY not implemented."
	 | LS.SAT_FF(SS.DROPPED_RVAR_ATY,pp) => die "prefix_sm: DROPPED_RVAR_ATY not implemented."
	 | LS.IGNORE => die "prefix_sm: IGNORE not implemented."
	 | LS.ATTOP_LI(aty,pp) => move_aty_into_reg_ap(aty,dst_reg,size_ff,C)
	 | LS.ATTOP_LF(aty,pp) => move_aty_into_reg_ap(aty,dst_reg,size_ff,C)
	 | LS.ATTOP_FI(aty,pp) => 
	  move_aty_into_reg_ap(aty,dst_reg,size_ff,
	  clear_atbot_bit(dst_reg,C))
	 | LS.ATTOP_FF(aty,pp) => 
	  move_aty_into_reg_ap(aty,dst_reg,size_ff, (* It is necessary to clear atbot bit *)
	  clear_atbot_bit(dst_reg,C))               (* because the region may be infinite *)
	 | LS.ATBOT_LI(SS.REG_I_ATY offset_reg_i,pp) => 
	  base_plus_offset(esp,BYTES(size_ff*4-offset_reg_i*4-4(*+BI.inf_bit+BI.atbot_bit*)),dst_reg,
	  set_inf_bit_and_atbot_bit(dst_reg, C))
	 | LS.ATBOT_LI(aty,pp) => 
	  move_aty_into_reg_ap(aty,dst_reg,size_ff,
	  set_atbot_bit(dst_reg,C))
	 | LS.ATBOT_LF(aty,pp) => move_aty_into_reg_ap(aty,dst_reg,size_ff,C)
	 | LS.SAT_FI(aty,pp) => move_aty_into_reg_ap(aty,dst_reg,size_ff,C)
	 | LS.SAT_FF(aty,pp) => move_aty_into_reg_ap(aty,dst_reg,size_ff,C)

    (* Used to build a region vector *)
    fun store_sm_in_record(sma,tmp:reg,base_reg,offset,size_ff,C) = 
      case sma 
	of LS.ATTOP_LI(SS.DROPPED_RVAR_ATY,pp) => die "store_sm_in_record: DROPPED_RVAR_ATY not implemented."
	 | LS.ATTOP_LF(SS.DROPPED_RVAR_ATY,pp) => die "store_sm_in_record: DROPPED_RVAR_ATY not implemented."
	 | LS.ATTOP_FI(SS.DROPPED_RVAR_ATY,pp) => die "store_sm_in_record: DROPPED_RVAR_ATY not implemented."
	 | LS.ATTOP_FF(SS.DROPPED_RVAR_ATY,pp) => die "store_sm_in_record: DROPPED_RVAR_ATY not implemented."
	 | LS.ATBOT_LI(SS.DROPPED_RVAR_ATY,pp) => die "store_sm_in_record: DROPPED_RVAR_ATY not implemented."
	 | LS.ATBOT_LF(SS.DROPPED_RVAR_ATY,pp) => die "store_sm_in_record: DROPPED_RVAR_ATY not implemented."
	 | LS.SAT_FI(SS.DROPPED_RVAR_ATY,pp) => die "store_sm_in_record: DROPPED_RVAR_ATY not implemented."
	 | LS.SAT_FF(SS.DROPPED_RVAR_ATY,pp) => die "store_sm_in_record: DROPPED_RVAR_ATY not implemented."
	 | LS.IGNORE => die "store_sm_in_record: IGNORE not implemented."
	 | LS.ATTOP_LI(SS.PHREG_ATY phreg,pp) => store_indexed(base_reg,offset,phreg,C)
	 | LS.ATTOP_LI(aty,pp) => move_aty_into_reg_ap(aty,tmp,size_ff,
				  store_indexed(base_reg,offset,tmp,C))
	 | LS.ATTOP_LF(SS.PHREG_ATY phreg,pp) => store_indexed(base_reg,offset,phreg,C)
	 | LS.ATTOP_LF(aty,pp) => move_aty_into_reg_ap(aty,tmp,size_ff,
				  store_indexed(base_reg,offset,tmp,C))
	 | LS.ATTOP_FI(aty,pp) => move_aty_into_reg_ap(aty,tmp,size_ff,
				  clear_atbot_bit(tmp,
				  store_indexed(base_reg,offset,tmp,C)))
	 | LS.ATTOP_FF(aty,pp) => move_aty_into_reg_ap(aty,tmp,size_ff,
				  clear_atbot_bit(tmp,                   (* The region may be infinite *)
				  store_indexed(base_reg,offset,tmp,C))) (* so we clear the atbot bit *)
	 | LS.ATBOT_LI(SS.REG_I_ATY offset_reg_i,pp) => 
	  base_plus_offset(esp,BYTES(size_ff*4-offset_reg_i*4-4(*+BI.inf_bit+BI.atbot_bit*)),tmp,
	  set_inf_bit_and_atbot_bit(tmp,
	  store_indexed(base_reg,offset,tmp,C)))
	 | LS.ATBOT_LI(aty,pp) => 
	  move_aty_into_reg_ap(aty,tmp,size_ff,
	  set_atbot_bit(tmp,
	  store_indexed(base_reg,offset,tmp,C)))
	 | LS.ATBOT_LF(SS.PHREG_ATY phreg,pp) => 
	  store_indexed(base_reg,offset,phreg,C) (* The region is finite so no atbot bit is necessary *)
	 | LS.ATBOT_LF(aty,pp) => 
	  move_aty_into_reg_ap(aty,tmp,size_ff,
	  store_indexed(base_reg,offset,tmp,C))
	 | LS.SAT_FI(SS.PHREG_ATY phreg,pp) => 
	  store_indexed(base_reg,offset,phreg,C) (* The storage bit is already recorded in phreg *)
	 | LS.SAT_FI(aty,pp) => move_aty_into_reg_ap(aty,tmp,size_ff,
		                store_indexed(base_reg,offset,tmp,C))
	 | LS.SAT_FF(SS.PHREG_ATY phreg,pp) => 
	  store_indexed(base_reg,offset,phreg,C) (* The storage bit is already recorded in phreg *)
	 | LS.SAT_FF(aty,pp) => move_aty_into_reg_ap(aty,tmp,size_ff,
			        store_indexed(base_reg,offset,tmp,C))

    fun force_reset_aux_region_kill_tmp0(sma,t:reg,size_ff,C) = 
      case sma 
	of LS.ATBOT_LI(aty,pp) => move_aty_into_reg_ap(aty,t,size_ff,
				  reset_region(t,tmp_reg0,size_ff,C))
	 | LS.SAT_FI(aty,pp) => move_aty_into_reg_ap(aty,t,size_ff, (* We do not check the storage mode *)
			        reset_region(t,tmp_reg0,size_ff,C))
	 | LS.SAT_FF(aty,pp) => 
	  let val default_lab = new_local_lab "no_reset"
	  in move_aty_into_reg_ap(aty,t,size_ff, (* We check the inf bit but not the storage mode *)
             I.btl(I "0", R t) ::                (* Is region infinite? kill tmp_reg0. *)
             I.jnc default_lab :: 
	     reset_region(t,tmp_reg0,size_ff,
             I.lab default_lab :: C))
	  end
	 | _ => C

      fun maybe_reset_aux_region_kill_tmp0(sma,t:reg,size_ff,C) = 
	case sma 
	  of LS.ATBOT_LI(aty,pp) => move_aty_into_reg_ap(aty,t,size_ff,
 			            reset_region(t,tmp_reg0,size_ff,C))
	   | LS.SAT_FI(aty,pp) => 
	    let val default_lab = new_local_lab "no_reset"
	    in move_aty_into_reg_ap(aty,t,size_ff,
	       I.btl(I "1", R t) :: (* Is storage mode atbot? kill tmp_reg0. *)
	       I.jnc default_lab ::
	       reset_region(t,tmp_reg0,size_ff,
               I.lab default_lab :: C))
	    end
	   | LS.SAT_FF(aty,pp) => 
	    let val default_lab = new_local_lab "no_reset"
	    in move_aty_into_reg_ap(aty,t,size_ff,
               I.btl (I "0", R t) ::  (* Is region infinite? *)
               I.jnc default_lab :: 
               I.btl (I "1", R t) ::  (* Is atbot bit set? *)
               I.jnc default_lab ::
	       reset_region(t,tmp_reg0,size_ff,
               I.lab default_lab :: C))
	    end
	   | _ => C

      (* Compile Switch Statements *)
      local
	fun new_label str = new_local_lab str
	fun label(lab,C) = I.lab lab :: C
	fun jmp(lab,C) = I.jmp(L lab) :: rem_dead_code C
      in
	fun binary_search(sels,
			  default,
			  opr: I.ea,
			  compile_insts,
			  toInt : 'a -> Int32.int,
			  C) =
	  let
	    val sels = map (fn (i,e) => (toInt i, e)) sels
	    fun if_not_equal_go_lab (lab,i,C) = I.cmpl(I (intToStr i),opr) :: I.jne lab :: C
	    fun if_less_than_go_lab (lab,i,C) = I.cmpl(I (intToStr i),opr) :: I.jl lab :: C
	    fun if_greater_than_go_lab (lab,i,C) = I.cmpl(I (intToStr i),opr) :: I.jg lab :: C
	  in
	    if jump_tables then
	      JumpTables.binary_search_new
	      (sels,
	       default,
	       comment,
	       new_label,
	       if_not_equal_go_lab,
	       if_less_than_go_lab,
	       if_greater_than_go_lab,
	       compile_insts,
	       label,
	       jmp,
	       fn (sel1,sel2) => Int32.abs(sel1-sel2), (* sel_dist *)
	       fn (lab,sel,C) => (I.movl(opr, R tmp_reg0) ::
				  I.sall(I "2", R tmp_reg0) ::
				  I.jmp(D(intToStr(~4*sel) ^ "+" ^ I.pr_lab lab, tmp_reg0)) :: 
                                  rem_dead_code C),
	       fn (lab,C) => I.dot_long (I.pr_lab lab) :: C, (*add_label_to_jump_tab*)
	       I.eq_lab,
	       C)
	    else
	      JumpTables.linear_search_new(sels,
					   default,
					   comment,
					   new_label,
					   if_not_equal_go_lab,
					   compile_insts,
					   label,jmp,C)
	  end
      end

      (* Compile switches on constructors, integers, and words *)
      fun compileNumSwitch {size_ff,size_ccf,CG_lss,toInt,opr_aty,oprBoxed,sels,default,C} =
	let 
	  val (opr_reg, F) = 
	    case opr_aty
	      of SS.PHREG_ATY r => (r, fn C => C)
	       | _ => (tmp_reg1, fn C => move_aty_into_reg(opr_aty,tmp_reg1,size_ff, C))
	  val opr = if oprBoxed then D("4", opr_reg)   (* boxed representation of nums *)
		    else R opr_reg                     (* unboxed representation of nums *)
	in
	  F (binary_search(sels,
			   default,
			   opr,
			   fn (lss,C) => CG_lss(lss,size_ff,size_ccf,C), (* compile_insts *)
			   toInt,
			   C))
	end


      fun cmpi_kill_tmp01 {box} (jump,x,y,d,size_ff,C) = 
	let val (x_reg,x_C) = resolve_arg_aty(x,tmp_reg0,size_ff)
	    val (y_reg,y_C) = resolve_arg_aty(y,tmp_reg1,size_ff)
	    val (d_reg,C') = resolve_aty_def(d,tmp_reg0,size_ff,C)
            val true_lab = new_local_lab "true"
            val cont_lab = new_local_lab "cont"
	    fun compare C = 
	      if box then
		I.movl(D("4",y_reg), R tmp_reg1) ::
		I.movl(D("4",x_reg), R tmp_reg0) ::
		I.cmpl(R tmp_reg1, R tmp_reg0) :: C
	      else I.cmpl(R y_reg, R x_reg) :: C
	in
	   x_C(
	   y_C(
	   compare (
	   jump true_lab ::
	   I.movl(I (int_to_string BI.ml_false), R d_reg) ::
	   I.jmp(L cont_lab) ::         
	   I.lab true_lab ::
	   I.movl(I (int_to_string BI.ml_true), R d_reg) ::
	   I.lab cont_lab :: C')))
	end

      fun cmpi_and_jmp_kill_tmp01(jump,x,y,lab_t,lab_f,size_ff,C) = 
	let
	  val (x_reg,x_C) = resolve_arg_aty(x,tmp_reg0,size_ff)
	  val (y_reg,y_C) = resolve_arg_aty(y,tmp_reg1,size_ff)
	in
	  x_C(y_C(
	  I.cmpl(R y_reg, R x_reg) ::
	  jump lab_t ::
          I.jmp (L lab_f) :: rem_dead_code C))
	end

      (* version with boxed arguments; assume tagging is enabled *)
      fun cmpbi_and_jmp_kill_tmp01(jump,x,y,lab_t,lab_f,size_ff,C) = 
	if BI.tag_integers() then
	  let val (x_reg,x_C) = resolve_arg_aty(x,tmp_reg0,size_ff)
	      val (y_reg,y_C) = resolve_arg_aty(y,tmp_reg1,size_ff)
	  in
	    x_C(y_C(
	    I.movl(D("4", y_reg), R tmp_reg1) ::
	    I.movl(D("4", x_reg), R tmp_reg0) ::
	    I.cmpl(R tmp_reg1, R tmp_reg0) ::
	    jump lab_t ::
            I.jmp (L lab_f) :: rem_dead_code C))
	  end
	else die "cmpbi_and_jmp_kill_tmp01: tagging disabled!"

      fun jump_overflow C = I.jo (NameLab "__raise_overflow") :: C

      fun sub_num_kill_tmp01 {ovf : bool, tag: bool} (x,y,d,size_ff,C) =
	let val (x_reg,x_C) = resolve_arg_aty(x,tmp_reg0,size_ff)
	    val (y_reg,y_C) = resolve_arg_aty(y,tmp_reg1,size_ff)
	    val (d_reg,C') = resolve_aty_def(d,tmp_reg0,size_ff,C)
	    fun check_ovf C = if ovf then jump_overflow C else C
	    fun do_tag C = if tag then I.addl(I "1",R d_reg) :: check_ovf C   (* check twice *)
			   else C
	in
	  x_C(y_C(
          copy(y_reg, tmp_reg1,
	  copy(x_reg, d_reg,
          I.subl(R tmp_reg1, R d_reg) ::
	  check_ovf (do_tag C')))))
	end
  
      fun add_num_kill_tmp01 {ovf,tag} (x,y,d,size_ff,C) =
	let val (x_reg,x_C) = resolve_arg_aty(x,tmp_reg0,size_ff)
	    val (y_reg,y_C) = resolve_arg_aty(y,tmp_reg1,size_ff)
	    val (d_reg,C') = resolve_aty_def(d,tmp_reg0,size_ff,C)
	    fun check_ovf C = if ovf then jump_overflow C else C
	    fun do_tag C = if tag then I.addl(I "-1", R d_reg) :: check_ovf C
			   else C
	in x_C(y_C(
           copy(y_reg, tmp_reg1,
           copy(x_reg, d_reg,
           I.addl(R tmp_reg1, R d_reg) ::
	   check_ovf (do_tag C')))))
	end

      fun mul_num_kill_tmp01 {ovf,tag} (x,y,d,size_ff,C) = 
	let val (x_reg,x_C) = resolve_arg_aty(x,tmp_reg0,size_ff)
	    val (y_reg,y_C) = resolve_arg_aty(y,tmp_reg1,size_ff)
	    val (d_reg,C') = resolve_aty_def(d,tmp_reg0,size_ff,C)
	    fun check_ovf C = if ovf then jump_overflow C else C
	in x_C(y_C(
           copy(y_reg, tmp_reg1,
           copy(x_reg, d_reg,
	   if tag then (* A[i*j] = 1 + (A[i] >> 1) * (A[j]-1) *)
		I.sarl(I "1", R d_reg) ::
		I.subl(I "1", R tmp_reg1) ::
		I.imull(R tmp_reg1, R d_reg) ::
                check_ovf (
		I.addl(I "1", R d_reg) :: 
                check_ovf C')
	   else 
		I.imull(R tmp_reg1, R d_reg) :: 
                check_ovf C'))))
	end

      fun neg_int_kill_tmp0 {tag} (x,d,size_ff,C) =
	let val (x_reg,x_C) = resolve_arg_aty(x,tmp_reg0,size_ff)
	    val (d_reg,C') = resolve_aty_def(d,tmp_reg0,size_ff,C)
	    fun do_tag C = if tag then I.addl(I "2", R d_reg) :: jump_overflow C else C
	in x_C(copy(x_reg, d_reg,
	   I.negl (R d_reg) :: 
           jump_overflow (
	   do_tag C')))
	end

      fun neg_int32b_kill_tmp0 (b,x,d,size_ff,C) =
	if not(BI.tag_integers()) then die "neg_int32b_kill_tmp0.tagging required"
	else 
	  let val (x_reg,x_C) = resolve_arg_aty(x,tmp_reg0,size_ff)
	    val (d_reg,C') = resolve_aty_def(d,tmp_reg1,size_ff,C)
	  in x_C(
	     load_indexed(tmp_reg0,x_reg,WORDS 1,
	     I.negl(R tmp_reg0) ::
             jump_overflow (
             move_aty_into_reg(b,d_reg,size_ff,
             store_indexed(d_reg,WORDS 1, tmp_reg0,                                       (* store negated value *)
             load_immed(IMMED(Word32.toLargeIntX (BI.tag_word_boxed false)),tmp_reg0,     (* mk tag *)
	     store_indexed(d_reg, WORDS 0, tmp_reg0, C')))))))                            (* store tag *)
	  end

     fun abs_int_kill_tmp0 {tag} (x,d,size_ff,C) =
       let val cont_lab = new_local_lab "cont"
	   val (x_reg,x_C) = resolve_arg_aty(x,tmp_reg0,size_ff)
	   val (d_reg,C') = resolve_aty_def(d,tmp_reg0,size_ff, C)
	   fun do_tag C = if tag then I.addl(I "2", R d_reg) :: jump_overflow C else C
       in
	 x_C(copy(x_reg,d_reg,
	 I.cmpl(I "0", R d_reg) ::
         I.jge cont_lab ::
         I.negl (R d_reg) ::  
         jump_overflow (
         do_tag (
         I.lab cont_lab :: C'))))
       end


     fun abs_int32b_kill_tmp0 (b,x,d,size_ff,C) =
       let val cont_lab = new_local_lab "cont"
	   val (x_reg,x_C) = resolve_arg_aty(x,tmp_reg0,size_ff)
	   val (d_reg,C') = resolve_aty_def(d,tmp_reg1,size_ff, C)
       in
	 x_C(
	 load_indexed(tmp_reg0,x_reg,WORDS 1,
	 I.cmpl(I "0", R tmp_reg0) ::
         I.jge cont_lab ::
         I.negl (R tmp_reg0) ::  
         jump_overflow (
         I.lab cont_lab :: 
         move_aty_into_reg(b,d_reg,size_ff,
         store_indexed(d_reg, WORDS 1, tmp_reg0,                                      (* store negated value *)
         load_immed(IMMED(Word32.toLargeIntX (BI.tag_word_boxed false)),tmp_reg0,     (* mk tag *)
         store_indexed(d_reg, WORDS 0, tmp_reg0, C')))))))                            (* store tag *)
       end

     fun word32ub_to_int32ub(x,d,size_ff,C) =
       let
	   val (x_reg,x_C) = resolve_arg_aty(x,tmp_reg0,size_ff)
	   val (d_reg,C') = resolve_aty_def(d,tmp_reg0,size_ff, C)
       in x_C(copy(x_reg, d_reg,
		   I.btl(I "31", R d_reg) ::     (* sign bit set? *)
		   I.jc (NameLab "__raise_overflow") :: C'))
       end

     fun num31_to_num32ub(x,d,size_ff,C) =
       let val (x_reg,x_C) = resolve_arg_aty(x,tmp_reg0,size_ff)
	   val (d_reg,C') = resolve_aty_def(d,tmp_reg0,size_ff, C)
       in x_C(copy(x_reg, d_reg, I.sarl (I "1", R d_reg) :: C'))
       end       

     fun num32_to_num31 {boxedarg,ovf} (x,d,size_ff,C) =
       let
	   val (x_reg,x_C) = resolve_arg_aty(x,tmp_reg0,size_ff)
	   val (d_reg,C') = resolve_aty_def(d,tmp_reg0,size_ff, C)
	   fun maybe_unbox C = if boxedarg then load_indexed(d_reg,x_reg,WORDS 1,C)
			       else copy(x_reg,d_reg,C)
	   fun check_ovf C = if ovf then jump_overflow C else C
       in x_C(
          maybe_unbox(
	  I.imull(I "2", R d_reg) ::
	  check_ovf (
          I.addl(I "1", R d_reg) :: C')))   (* No need to check for overflow after adding 1; the
					     * intermediate result is even (after multiplying 
					     * with 2) so adding one cannot give Overflow because the
					     * largest integer is odd! mael 2001-04-29 *)
       end

     fun bin_float_op_kill_tmp01 finst (x,y,b,d,size_ff,C) =
       let val x_C = push_float_aty(x, tmp_reg0, size_ff)
	   val y_C = push_float_aty(y, tmp_reg0, size_ff)
	   val (b_reg, b_C) = resolve_arg_aty(b, tmp_reg0, size_ff)
	   val (d_reg, C') = resolve_aty_def(d, tmp_reg0, size_ff, C)
       in
	 y_C(x_C(finst ::
	 b_C(pop_store_float_reg(b_reg,tmp_reg1,
	 copy(b_reg,d_reg, C')))))
       end

     fun addf_kill_tmp01 a = bin_float_op_kill_tmp01 I.faddp a
     fun subf_kill_tmp01 a = bin_float_op_kill_tmp01 I.fsubp a
     fun mulf_kill_tmp01 a = bin_float_op_kill_tmp01 I.fmulp a
     fun divf_kill_tmp01 a = bin_float_op_kill_tmp01 I.fdivp a

     fun unary_float_op_kill_tmp01 finst (b,x,d,size_ff,C) =
       let val x_C = push_float_aty(x, tmp_reg0, size_ff)
	   val (b_reg, b_C) = resolve_arg_aty(b, tmp_reg0, size_ff)
	   val (d_reg, C') = resolve_aty_def(d, tmp_reg0, size_ff, C)
       in
	 x_C(finst ::
	 b_C(pop_store_float_reg(b_reg,tmp_reg1,
	 copy(b_reg,d_reg, C'))))
       end

     fun negf_kill_tmp01 a = unary_float_op_kill_tmp01 I.fchs a
     fun absf_kill_tmp01 a = unary_float_op_kill_tmp01 I.fabs a

     datatype cond = LESSTHAN | LESSEQUAL | GREATERTHAN | GREATEREQUAL
 
     fun cmpf_kill_tmp01 (cond,x,y,d,size_ff,C) =
       let val x_C = push_float_aty(x, tmp_reg0, size_ff)
	   val y_C = push_float_aty(y, tmp_reg0, size_ff)
	   val (d_reg, C') = resolve_aty_def(d, tmp_reg0, size_ff, C)
           val true_lab = new_local_lab "true"
           val cont_lab = new_local_lab "cont"
           val (mlTrue, mlFalse, cond_code, jump, push_args) = (* from gcc experiments *)
	     case cond             
	       of LESSTHAN => (BI.ml_true, BI.ml_false, "69", I.je, x_C o y_C)
		| LESSEQUAL => (BI.ml_true, BI.ml_false, "5", I.je, x_C o y_C)
		| GREATERTHAN => (BI.ml_false, BI.ml_true, "69", I.jne, y_C o x_C)
		| GREATEREQUAL => (BI.ml_false, BI.ml_true, "5", I.jne, y_C o x_C)
       in
	 push_args(I.fcompp :: 
         I.movl(R eax, R tmp_reg1) ::  (* save eax *) 
         I.fnstsw ::
         I.andb(I cond_code, R ah) ::
	 I.movl(R tmp_reg1, R eax) ::   (* restore eax *)
	 jump true_lab ::
         I.movl(I (int_to_string mlFalse), R d_reg) ::
         I.jmp(L cont_lab) ::         
         I.lab true_lab ::
         I.movl(I (int_to_string mlTrue), R d_reg) ::
         I.lab cont_lab :: 
         C')
       end

     fun bin_op_kill_tmp01 inst (x,y,d,size_ff,C) =
       let val (x_reg,x_C) = resolve_arg_aty(x,tmp_reg0,size_ff)
	   val (y_reg,y_C) = resolve_arg_aty(y,tmp_reg1,size_ff)
	   val (d_reg,C') = resolve_aty_def(d,tmp_reg0,size_ff,C)
       in
	 x_C(y_C(
	 copy(y_reg, tmp_reg1,
	 copy(x_reg, d_reg,
         inst(R tmp_reg1, R d_reg) :: C'))))
       end

     (* andb and orb are the same for 31 bit (tagged) and 
      * 32 bit (untagged) representations *)
     fun andb_word_kill_tmp01 a = bin_op_kill_tmp01 I.andl a   (* A[x&y] = A[x] & A[y]  tagging *)
     fun orb_word_kill_tmp01 a = bin_op_kill_tmp01 I.orl a     (* A[x|y] = A[x] | A[y]  tagging *)

     (* xorb needs to set the lowest bit for the 31 bit (tagged) version *) 
     fun xorb_word_kill_tmp01 {tag} (x,y,d,size_ff,C) =
       let val (x_reg,x_C) = resolve_arg_aty(x,tmp_reg0,size_ff)
	   val (y_reg,y_C) = resolve_arg_aty(y,tmp_reg1,size_ff)
	   val (d_reg,C') = resolve_aty_def(d,tmp_reg0,size_ff,C)
	   fun do_tag C = if tag then I.orl(I "1", R d_reg) :: C else C
       in
	 x_C(y_C(
	 copy(y_reg, tmp_reg1,
	 copy(x_reg, d_reg,
         I.xorl(R tmp_reg1, R d_reg) :: 
	 do_tag C'))))
       end

     fun bin_op_w32boxed__ {ovf} inst (r,x,y,d,size_ff,C) = (* Only used when tagging is enabled; Word32.sml *)
       if not(BI.tag_integers()) then die "bin_op_w32boxed__.tagging_disabled"
       else 
	 let val (x_reg,x_C) = resolve_arg_aty(x,tmp_reg0,size_ff)
	     val (y_reg,y_C) = resolve_arg_aty(y,tmp_reg1,size_ff)
	     val (d_reg,C') = resolve_aty_def(d,tmp_reg0,size_ff,C)
	     fun check_ovf C = if ovf then jump_overflow C else C
	 in
	   x_C(
	   load_indexed(tmp_reg0,x_reg,WORDS 1,
	   y_C(
	   load_indexed(tmp_reg1,y_reg,WORDS 1,
	   inst(R tmp_reg0, R tmp_reg1) ::
           check_ovf (
	   move_aty_into_reg(r,d_reg,size_ff,
	   store_indexed(d_reg,WORDS 1,tmp_reg1,
	   load_immed(IMMED(Word32.toLargeIntX (BI.tag_word_boxed false)),tmp_reg1,
	   store_indexed(d_reg,WORDS 0, tmp_reg1,C')))))))))
	 end

     fun addw32boxed(r,x,y,d,size_ff,C) = (* Only used when tagging is enabled; Word32.sml *)
       bin_op_w32boxed__ {ovf=false} I.addl (r,x,y,d,size_ff,C)

     fun subw32boxed(r,x,y,d,size_ff,C) = (* Only used when tagging is enabled; Word32.sml *)
       bin_op_w32boxed__ {ovf=false} I.subl (r,y,x,d,size_ff,C) (* x and y swapped, see spec for subl *)

     fun mulw32boxed(r,x,y,d,size_ff,C) = (* Only used when tagging is enabled; Word32.sml *)
       bin_op_w32boxed__ {ovf=false} I.imull (r,x,y,d,size_ff,C)

     fun orw32boxed__ (r,x,y,d,size_ff,C) = (* Only used when tagging is enabled; Word32.sml *)
       bin_op_w32boxed__ {ovf=false} I.orl (r,x,y,d,size_ff,C)

     fun andw32boxed__ (r,x,y,d,size_ff,C) = (* Only used when tagging is enabled; Word32.sml *)
       bin_op_w32boxed__ {ovf=false} I.andl (r,x,y,d,size_ff,C)

     fun xorw32boxed__ (r,x,y,d,size_ff,C) = (* Only used when tagging is enabled; Word32.sml *)
       bin_op_w32boxed__ {ovf=false} I.xorl (r,x,y,d,size_ff,C)

     fun mul_int32b (b,x,y,d,size_ff,C) =
       bin_op_w32boxed__ {ovf=true} I.imull (b,x,y,d,size_ff,C)
	 
     fun sub_int32b (b,x,y,d,size_ff,C) =
       bin_op_w32boxed__ {ovf=true} I.subl (b,y,x,d,size_ff,C)

     fun add_int32b (b,x,y,d,size_ff,C) =
       bin_op_w32boxed__ {ovf=true} I.addl (b,x,y,d,size_ff,C)

     fun num31_to_num32b(b,x,d,size_ff,C) =   (* a boxed word is tagged as a scalar record *)
       if BI.tag_integers() then 
	 let val (d_reg,C') = resolve_aty_def(d,tmp_reg1,size_ff,C)
	 in
	   move_aty_into_reg(x,tmp_reg0,size_ff,
	   I.sarl(I "1", R tmp_reg0) :: 
	   move_aty_into_reg(b,d_reg,size_ff,
	   store_indexed(d_reg,WORDS 1,tmp_reg0,
	   load_immed(IMMED(Word32.toLargeIntX (BI.tag_word_boxed false)),tmp_reg0,
	   store_indexed(d_reg,WORDS 0,tmp_reg0, C')))))
	 end	 
       else die "num31_to_num32b.tagging_disabled"

     fun num32b_to_num32b {ovf:bool} (b,x,d,size_ff,C) =
       if not(BI.tag_integers()) then die "num32b_to_num32b.tagging_disabled"
       else 
	 let val (x_reg,x_C) = resolve_arg_aty(x,tmp_reg0,size_ff)
	     val (d_reg,C') = resolve_aty_def(d,tmp_reg1,size_ff, C)
	     fun check_ovf C = 
	       if ovf then
		 I.btl(I "31", R tmp_reg0) ::     (* sign bit set? *)
		 I.jc (NameLab "__raise_overflow") :: C
	       else C
	 in 
	   x_C (
           load_indexed(tmp_reg0,x_reg,WORDS 1,
	   check_ovf (
	   move_aty_into_reg(b,d_reg,size_ff,
	   store_indexed(d_reg, WORDS 1, tmp_reg0, 
	   load_immed(IMMED(Word32.toLargeIntX (BI.tag_word_boxed false)),tmp_reg0,
	   store_indexed(d_reg, WORDS 0, tmp_reg0, C')))))))
	 end

     fun shift_w32boxed__ inst (r,x,y,d,size_ff,C) = 
       if not(BI.tag_integers()) then die "shift_w32boxed__.tagging is not enabled as required"
       else
       (* y is unboxed and tagged *)
       let val (x_reg,x_C) = resolve_arg_aty(x,tmp_reg1,size_ff)
	   val (y_reg,y_C) = resolve_arg_aty(y,tmp_reg0,size_ff)
	   val (d_reg,C') = resolve_aty_def(d,tmp_reg0,size_ff,C)
       in
	 x_C(
	 load_indexed(tmp_reg1,x_reg,WORDS 1,
         y_C(
         copy(y_reg,ecx,                        (* tmp_reg0 = ecx, see InstsX86.sml *)
	 I.sarl (I "1", R ecx) ::               (* untag y: y >> 1 *)
         inst(R cl, R tmp_reg1) ::
	 move_aty_into_reg(r,d_reg,size_ff,
         store_indexed(d_reg,WORDS 1,tmp_reg1,
         load_immed(IMMED(Word32.toLargeIntX (BI.tag_word_boxed false)),tmp_reg1,
	 store_indexed(d_reg,WORDS 0, tmp_reg1, C'))))))))
       end

     fun shift_leftw32boxed__(r,x,y,d,size_ff,C) = (* Only used when tagging is enablen; Word32.sml *)
       shift_w32boxed__ I.sall (r,x,y,d,size_ff,C)

     fun shift_right_signedw32boxed__(r,x,y,d,size_ff,C) = (* Only used when tagging is enablen; Word32.sml *)
       shift_w32boxed__ I.sarl (r,x,y,d,size_ff,C)

     fun shift_right_unsignedw32boxed__(r,x,y,d,size_ff,C) = (* Only used when tagging is enablen; Word32.sml *)
       shift_w32boxed__ I.shrl (r,x,y,d,size_ff,C)

     fun shift_left_word_kill_tmp01 {tag} (x,y,d,size_ff,C) =  (*tmp_reg0 = %ecx*)
       let val (x_reg,x_C) = resolve_arg_aty(x,tmp_reg1,size_ff)
	   val (y_reg,y_C) = resolve_arg_aty(y,tmp_reg0,size_ff)
	   val (d_reg,C') = resolve_aty_def(d,tmp_reg1,size_ff,C)
	   (* y is represented tagged only when BI.tag_integers() is true *)
	   fun untag_y C = if BI.tag_integers() then I.sarl (I "1", R ecx) :: C     (* y >> 1 *)
			   else C
       in 
	 if tag then                     (* 1 + ((x - 1) << (y >> 1)) *)
	   x_C(y_C(
	   copy(y_reg, ecx,
           copy(x_reg, d_reg,
	   I.decl (R d_reg) ::           (* x - 1  *)
	   untag_y (                     (* y >> 1 *)
	   I.sall (R cl, R d_reg) ::     (*   <<   *)
	   I.incl (R d_reg) :: C')))))   (* 1 +    *)
	 else
	   x_C(y_C(         
	   copy(y_reg, ecx,
           copy(x_reg, d_reg,
           I.sall(R cl, R d_reg) :: C'))))
       end

     fun shift_right_signed_word_kill_tmp01 {tag} (x,y,d,size_ff,C) =  (*tmp_reg0 = %ecx*)
       let val (x_reg,x_C) = resolve_arg_aty(x,tmp_reg1,size_ff)
	   val (y_reg,y_C) = resolve_arg_aty(y,tmp_reg0,size_ff)
	   val (d_reg,C') = resolve_aty_def(d,tmp_reg1,size_ff,C)
	   (* y is represented tagged only when BI.tag_integers() is true *)
	   fun untag_y C = if BI.tag_integers() then I.sarl (I "1", R ecx) :: C     (* y >> 1 *)
			   else C
       in 
	 if tag then                         (* 1 | ((x) >> (y >> 1)) *)
	   x_C(y_C(         
 	   copy(y_reg, ecx,
	   copy(x_reg, d_reg,
	   untag_y (                         (* y >> 1 *)
           I.sarl (R cl,R d_reg) ::          (* x >>   *)
	   I.orl (I "1", R d_reg) :: C'))))) (* 1 |    *)
	 else
	   x_C(y_C(         
 	   copy(y_reg, ecx,
	   copy(x_reg, d_reg,
           I.sarl(R cl, R d_reg) :: C'))))
       end

     fun shift_right_unsigned_word_kill_tmp01 {tag} (x,y,d,size_ff,C) =  (*tmp_reg0 = %ecx*)
       let val (x_reg,x_C) = resolve_arg_aty(x,tmp_reg1,size_ff)
	   val (y_reg,y_C) = resolve_arg_aty(y,tmp_reg0,size_ff)
	   val (d_reg,C') = resolve_aty_def(d,tmp_reg1,size_ff,C)
	   (* y is represented tagged only when BI.tag_integers() is true *)
	   fun untag_y C = if BI.tag_integers() then I.sarl (I "1", R ecx) :: C     (* y >> 1 *)
			   else C
       in 
	 if tag then                         (* 1 | ((unsigned long)(x) >> (y >> 1)) *)
	   x_C(y_C(         
 	   copy(y_reg, ecx,
	   copy(x_reg, d_reg,
	   untag_y (                         (* y >> 1                *)
           I.shrl (R cl,R d_reg) ::          (* (unsigned long)x >>   *)
	   I.orl (I "1", R d_reg) :: C'))))) (* 1 |                   *)
	 else
	   x_C(y_C(         
 	   copy(y_reg, ecx,
	   copy(x_reg, d_reg,
           I.shrl(R cl, R d_reg) :: C'))))
       end

     (*******************)
     (* Code Generation *)
     (*******************)

     (* printing an assignment *)
     fun debug_assign(str,C) = C
(*      if Flags.is_on "debug_codeGen" then
      let
	val string_lab = gen_string_lab (str ^ "\n")
      in
	COMMENT "Start of Debug Assignment" ::
	load_label_addr_kill_gen1(string_lab,SS.PHREG_ATY arg0,0,
			compile_c_call_prim("printString",[SS.PHREG_ATY arg0],NONE,0,tmp_reg0 (*not used*),
					    COMMENT "End of Debug Assignment" :: C))
      end
      else C*)

     fun CG_lss(lss,size_ff,size_ccf,C) =
       let
	 fun pr_ls ls = LS.pr_line_stmt SS.pr_sty SS.pr_offset SS.pr_aty true ls
	 fun CG_ls(ls,C) = 
	   (case ls 
	      of LS.ASSIGN{pat=SS.FLOW_VAR_ATY(lv,lab_t,lab_f),
			   bind=LS.CON0{con,con_kind,aux_regions=[],alloc=LS.IGNORE}} =>
		if Con.eq(con,Con.con_TRUE) then I.jmp(L(LocalLab lab_t)) :: rem_dead_code C		 
		else 
		  if Con.eq(con,Con.con_FALSE) then I.jmp(L(LocalLab lab_f)) :: rem_dead_code C
		  else die "CG_lss: unmatched assign on flow variable"
               | LS.ASSIGN{pat,bind} =>
		debug_assign(""(*pr_ls ls*),
		comment_fn (fn () => "ASSIGN: " ^ pr_ls ls, 
		(case bind 
		   of LS.ATOM src_aty => move_aty_to_aty(src_aty,pat,size_ff,C)
		    | LS.LOAD label => load_from_label(DatLab label,pat,tmp_reg1,size_ff,C)
		    | LS.STORE(src_aty,label) => 
		     (gen_data_lab label;
		      store_in_label(src_aty,DatLab label,tmp_reg1,size_ff,C))
		    | LS.STRING str =>
		     let val string_lab = gen_string_lab str
		     in load_label_addr(string_lab,pat,tmp_reg1,size_ff,C)
		     end
		    | LS.REAL str => 
		     let val float_lab = new_float_lab()
		         val _ = 
			   if BI.tag_values() then 
			     add_static_data [I.dot_data,
					      I.dot_align 8,
					      I.lab float_lab,
					      I.dot_long(BI.pr_tag_w(BI.tag_real(true))),
					      I.dot_long "0", (* dummy *)
					      I.dot_double str]
			   else
			     add_static_data [I.dot_data,
					      I.dot_align 8,
					      I.lab float_lab,
					      I.dot_double str]
		     in load_label_addr(float_lab,pat,tmp_reg1,size_ff,C)
		     end
		    | LS.CLOS_RECORD{label,elems=elems as (lvs,excons,rhos),alloc} => 
		     let val (reg_for_result,C') = resolve_aty_def(pat,tmp_reg1,size_ff,C)
		         val num_elems = List.length (LS.smash_free elems)
		         val n_skip = length rhos + 1 (* We don't traverse region pointers,
						       * i.e. we skip rhos+1 fields *)
		     in
		       if BI.tag_values() then
			 alloc_ap_kill_tmp01(alloc,reg_for_result,num_elems+2,size_ff,
       		         load_immed(IMMED(Word32.toLargeIntX(BI.tag_clos(false,num_elems+1,n_skip))),tmp_reg0,
			 store_indexed(reg_for_result,WORDS 0,tmp_reg0,
			 load_label_addr(MLFunLab label,SS.PHREG_ATY tmp_reg0,tmp_reg0,size_ff,
			 store_indexed(reg_for_result,WORDS 1,tmp_reg0,
			 #2(foldr (fn (aty,(offset,C)) => 
				   (offset-1,store_aty_in_reg_record(aty,tmp_reg0,reg_for_result,
								     WORDS offset,size_ff, C))) 
			    (num_elems+1,C') (LS.smash_free elems)))))))
		       else
			 alloc_ap_kill_tmp01(alloc,reg_for_result,num_elems+1,size_ff,
			 load_label_addr(MLFunLab label,SS.PHREG_ATY tmp_reg0,tmp_reg0,size_ff,
			 store_indexed(reg_for_result,WORDS 0,tmp_reg0,
			 #2(foldr (fn (aty,(offset,C)) => 
				   (offset-1,store_aty_in_reg_record(aty,tmp_reg0,reg_for_result,
								     WORDS offset,size_ff, C))) 
			    (num_elems,C') (LS.smash_free elems)))))
		     end
		    | LS.REGVEC_RECORD{elems,alloc} =>
		     let val (reg_for_result,C') = resolve_aty_def(pat,tmp_reg1,size_ff,C)
		         val num_elems = List.length elems
		     in 
		       if BI.tag_values() then
			 alloc_ap_kill_tmp01(alloc,reg_for_result,num_elems+1,size_ff,
       		         load_immed(IMMED(Word32.toLargeIntX(BI.tag_regvec(false,num_elems))),tmp_reg0,
			 store_indexed(reg_for_result,WORDS 0,tmp_reg0,
			 #2(foldr (fn (sma,(offset,C)) => 
				   (offset-1,store_sm_in_record(sma,tmp_reg0,reg_for_result,
								WORDS offset,size_ff, C))) 
			    (num_elems,C') elems))))
		       else
			 alloc_ap_kill_tmp01(alloc,reg_for_result,num_elems,size_ff,
			 #2(foldr (fn (sma,(offset,C)) => 
				   (offset-1,store_sm_in_record(sma,tmp_reg0,reg_for_result,
								WORDS offset,size_ff, C))) 
			    (num_elems-1,C') elems))
		     end
		    | LS.SCLOS_RECORD{elems=elems as (lvs,excons,rhos),alloc} => 
		     let val (reg_for_result,C') = resolve_aty_def(pat,tmp_reg1,size_ff,C)
		         val num_elems = List.length (LS.smash_free elems)
			 val n_skip = length rhos (* We don't traverse region pointers *)
		     in
		       if BI.tag_values() then
			 alloc_ap_kill_tmp01(alloc,reg_for_result,num_elems+1,size_ff,
       		         load_immed(IMMED(Word32.toLargeIntX(BI.tag_sclos(false,num_elems,n_skip))),tmp_reg0,
			 store_indexed(reg_for_result,WORDS 0,tmp_reg0,
			 #2(foldr (fn (aty,(offset,C)) => 
				  (offset-1,store_aty_in_reg_record(aty,tmp_reg0,reg_for_result,
								    WORDS offset,size_ff, C))) 
			    (num_elems,C') (LS.smash_free elems)))))
		       else
			 alloc_ap_kill_tmp01(alloc,reg_for_result,num_elems,size_ff,
			 #2(foldr (fn (aty,(offset,C)) => 
				   (offset-1,store_aty_in_reg_record(aty,tmp_reg0,reg_for_result,
								     WORDS offset,size_ff, C))) 
			    (num_elems-1,C') (LS.smash_free elems)))
		     end
		    | LS.RECORD{elems=[],alloc,tag} => 
		     move_aty_to_aty(SS.UNIT_ATY,pat,size_ff,C) (* Unit is unboxed *)
		    | LS.RECORD{elems,alloc,tag} =>
		     let val (reg_for_result,C') = resolve_aty_def(pat,tmp_reg1,size_ff,C)
		         val num_elems = List.length elems
		     in
		       if BI.tag_values() then
			 alloc_ap_kill_tmp01(alloc,reg_for_result,num_elems+1,size_ff,
       		         load_immed(IMMED(Word32.toLargeIntX tag),tmp_reg0,
			 store_indexed(reg_for_result,WORDS 0,tmp_reg0,
		         #2(foldr (fn (aty,(offset,C)) => 
				   (offset-1,store_aty_in_reg_record(aty,tmp_reg0,reg_for_result,
								     WORDS offset,size_ff, C))) 
			    (num_elems,C') elems))))
		       else
			 alloc_ap_kill_tmp01(alloc,reg_for_result,num_elems,size_ff,
			 #2(foldr (fn (aty,(offset,C)) => 
				   (offset-1,store_aty_in_reg_record(aty,tmp_reg0,reg_for_result,
								     WORDS offset,size_ff, C))) 
			    (num_elems-1,C') elems))
		     end
		    | LS.SELECT(i,aty) => 
		     if BI.tag_values() then
		       move_index_aty_to_aty(aty,pat,WORDS(i+1),tmp_reg1,size_ff,C)
		     else
		       move_index_aty_to_aty(aty,pat,WORDS i,tmp_reg1,size_ff,C)
		    | LS.CON0{con,con_kind,aux_regions,alloc} =>
		       (case con_kind of
			  LS.ENUM i => 
			    let 
			      val tag = 
				if BI.tag_values() orelse (*hack to treat booleans tagged*)
				  Con.eq(con,Con.con_TRUE) orelse Con.eq(con,Con.con_FALSE) then 
				  2*i+1 
				else i
			      val (reg_for_result,C') = resolve_aty_def(pat,tmp_reg1,size_ff,C)
			    in
			      load_immed(IMMED (Int32.fromInt tag),reg_for_result,C')
			    end
			| LS.UNBOXED i => 
			    let
			      val tag = 4*i+3 
			      val (reg_for_result,C') = resolve_aty_def(pat,tmp_reg1,size_ff,C)
			      fun reset_regions C =
				foldr (fn (alloc,C) => 
				       maybe_reset_aux_region_kill_tmp0(alloc,tmp_reg1,size_ff,C)) 
				C aux_regions
			    in
			      reset_regions(load_immed(IMMED (Int32.fromInt tag),reg_for_result,C'))
			    end
			| LS.BOXED i => 
			    let 
			      val tag = int_to_string(Word32.toInt(BI.tag_con0(false,i)))
			      val (reg_for_result,C') = resolve_aty_def(pat,tmp_reg1,size_ff,C)
			      fun reset_regions C =
				List.foldr (fn (alloc,C) => 
					    maybe_reset_aux_region_kill_tmp0(alloc,tmp_reg1,size_ff,C)) 
				C aux_regions
			    in  
			      reset_regions(
                              alloc_ap_kill_tmp01(alloc,reg_for_result,1,size_ff,
                              I.movl(I tag, D("0",reg_for_result)) :: C'))
			    end)
		    | LS.CON1{con,con_kind,alloc,arg} => 
			  (case con_kind 
			     of LS.UNBOXED 0 => move_aty_to_aty(arg,pat,size_ff,C) 
			      | LS.UNBOXED i => 
			       let val (reg_for_result,C') = resolve_aty_def(pat,tmp_reg1,size_ff,C)
			       in case i 
				    of 1 => move_aty_into_reg(arg,reg_for_result,size_ff,
					    I.orl(I "1", R reg_for_result) :: C')
				     | 2 => move_aty_into_reg(arg,reg_for_result,size_ff,
					    I.orl(I "2", R reg_for_result) :: C')
				     | _ => die "CG_ls: UNBOXED CON1 with i > 2"
			       end
			      | LS.BOXED i => 
			       let val (reg_for_result,C') = resolve_aty_def(pat,tmp_reg1,size_ff,C)
				   val tag = int_to_string(Word32.toInt(BI.tag_con1(false,i)))
			       in 
				 if SS.eq_aty(pat,arg) then (* We must preserve arg. *)
				   alloc_ap_kill_tmp01(alloc,tmp_reg1,2,size_ff,
			           I.movl(I tag, D("0", tmp_reg1)) ::
			           store_aty_in_reg_record(arg,tmp_reg0,tmp_reg1,WORDS 1,size_ff,
				   copy(tmp_reg1,reg_for_result,C')))
				 else
			           alloc_ap_kill_tmp01(alloc,reg_for_result,2,size_ff,
				   I.movl(I tag, D("0", reg_for_result)) ::		     
			           store_aty_in_reg_record(arg,tmp_reg0,reg_for_result,WORDS 1,size_ff,C'))
			       end
			      | _ => die "CON1.con not unary in env.")
		    | LS.DECON{con,con_kind,con_aty} =>
		      (case con_kind 
			 of LS.UNBOXED 0 => move_aty_to_aty(con_aty,pat,size_ff,C)
			  | LS.UNBOXED _ => 
			   let
			     val (reg_for_result,C') = resolve_aty_def(pat,tmp_reg1,size_ff,C)
			   in
			     move_aty_into_reg(con_aty,reg_for_result,size_ff,
                             I.movl(I "3", R tmp_reg0) ::
			     I.notl(R tmp_reg0) ::
                             I.andl(R tmp_reg0, R reg_for_result) :: C')
			   end
			  | LS.BOXED _ => move_index_aty_to_aty(con_aty,pat,WORDS 1,tmp_reg1,size_ff,C)
			  | _ => die "CG_ls: DECON used with con_kind ENUM")
		    | LS.DEREF aty =>
		     let val offset = if BI.tag_values() then 1 else 0
		     in move_index_aty_to_aty(aty,pat,WORDS offset,tmp_reg1,size_ff,C)
		     end
		    | LS.REF(alloc,aty) =>
		     let val offset = if BI.tag_values() then 1 else 0
		         val (reg_for_result,C') = resolve_aty_def(pat,tmp_reg1,size_ff,C)
			 fun maybe_tag_value C =
			   if BI.tag_values() then
			     I.movl(I (int_to_string(Word32.toInt(BI.tag_ref(false)))), 
				    D("0", reg_for_result)) :: C
			   else C
		     in
		       if SS.eq_aty(pat,aty) then (* We must preserve aty *)
			 alloc_ap_kill_tmp01(alloc,tmp_reg1,BI.size_of_ref(),size_ff,
			 store_aty_in_reg_record(aty,tmp_reg0,tmp_reg1,WORDS offset,size_ff,
			 copy(tmp_reg1,reg_for_result,maybe_tag_value C')))
		       else
			 alloc_ap_kill_tmp01(alloc,reg_for_result,BI.size_of_ref(),size_ff,
		         store_aty_in_reg_record(aty,tmp_reg0,reg_for_result,WORDS offset,size_ff,
		         maybe_tag_value C'))
		     end
		    | LS.ASSIGNREF(alloc,aty1,aty2) =>
		     let 
		       val (reg_for_result,C') = resolve_aty_def(pat,tmp_reg1,size_ff,C)
		       val offset = if BI.tag_values() then 1 else 0
		     in
		       store_aty_in_aty_record(aty2,aty1,WORDS offset,tmp_reg1,tmp_reg0,size_ff,
                       if BI.tag_integers() then
			 load_immed(IMMED (Int32.fromInt BI.ml_unit),reg_for_result,C')
                       else C')
		     end
		    | LS.PASS_PTR_TO_MEM(alloc,i) =>
		     let
		       val (reg_for_result,C') = resolve_aty_def(pat,tmp_reg1,size_ff,C)
		     in
		       alloc_ap_kill_tmp01(alloc,reg_for_result,i,size_ff,C')
		     end
		    | LS.PASS_PTR_TO_RHO(alloc) =>
		     let
		       val (reg_for_result,C') = resolve_aty_def(pat,tmp_reg1,size_ff,C)
		     in 
		       prefix_sm(alloc,reg_for_result,size_ff,C')
		     end)))
	       | LS.FLUSH(aty,offset) => comment_fn (fn () => "FLUSH: " ^ pr_ls ls,
		                         store_aty_in_reg_record(aty,tmp_reg1,esp,WORDS(size_ff-offset-1),size_ff,C))
	       | LS.FETCH(aty,offset) => comment_fn (fn () => "FETCH: " ^ pr_ls ls,
                                         load_aty_from_reg_record(aty,tmp_reg1,esp,WORDS(size_ff-offset-1),size_ff,C))
	       | LS.FNJMP(cc as {opr,args,clos,res,bv}) =>
		comment_fn (fn () => "FNJMP: " ^ pr_ls ls,
		let
		  val (spilled_args,_,_) = CallConv.resolve_act_cc RI.args_phreg RI.res_phreg {args=args,clos=clos,
								    reg_args=[],reg_vec=NONE,res=res}
		  val offset_codeptr = if BI.tag_values() then "4" else "0"
		in
		  if List.length spilled_args > 0 then
		    CG_ls(LS.FNCALL cc,C)
		  else
		    case opr (* We fetch the addr from the closure and opr points at the closure *)
		      of SS.PHREG_ATY opr_reg => 
			I.movl(D(offset_codeptr,opr_reg), R tmp_reg1) ::    (* Fetch code label from closure *)
			base_plus_offset(esp,WORDS(size_ff+size_ccf),esp,   (* return label is now at top of stack *)
			I.jmp(R tmp_reg1) :: rem_dead_code C)
		       | _ => 
			move_aty_into_reg(opr,tmp_reg1,size_ff,
			I.movl(D(offset_codeptr,tmp_reg1), R tmp_reg1) ::   (* Fetch code label from closure *)
			base_plus_offset(esp,WORDS(size_ff+size_ccf),esp,   (* return label is now at top of stack *)
			I.jmp(R tmp_reg1) :: rem_dead_code C))
		end)
	       | LS.FNCALL{opr,args,clos,res,bv} =>
		  comment_fn (fn () => "FNCALL: " ^ pr_ls ls,
		  let 
		    val offset_codeptr = if BI.tag_values() then "4" else "0"
		    val (spilled_args,spilled_res,return_lab_offset) = 
		      CallConv.resolve_act_cc RI.args_phreg RI.res_phreg {args=args,clos=clos,reg_args=[],reg_vec=NONE,res=res}
		    val size_rcf = length spilled_res
		    val size_ccf = length spilled_args
		    val size_cc = size_rcf+size_ccf+1
(*val _ = if size_cc > 1 then die ("\nfncall: size_ccf: " ^ (Int.toString size_ccf) ^ " and size_rcf: " ^  
				 (Int.toString size_rcf) ^ ".") else () (* debug 2001-01-08, Niels *)*)

		    val return_lab = new_local_lab "return_from_app"
		    fun flush_args C =
		      foldr (fn ((aty,offset),C) => push_aty(aty,tmp_reg1,size_ff+offset,C)) C spilled_args
		    (* We pop in reverse order such that size_ff+offset works *)
		    fun fetch_res C = 
		      foldr (fn ((aty,offset),C) =>  
			     pop_aty(aty,tmp_reg1,size_ff+offset,C)) C (rev spilled_res) 
		    fun jmp C =  
		      case opr (* We fetch the add from the closure and opr points at the closure *)
			of SS.PHREG_ATY opr_reg => 
			  I.movl(D(offset_codeptr,opr_reg), R tmp_reg1) ::  (* Fetch code pointer *)
			  I.jmp(R tmp_reg1) :: C
			 | _ => 
			  move_aty_into_reg(opr,tmp_reg1,size_ff+size_cc,   (* esp is now pointing after the call *)
			  I.movl(D(offset_codeptr,tmp_reg1), R tmp_reg1) :: (* convention, i.e., size_ff+size_cc *)
			  I.jmp(R tmp_reg1) :: C)
		  in 
		    base_plus_offset(esp,WORDS(~size_rcf),esp,                         (* Move esp after rcf *)
		    I.pushl(LA return_lab) ::                                          (* Push Return Label *)
		    flush_args(jmp(gen_bv(bv, I.lab return_lab :: fetch_res C))))
		  end)
	       | LS.JMP(cc as {opr,args,reg_vec,reg_args,clos,res,bv}) => 
		  comment_fn (fn () => "JMP: " ^ pr_ls ls,
		  let 
		  (* The stack looks as follows - growing downwards to the right:  
		   *
		   *   ... | ff | rcf | retlab | ccf | ff |
		   *                                     ^sp
		   * To perform a tail call, the arguments that need be passed on the stack
		   * should overwrite the ``| ccf | ff |'' part and the stack pointer 
		   * should be adjusted accordingly. However, to compute the new arguments, some of
		   * the values in ``| ccf | ff |'' may be needed. On the other hand, some of the
		   * arguments may be positioned on the stack correctly already.
		   *)
		    val (spilled_args, (* those arguments that need be passed on the stack *)
			 spilled_res,  (* those return values that are returned on the stack *)
			 _) = CallConv.resolve_act_cc RI.args_phreg RI.res_phreg 
			      {args=args,clos=clos,reg_args=reg_args,reg_vec=reg_vec,res=res}

		    val size_rcf = length spilled_res
		    val size_ccf_new = length spilled_args
(*
		    val _ = if size_ccf_new > 0 then
			      print ("** JMP to " ^ Labels.pr_label opr ^ " with\n" ^ 
				     "**    size_ccf_new = " ^ Int.toString size_ccf_new ^ "\n" ^
				     "**    size_ccf = " ^ Int.toString size_ccf ^ "\n" ^
				     "**    size_ff = " ^ Int.toString size_ff ^ "\n")
			    else ()
*)
		    fun flush_args C =
		      foldr (fn ((aty,offset),C) => 
			     push_aty(aty,tmp_reg1, size_ff + offset - 1 - size_rcf, C)) C spilled_args
		    (* We pop in reverse order such that size_ff+offset works, but we must adjust for the
		     * return label and the return convention frame that we didn't push onto the stack
		     * because we're dealing with a tail call. *)

		  (* After the arguments are pushed onto the stack, we copy them down to 
		   * the current ``| ccf | ff |'', which is now dead. *)
		    fun copy_down 0 C = C
		      | copy_down n C = load_indexed(tmp_reg1, esp, WORDS (n-1),
					 store_indexed(esp, WORDS (size_ff+size_ccf+n-1), tmp_reg1, 
					  copy_down (n-1) C))
		    fun jmp C = I.jmp(L(MLFunLab opr)) :: rem_dead_code C
		  in 
		    flush_args
		    (copy_down size_ccf_new
		     (base_plus_offset(esp,WORDS(size_ff+size_ccf),esp,
				       jmp C)))
		  end)
	       | LS.FUNCALL{opr,args,reg_vec,reg_args,clos,res,bv} =>
		  comment_fn (fn () => "FUNCALL: " ^ pr_ls ls,
		  let 
		    val (spilled_args,spilled_res,return_lab_offset) = 
		      CallConv.resolve_act_cc RI.args_phreg RI.res_phreg {args=args,clos=clos,reg_args=reg_args,reg_vec=reg_vec,res=res}
		    val size_rcf = List.length spilled_res
		    val return_lab = new_local_lab "return_from_app"
		    fun flush_args C =
		      foldr (fn ((aty,offset),C) => push_aty(aty,tmp_reg1,size_ff+offset,C)) C (spilled_args)
		    (* We pop in reverse order such that size_ff+offset works *)
		    fun fetch_res C = 
		      foldr (fn ((aty,offset),C) => pop_aty(aty,tmp_reg1,size_ff+offset,C)) C (rev spilled_res) 
	 	    fun jmp C = I.jmp(L(MLFunLab opr)) :: C
		  in 
		    base_plus_offset(esp,WORDS(~size_rcf),esp,                          (* Move esp after rcf *)
		    I.pushl(LA return_lab) ::                                           (* Push Return Label *)
		    flush_args(jmp(gen_bv(bv, I.lab return_lab :: fetch_res C))))
		  end)
	       | LS.LETREGION{rhos,body} =>
		  comment ("LETREGION",
		  let 
		    fun key place = mkIntAty (Effect.key_of_eps_or_rho place)
		    fun alloc_region_prim(((place,phsize),offset),C) =
  	  	      if region_profiling() then
		        case phsize
			  of LineStmt.WORDS 0 => C (* zero-sized finite region *)
			   | LineStmt.WORDS i =>   (* finite region *)
			    let (* The offset points at the object - not the region descriptor, 
				 * nor the object descriptor; allocRegionFiniteProfiling expects
				 * a pointer to the region descriptor. See CalcOffset.sml for a 
				 * picture. The size i of the region does not include the sizes 
				 * of the object descriptor and the region descriptor. *)
			      val reg_offset = offset + BI.objectDescSizeP + BI.finiteRegionDescSizeP
			    in
			      base_plus_offset(esp,WORDS(size_ff-reg_offset-1),tmp_reg1,
			       compile_c_call_prim("allocRegionFiniteProfiling",
						   [SS.PHREG_ATY tmp_reg1,
						    key place,
						    mkIntAty i], NONE,
						   size_ff,tmp_reg0(*not used*),C))
			    end
			   | LineStmt.INF => 
			    base_plus_offset(esp,WORDS(size_ff-offset-1),tmp_reg1,
		              compile_c_call_prim("allocRegionInfiniteProfiling",
						  [SS.PHREG_ATY tmp_reg1, 
						   key place], NONE,
						  size_ff,tmp_reg0(*not used*),C))
		      else
		        case phsize
			  of LineStmt.WORDS i => C  (* finite region; no code generated *)
			   | LineStmt.INF => 
			    base_plus_offset(esp,WORDS(size_ff-offset-1),tmp_reg1,
		              compile_c_call_prim("allocateRegion",[SS.PHREG_ATY tmp_reg1],NONE,
						size_ff,tmp_reg0(*not used*),C))
		    fun dealloc_region_prim (((place,phsize),offset),C) = 
		      if region_profiling() then
		        case phsize
			  of LineStmt.WORDS 0 => C
			   | LineStmt.WORDS i =>
			    compile_c_call_prim("deallocRegionFiniteProfiling",[],NONE,
						size_ff,tmp_reg0(*not used*),C)
			   | LineStmt.INF => 
			    compile_c_call_prim("deallocateRegionNew",[],NONE,size_ff,tmp_reg0(*not used*),C)
		      else
			case phsize
			  of LineStmt.WORDS i => C
			   | LineStmt.INF => 
			    compile_c_call_prim("deallocateRegionNew",[],NONE,size_ff,tmp_reg0(*not used*),C)
		  in
		    foldr alloc_region_prim 
		    (CG_lss(body,size_ff,size_ccf,
			    foldl dealloc_region_prim C rhos)) rhos
		  end )
	       | LS.SCOPE{pat,scope} => CG_lss(scope,size_ff,size_ccf,C)
	       | LS.HANDLE{default,handl=(handl,handl_lv),handl_return=(handl_return,handl_return_aty,bv),offset} =>
	   (* An exception handler in an activation record starting at address offset contains the following fields: *)
	   (* sp[offset] = label for handl_return code.                                                              *)
	   (* sp[offset+1] = pointer to handle closure.                                                              *)
	   (* sp[offset+2] = pointer to previous exception handler used when updating expPtr.                        *)
	   (* sp[offset+3] = address of the first cell after the activation record used when resetting sp.           *)
	   (* Note that we call deallocate_regions_until to the address above the exception handler, (i.e., some of  *)
	   (* the infinite regions inside the activation record are also deallocated)!                               *)
		  let
		    val handl_return_lab = new_local_lab "handl_return"
		    val handl_join_lab = new_local_lab "handl_join"
		    fun handl_code C = comment ("HANDL_CODE", CG_lss(handl,size_ff,size_ccf,C))
		    fun store_handl_lv C =
		      comment ("STORE HANDLE_LV: sp[offset+1] = handl_lv",
		      store_aty_in_reg_record(handl_lv,tmp_reg1,esp,WORDS(size_ff-offset-1+1),size_ff,C))
		    fun store_handl_return_lab C =
		      comment ("STORE HANDL RETURN LAB: sp[offset] = handl_return_lab",
		      I.movl(LA handl_return_lab, R tmp_reg1) ::    
		      store_indexed(esp,WORDS(size_ff-offset-1),tmp_reg1,C))
		    fun store_exn_ptr C =
		      comment ("STORE EXN PTR: sp[offset+2] = exnPtr",
		      I.movl(L exn_ptr_lab, R tmp_reg1) :: 
	              store_indexed(esp,WORDS(size_ff-offset-1+2),tmp_reg1,
		      comment ("CALC NEW expPtr: expPtr = sp-size_ff+offset+size_of_handle",
		      base_plus_offset(esp,WORDS(size_ff-offset-1(*-BI.size_of_handle()*)),tmp_reg1,        (*hmmm *)
	              I.movl(R tmp_reg1, L exn_ptr_lab) :: C))))
		    fun store_sp C =
		      comment ("STORE SP: sp[offset+3] = sp",
		      store_indexed(esp,WORDS(size_ff-offset-1+3),esp,C))
		    fun default_code C = comment ("HANDLER DEFAULT CODE",
		      CG_lss(default,size_ff,size_ccf,C))
		    fun restore_exp_ptr C =
		      comment ("RESTORE EXN PTR: exnPtr = sp[offset+2]",
		      load_indexed(tmp_reg1,esp,WORDS(size_ff-offset-1+2),
	              I.movl(R tmp_reg1, L exn_ptr_lab) ::
	              I.jmp(L handl_join_lab) ::C))
		    fun handl_return_code C =
		      let val res_reg = RI.lv_to_reg(CallConv.handl_return_phreg RI.res_phreg)
		      in comment ("HANDL RETURN CODE: handl_return_aty = res_phreg",
			 gen_bv(bv,
		         I.lab handl_return_lab ::
		         move_aty_to_aty(SS.PHREG_ATY res_reg,handl_return_aty,size_ff,
		         CG_lss(handl_return,size_ff,size_ccf,
		         I.lab handl_join_lab :: C))))
		      end
		  in
		    comment ("START OF EXCEPTION HANDLER",
		    handl_code(
	            store_handl_lv(
                    store_handl_return_lab(
                    store_exn_ptr(
                    store_sp(
                    default_code(
                    restore_exp_ptr(
                    handl_return_code(comment ("END OF EXCEPTION HANDLER", C))))))))))
		  end
	       | LS.RAISE{arg=arg_aty,defined_atys} =>
		  push_aty(arg_aty,tmp_reg0,size_ff,
		  I.call (NameLab "raise_exn") :: rem_dead_code C)  (* function never returns *)
	       | LS.SWITCH_I{switch=LS.SWITCH(SS.FLOW_VAR_ATY(lv,lab_t,lab_f),[(sel_val,lss)],default),
			     precision} => 
		  let
		    val (t_lab,f_lab) = if sel_val = Int32.fromInt BI.ml_true then (lab_t,lab_f) else (lab_f,lab_t)
		    val lab_exit = new_local_lab "lab_exit"
		  in
		    I.lab(LocalLab t_lab) ::
		    CG_lss(lss,size_ff,size_ccf,
	            I.jmp(L lab_exit) ::
		    I.lab(LocalLab f_lab) ::
	            CG_lss(default,size_ff,size_ccf,
                    I.lab(lab_exit) :: C))
		  end
	       | LS.SWITCH_I {switch=LS.SWITCH(opr_aty,sels,default), precision} => 
		  compileNumSwitch {size_ff=size_ff,
				    size_ccf=size_ccf,
				    CG_lss=CG_lss,
				    toInt=fn i => maybeTagInt{value=i, precision=precision},
				    opr_aty=opr_aty,
				    oprBoxed=boxedNum precision,
				    sels=sels,
				    default=default,
				    C=C}
	       | LS.SWITCH_W {switch=LS.SWITCH(opr_aty,sels,default), precision} => 
		  compileNumSwitch {size_ff=size_ff,
				    size_ccf=size_ccf,
				    CG_lss=CG_lss,
				    toInt=fn w => maybeTagInt{value=Word32.toLargeIntX w, precision=precision},
				    opr_aty=opr_aty,
				    oprBoxed=boxedNum precision,
				    sels=sels,
				    default=default,
				    C=C}
	       | LS.SWITCH_S sw => die "SWITCH_S is unfolded in ClosExp"
	       | LS.SWITCH_C(LS.SWITCH(SS.FLOW_VAR_ATY(lv,lab_t,lab_f),[((con,con_kind),lss)],default)) => 
		  let
		    val (t_lab,f_lab) = if Con.eq(con,Con.con_TRUE) then (lab_t,lab_f) else (lab_f,lab_t)
		    val lab_exit = new_local_lab "lab_exit"
		  in
		    I.lab(LocalLab t_lab) ::
		    CG_lss(lss,size_ff,size_ccf,
		    I.jmp(L lab_exit) ::
		    I.lab(LocalLab f_lab) ::
		    CG_lss(default,size_ff,size_ccf,
                    I.lab lab_exit :: C))
		  end
	       | LS.SWITCH_C(LS.SWITCH(opr_aty,[],default)) => CG_lss(default,size_ff,size_ccf,C)
	       | LS.SWITCH_C(LS.SWITCH(opr_aty,sels,default)) => 
		  let (* NOTE: selectors in sels are tagged in ClosExp; values are 
		       * tagged here in CodeGenX86! *)
		    val con_kind = case sels 
				     of [] => die ("CG_ls: SWITCH_C sels is empty: " ^ (pr_ls ls))
				      | ((con,con_kind),_)::rest => con_kind
 		    val sels' = map (fn ((con,con_kind),sel_insts) => 
				     case con_kind 
				       of LS.ENUM i => (Int32.fromInt i,sel_insts)
					| LS.UNBOXED i => (Int32.fromInt i,sel_insts)
					| LS.BOXED i => (Int32.fromInt i,sel_insts)) sels
		    fun UbTagCon(src_aty,C) =
		      let val cont_lab = new_local_lab "cont"
		      in move_aty_into_reg(src_aty,tmp_reg0,size_ff, 
		         copy(tmp_reg0, tmp_reg1, (* operand is in tmp_reg1, see SWITCH_I *)
		         I.andl(I "3", R tmp_reg1) ::
                         I.cmpl(I "3", R tmp_reg1) ::   (* do copy if tr = 3; in that case we      *)
                         I.jne cont_lab ::              (* are dealing with a nullary constructor, *)
                         copy(tmp_reg0, tmp_reg1,       (* and all bits are used. *)
                         I.lab cont_lab :: C)))
		      end
		    val (F, opr_aty) =
		      case con_kind 
			of LS.ENUM _ => (fn C => C, opr_aty)
			 | LS.UNBOXED _ => (fn C => UbTagCon(opr_aty,C), SS.PHREG_ATY tmp_reg1)
			 | LS.BOXED _ => 
			  (fn C => move_index_aty_to_aty(opr_aty,SS.PHREG_ATY tmp_reg1,
							 WORDS 0,tmp_reg1,size_ff,C),
			   SS.PHREG_ATY tmp_reg1)
		  in
		    F (compileNumSwitch {size_ff=size_ff,
					 size_ccf=size_ccf,
					 CG_lss=CG_lss,
					 toInt=fn i => i,   (* tagging already done in ClosExp *)
					 opr_aty=opr_aty,
					 oprBoxed=false,
					 sels=sels',
					 default=default,
					 C=C})
		  end 
	       | LS.SWITCH_E sw => die "SWITCH_E is unfolded in ClosExp"
	       | LS.RESET_REGIONS{force=false,regions_for_resetting} =>
		  comment ("RESET_REGIONS(no force)",
		  foldr (fn (alloc,C) => maybe_reset_aux_region_kill_tmp0(alloc,tmp_reg1,size_ff,C)) C regions_for_resetting)
	       | LS.RESET_REGIONS{force=true,regions_for_resetting} =>
		  comment ("RESET_REGIONS(force)",
		  foldr (fn (alloc,C) => force_reset_aux_region_kill_tmp0(alloc,tmp_reg1,size_ff,C)) C regions_for_resetting)
	       | LS.PRIM{name,args,res=[SS.FLOW_VAR_ATY(lv,lab_t,lab_f)]} => 
		  comment_fn (fn () => "PRIM FLOW: " ^ pr_ls ls,
		  let val (lab_t,lab_f) = (LocalLab lab_t,LocalLab lab_f)
		      fun cmp(i,x,y) = cmpi_and_jmp_kill_tmp01(i,x,y,lab_t,lab_f,size_ff,C)
		      fun cmp_boxed(i,x,y) = cmpbi_and_jmp_kill_tmp01(i,x,y,lab_t,lab_f,size_ff,C)
		  in case (name,args) 
		       of ("__equal_int32ub",[x,y]) => cmp(I.je,x,y)
			| ("__equal_int32b",[x,y]) => cmp_boxed(I.je,x,y)
			| ("__equal_int31",[x,y]) => cmp(I.je,x,y)
			| ("__equal_word31",[x,y]) => cmp(I.je,x,y)
			| ("__equal_word32ub",[x,y]) => cmp(I.je,x,y)
			| ("__equal_word32b",[x,y]) => cmp_boxed(I.je,x,y)
			| ("__less_int32ub",[x,y]) => cmp(I.jl,x,y)
			| ("__less_int32b",[x,y]) => cmp_boxed(I.jl,x,y)
			| ("__less_int31",[x,y]) => cmp(I.jl,x,y)
			| ("__less_word31",[x,y]) => cmp(I.jb,x,y)
			| ("__less_word32ub",[x,y]) => cmp(I.jb,x,y)
			| ("__less_word32b",[x,y]) => cmp_boxed(I.jb,x,y)
			| ("__lesseq_int32ub",[x,y]) => cmp(I.jle,x,y)
			| ("__lesseq_int32b",[x,y]) => cmp_boxed(I.jle,x,y)
			| ("__lesseq_int31",[x,y]) => cmp(I.jle,x,y)
			| ("__lesseq_word31",[x,y]) => cmp(I.jbe,x,y) 
			| ("__lesseq_word32ub",[x,y]) => cmp(I.jbe,x,y) 
			| ("__lesseq_word32b",[x,y]) => cmp_boxed(I.jbe,x,y)
			| ("__greater_int32ub",[x,y]) => cmp(I.jg,x,y)
			| ("__greater_int32b",[x,y]) => cmp_boxed(I.jg,x,y)
			| ("__greater_int31",[x,y]) => cmp(I.jg,x,y)
			| ("__greater_word31",[x,y]) => cmp(I.ja,x,y)
			| ("__greater_word32ub",[x,y]) => cmp(I.ja,x,y)
			| ("__greater_word32b",[x,y]) => cmp_boxed(I.ja,x,y)
			| ("__greatereq_int32ub",[x,y]) => cmp(I.jge,x,y)
			| ("__greatereq_int32b",[x,y]) => cmp_boxed(I.jge,x,y)
			| ("__greatereq_int31",[x,y]) => cmp(I.jge,x,y)
			| ("__greatereq_word31",[x,y]) => cmp(I.jae,x,y)
			| ("__greatereq_word32ub",[x,y]) => cmp(I.jae,x,y)
			| ("__greatereq_word32b",[x,y]) => cmp_boxed(I.jae,x,y)
			| _ => die "CG_ls: Unknown PRIM used on Flow Variable"
		  end)
	       | LS.PRIM{name,args,res} => 
		  let
		  in
		  comment_fn (fn () => "PRIM: " ^ pr_ls ls,
		  (* Note that the prim names are defined in BackendInfo! *)
		  (case (name,args,case res of nil => [SS.UNIT_ATY] | _ => res) 
		     of ("__equal_int32ub",[x,y],[d]) => cmpi_kill_tmp01 {box=false} (I.je,x,y,d,size_ff,C)
		      | ("__equal_int32b",[x,y],[d]) => cmpi_kill_tmp01 {box=true} (I.je,x,y,d,size_ff,C)
		      | ("__equal_int31",[x,y],[d]) => cmpi_kill_tmp01 {box=false} (I.je,x,y,d,size_ff,C)
		      | ("__equal_word31",[x,y],[d]) => cmpi_kill_tmp01 {box=false} (I.je,x,y,d,size_ff,C)
		      | ("__equal_word32ub",[x,y],[d]) => cmpi_kill_tmp01 {box=false} (I.je,x,y,d,size_ff,C)
		      | ("__equal_word32b",[x,y],[d]) => cmpi_kill_tmp01 {box=true} (I.je,x,y,d,size_ff,C)

		      | ("__plus_int32ub",[x,y],[d]) => add_num_kill_tmp01 {ovf=true,tag=false} (x,y,d,size_ff,C)
		      | ("__plus_int32b",[b,x,y],[d]) => add_int32b (b,x,y,d,size_ff,C)
		      | ("__plus_int31",[x,y],[d]) => add_num_kill_tmp01 {ovf=true,tag=true} (x,y,d,size_ff,C)
		      | ("__plus_word31",[x,y],[d]) => add_num_kill_tmp01 {ovf=false,tag=true} (x,y,d,size_ff,C)
		      | ("__plus_word32ub",[x,y],[d]) => add_num_kill_tmp01 {ovf=false,tag=false} (x,y,d,size_ff,C)
		      | ("__plus_word32b",[b,x,y],[d]) => addw32boxed(b,x,y,d,size_ff,C)
		      | ("__plus_real",[b,x,y],[d]) => addf_kill_tmp01(x,y,b,d,size_ff,C)

		      | ("__minus_int32ub",[x,y],[d]) => sub_num_kill_tmp01 {ovf=true,tag=false} (x,y,d,size_ff,C)
		      | ("__minus_int32b",[b,x,y],[d]) => sub_int32b (b,x,y,d,size_ff,C)
		      | ("__minus_int31",[x,y],[d]) => sub_num_kill_tmp01 {ovf=true,tag=true} (x,y,d,size_ff,C)
		      | ("__minus_word31",[x,y],[d]) => sub_num_kill_tmp01 {ovf=false,tag=true} (x,y,d,size_ff,C)
		      | ("__minus_word32ub",[x,y],[d]) => sub_num_kill_tmp01 {ovf=false,tag=false} (x,y,d,size_ff,C)
		      | ("__minus_word32b",[b,x,y],[d]) => subw32boxed(b,x,y,d,size_ff,C)
		      | ("__minus_real",[b,x,y],[d]) => subf_kill_tmp01(x,y,b,d,size_ff,C)

		      | ("__mul_int32ub", [x,y], [d]) => mul_num_kill_tmp01 {ovf=true,tag=false} (x,y,d,size_ff,C) 
		      | ("__mul_int32b", [b,x,y], [d]) => mul_int32b (b,x,y,d,size_ff,C)
		      | ("__mul_int31", [x,y], [d]) => mul_num_kill_tmp01 {ovf=true,tag=true} (x,y,d,size_ff,C) 
		      | ("__mul_word31", [x,y], [d]) => mul_num_kill_tmp01 {ovf=false,tag=true} (x,y,d,size_ff,C)  
		      | ("__mul_word32ub", [x,y], [d]) => mul_num_kill_tmp01 {ovf=false,tag=false} (x,y,d,size_ff,C) 
		      | ("__mul_word32b", [b,x,y], [d]) => mulw32boxed(b,x,y,d,size_ff,C)
		      | ("__mul_real",[b,x,y],[d]) => mulf_kill_tmp01(x,y,b,d,size_ff,C)

		      | ("__div_real", [b,x,y],[d]) => divf_kill_tmp01(x,y,b,d,size_ff,C)

		      | ("__neg_int32ub",[x],[d]) => neg_int_kill_tmp0 {tag=false} (x,d,size_ff,C)
		      | ("__neg_int32b",[b,x],[d]) => neg_int32b_kill_tmp0 (b,x,d,size_ff,C)
		      | ("__neg_int31",[x],[d]) => neg_int_kill_tmp0 {tag=true} (x,d,size_ff,C)
		      | ("__neg_real",[b,x],[d]) => negf_kill_tmp01(b,x,d,size_ff,C)

		      | ("__abs_int32ub",[x],[d]) => abs_int_kill_tmp0 {tag=false} (x,d,size_ff,C)
		      | ("__abs_int32b",[b,x],[d]) => abs_int32b_kill_tmp0 (b,x,d,size_ff,C)
		      | ("__abs_int31",[x],[d]) => abs_int_kill_tmp0 {tag=true} (x,d,size_ff,C)
		      | ("__abs_real",[b,x],[d]) => absf_kill_tmp01(b,x,d,size_ff,C)

		      | ("__less_int32ub",[x,y],[d]) => cmpi_kill_tmp01 {box=false} (I.jl,x,y,d,size_ff,C)
		      | ("__less_int32b",[x,y],[d]) => cmpi_kill_tmp01 {box=true} (I.jl,x,y,d,size_ff,C)
		      | ("__less_int31",[x,y],[d]) => cmpi_kill_tmp01 {box=false} (I.jl,x,y,d,size_ff,C)
		      | ("__less_word31",[x,y],[d]) => cmpi_kill_tmp01 {box=false} (I.jb,x,y,d,size_ff,C)
		      | ("__less_word32ub",[x,y],[d]) => cmpi_kill_tmp01 {box=false} (I.jb,x,y,d,size_ff,C)
		      | ("__less_word32b",[x,y],[d]) => cmpi_kill_tmp01 {box=true} (I.jb,x,y,d,size_ff,C)
		      | ("__less_real",[x,y],[d]) => cmpf_kill_tmp01(LESSTHAN,x,y,d,size_ff,C)

		      | ("__lesseq_int32ub",[x,y],[d]) => cmpi_kill_tmp01 {box=false} (I.jle,x,y,d,size_ff,C)
		      | ("__lesseq_int32b",[x,y],[d]) => cmpi_kill_tmp01 {box=true} (I.jle,x,y,d,size_ff,C)
		      | ("__lesseq_int31",[x,y],[d]) => cmpi_kill_tmp01 {box=false} (I.jle,x,y,d,size_ff,C)
		      | ("__lesseq_word31",[x,y],[d]) => cmpi_kill_tmp01 {box=false} (I.jbe,x,y,d,size_ff,C)
		      | ("__lesseq_word32ub",[x,y],[d]) => cmpi_kill_tmp01 {box=false} (I.jbe,x,y,d,size_ff,C)
		      | ("__lesseq_word32b",[x,y],[d]) => cmpi_kill_tmp01 {box=true} (I.jbe,x,y,d,size_ff,C)
		      | ("__lesseq_real",[x,y],[d]) => cmpf_kill_tmp01(LESSEQUAL,x,y,d,size_ff,C)

		      | ("__greater_int32ub",[x,y],[d]) => cmpi_kill_tmp01 {box=false} (I.jg,x,y,d,size_ff,C)
		      | ("__greater_int32b",[x,y],[d]) => cmpi_kill_tmp01 {box=true} (I.jg,x,y,d,size_ff,C)
		      | ("__greater_int31",[x,y],[d]) => cmpi_kill_tmp01 {box=false} (I.jg,x,y,d,size_ff,C)
		      | ("__greater_word31",[x,y],[d]) => cmpi_kill_tmp01 {box=false} (I.ja,x,y,d,size_ff,C)
		      | ("__greater_word32ub",[x,y],[d]) => cmpi_kill_tmp01 {box=false} (I.ja,x,y,d,size_ff,C)
		      | ("__greater_word32b",[x,y],[d]) => cmpi_kill_tmp01 {box=true} (I.ja,x,y,d,size_ff,C)
		      | ("__greater_real",[x,y],[d]) => cmpf_kill_tmp01(GREATERTHAN,x,y,d,size_ff,C)

		      | ("__greatereq_int32ub",[x,y],[d]) => cmpi_kill_tmp01 {box=false} (I.jge,x,y,d,size_ff,C)
		      | ("__greatereq_int32b",[x,y],[d]) => cmpi_kill_tmp01 {box=true} (I.jge,x,y,d,size_ff,C)
		      | ("__greatereq_int31",[x,y],[d]) => cmpi_kill_tmp01 {box=false} (I.jge,x,y,d,size_ff,C)
		      | ("__greatereq_word31",[x,y],[d]) => cmpi_kill_tmp01 {box=false} (I.jae,x,y,d,size_ff,C)
		      | ("__greatereq_word32ub",[x,y],[d]) => cmpi_kill_tmp01 {box=false} (I.jae,x,y,d,size_ff,C)
		      | ("__greatereq_word32b",[x,y],[d]) => cmpi_kill_tmp01 {box=true} (I.jae,x,y,d,size_ff,C)
		      | ("__greatereq_real",[x,y],[d]) => cmpf_kill_tmp01(GREATEREQUAL,x,y,d,size_ff,C)		       
		       	
		      | ("__andb_word31",[x,y],[d]) => andb_word_kill_tmp01(x,y,d,size_ff,C)
		      | ("__andb_word32ub",[x,y],[d]) => andb_word_kill_tmp01(x,y,d,size_ff,C)
		      | ("__andb_word32b",[b,x,y],[d]) => andw32boxed__(b,x,y,d,size_ff,C)

		      | ("__orb_word31",[x,y],[d]) => orb_word_kill_tmp01(x,y,d,size_ff,C)
		      | ("__orb_word32ub",[x,y],[d]) => orb_word_kill_tmp01(x,y,d,size_ff,C)
		      | ("__orb_word32b",[b,x,y],[d]) => orw32boxed__(b,x,y,d,size_ff,C)

		      | ("__xorb_word31",[x,y],[d]) => xorb_word_kill_tmp01 {tag=true} (x,y,d,size_ff,C)
		      | ("__xorb_word32ub",[x,y],[d]) => xorb_word_kill_tmp01 {tag=false} (x,y,d,size_ff,C)
		      | ("__xorb_word32b",[b,x,y],[d]) => xorw32boxed__(b,x,y,d,size_ff,C)

		      | ("__shift_left_word31",[x,y],[d]) => shift_left_word_kill_tmp01 {tag=true} (x,y,d,size_ff,C)
		      | ("__shift_left_word32ub",[x,y],[d]) => shift_left_word_kill_tmp01 {tag=false} (x,y,d,size_ff,C)
		      | ("__shift_left_word32b",[b,x,y],[d]) => shift_leftw32boxed__(b,x,y,d,size_ff,C)

		      | ("__shift_right_signed_word31",[x,y],[d]) =>
		       shift_right_signed_word_kill_tmp01 {tag=true} (x,y,d,size_ff,C)
		      | ("__shift_right_signed_word32ub",[x,y],[d]) => 
		       shift_right_signed_word_kill_tmp01 {tag=false} (x,y,d,size_ff,C)
		      | ("__shift_right_signed_word32b",[b,x,y],[d]) => 
		       shift_right_signedw32boxed__(b,x,y,d,size_ff,C)

		      | ("__shift_right_unsigned_word31",[x,y],[d]) =>
		       shift_right_unsigned_word_kill_tmp01 {tag=true} (x,y,d,size_ff,C)
		      | ("__shift_right_unsigned_word32ub",[x,y],[d]) => 
		       shift_right_unsigned_word_kill_tmp01 {tag=false} (x,y,d,size_ff,C)
		      | ("__shift_right_unsigned_word32b",[b,x,y],[d]) => 
		       shift_right_unsignedw32boxed__(b,x,y,d,size_ff,C)

		      | ("__int31_to_int32b",[b,x],[d]) => num31_to_num32b(b,x,d,size_ff,C)
		      | ("__int31_to_int32ub",[x],[d]) => num31_to_num32ub(x,d,size_ff,C)
		      | ("__int32b_to_int31",[x],[d]) => num32_to_num31 {boxedarg=true,ovf=true} (x,d,size_ff,C)
		      | ("__int32ub_to_int31",[x],[d]) => num32_to_num31 {boxedarg=false,ovf=true} (x,d,size_ff,C)

		      | ("__word31_to_word32b",[b,x],[d]) => num31_to_num32b(b,x,d,size_ff,C)
		      | ("__word31_to_word32ub",[x],[d]) => num31_to_num32ub(x,d,size_ff,C)
		      | ("__word32b_to_word31",[x],[d]) => num32_to_num31 {boxedarg=true,ovf=false} (x,d,size_ff,C)
		      | ("__word32ub_to_word31",[x],[d]) => num32_to_num31 {boxedarg=false,ovf=false} (x,d,size_ff,C)

		      | ("__word31_to_word32ub_X",[x],[d]) => num31_to_num32ub(x,d,size_ff,C)
		      | ("__word31_to_word32b_X",[b,x],[d]) => num31_to_num32b(b,x,d,size_ff,C)

		      | ("__word32b_to_int32b",[b,x],[d]) => num32b_to_num32b {ovf=true} (b,x,d,size_ff,C)
		      | ("__word32b_to_int32b_X",[b,x],[d]) => num32b_to_num32b {ovf=false} (b,x,d,size_ff,C)
		      | ("__int32b_to_word32b",[b,x],[d]) => num32b_to_num32b {ovf=false} (b,x,d,size_ff,C)
		      | ("__word32ub_to_int32ub",[x],[d]) => word32ub_to_int32ub(x,d,size_ff,C)
		      | ("__word32b_to_int31",[x],[d]) => num32_to_num31 {boxedarg=true,ovf=true} (x,d,size_ff,C)
		      | ("__int32b_to_word31",[x],[d]) => num32_to_num31 {boxedarg=true,ovf=false} (x,d,size_ff,C)
		      | ("__word32b_to_int31_X", [x],[d]) => num32_to_num31 {boxedarg=true,ovf=true} (x,d,size_ff,C)

		      | ("__fresh_exname",[],[aty]) =>
		       I.movl(L exn_counter_lab, R tmp_reg0) ::
		       move_reg_into_aty(tmp_reg0,aty,size_ff,
                       I.addl(I "1", R tmp_reg0) ::
                       I.movl(R tmp_reg0, L exn_counter_lab) :: C)
		      | _ => die ("PRIM(" ^ name ^ ") not implemented")))
		  end
	       | LS.CCALL{name,args,rhos_for_result,res} => 
		  let 
		    fun comp_c_call(all_args,res,C) = 
		      compile_c_call_prim(name, all_args, res, size_ff, tmp_reg1, C)
		    val _ = 
		      if BI.is_prim name then
			die ("CCALL." ^ name ^ " is meant to be a primitive inlined by the compiler " ^ 
			     "- but it is not dealt with!")
		      else ()
		  in
		    comment_fn (fn () => "CCALL: " ^ pr_ls ls,
		     (case (name, rhos_for_result@args, res)
			of (_,all_args,[]) => comp_c_call(all_args, NONE, C)
			 | (_,all_args, [res_aty]) => comp_c_call(all_args, SOME res_aty, C)
			 | _ => die "CCall with more than one result variable"))
		  end)
       in
	 foldr (fn (ls,C) => CG_ls(ls,C)) C lss
       end

     fun do_prof C =
       if region_profiling() then
	 let val labStack = new_local_lab "profStack"
	   val labCont = new_local_lab "profCont"
	   val labCont2 = new_local_lab "profCont2-"
	   val maxStackLab = NameLab "maxStack"
	   val timeToProfLab = NameLab "timeToProfile"
	 in I.movl(L maxStackLab, R tmp_reg0) ::     (* The stack grows downwards!! *)
	   I.cmpl(R esp, R tmp_reg0) ::
	   I.jl labCont ::                                                    (* if ( *maxStack > esp ) {     *)
	   I.movl(R esp, L maxStackLab) ::                                    (*    *maxStack = esp ;         *)
	   I.movl(L (NameLab "regionDescUseProfInf"), R tmp_reg0) ::          (*    maxProfStack =            *)
	   I.addl(L (NameLab "regionDescUseProfFin"), R tmp_reg0) ::          (*       regionDescUseProfInf   *)
	   I.addl(L (NameLab "allocProfNowFin"), R tmp_reg0) ::               (*     + regionDescUseProfFin   *)
	   I.movl(R tmp_reg0, L (NameLab "maxProfStack")) ::                  (*     + allocProfNowFin ;      *)
	   I.lab labCont ::                                                   (* }                            *)
	   I.movl(L timeToProfLab, R tmp_reg0) ::                             (* if ( timeToProfile )         *)
	   I.cmpl(I "0", R tmp_reg0) ::                                       (*    call __proftick(esp);     *) 
	   I.je labCont2 ::
	   I.movl (R esp, R tmp_reg1) ::              (* proftick assumes argument in tmp_reg1 *)
	   I.pushl (LA labCont2) ::                    (* push return address *)
	   I.jmp (L(NameLab "__proftick")) ::
	   I.lab labCont2 ::
	   C
	 end
       else C
	   
    fun CG_top_decl' gen_fn (lab,cc,lss) = 
      let
	val w0 = Word32.fromInt 0
	fun pw w = print ("Word is " ^ (Word32.fmt StringCvt.BIN w) ^ "\n")
	fun pws ws = app pw ws
	fun set_bit(bit_no,w) = Word32.orb(w,Word32.<<(Word32.fromInt 1,Word.fromInt bit_no))

	val size_ff = CallConv.get_frame_size cc
	val size_ccf = CallConv.get_ccf_size cc
	val size_rcf = CallConv.get_rcf_size cc
(*val _ = if size_ccf + size_rcf > 0 then die ("\ndo_gc: size_ccf: " ^ (Int.toString size_ccf) ^ " and size_rcf: " ^ 
					       (Int.toString size_rcf) ^ ".") else () (* 2001-01-08, Niels debug *)*)
	val C = base_plus_offset(esp,WORDS(size_ff+size_ccf),esp,
				 I.popl (R tmp_reg1) ::
				 I.jmp (R tmp_reg1) :: [])
	val size_spilled_region_args = List.length (CallConv.get_spilled_region_args cc)
	val reg_args = map lv_to_reg_no (CallConv.get_register_args_excluding_region_args cc)
	val reg_map = foldl (fn (reg_no,w) => set_bit(reg_no,w)) w0 reg_args
   (*
	val _ = app (fn reg_no => print ("reg_no " ^ Int.toString reg_no ^ " is an argument\n")) reg_args
	val _ = pw reg_map
   *)
      in
	gen_fn(lab,
	       do_gc(reg_map,size_ccf,size_rcf,size_spilled_region_args,
		base_plus_offset(esp,WORDS(~size_ff),esp,
                 do_prof(
		  CG_lss(lss,size_ff,size_ccf,C)))))
      end

    fun CG_top_decl(LS.FUN(lab,cc,lss)) = CG_top_decl' I.FUN (lab,cc,lss)
      | CG_top_decl(LS.FN(lab,cc,lss)) = CG_top_decl' I.FN (lab,cc,lss)

    (***************************************************)
    (* Init Code and Static Data for this program unit *)
    (***************************************************)
    fun static_data() = 
      I.dot_data :: 
      comment ("START OF STATIC DATA AREA",
      get_static_data (comment ("END OF STATIC DATA AREA",nil)))

    fun init_x86_code() = [I.dot_text]
  in
    fun CG {main_lab:label,
	    code=ss_prg: (StoreTypeCO,offset,AtySS) LinePrg,
	    imports:label list * label list,
	    exports:label list * label list,
	    safe:bool} = 
      let
	val _ = chat "[X86 Code Generation..."
	val _ = reset_static_data()
	val _ = reset_label_counter()
	val _ = add_static_data (map (fn lab => I.dot_globl(MLFunLab lab)) (main_lab::(#1 exports))) 
	val _ = add_static_data (map (fn lab => I.dot_globl(DatLab lab)) (#2 exports)) 
	val x86_prg = {top_decls = foldr (fn (func,acc) => CG_top_decl func :: acc) [] ss_prg,
		       init_code = init_x86_code(),
		       static_data = static_data()}
	val _ = chat "]\n"
      in
	x86_prg
      end

    (* ------------------------------------------------------------------------------ *)
    (*              Generate Link Code for Incremental Compilation                    *)
    (* ------------------------------------------------------------------------------ *)
    fun generate_link_code (linkinfos:label list, exports: label list * label list) : I.AsmPrg = 
      let	
	val _ = reset_static_data()
	val _ = reset_label_counter()

 	val lab_exit = NameLab "__lab_exit"
        val next_prog_unit = Labels.new_named "next_prog_unit"
	val progunit_labs = map MLFunLab linkinfos
	val dat_labs = map DatLab (#2 exports) (* Also in the root set 2001-01-09, Niels *)
(*
val _ = print ("There are " ^ (Int.toString (List.length dat_labs)) ^ " data labels in the root set. ")
val _ = List.app (fn lab => print ("\n" ^ (I.pr_lab lab))) (List.rev dat_labs)
*)
	fun slot_for_datlab((_,l),C) =
	  I.dot_globl (DatLab l) ::
	  I.dot_data ::
	  I.dot_align 4 ::
	  I.dot_size(DatLab l, 4) ::
	  I.lab (DatLab l) ::
	  I.dot_long "0" :: C

	fun slots_for_datlabs(l,C) = foldr slot_for_datlab C l

	fun toplevel_handler C =
 	  let
	    val (clos_lv,arg_lv) = CallConv.handl_arg_phreg RI.args_phreg
	    val (clos_reg,arg_reg) = (RI.lv_to_reg clos_lv, RI.lv_to_reg arg_lv)
	    val offset = if BI.tag_values() then 1 else 0
	  in
	      I.lab (NameLab "TopLevelHandlerLab") ::
	      load_indexed(arg_reg,arg_reg,WORDS offset, 
	      load_indexed(arg_reg,arg_reg,WORDS (offset+1), (* Fetch pointer to exception string *)
	      compile_c_call_prim("uncaught_exception",[SS.PHREG_ATY arg_reg],NONE,0,tmp_reg1,C)))
	  end

	fun store_exported_data_for_gc (labs,C) =
	  if gc_p() then
	    foldr (fn (l,acc) => I.pushl(LA l) :: acc) 
	    (I.pushl (I (int_to_string (List.length labs))) ::
	     I.movl(R esp, L data_lab_ptr_lab) :: C) labs
	  else C


	fun raise_insts C = (* expects exception value on stack!! *)
	  let
	    val (clos_lv,arg_lv) = CallConv.handl_arg_phreg RI.args_phreg
	    val (clos_reg,arg_reg) = (RI.lv_to_reg clos_lv, RI.lv_to_reg arg_lv)
	    val offset_codeptr = if BI.tag_values() then "4" else "0"
	  in
	    I.dot_globl(NameLab "raise_exn") ::
	    I.lab (NameLab "raise_exn") ::
	    
	    comment ("DEALLOCATE REGIONS UNTIL",
	    I.movl(L exn_ptr_lab, R tmp_reg1) ::
	    compile_c_call_prim("deallocateRegionsUntil_X86",[SS.PHREG_ATY tmp_reg1],NONE,0,tmp_reg1,

	    comment ("RESTORE EXN PTR",
	    I.movl(L exn_ptr_lab, R tmp_reg1) ::
            I.movl(D("8",tmp_reg1), R tmp_reg0) ::
            I.movl(R tmp_reg0, L exn_ptr_lab) ::

	    comment ("FETCH HANDLER EXN-ARGUMENT",
	    I.movl(D("4",esp), R arg_reg) ::

	    comment ("RESTORE ESP AND PUSH RETURN LAB",
	    I.movl(D("12", tmp_reg1), R esp) ::             (* Restore sp *)
	    I.pushl(D("0", tmp_reg1)) ::                    (* Push Return Lab *)

	    comment ("JUMP TO HANDLE FUNCTION",
	    I.movl(D("4", tmp_reg1), R clos_reg) ::         (* Fetch Closure into Closure Argument Register *)
	    I.movl(D(offset_codeptr,clos_reg), R tmp_reg0) ::

	    I.jmp (R tmp_reg0) :: C))))))
	  end

	(* primitive exceptions *)
	fun setup_primitive_exception((n,exn_string,exn_lab,exn_flush_lab),C) =
	  let
	    val string_lab = gen_string_lab exn_string
	    val _ = 
	      if BI.tag_values() then       (* Exception Name and Exception must be tagged. *)
		add_static_data [I.dot_data,
				 I.dot_align 4,
				 I.dot_globl exn_lab,
				 I.lab exn_lab,
				 I.dot_long(BI.pr_tag_w(BI.tag_exname(true))),
				 I.dot_long "0", (*dummy for pointer to next word*)
				 I.dot_long(BI.pr_tag_w(BI.tag_excon0(true))),
				 I.dot_long(int_to_string n),
				 I.dot_long "0"  (*dummy for pointer to string*),
				 I.dot_data,
				 I.dot_align 4,
				 I.dot_globl exn_flush_lab,
				 I.lab exn_flush_lab, (* The Primitive Exception is Flushed at this Address *)
				 I.dot_long "0"]
	      else
		add_static_data [I.dot_data,
				 I.dot_align 4,
				 I.dot_globl exn_lab,
				 I.lab exn_lab,
				 I.dot_long "0", (*dummy for pointer to next word*)
				 I.dot_long(int_to_string n),
				 I.dot_long "0",  (*dummy for pointer to string*)
				 I.dot_data,
				 I.dot_align 4,
				 I.dot_globl exn_flush_lab,
				 I.lab exn_flush_lab, (* The Primitive Exception is Flushed at this Address *)
				 I.dot_long "0"]
	  in
	    if BI.tag_values() then
	      comment ("SETUP PRIM EXN: " ^ exn_string,
	      load_label_addr(exn_lab,SS.PHREG_ATY tmp_reg0,tmp_reg0,0,
	      I.movl(R tmp_reg0, R tmp_reg1) ::
	      I.addl(I "8", R tmp_reg1) ::
	      I.movl(R tmp_reg1, D("4",tmp_reg0)) ::
	      load_label_addr(string_lab,SS.PHREG_ATY tmp_reg1,tmp_reg1,0,
	      I.movl(R tmp_reg1,D("16",tmp_reg0)) ::
	      load_label_addr(exn_flush_lab,SS.PHREG_ATY tmp_reg1,tmp_reg1,0, (* Now flush the exception *)
	      I.movl(R tmp_reg0, D("0",tmp_reg1)) :: C))))
	    else
	      comment ("SETUP PRIM EXN: " ^ exn_string,
	      load_label_addr(exn_lab,SS.PHREG_ATY tmp_reg0,tmp_reg0,0,
              I.movl(R tmp_reg0, R tmp_reg1) ::
	      I.addl(I "4", R tmp_reg1) ::
	      I.movl(R tmp_reg1,D("0",tmp_reg0)) ::
	      load_label_addr(string_lab,SS.PHREG_ATY tmp_reg1,tmp_reg1,0,
	      I.movl(R tmp_reg1,D("8",tmp_reg0)) ::
	      load_label_addr(exn_flush_lab,SS.PHREG_ATY tmp_reg1,tmp_reg1,0, (* Now flush the exception *)
	      I.movl(R tmp_reg0,D("0",tmp_reg1)) :: C))))
	  end

	val primitive_exceptions = [(0, "Match", NameLab "exn_MATCH", DatLab BI.exn_MATCH_lab),
				    (1, "Bind", NameLab "exn_BIND", DatLab BI.exn_BIND_lab),
				    (2, "Overflow", NameLab "exn_OVERFLOW", DatLab BI.exn_OVERFLOW_lab),
				    (3, "Interrupt", NameLab "exn_INTERRUPT", DatLab BI.exn_INTERRUPT_lab),
				    (4, "Div", NameLab "exn_DIV", DatLab BI.exn_DIV_lab)]
	val initial_exnname_counter = 5

	fun init_primitive_exception_constructors_code C = 
	  foldl (fn (t,C) => setup_primitive_exception(t,C)) C primitive_exceptions

	val static_data = 
	  slots_for_datlabs(global_region_labs,
			    I.dot_data ::
			    I.dot_globl exn_counter_lab ::
			    I.lab exn_counter_lab :: (* The Global Exception Counter *)
			    I.dot_long (int_to_string initial_exnname_counter) ::

			    I.dot_globl exn_ptr_lab ::
			    I.lab exn_ptr_lab :: (* The Global Exception Pointer *)
			    I.dot_long "0" :: nil)
	val _  = add_static_data static_data

	(* args can only be tmp_reg0 and tmp_reg1; no arguments 
	 * on the stack; only the return address! *)
	fun ccall_stub(stubname, cfunction, args, res, C) =  (* result in tmp_reg1 if ret=true *)
	  let 
	    fun push_callersave_regs C = 
	      foldl (fn (r, C) => I.pushl(R r) :: C) C caller_save_regs_ccall
	    fun pop_callersave_regs C = 
	      foldr (fn (r, C) => I.popl(R r) :: C) C caller_save_regs_ccall
	    val size_ff = 0 (* dummy *)
	    val stublab = NameLab stubname
	    val res = if res then SOME (SS.PHREG_ATY tmp_reg1) else NONE
	  in 
	    I.dot_text ::
	    I.dot_globl stublab ::
	    I.lab stublab ::
	    push_callersave_regs
	    (compile_c_call_prim(cfunction, map SS.PHREG_ATY args, res, size_ff, eax,
	      pop_callersave_regs 
              (I.popl(R tmp_reg0) ::
	       I.jmp(R tmp_reg0) :: C)))
	  end       	     

	fun allocate C = (* args in tmp_reg1 and tmp_reg0; result in tmp_reg1. *)
	  ccall_stub("__allocate", "alloc", [tmp_reg1, tmp_reg0], true, C)

	fun resetregion C = 
	  ccall_stub("__reset_region", "resetRegion", [tmp_reg1], true, C)

	fun proftick C =
	  if region_profiling() then
	    ccall_stub("__proftick", "profileTick", [tmp_reg1], false, C)
	  else C

	fun overflow_stub C =
	  let val stublab = NameLab "__raise_overflow"
	  in I.dot_text ::
	     I.dot_globl stublab ::
	     I.lab stublab ::
             I.pushl(L(DatLab BI.exn_OVERFLOW_lab)) ::
             I.call(NameLab "raise_exn") :: C   (*the call never returns *)
	  end

	fun gc_stub C = (* tmp_reg1 must contain the register map and tmp_reg0 the return address. *)
	  if gc_p() then
	    let
	      fun push_all_regs C = 
		foldr (fn (r, C) => I.pushl(R r) :: C) C all_regs
	      fun pop_all_regs C = 
		foldl (fn (r, C) => I.popl(R r) :: C) C all_regs
	      fun pop_size_ccf_rcf_reg_args C = base_plus_offset(esp,WORDS(3),esp,C) (* they are pushed in do_gc *)
	      val size_ff = 0 (*dummy*)
	    in
	      I.dot_text ::
	      I.dot_globl gc_stub_lab ::
	      I.lab gc_stub_lab ::
	      push_all_regs (* The return lab and ecx are also preserved *)
	      (copy(esp,tmp_reg0,
		    compile_c_call_prim("gc",[SS.PHREG_ATY tmp_reg0,SS.PHREG_ATY tmp_reg1],NONE,size_ff,eax,
					pop_all_regs( (* The return lab and tmp_reg0 are also popped again *)
					pop_size_ccf_rcf_reg_args(
					(I.jmp(R tmp_reg0) :: C))))))
	    end
	  else C

	fun generate_jump_code_progunits(progunit_labs,C) = 
	  foldr (fn (l,C) => 
		 let val next_lab = new_local_lab "next_progunit_lab"
		 in
		   comment ("PUSH NEXT LOCAL LABEL",
		   I.pushl(LA next_lab) ::
		   comment ("JUMP TO NEXT PROGRAM UNIT",
		   I.jmp(L l) :: 
		   I.dot_long "0XFFFFFFFF" :: (* Marks, no more frames on stack. Used to calculate rootset. *)
		   I.dot_long "0XFFFFFFFF" :: (* An arbitrary offsetToReturn *)
		   I.dot_long "0XFFFFFFFF" :: (* An arbitrary function number. *)
                   I.lab next_lab :: C))
		 end) C progunit_labs

	fun allocate_global_regions(region_labs,C) = 
	  let 
	    fun maybe_push_region_id (region_id,C) = 
	      if region_profiling() then I.pushl(I (int_to_string region_id)) :: C
	      else C
	    val c_name = if region_profiling() then "allocRegionInfiniteProfiling"
			 else "allocateRegion"
	    fun pop_args C =
	      if region_profiling() then I.addl(I "8", R esp) :: C (* two arguments to pop *)
	      else I.addl(I "4", R esp) :: C                       (* one argument to pop *)
	  in
	    foldl (fn ((region_id,lab),C) =>
		   I.subl(I(int_to_string(4*BI.size_of_reg_desc())), R esp) ::
		   I.movl(R esp, R tmp_reg1) ::
                   maybe_push_region_id (region_id,
		   I.pushl(R tmp_reg1) ::
		   I.call(NameLab c_name) ::
		   pop_args 
		   (I.movl(R eax, L (DatLab lab)) :: C))) C region_labs
	  end

	fun push_top_level_handler C =
	  let 
	    fun gen_clos C = 
	      if BI.tag_values() then 
		copy(esp, tmp_reg1,
		I.addl(I "-4", R tmp_reg1) ::
		I.movl(R tmp_reg1, D("4", esp)) :: C)
	      else
		I.movl(R esp, D("4", esp)) :: C		  
	  in
            comment ("PUSH TOP-LEVEL HANDLER ON STACK",
	    I.subl(I "16", R esp) ::
	    I.movl(LA (NameLab "TopLevelHandlerLab"), D("0", esp)) ::
	    gen_clos (	    
	    I.movl(L exn_ptr_lab, R tmp_reg1) ::
            I.movl(R tmp_reg1, D("8", esp)) ::
	    I.movl(R esp, D("12", esp)) ::
	    I.movl(R esp, L exn_ptr_lab) :: C))
	  end

	fun init_stack_bot_gc C = 
	  if gc_p() then  (* stack_bot_gc[0] = esp *)
	    I.movl(R esp, L stack_bot_gc_lab) :: C
	  else C

	fun init_prof C = 
	  if region_profiling() then  (* stack_bot_gc[0] = esp *)
	    I.movl(R esp, L (NameLab "stackBot")) :: 
	    I.movl(R esp, L (NameLab "maxStack")) :: 
	    I.movl(R esp, L (NameLab "maxStackP")) :: 
	    C
	  else C

	fun main_insts C =
	   (I.dot_text ::
	    I.dot_align 4 ::
	    I.dot_globl (NameLab "code") ::
	    I.lab (NameLab "code") ::

	    (* Put data labels on the stack; they are part of the root-set. *)
	    store_exported_data_for_gc (dat_labs,

	    (* Allocate global regions and push them on stack *)
	    comment ("Allocate global regions and push them on the stack",
	    allocate_global_regions(global_region_labs,

	    (* Initialize primitive exceptions *)
            init_primitive_exception_constructors_code(

	    (* Push top-level handler on stack *)
	    push_top_level_handler(

	    (* Initialize stack_bot_gc. *)
	    init_stack_bot_gc(

            (* Initialize profiling *)
            init_prof(
            
	    (* Code that jump to progunits. *)
	    comment ("JUMP CODE TO PROGRAM UNITS",
	    generate_jump_code_progunits(progunit_labs,

            (* Exit instructions *)
	    compile_c_call_prim("terminateML", [mkIntAty 0], 
				NONE,0,eax, (* instead of res we might use the result from 
					     * the last function call, 2001-01-08, Niels *)
	    (*I.leave :: *)
	    I.ret :: C)))))))))))

	val init_link_code = (main_insts o raise_insts o 
			      toplevel_handler o allocate o resetregion o 
			      overflow_stub o gc_stub o proftick) nil
      in
	{top_decls = [],
	 init_code = init_link_code,
	 static_data = get_static_data []}
      end
  end


  (* ------------------------------------------------------------ *)
  (*  Emitting Target Code                                        *)
  (* ------------------------------------------------------------ *)
  fun emit(prg: AsmPrg,filename: string) : unit = 
    (I.emit(prg,filename);
     print ("[wrote X86 code file:\t" ^ filename ^ "]\n"))
    handle IO.Io {name,...} => Crash.impossible ("X86KAMBackend.emit:\nI cannot open \""
						 ^ filename ^ "\":\n" ^ name)

end
