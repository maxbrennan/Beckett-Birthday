port module Main exposing (main)

import Browser
import Html exposing (Html, text)
import Json.Decode as Decode exposing (Decoder)


port receiveDevices : (String -> msg) -> Sub msg


isMatchDecoder : Decoder Bool
isMatchDecoder =
    Decode.map4
        (\m t a r -> m == "Apple Inc." && t == "Bluetooth" && a && r)
        (Decode.field "manufacturer" Decode.string)
        (Decode.field "transport" Decode.string)
        (Decode.field "is_alive" Decode.bool)
        (Decode.field "is_running" Decode.bool)


parseDevices : String -> Bool
parseDevices json =
    let
        decoder =
            Decode.list (Decode.oneOf [ isMatchDecoder, Decode.succeed False ])
    in
    case Decode.decodeString decoder json of
        Ok results ->
            List.length (List.filter identity results) == 1

        Err _ ->
            False


type alias Model =
    Bool


type Msg
    = DevicesReceived String


init : () -> ( Model, Cmd Msg )
init _ =
    ( False, Cmd.none )


update : Msg -> Model -> ( Model, Cmd Msg )
update (DevicesReceived json) _ =
    ( parseDevices json, Cmd.none )


view : Model -> Html Msg
view model =
    text
        (if model then
            "true"

         else
            "false"
        )


subscriptions : Model -> Sub Msg
subscriptions _ =
    receiveDevices DevicesReceived


main : Program () Model Msg
main =
    Browser.element
        { init = init
        , update = update
        , view = view
        , subscriptions = subscriptions
        }
