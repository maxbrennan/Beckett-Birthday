port module Main exposing (main)

import Browser
import Browser.Events
import Char
import Html exposing (Html, button, div, img, input, p, text)
import Html.Attributes exposing (placeholder, src, style, type_, value)
import Html.Events exposing (onClick, onInput)
import Json.Decode as Decode exposing (Decoder)
import Random
import Task
import Time


port receiveDevices : (String -> msg) -> Sub msg

port playMusic : String -> Cmd msg

port playVideo : { filename : String, loop : Bool } -> Cmd msg

port stopMusic : String -> Cmd msg

port receiveTrackInfo : ({ name : String, currentTime : Float, duration : Float } -> msg) -> Sub msg

port trackEnded : (String -> msg) -> Sub msg

port playDing : Float -> Cmd msg

port showFlash : Bool -> Cmd msg

port musicError : (String -> msg) -> Sub msg


-- Set to True to enable debug mode (smaller counts, faster delays, no AirPods required).
debug : Bool
debug =
    True


-- Total correct ding presses required to pass the IQ test.
-- Debug: 10  |  Production: 100
iqQuestionCount : Int
iqQuestionCount =
    if debug then
        10

    else
        100


-- Lower bound (as a fraction of iqQuestionCount) for the fake-flash trap position.
-- Debug: 0.65  |  Production: 0.85
fakeFlashRangeLo : Float
fakeFlashRangeLo =
    if debug then
        0.65

    else
        0.85


-- Upper bound (as a fraction of iqQuestionCount) for the fake-flash trap position.
-- Debug: 0.75  |  Production: 0.95
fakeFlashRangeHi : Float
fakeFlashRangeHi =
    if debug then
        0.75

    else
        0.95


-- Minimum milliseconds between successive dings.
-- Debug: 100  |  Production: 2000
minDingDelay : Float
minDingDelay =
    if debug then
        100

    else
        2000


-- Maximum milliseconds between successive dings.
-- Debug: 500  |  Production: 15000
maxDingDelay : Float
maxDingDelay =
    if debug then
        500

    else
        15000


-- Duration (ms) of the green flash visual.
iqFlashDuration : Float
iqFlashDuration =
    250


-- Duration (ms) of the window in which a space-bar press counts as a ding response.
iqWindowDuration : Float
iqWindowDuration =
    1000


-- Volume (0–1) for the ding sound effect.
iqDingVolume : Float
iqDingVolume =
    0.8


-- Milliseconds per tick for the counter animation on the fake-flash penalty screen.
counterTickMs : Float
counterTickMs =
    80


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
    , { song = "dracula.mp3", answers = [ "dracula" ] }
    , { song = "borderline.mp3", answers = [ "borderline" ] }
    , { song = "cant-stop.mp3", answers = [ "cant stop" ] }
    , { song = "korean.mp3", answers = [ "천 번 차이는 남자" ] }
    ]


getQuestion : Int -> Maybe Question
getQuestion idx =
    List.head (List.drop idx questions)


normalize : String -> String
normalize s =
    s
        |> String.toLower
        |> String.filter (\c -> Char.isAlpha c || c == ' ')
        |> String.words
        |> String.join " "


capitalize : String -> String
capitalize s =
    case String.uncons s of
        Just ( first, rest ) ->
            String.fromChar (Char.toUpper first) ++ rest

        Nothing ->
            s


isVideo : String -> Bool
isVideo filename =
    String.endsWith ".mp4" filename


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


type alias DingSchedule =
    { delay : Float, nextRandom : Bool }


type alias IQTestInit =
    { delay : Float, nextRandom : Bool, fakeFlashPoint : Int }


type alias IQTestScreenState =
    { questionIdx : Int
    , totalDings : Int
    , fakeFlashUsed : Bool
    , in50PercentPhase : Bool
    }


-- State for the countdown shown between pressing "Begin" and the test starting.
type alias IQTestCountdownState =
    { questionIdx : Int
    , totalDings : Int
    , fakeFlashUsed : Bool
    , in50PercentPhase : Bool
    , countdown : Int
    , initData : IQTestInit
    }


type alias IQTestState =
    { questionIdx : Int
    , dingCount : Int
    , totalDings : Int
    , isFlashing : Bool
    , dingActive : Bool
    , fakeFlashActive : Bool
    , loudPlaying : Bool
    , fakeFlashUsed : Bool
    , fakeFlashPoint : Int
    , nextRandom : Bool
    , in50PercentPhase : Bool
    }


type FakeFlashPhase
    = FfDelay
    | FfText1In
    | FfText1Hold
    | FfText1Out
    | FfText2In
    | FfText2Hold
    | FfText2Out
    | FfCounterIn
    | FfTickNumerator
    | FfTickDelay
    | FfTickDenominator
    | FfCounterOut


type alias FakeFlashCaughtState =
    { questionIdx : Int
    , originalTotal : Int
    , displayNumerator : Int
    , displayDenominator : Int
    , phase : FakeFlashPhase
    }


type Screen
    = ConnectScreen
    | BeginScreen
    | BlankScreen Int
    | QuestionScreen Int String
    | WrongAnswerScreen Int
    | IQTestScreen IQTestScreenState
    | IQTestCountdownScreen IQTestCountdownState
    | IQTestActiveScreen IQTestState
    | FakeFlashCaughtScreen FakeFlashCaughtState
    | WinScreen


-- A message scheduled to fire at an absolute timestamp (ms since Unix epoch).
type alias PendingEvent =
    { fireAt : Float
    , msg : Msg
    }


type alias Model =
    { connected : Bool
    , screen : Screen
    , trackInfo : Maybe TrackInfo
    , jeopardyPlaying : Bool
    , now : Float
    , pending : List PendingEvent
    }


type Msg
    = Tick Float
    | DevicesReceived String
    | BeginPressed
    | PlaySong Int
    | TrackEnded String
    | ShowQuestion Int
    | TrackInfoReceived TrackInfo
    | MusicError String
    | AnswerChanged String
    | AnswerSubmitted
    | ContinuePressed
    | IQTestBeginPressed
    | IQTestStarted IQTestInit
    | CountdownTick
    | DingOccurred
    | DingFlashEnd
    | DingWindowExpired
    | SpaceBarPressed
    | ScheduleNextDing DingSchedule
    | StartLoudMusic
    | FakeFlashNextPhase
    | FakeFlashCounterTick
    | FakeFlashWindowExpired


init : () -> ( Model, Cmd Msg )
init _ =
    ( { connected = False
      , screen = ConnectScreen
      , trackInfo = Nothing
      , jeopardyPlaying = True
      , now = 0
      , pending = []
      }
    , Cmd.batch
        [ playMusic "jeopardy-theme.mp3"
        , Task.perform (\posix -> Tick (toFloat (Time.posixToMillis posix))) Time.now
        ]
    )


-- Queue a message to fire `delay` ms from now.
schedule : Float -> Msg -> Model -> Model
schedule delay msg model =
    { model | pending = { fireAt = model.now + delay, msg = msg } :: model.pending }


-- Drop all pending events (use on major screen transitions to avoid stale firings).
clearPending : Model -> Model
clearPending model =
    { model | pending = [] }


dingScheduleGen : Random.Generator DingSchedule
dingScheduleGen =
    Random.map2 (\d r -> { delay = d, nextRandom = r })
        (Random.float minDingDelay maxDingDelay)
        (Random.map (\n -> n < 0.5) (Random.float 0 1))


iqTestInitGen : Int -> Random.Generator IQTestInit
iqTestInitGen total =
    let
        lo =
            Basics.max 0 (floor (fakeFlashRangeLo * toFloat total))

        hi =
            Basics.max lo (Basics.min (total - 1) (floor (fakeFlashRangeHi * toFloat total)))
    in
    Random.map3 (\d r fp -> { delay = d, nextRandom = r, fakeFlashPoint = fp })
        (Random.float minDingDelay maxDingDelay)
        (Random.map (\n -> n < 0.5) (Random.float 0 1))
        (Random.int lo hi)


iqFail : Model -> IQTestState -> ( Model, Cmd Msg )
iqFail model state =
    ( clearPending
        { model
            | screen =
                IQTestScreen
                    { questionIdx = state.questionIdx
                    , totalDings = state.totalDings
                    , fakeFlashUsed = state.fakeFlashUsed
                    , in50PercentPhase = state.in50PercentPhase
                    }
        }
    , if state.loudPlaying then stopMusic "loud.mp4" else Cmd.none
    )


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        -- Advance the clock. Fire any events whose fireAt has passed.
        -- The first Tick (model.now == 0) just initialises the clock without firing.
        Tick t ->
            if model.now == 0 then
                ( { model | now = t }, Cmd.none )

            else
                let
                    ( due, stillPending ) =
                        List.partition (\e -> e.fireAt <= t) model.pending

                    baseModel =
                        { model | now = t, pending = stillPending }
                in
                List.foldl
                    (\event ( m, cmd ) ->
                        let
                            ( m2, cmd2 ) =
                                update event.msg m
                        in
                        ( m2, Cmd.batch [ cmd, cmd2 ] )
                    )
                    ( baseModel, Cmd.none )
                    due

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

                            WrongAnswerScreen _ ->
                                True

                            IQTestScreen _ ->
                                True

                            IQTestCountdownScreen _ ->
                                True

                            IQTestActiveScreen _ ->
                                True

                            FakeFlashCaughtScreen _ ->
                                True

                            _ ->
                                False

                    stopLoop =
                        case model.screen of
                            IQTestActiveScreen state ->
                                state.loudPlaying

                            _ ->
                                False
                in
                ( clearPending { model | connected = False, screen = ConnectScreen, jeopardyPlaying = model.jeopardyPlaying || needsJeopardy }
                , Cmd.batch
                    [ if needsJeopardy then playMusic "jeopardy-theme.mp3" else Cmd.none
                    , if stopLoop then stopMusic "loud.mp4" else Cmd.none
                    ]
                )

        BeginPressed ->
            ( { model | screen = BlankScreen 0, jeopardyPlaying = False }
                |> clearPending
                |> schedule 1000 (PlaySong 0)
            , stopMusic "jeopardy-theme.mp3"
            )

        PlaySong idx ->
            case model.screen of
                BlankScreen blankIdx ->
                    if blankIdx == idx then
                        case getQuestion idx of
                            Just q ->
                                ( model
                                , if isVideo q.song then
                                    playVideo { filename = q.song, loop = False }

                                  else
                                    playMusic q.song
                                )

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
                                    ( schedule 1000 (ShowQuestion idx) model, Cmd.none )

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
                            if List.any (\a -> normalize answer == normalize a) q.answers then
                                let
                                    nextIdx =
                                        idx + 1
                                in
                                case getQuestion nextIdx of
                                    Just _ ->
                                        ( { model | screen = BlankScreen nextIdx }
                                            |> clearPending
                                            |> schedule 1000 (PlaySong nextIdx)
                                        , Cmd.none
                                        )

                                    Nothing ->
                                        ( clearPending { model | screen = WinScreen }, Cmd.none )

                            else
                                ( { model | screen = WrongAnswerScreen idx }, Cmd.none )

                        Nothing ->
                            ( model, Cmd.none )

                _ ->
                    ( model, Cmd.none )

        ContinuePressed ->
            case model.screen of
                WrongAnswerScreen idx ->
                    ( clearPending
                        { model
                            | screen =
                                IQTestScreen
                                    { questionIdx = idx
                                    , totalDings = iqQuestionCount
                                    , fakeFlashUsed = False
                                    , in50PercentPhase = False
                                    }
                        }
                    , Cmd.none
                    )

                _ ->
                    ( model, Cmd.none )

        IQTestBeginPressed ->
            case model.screen of
                IQTestScreen iqScreen ->
                    ( model
                    , Random.generate IQTestStarted (iqTestInitGen iqScreen.totalDings)
                    )

                _ ->
                    ( model, Cmd.none )

        IQTestStarted initData ->
            case model.screen of
                IQTestScreen iqScreen ->
                    ( { model
                        | screen =
                            IQTestCountdownScreen
                                { questionIdx = iqScreen.questionIdx
                                , totalDings = iqScreen.totalDings
                                , fakeFlashUsed = iqScreen.fakeFlashUsed
                                , in50PercentPhase = iqScreen.in50PercentPhase
                                , countdown = iqScreen.totalDings
                                , initData = initData
                                }
                      }
                        |> schedule 1000 CountdownTick
                    , Cmd.none
                    )

                _ ->
                    ( model, Cmd.none )

        CountdownTick ->
            case model.screen of
                IQTestCountdownScreen state ->
                    if state.countdown > 1 then
                        ( { model | screen = IQTestCountdownScreen { state | countdown = state.countdown - 1 } }
                            |> schedule 1000 CountdownTick
                        , Cmd.none
                        )

                    else
                        let
                            { delay, nextRandom, fakeFlashPoint } =
                                state.initData
                        in
                        ( clearPending
                            { model
                                | screen =
                                    IQTestActiveScreen
                                        { questionIdx = state.questionIdx
                                        , dingCount = 0
                                        , totalDings = state.totalDings
                                        , isFlashing = False
                                        , dingActive = False
                                        , fakeFlashActive = False
                                        , loudPlaying = False
                                        , fakeFlashUsed = state.fakeFlashUsed
                                        , fakeFlashPoint = fakeFlashPoint
                                        , nextRandom = nextRandom
                                        , in50PercentPhase = state.in50PercentPhase
                                        }
                            }
                            |> schedule delay DingOccurred
                        , Cmd.none
                        )

                _ ->
                    ( model, Cmd.none )

        ScheduleNextDing { delay, nextRandom } ->
            case model.screen of
                IQTestActiveScreen state ->
                    ( { model | screen = IQTestActiveScreen { state | nextRandom = nextRandom } }
                        |> schedule delay DingOccurred
                    , Cmd.none
                    )

                _ ->
                    ( model, Cmd.none )

        DingOccurred ->
            case model.screen of
                IQTestActiveScreen state ->
                    let
                        isFakeFlashPoint =
                            not state.fakeFlashUsed
                                && not state.in50PercentPhase
                                && state.dingCount == state.fakeFlashPoint

                        isFake =
                            isFakeFlashPoint || (state.in50PercentPhase && state.nextRandom)
                    in
                    if isFake then
                        ( { model | screen = IQTestActiveScreen { state | isFlashing = True, fakeFlashActive = True } }
                            |> schedule iqFlashDuration DingFlashEnd
                            |> schedule iqWindowDuration FakeFlashWindowExpired
                        , showFlash True
                        )

                    else
                        ( { model | screen = IQTestActiveScreen { state | isFlashing = True, dingActive = True } }
                            |> schedule iqFlashDuration DingFlashEnd
                            |> schedule iqWindowDuration DingWindowExpired
                        , Cmd.batch [ playDing iqDingVolume, showFlash True ]
                        )

                _ ->
                    ( model, Cmd.none )

        DingFlashEnd ->
            case model.screen of
                IQTestActiveScreen state ->
                    ( { model | screen = IQTestActiveScreen { state | isFlashing = False } }, showFlash False )

                _ ->
                    ( model, Cmd.none )

        DingWindowExpired ->
            case model.screen of
                IQTestActiveScreen state ->
                    if state.dingActive then
                        iqFail model state

                    else
                        ( model, Cmd.none )

                _ ->
                    ( model, Cmd.none )

        FakeFlashWindowExpired ->
            case model.screen of
                IQTestActiveScreen state ->
                    if state.fakeFlashActive then
                        ( { model | screen = IQTestActiveScreen { state | fakeFlashActive = False, fakeFlashUsed = True } }
                        , Random.generate ScheduleNextDing dingScheduleGen
                        )

                    else
                        ( model, Cmd.none )

                _ ->
                    ( model, Cmd.none )

        SpaceBarPressed ->
            case model.screen of
                IQTestActiveScreen state ->
                    if state.fakeFlashActive then
                        if not state.fakeFlashUsed then
                            ( clearPending
                                { model
                                    | screen =
                                        FakeFlashCaughtScreen
                                            { questionIdx = state.questionIdx
                                            , originalTotal = state.totalDings
                                            , displayNumerator = state.dingCount
                                            , displayDenominator = state.totalDings
                                            , phase = FfDelay
                                            }
                                }
                                |> schedule 1000 FakeFlashNextPhase
                            , Cmd.batch
                                [ if state.loudPlaying then stopMusic "loud.mp4" else Cmd.none
                                , showFlash False
                                ]
                            )

                        else
                            let
                                ( newModel, cmd ) =
                                    iqFail model state
                            in
                            ( newModel, Cmd.batch [ cmd, showFlash False ] )

                    else if state.dingActive then
                        let
                            stillPunished =
                                state.totalDings > iqQuestionCount

                            newDingCount =
                                if stillPunished then state.dingCount else state.dingCount + 1

                            newTotalDings =
                                if stillPunished then state.totalDings - 1 else state.totalDings

                            newIn50Percent =
                                state.in50PercentPhase || (stillPunished && newTotalDings == iqQuestionCount)

                            completed =
                                not stillPunished && newDingCount >= state.totalDings

                            -- Trigger the loud loop on the 4th legitimate ding (only once per session).
                            triggerLoud =
                                not stillPunished && not state.loudPlaying && newDingCount == 4

                            nextIdx =
                                state.questionIdx + 1
                        in
                        if completed then
                            ( clearPending { model | screen = BlankScreen nextIdx }
                                |> schedule 1000 (PlaySong nextIdx)
                            , if state.loudPlaying then stopMusic "loud.mp4" else Cmd.none
                            )

                        else
                            let
                                newState =
                                    { state
                                        | dingCount = newDingCount
                                        , totalDings = newTotalDings
                                        , dingActive = False
                                        , in50PercentPhase = newIn50Percent
                                    }

                                newModel =
                                    if triggerLoud then
                                        { model | screen = IQTestActiveScreen newState }
                                            |> schedule 3000 StartLoudMusic

                                    else
                                        { model | screen = IQTestActiveScreen newState }
                            in
                            ( newModel
                            , Random.generate ScheduleNextDing dingScheduleGen
                            )

                    else
                        iqFail model state

                _ ->
                    ( model, Cmd.none )

        StartLoudMusic ->
            case model.screen of
                IQTestActiveScreen state ->
                    ( { model | screen = IQTestActiveScreen { state | loudPlaying = True } }
                    , playVideo { filename = "loud.mp4", loop = True }
                    )

                _ ->
                    ( model, Cmd.none )

        FakeFlashNextPhase ->
            case model.screen of
                FakeFlashCaughtScreen state ->
                    let
                        advance newPhase delay =
                            ( { model | screen = FakeFlashCaughtScreen { state | phase = newPhase } }
                                |> schedule delay FakeFlashNextPhase
                            , Cmd.none
                            )
                    in
                    case state.phase of
                        FfDelay ->
                            advance FfText1In 1000

                        FfText1In ->
                            advance FfText1Hold 2500

                        FfText1Hold ->
                            advance FfText1Out 1000

                        FfText1Out ->
                            advance FfText2In 800

                        FfText2In ->
                            advance FfText2Hold 2500

                        FfText2Hold ->
                            advance FfText2Out 1000

                        FfText2Out ->
                            advance FfCounterIn 700

                        FfCounterIn ->
                            ( { model | screen = FakeFlashCaughtScreen { state | phase = FfTickNumerator } }
                                |> schedule counterTickMs FakeFlashCounterTick
                            , Cmd.none
                            )

                        FfTickDelay ->
                            ( { model | screen = FakeFlashCaughtScreen { state | phase = FfTickDenominator } }
                                |> schedule counterTickMs FakeFlashCounterTick
                            , Cmd.none
                            )

                        FfCounterOut ->
                            ( clearPending
                                { model
                                    | screen =
                                        IQTestScreen
                                            { questionIdx = state.questionIdx
                                            , totalDings = state.originalTotal * 2
                                            , fakeFlashUsed = True
                                            , in50PercentPhase = False
                                            }
                                }
                            , Cmd.none
                            )

                        _ ->
                            ( model, Cmd.none )

                _ ->
                    ( model, Cmd.none )

        FakeFlashCounterTick ->
            case model.screen of
                FakeFlashCaughtScreen state ->
                    case state.phase of
                        FfTickNumerator ->
                            if state.displayNumerator > 0 then
                                ( { model | screen = FakeFlashCaughtScreen { state | displayNumerator = state.displayNumerator - 1 } }
                                    |> schedule counterTickMs FakeFlashCounterTick
                                , playDing 0.15
                                )

                            else
                                ( { model | screen = FakeFlashCaughtScreen { state | phase = FfTickDelay } }
                                    |> schedule 500 FakeFlashNextPhase
                                , Cmd.none
                                )

                        FfTickDenominator ->
                            let
                                target =
                                    state.originalTotal * 2
                            in
                            if state.displayDenominator < target then
                                ( { model | screen = FakeFlashCaughtScreen { state | displayDenominator = state.displayDenominator + 1 } }
                                    |> schedule counterTickMs FakeFlashCounterTick
                                , playDing 0.3
                                )

                            else
                                ( { model | screen = FakeFlashCaughtScreen { state | phase = FfCounterOut } }
                                    |> schedule 1500 FakeFlashNextPhase
                                , Cmd.none
                                )

                        _ ->
                            ( model, Cmd.none )

                _ ->
                    ( model, Cmd.none )


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


isCounterBig : FakeFlashPhase -> Bool
isCounterBig phase =
    case phase of
        FfCounterIn ->
            True

        FfTickNumerator ->
            True

        FfTickDelay ->
            True

        FfTickDenominator ->
            True

        FfCounterOut ->
            True

        _ ->
            False


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
            screenBg bg []

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
                    if state.isFlashing then
                        "#00cc44"

                    else if state.loudPlaying then
                        "transparent"

                    else
                        "#a8c8e0"

                counter =
                    String.fromInt state.dingCount ++ " / " ++ String.fromInt state.totalDings
            in
            div []
                [ p
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
                    , style "transition" "opacity 0.8s ease"
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
                    [ text "You Win!" ]
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


subscriptions : Model -> Sub Msg
subscriptions model =
    let
        keyboardSub =
            case model.screen of
                IQTestActiveScreen _ ->
                    Browser.Events.onKeyDown spaceBarDecoder

                _ ->
                    Sub.none
    in
    Sub.batch
        [ receiveDevices DevicesReceived
        , receiveTrackInfo TrackInfoReceived
        , trackEnded TrackEnded
        , musicError MusicError
        , keyboardSub
        , Browser.Events.onAnimationFrame (\posix -> Tick (toFloat (Time.posixToMillis posix)))
        ]


main : Program () Model Msg
main =
    Browser.element
        { init = init
        , update = update
        , view = view
        , subscriptions = subscriptions
        }
