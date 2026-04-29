port module Main exposing (main)

import Browser
import Char
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


type alias Question =
    { song : String
    , answers : List String
    }


questions : List Question
questions =
    [ { song = "golden.mp3", answers = [ "golden" ] }
    , { song = "im-just-ken.mp3", answers = [ "im just ken" ] }
    , { song = "espresso.mp3", answers = [ "espresso" ] }
    , { song = "revenge.mp4", answers = [ "revenge", "revenge parody", "revenge a minecraft parody" ] }
    , { song = "chest-pain.mp3", answers = [ "chest pain", "i love", "chest pain i love" ] }
    , { song = "i-saw-your-face.mp3", answers = [ "i saw your face" ] }
    ]


getQuestion : Int -> Maybe Question
getQuestion idx =
    List.head (List.drop idx questions)


normalize : String -> String
normalize s =
    String.filter Char.isAlpha (String.toLower s)


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
    | BlankScreen Int
    | QuestionScreen Int String
    | WinScreen


type alias Model =
    { connected : Bool
    , screen : Screen
    , trackInfo : Maybe TrackInfo
    , jeopardyPlaying : Bool
    }


type Msg
    = DevicesReceived String
    | BeginPressed
    | PlaySong Int
    | TrackEnded String
    | ShowQuestion Int
    | TrackInfoReceived TrackInfo
    | MusicError String
    | AnswerChanged String
    | AnswerSubmitted


init : () -> ( Model, Cmd Msg )
init _ =
    ( { connected = False, screen = ConnectScreen, trackInfo = Nothing, jeopardyPlaying = True }
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

                    shouldStart =
                        not model.jeopardyPlaying
                            && (newScreen == ConnectScreen || newScreen == BeginScreen)
                in
                ( { model | connected = True, screen = newScreen, jeopardyPlaying = model.jeopardyPlaying || shouldStart }
                , if shouldStart then playMusic "jeopardy-theme.mp3" else Cmd.none
                )

            else
                let
                    needsJeopardy =
                        case model.screen of
                            BlankScreen _ ->
                                True

                            QuestionScreen _ _ ->
                                True

                            _ ->
                                False
                in
                ( { model | connected = False, screen = ConnectScreen, jeopardyPlaying = model.jeopardyPlaying || needsJeopardy }
                , if needsJeopardy then playMusic "jeopardy-theme.mp3" else Cmd.none
                )

        BeginPressed ->
            ( { model | screen = BlankScreen 0, jeopardyPlaying = False }
            , Cmd.batch
                [ stopMusic "jeopardy-theme.mp3"
                , sleep 1000 (PlaySong 0)
                ]
            )

        PlaySong idx ->
            case model.screen of
                BlankScreen blankIdx ->
                    if blankIdx == idx then
                        case getQuestion idx of
                            Just q ->
                                ( model, playMusic q.song )

                            Nothing ->
                                ( model, Cmd.none )

                    else
                        ( model, Cmd.none )

                _ ->
                    ( model, Cmd.none )

        TrackEnded name ->
            if name == "jeopardy-theme.mp3" then
                case model.screen of
                    ConnectScreen ->
                        ( { model | jeopardyPlaying = True }, playMusic "jeopardy-theme.mp3" )

                    BeginScreen ->
                        ( { model | jeopardyPlaying = True }, playMusic "jeopardy-theme.mp3" )

                    _ ->
                        ( { model | jeopardyPlaying = False }, Cmd.none )

            else
                case model.screen of
                    BlankScreen idx ->
                        case getQuestion idx of
                            Just q ->
                                if q.song == name then
                                    ( model, sleep 1000 (ShowQuestion idx) )

                                else
                                    ( model, Cmd.none )

                            Nothing ->
                                ( model, Cmd.none )

                    _ ->
                        ( model, Cmd.none )

        ShowQuestion idx ->
            case model.screen of
                BlankScreen blankIdx ->
                    if blankIdx == idx then
                        ( { model | screen = QuestionScreen idx "" }, Cmd.none )

                    else
                        ( model, Cmd.none )

                _ ->
                    ( model, Cmd.none )

        TrackInfoReceived info ->
            ( { model | trackInfo = Just info }, Cmd.none )

        MusicError _ ->
            ( model, Cmd.none )

        AnswerChanged typed ->
            case model.screen of
                QuestionScreen idx _ ->
                    ( { model | screen = QuestionScreen idx typed }, Cmd.none )

                _ ->
                    ( model, Cmd.none )

        AnswerSubmitted ->
            case model.screen of
                QuestionScreen idx answer ->
                    case getQuestion idx of
                        Just q ->
                            if normalize answer == q.answer then
                                let
                                    nextIdx =
                                        idx + 1
                                in
                                case getQuestion nextIdx of
                                    Just _ ->
                                        ( { model | screen = BlankScreen nextIdx }
                                        , sleep 1000 (PlaySong nextIdx)
                                        )

                                    Nothing ->
                                        ( { model | screen = WinScreen }, Cmd.none )

                            else
                                ( model, Cmd.none )

                        Nothing ->
                            ( model, Cmd.none )

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

        BlankScreen _ ->
            screen []

        QuestionScreen idx answer ->
            let
                prompt =
                    if idx == 0 then
                        "Let's start with an easy one. What song just played?"

                    else
                        "What song just played?"
            in
            screen
                [ p
                    [ style "font-size" "26px"
                    , style "color" "#2c4a5a"
                    , style "text-align" "center"
                    , style "margin" "0"
                    , style "max-width" "560px"
                    , style "line-height" "1.5"
                    ]
                    [ text prompt ]
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
                , button
                    [ onClick AnswerSubmitted
                    , style "padding" "16px 48px"
                    , style "font-size" "22px"
                    , style "cursor" "pointer"
                    , style "border-radius" "12px"
                    , style "border" "none"
                    , style "background-color" "#4a9eca"
                    , style "color" "white"
                    , style "font-weight" "bold"
                    ]
                    [ text "Submit" ]
                ]

        WinScreen ->
            screen
                [ p
                    [ style "font-size" "48px"
                    , style "color" "#2c4a5a"
                    , style "text-align" "center"
                    , style "margin" "0"
                    , style "font-weight" "bold"
                    ]
                    [ text "You Win!" ]
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
