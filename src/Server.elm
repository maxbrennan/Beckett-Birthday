port module Server exposing (..)

import Json.Encode as Encode
import Platform


type alias Model =
    { state : Encode.Value
    , connected : Maybe String
    }


type Msg
    = ClientConnected String
    | ClientDisconnected String
    | MessageReceived { clientId : String, payload : Encode.Value }


init : Encode.Value -> ( Model, Cmd Msg )
init savedState =
    ( { state = savedState, connected = Nothing }, Cmd.none )


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        ClientConnected clientId ->
            case model.connected of
                Just _ ->
                    ( model, rejectClient clientId )

                Nothing ->
                    ( { model | connected = Just clientId }
                    , sendToClient { clientId = clientId, payload = model.state }
                    )

        ClientDisconnected clientId ->
            if model.connected == Just clientId then
                ( { model | connected = Nothing }, Cmd.none )

            else
                ( model, Cmd.none )

        MessageReceived { clientId, payload } ->
            if model.connected == Just clientId then
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


subscriptions : Model -> Sub Msg
subscriptions _ =
    Sub.batch
        [ onConnection ClientConnected
        , onDisconnection ClientDisconnected
        , onMessage MessageReceived
        ]


main : Program Encode.Value Model Msg
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

port rejectClient : String -> Cmd msg

port saveState : Encode.Value -> Cmd msg
