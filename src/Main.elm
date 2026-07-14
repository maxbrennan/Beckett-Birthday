port module Main exposing (..)

import Audio exposing (..)
import Browser
import Browser.Dom
import Browser.Events
import Game.IQTest exposing (..)
import Game.Quiz exposing (..)
import Html exposing (Html, audio, button, div, img, input, p, text, video)
import Html.Attributes exposing (autoplay, id, loop, placeholder, property, src, style, type_, value)
import Html.Events exposing (on, onClick, onInput)
import Html.Keyed
import Json.Decode as Decode exposing (Decoder)
import Json.Encode as Encode
import Sync exposing (..)
import Task
import Time
import Types exposing (..)
import View exposing (..)


port pauseMusic : String -> Cmd msg

port setDomProperty : { elementId : String, property : String, value : Encode.Value } -> Cmd msg

port domPropertyError : (String -> msg) -> Sub msg

port getDomProperty : { elementId : String, property : String } -> Cmd msg

port receiveDomProperty : ({ elementId : String, property : String, value : Decode.Value } -> msg) -> Sub msg

port logToFile : String -> Cmd msg

port initWebSocketClient : String -> Cmd msg

port wsClientReady : (String -> msg) -> Sub msg

port sendToWs : { wsId : String, data : String } -> Cmd msg

port receiveFromWs : (String -> msg) -> Sub msg

port wsClientFailed : (String -> msg) -> Sub msg

port readFile : String -> Cmd msg

port readFileResult : ({ path : String, contents : Maybe String, error : Maybe String } -> msg) -> Sub msg

-- Lists assets/songs/ directly -- the client no longer reads any config/ JSON for
-- the quiz (see #54, #70's review); song order comes from the numeric filename
-- convention alone (see Game.Quiz.songOrder).
port readDir : String -> Cmd msg

port readDirResult : ({ path : String, files : List String, error : Maybe String } -> msg) -> Sub msg

-- Mirrors Server.elm's writeFile/writeFileResult port shape (same record fields),
-- but under a different name -- used only for the local offer-grant cache (see
-- offerGrantCachePath), a pure rendering accelerator, not authoritative state.
-- Named distinctly from Server.elm's own writeFile/writeFileResult (not just for
-- clarity: elm-test compiles every test module into one combined program, and
-- unlike readFile/readFileResult -- which only ever fire from inside init, so
-- only one of Main's/Server's survives dead-code elimination when a test run
-- exercises just one of the two -- this port is called directly by
-- writeOfferGrantCache/clearOfferGrantCache below, which MainTest.elm unit-tests
-- outside of init; reusing Server.elm's exact port name here would make both
-- same-named ports genuinely reachable at once and crash at runtime ("There can
-- only be one port named `writeFile`"), the same category of hazard already
-- documented for readFile in CLAUDE.md's test-coverage-conventions section.
-- writeCacheFileResult is deliberately not subscribed to: a failed write just
-- means the next launch falls back to the normal (slightly slower) server round
-- trip, nothing to react to.
port writeCacheFile : { path : String, contents : String, encoding : String, append : Bool } -> Cmd msg

port writeCacheFileResult : ({ path : String, ok : Bool, error : Maybe String } -> msg) -> Sub msg


-- Local on-disk cache of an outstanding IQ-test skip-offer grant (see
-- Game.IQTest.CachedOfferGrant's doc comment) -- read at launch (init below)
-- and kept in sync by every write/clear trigger in `update` (search for this
-- constant).
offerGrantCachePath : String
offerGrantCachePath =
    "iq-offer-grant.json"


init : String -> ( Model, Cmd Msg )
init wsUrl =
    ( { screen = WsConnectingScreen
      , now = 0
      , pending = []
      , dingKey = 0
      , wsClientId = Nothing
      , timerEndsAt = 0
      , myUuid = Nothing
      , wsUrl = wsUrl
      , questions = []
      , awaitingAnswerResult = False
      , songTimerElapsed = False
      , songEndAcked = False
      }
    , Cmd.batch
        [ readFile "app-uuid.json"
        , readFile offerGrantCachePath
        , readDir "assets/songs"
        , Task.perform tickFromPosix Time.now
        ]
    )


writeOfferGrantCache : CachedOfferGrant -> Cmd Msg
writeOfferGrantCache grant =
    writeCacheFile
        { path = offerGrantCachePath
        , contents = Encode.encode 0 (encodeCachedOfferGrant grant)
        , encoding = "utf8"
        , append = False
        }


clearOfferGrantCache : Cmd Msg
clearOfferGrantCache =
    writeCacheFile
        { path = offerGrantCachePath
        , contents = "null"
        , encoding = "utf8"
        , append = False
        }


-- Keeps the local offer-grant cache in sync with a bare (unwrapped) Screen that
-- may or may not carry a pending offer -- called both right after a live
-- ServerIqOfferDecision (see its handler) and, unwrapped from BeginScreen, after
-- every ServerStateUpdate (see applyServerStateUpdate) so a reconnect that finds
-- a different grant state than what was last cached corrects it.
offerGrantCacheSyncCmd : Screen -> Cmd Msg
offerGrantCacheSyncCmd scr =
    case scr of
        IQTestScreen s ->
            case s.pendingSkipOffer of
                Just totalDings ->
                    writeOfferGrantCache
                        { questionIdx = s.questionIdx
                        , totalDings = totalDings
                        , trigger = FailTrigger
                        , offerIsLastChance = s.offerIsLastChance
                        }

                Nothing ->
                    clearOfferGrantCache

        FakeFlashCaughtScreen s ->
            case s.skipOffer of
                Just totalDings ->
                    writeOfferGrantCache
                        { questionIdx = s.questionIdx
                        , totalDings = totalDings
                        , trigger = CatchTrigger
                        , offerIsLastChance = s.offerIsLastChance
                        }

                Nothing ->
                    clearOfferGrantCache

        _ ->
            Cmd.none


-- Decodes a ServerStateUpdate's inner JSON and merges it into the live Model,
-- carrying forward session/connection-local fields decodeModel can't know (see
-- inline comment below) -- shared by both valid states WsDataReceived accepts a
-- ServerStateUpdate from (WsLoadingScreen, and a still-showing optimistic
-- BeginScreen guess from the local cache -- see WsClientReady's guard). Also
-- syncs the local offer-grant cache to whatever the authoritative reply says,
-- so a stale/wrong optimistic guess (or one that's simply gone stale since it
-- was last written) is corrected going forward too.
applyServerStateUpdate : Model -> String -> ( Model, Cmd Msg )
applyServerStateUpdate model inner =
    case Decode.decodeString decodeModel inner of
        Ok newModel ->
            let
                merged =
                    { newModel
                        | wsClientId = model.wsClientId
                        , myUuid = model.myUuid
                        , wsUrl = model.wsUrl
                        , questions = model.questions
                        , timerEndsAt = model.timerEndsAt
                    }

                cacheCmd =
                    case merged.screen of
                        BeginScreen unwrapped ->
                            offerGrantCacheSyncCmd unwrapped

                        _ ->
                            Cmd.none
            in
            ( merged, cacheCmd )

        Err _ ->
            ( model, Cmd.none )


-- Converts an animation-frame/Time.now Posix into the Tick Msg it drives.
tickFromPosix : Time.Posix -> Msg
tickFromPosix posix =
    Tick (toFloat (Time.posixToMillis posix))


-- Queue a message to fire `delay` ms from now.
schedule : Float -> Msg -> Model -> Model
schedule delay msg model =
    { model | pending = { fireAt = model.now + delay, msg = msg } :: model.pending }


-- Same as `schedule 3000 WsReconnect`, but first drops any WsReconnect already queued.
-- Without this, a burst of disconnects while the server is unreachable (a real client
-- can see several in quick succession, e.g. from both the socket's error and close
-- events firing for the same failure) queues one WsReconnect per disconnect, all with
-- nearly the same fireAt — when the server comes back, every one of them fires in the
-- same Tick and each independently reopens a socket, flooding the server with duplicate
-- connections for the same uuid (all but one correctly rejected, but the client can
-- spend a long time cycling through the pile-up before it settles).
scheduleReconnect : Model -> Model
scheduleReconnect model =
    { model | pending = { fireAt = model.now + 3000, msg = WsReconnect } :: List.filter (\e -> e.msg /= WsReconnect) model.pending }


-- Drop all pending events (use on major screen transitions to avoid stale firings).
clearPending : Model -> Model
clearPending model =
    { model | pending = [] }


-- Send a payload to the server over the WebSocket, if connected.
sendWs : Model -> Encode.Value -> Cmd Msg
sendWs model payload =
    case model.wsClientId of
        Just wsId ->
            sendToWs { wsId = wsId, data = Encode.encode 0 payload }

        Nothing ->
            Cmd.none


-- After restoring a saved screen on reconnect, tell the server we're back so it
-- can re-arm whatever IQ timer it paused on disconnect (see Server.elm's
-- resumeIqTimer). Harmless to send for FakeFlashCaughtScreen too -- the server
-- has nothing scheduled for that phase, so it's just a no-op there.
--
-- A saved QuestionScreen resumes directly onto the answer input (see
-- BeginPressed below) -- the song never replays, so TrackEnded never fires to
-- re-report it. Without re-sending quizSongEnded here, the server's tracked
-- confirmation for this idx (cleared on every connect, and lost on a server
-- restart regardless -- see Model.quizSongEnded) would never be re-established,
-- and ClientQuizAnswerSubmitted's gate would block the answer forever.
resumeCmd : Model -> Screen -> Cmd Msg
resumeCmd model screen =
    case screen of
        IQTestCountdownScreen _ ->
            sendWs model iqResumeEnvelope

        IQTestActiveScreen _ ->
            sendWs model iqResumeEnvelope

        FakeFlashCaughtScreen _ ->
            sendWs model iqResumeEnvelope

        QuestionScreen idx _ ->
            sendWs model (quizSongEndedEnvelope idx)

        _ ->
            Cmd.none



-- A qualifying fail just happened (DingWindowExpired timeout, or a SpaceBarPressed
-- miss). Unlike the old client-only decision, the screen doesn't transition yet --
-- the server now decides whether this grants the one-time skip offer (see
-- Server.elm's decideIqOffer), and Main.elm's ServerIqOfferDecision handling is what
-- actually moves off IQTestActiveScreen once that reply arrives. Meanwhile just
-- freeze the active flags so nothing looks "live" while waiting.
iqFail : Model -> IQTestState -> ( Model, Cmd Msg )
iqFail model state =
    ( clearPending
        { model | screen = IQTestActiveScreen { state | isFlashing = False, dingActive = False, fakeFlashActive = False } }
    , sendWs model iqFailedEnvelope
    )


-- Unwraps a BlankScreen index through the CheckingAnswerScreen/ConfirmingAnswerScreen
-- wrappers a screen may be paused/synced under.
innerBlankIdx : Screen -> Maybe Int
innerBlankIdx s =
    case s of
        BlankScreen i ->
            Just i

        CheckingAnswerScreen inner ->
            innerBlankIdx inner

        ConfirmingAnswerScreen inner ->
            innerBlankIdx inner

        _ ->
            Nothing


-- Which BlankScreen index (if any) a TrackEnded event should advance to.
-- VideoScreen always advances (its own end already gates on the right video);
-- BlankScreen only advances if the reported track matches the song scheduled
-- for that question, rejecting a stale TrackEnded left over from a transition.
trackEndedTarget : List String -> Screen -> String -> Maybe Int
trackEndedTarget questions screen name =
    case screen of
        BlankScreen idx ->
            case getQuestion questions idx of
                Just song ->
                    if song == name then
                        Just idx

                    else
                        Nothing

                Nothing ->
                    Nothing

        VideoScreen idx _ ->
            Just idx

        _ ->
            Nothing


-- Actually reveals the answer input for idx, once both the local pause and
-- the server's song-ended ack have each independently arrived (see
-- ShowQuestion / the ServerQuizSongEndedAck case below).
revealQuestion : Int -> Model -> ( Model, Cmd Msg )
revealQuestion idx model =
    ( { model | screen = QuestionScreen idx "" }
    , Task.attempt (\_ -> NoOp) (Browser.Dom.focus "answer-input")
    )


-- Which PlaySong (if any) pressing Begin must schedule to actually start the
-- screen we're parked on. Only a bare BlankScreen on a *video* slide with no
-- PlaySong already pending needs the kick: the server-derived resume screen
-- (see Server.elm's deriveQuizScreen) is a BlankScreen, and while an audio
-- slide self-starts from there (the audio element renders and plays -- see
-- Audio.currentQuizSong), a video slide only ever starts via PlaySong's
-- transition into VideoScreen, so without this it would sit on the blank
-- screen forever.
resumePlaySongTarget : List String -> List PendingEvent -> Screen -> Maybe Int
resumePlaySongTarget questions pending screen =
    case screen of
        BlankScreen idx ->
            case getQuestion questions idx of
                Just song ->
                    if isVideo song && not (hasPendingPlaySong idx pending) then
                        Just idx

                    else
                        Nothing

                Nothing ->
                    Nothing

        _ ->
            Nothing


-- Promotes a CheckingAnswerScreen to ConfirmingAnswerScreen once the client
-- actually has a connection to send that state over.
promoteChecking : Screen -> Screen
promoteChecking screen =
    case screen of
        CheckingAnswerScreen nextScreen ->
            ConfirmingAnswerScreen nextScreen

        _ ->
            screen


-- Falls a CheckingAnswerScreen straight through to its wrapped screen when
-- there's no connection to confirm it over.
resolveChecking : Screen -> Screen
resolveChecking screen =
    case screen of
        CheckingAnswerScreen nextScreen ->
            nextScreen

        _ ->
            screen


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
                -- Whether the session has timed out is a server decision (see
                -- Server.elm's ClientStateUpdate handling / the ServerTimedOut case
                -- below), not something the client computes from its own clock.
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

        
        BeginPressed ->
            case model.screen of
                BeginScreen inner ->
                    -- inner is already whatever the server derived (or, for the
                    -- families that stay self-reported, the client's own last
                    -- report) -- unwrapping it is the whole resume, no separate
                    -- round-trip needed. Clear any stray leftover local
                    -- scheduling defensively (there shouldn't be any live while
                    -- parked on the begin screen), then kick off whatever this
                    -- screen needs to actually start running.
                    let
                        cleared =
                            { model | screen = inner } |> clearPending

                        kicked =
                            case resumePlaySongTarget cleared.questions cleared.pending cleared.screen of
                                Just idx ->
                                    schedule 1000 (PlaySong idx) cleared

                                Nothing ->
                                    cleared
                    in
                    ( kicked
                    , Cmd.batch [ pauseMusic "jeopardy-audio", resumeCmd model inner ]
                    )

                _ ->
                    ( model, Cmd.none )

        PlaySong idx ->
            case innerBlankIdx model.screen of
                Just blankIdx ->
                    if blankIdx == idx then
                        case getQuestion model.questions idx of
                            Just song ->
                                if isVideo song then
                                    ( { model | screen = VideoScreen idx song }, Cmd.none )

                                else
                                    ( model, Cmd.none )

                            Nothing ->
                                ( model, Cmd.none )

                    else
                        ( model, Cmd.none )

                Nothing ->
                    ( model, Cmd.none )

        TrackEnded name ->
            if name == "jeopardy-theme.mp3" then
                ( model, Cmd.none )

            else
                case trackEndedTarget model.questions model.screen name of
                    Just idx ->
                        ( { model | screen = BlankScreen idx, songTimerElapsed = False, songEndAcked = False }
                            |> schedule 1000 (ShowQuestion idx)
                        , sendWs model (quizSongEndedEnvelope idx)
                        )

                    Nothing ->
                        ( model, Cmd.none )

        ShowQuestion idx ->
            case model.screen of
                BlankScreen blankIdx ->
                    if blankIdx == idx then
                        if model.songEndAcked then
                            revealQuestion idx model

                        else
                            ( { model | songTimerElapsed = True }, Cmd.none )

                    else
                        ( model, Cmd.none )

                _ ->
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
                    -- The server, not this client, holds the answers (see #54)
                    -- and decides correctness -- the result arrives as
                    -- ServerQuizAnswerResult in WsDataReceived below, which is
                    -- what actually transitions the screen. awaitingAnswerResult
                    -- both disables the submit UI (see View.elm) and guards
                    -- against a duplicate submit while the round trip is in flight.
                    if model.awaitingAnswerResult then
                        ( model, Cmd.none )

                    else
                        ( { model | awaitingAnswerResult = True }
                        , sendWs model (quizAnswerSubmittedEnvelope { idx = idx, answer = answer })
                        )

                _ ->
                    ( model, Cmd.none )

        ContinuePressed ->
            case model.screen of
                WrongAnswerScreen idx _ ->
                    ( clearPending
                        { model
                            | screen =
                                IQTestScreen
                                    { questionIdx = idx
                                    , totalDings = iqQuestionCount
                                    , pendingSkipOffer = Nothing
                                    , offerIsLastChance = False
                                    }
                        }
                    , Cmd.none
                    )

                _ ->
                    ( model, Cmd.none )

        IQTestBeginPressed ->
            case model.screen of
                IQTestScreen iqScreen ->
                    case iqScreen.pendingSkipOffer of
                        -- A grant is already sitting here (from ServerIqOfferDecision, or
                        -- re-derived fresh on reconnect by Server.elm's deriveIqScreen) --
                        -- show the offer screen instead of starting the countdown. Purely
                        -- local: the server already recorded the grant when it decided it,
                        -- so there's nothing new to report.
                        Just totalDings ->
                            ( clearPending
                                { model
                                    | screen =
                                        IQTestSkipOfferScreen
                                            { questionIdx = iqScreen.questionIdx
                                            , totalDings = totalDings
                                            , pendingSkipOffer = Nothing
                                            , offerIsLastChance = iqScreen.offerIsLastChance
                                            }
                                }
                            , Cmd.none
                            )

                        Nothing ->
                            -- Enter the countdown screen and ask the server to run it. The
                            -- server owns the count and all timing; the client just renders.
                            ( { model
                                | screen =
                                    IQTestCountdownScreen
                                        { questionIdx = iqScreen.questionIdx
                                        , totalDings = iqScreen.totalDings
                                        , countdown = iqScreen.totalDings
                                        }
                              }
                            , sendWs model iqStartCountdownEnvelope
                            )

                _ ->
                    ( model, Cmd.none )

        DingFlashEnd ->
            case model.screen of
                IQTestActiveScreen state ->
                    ( { model | screen = IQTestActiveScreen { state | isFlashing = False } }, Cmd.none )

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
                        -- Correctly ignored the fake: clear it and ask the server
                        -- for the next ding. The server advances its own progression.
                        ( { model | screen = IQTestActiveScreen { state | fakeFlashActive = False } }
                        , sendWs model iqReadyForDingEnvelope
                        )

                    else
                        ( model, Cmd.none )

                _ ->
                    ( model, Cmd.none )

        SpaceBarPressed ->
            case model.screen of
                IQTestActiveScreen state ->
                    -- The server is authoritative and its next ServerIqDing/
                    -- ServerIqTestComplete overwrites whatever decideSpaceBar
                    -- guesses here; this just makes the UI responsive.
                    case decideSpaceBar state of
                        CaughtTrap caughtState ->
                            ( clearPending { model | screen = FakeFlashCaughtScreen caughtState }
                                |> schedule 1000 FakeFlashNextPhase
                            , sendWs model iqCaughtEnvelope
                            )

                        SpaceBarFailed ->
                            iqFail model state

                        OptimisticClear newState ->
                            ( { model | screen = IQTestActiveScreen newState }
                            , sendWs model iqReadyForDingEnvelope
                            )

                _ ->
                    ( model, Cmd.none )

        StartLoudMusic ->
            case model.screen of
                IQTestActiveScreen state ->
                    ( { model | screen = IQTestActiveScreen { state | loudPlaying = True } }
                    , Cmd.none
                    )

                _ ->
                    ( model, Cmd.none )

        FakeFlashNextPhase ->
            case model.screen of
                FakeFlashCaughtScreen state ->
                    case nextFfPhase state.phase of
                        Just ( newPhase, delay ) ->
                            ( { model | screen = FakeFlashCaughtScreen { state | phase = newPhase } }
                                |> schedule delay FakeFlashNextPhase
                            , Cmd.none
                            )

                        Nothing ->
                            case state.phase of
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
                                    -- If the server's ServerIqOfferDecision (in reply to the
                                    -- iqCaught this cutscene started from) already arrived and
                                    -- granted the offer, land on the offer screen instead of the
                                    -- plain IQ begin screen -- see Main.elm's WsDataReceived
                                    -- handling of ServerIqOfferDecision.
                                    case state.skipOffer of
                                        Just totalDings ->
                                            ( clearPending
                                                { model
                                                    | screen =
                                                        IQTestSkipOfferScreen
                                                            { questionIdx = state.questionIdx
                                                            , totalDings = totalDings
                                                            , pendingSkipOffer = Nothing
                                                            , offerIsLastChance = state.offerIsLastChance
                                                            }
                                                }
                                            , Cmd.none
                                            )

                                        Nothing ->
                                            ( clearPending { model | screen = IQTestScreen (exitFakeFlash state) }
                                            , Cmd.none
                                            )

                                _ ->
                                    ( model, Cmd.none )

                _ ->
                    ( model, Cmd.none )

        IQSkipOfferAccepted ->
            case model.screen of
                IQTestSkipOfferScreen s ->
                    ( clearPending
                        { model
                            | screen =
                                IQTestSkipAnimScreen
                                    { questionIdx = s.questionIdx
                                    , displayCount = 0
                                    , total = s.totalDings
                                    , phase = SkipCounterIn
                                    }
                        }
                        |> schedule 700 IQSkipAnimNextPhase
                    , clearOfferGrantCache
                    )

                _ ->
                    ( model, Cmd.none )

        IQSkipOfferDeclined ->
            case model.screen of
                IQTestSkipOfferScreen s ->
                    -- Releases the server-held grant (see decideIqOffer/
                    -- Model.iqOfferGrants) so a subsequent Begin press isn't blocked --
                    -- the one-time flag was already committed server-side at grant
                    -- time, so this is the only thing left to report.
                    ( clearPending
                        { model
                            | screen =
                                IQTestScreen
                                    { questionIdx = s.questionIdx
                                    , totalDings = s.totalDings
                                    , pendingSkipOffer = Nothing
                                    , offerIsLastChance = False
                                    }
                        }
                    , Cmd.batch [ sendWs model iqOfferDeclinedEnvelope, clearOfferGrantCache ]
                    )

                _ ->
                    ( model, Cmd.none )

        IQSkipAnimNextPhase ->
            case model.screen of
                IQTestSkipAnimScreen s ->
                    case s.phase of
                        SkipCounterIn ->
                            ( { model | screen = IQTestSkipAnimScreen { s | phase = SkipTick } }
                                |> schedule counterTickMs IQSkipCounterTick
                            , Cmd.none
                            )

                        SkipTick ->
                            ( { model | screen = IQTestSkipAnimScreen { s | phase = SkipCounterOut } }
                                |> schedule 1500 IQSkipAnimNextPhase
                            , Cmd.none
                            )

                        SkipCounterOut ->
                            -- Exactly mirrors ServerIqTestComplete's genuine-pass transition
                            -- below (BlankScreen nextIdx + PlaySong + quizAdvancedEnvelope) --
                            -- the count-up animation is flavor layered in front of it, not a
                            -- substitute for it.
                            let
                                nextIdx =
                                    s.questionIdx + 1
                            in
                            ( clearPending { model | screen = BlankScreen nextIdx }
                                |> schedule 1000 (PlaySong nextIdx)
                            , sendWs model (quizAdvancedEnvelope s.questionIdx)
                            )

                _ ->
                    ( model, Cmd.none )

        IQSkipCounterTick ->
            case model.screen of
                IQTestSkipAnimScreen s ->
                    case s.phase of
                        SkipTick ->
                            if s.displayCount < s.total then
                                let
                                    targetId =
                                        "ding-audio-" ++ String.fromInt (modBy dingSlotCount model.dingKey)
                                in
                                ( { model
                                    | screen = IQTestSkipAnimScreen { s | displayCount = s.displayCount + 1 }
                                    , dingKey = model.dingKey + 1
                                  }
                                    |> schedule counterTickMs IQSkipCounterTick
                                , setDomProperty { elementId = targetId, property = "volume", value = Encode.float 0.3 }
                                )

                            else
                                ( model
                                    |> schedule 500 IQSkipAnimNextPhase
                                , Cmd.none
                                )

                        _ ->
                            ( model, Cmd.none )

                _ ->
                    ( model, Cmd.none )

        WsClientReady wsId ->
            let
                newModel =
                    { model
                        | wsClientId = Just wsId
                        , screen =
                            case model.screen of
                                -- Preserve an optimistically-seeded cache guess (see
                                -- OfferGrantCacheLoaded) instead of stomping it back to a
                                -- generic loading screen -- WsDataReceived's
                                -- ServerStateUpdate handling below still reconciles it
                                -- (silently, in place) once the real reply lands.
                                BeginScreen _ ->
                                    model.screen

                                _ ->
                                    WsLoadingScreen
                    }
            in
            case model.myUuid of
                Just uuid ->
                    ( newModel
                    , sendToWs { wsId = wsId, data = Encode.encode 0 (stateRequestEnvelope uuid) }
                    )

                Nothing ->
                    ( { newModel | screen = WsErrorScreen }, Cmd.none )

        WsDataReceived envelopeJson ->
            case Decode.decodeString decodeServerEnvelope envelopeJson of
                Ok (ServerStateUpdate inner) ->
                    -- decodeModel is tolerant of the brand-new-player "{}" shape (screen
                    -- defaults to BeginScreen (BlankScreen 0)), so every case -- fresh
                    -- player or resume -- goes through the same decode; there's no
                    -- separate empty-object sentinel branch. dingKey isn't carried
                    -- forward in applyServerStateUpdate: 0 is exactly correct for a
                    -- freshly (re)connected session, nothing ding-related survives a
                    -- disconnect.
                    case model.screen of
                        WsLoadingScreen ->
                            applyServerStateUpdate model inner

                        -- A still-showing optimistic guess seeded from the local cache
                        -- (see OfferGrantCacheLoaded/WsClientReady's preserving guard) is
                        -- also a valid state to reconcile from -- this is what actually
                        -- corrects a stale/wrong cached guess in place, invisibly, once
                        -- the real reply lands. Accepted residual risk: if the player
                        -- already presses Begin and unwraps the guess before this
                        -- arrives, the correction can no longer apply since the screen
                        -- is no longer BeginScreen _ -- cosmetic only, since accept/
                        -- decline stay fully server-enforced via Server.elm's
                        -- Model.iqOfferGrants regardless of what the client displays.
                        BeginScreen _ ->
                            applyServerStateUpdate model inner

                        _ ->
                            ( model, Cmd.none )

                Ok (ServerRejected _) ->
                    ( { model | screen = WsErrorScreen, wsClientId = Nothing }, Cmd.none )

                Ok ServerAck ->
                    case model.screen of
                        ConfirmingAnswerScreen (WinScreen _) ->
                            -- The win screen is revealed by the separate winText message,
                            -- not this ack, so the client waits here until it arrives.
                            ( model, Cmd.none )

                        ConfirmingAnswerScreen nextScreen ->
                            ( { model | screen = nextScreen }, Cmd.none )

                        _ ->
                            ( model, Cmd.none )

                Ok (ServerWinText winText) ->
                    case model.screen of
                        CheckingAnswerScreen (WinScreen _) ->
                            ( { model | screen = WinScreen winText }, Cmd.none )

                        ConfirmingAnswerScreen (WinScreen _) ->
                            ( { model | screen = WinScreen winText }, Cmd.none )

                        WinScreen _ ->
                            ( { model | screen = WinScreen winText }, Cmd.none )

                        -- The wrong-answer -> IQ-test-penalty -> pass path
                        -- (ServerIqTestComplete / IQSkipAnimNextPhase's
                        -- SkipCounterOut) advances straight to BlankScreen
                        -- nextIdx without checking whether nextIdx is in
                        -- range, so on the last question it strands the
                        -- player there with no song to play. winText only
                        -- ever arrives once the server's own tally confirms
                        -- quizJustCompleted, so honoring it here can't
                        -- misfire on a legitimate mid-quiz BlankScreen.
                        BlankScreen _ ->
                            ( { model | screen = WinScreen winText }, Cmd.none )

                        _ ->
                            ( model, Cmd.none )

                Ok (ServerIqCountdownTick remaining) ->
                    -- Display-only: the server is authoritative on the countdown.
                    case model.screen of
                        IQTestCountdownScreen state ->
                            ( { model | screen = IQTestCountdownScreen { state | countdown = remaining } }, Cmd.none )

                        _ ->
                            ( model, Cmd.none )

                Ok (ServerIqCountdownComplete dingCount) ->
                    -- Countdown done: enter the active test and request the first ding.
                    -- dingCount is the server's authoritative count (nonzero if edit:state
                    -- set it while the countdown was running); render it directly instead
                    -- of assuming a fresh test's 0, and if it's already at/above the loud
                    -- threshold, arm the loud gag now rather than waiting on a
                    -- ServerIqStartLoud that (having already passed that threshold) will
                    -- never arrive.
                    case model.screen of
                        IQTestCountdownScreen state ->
                            let
                                withActiveScreen =
                                    clearPending
                                        { model
                                            | screen =
                                                IQTestActiveScreen
                                                    { questionIdx = state.questionIdx
                                                    , dingCount = dingCount
                                                    , totalDings = state.totalDings
                                                    , isFlashing = False
                                                    , dingActive = False
                                                    , fakeFlashActive = False
                                                    , fakeIsTrap = False
                                                    , loudPlaying = False
                                                    }
                                        }
                            in
                            ( if dingCount >= iqLoudDingThreshold then
                                withActiveScreen |> schedule iqLoudDelay StartLoudMusic

                              else
                                withActiveScreen
                            , sendWs model iqReadyForDingEnvelope
                            )

                        _ ->
                            ( model, Cmd.none )

                Ok (ServerIqDing d) ->
                    -- The server decided real vs fake (and, for fakes, trap vs
                    -- 50%-phase). The client just renders the flash and arms the
                    -- local response window.
                    case model.screen of
                        IQTestActiveScreen state ->
                            let
                                base =
                                    { state | dingCount = d.dingCount, totalDings = d.totalDings, isFlashing = True }
                            in
                            if d.fake then
                                ( { model | screen = IQTestActiveScreen { base | dingActive = False, fakeFlashActive = True, fakeIsTrap = d.trap } }
                                    |> schedule iqFlashDuration DingFlashEnd
                                    |> schedule iqWindowDuration FakeFlashWindowExpired
                                , Cmd.none
                                )

                            else
                                ( { model
                                    | screen = IQTestActiveScreen { base | dingActive = True, fakeFlashActive = False }
                                    , dingKey = model.dingKey + 1
                                  }
                                    |> schedule iqFlashDuration DingFlashEnd
                                    |> schedule iqWindowDuration DingWindowExpired
                                , Cmd.none
                                )

                        _ ->
                            ( model, Cmd.none )

                Ok ServerIqStartLoud ->
                    -- The 4th real ding was cleared: arm the loud gag after 3 s
                    -- (kept client-side to match the original timing).
                    case model.screen of
                        IQTestActiveScreen _ ->
                            ( model |> schedule iqLoudDelay StartLoudMusic, Cmd.none )

                        _ ->
                            ( model, Cmd.none )

                Ok ServerIqTestComplete ->
                    -- The server's count reached the target: release to the next song.
                    case model.screen of
                        IQTestActiveScreen state ->
                            let
                                nextIdx =
                                    state.questionIdx + 1
                            in
                            ( clearPending { model | screen = BlankScreen nextIdx }
                                |> schedule 1000 (PlaySong nextIdx)
                            -- The wrong-answer -> IQ-test-penalty path doesn't replay the
                            -- question -- it advances past it just like a correct answer
                            -- would, so this counts as passing state.questionIdx too (see
                            -- Server.elm's acceptQuizAdvance/quizJustCompleted).
                            , sendWs model (quizAdvancedEnvelope state.questionIdx)
                            )

                        _ ->
                            ( model, Cmd.none )

                Ok (ServerQuizAnswerResult r) ->
                    -- The server independently validated the answer (see #54);
                    -- this is what actually transitions off QuestionScreen. The
                    -- idx check guards against a stale result arriving after the
                    -- screen has already moved on (e.g. a race with a reconnect).
                    case model.screen of
                        QuestionScreen idx _ ->
                            if idx /= r.idx then
                                ( model, Cmd.none )

                            else
                                let
                                    cleared =
                                        { model | awaitingAnswerResult = False }
                                in
                                if r.correct then
                                    let
                                        nextIdx =
                                            idx + 1
                                    in
                                    case getQuestion model.questions nextIdx of
                                        Just _ ->
                                            ( { cleared | screen = CheckingAnswerScreen (BlankScreen nextIdx) }
                                                |> clearPending
                                                |> schedule 1000 (PlaySong nextIdx)
                                            , Cmd.none
                                            )

                                        Nothing ->
                                            -- Empty text for now; the server fills it in at win
                                            -- time via the winText message (see ServerWinText),
                                            -- once it independently confirms the server's own
                                            -- quizProgress tally reached totalQuestions (see
                                            -- Server.elm's acceptQuizAdvance/quizJustCompleted).
                                            ( clearPending { cleared | screen = CheckingAnswerScreen (WinScreen "") }
                                            , Cmd.none
                                            )

                                else
                                    ( { cleared | screen = WrongAnswerScreen idx r.revealAnswer }, Cmd.none )

                        _ ->
                            ( model, Cmd.none )

                Ok (ServerQuizSongEndedAck idx) ->
                    -- The server confirmed it recorded this song/video as ended.
                    -- Only meaningful while still on the matching BlankScreen (guards
                    -- a stale/late ack after the screen already moved on). Reveals the
                    -- answer input immediately if the local pause has already elapsed;
                    -- otherwise just records the ack and waits for ShowQuestion.
                    case model.screen of
                        BlankScreen blankIdx ->
                            if blankIdx /= idx then
                                ( model, Cmd.none )

                            else if model.songTimerElapsed then
                                revealQuestion idx model

                            else
                                ( { model | songEndAcked = True }, Cmd.none )

                        _ ->
                            ( model, Cmd.none )

                Ok (ServerIqOfferDecision d) ->
                    -- The server's authoritative reply to iqFailedEnvelope (a plain fail)
                    -- or iqCaughtEnvelope (a trap catch) -- see Server.elm's decideIqOffer.
                    -- On IQTestActiveScreen (the plain-fail case, frozen there by iqFail
                    -- above) this is what actually transitions off it, to the instructions
                    -- screen either way -- a granted offer is stashed as pendingSkipOffer
                    -- rather than jumping straight to the offer screen, so the player always
                    -- sees the instructions first and only reaches the offer via
                    -- IQTestBeginPressed (see issue #93). On FakeFlashCaughtScreen (the catch
                    -- case) the cutscene is still ~10s from its end, so just stash the
                    -- decision for FfCounterOut to read -- that path lands directly on the
                    -- offer screen once the cutscene finishes, which is the correct/desired
                    -- behavior there, unlike the plain-fail case. Any other screen: a
                    -- stale/late reply after the screen already moved on (e.g. a race with a
                    -- reconnect) -- ignore.
                    case model.screen of
                        IQTestActiveScreen state ->
                            let
                                newScreen =
                                    IQTestScreen
                                        { questionIdx = state.questionIdx
                                        , totalDings = d.totalDings
                                        , pendingSkipOffer =
                                            if d.granted then
                                                Just d.totalDings

                                            else
                                                Nothing
                                        , offerIsLastChance = d.granted && d.isLastChance
                                        }
                            in
                            ( { model | screen = newScreen }, offerGrantCacheSyncCmd newScreen )

                        FakeFlashCaughtScreen state ->
                            let
                                newScreen =
                                    FakeFlashCaughtScreen
                                        { state
                                            | skipOffer = if d.granted then Just d.totalDings else Nothing
                                            , offerIsLastChance = d.granted && d.isLastChance
                                        }
                            in
                            ( { model | screen = newScreen }, offerGrantCacheSyncCmd newScreen )

                        _ ->
                            ( model, Cmd.none )

                Ok (ServerTimerSync deadline) ->
                    -- Delivered once per stateRequest (see Server.elm's
                    -- ClientStateRequest handling): the server-established 7-day
                    -- deadline, for display only -- the client never computes it.
                    ( { model | timerEndsAt = deadline }, Cmd.none )

                Ok ServerTimedOut ->
                    -- The server's own clock decided the session is over.
                    ( { model | screen = TimedOutScreen }, Cmd.none )

                _ ->
                    ( model, Cmd.none )

        WsDisconnected _ ->
            let
                _ = Debug.log "WebSocket disconnected"
            in
            case model.screen of
                WsConnectingScreen ->
                    ( model |> scheduleReconnect, Cmd.none )

                _ ->
                    ( { model | wsClientId = Nothing, screen = WsConnectingScreen } |> scheduleReconnect, Cmd.none )

        WsReconnect ->
            case model.screen of
                WsErrorScreen ->
                    ( { model | screen = WsConnectingScreen }, initWebSocketClient model.wsUrl )

                WsConnectingScreen ->
                    ( model, initWebSocketClient model.wsUrl )

                _ ->
                    ( model, Cmd.none )

        WsSyncTick ->
            case ( model.wsClientId, model.screen ) of
                ( Just _, WsLoadingScreen ) ->
                    ( model, Cmd.none )

                ( Just _, WsConnectingScreen ) ->
                    ( model, Cmd.none )

                ( Just _, WsErrorScreen ) ->
                    ( model, Cmd.none )

                ( Just wsId, _ ) ->
                    let
                        newModel =
                            { model | screen = promoteChecking model.screen }
                    in
                    ( newModel, sendToWs { wsId = wsId, data = Encode.encode 0 (clientStateEnvelope newModel) } )

                ( Nothing, _ ) ->
                    ( { model | screen = resolveChecking model.screen }, Cmd.none )

        UuidLoaded maybeUuid ->
            case maybeUuid of
                Just uuid ->
                    ( { model | myUuid = Just uuid }, initWebSocketClient model.wsUrl )

                Nothing ->
                    ( { model | screen = WsErrorScreen }, Cmd.none )

        QuestionsLoaded loadedQuestions ->
            ( { model | questions = loadedQuestions }, Cmd.none )

        OfferGrantCacheLoaded maybeGrant ->
            -- Optimistically seed the starting screen from the local cache (see
            -- offerGrantCachePath/CachedOfferGrant's doc comment) so the very first
            -- render is already offer-eligible instead of a generic connecting
            -- screen, while the WebSocket round trip is still in flight. Mirrors
            -- Server.elm's deriveIqScreen's own derivation formula exactly (down to
            -- the FfDelay/0-numerator coarse-resume shape for a catch-triggered
            -- grant) so the optimistic guess and the eventual authoritative
            -- ServerStateUpdate render identically when the cache wasn't stale --
            -- see WsClientReady/WsDataReceived's BeginScreen-preserving guards,
            -- which are what actually reconcile it once the real reply lands.
            case maybeGrant of
                Nothing ->
                    ( model, Cmd.none )

                Just grant ->
                    let
                        derived =
                            case grant.trigger of
                                FailTrigger ->
                                    IQTestScreen
                                        { questionIdx = grant.questionIdx
                                        , totalDings = grant.totalDings
                                        , pendingSkipOffer = Just grant.totalDings
                                        , offerIsLastChance = grant.offerIsLastChance
                                        }

                                CatchTrigger ->
                                    let
                                        originalTotal =
                                            grant.totalDings // 2
                                    in
                                    FakeFlashCaughtScreen
                                        { questionIdx = grant.questionIdx
                                        , originalTotal = originalTotal
                                        , displayNumerator = 0
                                        , displayDenominator = originalTotal
                                        , phase = FfDelay
                                        , skipOffer = Just grant.totalDings
                                        , offerIsLastChance = grant.offerIsLastChance
                                        }
                    in
                    ( { model | screen = BeginScreen derived }, Cmd.none )

        NoOp ->
            ( model, Cmd.none )

        DomPropertyReceived _ ->
            ( model, Cmd.none )

        DomPropertyError _ ->
            ( model, Cmd.none )

        FakeFlashCounterTick ->
            case model.screen of
                FakeFlashCaughtScreen state ->
                    case state.phase of
                        FfTickNumerator ->
                            if state.displayNumerator > 0 then
                                let
                                    targetId =
                                        "ding-audio-" ++ String.fromInt (modBy dingSlotCount model.dingKey)
                                in
                                ( { model
                                    | screen = FakeFlashCaughtScreen { state | displayNumerator = state.displayNumerator - 1 }
                                    , dingKey = model.dingKey + 1
                                  }
                                    |> schedule counterTickMs FakeFlashCounterTick
                                , setDomProperty { elementId = targetId, property = "volume", value = Encode.float 0.15 }
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
                                let
                                    targetId =
                                        "ding-audio-" ++ String.fromInt (modBy dingSlotCount model.dingKey)
                                in
                                ( { model
                                    | screen = FakeFlashCaughtScreen { state | displayDenominator = state.displayDenominator + 1 }
                                    , dingKey = model.dingKey + 1
                                  }
                                    |> schedule counterTickMs FakeFlashCounterTick
                                , setDomProperty { elementId = targetId, property = "volume", value = Encode.float 0.3 }
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








-- Decides what Msg a readFile port response becomes: app-uuid.json (its "uuid"
-- field) and offerGrantCachePath (a CachedOfferGrant, see its doc comment) are
-- the only two files this port is used for -- the quiz no longer reads any
-- config/ JSON client-side, see #54/#70's review. Switches on `path` since a
-- single readFileResult subscription (see subscriptions) handles both.
decodeReadFileResult : { path : String, contents : Maybe String, error : Maybe String } -> Msg
decodeReadFileResult { path, contents } =
    if path == offerGrantCachePath then
        case contents of
            Just raw ->
                OfferGrantCacheLoaded (Decode.decodeString decodeCachedOfferGrant raw |> Result.toMaybe)

            Nothing ->
                OfferGrantCacheLoaded Nothing

    else
        case contents of
            Just raw ->
                case Decode.decodeString (Decode.field "uuid" Decode.string) raw of
                    Ok uuid ->
                        UuidLoaded (Just uuid)

                    Err _ ->
                        UuidLoaded Nothing

            Nothing ->
                UuidLoaded Nothing


-- Decides what Msg a readDir port response becomes: assets/songs/'s listing,
-- ordered by each filename's leading number (see Game.Quiz.songOrder) -- an
-- unreadable directory naturally yields no questions, the same fail-safe
-- default as a malformed quiz-manifest.json used to.
decodeReadDirResult : { path : String, files : List String, error : Maybe String } -> Msg
decodeReadDirResult { files } =
    QuestionsLoaded (songOrder files)


everySecond : Time.Posix -> Msg
everySecond _ =
    WsSyncTick


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
        [ wsClientReady WsClientReady
        , receiveFromWs WsDataReceived
        , wsClientFailed WsDisconnected
        , Time.every 1000 everySecond
        , keyboardSub
        , Browser.Events.onAnimationFrame tickFromPosix
        , receiveDomProperty DomPropertyReceived
        , domPropertyError DomPropertyError
        , readFileResult decodeReadFileResult
        , readDirResult decodeReadDirResult
        ]

main : Program String Model Msg
main =
    Browser.element
        { init = init
        , update = update
        , view = view
        , subscriptions = subscriptions
        }
