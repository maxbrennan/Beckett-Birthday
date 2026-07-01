module Audio exposing (..)

import Game.IQTest exposing (..)
import Game.Quiz exposing (..)
import Html exposing (Html, audio, div, text)
import Html.Attributes exposing (autoplay, id, loop, src)
import Html.Events exposing (on)
import Html.Keyed
import Json.Decode as Decode
import Json.Encode as Encode
import Types exposing (..)


currentQuizSong : Model -> Maybe String
currentQuizSong model =
    case model.screen of
        BlankScreen idx ->
            getQuestion model.questions idx
                |> Maybe.andThen
                    (\q ->
                        if isVideo q.song then
                            Nothing

                        else if hasPendingPlaySong idx model.pending then
                            Nothing

                        else
                            Just q.song
                    )

        _ ->
            Nothing


hasPendingPlaySong : Int -> List PendingEvent -> Bool
hasPendingPlaySong idx pending =
    List.any
        (\e ->
            case e.msg of
                PlaySong i ->
                    i == idx

                _ ->
                    False
        )
        pending


viewAudio : Model -> Html Msg
viewAudio model =
    let
        jeopardyAudio =
            if model.jeopardyPlaying then
                audio
                    [ id "jeopardy-audio"
                    , src "assets/jeopardy-theme.mp3"
                    , autoplay True
                    , loop True
                    ]
                    []

            else
                text ""

        quizAudio =
            case currentQuizSong model of
                Just songSrc ->
                    audio
                        [ id "quiz-audio"
                        , src ("assets/" ++ songSrc)
                        , autoplay True
                        , on "loadedmetadata" (Decode.succeed SongMetadataLoaded)
                        , on "ended" (Decode.succeed (TrackEnded songSrc))
                        ]
                        []

                Nothing ->
                    text ""

        dingAudio =
            Html.Keyed.node "div"
                []
                (List.range 0 (dingSlotCount - 1)
                    |> List.filterMap
                        (\s ->
                            let
                                lastTrigger =
                                    lastTriggerForSlot s model.dingKey
                            in
                            if lastTrigger == 0 then
                                Nothing

                            else
                                Just
                                    ( "ding-slot-" ++ String.fromInt s ++ "-" ++ String.fromInt lastTrigger
                                    , audio
                                        [ id ("ding-audio-" ++ String.fromInt s)
                                        , src "assets/ding.mp3"
                                        , autoplay True
                                        , Html.Attributes.property "volume" (Encode.float iqDingVolume)
                                        ]
                                        []
                                    )
                        )
                )
    in
    div [] [ jeopardyAudio, quizAudio, dingAudio ]
