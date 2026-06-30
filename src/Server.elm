port module Server exposing (..)

import Dict exposing (Dict)
import Json.Decode as Decode
import Json.Encode as Encode
import Platform


type alias DistInfo =
    { uuid : String, platform : String }


type DistStage
    = AwaitingAuth DistInfo
    | AwaitingUpload DistInfo


type alias RegistryEntry =
    { uuid : String
    , filename : String
    , platform : String
    , state : Maybe Encode.Value
    }


type alias Model =
    { connectedPlayers : Dict String String
    , distClients : Dict String DistStage
    , registry : List RegistryEntry
    , isDev : Bool
    }


type Msg
    = ClientConnected String
    | ClientDisconnected String
    | MessageReceived { clientId : String, payload : Encode.Value }
    | FileRead String (Result String String)
    | AuthCompleted { clientId : String, success : Bool, level : Int, uuid : String }
    | WriteFileCompleted { path : String, ok : Bool, error : Maybe String }


registryFilePath : String
registryFilePath =
    "app-builds/builds.jsonl"


type ClientEnvelope
    = ClientStateUpdate Encode.Value
    | ClientStateRequest String
    | ClientDistRegister DistInfo
    | ClientDistUpload { uuid : String, filename : String, contentsBase64 : String, chunkIndex : Int, isLast : Bool }
    | ClientUnknown


decodeClientEnvelope : Decode.Decoder ClientEnvelope
decodeClientEnvelope =
    Decode.field "payload" Decode.string
        |> Decode.andThen
            (\variant ->
                case variant of
                    "stateUpdate" ->
                        Decode.at [ "stateUpdate", "json" ] Decode.string
                            |> Decode.andThen
                                (\inner ->
                                    case Decode.decodeString Decode.value inner of
                                        Ok v ->
                                            Decode.succeed (ClientStateUpdate v)

                                        Err _ ->
                                            Decode.succeed ClientUnknown
                                )

                    "stateRequest" ->
                        Decode.map ClientStateRequest
                            (Decode.at [ "stateRequest", "uuid" ] Decode.string)

                    "distRegister" ->
                        Decode.map2 (\u p -> ClientDistRegister { uuid = u, platform = p })
                            (Decode.at [ "distRegister", "uuid" ] Decode.string)
                            (Decode.at [ "distRegister", "platform" ] Decode.string)

                    "distUpload" ->
                        Decode.map5
                            (\u f c idx last ->
                                ClientDistUpload
                                    { uuid = u
                                    , filename = f
                                    , contentsBase64 = c
                                    , chunkIndex = idx
                                    , isLast = last
                                    }
                            )
                            (Decode.at [ "distUpload", "uuid" ] Decode.string)
                            (Decode.at [ "distUpload", "filename" ] Decode.string)
                            (Decode.at [ "distUpload", "contents" ] Decode.string)
                            (Decode.at [ "distUpload", "chunkIndex" ] Decode.int)
                            (Decode.at [ "distUpload", "isLast" ] Decode.bool)

                    _ ->
                        Decode.succeed ClientUnknown
            )


stateEnvelope : Encode.Value -> Encode.Value
stateEnvelope state =
    Encode.object
        [ ( "payload", Encode.string "stateUpdate" )
        , ( "stateUpdate", Encode.object [ ( "json", Encode.string (Encode.encode 0 state) ) ] )
        ]


ackEnvelope : Encode.Value
ackEnvelope =
    Encode.object
        [ ( "payload", Encode.string "ack" )
        , ( "ack", Encode.object [] )
        ]


rejectEnvelope : String -> Encode.Value
rejectEnvelope reason =
    Encode.object
        [ ( "payload", Encode.string "stateRequestRejected" )
        , ( "stateRequestRejected", Encode.object [ ( "reason", Encode.string reason ) ] )
        ]


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


findUuidByClient : String -> Dict String String -> Maybe String
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


writeRegistry : List RegistryEntry -> Cmd Msg
writeRegistry entries =
    writeFile
        { path = registryFilePath
        , contents = encodeRegistry entries
        , encoding = "utf8"
        , append = False
        }


init : Bool -> ( Model, Cmd Msg )
init isDev =
    ( { connectedPlayers = Dict.empty
      , distClients = Dict.empty
      , registry = []
      , isDev = isDev
      }
    , readFile registryFilePath
    )


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        ClientConnected _ ->
            ( model, Cmd.none )

        ClientDisconnected clientId ->
            let
                cleanedDist =
                    Dict.remove clientId model.distClients
            in
            case findUuidByClient clientId model.connectedPlayers of
                Nothing ->
                    ( { model | distClients = cleanedDist }, Cmd.none )

                Just uuid ->
                    let
                        currentState =
                            model.registry
                                |> List.filter (\e -> e.uuid == uuid)
                                |> List.head
                                |> Maybe.andThen .state
                                |> Maybe.withDefault (Encode.object [])

                        snapshotted =
                            snapshotForJeopardy currentState

                        newRegistry =
                            updateEntryState uuid snapshotted model.registry
                    in
                    ( { model
                        | connectedPlayers = Dict.remove uuid model.connectedPlayers
                        , distClients = cleanedDist
                        , registry = newRegistry
                      }
                    , writeRegistry newRegistry
                    )

        MessageReceived { clientId, payload } ->
            case Decode.decodeValue decodeClientEnvelope payload of
                Ok (ClientStateRequest uuid) ->
                    if Dict.member uuid model.connectedPlayers then
                        ( model
                        , Cmd.batch
                            [ sendToClient { clientId = clientId, payload = rejectEnvelope "player already connected" }
                            , closeClient { clientId = clientId, reason = "duplicate uuid" }
                            ]
                        )

                    else
                        case List.filter (\e -> e.uuid == uuid) model.registry of
                            [] ->
                                if model.isDev then
                                    ( { model | connectedPlayers = Dict.insert uuid clientId model.connectedPlayers }
                                    , sendToClient { clientId = clientId, payload = stateEnvelope (Encode.object []) }
                                    )

                                else
                                    ( model
                                    , Cmd.batch
                                        [ sendToClient { clientId = clientId, payload = rejectEnvelope "unknown uuid" }
                                        , closeClient { clientId = clientId, reason = "unknown uuid" }
                                        ]
                                    )

                            entry :: _ ->
                                let
                                    initialState =
                                        Maybe.withDefault (Encode.object []) entry.state
                                in
                                ( { model | connectedPlayers = Dict.insert uuid clientId model.connectedPlayers }
                                , sendToClient { clientId = clientId, payload = stateEnvelope initialState }
                                )

                Ok (ClientStateUpdate inner) ->
                    case findUuidByClient clientId model.connectedPlayers of
                        Nothing ->
                            ( model, Cmd.none )

                        Just uuid ->
                            let
                                newRegistry =
                                    updateEntryState uuid inner model.registry
                            in
                            ( { model | registry = newRegistry }
                            , Cmd.batch
                                [ writeRegistry newRegistry
                                , sendToClient { clientId = clientId, payload = ackEnvelope }
                                ]
                            )

                Ok (ClientDistRegister info) ->
                    ( { model | distClients = Dict.insert clientId (AwaitingAuth info) model.distClients }
                    , requestAuth { clientId = clientId, level = 2 }
                    )

                Ok (ClientDistUpload upload) ->
                    case Dict.get clientId model.distClients of
                        Just (AwaitingUpload info) ->
                            if info.uuid == upload.uuid then
                                let
                                    binPath =
                                        "app-builds/" ++ upload.filename

                                    writeChunk =
                                        writeFile
                                            { path = binPath
                                            , contents = upload.contentsBase64
                                            , encoding = "base64"
                                            , append = upload.chunkIndex > 0
                                            }
                                in
                                if upload.isLast then
                                    let
                                        newEntry =
                                            { uuid = upload.uuid
                                            , filename = upload.filename
                                            , platform = info.platform
                                            , state = Nothing
                                            }

                                        newRegistry =
                                            List.filter (\e -> e.filename /= upload.filename) model.registry
                                                ++ [ newEntry ]
                                    in
                                    ( { model
                                        | distClients = Dict.remove clientId model.distClients
                                        , registry = newRegistry
                                      }
                                    , Cmd.batch
                                        [ writeChunk
                                        , writeRegistry newRegistry
                                        , sendToClient { clientId = clientId, payload = ackEnvelope }
                                        ]
                                    )

                                else
                                    ( model, writeChunk )

                            else
                                ( model, Cmd.none )

                        _ ->
                            ( model, Cmd.none )

                _ ->
                    ( model, Cmd.none )

        AuthCompleted { clientId, success, level } ->
            case Dict.get clientId model.distClients of
                Just (AwaitingAuth info) ->
                    if success && level == 2 then
                        ( { model | distClients = Dict.insert clientId (AwaitingUpload info) model.distClients }
                        , sendToClient { clientId = clientId, payload = ackEnvelope }
                        )

                    else
                        ( { model | distClients = Dict.remove clientId model.distClients }
                        , closeClient { clientId = clientId, reason = "Auth failed" }
                        )

                _ ->
                    ( model, Cmd.none )

        FileRead path result ->
            if path == registryFilePath then
                case result of
                    Ok contents ->
                        ( { model | registry = parseRegistryJsonl contents }, Cmd.none )

                    Err _ ->
                        ( model, Cmd.none )

            else
                ( model, Cmd.none )

        WriteFileCompleted _ ->
            ( model, Cmd.none )


subscriptions : Model -> Sub Msg
subscriptions _ =
    Sub.batch
        [ onConnection ClientConnected
        , onDisconnection ClientDisconnected
        , onMessage MessageReceived
        , authResult AuthCompleted
        , writeFileResult WriteFileCompleted
        , readFileResult
            (\{ path, contents, error } ->
                case ( contents, error ) of
                    ( Just c, _ ) ->
                        FileRead path (Ok c)

                    ( _, Just e ) ->
                        FileRead path (Err e)

                    _ ->
                        FileRead path (Err "unknown error")
            )
        ]


main : Program Bool Model Msg
main =
    Platform.worker
        { init = init
        , update = update
        , subscriptions = subscriptions
        }


port onConnection : (String -> msg) -> Sub msg

port onDisconnection : (String -> msg) -> Sub msg

port onMessage : ({ clientId : String, payload : Encode.Value } -> msg) -> Sub msg

port sendToClient : { clientId : String, payload : Encode.Value } -> Cmd msg

port closeClient : { clientId : String, reason : String } -> Cmd msg

port readFile : String -> Cmd msg

port readFileResult : ({ path : String, contents : Maybe String, error : Maybe String } -> msg) -> Sub msg

port requestAuth : { clientId : String, level : Int } -> Cmd msg

port authResult : ({ clientId : String, success : Bool, level : Int, uuid : String } -> msg) -> Sub msg

port writeFile : { path : String, contents : String, encoding : String, append : Bool } -> Cmd msg

port writeFileResult : ({ path : String, ok : Bool, error : Maybe String } -> msg) -> Sub msg
