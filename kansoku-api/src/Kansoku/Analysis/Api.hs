{-# LANGUAGE DataKinds #-}
{-# LANGUAGE UndecidableInstances #-}

module Kansoku.Analysis.Api where

import Data.SOP (I (..), NS (..))
import Data.UUID (UUID)
import GHC.TypeLits (Symbol)
import Kansoku.Analysis.Types
import Kansoku.Api.Response
import Kansoku.Auth.Api (MetricsAuth)
import Kansoku.Cohort.Api (PageReply)
import Kansoku.Prelude
import Relay.Pagination.Servant (RelayPage)
import Servant.API
import Servant.API.MultiVerb

data AnalysisResult a
  = AnalysisOk a
  | AnalysisBadRequest ProblemDetails
  | AnalysisNotFound ProblemDetails
  | AnalysisConflict ProblemDetails
  | AnalysisUnavailable ProblemDetails
  deriving stock (Generic, Eq, Show)

type AnalysisResponses (desc :: Symbol) a =
  '[ RespondAs JSON 200 desc a,
     RespondAs ProblemJSON 400 "Invalid analysis" ProblemDetails,
     RespondAs ProblemJSON 404 "Analysis not found" ProblemDetails,
     RespondAs ProblemJSON 409 "Revision conflict or account limit reached" ProblemDetails,
     RespondAs ProblemJSON 503 "Analysis store unavailable" ProblemDetails
   ]

instance AsUnion (AnalysisResponses desc a) (AnalysisResult a) where
  toUnion = \case
    AnalysisOk x -> Z (I x)
    AnalysisBadRequest x -> S (Z (I x))
    AnalysisNotFound x -> S (S (Z (I x)))
    AnalysisConflict x -> S (S (S (Z (I x))))
    AnalysisUnavailable x -> S (S (S (S (Z (I x)))))
  fromUnion = \case
    Z (I x) -> AnalysisOk x
    S (Z (I x)) -> AnalysisBadRequest x
    S (S (Z (I x))) -> AnalysisNotFound x
    S (S (S (Z (I x)))) -> AnalysisConflict x
    S (S (S (S (Z (I x))))) -> AnalysisUnavailable x
    S (S (S (S (S impossible)))) -> case impossible of {}

type AtAnalysis sub = "analyses" :> MetricsAuth :> Capture "id" UUID :> sub

type AnalysisReply method a = MultiVerb method '[JSON, ProblemJSON] (AnalysisResponses "Saved analysis result" a) (AnalysisResult a)

data Analyses mode = Analyses
  { createAnalysis :: mode :- "analyses" :> MetricsAuth :> Description "Save opaque client state without executing or interpreting it. Names are trimmed, 1..120 Unicode characters; descriptions retain whitespace, maximum 500 characters. Metadata rejects zero characters. documentVersion is a positive integer; document must be an object, maximum 32768 compact Aeson UTF-8 bytes. Raw analysis request bodies have a separate 5 MiB transport limit, independent of the ingest body setting. Duplicate names are allowed. The positive KANSOKU_ANALYSES_MAX_PER_ACCOUNT limit defaults to 1000 and must match on all replicas. A full account returns non-retryable 409 analysis_limit_reached." :> ReqBody '[JSON] AnalysisInput :> AnalysisReply 'POST SavedAnalysis,
    getAnalysis :: mode :- AtAnalysis (AnalysisReply 'GET SavedAnalysis),
    listAnalyses :: mode :- "analyses" :> MetricsAuth :> Description "Current-read pages ordered by updatedAt descending, id ascending. Default 20, maximum 100. Both directions keep canonical order. Cursors preserve microseconds, survive deletion/replacement of their source row, and must be reused with the same kind filter. No cross-request snapshot; refresh from the first page after edits. Invalid kind returns a 400 problem document; invalid pagination uses the existing Relay JSON error." :> QueryParam "kind" AnalysisKind :> RelayPage 20 100 :> PageReply SavedAnalysis,
    replaceAnalysis :: mode :- AtAnalysis (Description "Full replacement with required positive revision from the last read. Stale revision returns 409 analysis_revision_conflict. Every successful replacement increments revision, preserves createdAt and advances updatedAt, including identical content. The same field and byte limits as create apply." :> ReqBody '[JSON] AnalysisReplace :> AnalysisReply 'PUT SavedAnalysis),
    deleteAnalysis :: mode :- AtAnalysis (Description "Delete with the required positive revision from the last read. Stale revision returns 409; missing or foreign IDs return 404, including repeated deletion." :> QueryParam' '[Required, Strict] "revision" Revision :> AnalysisReply 'DELETE Bool)
  }
  deriving stock (Generic)
