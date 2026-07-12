module Server.Registry exposing (..)

import Dict
import Json.Decode as Decode
import Json.Encode as Encode


type alias RegistryEntry =
    { uuid : String
    , filename : String
    , platform : String
    , state : Maybe Encode.Value
    , pendingStateEdit : Bool
    , winText : String

    -- Opaque (Registry.elm never inspects it) snapshot of the IQ test's
    -- server-owned Server.IqTimerState, encoded via Server.elm's
    -- encodeIqTimerStateFull. It exists so a server restart can rehydrate the
    -- in-memory iqTimers Dict (see Server.elm's init) instead of silently
    -- losing a player's progress. quizProgress below is the generalization of
    -- this idea to the quiz phase; for both, the `state` blob's `screen` is
    -- overwritten from this server-owned record wherever it's derivable (see
    -- Server.elm's deriveIqScreen/deriveQuizScreen) rather than trusting the
    -- client's own stateUpdate verbatim.
    , iqTimer : Maybe Encode.Value

    -- The furthest quiz question index (see Server.elm's quizProgress Dict)
    -- the server has independently confirmed this player has passed, via
    -- explicit quizAdvanced events rather than the client-reported `state`
    -- blob. Lets a server restart rehydrate quizProgress without trusting
    -- (or losing) anything the client itself claims about its screen.
    , quizProgress : Int

    -- The server-computed epoch-ms deadline for this player's 7-day session
    -- timer. Nothing until their first stateRequest, at which point the server
    -- establishes it once (see Server.elm's ClientStateRequest handling) and it
    -- never changes again for that uuid -- the client only ever receives it
    -- (via timerSyncEnvelope) and renders it, never invents or reports its own.
    , timerEndsAt : Maybe Float

    -- Opaque (Registry.elm never decodes into Game.Quiz.Question -- Server.elm does that)
    -- per-build song/answer list, sent at deploy time on DistComplete/DistReplaceComplete
    -- and used by Server.elm to validate ClientQuizAnswerSubmitted for the connecting
    -- player only. Unlike winText/iqTimer/quizProgress/timerEndsAt above, this is resent
    -- (not inherited from the old entry) on a build replacement -- see Server.elm's
    -- ClientDistReplaceComplete handler.
    , quizQuestions : Maybe Encode.Value
    }


registryFilePath : String
registryFilePath =
    "app-builds/builds.json"


-- ── Codecs ────────────────────────────────────────────────────────────────────


{-| Encodes just the six server/game-state fields (everything except the
file-distribution metadata `uuid`/`filename`/`platform`/`pendingStateEdit`).
Reused both to nest them under `serverState` in `encodeRegistryEntry` below,
and by Server.elm's `performStateEdit` to hand an admin the exact same
document shape for `edit:state` -- one physically merged blob covering
`state` (the screen), `winText`, `iqTimer`, `quizProgress`, `timerEndsAt`, and
`quizQuestions`, rather than just the raw screen.
-}
encodeServerStateFields : ServerStateFields -> Encode.Value
encodeServerStateFields fields =
    Encode.object
        [ ( "state", Maybe.withDefault Encode.null fields.state )
        , ( "winText", Encode.string fields.winText )
        , ( "iqTimer", Maybe.withDefault Encode.null fields.iqTimer )
        , ( "quizProgress", Encode.int fields.quizProgress )
        , ( "timerEndsAt", fields.timerEndsAt |> Maybe.map Encode.float |> Maybe.withDefault Encode.null )
        , ( "quizQuestions", Maybe.withDefault Encode.null fields.quizQuestions )
        ]


{-| `uuid`/`filename`/`platform`/`pendingStateEdit` are file-distribution
metadata and stay top-level; everything server/game-state-related is
physically merged into one nested `serverState` object via
`encodeServerStateFields` above.
-}
encodeRegistryEntry : RegistryEntry -> Encode.Value
encodeRegistryEntry entry =
    Encode.object
        [ ( "uuid", Encode.string entry.uuid )
        , ( "filename", Encode.string entry.filename )
        , ( "platform", Encode.string entry.platform )
        , ( "pendingStateEdit", Encode.bool entry.pendingStateEdit )
        , ( "serverState"
          , encodeServerStateFields
                { state = entry.state
                , winText = entry.winText
                , iqTimer = entry.iqTimer
                , quizProgress = entry.quizProgress
                , timerEndsAt = entry.timerEndsAt
                , quizQuestions = entry.quizQuestions
                }
          )
        ]


encodeRegistry : List RegistryEntry -> String
encodeRegistry entries =
    Encode.encode 2 (Encode.object [ ( "builds", Encode.list encodeRegistryEntry entries ) ]) ++ "\n"


-- Treat a JSON-null-serialized value the same as a genuinely missing field.
decodeOptionalValue : String -> Decode.Decoder (Maybe Encode.Value)
decodeOptionalValue name =
    Decode.maybe (Decode.field name Decode.value)
        |> Decode.map
            (Maybe.andThen
                (\v ->
                    if Encode.encode 0 v == "null" then
                        Nothing

                    else
                        Just v
                )
            )


{-| The six server/game-state fields, nested under `serverState` in the
current shape. Tried there first; falls back to reading them top-level (the
pre-merge shape every row on disk before this change used) so existing
`builds.json` rows keep loading -- same tolerant-decoder convention as the
individual per-field defaults below.
-}
type alias ServerStateFields =
    { state : Maybe Encode.Value
    , winText : String
    , iqTimer : Maybe Encode.Value
    , quizProgress : Int
    , timerEndsAt : Maybe Float
    , quizQuestions : Maybe Encode.Value
    }


decodeServerStateFields : Decode.Decoder ServerStateFields
decodeServerStateFields =
    let
        fields =
            Decode.map4
                (\state winText iqTimer quizProgress ->
                    \timerEndsAt quizQuestions ->
                        ServerStateFields state winText iqTimer quizProgress timerEndsAt quizQuestions
                )
                (decodeOptionalValue "state")
                -- older rows predate the win text; treat missing as empty.
                (Decode.maybe (Decode.field "winText" Decode.string)
                    |> Decode.map (Maybe.withDefault "")
                )
                -- older rows predate the IQ timer snapshot; treat missing as Nothing.
                (decodeOptionalValue "iqTimer")
                -- older rows predate quiz progress tracking; treat missing as 0.
                (Decode.maybe (Decode.field "quizProgress" Decode.int)
                    |> Decode.map (Maybe.withDefault 0)
                )
                |> Decode.andThen
                    (\partial ->
                        Decode.map2 partial
                            -- older rows predate the server-owned timer; treat missing as
                            -- Nothing (established fresh on this player's next stateRequest).
                            (Decode.maybe (Decode.field "timerEndsAt" Decode.float))
                            -- older rows predate per-build quiz questions; treat missing as Nothing.
                            (decodeOptionalValue "quizQuestions")
                    )
    in
    Decode.oneOf [ Decode.field "serverState" fields, fields ]


decodeRegistryEntry : Decode.Decoder RegistryEntry
decodeRegistryEntry =
    Decode.map4
        (\uuid filename platform pendingStateEdit ->
            \serverState ->
                RegistryEntry uuid
                    filename
                    platform
                    serverState.state
                    pendingStateEdit
                    serverState.winText
                    serverState.iqTimer
                    serverState.quizProgress
                    serverState.timerEndsAt
                    serverState.quizQuestions
        )
        (Decode.field "uuid" Decode.string)
        (Decode.field "filename" Decode.string)
        (Decode.field "platform" Decode.string)
        -- older builds.json rows predate this field; treat missing as unlocked.
        (Decode.maybe (Decode.field "pendingStateEdit" Decode.bool)
            |> Decode.map (Maybe.withDefault False)
        )
        |> Decode.andThen (\partial -> Decode.map partial decodeServerStateFields)


decodeRegistry : String -> List RegistryEntry
decodeRegistry contents =
    Decode.decodeString
        (Decode.field "builds" (Decode.list (Decode.maybe decodeRegistryEntry))
            |> Decode.map (List.filterMap identity)
        )
        contents
        |> Result.withDefault []


-- ── State Helpers ─────────────────────────────────────────────────────────────


{-| Mark a player as parked on the neutral begin screen by wrapping the
persisted screen in `BeginScreen` -- the wrapped inner value is already
whatever the IQ/quiz/timeout override chain last derived (or the client's own
report, for the families that stay self-reported), so there's nothing to
stash separately: the wrapped screen already *is* the correct resume target,
and unwrapping it (see Main.elm's BeginPressed) is what removes any round-trip
latency from pressing Begin. Idempotent: a screen already wrapped in
BeginScreen is returned unchanged, so a player who reconnects then immediately
disconnects again before ever pressing Begin doesn't get double-wrapped.
-}
snapshotForJeopardy : Encode.Value -> Encode.Value
snapshotForJeopardy screen =
    case Decode.decodeValue (Decode.field "tag" Decode.string) screen of
        Ok "BeginScreen" ->
            screen

        _ ->
            Encode.object [ ( "tag", Encode.string "BeginScreen" ), ( "nextScreen", screen ) ]


findUuidByClient : String -> Dict.Dict String String -> Maybe String
findUuidByClient clientId dict =
    Dict.toList dict
        |> List.filterMap
            (\( u, c ) ->
                if c == clientId then
                    Just u

                else
                    Nothing
            )
        |> List.head


updateEntryState : String -> Encode.Value -> List RegistryEntry -> List RegistryEntry
updateEntryState uuid newState =
    List.map
        (\e ->
            if e.uuid == uuid then
                { e | state = Just newState, pendingStateEdit = False }

            else
                e
        )


-- IQ-only stepping stone (see RegistryEntry.iqTimer). Mirrors updateEntryState
-- but for the opaque server-state snapshot rather than the client-reported one.
updateEntryIqTimer : String -> Maybe Encode.Value -> List RegistryEntry -> List RegistryEntry
updateEntryIqTimer uuid newIqTimer =
    List.map
        (\e ->
            if e.uuid == uuid then
                { e | iqTimer = newIqTimer }

            else
                e
        )


-- Mirrors updateEntryIqTimer but for the plain integer quiz-progress counter.
updateEntryQuizProgress : String -> Int -> List RegistryEntry -> List RegistryEntry
updateEntryQuizProgress uuid newQuizProgress =
    List.map
        (\e ->
            if e.uuid == uuid then
                { e | quizProgress = newQuizProgress }

            else
                e
        )


-- Mirrors updateEntryQuizProgress but for the server-owned session-timer deadline.
updateEntryTimer : String -> Float -> List RegistryEntry -> List RegistryEntry
updateEntryTimer uuid newTimerEndsAt =
    List.map
        (\e ->
            if e.uuid == uuid then
                { e | timerEndsAt = Just newTimerEndsAt }

            else
                e
        )


-- True once `now` has reached or passed this entry's established deadline. An entry
-- with no deadline yet (a brand new player who hasn't sent their first stateRequest)
-- can never be expired.
isExpired : Float -> RegistryEntry -> Bool
isExpired now entry =
    case entry.timerEndsAt of
        Just deadline ->
            now >= deadline

        Nothing ->
            False


-- Overwrite one entry's persisted state with a server-derived screen value.
-- The persisted state *is* the screen's own JSON directly (see Sync.elm's
-- encodeModel), so this is a straight replacement -- no key-within-object
-- indirection needed.
overwriteEntryScreen : String -> Encode.Value -> List RegistryEntry -> List RegistryEntry
overwriteEntryScreen uuid screen =
    List.map
        (\e ->
            if e.uuid == uuid then
                { e | state = Just screen }

            else
                e
        )


setPendingStateEdit : String -> List RegistryEntry -> List RegistryEntry
setPendingStateEdit uuid =
    List.map
        (\e ->
            if e.uuid == uuid then
                { e | pendingStateEdit = True }

            else
                e
        )
