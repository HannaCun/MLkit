
(* Build-file for the compiler. It returns a compile basis structure
 * and a compile structure. 
 *)

signature BUILD_COMPILE = 
  sig
    structure CompilerEnv : COMPILER_ENV
    structure CompileBasis: COMPILE_BASIS
    structure Compile: COMPILE
    structure CallConv : CALL_CONV
    structure LineStmt : LINE_STMT
    structure SubstAndSimplify : SUBST_AND_SIMPLIFY
  end  

functor BuildCompile (structure BackendInfo : BACKEND_INFO
		      structure RegisterInfo : REGISTER_INFO
		      include EXECUTION_ARGS 
			where type Labels.label = BackendInfo.label
			where type Lvars.lvar = RegisterInfo.lvar
                        where type Lvarset.lvarset = RegisterInfo.lvarset) : BUILD_COMPILE =
  struct

    structure Basics = Elaboration.Basics
    structure TopdecGrammar = Elaboration.PostElabTopdecGrammar
    structure Tools = Basics.Tools
    structure PP = Tools.PrettyPrint
    structure Crash = Tools.Crash
    structure Flags = Tools.Flags
    structure FinMap = Tools.FinMap
    structure FinMapEq = Tools.FinMapEq
    structure Name = Basics.Name
    structure Report = Tools.Report
    structure IntFinMap = Tools.IntFinMap

    structure TyName = Basics.TyName
    structure DecGrammar = TopdecGrammar.DecGrammar
    structure SCon = DecGrammar.SCon
    structure Lab = DecGrammar.Lab
    structure TyVar = DecGrammar.TyVar
    structure Ident = DecGrammar.Ident
    structure StrId = DecGrammar.StrId
    structure TyCon = DecGrammar.TyCon

    structure LambdaExp =
      LambdaExp(structure Lvars = Lvars
                structure Con = Con
                structure Excon = Excon
                structure TyName = TyName
                structure PP = PP
                structure Crash = Crash
                structure Flags = Flags)

    structure LambdaBasics = 
      LambdaBasics(structure Lvars = Lvars
		   structure TyName = TyName
		   structure TLE = LambdaExp
		   structure FinMap = FinMap
		   structure FinMapEq = FinMapEq
		   structure Crash = Crash
		   structure Flags = Flags)
      
    structure NatSet = NatSet(structure PP = PP)

    structure LambdaStatSem =
      LambdaStatSem(structure Lvars = Lvars
		    structure Con = Con
		    structure Excon = Excon
		    structure TyName = TyName
		    structure Name = Name
		    structure NatSet = NatSet
		    structure LambdaExp = LambdaExp
		    structure LambdaBasics = LambdaBasics
		    structure Crash = Crash
		    structure PP = PP
		    structure Flags = Flags)

    structure EliminateEq =
      EliminateEq(structure Lvars = Lvars
		  structure Con = Con
		  structure Name = Name
		  structure TyName = TyName
		  structure LambdaExp = LambdaExp
		  structure Crash = Crash
		  structure Flags = Flags
		  structure PP = PP
		  structure TyVarMap =
		    OrderFinMap(structure Order = struct type T = LambdaExp.tyvar
							 fun lt (a:T) b = LambdaExp.lt_tyvar(a,b)
						  end
				structure PP = PP
				structure Report = Report))

    structure Stack = Stack()

    structure UnionFindPoly = UF_with_path_halving_and_union_by_rank()

    structure DiGraph = DiGraph(structure UF = UnionFindPoly
                                structure Stack = Stack
                                structure PP = PP
                                structure Flags = Flags
                                structure Crash = Crash)

   structure Effect = Effect(structure G = DiGraph
			     structure Flags = Flags
			     structure PP = PP
			     structure Crash = Crash
			     structure Report = Report)

  structure CConst = CConst(structure Flags = Flags
			    structure Crash = Crash
			    structure TyName = TyName)

   structure RType = RType(structure Flags = Flags
			   structure Crash = Crash
			   structure E = Effect
			   structure DiGraph = DiGraph
			   structure L = LambdaExp
			   structure CConst = CConst
			   structure FinMap = FinMap
			   structure TyName = TyName
			   structure PP = PP)

   structure RegionStatEnv = RegionStatEnv(
     structure Name = Name
     structure Flags=Flags
     structure R = RType 
     structure E = Effect
     structure TyName = TyName
     structure Con = Con
     structure Excon = Excon
     structure Lvar = Lvars
     structure Crash = Crash
     structure L = LambdaExp
     structure PP = PP)

   structure RegionExp = 
        RegionExp(structure R = RType
                  structure Eff = Effect
                  structure Lam = LambdaExp
                  structure Lvar = Lvars
                  structure Con = Con
                  structure Excon = Excon
                  structure TyName = TyName
                  structure Flags = Flags
                  structure Crash = Crash
                  structure PP = PP);
        
  structure SpreadDatatype = SpreadDatatype(
           structure R = RType
           structure Con = Con
           structure ExCon = Excon
           structure Effect = Effect
           structure FinMap = FinMap    (* for tyvars *)
           structure E = LambdaExp
           structure E' = RegionExp 
           structure RSE = RegionStatEnv
           structure TyName = TyName
           structure Crash = Crash
	   structure Flags = Flags
           structure PP = PP)

  structure SpreadExpression =  SpreadExpression(
       structure Con = Con
       structure ExCon = Excon
       structure E = LambdaExp
       structure E'= RegionExp
       structure Eff = Effect
       structure R= RType
       structure RSE = RegionStatEnv
       structure SpreadDatatype = SpreadDatatype
       structure Lvars =  Lvars
       structure TyName = TyName
       structure FinMap = FinMap
       structure Crash = Crash
       structure PP = PP
       structure Flags=Flags
       structure Report = Report
       structure CConst = CConst)


   structure RegInf= RegInf(
      structure Con = Con
      structure ExCon = Excon
      structure TyName = TyName
      structure Exp = RegionExp
      structure Report = Report
      structure RType = RType
      structure Effect = Effect
      structure RSE = RegionStatEnv
      structure Lvar= Lvars
      structure Crash = Crash
      structure PrettyPrint = PP
      structure Flags = Flags)

   structure EffVarEnv=
      OrderFinMap(structure Order =
                  struct
                    type T = Effect.effect
                    fun lt(a: T) b = Effect.lt_eps_or_rho(a,b)
                  end
                  structure PP =PP
                  structure Report = Report)


   structure HashTable = HashTable(structure PP = PP)

   structure QM_EffVarEnv = QuasiEnv(
      structure OFinMap = EffVarEnv
      val key = Effect.key_of_eps_or_rho
      structure HashTable = HashTable
      structure PP = PP
      structure Crash = Crash)


   structure Mul = Mul(
      structure Name = Name
      structure Lam = LambdaExp
      structure Eff = Effect
      structure Crash = Crash
      structure Flags = Flags
      structure Lvar = Lvars
      structure TyName = TyName
      structure RType = RType
      structure RSE = RegionStatEnv
      structure PP = PP
      structure UF = UnionFindPoly
      structure QM_EffVarEnv = QM_EffVarEnv)

   structure MulExp = MulExp(
      structure Flags = Flags
      structure Report = Report
      structure Con = Con
      structure Excon= Excon
      structure RegionExp = RegionExp
      structure Eff = Effect
      structure Mul = Mul
      structure R = RType
      structure TyName = TyName
      structure Crash = Crash
      structure PP = PP
      structure Lvar = Lvars
      structure Lam = LambdaExp
      structure RSE = RegionStatEnv)      

   structure MulInf = MulInf(
      structure Lvar = Lvars
      structure TyName = TyName
      structure RType = RType
      structure MulExp=MulExp
      structure RegionExp = RegionExp
      structure Mul = Mul
      structure Eff = Effect
      structure Flags = Flags
      structure Report = Report
      structure PP = PP
      structure Crash = Crash)

    structure IntSet = IntSet(structure PP = PP)

    structure CompilerEnv =
      CompilerEnv(structure Ident = Ident
		  structure StrId = StrId
                  structure Con = Con
                  structure Excon = Excon
		  structure Environments = Basics.Environments
		  structure LambdaBasics = LambdaBasics
                  structure TyCon = TyCon
                  structure TyVar = TyVar
                  structure TyName = TyName
                  structure LambdaExp = LambdaExp
                  structure Lvars = Lvars
                  structure FinMap = FinMap
		  structure FinMapEq = FinMapEq
                  structure PP = PP
		  structure Flags = Flags
                  structure Crash = Crash)

    structure LvarDiGraphScc = 
      DiGraphScc(structure InfoDiGraph = 
		   struct
		     type nodeId = Lvars.lvar
		     type info = Lvars.lvar
		     type edgeInfo = unit
		     val lt = fn a => fn b => Lvars.lt(a,b)
		     fun getId lv = lv
		   end
		 structure PP = PP
		 structure Flags = Flags
		 structure Crash = Crash
		 structure Report = Report)


    structure OptLambda = 
      OptLambda(structure Lvars = Lvars
		structure LambdaExp = LambdaExp
		structure Name = Name
		structure IntFinMap = IntFinMap
		structure LvarDiGraphScc = LvarDiGraphScc
		structure LambdaBasics = LambdaBasics
		structure FinMap = FinMap
		structure BasicIO = Tools.BasicIO
		structure Con = Con
		structure Excon = Excon
		structure TyName = TyName
		structure Flags = Flags
		structure Crash = Crash
		structure PP = PP)
 
    structure RegFlow = RegFlow(
                structure Lvars = Lvars
		structure Con = Con
		structure Excon = Excon
		structure PrettyPrint = PP
		structure Crash = Crash
                structure Flags = Flags
                structure Eff = Effect
                structure RType = RType
                structure MulExp = MulExp)

    structure LLV = LocallyLiveVariables(
                structure Lvars = Lvars
                structure Lvarset = Lvarset
		structure Con = Con
		structure Excon = Excon
		structure PrettyPrint = PP
		structure Crash = Crash
                structure Flags = Flags
                structure Eff = Effect
                structure RType = RType
                structure MulExp = MulExp
                structure MulInf = MulInf)

    structure AtInf = AtInf(structure Lvars = Lvars
                            structure Excon = Excon
                            structure MulExp = MulExp
			    structure Mul = Mul
			    structure Eff = Effect
                            structure RType = RType
                            structure LLV = LLV
                            structure RegFlow = RegFlow
                            structure BT = IntFinMap
                            structure RegvarBT = EffVarEnv
			    structure PP = PP
                            structure Flags = Flags
			    structure Crash = Crash
			    structure Report = Report
                            structure Timing = Tools.Timing)


    structure DropRegions = DropRegions(structure MulExp = MulExp
					structure Name = Name
					structure AtInf = AtInf
					structure RSE = RegionStatEnv
					structure RType = RType
					structure Lvars = Lvars
					structure Crash = Crash
					structure PP = PP
					structure FinMapEq = FinMapEq
					structure Flags = Flags
					structure Eff = Effect
                                        structure Mul= Mul
                                        structure RegionExp = RegionExp
                                        structure ExCon = Excon)

      
    structure PhysSizeInf = PhysSizeInf(structure MulExp = MulExp
					structure Name = Name
					structure Effect = Effect
					structure TyName = TyName
					structure AtInf = AtInf
					structure Lvars = Lvars
					structure ExCon = Excon
					structure Mul = Mul
					structure DiGraph = DiGraph
					structure RType = RType
					structure RegvarFinMap = EffVarEnv
					structure Flags = Flags
					structure Crash = Crash
					structure PP = PP
					structure CConst = CConst)

    structure RegionFlowGraphProfiling =
      RegionFlowGraphProfiling(structure Effect = Effect
			       structure AtInf = AtInf
			       structure PhySizeInf = PhysSizeInf
			       structure PP = PP
			       structure Flags = Flags
			       structure Crash = Crash
			       structure Report = Report)

    structure ClosConvEnv = ClosConvEnv(structure Lvars = Lvars
					structure Con = Con
					structure Excon = Excon
					structure Effect = Effect
					structure MulExp = MulExp
					structure RegvarFinMap = EffVarEnv
					structure PhysSizeInf = PhysSizeInf
					structure Labels = Labels
					structure BI = BackendInfo
					structure PP = PP
					structure Crash = Crash)

    structure CallConv = CallConv(structure Lvars = Lvars
				  structure RI = RegisterInfo
				  structure BI = BackendInfo
				  structure PP = PP
				  structure Flags = Flags
				  structure Report = Report
				  structure Crash = Crash)

    structure ClosExp = ClosExp(structure Con = Con
				structure Excon = Excon
				structure Lvars = Lvars
				structure TyName = TyName
				structure Effect = Effect
				structure RType = RType
				structure MulExp = MulExp
				structure Mul = Mul
				structure RegionExp = RegionExp
				structure AtInf = AtInf
				structure PhysSizeInf = PhysSizeInf
				structure Labels = Labels
				structure ClosConvEnv = ClosConvEnv
				structure BI = BackendInfo
				structure CallConv = CallConv
				structure PP = PP
				structure Flags = Flags
				structure Report = Report
				structure Crash = Crash)

    structure LineStmt = LineStmt(structure PhysSizeInf = PhysSizeInf
				  structure Con = Con
				  structure Excon = Excon
				  structure Lvars = Lvars
				  structure Effect = Effect
				  structure Labels = Labels
				  structure CallConv = CallConv
				  structure ClosExp = ClosExp
				  structure RI = RegisterInfo
				  structure BI = BackendInfo
				  structure Lvarset = Lvarset
				  structure PP = PP
				  structure Flags = Flags
				  structure Report = Report
				  structure Crash = Crash)

    structure RegAlloc = RegAlloc(structure PhysSizeInf = PhysSizeInf
				  structure Con = Con
				  structure Excon = Excon
				  structure Lvars = Lvars
				  structure Effect = Effect
				  structure Lvarset = Lvarset
				  structure Labels = Labels
				  structure CallConv = CallConv
				  structure LineStmt = LineStmt
				  structure RI = RegisterInfo
				  structure PP = PP
				  structure Flags = Flags
				  structure Report = Report
				  structure Crash = Crash)

    structure FetchAndFlush = FetchAndFlush(structure PhysSizeInf = PhysSizeInf
					    structure Con = Con
					    structure Excon = Excon
					    structure Lvars = Lvars
					    structure Effect = Effect
					    structure Labels = Labels
					    structure CallConv = CallConv
					    structure LineStmt = LineStmt
					    structure RegAlloc = RegAlloc
					    structure RI = RegisterInfo
					    structure Lvarset = Lvarset
					    structure PP = PP
					    structure Flags = Flags
					    structure Report = Report
					    structure Crash = Crash)

    structure CalcOffset = CalcOffset(structure PhysSizeInf = PhysSizeInf
				      structure Con = Con
				      structure Excon = Excon
				      structure Lvars = Lvars
				      structure Effect = Effect
				      structure Labels = Labels
				      structure CallConv = CallConv
				      structure LineStmt = LineStmt
				      structure FetchAndFlush = FetchAndFlush
				      structure BI = BackendInfo
				      structure IntSet = IntSet
				      structure PP = PP
				      structure Flags = Flags
				      structure Report = Report
				      structure Crash = Crash)

    structure SubstAndSimplify = SubstAndSimplify(structure PhysSizeInf = PhysSizeInf
						  structure Con = Con
						  structure Excon = Excon
						  structure Lvars = Lvars
						  structure Effect = Effect
						  structure RegvarFinMap = EffVarEnv
						  structure Labels = Labels
						  structure CallConv = CallConv
						  structure LineStmt = LineStmt
						  structure CalcOffset = CalcOffset
						  structure RI = RegisterInfo
						  structure PP = PP
						  structure Flags = Flags
						  structure Report = Report
						  structure Crash = Crash)


    structure CompileBasis =
      CompileBasis(structure CompilerEnv = CompilerEnv
		   structure Con = Con
		   structure Lvars = Lvars
		   structure Excon = Excon
		   structure TyName = TyName
		   structure LambdaStatSem = LambdaStatSem
		   structure EliminateEq = EliminateEq
		   structure OptLambda = OptLambda
		   structure Effect = Effect
		   structure RegionStatEnv = RegionStatEnv
		   structure DropRegions = DropRegions
		   structure PhysSizeInf = PhysSizeInf
		   structure ClosExp = ClosExp
		   structure Report = Report
		   structure PP = PP
		   structure Flags = Flags
		   structure Mul = Mul)


    structure CompileDec = CompileDec(
			structure Ident = Ident
                        structure Lab = Lab
                        structure SCon = SCon
                        structure Con = Con
                        structure Excon = Excon
                        structure TyCon = TyCon
                        structure TyName = TyName
                        structure TyVar = TyVar
                        structure Grammar = DecGrammar
			structure TopdecGrammar = TopdecGrammar
                        structure StatObject = Basics.StatObject
			structure Environments = Basics.Environments
                        structure Lvars = Lvars
                        structure LambdaExp = LambdaExp
                        structure LambdaBasics = LambdaBasics
                        structure CompilerEnv = CompilerEnv
			structure ElabInfo = Basics.AllInfo.ElabInfo
                        structure FinMap = FinMap
                        structure FinMapEq = FinMapEq
                        structure PrettyPrint = PP
                        structure Report = Report
                        structure Flags = Flags
                        structure Crash = Crash)

    structure Compile =
      Compile(structure RegionExp = RegionExp
	      structure Excon = Excon
	      structure FinMap = FinMap
	      structure Lvars = Lvars
	      structure Name = Name
	      structure LambdaExp = LambdaExp
	      structure LambdaStatSem = LambdaStatSem
	      structure EliminateEq = EliminateEq
	      structure SpreadExp = SpreadExpression
	      structure RegInf= RegInf
	      structure AtInf = AtInf
	      structure DropRegions = DropRegions
	      structure PhysSizeInf = PhysSizeInf
	      structure ClosExp = ClosExp
	      structure LineStmt = LineStmt
	      structure RegAlloc = RegAlloc
	      structure FetchAndFlush = FetchAndFlush
	      structure CalcOffset = CalcOffset
	      structure SubstAndSimplify = SubstAndSimplify
	      structure RegionFlowGraphProfiling = RegionFlowGraphProfiling
	      structure CompilerEnv = CompilerEnv
	      structure RType = RType
	      structure Effect = Effect
	      structure Mul = Mul
	      structure MulExp = MulExp
	      structure MulInf = MulInf
	      structure CompileDec = CompileDec
	      structure OptLambda = OptLambda
	      structure CompileBasis = CompileBasis
	      structure Report = Report
	      structure Flags = Flags
	      structure PP = PP
	      structure Crash = Crash
	      structure Timing = Tools.Timing)
  end
