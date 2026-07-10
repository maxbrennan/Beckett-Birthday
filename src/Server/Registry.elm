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
    }


registryFilePath : String
registryFilePath =
    "app-builds/builds.jsonl"


-- ── Codecs ────────────────────────────────────────────────────────────────────


encodeRegistryEntry : RegistryEntry -> Encode.Value
encodeRegistryEntry entry =
    Encode.object
        [ ( "uuid", Encode.string entry.uuid )
        , ( "filename", Encode.string entry.filename )
        , ( "platform", Encode.string entry.platform )
        , ( "state", Maybe.withDefault Encode.null entry.state )
        , ( "pendingStateEdit", Encode.bool entry.pendingStateEdit )
        , ( "winText", Encode.string entry.winText )
        , ( "iqTimer", Maybe.withDefault Encode.null entry.iqTimer )
        , ( "quizProgress", Encode.int entry.quizProgress )
        , ( "timerEndsAt", entry.timerEndsAt |> Maybe.map Encode.float |> Maybe.withDefault Encode.null )
        ]


encodeRegistry : List RegistryEntry -> String
encodeRegistry entries =
    let
        body =
            entries
                |> List.map (\e -> Encode.encode 0 (encodeRegistryEntry e))
                |> String.join "\n"
    in
    if body == "" then
        ""

    else
        body ++ "\n"


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


decodeRegistryEntry : Decode.Decoder RegistryEntry
decodeRegistryEntry =
    Decode.map8
        (\uuid filename platform state pendingStateEdit winText iqTimer quizProgress ->
            RegistryEntry uuid filename platform state pendingStateEdit winText iqTimer quizProgress
        )
        (Decode.field "uuid" Decode.string)
        (Decode.field "filename" Decode.string)
        (Decode.field "platform" Decode.string)
        (decodeOptionalValue "state")
        -- older builds.jsonl rows predate this field; treat missing as unlocked.
        (Decode.maybe (Decode.field "pendingStateEdit" Decode.bool)
            |> Decode.map (Maybe.withDefault False)
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
                -- older rows predate the server-owned timer; treat missing as Nothing
                -- (established fresh on this player's next stateRequest).
                Decode.map partial
                    (Decode.maybe (Decode.field "timerEndsAt" Decode.float))
            )


parseRegistryJsonl : String -> List RegistryEntry
parseRegistryJsonl raw =
    raw
        |> String.split "\n"
        |> List.filter (\l -> String.trim l /= "")
        |> List.filterMap (\l -> Decode.decodeString decodeRegistryEntry l |> Result.toMaybe)


-- ── State Helpers ─────────────────────────────────────────────────────────────


snapshotForJeopardy : Encode.Value -> Encode.Value
snapshotForJeopardy state =
    let
        getField name =
            Decode.decodeValue (Decode.field name Decode.value) state
                |> Result.withDefault Encode.null

        screenTag =
            Decode.decodeValue (Decode.at [ "screen", "tag" ] Decode.string) state
                |> Result.withDefault ""

        savedState =
            if screenTag == "BeginScreen" then
                -- Screen is already BeginScreen (e.g. client reconnected then immediately
                -- disconnected). Carry the existing savedState forward so the original
                -- game position is not clobbered. BeginScreen can never become a savedState.
                getField "savedState"

            else
                Encode.object
                    [ ( "screen", getField "screen" )
                    , ( "pending", getField "pending" )
                    , ( "savedAt", getField "now" )
                    , ( "songResumeTime", Encode.null )
                    , ( "videoResumeTime", Encode.null )
                    ]

        stateDict =
            Decode.decodeValue (Decode.dict Decode.value) state
                |> Result.withDefault Dict.empty
    in
    stateDict
        |> Dict.insert "screen" (Encode.object [ ( "tag", Encode.string "BeginScreen" ) ])
        |> Dict.insert "jeopardyPlaying" (Encode.bool True)
        |> Dict.insert "pending" (Encode.list identity [])
        |> Dict.insert "savedState" savedState
        |> Encode.dict identity identity


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


-- Replace a single top-level key of a JSON object, leaving every other key
-- untouched. Used to overwrite just the `screen` field of a persisted state
-- blob while preserving pending/now/etc. exactly as last reported.
overwriteField : String -> Encode.Value -> Encode.Value -> Encode.Value
overwriteField key newValue original =
    Decode.decodeValue (Decode.dict Decode.value) original
        |> Result.withDefault Dict.empty
        |> Dict.insert key newValue
        |> Encode.dict identity identity


-- Overwrite just the `screen` of one entry's persisted state blob with a
-- server-derived value, preserving pending/now/etc. exactly as last reported.
overwriteEntryScreen : String -> Encode.Value -> List RegistryEntry -> List RegistryEntry
overwriteEntryScreen uuid screen =
    List.map
        (\e ->
            if e.uuid == uuid then
                { e | state = Just (overwriteField "screen" screen (Maybe.withDefault (Encode.object []) e.state)) }

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
