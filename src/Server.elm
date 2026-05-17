port module Server exposing (..)

import Dict
import Json.Decode as Decode
import Json.Encode as Encode
import Platform


type alias Model =
    { state : Encode.Value
    , connectedClientId : Maybe String
    }


type Msg
    = ClientConnected String
    | ClientDisconnected String
    | MessageReceived { clientId : String, payload : Encode.Value }
    | FileRead String (Result String String)


stateFilePath : String
stateFilePath =
    "state.json"


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
    ( { state = Encode.object [], connectedClientId = Nothing }
    , readFile stateFilePath
    )


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        ClientConnected clientId ->
            case model.connectedClientId of
                Just _ ->
                    ( model, closeClient { clientId = clientId, reason = "Another client is already connected" } )

                Nothing ->
                    ( { model | connectedClientId = Just clientId }
                    , sendToClient { clientId = clientId, payload = model.state }
                    )

        ClientDisconnected clientId ->
            if model.connectedClientId == Just clientId then
                let
                    newState =
                        snapshotForJeopardy model.state
                in
                ( { model | connectedClientId = Nothing, state = newState }
                , saveState newState
                )

            else
                ( model, Cmd.none )

        MessageReceived { clientId, payload } ->
            if model.connectedClientId == Just clientId then
                ( { model | state = payload }
                , Cmd.batch
                    [ saveState payload
                    , sendToClient
                        { clientId = clientId
                        , payload = Encode.object [ ( "tag", Encode.string "ack" ) ]
                        }
                    ]
                )

            else
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

            else
                ( model, Cmd.none )


subscriptions : Model -> Sub Msg
subscriptions _ =
    Sub.batch
        [ onConnection ClientConnected
        , onDisconnection ClientDisconnected
        , onMessage MessageReceived
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
