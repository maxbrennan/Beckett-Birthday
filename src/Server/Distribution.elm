module Server.Distribution exposing (..)


type alias DistInfo =
    { uuid : String, platform : String }


type DistStage
    = AwaitingAuth DistInfo
    | AwaitingUpload DistInfo
    | AwaitingUndeployAuth String
      -- uuid to remove once admin auth succeeds
    | AwaitingListAuth
    | AwaitingStateEditAuth String
      -- uuid whose state will be opened for editing once admin auth succeeds
    | EditingState String
      -- uuid; authorizes a subsequent distStateEditSave (replaces the JS activeStateEdits set)
