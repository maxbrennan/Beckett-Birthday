module Server.Registry exposing (..)

import Dict
import Json.Decode as Decode
import Json.Encode as Encode


type alias RegistryEntry =
    { uuid : String
    , filename : String
    , platform : String
    , state : Maybe Encode.Value
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


decodeRegistryEntry : Decode.Decoder RegistryEntry
decodeRegistryEntry =
    Decode.map4 RegistryEntry
        (Decode.field "uuid" Decode.string)
        (Decode.field "filename" Decode.string)
        (Decode.field "platform" Decode.string)
        (Decode.maybe (Decode.field "state" Decode.value)
            |> Decode.map
                (Maybe.andThen
                    (\v ->
                        if Encode.encode 0 v == "null" then
                            Nothing

                        else
                            Just v
                    )
                )
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
                { e | state = Just newState }

            else
                e
        )
