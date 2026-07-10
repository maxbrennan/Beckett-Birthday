module Audio exposing (..)

import Game.Quiz exposing (..)
import Types exposing (..)


currentQuizSong : Model -> Maybe String
currentQuizSong model =
    case model.screen of
        BlankScreen idx ->
            getQuestion model.questions idx
                |> Maybe.andThen
                    (\song ->
                        if isVideo song then
                            Nothing

                        else if hasPendingPlaySong idx model.pending then
                            Nothing

                        else
                            Just song
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
