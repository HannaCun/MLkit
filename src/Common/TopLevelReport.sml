(* Top-level reporting: ties static and dynamic basis together, generates
   a report of bindings. *)

functor TopLevelReport(structure FunId: FUNID
		       structure SigId: SIGID
		       structure StrId: STRID
		       structure Ident: IDENT

		       structure InfixBasis: INFIX_BASIS

		       structure StatObject: STATOBJECT

		       structure Environments: ENVIRONMENTS
			 sharing type Environments.strid = StrId.strid
			 sharing type Environments.id = Ident.id
			 sharing type Environments.Type = StatObject.Type
			 sharing type Environments.TypeScheme
				      = StatObject.TypeScheme

		       structure ModuleStatObject: MODULE_STATOBJECT
			 sharing type ModuleStatObject.Env
				      = Environments.Env

		       structure ModuleEnvironments: MODULE_ENVIRONMENTS
			 sharing type ModuleEnvironments.sigid = SigId.sigid
			 sharing type ModuleEnvironments.funid = FunId.funid
			 sharing type ModuleEnvironments.Sig
				      = ModuleStatObject.Sig
			 sharing type ModuleEnvironments.FunSig
				      = ModuleStatObject.FunSig
			 sharing type ModuleEnvironments.Env
			              = Environments.Env

		       structure Report: REPORT
			 sharing type InfixBasis.Report
				      = Environments.Report
			   	      = ModuleEnvironments.Report
				      = Report.Report

		       structure Crash: CRASH
		      ): TOP_LEVEL_REPORT =
  struct
    type ElabBasis = ModuleEnvironments.Basis
    type InfixBasis = InfixBasis.Basis
    type Report = Report.Report

    (*import from Environments:*)
    structure VE           = Environments.VE
    structure TyStr        = Environments.TyStr
    structure TE           = Environments.TE
    structure SE           = Environments.SE
    structure E            = Environments.E
    structure C            = Environments.C

    (*import from ModuleEnvironments:*)
    structure G            = ModuleEnvironments.G
    structure F            = ModuleEnvironments.F
    structure B            = ModuleEnvironments.B 

    (*import from ModuleStatObject:*)
    structure Sigma        = ModuleStatObject.Sigma
    structure Phi          = ModuleStatObject.Phi

    (*import from StatObject:*)
    structure TyVar        = StatObject.TyVar
    structure TyName       = StatObject.TyName
    structure Type         = StatObject.Type
    structure TypeScheme   = StatObject.TypeScheme
    structure Substitution = StatObject.Substitution
    structure TypeFcn      = StatObject.TypeFcn
    structure Realisation  = StatObject.Realisation

    val // = Report.//     infix //


   (* We report a top-level environment (a Basis in fact) by traversing
      the static environment. For each item found, we print out a
      sensible dynamic value, looking in the dynamic environment for
      a representation if required. `report' can also be told to ignore
      the dynamic side of things. Note that Environments and
      ModuleEnvironments have a lot of reporting functions already, and
      can happily handle the cases where no dynamic information is needed.
      Oh: we deal with the infix basis here as well. *)

    fun reportVE (render, pathR, VE, bindings) =
      VE.report
	(fn (id, VE.LONGVAR sigma) => 
	      Report.line ("val "
			   ^ Ident.pr_id id
			   ^ (if bindings then " = " ^ render (pathR, id, sigma)
			      else "")
	                   ^ " : "
	                   ^ TypeScheme.pretty_string
	                       (StatObject.newTVNames ()) sigma)
          | (id, VE.LONGCON sigma) =>
	      Report.null 	(*We'll get the cons when we walk over
				 the TyStr's in the TE.*)
	  | (id, VE.LONGEXCON tau) =>
	      Report.line ("exception " ^ Ident.pr_id id
			   ^ (if Type.is_Exn tau then ""
			      else
				" of "
				^ (case Type.un_Arrow tau of
				     SOME (domTy, _) => Type.string domTy
				   | NONE => Crash.impossible "TopLevelReport.reportVE"))) ,
	 VE)

    fun reportSig(sigid, Sig) =
      let
	val (_, E) = Sigma.to_T_and_E Sig
      in
	   Report.line ("signature " ^ SigId.pr_SigId sigid ^ " =")
	// Report.line "  sig"
	// Report.indent (4, reportEnvSTATIC E)
	// Report.line "  end"
      end

   (* I can't explain how I print out functors; run the damn thing and see
      for yourself. *)

    and reportFunSig(funid, funsig') =
      let
	val (_, E, N'E') = Phi.to_T_and_E_and_Sigma funsig'
	val (_, E') = Sigma.to_T_and_E N'E'

	val heading = "functor " ^ FunId.pr_FunId funid ^ "("
	val tab = String.size heading - 1
      in
	Report.decorate (heading, reportEnvSTATIC E)
	  // Report.indent (tab,    Report.line "): sig"
			    // Report.indent(5, reportEnvSTATIC E')
			    // Report.line "   end")
      end

    and reportSE(render, pathR, SE, bindings) =
      SE.report(
	fn (strId, E) =>
	  Report.line("structure "
		      ^ StrId.pr_StrId strId
		      ^ (if bindings then " =" else " :")
		     )
	  // Report.line(if bindings then "  struct" else "  sig")
	  // Report.indent(4, reportEnv (render, strId :: pathR, E, bindings))
	  // Report.line "  end",
	SE
      )

    and reportEnvSTATIC E = 
          reportEnv (fn _ => Crash.impossible "TopLevelReport.reportEnvSTATIC",
		     [], E, false)

    and reportEnv(render, pathR, env, bindings) =
      let
	val (SE, TE, VE) = E.un env
      in
	reportSE(render, pathR, SE, bindings)
	// TE.report {tyEnv=TE, bindings=bindings}
	// reportVE(render, pathR, VE, bindings)
      end

    fun reportStaticBasis(render, sb: ElabBasis, bindings: bool)
          : Report =
      let
	val funenv = B.to_F sb
	val sigenv = B.to_G sb
	val env = B.to_E sb
      in		(* Sigs first; looks better (though in fact SML's
			   top-level syntax is knobbled so they can't be
			   mixed). *)
	G.report (reportSig, sigenv)
	// F.report (reportFunSig, funenv)
	// reportEnv(render, nil, env, bindings)
      end

    fun report{infB=ib,elabB=sb, bindings} =
      let
(*	val db =  (* Might be void (ELAB_ONLY) *) *)

	fun render(pathR, id, tyScheme) = ""
(*	  ValPrint.print(ValPrint.locate(db, rev pathR, id), tyScheme) *)
      in
	Report.decorate("> ", InfixBasis.reportBasis ib
			      // reportStaticBasis(render, sb, bindings)
		       )
      end
  end;