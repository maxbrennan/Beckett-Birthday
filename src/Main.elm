port module Main exposing (main)

import Browser
import Html exposing (Html, button, div, img, input, p, text)
import Html.Attributes exposing (placeholder, src, style, type_, value)
import Html.Events exposing (onClick, onInput)
import Json.Decode as Decode exposing (Decoder)
import Process
import Task


port receiveDevices : (String -> msg) -> Sub msg

port playMusic : String -> Cmd msg

port stopMusic : String -> Cmd msg

port receiveTrackInfo : ({ name : String, currentTime : Float, duration : Float } -> msg) -> Sub msg

port trackEnded : (String -> msg) -> Sub msg

port musicError : (String -> msg) -> Sub msg


debug : Bool
debug =
    True


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


type alias TrackInfo =
    { name : String
    , currentTime : Float
    , duration : Float
    }


type Screen
    = ConnectScreen
    | BeginScreen
    | BlankScreen
    | QuestionScreen String


type alias Model =
    { connected : Bool
    , screen : Screen
    , trackInfo : Maybe TrackInfo
    }


type Msg
    = DevicesReceived String
    | BeginPressed
    | StartGolden
    | TrackEnded String
    | ShowQuestion
    | TrackInfoReceived TrackInfo
    | MusicError String
    | AnswerChanged String


init : () -> ( Model, Cmd Msg )
init _ =
    ( { connected = False, screen = ConnectScreen, trackInfo = Nothing }
    , playMusic "jeopardy-theme.mp3"
    )


sleep : Float -> Msg -> Cmd Msg
sleep ms msg =
    Task.perform (\_ -> msg) (Process.sleep ms)


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        DevicesReceived json ->
            let
                connected =
                    parseDevices json || debug
            in
            if connected then
                let
                    newScreen =
                        case model.screen of
                            ConnectScreen ->
                                BeginScreen

                            other ->
                                other
                in
                ( { model | connected = True, screen = newScreen }, Cmd.none )

            else
                let
                    cmd =
                        case model.screen of
                            BlankScreen ->
                                playMusic "jeopardy-theme.mp3"

                            QuestionScreen _ ->
                                playMusic "jeopardy-theme.mp3"

                            _ ->
                                Cmd.none
                in
                ( { model | connected = False, screen = ConnectScreen }, cmd )

        BeginPressed ->
            ( { model | screen = BlankScreen }
            , Cmd.batch
                [ stopMusic "jeopardy-theme.mp3"
                , sleep 1000 StartGolden
                ]
            )

        StartGolden ->
            case model.screen of
                BlankScreen ->
                    ( model, playMusic "golden.mp3" )

                _ ->
                    ( model, Cmd.none )

        TrackEnded name ->
            if name == "golden.mp3" then
                case model.screen of
                    BlankScreen ->
                        ( model, sleep 1000 ShowQuestion )

                    _ ->
                        ( model, Cmd.none )

            else if name == "jeopardy-theme.mp3" then
                case model.screen of
                    ConnectScreen ->
                        ( model, playMusic "jeopardy-theme.mp3" )

                    BeginScreen ->
                        ( model, playMusic "jeopardy-theme.mp3" )

                    _ ->
                        ( model, Cmd.none )

            else
                ( model, Cmd.none )

        ShowQuestion ->
            case model.screen of
                BlankScreen ->
                    ( { model | screen = QuestionScreen "" }, Cmd.none )

                _ ->
                    ( model, Cmd.none )

        TrackInfoReceived info ->
            ( { model | trackInfo = Just info }, Cmd.none )

        MusicError _ ->
            ( model, Cmd.none )

        AnswerChanged text ->
            case model.screen of
                QuestionScreen _ ->
                    ( { model | screen = QuestionScreen text }, Cmd.none )

                _ ->
                    ( model, Cmd.none )


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
    case model.screen of
        ConnectScreen ->
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

        BeginScreen ->
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

        BlankScreen ->
            screen []

        QuestionScreen answer ->
            screen
                [ p
                    [ style "font-size" "26px"
                    , style "color" "#2c4a5a"
                    , style "text-align" "center"
                    , style "margin" "0"
                    , style "max-width" "560px"
                    , style "line-height" "1.5"
                    ]
                    [ text "Let's start with an easy one. What song just played?" ]
                , input
                    [ type_ "text"
                    , value answer
                    , onInput AnswerChanged
                    , placeholder "Type your answer..."
                    , style "font-size" "22px"
                    , style "padding" "12px 20px"
                    , style "border-radius" "8px"
                    , style "border" "1px solid #4a9eca"
                    , style "outline" "none"
                    , style "width" "400px"
                    , style "box-sizing" "border-box"
                    ]
                    []
                ]


subscriptions : Model -> Sub Msg
subscriptions _ =
    Sub.batch
        [ receiveDevices DevicesReceived
        , receiveTrackInfo TrackInfoReceived
        , trackEnded TrackEnded
        , musicError MusicError
        ]


main : Program () Model Msg
main =
    Browser.element
        { init = init
        , update = update
        , view = view
        , subscriptions = subscriptions
        }
