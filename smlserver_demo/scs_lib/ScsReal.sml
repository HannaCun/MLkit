signature SCS_REAL =
  sig

    (* [toString lang r] returns the string representation of real r
       in language lang *)
    val toString : ScsLang.lang -> real -> string

    (* [fromString lang r] try to convert a string representation r of
       a real written in language lang to a real *)
    val fromString : ScsLang.lang -> string -> real

      (* [normReal r] normalises a real, that is, a real i format
         ([0-9]*(\.|\,)[0-9]* )+ has the last . or , turned into a
         . and the rest of , and . removed. The following will convert
         a real typed in many stupid ways into an ML real:

             val r = Real.fromString (normReal r) *)
    val normReal : string -> string
  end

structure ScsReal :> SCS_REAL =
  struct
    fun toString ScsLang.da r = 
      String.map (fn c => if c = #"." then #"," else if c = #"," then #"." else c)
      (Real.fmt (StringCvt.FIX(SOME 2)) r)
    | toString ScsLang.en r = Real.fmt (StringCvt.FIX(SOME 2)) r

    local
      fun fromString' s =
	case Real.fromString s of
	  NONE => ScsError.panic `ScsLang.fromString: ^s not a real`
	| SOME r => r
    in
      fun fromString ScsLang.da s =
	fromString' (String.map (fn c => if c = #"." then #"," else if c = #"," then #"." else c) s)
      | fromString ScsLang.en s = fromString' s
    end

    fun normReal r =
      let
	val l_rev = List.rev (String.explode r)
	fun f [] = []
	  | f (c::xs) = if c = #"." orelse c = #"," then #"." :: f' xs else c :: f xs
	and f' [] = []
	  | f' (c::xs) = if c = #"." orelse c = #"," then f' xs else c :: f' xs
      in
	String.implode (List.rev (f l_rev))
      end
  end
