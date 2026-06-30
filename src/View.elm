module View exposing (..)

import Audio exposing (viewAudio)
import Game.IQTest exposing (..)
import Game.Quiz exposing (..)
import Html exposing (Html, audio, button, div, img, input, p, text, video)
import Html.Attributes exposing (autoplay, id, loop, placeholder, src, style, type_, value)
import Html.Events exposing (on, onClick, onInput)
import Json.Decode as Decode exposing (Decoder)
import Types exposing (..)


-- ── Layout Helpers ────────────────────────────────────────────────────────────


screenBg : String -> List (Html Msg) -> Html Msg
screenBg bg children =
    div
        [ style "height" "100vh"
        , style "background-color" bg
        , style "display" "flex"
        , style "flex-direction" "column"
        , style "align-items" "center"
        , style "justify-content" "center"
        , style "gap" "36px"
        ]
        children


screen : List (Html Msg) -> Html Msg
screen =
    screenBg "#a8c8e0"


headphones : Html Msg
headphones =
    img
        [ src "assets/airpods.png"
        , style "width" "340px"
        ]
        []


-- ── Timer ─────────────────────────────────────────────────────────────────────


formatTimer : Float -> String
formatTimer ms =
    let
        totalSecs =
            floor (ms / 1000)

        days =
            totalSecs // 86400

        hours =
            (totalSecs - days * 86400) // 3600

        minutes =
            (totalSecs - days * 86400 - hours * 3600) // 60

        secs =
            modBy 60 totalSecs
    in
    String.fromInt days
        ++ "d "
        ++ String.fromInt hours
        ++ "h "
        ++ String.fromInt minutes
        ++ "m "
        ++ String.fromInt secs
        ++ "s"


timerBar : Model -> Html Msg
timerBar model =
    let
        showTimer =
            case model.screen of
                WsConnectingScreen ->
                    False

                WsErrorScreen ->
                    False

                WsLoadingScreen ->
                    False

                _ ->
                    True

        remaining =
            max 0 (model.timerEndsAt - model.now)
    in
    if showTimer then
        div
            [ style "position" "fixed"
            , style "top" "0"
            , style "left" "0"
            , style "right" "0"
            , style "background-color" "rgba(0,0,0,0.18)"
            , style "color" "white"
            , style "font-size" "14px"
            , style "font-weight" "bold"
            , style "text-align" "center"
            , style "padding" "6px 0"
            , style "letter-spacing" "0.05em"
            , style "pointer-events" "none"
            ]
            [ text (formatTimer remaining ++ " remaining") ]

    else
        text ""


-- ── Root View ─────────────────────────────────────────────────────────────────


view : Model -> Html Msg
view model =
    div []
        [ viewScreen model
        , viewAudio model
        , timerBar model
        ]


viewScreen : Model -> Html Msg
viewScreen model =
    case model.screen of
        WsConnectingScreen ->
            screen
                [ p
                    [ style "font-size" "26px"
                    , style "color" "#2c4a5a"
                    , style "text-align" "center"
                    , style "margin" "0"
                    ]
                    [ text "Connecting to server..." ]
                ]

        WsErrorScreen ->
            screen
                [ p
                    [ style "font-size" "26px"
                    , style "color" "#c0392b"
                    , style "text-align" "center"
                    , style "margin" "0"
                    , style "max-width" "480px"
                    , style "line-height" "1.5"
                    ]
                    [ text "Something is wrong with the internet connection. Reconnecting..." ]
                ]

        WsLoadingScreen ->
            screen
                [ p
                    [ style "font-size" "26px"
                    , style "color" "#2c4a5a"
                    , style "text-align" "center"
                    , style "margin" "0"
                    ]
                    [ text "Loading..." ]
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

        BlankScreen idx ->
            let
                bg =
                    case getQuestion idx of
                        Just q ->
                            if isVideo q.song then
                                "#000000"

                            else
                                "#a8c8e0"

                        Nothing ->
                            "#a8c8e0"
            in
            screenBg bg
                [ p
                    [ style "font-size" "32px"
                    , style "color" "#2c4a5a"
                    , style "text-align" "center"
                    , style "margin" "0"
                    ]
                    [ text "Listen carefully..." ]
                ]

        VideoScreen _ filename ->
            div
                [ style "position" "fixed"
                , style "top" "0"
                , style "left" "0"
                , style "width" "100vw"
                , style "height" "100vh"
                , style "background-color" "#000000"
                ]
                [ video
                    [ id "playing-video"
                    , src ("assets/" ++ filename)
                    , autoplay True
                    , on "ended" (Decode.succeed (TrackEnded filename))
                    , style "position" "absolute"
                    , style "top" "50%"
                    , style "left" "50%"
                    , style "transform" "translate(-50%, -50%)"
                    , style "width" "100%"
                    , style "height" "100%"
                    , style "object-fit" "contain"
                    ]
                    []
                ]

        QuestionScreen idx answer ->
            let
                prompt =
                    if idx == 0 then
                        "Let's start with an easy one. What song just played?"

                    else
                        "What song just played?"

                total =
                    List.length questions

                progress =
                    "Question " ++ String.fromInt (idx + 1) ++ " of " ++ String.fromInt total
            in
            div []
                [ p
                    [ style "position" "fixed"
                    , style "top" "20px"
                    , style "left" "0"
                    , style "width" "100%"
                    , style "text-align" "center"
                    , style "font-size" "16px"
                    , style "color" "#2c4a5a"
                    , style "margin" "0"
                    ]
                    [ text progress ]
                , screen
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
                        [ id "answer-input"
                        , type_ "text"
                        , value answer
                        , onInput AnswerChanged
                        , on "keydown"
                            (Decode.field "key" Decode.string
                                |> Decode.andThen
                                    (\key ->
                                        if key == "Enter" then
                                            Decode.succeed AnswerSubmitted

                                        else
                                            Decode.fail "not enter"
                                    )
                            )
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
                ]

        WrongAnswerScreen idx ->
            let
                correctAnswer =
                    case getQuestion idx of
                        Just q ->
                            List.head q.answers
                                |> Maybe.map capitalize
                                |> Maybe.withDefault "Unknown"

                        Nothing ->
                            "Unknown"
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
                    [ text ("The song was \"" ++ correctAnswer ++ "\".") ]
                , button
                    [ onClick ContinuePressed
                    , style "padding" "16px 48px"
                    , style "font-size" "22px"
                    , style "cursor" "pointer"
                    , style "border-radius" "12px"
                    , style "border" "none"
                    , style "background-color" "#4a9eca"
                    , style "color" "white"
                    , style "font-weight" "bold"
                    ]
                    [ text "Continue" ]
                ]

        IQTestScreen _ ->
            screen
                [ p
                    [ style "font-size" "36px"
                    , style "color" "#2c4a5a"
                    , style "text-align" "center"
                    , style "margin" "0"
                    , style "font-weight" "bold"
                    ]
                    [ text "IQ Test 2.0" ]
                , p
                    [ style "font-size" "22px"
                    , style "color" "#2c4a5a"
                    , style "text-align" "center"
                    , style "margin" "0"
                    , style "max-width" "560px"
                    , style "line-height" "1.6"
                    ]
                    [ text "You are so dumb that you don't know what song was playing. You must prove your IQ to keep playing." ]
                , p
                    [ style "font-size" "20px"
                    , style "color" "#2c4a5a"
                    , style "text-align" "center"
                    , style "margin" "0"
                    , style "max-width" "520px"
                    , style "line-height" "1.6"
                    ]
                    [ text "Listen carefully for a faint ding. Every time you hear it, press the space bar." ]
                , button
                    [ onClick IQTestBeginPressed
                    , style "padding" "16px 48px"
                    , style "font-size" "22px"
                    , style "cursor" "pointer"
                    , style "border-radius" "12px"
                    , style "border" "none"
                    , style "background-color" "#4a9eca"
                    , style "color" "white"
                    , style "font-weight" "bold"
                    ]
                    [ text "Begin" ]
                ]

        IQTestCountdownScreen state ->
            let
                secondsWord =
                    if state.countdown == 1 then
                        "second"

                    else
                        "seconds"
            in
            screen
                [ p
                    [ style "font-size" "28px"
                    , style "color" "#2c4a5a"
                    , style "text-align" "center"
                    , style "margin" "0"
                    , style "max-width" "560px"
                    , style "line-height" "1.6"
                    ]
                    [ text ("You may start the IQ test in " ++ String.fromInt state.countdown ++ " " ++ secondsWord ++ ".") ]
                ]

        IQTestActiveScreen state ->
            let
                bg =
                    if state.loudPlaying then
                        "#000000"

                    else
                        "#a8c8e0"

                counter =
                    String.fromInt state.dingCount ++ " / " ++ String.fromInt state.totalDings
            in
            div []
                [ if state.isFlashing then
                    div
                        [ style "position" "fixed"
                        , style "top" "0"
                        , style "left" "0"
                        , style "width" "100vw"
                        , style "height" "100vh"
                        , style "background-color" "#00cc44"
                        , style "z-index" "9999"
                        , style "pointer-events" "none"
                        ]
                        []

                  else
                    text ""
                , if state.loudPlaying then
                    video
                        [ id "playing-video"
                        , src "assets/loud.mp4"
                        , autoplay True
                        , loop True
                        , style "position" "fixed"
                        , style "top" "50%"
                        , style "left" "50%"
                        , style "transform" "translate(-50%, -50%)"
                        , style "width" "100vw"
                        , style "height" "100vh"
                        , style "object-fit" "contain"
                        , style "z-index" "0"
                        ]
                        []

                  else
                    text ""
                , p
                    [ style "position" "fixed"
                    , style "top" "20px"
                    , style "left" "0"
                    , style "width" "100%"
                    , style "text-align" "center"
                    , style "font-size" "20px"
                    , style "color" "#2c4a5a"
                    , style "margin" "0"
                    , style "z-index" "10"
                    ]
                    [ text counter ]
                , screenBg bg []
                ]

        FakeFlashCaughtScreen state ->
            let
                big =
                    isCounterBig state.phase

                counterTop =
                    if big then "50%" else "20px"

                counterTransform =
                    if big then "translate(-50%, -50%)" else "translate(-50%, 0)"

                counterFontSize =
                    if big then "96px" else "20px"

                counterOpacity =
                    if state.phase == FfCounterOut then "0" else "1"

                text1Opacity =
                    case state.phase of
                        FfText1In ->
                            "1"

                        FfText1Hold ->
                            "1"

                        _ ->
                            "0"

                text2Opacity =
                    case state.phase of
                        FfText2In ->
                            "1"

                        FfText2Hold ->
                            "1"

                        _ ->
                            "0"

                counterText =
                    String.fromInt state.displayNumerator ++ " / " ++ String.fromInt state.displayDenominator

                text2Transition =
                    case state.phase of
                        FfDelay ->
                            "none"

                        _ ->
                            "opacity 0.8s ease"
            in
            div [ style "height" "100vh", style "background-color" "#a8c8e0" ]
                [ p
                    [ style "position" "fixed"
                    , style "top" counterTop
                    , style "left" "50%"
                    , style "transform" counterTransform
                    , style "font-size" counterFontSize
                    , style "color" "#2c4a5a"
                    , style "margin" "0"
                    , style "font-weight" "bold"
                    , style "text-align" "center"
                    , style "white-space" "nowrap"
                    , style "opacity" counterOpacity
                    , style "transition" "top 0.6s ease, font-size 0.6s ease, opacity 0.8s ease, transform 0.6s ease"
                    , style "z-index" "10"
                    ]
                    [ text counterText ]
                , p
                    [ style "position" "fixed"
                    , style "top" "50%"
                    , style "left" "50%"
                    , style "transform" "translate(-50%, -50%)"
                    , style "font-size" "28px"
                    , style "color" "#2c4a5a"
                    , style "margin" "0"
                    , style "text-align" "center"
                    , style "max-width" "600px"
                    , style "line-height" "1.5"
                    , style "opacity" text1Opacity
                    , style "transition" "opacity 0.8s ease"
                    ]
                    [ text "You pressed the space bar because you saw a green flash." ]
                , p
                    [ style "position" "fixed"
                    , style "top" "50%"
                    , style "left" "50%"
                    , style "transform" "translate(-50%, -50%)"
                    , style "font-size" "28px"
                    , style "color" "#2c4a5a"
                    , style "margin" "0"
                    , style "text-align" "center"
                    , style "max-width" "600px"
                    , style "line-height" "1.5"
                    , style "opacity" text2Opacity
                    , style "transition" text2Transition
                    ]
                    [ text "But there was no ding..." ]
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
                    [ text "Text \"creeper... awwww man\" to Max to claim your reward!" ]
                ]

        TimedOutScreen ->
            screen
                [ p
                    [ style "font-size" "42px"
                    , style "color" "#c0392b"
                    , style "text-align" "center"
                    , style "margin" "0"
                    , style "font-weight" "bold"
                    ]
                    [ text "You ran out of time." ]
                ]

        CheckingAnswerScreen _ ->
            screen
                [ p
                    [ style "font-size" "32px"
                    , style "color" "#2c4a5a"
                    , style "text-align" "center"
                    , style "margin" "0"
                    ]
                    [ text "Checking..." ]
                ]

        ConfirmingAnswerScreen _ ->
            screen
                [ p
                    [ style "font-size" "32px"
                    , style "color" "#2c4a5a"
                    , style "text-align" "center"
                    , style "margin" "0"
                    ]
                    [ text "Checking..." ]
                ]


spaceBarDecoder : Decoder Msg
spaceBarDecoder =
    Decode.field "key" Decode.string
        |> Decode.andThen
            (\key ->
                if key == " " then
                    Decode.succeed SpaceBarPressed

                else
                    Decode.fail "not space"
            )
