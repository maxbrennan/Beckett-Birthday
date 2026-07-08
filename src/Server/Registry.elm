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
    -- encodeIqTimerStateFull. This is a TEMPORARY, IQ-only stepping stone: it
    -- exists so a server restart can rehydrate the in-memory iqTimers Dict
    -- (see Server.elm's init) instead of silently losing a player's progress.
    -- Every other screen still round-trips through `state` alone, written
    -- verbatim from the client's own stateUpdate. A future PR generalizing
    -- server-side ownership beyond the IQ test would likely replace this
    -- field with something less IQ-specific.
    , iqTimer : Maybe Encode.Value
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
    Decode.map7 RegistryEntry
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


-- Replace a single top-level key of a JSON object, leaving every other key
-- untouched. Used to overwrite just the `screen` field of a persisted state
-- blob while preserving pending/now/etc. exactly as last reported.
overwriteField : String -> Encode.Value -> Encode.Value -> Encode.Value
overwriteField key newValue original =
    Decode.decodeValue (Decode.dict Decode.value) original
        |> Result.withDefault Dict.empty
        |> Dict.insert key newValue
        |> Encode.dict identity identity


setPendingStateEdit : String -> List RegistryEntry -> List RegistryEntry
setPendingStateEdit uuid =
    List.map
        (\e ->
            if e.uuid == uuid then
                { e | pendingStateEdit = True }

            else
                e
        )
