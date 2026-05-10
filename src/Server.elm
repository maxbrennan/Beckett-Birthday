port module Server exposing (..)

import Json.Encode as Encode
import Platform


type alias Model =
    { state : Encode.Value }


type Msg
    = ClientConnected String
    | MessageReceived { clientId : String, payload : Encode.Value }


init : () -> ( Model, Cmd Msg )
init _ =
    ( { state = Encode.object [] }, Cmd.none )


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        ClientConnected clientId ->
            ( model, sendToClient { clientId = clientId, payload = model.state } )

        MessageReceived { payload } ->
            ( { model | state = payload }, Cmd.none )


subscriptions : Model -> Sub Msg
subscriptions _ =
    Sub.batch
        [ onConnection ClientConnected
        , onMessage MessageReceived
        ]


main : Program () Model Msg
main =
    Platform.worker
        { init = init
        , update = update
        , subscriptions = subscriptions
        }


port onConnection : (String -> msg) -> Sub msg

port onMessage : ({ clientId : String, payload : Encode.Value } -> msg) -> Sub msg

port sendToClient : { clientId : String, payload : Encode.Value } -> Cmd msg
