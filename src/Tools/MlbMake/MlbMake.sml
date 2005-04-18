structure Listsort =
  struct
    fun sort ordr xs =
      let 
	fun merge []      ys = ys 
	  | merge xs      [] = xs
	  | merge (x::xs) (y::ys) =
	  if ordr(x, y) <> GREATER then x :: merge xs (y::ys)
	  else y :: merge (x::xs) ys
	fun mergepairs l1  []              k = [l1]
	  | mergepairs l1 (ls as (l2::lr)) k =
	  if k mod 2 = 1 then l1::ls
	  else mergepairs (merge l1 l2) lr (k div 2)
        fun nextrun run []      = (run, [])
          | nextrun run (xs as (x::xr)) =
	  if ordr(x, List.hd run) = LESS then (run, xs)
	  else nextrun (x::run) xr
        fun sorting []      ls r = List.hd(mergepairs [] ls 0)
          | sorting (x::xs) ls r =
	  let val (revrun, tail) = nextrun [x] xs
	  in sorting tail (mergepairs (List.rev revrun) ls (r+1)) (r+1) 
	  end
      in sorting xs [] 0 
      end
  end	

structure Options =
    struct
	fun opt s = case explode s of 
	    #"-":: #"-"::rest => SOME (implode rest)
	  | #"-"::rest => SOME (implode rest)
	  | _ => NONE

	fun lookup_key key (l:(string *('a->unit))list) : ('a -> unit) option =
	    let fun look nil = NONE
		  | look ((x,f)::rest) = if key=x then SOME f else look rest
	    in look l
	    end

	fun read_options  {nullary:(string*(unit->unit))list,
			   unary:(string*(string->unit))list,
			   options: string list} : string list =
	    let	
		fun loop nil = nil
		  | loop (all as s::ss) =
		    case opt s of 
			SOME key => 	      
			    let 
				fun try_nullary exn =
				    case lookup_key key nullary of 
					SOME f => (f(); loop ss)
				      | NONE => raise Fail exn
			    in case lookup_key key unary of 
				SOME f => 
				    (case ss
					 of s::ss => (f s; loop ss)
				       | nil => try_nullary ("missing argument to " ^ s))
			      | NONE => try_nullary ("unknown option: " ^ s)
			    end
		      | NONE => all
	    in loop options
	    end
    end

signature COMP =
  sig
     val name : string
     val compile : {basisFiles: string list, 
		    source: string, 
		    namebase: string,     (* for uniqueness of type names, etc *)
		    target: string, 
		    flags: string} -> string
     val link : {target: string, lnkFiles: string list, flags: string} -> string option

     val mlbdir : unit -> string
     val objFileExt : unit -> string (* e.g., .o *)
  end

fun pp_list sep nil = ""
  | pp_list sep [x] = x 
  | pp_list sep (x::xs) = x ^ sep ^ pp_list sep xs

structure MLKitComp : COMP =
    struct
	val name = "mlkit"
	val default_mlkitexe = "/usr/bin/mlkit"
	fun mlkitexe() = 
	    case OS.Process.getEnv "MLB_MLKIT" of
		SOME exe => exe
	      | NONE => default_mlkitexe
	fun compile {basisFiles: string list, 
		     source: string, 
		     target: string,  (* file.o -> file.o.lnk, file.o, file.o.eb *)
		     namebase: string,
		     flags: string} : string =
	    let val s = mlkitexe() ^ " -c -no_cross_opt -namebase " ^ namebase ^ " -o " ^ target
		val s = if flags = "" then s else s ^ " " ^ flags
		val s = case basisFiles of nil => s | _ => s ^ " -load " ^ pp_list " " basisFiles
	    in s ^ " " ^ source
	    end
	fun link {target: string, lnkFiles: string list, flags:string} : string option =
	    SOME(mlkitexe() ^ " " ^ flags ^ " -o " ^ target ^ " -link " ^ pp_list " " lnkFiles)

	fun mlbdir() = "MLB/MLKit"
	fun objFileExt() = ".o"
    end

structure BarryComp : COMP =
    struct
	val name = "barry"
	val default_barryexe = "/usr/bin/barry"
	fun compile {basisFiles: string list, 
		     source: string, 
		     target: string,  (* file.o -> file.o.lnk, file.o, file.o.eb *)
		     namebase: string,
		     flags: string} : string =
	    let fun barryexe() = 
		  case OS.Process.getEnv "MLB_BARRY" of
		      SOME exe => exe
		    | NONE => default_barryexe
		val s = barryexe() ^ " -c -no_cross_opt -namebase " ^ namebase ^ " -o " ^ target
		val s = if flags = "" then s else s ^ " " ^ flags
		val s = case basisFiles of nil => s | _ => s ^ " -load " ^ pp_list " " basisFiles
	    in s ^ " " ^ source
	    end
	fun link {target: string, lnkFiles: string list, flags: string} : string option = NONE

	fun mlbdir() = "MLB/Barry"
	fun objFileExt() = ".b"
    end
	
(* [mlkit-mlb flags sources.mlb] Flags not recognized by mlkit-mlb are
 * sent to the compiler for each invocation. A directory MLB is
 * constructed for storing compilation and link information. *)

(* Idea: different combinations of "behavioral" options (e.g., 
 * -gc,-prof) could result in information being stored in different
 * subdirectories to MLB. *)


functor Mlb(structure C: COMP
	    val verbose : bool ref
	    val oneSrcFile : string option ref)
    : sig val build : string -> string -> unit 
      end =
struct
    structure MlbProject = MlbProject()

    (* -------------------------------------------
     * Some operations on directories and files
     * ------------------------------------------- *)

    fun quot s = "'" ^ s ^ "'"

    local
	fun err s = print ("\nError: " ^ s ^ ".\n\n"); 
    in
	fun error (s : string) = (err s; raise Fail "error")	    
	fun errors (ss:string list) = 
	    (app err ss; raise Fail "error")
    end

    fun vchat s = if !verbose then print (" ++ " ^ s ^ "\n") else ()

    local
	fun fileFromSmlFile smlfile ext =
	    let val {dir,file} = OS.Path.splitDirFile smlfile
		infix ##
		val op ## = OS.Path.concat
	    in dir ## C.mlbdir () ## (file ^ ext)
	    end
    in
	fun objFileFromSmlFile mlbfile smlfile =
	    fileFromSmlFile smlfile (C.objFileExt())

	fun lnkFileFromSmlFile mlbfile smlfile = 
	    objFileFromSmlFile mlbfile smlfile ^ ".lnk"

	fun ebFileFromSmlFile mlbfile smlfile = 
	    objFileFromSmlFile mlbfile smlfile ^ ".eb"

	fun depFileFromSmlFile smlfile =
	    fileFromSmlFile smlfile ".d"
    end

    fun maybe_create_dir d : unit = 
      if OS.FileSys.access (d, []) handle _ => error ("I cannot access directory " ^ quot d) then
	if OS.FileSys.isDir d then ()
	else error ("The file " ^ quot d ^ " is not a directory")
      else ((OS.FileSys.mkDir d;()) handle _ => 
	    error ("I cannot create directory " ^ quot d ^ " --- the current directory is " ^ 
		   OS.FileSys.getDir()))

    fun maybe_create_mlbdir() =
      let val dirs = String.tokens (fn c => c = #"/") (C.mlbdir())
	fun append_path "" d = d
	  | append_path p d = p ^ "/" ^ d
	fun loop (p, nil) = ()
	  | loop (p, d::ds) = let val p = append_path p d
			      in maybe_create_dir p; loop(p, ds)
			      end
      in loop("", dirs)
      end

    fun change_dir p : {cd_old : unit -> unit, file : string} =
      let val {dir,file} = OS.Path.splitDirFile p
      in if dir = "" then {cd_old = fn()=>(),file=file}
	 else let val old_dir = OS.FileSys.getDir()
	          val _ = OS.FileSys.chDir dir
	      in {cd_old=fn()=>OS.FileSys.chDir old_dir, file=file}
	      end handle OS.SysErr _ => error ("I cannot access directory " ^ quot dir)
      end

    fun mkAbs file = OS.Path.mkAbsolute(file,OS.FileSys.getDir())

    fun subDir "" = (fn p => p)
      | subDir dir =
	let val dir_abs = mkAbs dir
	    in fn p =>
		let val p_abs = mkAbs p
		in OS.Path.mkRelative(p_abs,dir_abs)
		end
	end

    fun dirMod dir file = if OS.Path.isAbsolute file then file
			  else OS.Path.concat(dir,file)

    (* --------------------
     * Build an mlb-project
     * -------------------- *)

    fun readDependencies smlfile = 
	let val dir = OS.Path.dir smlfile
	    val depFile = depFileFromSmlFile smlfile
	    val is = TextIO.openIn depFile
	in let val all = TextIO.inputAll is handle _ => ""
	       val smlfiles = String.tokens Char.isSpace all
	       val smlfiles = map (dirMod dir) smlfiles   
	       val _ = vchat ("Dependencies for " ^ smlfile ^ ": " ^ all)
	   in TextIO.closeIn is; smlfiles
	   end handle _ => (TextIO.closeIn is; nil)
	end handle _ => nil

    fun recompileUnnecessary mlbfile smlfile : bool =
    (* f.sml<f.{lnk,eb} and f.d<f.{lnk,eb} and forall g \in F(f.d) . g.eb < f.lnk *)
	let val _ = vchat ("Checking necessity of recompiling " ^ smlfile)
	    fun modTime f = OS.FileSys.modTime f
	    val op < = Time.<=
	    val lnkFile = lnkFileFromSmlFile mlbfile smlfile
	    val ebFile = ebFileFromSmlFile mlbfile smlfile
	    val depFile = depFileFromSmlFile smlfile
	    val modTimeSmlFile = modTime smlfile handle X => (vchat "modTime SMLfile"; raise X)
	    val modTimeLnkFile = modTime lnkFile handle X => (vchat "modTime lnkFile"; raise X)
	    fun debug(s,b) = (vchat(s ^ ":" ^ Bool.toString b); b)
	in modTimeSmlFile < modTimeLnkFile 
	    andalso
	    let val modTimeEbFile = modTime ebFile handle X => (vchat ("modTime ebFile " ^ ebFile); raise X)
	    in modTimeSmlFile < modTimeEbFile 
		andalso
		let val modTimeDepFile = modTime depFile handle X => (vchat "modTime depFile"; raise X)
		in modTimeDepFile < modTimeLnkFile
		    andalso
		    modTimeDepFile < modTimeEbFile
		    andalso
		    List.all (fn smlfile => modTime (ebFileFromSmlFile mlbfile smlfile) < modTimeLnkFile)
		    (readDependencies smlfile)
		end
	    end
	end handle _ => false

    fun system cmd : unit = 
	(vchat ("Executing command: " ^ cmd) ;
	let 
	    val status = OS.Process.system cmd
		handle _ => error ("Command failed: " ^ quot cmd)
	in if status = OS.Process.failure then
	    error ("Command failed: " ^ quot cmd)
	   else ()
	end
	 )
	
    fun build_mlb_one (flags:string) (mlbfile:string) (smlfile:string) : unit =
	if recompileUnnecessary mlbfile smlfile then ()
	else 
	let val _ = vchat ("Reading dependencies for " ^ smlfile)
	    val deps = readDependencies smlfile
	    val basisFiles = map (ebFileFromSmlFile mlbfile) deps
	    val cmd = C.compile {basisFiles=basisFiles,source=smlfile,
				 target=objFileFromSmlFile mlbfile smlfile,
				 namebase=OS.Path.file mlbfile ^ "-" ^ OS.Path.file smlfile,
				 flags=flags}
	in system cmd
	end

    fun map2 f ss = map (fn (x,y) => (f x,f y)) ss

    fun check_sources srcs_mlbs =
	let (* first canonicalize paths *)
	    val srcs_mlbs = map2 OS.Path.mkCanonical srcs_mlbs
	    fun report(s,m1,m2) =
		let val first = "The file " ^ quot s ^ " is referenced "
		in if m1 = m2 then first ^ "more than once in " ^ quot m1
		   else first ^ "in both " ^ quot m1 
		       ^ " and " ^ quot m2
		end
	    fun porder ((s1,m1),(s2,m2)) =
		if s1 < s2 then LESS
		else if s1 = s2 then
		        (if m1 < m2 then LESS
			 else if m1 = m2 then EQUAL
			      else GREATER)
		     else GREATER				
	    val srcs_mlbs = 
	      Listsort.sort porder srcs_mlbs
	    fun check ((s1,m1)::(s2,m2)::rest,acc) =
		check((s2,m2)::rest,
		      if s1 = s2 then (s1,m1,m2)::acc
		      else acc)
	      | check (_,nil) = ()
	      | check (_,acc) =	(errors (map report acc))
	in check (srcs_mlbs,nil)
	end

    fun writeFile f c =
	let val os = TextIO.openOut f
	in (TextIO.output(os,c) before TextIO.closeOut os)
	    handle _ => TextIO.closeOut os
	end

    fun maybeWriteDefaultMlbFile mlbfile : string =
	case OS.Path.ext mlbfile of
	    SOME "sml" =>
		let val content =
		      "local open $(SML_LIB)/basis/basis.mlb in " 
		      ^ mlbfile ^ " end"
		    val file = mlbfile ^ ".mlb"
		in (writeFile file content; file)
		    handle _ => error ("Failed to generate file " ^ file)
		end
	  | SOME "mlb" => mlbfile
	  | _ => error "Expects file with extension '.mlb' or '.sml'"

    fun del f = OS.FileSys.remove f handle _ => ()

    exception Exit
    fun maybeWriteOneSourceFile ss =
	case !oneSrcFile of
	    NONE => ()
	  | SOME f => 
		let fun readAll s =
		      let val is = TextIO.openIn s
		      in TextIO.inputAll is
		      end
		    fun appendAll st =
			let val os = TextIO.openAppend f
			in TextIO.output(os,st)
			end
		    fun w s =
			let val st = readAll s
			in appendAll st
			end
		in del f; app w ss; raise Exit
		end

    fun build flags mlbfile =
	let val mlbfile = maybeWriteDefaultMlbFile mlbfile
	    val _ = vchat ("Finding sources...\n")		
	    val srcs_mlbs : (string * string) list = MlbProject.sources mlbfile
	    val _ = check_sources srcs_mlbs
	    val ss = map #1 srcs_mlbs

	    val _ = maybeWriteOneSourceFile ss

	    val _ = vchat ("Updating dependencies...\n")
	    val _ = maybe_create_mlbdir()
	    val _ = MlbProject.depDir := C.mlbdir()
	    val _ = MlbProject.dep mlbfile
		
	    val _ = vchat ("Compiling...\n")		
	    val _ = app (build_mlb_one flags mlbfile) ss

	    val _ = vchat ("Linking...\n")		
	    val lnkFiles = map (lnkFileFromSmlFile mlbfile) ss
	in case C.link {target="a.out",lnkFiles=lnkFiles,flags=flags} of
	    SOME cmd => system cmd
	  | NONE => ()
	end handle Exit => ()

end

structure Main : 
    sig 
	val cmdName : unit -> string
	val mlbmake : string * string list -> OS.Process.status
    end =
struct

    val verbose = ref false
    fun vchat0 s = if !verbose then print s else ()

    val oneSrcFile : string option ref = ref NONE
    structure MlbMLKit = Mlb(structure C = MLKitComp
			     val verbose = verbose
			     val oneSrcFile = oneSrcFile) 

    structure MlbBarry = Mlb(structure C = BarryComp
			     val verbose = verbose
			     val oneSrcFile = oneSrcFile) 

(*    structure MlbMosml = Mlb(MosmlComp) *)

    fun error (s : string) = (print ("\nError: " ^ s ^ ".\n\n"); 
			      raise Fail "error")

    val date = Date.fmt "%b %d, %Y" (Date.fromTimeLocal (Time.now()))
    val version = "0.2"

    fun cmdName() = "mlbmake"
	    
    fun greetings comp =
	cmdName() ^ " version " ^ version ^ comp ^ ", " ^ date ^ "\n"

    fun print_usage() = print ("\nUsage: " ^ cmdName() ^ " {-mlkit|-mosml} [OPTION]*... [file.mlb] [COMPILER OPTION]*\n\n" ^
			       "Options:\n\n")

    val options = [("-compiler {mlkit,barry}", ["Specify compiler to use (default: mlkit)."]),
		   ("-oneSrcFile s", ["Copy all sources to the file s and exit."]),
		   ("-version", ["Print version information and exit."]),
		   ("-help", ["Print help information and exit."])
		   ]

    fun print_indent nil = ()
      | print_indent (s::ss) = (print ("     " ^ s ^ "\n"); print_indent ss)
	
    fun print_options() = app (fn (t, l) => (print(t ^ "\n"); print_indent l; print "\n")) options
 
    val compiler = ref "mlkit"

    val unary_options =
	[("compiler", fn s => compiler := s),
	 ("oneSrcFile", fn s => oneSrcFile := SOME s)]

    fun show_version() =
	(print (greetings(!compiler)); OS.Process.exit OS.Process.success)

    val nullary_options =
	[("version", fn () => show_version()),
	 ("V", fn () => show_version()),
	 ("verbose", fn () => verbose := true),
	 ("v", fn () => verbose := true),	 
   	 ("help", fn () => (print (greetings(!compiler));
			    print_usage();
			    print_options();
			    OS.Process.exit OS.Process.success))]
	
    fun mlbmake (cmd,args) = 
	(let val rest = Options.read_options{options=args, 
					     nullary=nullary_options,
					     unary=unary_options}
	     val _ = vchat0(greetings(!compiler))
	     val build = 
		 case !compiler of
		     "mlkit" => MlbMLKit.build
		   | "barry" => MlbBarry.build
		   | comp => error ("compiler " ^ comp ^ " not supported")
	     fun sappend nil = ""
	       | sappend [x] = x
	       | sappend (x::xs) = x ^ " " ^ sappend xs
	 in case rest of
	    mlbfile :: flags => (build (sappend flags) mlbfile; OS.Process.success) 
	  | _ => error "I expect exactly one mlb-file as argument"
	 end handle _ => OS.Process.failure)
end