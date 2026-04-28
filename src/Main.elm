port module Main exposing (main)

import Browser
import Html exposing (Html, button, div, img, p, text)
import Html.Attributes exposing (src, style)
import Html.Events exposing (onClick)
import Json.Decode as Decode exposing (Decoder)


port receiveDevices : (String -> msg) -> Sub msg


port stopMusic : () -> Cmd msg


port restartMusic : () -> Cmd msg


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
    { connected : Bool
    , begun : Bool
    }


type Msg
    = DevicesReceived String
    | BeginPressed


init : () -> ( Model, Cmd Msg )
init _ =
    ( { connected = False, begun = False }, Cmd.none )


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        DevicesReceived json ->
            let
                connected =
                    parseDevices json

                cmd =
                    if not connected && model.begun then
                        restartMusic ()

                    else
                        Cmd.none
            in
            ( { connected = connected, begun = model.begun && connected }, cmd )

        BeginPressed ->
            ( { model | begun = True }, stopMusic () )


screen : List (Html Msg) -> Html Msg
screen children =
    div
        [ style "height" "100vh"
        , style "background-color" "#a8c8e0"
        , style "display" "flex"
        , style "flex-direction" "column"
        , style "align-items" "center"
        , style "justify-content" "center"
        , style "gap" "36px"
        ]
        children


headphones : Html Msg
headphones =
    img
        [ src "assets/airpods.png"
        , style "width" "340px"
        ]
        []


view : Model -> Html Msg
view model =
    if not model.connected then
        screen
            [ headphones
            , p
                [ style "font-size" "26px"
                , style "color" "#2c4a5a"
                , style "text-align" "center"
                , style "margin" "0"
                , style "max-width" "480px"
                , style "line-height" "1.5"
                ]
                [ text "Connect your AirPods Max 2 and turn up the volume." ]
            ]

    else if not model.begun then
        screen
            [ headphones
            , p
                [ style "font-size" "26px"
                , style "color" "#2c4a5a"
                , style "text-align" "center"
                , style "margin" "0"
                , style "max-width" "480px"
                , style "line-height" "1.5"
                ]
                [ text "Press Begin once you can hear the music." ]
            , button
                [ onClick BeginPressed
                , style "padding" "20px 64px"
                , style "font-size" "24px"
                , style "cursor" "pointer"
                , style "border-radius" "12px"
                , style "border" "none"
                , style "background-color" "#4a9eca"
                , style "color" "white"
                , style "font-weight" "bold"
                ]
                [ text "Begin" ]
            ]

    else
        screen []


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
