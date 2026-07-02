port module Server exposing (..)

import Dict exposing (Dict)
import Json.Decode as Decode
import Json.Encode as Encode
import Platform
import Server.Distribution exposing (..)
import Server.Protocol exposing (..)
import Server.Registry exposing (..)
import Set exposing (Set)



type alias Model =
    { connectedPlayers : Dict String String
    , distClients : Dict String DistStage
    , registry : List RegistryEntry
    , isDev : Bool
    , pendingStateEdits : Set String
    }


type Msg
    = ClientConnected String
    | ClientDisconnected String
    | MessageReceived { clientId : String, payload : Encode.Value }
    | FileRead String (Result String String)
    | AuthCompleted { clientId : String, success : Bool, level : Int, uuid : String }
    | WriteFileCompleted { path : String, ok : Bool, error : Maybe String }





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
      , pendingStateEdits = Set.empty
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
                    if Set.member uuid model.pendingStateEdits then
                        ( { model
                            | connectedPlayers = Dict.remove uuid model.connectedPlayers
                            , distClients = cleanedDist
                          }
                        , Cmd.none
                        )

                    else
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
                    if Set.member uuid model.pendingStateEdits then
                        ( model
                        , rejectAndClose { clientId = clientId, reason = "state is being edited by admin", payload = rejectEnvelope "state is being edited by admin" }
                        )

                    else if Dict.member uuid model.connectedPlayers then
                        ( model
                        , rejectAndClose { clientId = clientId, reason = "duplicate uuid", payload = rejectEnvelope "player already connected" }
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
                                    , rejectAndClose { clientId = clientId, reason = "unknown uuid", payload = rejectEnvelope "unknown uuid" }
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

                Ok (ClientDistComplete { uuid, filename }) ->
                    case Dict.get clientId model.distClients of
                        Just (AwaitingUpload info) ->
                            if info.uuid == uuid then
                                let
                                    newEntry =
                                        { uuid = uuid
                                        , filename = filename
                                        , platform = info.platform
                                        , state = Nothing
                                        }

                                    newRegistry =
                                        List.filter (\e -> e.filename /= filename) model.registry
                                            ++ [ newEntry ]
                                in
                                ( { model
                                    | distClients = Dict.remove clientId model.distClients
                                    , registry = newRegistry
                                  }
                                , Cmd.batch
                                    [ writeRegistry newRegistry
                                    , sendToClient { clientId = clientId, payload = ackEnvelope }
                                    ]
                                )

                            else
                                ( model, Cmd.none )

                        _ ->
                            ( model, Cmd.none )

                Ok (ClientDistStateEdit uuid) ->
                    let
                        maybePlayerClientId =
                            Dict.get uuid model.connectedPlayers

                        currentState =
                            model.registry
                                |> List.filter (\e -> e.uuid == uuid)
                                |> List.head
                                |> Maybe.andThen .state
                                |> Maybe.withDefault (Encode.object [])
                    in
                    ( { model | pendingStateEdits = Set.insert uuid model.pendingStateEdits }
                    , Cmd.batch
                        [ case maybePlayerClientId of
                            Nothing ->
                                Cmd.none

                            Just playerClientId ->
                                closeClient { clientId = playerClientId, reason = "admin editing state" }
                        , stateEditReady { adminClientId = clientId, uuid = uuid, json = Encode.encode 0 currentState }
                        ]
                    )

                Ok (ClientDistStateEditSave { uuid, json }) ->
                    case Decode.decodeString Decode.value json of
                        Ok parsedState ->
                            let
                                newRegistry =
                                    updateEntryState uuid parsedState model.registry
                            in
                            ( { model
                                | registry = newRegistry
                                , pendingStateEdits = Set.remove uuid model.pendingStateEdits
                              }
                            , Cmd.batch
                                [ writeRegistry newRegistry
                                , sendToClient { clientId = clientId, payload = ackEnvelope }
                                ]
                            )

                        Err _ ->
                            ( model, sendToClient { clientId = clientId, payload = rejectEnvelope "invalid json" } )

                Ok (ClientDistUndeploy uuid) ->
                    let
                        maybePlayerClientId =
                            Dict.get uuid model.connectedPlayers

                        maybeTarget =
                            model.registry
                                |> List.filter (\e -> e.uuid == uuid)
                                |> List.head

                        newRegistry =
                            List.filter (\e -> e.uuid /= uuid) model.registry
                    in
                    ( { model
                        | registry = newRegistry
                        , connectedPlayers = Dict.remove uuid model.connectedPlayers
                      }
                    , Cmd.batch
                        [ case maybePlayerClientId of
                            Nothing ->
                                Cmd.none

                            Just playerClientId ->
                                closeClient { clientId = playerClientId, reason = "admin undeployed build" }
                        , case maybeTarget of
                            Nothing ->
                                Cmd.none

                            Just target ->
                                deleteBuildFile target.filename
                        , writeRegistry newRegistry
                        , sendToClient { clientId = clientId, payload = ackEnvelope }
                        ]
                    )

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

port rejectAndClose : { clientId : String, reason : String, payload : Encode.Value } -> Cmd msg

port readFile : String -> Cmd msg

port readFileResult : ({ path : String, contents : Maybe String, error : Maybe String } -> msg) -> Sub msg

port requestAuth : { clientId : String, level : Int } -> Cmd msg

port authResult : ({ clientId : String, success : Bool, level : Int, uuid : String } -> msg) -> Sub msg

port writeFile : { path : String, contents : String, encoding : String, append : Bool } -> Cmd msg

port writeFileResult : ({ path : String, ok : Bool, error : Maybe String } -> msg) -> Sub msg

port stateEditReady : { adminClientId : String, uuid : String, json : String } -> Cmd msg

port deleteBuildFile : String -> Cmd msg
