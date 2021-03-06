{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TypeSynonymInstances #-}

module Quasiquote.Core.Parser where

import Control.Applicative ((<$>),(<*>),(*>),(<*))
import Control.Monad.Reader
import Data.List (foldl')
import Text.Parsec
import qualified Text.Parsec.Token as Token

import Utils.ABT
import Utils.Names
import Utils.Plicity
import Utils.Vars
import Quasiquote.Core.ConSig
import Quasiquote.Core.DeclArg
import Quasiquote.Core.Term
import Quasiquote.Core.Program




-- Language Definition

languageDef :: Token.LanguageDef st
languageDef = Token.LanguageDef
              { Token.commentStart = "{-"
              , Token.commentEnd = "-}"
              , Token.commentLine = "--"
              , Token.nestedComments = True
              , Token.identStart = letter <|> char '_'
              , Token.identLetter = alphaNum <|> char '_' <|> char '\''
              , Token.opStart = oneOf ""
              , Token.opLetter = oneOf ""
              , Token.reservedNames = ["data","case","motive","of","end"
                                      ,"where","let","Type","module","open"
                                      ,"opening","as","using","hiding"
                                      ,"renaming","to","Rec","family","instance","Quoted"
                                      ]
              , Token.reservedOpNames = ["|","||","->","\\",":","::","=",".","`","~"]
              , Token.caseSensitive = True
              }

tokenParser = Token.makeTokenParser languageDef

identifier = Token.identifier tokenParser
reserved = Token.reserved tokenParser
reservedOp = Token.reservedOp tokenParser
parens = Token.parens tokenParser
braces = Token.braces tokenParser
symbol = Token.symbol tokenParser
whiteSpace = Token.whiteSpace tokenParser





-- names

varName = do lookAhead (lower <|> char '_')
             identifier

decName = do lookAhead upper
             identifier




-- term parsers

variable = do x <- varName
              guard (x /= "_")
              return $ Var (Free (FreeVar x))

dottedName = try $ do
               modName <- decName
               _ <- reservedOp "."
               valName <- varName
               return $ In (Defined (DottedLocal modName valName))

recordProj = do (m,f) <- try $ do
                  m <- recProjArg
                  _ <- reservedOp "."
                  f <- varName
                  return (m,f)
                fieldNames <- many $ do
                  _ <- reservedOp "."
                  varName
                return $ foldl' recordProjH m (f:fieldNames)

dottedThings = recordProj <|> dottedName

annotation = do m <- try $ do
                  m <- annLeft
                  _ <- reservedOp ":"
                  return m
                t <- annRight
                return $ annH m t

typeType = do _ <- reserved "Type"
              return $ In Type

explFunType = do (xs,arg) <- try $ do
                   (xs,arg) <- parens $ do
                     xs <- many1 varName
                     _ <- reservedOp ":"
                     arg <- term
                     return (xs,arg)
                   _ <- reservedOp "->"
                   return (xs,arg)
                 ret <- funRet
                 let xsFreshDummies =
                       map unBNSString
                           (dummiesToFreshNames
                              (freeVarNames ret)
                              (map BNSString xs))
                 return $ helperFold (\x -> funH Expl x arg)
                                     xsFreshDummies
                                     ret

implFunType = do (xs,arg) <- try $ do
                   (xs,arg) <- braces $ do
                     xs <- many1 varName
                     _ <- reservedOp ":"
                     arg <- term
                     return (xs,arg)
                   _ <- reservedOp "->"
                   return (xs,arg)
                 ret <- funRet
                 let xsFreshDummies =
                       map unBNSString
                           (dummiesToFreshNames
                              (freeVarNames ret)
                              (map BNSString xs))
                 return $ helperFold (\x -> funH Impl x arg)
                                     xsFreshDummies
                                     ret

binderFunType = explFunType <|> implFunType

noBinderFunType = do arg <- try $ do
                       arg <- funArg
                       _ <- reservedOp "->"
                       return arg
                     ret <- funRet
                     let xsFreshDummies =
                           unBNSString
                             (dummiesToFreshNames
                                (freeVarNames ret)
                                (BNSString "_"))
                     return $ funH Expl xsFreshDummies arg ret

funType = binderFunType <|> noBinderFunType

explArg = do x <- varName
             return (Expl,x)

implArg = do x <- braces varName
             return (Impl,x)

lambdaArg = explArg <|> implArg

lambda = do xs <- try $ do
              _ <- reservedOp "\\"
              many1 lambdaArg
            _ <- reservedOp "->"
            b <- lamBody
            let xsFreshDummies =
                  map (\(plic,s) -> (plic, unBNSString s))
                      (dummiesToFreshNames
                         (freeVarNames b)
                         (map (\(plic,s) -> (plic, BNSString s)) xs))
            return $ helperFold (\(plic,x) -> lamH plic x)
                                xsFreshDummies
                                b

application = do (f,pa) <- try $ do
                   f <- appFun
                   pa <- appArg
                   return (f,pa)
                 pas <- many appArg
                 return $ foldl' (\f' (plic,a') -> appH plic f' a') f (pa:pas)

bareCon = do conName <- decName
             return $ BareLocal conName

dottedCon = try $ do
              modName <- decName
              _ <- reservedOp "."
              conName <- decName
              return $ DottedLocal modName conName

constructor = dottedCon <|> bareCon

noArgConData = do c <- constructor
                  return $ conH c []

conData = do c <- constructor
             as <- many conArg
             return $ conH c as

assertionPattern = do _ <- reservedOp "."
                      m <- assertionPatternArg
                      return $ assertionPatH m

varPattern = do x <- varName
                return $ Var (Free (FreeVar x))

noArgConPattern = do c <- constructor
                     return $ conPatH c []

conPattern = do c <- constructor
                ps <- many conPatternArg
                return $ conPatH c ps

parenPattern = parens pattern

pattern = assertionPattern <|> parenPattern <|> conPattern <|> varPattern

consMotivePart = do (xs,a) <- try $ parens $ do
                      xs <- many1 varName
                      _ <- reservedOp ":"
                      a <- term
                      return (xs,a)
                    _ <- reservedOp "||"
                    (xs',as,b) <- caseMotiveParts
                    return (xs ++ xs', replicate (length xs) a ++ as, b)

nilMotivePart = do b <- term
                   return ([], [], b)

caseMotiveParts = consMotivePart <|> nilMotivePart

caseMotive = do (xs,as,b) <- caseMotiveParts
                let xsFreshDummies =
                      map unBNSString
                          (dummiesToFreshNames
                             (freeVarNames b ++ (freeVarNames =<< as))
                             (map BNSString xs))
                return $ caseMotiveH xsFreshDummies as b

clause = do ps <- try $ do
              ps <- pattern `sepBy` reservedOp "||"
              _ <- reservedOp "->"
              return ps
            b <- term
            let freshenedPs =
                  dummiesToFreshNames (freeVarNames b) ps
                xs = freeVarNames =<< freshenedPs
            return $ clauseH xs freshenedPs b

caseExp = do _ <- reserved "case"
             ms <- caseArg `sepBy1` reservedOp "||"
             _ <- reservedOp "motive"
             mot <- caseMotive
             _ <- reserved "of"
             _ <- optional (reservedOp "|")
             cs <- clause `sepBy` reservedOp "|"
             _ <- reserved "end"
             return $ caseH ms mot cs

recordType = do _ <- reserved "Rec"
                xts <- braces $ fieldDecl `sepBy` reservedOp ","
                return $ recordTypeH xts
  where
    fieldDecl = do x <- varName
                   guard (x /= "_")
                   _ <- reservedOp ":"
                   t <- term
                   return (x,t)

emptyRecordCon = try $ do
                   braces $ return ()
                   return $ recordConH []

nonEmptyRecordCon = do x <- try $ do
                         _ <- symbol "{"
                         x <- varName
                         _ <- reservedOp "="
                         return x
                       m <- term
                       guard (x /= "_")
                       xms' <- many $ do
                         _ <- reservedOp ","
                         x' <- varName
                         guard (x' /= "_")
                         _ <- reservedOp "="
                         m' <- term
                         return (x',m')
                       _ <- symbol "}"
                       return $ recordConH ((x,m):xms')

recordCon = emptyRecordCon <|> nonEmptyRecordCon

quotedType = do _ <- try $ reserved "Quoted"
                a <- quotedTypeArg
                return $ quotedTypeH a

quote = do _ <- try $ reservedOp "`"
           m <- quoteArg
           return $ quoteH m

unquote = do _ <- try $ reservedOp "~"
             m <- unquoteArg
             return $ unquoteH m

parenTerm = parens term

term = annotation <|> funType <|> application <|> dottedThings <|> parenTerm <|> lambda <|> conData <|> quotedType <|> quote <|> unquote <|> caseExp <|> variable <|> typeType <|> recordType <|> recordCon






annLeft = application <|> dottedThings <|> parenTerm <|> conData <|> quotedType <|> quote <|> unquote <|> variable <|> typeType <|> recordType <|> recordCon

annRight = funType <|> application <|> dottedThings <|> parenTerm <|> lambda <|> conData <|> quotedType <|> quote <|> unquote <|> caseExp <|> variable <|> typeType <|> recordType <|> recordCon

funArg = application <|> dottedThings <|> parenTerm <|> conData <|> quotedType <|> quote <|> unquote <|> caseExp <|> variable <|> typeType <|> recordType <|> recordCon

funRet = annotation <|> funType <|> application <|> dottedThings <|> parenTerm <|> lambda <|> conData <|> quotedType <|> quote <|> unquote <|> caseExp <|> variable <|> typeType <|> recordType <|> recordCon

lamBody = annotation <|> funType <|> application <|> dottedThings <|> parenTerm <|> lambda <|> conData <|> quotedType <|> quote <|> unquote <|> caseExp <|> variable <|> typeType <|> recordType <|> recordCon

appFun = dottedThings <|> parenTerm <|> quote <|> unquote <|> variable <|> typeType <|> recordType <|> recordCon

rawExplAppArg = dottedThings <|> parenTerm <|> noArgConData <|> quote <|> unquote <|> variable <|> typeType <|> recordType <|> recordCon

explAppArg = do m <- rawExplAppArg
                return (Expl,m)

rawImplAppArg = annotation <|> funType <|> application <|> dottedThings <|> parenTerm <|> lambda <|> conData <|> quotedType <|> quote <|> unquote <|> caseExp <|> variable <|> typeType <|> recordType <|> recordCon

implAppArg = do m <- braces $ rawImplAppArg
                return (Impl,m)

appArg = explAppArg <|> implAppArg

rawExplConArg = dottedThings <|> parenTerm <|> noArgConData <|> quote <|> unquote <|> variable <|> typeType <|> recordType <|> recordCon

explConArg = do m <- rawExplConArg
                return (Expl,m)

rawImplConArg = annotation <|> funType <|> application <|> dottedThings <|> parenTerm <|> lambda <|> conData <|> quotedType <|> quote <|> unquote <|> caseExp <|> variable <|> typeType <|> recordType <|> recordCon

implConArg = do m <- braces $ rawImplConArg
                return (Impl,m)

conArg = explConArg <|> implConArg

caseArg = annotation <|> funType <|> application <|> dottedThings <|> parenTerm <|> lambda <|> conData <|> quotedType <|> quote <|> unquote <|> variable <|> typeType <|> recordType <|> recordCon

rawExplConPatternArg = assertionPattern <|> parenPattern <|> noArgConPattern <|> varPattern

explConPatternArg = do p <- rawExplConPatternArg
                       return (Expl,p)

rawImplConPatternArg = assertionPattern <|> parenPattern <|> conPattern <|> varPattern

implConPatternArg = do p <- braces $ rawImplConPatternArg
                       return (Impl,p)

conPatternArg = explConPatternArg <|> implConPatternArg

assertionPatternArg = parenTerm <|> noArgConData <|> variable <|> typeType

recProjArg = recordType <|> recordCon <|> dottedName <|> variable <|> parenTerm <|> typeType

quotedTypeArg = dottedThings <|> parenTerm <|> noArgConData <|> variable <|> typeType <|> quote <|> unquote <|> recordType <|> recordCon

quoteArg = dottedThings <|> parenTerm <|> noArgConData <|> caseExp <|> variable <|> typeType <|> recordType <|> recordCon

unquoteArg = dottedThings <|> parenTerm <|> noArgConData <|> caseExp <|> variable <|> typeType <|> recordType <|> recordCon






parseTerm str = case parse (whiteSpace *> term <* eof) "(unknown)" str of
                  Left e -> Left (show e)
                  Right p -> Right p



-- statement parsers

eqTermDecl = do (x,t) <- try $ do
                  _ <- reserved "let"
                  x <- varName
                  _ <- reservedOp ":"
                  t <- term
                  _ <- reservedOp "="
                  return (x,t)
                m <- term
                _ <- reserved "end"
                return $ TermDeclaration x t m

whereTermDecl = do (x,t) <- try $ do
                     _ <- reserved "let"
                     x <- varName
                     _ <- reservedOp ":"
                     t <- term
                     _ <- reserved "where"
                     return (x,t)
                   _ <- optional (reservedOp "|")
                   preclauses <- patternMatchClause x `sepBy1` reservedOp "|"
                   _ <- reserved "end"
                   return $ WhereDeclaration x t preclauses
    
letFamilyDecl = do try $ do
                     _ <- reserved "let"
                     _ <- reserved "family"
                     return ()
                   x <- varName
                   args <- typeArgs
                   _ <- reservedOp ":"
                   t <- term
                   _ <- reserved "end"
                   return $ LetFamilyDeclaration x args t

letInstanceDecl = do  try $ do
                        _ <- reserved "let"
                        _ <- reserved "instance"
                        return ()
                      n <- letInstanceName
                      _ <- reserved "where"
                      _ <- optional (reservedOp "|")
                      preclauses <- instancePatternMatchClause n `sepBy1` reservedOp "|"
                      _ <- reserved "end"
                      return $ LetInstanceDeclaration n preclauses

letInstanceBareName = do x <- varName
                         guard (x /= "_")
                         return $ BareLocal x

letInstanceDottedName = try $ do
                       modName <- decName
                       _ <- reservedOp "."
                       valName <- varName
                       return $ DottedLocal modName valName

letInstanceName = letInstanceDottedName <|> letInstanceBareName

instancePatternMatchClause c
  = do c' <- letInstanceName
       guard (c == c')
       ps <- many wherePattern
       _ <- reservedOp "="
       b <- term
       let freshenedPs = dummiesToFreshNames (freeVarNames b) ps
           xs = do (_,p) <- freshenedPs
                   freeVarNames p
       return ( map fst freshenedPs
              , (xs, map snd freshenedPs, b)
              )

patternMatchClause x = do _ <- symbol x
                          ps <- many wherePattern
                          _ <- reservedOp "="
                          b <- term
                          let freshenedPs =
                                dummiesToFreshNames (freeVarNames b) ps
                              xs = do (_,p) <- freshenedPs
                                      freeVarNames p
                          return ( map fst freshenedPs
                                 , (xs, map snd freshenedPs, b)
                                 )

rawExplWherePattern = assertionPattern <|> parenPattern <|> noArgConPattern <|> varPattern

explWherePattern = do p <- rawExplWherePattern
                      return (Expl,p)

rawImplWherePattern = assertionPattern <|> parenPattern <|> conPattern <|> varPattern

implWherePattern = do p <- braces $ rawImplWherePattern
                      return (Impl,p)

wherePattern = implWherePattern <|> explWherePattern

termDecl = letFamilyDecl
       <|> letInstanceDecl
       <|> eqTermDecl
       <|> whereTermDecl

alternative = do c <- decName
                 as <- alternativeArgs
                 _ <- reservedOp ":"
                 t <- term
                 return (c,conSigH as t)

explAlternativeArg = parens $ do
                       xs <- many1 varName
                       _ <- reservedOp ":"
                       t <- term
                       return $ [ DeclArg Expl x t | x <- xs ]

implAlternativeArg = braces $ do
                       xs <- many1 varName
                       _ <- reservedOp ":"
                       t <- term
                       return $ [ DeclArg Impl x t | x <- xs ]

alternativeArg = explAlternativeArg <|> implAlternativeArg

alternativeArgs = do argss <- many alternativeArg
                     return (concat argss)

emptyTypeDecl = do (tycon,tyargs) <- try $ do
                     _ <- reserved "data"
                     tycon <- decName
                     tyargs <- typeArgs
                     _ <- reserved "end"
                     return (tycon,tyargs)
                   return $ TypeDeclaration tycon tyargs []

nonEmptyTypeDecl = do (tycon,tyargs) <- try $ do
                        _ <- reserved "data"
                        tycon <- decName
                        tyargs <- typeArgs
                        _ <- reserved "where"
                        return (tycon,tyargs)
                      _ <- optional (reservedOp "|")
                      alts <- alternative `sepBy` reservedOp "|"
                      _ <- reserved "end"
                      return $ TypeDeclaration tycon tyargs alts

explTypeArg = parens $ do
                xs <- many1 varName
                _ <- reservedOp ":"
                t <- term
                return $ [ DeclArg Expl x t | x <- xs ]

implTypeArg = braces $ do
                xs <- many1 varName
                _ <- reservedOp ":"
                t <- term
                return $ [ DeclArg Impl x t | x <- xs ]

typeArg = explTypeArg <|> implTypeArg

typeArgs = do argss <- many typeArg
              return (concat argss)

dataFamilyDecl = do try $ do
                      _ <- reserved "data"
                      _ <- reserved "family"
                      return ()
                    tycon <- decName
                    tyargs <- typeArgs
                    _ <- reserved "end"
                    return $ DataFamilyDeclaration tycon tyargs

dataInstanceDecl = do try $ do
                        _ <- reserved "data"
                        _ <- reserved "instance"
                        return ()
                      tycon <- constructor
                      _ <- reserved "where"
                      _ <- optional (reservedOp "|")
                      alts <- alternative `sepBy` reservedOp "|"
                      _ <- reserved "end"
                      return $ DataInstanceDeclaration tycon alts

typeDecl = emptyTypeDecl
       <|> nonEmptyTypeDecl
       <|> dataFamilyDecl
       <|> dataInstanceDecl

statement = TmDecl <$> termDecl
        <|> TyDecl <$> typeDecl





-- open settings

oAs = optionMaybe $ do
        _ <- reserved "as"
        decName

oHidingUsing = optionMaybe (hiding <|> using)
  where
    hiding = do _ <- reserved "hiding"
                ns <- parens (sepBy (varName <|> decName) (reservedOp ","))
                return (Hiding ns)
    using = do _ <- reserved "using"
               ns <- parens (sepBy (varName <|> decName) (reservedOp ","))
               return (Using ns)

oRenaming = do m <- openRenamingP
               case m of
                 Nothing -> return []
                 Just ns -> return ns
  where
    openRenamingP = optionMaybe $ do
                      _ <- reserved "renaming"
                      parens (sepBy (varRen <|> decRen) (reservedOp ","))
    varRen = do n <- varName
                _ <- reserved "to"
                n' <- varName
                return (n,n')
    decRen = do n <- decName
                _ <- reserved "to"
                n' <- decName
                return (n,n')

openSettings = OpenSettings <$> decName
                            <*> oAs
                            <*> oHidingUsing
                            <*> oRenaming




-- modules

modulOpen = do n <- try $ do
                 _ <- reserved "module"
                 n <- decName
                 _ <- reserved "opening"
                 return n
               _ <- optional (reserved "|")
               settings <- sepBy openSettings (reserved "|")
               _ <- reserved "where"
               stmts <- many statement
               _ <- reserved "end"
               return $ Module n settings stmts

modulNoOpen = do n <- try $ do
                   _ <- reserved "module"
                   n <- decName
                   _ <- reserved "where"
                   return n
                 stmts <- many statement
                 _ <- reserved "end"
                 return $ Module n [] stmts

modul = modulOpen <|> modulNoOpen





-- programs

program = Program <$> many modul



parseProgram :: String -> Either String Program
parseProgram str
  = case parse (whiteSpace *> program <* eof) "(unknown)" str of
      Left e -> Left (show e)
      Right p -> Right p