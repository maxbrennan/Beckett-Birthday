module Server.Distribution exposing (..)


type alias DistInfo =
    { uuid : String, platform : String }


type DistStage
    = AwaitingAuth DistInfo
    | AwaitingUpload DistInfo
