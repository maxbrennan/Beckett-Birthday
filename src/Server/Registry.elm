module Server.Registry exposing (..)

import Dict
import Json.Decode as Decode
import Json.Encode as Encode


{-| Deliberately has **no** persisted screen field. Every player-facing screen
is synthesized fresh, at connect time, purely from `iqTimer`/`quizProgress`/
`winText`/`quizQuestions`/`timerEndsAt` (see Server.elm's `ClientStateRequest`
and `deriveIqScreen`/`deriveQuizOrWinScreen`/`deriveTimedOutScreen`) -- these
five fields are collectively the *only* source of truth for what a
reconnecting player sees. There is deliberately nothing else to cache or keep
in sync: previously a `state` field held a write-time-derived copy of the
screen, but every screen tag that matters is a pure function of the fields
below, so caching it only risked drifting out of sync with them.
-}
type alias RegistryEntry =
    { uuid : String
    , filename : String
    , platform : String
    , pendingStateEdit : Bool
    , winText : String

    -- Opaque (Registry.elm never inspects it) snapshot of the IQ test's
    -- server-owned Server.IqTimerState, encoded via Server.elm's
    -- encodeIqTimerStateFull. It exists so a server restart can rehydrate the
    -- in-memory iqTimers Dict (see Server.elm's init) instead of silently
    -- losing a player's progress. quizProgress below is the generalization of
    -- this idea to the quiz phase.
    , iqTimer : Maybe Encode.Value

    -- The furthest quiz question index (see Server.elm's quizProgress Dict)
    -- the server has independently confirmed this player has passed, via
    -- explicit quizAdvanced events rather than anything the client itself
    -- claims. Lets a server restart rehydrate quizProgress without trusting
    -- (or losing) anything the client reports.
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


{-| Encodes just the five server/game-state fields (everything except the
file-distribution metadata `uuid`/`filename`/`platform`/`pendingStateEdit`).
Reused both to nest them under `serverState` in `encodeRegistryEntry` below,
and by Server.elm's `performStateEdit` to hand an admin the exact same
document shape for `edit:state` -- `winText`, `iqTimer`, `quizProgress`,
`timerEndsAt`, and `quizQuestions` are the sole editable, authoritative
fields; there is no separate screen to edit, since it's always derived fresh
from these (see RegistryEntry's doc comment).
-}
encodeServerStateFields : ServerStateFields -> Encode.Value
encodeServerStateFields fields =
    Encode.object
        [ ( "winText", Encode.string fields.winText )
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
                { winText = entry.winText
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


{-| The five server/game-state fields, nested under `serverState` in the
current shape. Tried there first; falls back to reading them top-level (the
pre-merge shape every row on disk before this change used) so existing
`builds.json` rows keep loading -- same tolerant-decoder convention as the
individual per-field defaults below. A stale `state`/`screen` key left over
from an older row is simply never asked for, so it's silently ignored -- no
migration needed.
-}
type alias ServerStateFields =
    { winText : String
    , iqTimer : Maybe Encode.Value
    , quizProgress : Int
    , timerEndsAt : Maybe Float
    , quizQuestions : Maybe Encode.Value
    }


decodeServerStateFields : Decode.Decoder ServerStateFields
decodeServerStateFields =
    let
        fields =
            Decode.map3
                (\winText iqTimer quizProgress ->
                    \timerEndsAt quizQuestions ->
                        ServerStateFields winText iqTimer quizProgress timerEndsAt quizQuestions
                )
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


-- IQ-only stepping stone (see RegistryEntry.iqTimer).
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


setPendingStateEdit : String -> List RegistryEntry -> List RegistryEntry
setPendingStateEdit uuid =
    List.map
        (\e ->
            if e.uuid == uuid then
                { e | pendingStateEdit = True }

            else
                e
        )
