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
    { uuid : String, filename : String, platform : String }


type alias Model =
    { state : Encode.Value
    , connectedClientId : Maybe String
    , distClients : Dict String DistStage
    , registry : List RegistryEntry
    }


type Msg
    = ClientConnected String
    | ClientDisconnected String
    | MessageReceived { clientId : String, payload : Encode.Value }
    | FileRead String (Result String String)
    | AuthCompleted { clientId : String, success : Bool, level : Int, uuid : String }
    | WriteFileCompleted { path : String, ok : Bool, error : Maybe String }


stateFilePath : String
stateFilePath =
    "state.json"


registryFilePath : String
registryFilePath =
    "app-builds/registry.json"


type ClientEnvelope
    = ClientStateUpdate Encode.Value
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


encodeRegistryEntry : RegistryEntry -> Encode.Value
encodeRegistryEntry entry =
    Encode.object
        [ ( "uuid", Encode.string entry.uuid )
        , ( "filename", Encode.string entry.filename )
        , ( "platform", Encode.string entry.platform )
        ]


encodeRegistry : List RegistryEntry -> String
encodeRegistry entries =
    Encode.encode 2 (Encode.list encodeRegistryEntry entries)


decodeRegistry : Decode.Decoder (List RegistryEntry)
decodeRegistry =
    Decode.list
        (Decode.map3 (\u f p -> { uuid = u, filename = f, platform = p })
            (Decode.field "uuid" Decode.string)
            (Decode.field "filename" Decode.string)
            (Decode.field "platform" Decode.string)
        )


snapshotForJeopardy : Encode.Value -> Encode.Value
snapshotForJeopardy state =
    let
        getField name =
            Decode.decodeValue (Decode.field name Decode.value) state
                |> Result.withDefault Encode.null

        savedState =
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


init : () -> ( Model, Cmd Msg )
init _ =
    ( { state = Encode.object []
      , connectedClientId = Nothing
      , distClients = Dict.empty
      , registry = []
      }
    , Cmd.batch
        [ readFile stateFilePath
        , readFile registryFilePath
        ]
    )


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        ClientConnected clientId ->
            -- TODO: in the future, reject duplicate connections from the same player UUID.
            -- For now, allow concurrent clients so the dist orchestrator can connect alongside the player.
            -- The "player" slot is claimed lazily on the first StateUpdate, not on connection.
            ( model
            , sendToClient { clientId = clientId, payload = stateEnvelope model.state }
            )

        ClientDisconnected clientId ->
            let
                cleanedDist =
                    Dict.remove clientId model.distClients
            in
            if model.connectedClientId == Just clientId then
                let
                    newState =
                        snapshotForJeopardy model.state
                in
                ( { model
                    | connectedClientId = Nothing
                    , state = newState
                    , distClients = cleanedDist
                  }
                , saveState newState
                )

            else
                ( { model | distClients = cleanedDist }, Cmd.none )

        MessageReceived { clientId, payload } ->
            case Decode.decodeValue decodeClientEnvelope payload of
                Ok (ClientStateUpdate inner) ->
                    case model.connectedClientId of
                        Nothing ->
                            ( { model | state = inner, connectedClientId = Just clientId }
                            , Cmd.batch
                                [ saveState inner
                                , sendToClient { clientId = clientId, payload = ackEnvelope }
                                ]
                            )

                        Just current ->
                            if current == clientId then
                                ( { model | state = inner }
                                , Cmd.batch
                                    [ saveState inner
                                    , sendToClient { clientId = clientId, payload = ackEnvelope }
                                    ]
                                )

                            else
                                ( model, Cmd.none )

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

                                    -- chunkIndex == 0 truncates / starts the file; later chunks append.
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
                                            }

                                        -- Replace any existing entry for this filename; otherwise append.
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
                                        , writeFile
                                            { path = registryFilePath
                                            , contents = encodeRegistry newRegistry
                                            , encoding = "utf8"
                                            , append = False
                                            }
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
            if path == stateFilePath then
                case result of
                    Ok contents ->
                        case Decode.decodeString Decode.value contents of
                            Ok value ->
                                ( { model | state = value }, Cmd.none )

                            Err _ ->
                                ( model, Cmd.none )

                    Err _ ->
                        ( model, Cmd.none )

            else if path == registryFilePath then
                case result of
                    Ok contents ->
                        case Decode.decodeString decodeRegistry contents of
                            Ok entries ->
                                ( { model | registry = entries }, Cmd.none )

                            Err _ ->
                                ( model, Cmd.none )

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


main : Program () Model Msg
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

port saveState : Encode.Value -> Cmd msg

port readFile : String -> Cmd msg

port readFileResult : ({ path : String, contents : Maybe String, error : Maybe String } -> msg) -> Sub msg

port requestAuth : { clientId : String, level : Int } -> Cmd msg

port authResult : ({ clientId : String, success : Bool, level : Int, uuid : String } -> msg) -> Sub msg

port writeFile : { path : String, contents : String, encoding : String, append : Bool } -> Cmd msg

port writeFileResult : ({ path : String, ok : Bool, error : Maybe String } -> msg) -> Sub msg
