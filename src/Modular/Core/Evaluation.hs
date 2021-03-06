{-# OPTIONS -Wall #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TypeSynonymInstances #-}







-- | This module defines how to evaluate terms in the dependently typed lambda
-- calculus.

module Modular.Core.Evaluation where

import Control.Monad.Except

import Utils.ABT
import Utils.Env
import Utils.Eval
import Utils.Names
import Utils.Pretty
import Utils.Telescope
import Modular.Core.Term







-- | Because a case expression can be evaluated under a binder, it's necessary
-- to determine when a match failure is real or illusory. For example, if we
-- have the function @\x -> case x of { Zero -> True ; _ -> False }@, and
-- naively tried to match, the first clause would fail, because @x =/= Zero@,
-- and the second would succeed, reducing this function to @\x -> False@.
-- But this would be bad, because if we then applied this function to @Zero@,
-- the result is just @False@. But if we had applied the original function to
-- @Zero@ and evaluated, it would reduce to @True@. Instead, we need to know
-- more than just did the match succeed or fail, but rather, did it succeed,
-- definitely fail because of a constructor mismatch, or is it uncertain
-- because of insufficient information (e.g. a variable or some other
-- non-constructor expression). We can use this type to represent that
-- three-way distinction between definite matches, definite failures, and
-- unknown situations.

data MatchResult a
  = Success a
  | Unknown
  | Failure
  deriving (Functor)


instance Applicative MatchResult where
  pure = Success
  
  Success f <*> Success x = Success (f x)
  Unknown <*> _ = Unknown
  _ <*> Unknown = Unknown
  _ <*> _ = Failure


instance Monad MatchResult where
  return = Success
  
  Success x >>= f = f x
  Unknown >>= _ = Unknown
  Failure >>= _ = Failure


-- | Pattern matching for case expressions.

matchPattern :: Pattern -> Term -> MatchResult [Term]
matchPattern (Var _) v = Success [v]
matchPattern (In (ConPat c ps)) (In (Con c' as))
  | c == c' && length ps == length as =
    fmap concat
      $ forM (zip ps as)
          $ \((plic,psc),(plic',asc)) -> 
              if (plic == plic')
                 then matchPattern (body psc) (body asc)
                 else Failure
  | otherwise = Failure
matchPattern (In (AssertionPat _)) v = Success [v]
matchPattern _ _ = Unknown

matchPatterns :: [Pattern] -> [Term] -> MatchResult [Term]
matchPatterns [] [] =
  Success []
matchPatterns (p:ps) (m:ms) =
  do vs <- matchPattern p m
     vs' <- matchPatterns ps ms
     return $ vs ++ vs'
matchPatterns _ _ = Failure

matchClauses :: [Clause] -> [Term] -> MatchResult Term
matchClauses [] _ = Failure
matchClauses (Clause pscs sc:cs) ms =
  case matchPatterns (map patternBody pscs) ms of
    Failure -> matchClauses cs ms
    Unknown -> Unknown
    Success vs -> Success (instantiate sc vs)





-- | Standard eager evaluation.

type EnvKey = (String,String)

instance Eval (Env EnvKey Term) Term where
  eval (Var v) =
    return $ Var v
  eval (In (Defined (Absolute m n))) =
    do env <- environment
       case lookup (m,n) env of
         Nothing -> throwError $ "Unknown constant/defined term: "
                              ++ showName (Absolute m n)
         Just x  -> eval x
  eval (In (Defined x)) =
    throwError $ "Cannot evaluate the local name " ++ showName x
  eval (In (Ann m _)) =
    eval (instantiate0 m)
  eval (In Type) =
    return $ In Type
  eval (In (Fun plic a sc)) =
    do ea <- underF eval a
       esc <- underF eval sc
       return $ In (Fun plic ea esc)
  eval (In (Lam plic sc)) =
    do esc <- underF eval sc
       return $ In (Lam plic esc)
  eval (In (App plic f a)) =
    do ef <- eval (instantiate0 f)
       ea <- eval (instantiate0 a)
       case ef of
         In (Lam plic' sc)
           | plic == plic' -> eval (instantiate sc [ea])
           | otherwise ->
               throwError "Mismatching plicities."
         _      -> return $ appH plic ef ea
  eval (In (Con c as)) =
    do eas <- forM as $ \(plic,a) ->
                do ea <- eval (instantiate0 a)
                   return (plic,ea)
       return $ conH c eas
  eval (In (Case ms mot cs)) =
    do ems <- mapM eval (map instantiate0 ms)
       case matchClauses cs ems of
         Success b  -> eval b
         Unknown -> 
           do emot <- eval mot
              return $ caseH ems emot cs
         Failure ->
           throwError $ "Incomplete pattern match: "
                     ++ pretty (In (Case ms mot cs))


instance Eval (Env EnvKey Term) CaseMotive where
  eval (CaseMotive (BindingTelescope ascs bsc)) =
    do eascs <- mapM (underF eval) ascs
       ebsc <- underF eval bsc
       return $ CaseMotive (BindingTelescope eascs ebsc)


instance Eval (Env EnvKey Term) Clause where
  eval (Clause pscs bsc) =
    do epscs <- mapM eval pscs
       ebsc <- underF eval bsc
       return $ Clause epscs ebsc


instance Eval (Env EnvKey Term) (PatternF (Scope TermF)) where
  eval (PatternF x) =
    do ex <- underF eval x
       return $ PatternF ex


instance Eval (Env EnvKey Term) (ABT (PatternFF (Scope TermF))) where
  eval (Var v) =
    return $ Var v
  eval (In (ConPat c ps)) =
    do eps <- forM ps $ \(plic,p) ->
                do ep <- underF eval p
                   return (plic,ep)
       return $ In (ConPat c eps)
  eval (In (AssertionPat m)) =
    do em <- underF eval m
       return $ In (AssertionPat em)
  eval (In MakeMeta) =
    return $ In MakeMeta