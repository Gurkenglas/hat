-- Derive instances of standard classes.
-- Thus given a type declaration with a non-empty derive clause,
-- produce all the instances demanded.
module Derive (derive) where

import Language.Haskell.Exts
import Wired (mkExpDeriveEqualEqual,mkExpDeriveAndAnd,mkExpDeriveTrue,mkExpDeriveFalse,qNameBuiltinIdent)
import SynHelp (Id(getId),appN,tyAppN,litInt,litString,litChar,conDeclName,conDeclArity
               ,mkQName, fieldDeclNames
               ,instRuleQName,declHeadName,declHeadTyVarBinds,tyVarBind2Type
               ,combineMaybeContexts)
import Environment (Environment, hasPriority)
import Debug.Trace

-- ----------------------------------------------------------------------------

-- Derive instances for all given classes for a data/newtype
derive :: Environment -> Decl l -> [Decl l]
derive env (DataDecl l dataOrNew maybeContext declHead qualConDecls maybeDeriving) =
  case maybeDeriving of
    Nothing -> []
    Just (Deriving _ instRules) -> 
      map (deriveClass env maybeContext instTy tyVars conDecls . instRuleQName) 
        instRules
      where
      tyVars = map tyVarBind2Type (declHeadTyVarBinds declHead)
      nameTy = declHeadName declHead
      instTy = tyAppN (TyCon l (UnQual l nameTy) : tyVars)
      conDecls = map getConDecl qualConDecls
        

getConDecl :: QualConDecl l -> ConDecl l
getConDecl (QualConDecl _ Nothing Nothing conDecl) = conDecl
getConDecl (QualConDecl _ _ _ _) = 
  error "Derive.getConDecl: Cannot derive class instance for existentially quantified data constructor."


-- Produce a class instance.
deriveClass :: 
  Environment -> 
  Maybe (Context l) -> -- context of the data type (should be empty)
  (Type l) ->          -- type constructor with variable args to be made instance
  [Type l] ->          -- type variables args of above
  [ConDecl l] ->       -- constructor of data type
  QName l ->           -- names of class to derive
  Decl l
deriveClass env maybeContext instTy tyVars conDecls className 
  | getId className == "Eq" = deriveEq l maybeContext' instTy conDecls 
  | getId className == "Ord" = deriveOrd l maybeContext' instTy conDecls
  | getId className == "Bounded" = deriveBounded l maybeContext' instTy conDecls
  | getId className == "Enum" = deriveEnum l maybeContext' instTy conDecls
  | getId className == "Read" = deriveRead env l maybeContext' instTy conDecls
  | getId className == "Show" = deriveShow env l maybeContext' instTy conDecls
  | getId className == "Ix" = deriveIx l maybeContext' instTy conDecls
  | otherwise = error "Derive.deriveClass: unknown class"
  where
  l = ann className
  -- this is a HACK that covers only the common cases
  -- for correct result would need to implement full context reduction
  -- and take the least fixpoint
  maybeContext' = 
    combineMaybeContexts maybeContext
      (Just (CxTuple l (map (\ty -> ClassA l className [ty]) tyVars)))


-- ----------------------------------------------------------------------------

deriveEq :: l -> Maybe (Context l) -> (Type l) -> [ConDecl l] -> Decl l
deriveEq l maybeContext instTy conDecls =
  mkInstance l maybeContext "Eq" instTy
    [InsDecl l (FunBind l (
      map matchEqConstr conDecls ++
      [Match l (Symbol l "==") [PWildCard l, PWildCard l] 
        (UnGuardedRhs l (mkExpDeriveFalse l))
        Nothing]))]
  where
  names = newNames l
  -- mkExpEqual :: Exp l -> Exp l -> Exp l
  mkExpEqual e1 e2 = App l (App l (mkExpDeriveEqualEqual l) e1) e2
  -- matchEqConstr :: ConDecl l -> Match l
  matchEqConstr conDecl =
    Match l (Symbol l "==") 
      [PApp l (UnQual l conName) patALs, PApp l (UnQual l conName) patARs] 
      (UnGuardedRhs l 
        (foldr mkExpAnd (mkExpDeriveTrue l) (zipWith mkExpEqual expALs expARs)))
      Nothing
    where
    conName = conDeclName conDecl
    arity = conDeclArity conDecl
    (namesL, namesRest) = splitAt arity names
    namesR = take arity namesRest
    patALs = map (PVar l) namesL
    patARs = map (PVar l) namesR
    expALs = map (Var l . UnQual l) namesL
    expARs = map (Var l . UnQual l) namesR
    

-- ----------------------------------------------------------------------------

deriveOrd :: l -> Maybe (Context l) -> (Type l) -> [ConDecl l] -> Decl l
deriveOrd l maybeContext instTy conDecls =
  mkInstance l maybeContext "Ord" instTy
    [InsDecl l (FunBind l (
      concatMap matchCompareEqConstr conDecls ++
      [Match l nameCompare [PVar l nameL, PVar l nameR]
        (UnGuardedRhs l
          (App l 
             (App l (Var l (deriveIdent "compare" l))
                (App l (Var l (UnQual l nameLocalFromEnum))
                   (Var l (UnQual l nameL))))
             (App l (Var l (UnQual l nameLocalFromEnum))
                (Var l (UnQual l nameR)))))
        (Just (BDecls l [FunBind l (zipWith matchLocalFromEnum conDecls [(0::Int)..])]))
      ]))]
  where
  nameL : nameR : names = newNames l
  nameCompare = Ident l "compare"
  nameLocalFromEnum = Ident l "localFromEnum"
  matchCompareEqConstr conDecl =
    if arity == 0 then [] else
      [Match l nameCompare 
        [PApp l (UnQual l conName) patALs, PApp l (UnQual l conName) patARs] 
      (UnGuardedRhs l 
        (foldr1 mkExpCase (zipWith mkExpCompare expALs expARs)))
      Nothing]
    where
    conName = conDeclName conDecl
    arity = conDeclArity conDecl
    (namesL, namesRest) = splitAt arity names
    namesR = take arity namesRest
    patALs = map (PVar l) namesL
    patARs = map (PVar l) namesR
    expALs = map (Var l . UnQual l) namesL
    expARs = map (Var l . UnQual l) namesR
  -- mkExpCase :: Exp l -> Exp l -> Exp l
  mkExpCase e1 e2 =
    Case l e1 
      [Alt l (PApp l (deriveIdent "EQ" l) []) (UnGuardedRhs l e2) Nothing
      ,Alt l (PVar l nameL) (UnGuardedRhs l (Var l (UnQual l nameL))) Nothing]
  -- mkExpCompare :: Exp l -> Exp l -> Exp l
  mkExpCompare e1 e2 =
    App l (App l (Var l (deriveIdent "compare" l)) e1) e2
  -- matchLocalFromEnum :: ConDecl l -> Int -> Match l
  matchLocalFromEnum conDecl num =
    Match l nameLocalFromEnum [PApp l (UnQual l conName) args] 
      (UnGuardedRhs l (ExpTypeSig l (litInt l num) (TyCon l (qNameBuiltinIdent "Int" l)))) Nothing
    where
    conName = conDeclName conDecl
    args = replicate (conDeclArity conDecl) (PWildCard l)

-- ----------------------------------------------------------------------------

deriveBounded :: l -> Maybe (Context l) -> (Type l) -> [ConDecl l] -> Decl l
deriveBounded l maybeContext instTy conDecls =
  mkInstance l maybeContext "Bounded" instTy
    (if all (== 0) (map conDeclArity conDecls)
      then -- all constructors have no arguments (enumeration)
          [InsDecl l (PatBind l 
            (PVar l (Ident l "minBound"))
            (UnGuardedRhs l (Con l (UnQual l (conDeclName (head conDecls)))))
            Nothing)
          ,InsDecl l (PatBind l 
            (PVar l (Ident l "maxBound"))
            (UnGuardedRhs l (Con l (UnQual l (conDeclName (last conDecls)))))
            Nothing)]
      else -- exactly one constructor
        let [conDecl] = conDecls in
            [InsDecl l (PatBind l 
              (PVar l (Ident l "minBound"))
              (UnGuardedRhs l 
                (appN 
                  (Con l (UnQual l (conDeclName conDecl))
                  :replicate (conDeclArity conDecl) 
                    (Var l (deriveIdent "minBound" l)))))
              Nothing)
            ,InsDecl l (PatBind l 
              (PVar l (Ident l "maxBound"))
              (UnGuardedRhs l 
                (appN
                  (Con l (UnQual l (conDeclName conDecl))
                  :replicate (conDeclArity conDecl)
                    (Var l (deriveIdent "maxBound" l)))))
              Nothing)])

-- ----------------------------------------------------------------------------

deriveEnum :: l -> Maybe (Context l) -> (Type l) -> [ConDecl l] -> Decl l
deriveEnum  l maybeContext instTy conDecls =
  -- assert: all (== 0) (map constrArity constrs) 
  mkInstance l maybeContext "Enum" instTy
      [InsDecl l (FunBind l (zipWith matchFromEnum conDecls [(0::Int)..]))
      ,InsDecl l (FunBind l (zipWith matchToEnum conDecls [(0::Integer)..] ++ [failure]))
      ,InsDecl l (FunBind l 
        [Match l (Ident l "enumFrom") [PVar l name1]
          (UnGuardedRhs l
            (appN [Var l (deriveIdent "enumFromTo" l)
                  ,var1
                  ,Con l (UnQual l (conDeclName (last conDecls)))]))
          Nothing])
      ,InsDecl l (FunBind l
        [Match l (Ident l "enumFromThen") [PVar l name1,PVar l name2]
          (UnGuardedRhs l
            (appN [Var l (deriveIdent "enumFromThenTo" l)
                  ,var1
                  ,var2
                  ,If l (appN
                           [Var l (deriveSymbol ">=" l)
                           ,App l (Var l (deriveIdent "fromEnum" l))
                                  (Var l (UnQual l name2))
                           ,App l (Var l (deriveIdent "fromEnum" l))
                                  (Var l (UnQual l name1))])
                         (Con l (UnQual l (conDeclName (last conDecls))))
                         (Con l (UnQual l (conDeclName (head conDecls))))]))
          Nothing])]  
  where
  name1:name2:_ = newNames l
  var1 = Var l (UnQual l name1)
  var2 = Var l (UnQual l name2)
  matchFromEnum conDecl num =
    Match l (Ident l "fromEnum") [PApp l (UnQual l (conDeclName conDecl)) []]
      (UnGuardedRhs l (litInt l num)) Nothing
  matchToEnum conDecl num =
    Match l (Ident l "toEnum") [PLit l (Signless l) (Int l num (show num))]
      (UnGuardedRhs l (Con l (UnQual l (conDeclName conDecl)))) Nothing
  failure = 
    Match l (Ident l "toEnum") [PWildCard l]
      (UnGuardedRhs l 
        (App l (Var l (deriveIdent "error" l))
               (litString l "toEnum: argument out of bounds")))
      Nothing

-- ----------------------------------------------------------------------------

deriveRead :: Environment -> l -> Maybe (Context l) -> (Type l) -> [ConDecl l] -> Decl l
deriveRead  env l maybeContext instTy conDecls =
  mkInstance l maybeContext "Read" instTy
    [InsDecl l (FunBind l (
      [Match l (Ident l "readsPrec") [PVar l name1]
        (UnGuardedRhs l (foldr1 alt . map expReadsPrec $ conDecls)) Nothing]))]
  where
  name1:_ = newNames l
  e1 `alt` e2 =  appN [Var l (mkQName l "PreludeBasic.alt"), e1, e2]
  expReadsPrec conDecl =
    if arity == 0
      then readParen (mkExpDeriveFalse l) (yield conExp `thenLex` getId conName)
      else
        case conDecl of
          ConDecl _ _ _ ->
            readParen precGreaterPriority
              (foldl thenAp (yield conExp `thenLex` getId conName) (replicate arity readsArg))
          InfixConDecl _ _ _ _ -> 
            readParen precGreaterPriority
              (yield conExp `thenAp` readsArg `thenLex` getId conName `thenAp` readsArg)
          RecDecl _ _ fieldDecls ->
            let fieldNames = concatMap fieldDeclNames fieldDecls
            in (foldl thenCommaField (yield conExp `thenLex` getId conName `thenLex` "{" `thenField` head fieldNames)
                 (tail fieldNames))
                 `thenLex` "}"
    where
    infixl 6 `thenAp`, `thenLex`, `thenField`
    conName = conDeclName conDecl
    arity = conDeclArity conDecl
    conExp = Con l (UnQual l conName)
    priority = Environment.hasPriority env conName
    priorityPlus1 = priority + 1
    readParen eb e = appN [Var l (deriveIdent "readParen" l), eb, e]
    yield e = appN [Var l (mkQName l "PreludeBasic.yield"), e]
    e1 `thenLex` s = appN [Var l (mkQName l "PreludeBasic.thenLex"), e1, litString l s]
    e1 `thenAp` e2 = appN [Var l (mkQName l "PreludeBasic.thenAp"), e1, e2]
    precGreaterPriority = InfixApp l (Var l (UnQual l name1)) (QVarOp l (deriveSymbol ">" l)) (litInt l priority)
    readsArg = appN [Var l (deriveIdent "readsPrec" l), litInt l priorityPlus1]
    readsArg0 = appN [Var l (deriveIdent "readsPrec" l), litInt l (0::Integer)]
    p `thenField` fieldName = p `thenLex` getId fieldName `thenLex` "=" `thenAp` readsArg0
    p `thenCommaField` fieldName = p `thenLex` "," `thenField` fieldName

-- ----------------------------------------------------------------------------

deriveShow :: Environment -> l -> Maybe (Context l) -> (Type l) -> [ConDecl l] -> Decl l
deriveShow  env l maybeContext instTy conDecls =
  mkInstance l maybeContext "Show" instTy
    [InsDecl l (FunBind l (map matchShowsPrec conDecls))]
  where
  name1:names = newNames l
  matchShowsPrec conDecl =
    Match l (Ident l "showsPrec") 
      [PVar l name1, PApp l (UnQual l (conDeclName conDecl)) (map (PVar l) . take arity $ names)] 
      (UnGuardedRhs l body) Nothing
    where
    conName = conDeclName conDecl
    arity = conDeclArity conDecl
    args = map (Var l . UnQual l) . take arity $ names
    priority = Environment.hasPriority env conName
    priorityPlus1 = priority + 1
    body = if arity == 0 
             then showStringExp (getId conName)
             else
               case conDecl of
                 ConDecl _ _ _ -> 
                   appN [Var l (deriveIdent "showParen" l)
                        ,appN [Var l (deriveSymbol ">" l), Var l (UnQual l name1), litInt l priority]
                        ,showStringExp (getId conName ++ " ") `compose`
                          foldr1 composeSpace (map (showPrec priorityPlus1) args)]
                 InfixConDecl _ _ _ _ ->
                   appN [Var l (deriveIdent "showParen" l)
                        ,appN [Var l (deriveSymbol ">" l), Var l (UnQual l name1), litInt l priority]
                        ,showPrec priorityPlus1 (Var l (UnQual l (names!!0))) `compose`
                          showStringExp (' ' : getId conName ++ " ") `compose`
                          showPrec priorityPlus1 (Var l (UnQual l (names!!1)))]
                 RecDecl _ _ fieldDecls ->
                   let fieldNames = concatMap fieldDeclNames fieldDecls
                   in showStringExp (getId conName ++ "{") `compose`
                        foldr1 composeComma (zipWith showField fieldNames args) `compose` showCharExp '}'
    showStringExp s = appN [Var l (deriveIdent "showString" l), litString l s]
    showCharExp c = appN [Var l (deriveIdent "showChar" l), litChar l c]
    e1 `compose` e2 = appN [Var l (deriveSymbol "." l), e1, e2]
    e1 `composeSpace` e2 = e1 `compose` showCharExp ' ' `compose` e2
    e1 `composeComma` e2 = e1 `compose` showCharExp ',' `compose` e2
    showField fieldName e =
      showStringExp (getId  fieldName) `compose` showCharExp '=' `compose` showPrec (0::Int) e
    showPrec d e = appN [Var l (deriveIdent "showsPrec" l), litInt l d, e]


-- ----------------------------------------------------------------------------

deriveIx :: l -> Maybe (Context l) -> (Type l) -> [ConDecl l] -> Decl l
deriveIx  l maybeContext instTy conDecls =
  mkInstance l maybeContext "Ix" instTy 
    (map (InsDecl l) (if all (==0) (map conDeclArity conDecls) then ixEnumeration else ixSingleConstructor))
  where
  ixEnumeration =
    [FunBind l [Match l (Ident l "range") [ppair (PVar l lName) (PVar l uName)] (UnGuardedRhs l 
      (appN [Var l (deriveIdent "map" l)
            ,toEnumVar 'r'
            ,appN [Var l (deriveIdent "enumFromTo" l)
                  ,appN [fromEnumVar 'r', Var l (UnQual l lName)]
                  ,appN [fromEnumVar 'r', Var l (UnQual l uName)]]]))
      (Just (BDecls l (declsToEnum 'r' ++ declsFromEnum 'r')))]
    ,FunBind l [Match l (Ident l "index") [ppair (PVar l lName) (PVar l uName), PVar l iName] (UnGuardedRhs l
      (InfixApp l (appN [fromEnumVar 'i', Var l (UnQual l iName)]) (QVarOp l (deriveSymbol "-" l)) 
        (appN [fromEnumVar 'i', Var l (UnQual l uName)])))
      (Just (BDecls l (declsFromEnum 'i')))]
    ,FunBind l [Match l (Ident l "inRange") [ppair (PVar l lName) (PVar l uName), PVar l iName] (UnGuardedRhs l
      (appN [Var l (deriveIdent "inRange" l)
            ,pair (appN [fromEnumVar 'n', Var l (UnQual l lName)])
                  (appN [fromEnumVar 'n', Var l (UnQual l uName)])
            ,appN [fromEnumVar 'n', Var l (UnQual l iName)]]))
      (Just (BDecls l (declsFromEnum 'n')))]]
    where
    -- pair :: Exp l -> Exp l -> Exp l
    pair e1 e2 = Tuple l Boxed [e1,e2]
    -- ppair :: Pat l - Pat l -> Pat l
    ppair p1 p2 = PTuple l Boxed [p1,p2]
    lName:uName:iName:_ = newNames l
    fromEnumVar prefix = Var l (deriveIdent (prefix : "fromEnum") l)
    toEnumVar prefix = Var l (deriveIdent (prefix : "toEnum") l)
    -- declsFromEnum :: [Decl l]
    declsFromEnum prefix = 
      [TypeSig l [(Ident l (prefix : "fromEnum"))] (TyFun l instTy (TyCon l (deriveIdent "Int" l)))
      ,FunBind l (zipWith (matchFromEnum prefix) conDecls [(0::Integer)..])]
    declsToEnum prefix =
      [TypeSig l [(Ident l (prefix : "toEnum"))] (TyFun l (TyCon l (deriveIdent "Int" l)) instTy)
      ,FunBind l (zipWith (matchToEnum prefix) conDecls [(0::Integer)..])]
    matchFromEnum prefix conDecl num =
      Match l (Ident l (prefix : "fromEnum")) [PApp l (UnQual l (conDeclName conDecl)) []]
        (UnGuardedRhs l (litInt l num)) Nothing
    matchToEnum prefix conDecl num =
      Match l (Ident l (prefix :  "toEnum")) [PLit l (Signless l) (Int l num (show num))] 
        (UnGuardedRhs l (Con l (UnQual l (conDeclName conDecl)))) Nothing
  ixSingleConstructor =
    [FunBind l [Match l  (Ident l "range") [pTupleConLU] (UnGuardedRhs l 
      (foldr ($) (appN [Var l (deriveIdent "return" l), conIVars]) (zipWith3 rangeComb lvars uvars iNames)))
      Nothing]
    ,FunBind l [Match l (Ident l "index") [pTupleConLU, pConI] (UnGuardedRhs l
      (foldl (flip ($)) (indexExp (head lvars) (head uvars) (head ivars)) 
        (tail (zipWith3 indexComb lvars uvars ivars))))
      Nothing]
    ,FunBind l [Match l (Ident l "inRange") [pTupleConLU, pConI] (UnGuardedRhs l
      (foldr1 andExp (zipWith3 inRangeExp lvars uvars ivars)))
      Nothing]]
    where
    [conDecl] = conDecls
    conName = conDeclName conDecl
    arity = conDeclArity conDecl
    (lNames, names1) = splitAt arity (newNames l)
    (uNames, names2) = splitAt arity names1
    iNames = take arity names2
    lvars = map (Var l . UnQual l) lNames
    uvars = map (Var l . UnQual l) uNames
    ivars = map (Var l . UnQual l) iNames
    conIVars = appN (Con l (UnQual l conName) : ivars)
    pTupleConLU = PTuple l Boxed [PApp l (UnQual l conName) (map (PVar l) lNames)
                                 ,PApp l (UnQual l conName) (map (PVar l) uNames)]
    pConI = PApp l (UnQual l conName) (map (PVar l) iNames)
    -- rangeComb :: Exp l -> Exp l -> Name l -> Exp l -> Exp l
    rangeComb le ue ie cont = 
      InfixApp l (appN [Var l (deriveIdent "range" l), pair le ue]) (QVarOp l (deriveSymbol ">>=" l))
        (Lambda l [PVar l ie] cont)
    indexExp le ue ie = appN [Var l (deriveIdent "index" l), pair le ue, ie]
    -- indexComb :: Exp l -> Exp l -> Exp l -> Exp l -> Exp l
    indexComb le ue ie ee =
      InfixApp l (indexExp le ue ie) (QVarOp l (deriveSymbol "+" l)) 
        (InfixApp l (appN [Var l (deriveIdent "rangeSize" l), pair le ue]) 
          (QVarOp l (deriveSymbol "*" l)) ee)
    inRangeExp le ue ie = appN [Var l (deriveIdent "inRange" l), pair le ue, ie]
    -- andExp :: Exp l -> Exp l -> Exp l
    andExp e1 e2 = InfixApp l e1 (QVarOp l (deriveSymbol "&&" l)) e2
    -- pair :: Exp l -> Exp l -> Exp l
    pair e1 e2 = Tuple l Boxed [e1,e2]

-- ----------------------------------------------------------------------------

-- Create simple instance as needed for derived instances, filling in all arguments that are trivial.
mkInstanceO :: l -> Maybe (Context l) -> String -> Type l -> Maybe [InstDecl l] -> Decl l
mkInstanceO l maybeContext id instTy maybeDecls =
  InstDecl l Nothing (IRule l Nothing maybeContext (IHApp l (IHCon l (deriveIdent id l)) instTy)) maybeDecls

mkInstance :: l -> Maybe (Context l) -> String -> Type l -> [InstDecl l] -> Decl l
mkInstance l maybeContext id instTy decls = mkInstanceO l maybeContext id instTy (Just decls)

-- Infinite list of parameter names in derived code.
-- Only need to avoid conflict with names of the methods of derived classes.
newNames :: l -> [Name l]
newNames l = map (Ident l . ('y':) . show) [(1::Int)..]

-- syntax helpers:

mkExpAnd :: Exp l -> Exp l -> Exp l
mkExpAnd e1 e2 = App l (App l (mkExpDeriveAndAnd l) e1) e2
  where 
  l = ann e1

-- QNames introduced by deriving are unqualified.
-- However, that assumes that the defining modules are imported unqualfied,
-- which may not be the case.
deriveIdent :: String -> l -> QName l
deriveIdent id l = UnQual l (Ident l id)

deriveSymbol :: String -> l -> QName l
deriveSymbol id l = UnQual l (Symbol l id)