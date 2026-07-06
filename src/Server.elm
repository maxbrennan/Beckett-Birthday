port module Server exposing (..)

import Dict exposing (Dict)
import Game.IQTest as IQTest
import Json.Decode as Decode
import Json.Encode as Encode
import Platform
import Process
import Random
import Server.Distribution exposing (..)
import Server.Protocol exposing (..)
import Server.Registry exposing (..)
import Set exposing (Set)
import Task
import Time



type alias Model =
    { connectedPlayers : Dict String String
    , distClients : Dict String DistStage
    , registry : List RegistryEntry
    , pendingStateEdits : Set String
    , iqTimers : Dict String IqTimerState
    , seed : Random.Seed
    }


{-| Where a player is in the server-driven IQ test. The server owns all timing
and the whole ding/question count; the client only renders and reports raw input.
-}
type IqPhase
    = IqCounting -- pre-test countdown ticking down
    | IqAwaitingReady -- countdown done or a ding resolved; waiting for the client's iqReadyForDing
    | IqDingScheduled -- a random inter-ding delay is sleeping; ding not yet shown
    | IqDingShown -- a ding was emitted; waiting for the client to resolve it
    | IqIdle -- post-catch: waiting for the client to press Begin (iqStartCountdown) again


{-| Per-player IQ-test state, keyed by **uuid** (the durable player identity, not
the ephemeral `clientId` a WebSocket connection gets) so it survives a
disconnect/reconnect. Persists across fail-restart, catch-restart, and a
disconnect within a session -- only test completion removes it. The client
never supplies the count -- the server initializes it to `iqQuestionCount` and
doubles it on a catch.

On disconnect the entry is *paused*, not dropped: `ClientDisconnected` bumps
`epoch` (invalidating any in-flight `Process.sleep`) but keeps every field, and
`ClientIqResume` re-arms the appropriate schedule once the player is back and
has actually rendered the IQ screen again -- see `resumeIqTimer`.
-}
type alias IqTimerState =
    { epoch : Int -- bumped on every start; stale Process.sleep fires are ignored
    , phase : IqPhase
    , countdownRemaining : Int
    , dingCount : Int -- real dings cleared so far
    , totalDings : Int -- target count; the punishment phase decrements this toward iqQuestionCount
    , fakeFlashPoint : Int -- server-chosen trap position
    , fakeFlashUsed : Bool
    , in50PercentPhase : Bool
    , lastDing : DingKind -- kind of the ding most recently emitted
    }


{-| What the server most recently flashed. A `TrapFake` is the one-time
catchable trap (pressing it triggers the penalty); a `PhaseFake` is a 50%-phase
fake (pressing it fails). Both are "fakes" for progression purposes.
-}
type DingKind
    = RealDing
    | TrapFake
    | PhaseFake


type Msg
    = ClientConnected String
    | ClientDisconnected String
    | MessageReceived { clientId : String, payload : Encode.Value }
    | FileRead String (Result String String)
    | AuthCompleted { clientId : String, success : Bool, level : Int, uuid : String }
    | WriteFileCompleted { path : String, ok : Bool, error : Maybe String }
    | GotTime Time.Posix
    | CountdownStep { uuid : String, epoch : Int }
    | DingReady { uuid : String, epoch : Int }





-- ── IQ-test server-side logic ────────────────────────────────────────────────
-- Pure ports of the old client scoring, kept separate so they can be unit-tested.


{-| Classify the next ding. Mirrors the old client `DingOccurred` rule: the
one-time trap fires at `fakeFlashPoint` (until used), and once used only the 50%
phase produces fakes (on a coin flip).
-}
classifyDing : Bool -> IqTimerState -> DingKind
classifyDing coin s =
    if not s.fakeFlashUsed && not s.in50PercentPhase && s.dingCount == s.fakeFlashPoint then
        TrapFake

    else if s.in50PercentPhase && coin then
        PhaseFake

    else
        RealDing


dingIsFake : DingKind -> Bool
dingIsFake kind =
    kind /= RealDing


type ClearOutcome
    = Completed
    | Advanced { startLoud : Bool, state : IqTimerState }


{-| Advance the progression when the client reports the outstanding ding was
resolved (a real ding cleared, or a fake correctly ignored). Mirrors the old
client `SpaceBarPressed` scoring: a cleared fake marks the trap used; a cleared
real ding either grinds down the punishment total, or counts up toward the target
(triggering the loud gag on the 4th and completing at the target).
-}
advanceOnClear : IqTimerState -> ClearOutcome
advanceOnClear s =
    if dingIsFake s.lastDing then
        Advanced { startLoud = False, state = { s | fakeFlashUsed = True } }

    else if s.totalDings > IQTest.iqQuestionCount then
        let
            newTotal =
                s.totalDings - 1
        in
        Advanced
            { startLoud = False
            , state =
                { s
                    | totalDings = newTotal
                    , in50PercentPhase = s.in50PercentPhase || (newTotal == IQTest.iqQuestionCount)
                }
            }

    else
        let
            newDingCount =
                s.dingCount + 1
        in
        if newDingCount >= s.totalDings then
            Completed

        else
            Advanced
                { startLoud = newDingCount == 4
                , state = { s | dingCount = newDingCount }
                }


{-| Apply the fake-flash penalty: double the count (capped), re-arm the punishment
phase, and reset progress. Mirrors the old client `FfCounterOut` restart.
-}
applyCatch : IqTimerState -> IqTimerState
applyCatch s =
    { s
        | totalDings = Basics.min (s.totalDings * 2) IQTest.maxTotalDings
        , fakeFlashUsed = True
        , in50PercentPhase = False
        , dingCount = 0
    }


{-| The IQ-relevant fields of whatever screen an admin state edit just saved.
`EditedIqOther` covers both "not an IQ screen" and "decode failed" -- either
way there's nothing to reconcile.
-}
type EditedIqScreen
    = EditedIqBegin { totalDings : Int }
    | EditedIqCountdown { countdown : Int, totalDings : Int }
    | EditedIqActive { dingCount : Int, totalDings : Int }
    | EditedIqOther


decodeEditedIqScreen : Decode.Decoder EditedIqScreen
decodeEditedIqScreen =
    Decode.oneOf
        [ Decode.at [ "screen", "tag" ] Decode.string
            |> Decode.andThen
                (\tag ->
                    case tag of
                        "IQTestScreen" ->
                            Decode.map (\td -> EditedIqBegin { totalDings = td })
                                (Decode.at [ "screen", "state", "totalDings" ] Decode.int)

                        "IQTestCountdownScreen" ->
                            Decode.map2 (\cd td -> EditedIqCountdown { countdown = cd, totalDings = td })
                                (Decode.at [ "screen", "state", "countdown" ] Decode.int)
                                (Decode.at [ "screen", "state", "totalDings" ] Decode.int)

                        "IQTestActiveScreen" ->
                            Decode.map2 (\dc td -> EditedIqActive { dingCount = dc, totalDings = td })
                                (Decode.at [ "screen", "state", "dingCount" ] Decode.int)
                                (Decode.at [ "screen", "state", "totalDings" ] Decode.int)

                        _ ->
                            Decode.succeed EditedIqOther
                )
        , Decode.succeed EditedIqOther
        ]


{-| The server's in-memory `iqTimers` is now the sole authority on the IQ
countdown/count, entirely separate from the persisted registry JSON an admin
edits with `edit:state`. Without this, an edited countdown/count is silently
clobbered the moment the server resends its own (unrelated) authoritative
value -- see the `iqResume`-driven resends in `resumeIqTimer`. So: whenever an
edit is saved, treat its IQ-relevant fields as the new authoritative state and
overwrite (or create) the player's `iqTimers` entry to match, keeping it
paused (no live schedule armed) exactly like a normal disconnect, so the next
`iqResume` (once the player reconnects and presses Begin again) arms it.
`fakeFlashUsed`/`in50PercentPhase` carry over from any existing entry (an edit
doesn't expose them); `fakeFlashPoint` is freshly drawn since the client no
longer has one to round-trip.
-}
reconcileIqTimerAfterEdit : String -> Encode.Value -> Model -> Model
reconcileIqTimerAfterEdit uuid parsedState model =
    let
        prev =
            Dict.get uuid model.iqTimers

        nextEpoch =
            (prev |> Maybe.map .epoch |> Maybe.withDefault 0) + 1

        carriedFakeFlashUsed =
            prev |> Maybe.map .fakeFlashUsed |> Maybe.withDefault False

        carriedIn50Percent =
            prev |> Maybe.map .in50PercentPhase |> Maybe.withDefault False
    in
    case Decode.decodeValue decodeEditedIqScreen parsedState of
        Ok (EditedIqBegin { totalDings }) ->
            { model
                | iqTimers =
                    Dict.insert uuid
                        { epoch = nextEpoch
                        , phase = IqIdle
                        , countdownRemaining = totalDings
                        , dingCount = 0
                        , totalDings = totalDings
                        , fakeFlashPoint = prev |> Maybe.map .fakeFlashPoint |> Maybe.withDefault 0
                        , fakeFlashUsed = carriedFakeFlashUsed
                        , in50PercentPhase = carriedIn50Percent
                        , lastDing = RealDing
                        }
                        model.iqTimers
            }

        Ok (EditedIqCountdown { countdown, totalDings }) ->
            let
                ( fakeFlashPoint, newSeed ) =
                    Random.step (IQTest.fakeFlashPointGen totalDings) model.seed
            in
            { model
                | iqTimers =
                    Dict.insert uuid
                        { epoch = nextEpoch
                        , phase = IqCounting
                        , countdownRemaining = countdown
                        , dingCount = 0
                        , totalDings = totalDings
                        , fakeFlashPoint = fakeFlashPoint
                        , fakeFlashUsed = carriedFakeFlashUsed
                        , in50PercentPhase = carriedIn50Percent
                        , lastDing = RealDing
                        }
                        model.iqTimers
                , seed = newSeed
            }

        Ok (EditedIqActive { dingCount, totalDings }) ->
            let
                ( fakeFlashPoint, newSeed ) =
                    Random.step (IQTest.fakeFlashPointGen totalDings) model.seed
            in
            { model
                | iqTimers =
                    Dict.insert uuid
                        { epoch = nextEpoch
                        , phase = IqAwaitingReady
                        , countdownRemaining = 0
                        , dingCount = dingCount
                        , totalDings = totalDings
                        , fakeFlashPoint = fakeFlashPoint
                        , fakeFlashUsed = carriedFakeFlashUsed
                        , in50PercentPhase = carriedIn50Percent
                        , lastDing = RealDing
                        }
                        model.iqTimers
                , seed = newSeed
            }

        Ok EditedIqOther ->
            model

        Err _ ->
            model


-- Send a payload to a player's *current* connection, resolved live via
-- connectedPlayers (their clientId can change across a disconnect/reconnect).
-- Silently drops the send if the player isn't currently connected.
sendToPlayer : String -> Model -> Encode.Value -> Cmd Msg
sendToPlayer uuid model payload =
    case Dict.get uuid model.connectedPlayers of
        Just clientId ->
            sendToClient { clientId = clientId, payload = payload }

        Nothing ->
            Cmd.none


scheduleCountdownStep : String -> Int -> Cmd Msg
scheduleCountdownStep uuid epoch =
    Process.sleep 1000
        |> Task.perform (\_ -> CountdownStep { uuid = uuid, epoch = epoch })


scheduleDing : String -> Int -> Float -> Cmd Msg
scheduleDing uuid epoch delay =
    Process.sleep delay
        |> Task.perform (\_ -> DingReady { uuid = uuid, epoch = epoch })


{-| Start (or restart) a player's countdown. The base count comes from the
server's own stored state -- the existing entry's `totalDings` (preserved across
fail/catch), or `iqQuestionCount` for the player's first start this session --
never from the client. Resets the run (fresh trap point, `dingCount` 0) while
preserving `fakeFlashUsed`/`in50PercentPhase`.
-}
startCountdown : String -> Model -> ( Model, Cmd Msg )
startCountdown uuid model =
    let
        prev =
            Dict.get uuid model.iqTimers

        baseTotal =
            prev |> Maybe.map .totalDings |> Maybe.withDefault IQTest.iqQuestionCount

        epoch =
            (prev |> Maybe.map .epoch |> Maybe.withDefault 0) + 1

        ( fakeFlashPoint, newSeed ) =
            Random.step (IQTest.fakeFlashPointGen baseTotal) model.seed

        newState =
            { epoch = epoch
            , phase = IqCounting
            , countdownRemaining = baseTotal
            , dingCount = 0
            , totalDings = baseTotal
            , fakeFlashPoint = fakeFlashPoint
            , fakeFlashUsed = prev |> Maybe.map .fakeFlashUsed |> Maybe.withDefault False
            , in50PercentPhase = prev |> Maybe.map .in50PercentPhase |> Maybe.withDefault False
            , lastDing = RealDing
            }
    in
    ( { model | iqTimers = Dict.insert uuid newState model.iqTimers, seed = newSeed }
    , scheduleCountdownStep uuid epoch
    )


-- Schedule the next ding after a server-enforced random delay, moving the player
-- into the DingScheduled phase.
scheduleNextDing : String -> IqTimerState -> Model -> ( Model, Cmd Msg )
scheduleNextDing uuid state model =
    let
        ( delay, newSeed ) =
            Random.step IQTest.dingDelayGen model.seed
    in
    ( { model
        | iqTimers = Dict.insert uuid { state | phase = IqDingScheduled } model.iqTimers
        , seed = newSeed
      }
    , scheduleDing uuid state.epoch delay
    )


{-| Re-arm a paused IQ timer once the player has reconnected *and* actually
rendered the corresponding IQ screen again (signalled by the client's
`iqResume`, sent right after `BeginPressed` restores an IQ screen from
`savedState`). Bumping to a fresh epoch here isn't needed -- `ClientDisconnected`
already bumped it, and nothing was scheduled against the new epoch until now.

- `IqCounting`: resend the current tick immediately (so the UI doesn't wait up
  to 1s for the next natural tick) and re-arm the 1s loop.
- `IqDingScheduled` / `IqAwaitingReady`: nothing was shown yet -- just arm the
  next ding (a fresh random delay; the exact remaining wait isn't tracked).
- `IqDingShown`: resend the same ding fresh, so the player gets a full
  250ms/2000ms window rather than whatever's left of the generic client-side
  pending-resume's rebased (and floor-clamped) window.
- `IqIdle`: nothing to resume; the player will press Begin to send a fresh
  `iqStartCountdown`.
-}
resumeIqTimer : String -> Model -> ( Model, Cmd Msg )
resumeIqTimer uuid model =
    case Dict.get uuid model.iqTimers of
        Nothing ->
            ( model, Cmd.none )

        Just state ->
            case state.phase of
                IqCounting ->
                    ( model
                    , Cmd.batch
                        [ sendToPlayer uuid model (iqCountdownTickEnvelope state.countdownRemaining)
                        , scheduleCountdownStep uuid state.epoch
                        ]
                    )

                IqDingScheduled ->
                    scheduleNextDing uuid state model

                IqAwaitingReady ->
                    scheduleNextDing uuid state model

                IqDingShown ->
                    ( model
                    , sendToPlayer uuid
                        model
                        (iqDingEnvelope
                            { fake = dingIsFake state.lastDing
                            , trap = state.lastDing == TrapFake
                            , dingCount = state.dingCount
                            , totalDings = state.totalDings
                            }
                        )
                    )

                IqIdle ->
                    ( model, Cmd.none )


writeRegistry : List RegistryEntry -> Cmd Msg
writeRegistry entries =
    writeFile
        { path = registryFilePath
        , contents = encodeRegistry entries
        , encoding = "utf8"
        , append = False
        }


{-| Remove a build after admin auth: drop it from the registry, kick any
connected player on that uuid, delete the file, persist, and ack the admin.
Runs only from AuthCompleted (post level-2 auth).
-}
performUndeploy : String -> String -> Model -> ( Model, Cmd Msg )
performUndeploy uuid clientId model =
    let
        maybePlayerClientId =
            Dict.get uuid model.connectedPlayers

        maybeTarget =
            model.registry
                |> List.filter (\e -> e.uuid == uuid)
                |> List.head

        newRegistry =
            List.filter (\e -> e.uuid /= uuid) model.registry
    in
    ( { model
        | registry = newRegistry
        , connectedPlayers = Dict.remove uuid model.connectedPlayers
        , distClients = Dict.remove clientId model.distClients
      }
    , Cmd.batch
        [ case maybePlayerClientId of
            Nothing ->
                Cmd.none

            Just playerClientId ->
                closeClient { clientId = playerClientId, reason = "admin undeployed build" }
        , case maybeTarget of
            Nothing ->
                Cmd.none

            Just target ->
                deleteBuildFile target.filename
        , writeRegistry newRegistry
        , sendToClient { clientId = clientId, payload = ackEnvelope }
        ]
    )


{-| Open a build's state for editing after admin auth: mark it pending, kick any
connected player, hand the current state to the admin, and move the admin into
the EditingState stage (which authorizes the following distStateEditSave).
Runs only from AuthCompleted (post level-2 auth).
-}
performStateEdit : String -> String -> Model -> ( Model, Cmd Msg )
performStateEdit uuid clientId model =
    let
        maybePlayerClientId =
            Dict.get uuid model.connectedPlayers

        currentState =
            model.registry
                |> List.filter (\e -> e.uuid == uuid)
                |> List.head
                |> Maybe.andThen .state
                |> Maybe.withDefault (Encode.object [])

        newRegistry =
            setPendingStateEdit uuid model.registry
    in
    ( { model
        | pendingStateEdits = Set.insert uuid model.pendingStateEdits
        , registry = newRegistry
        , distClients = Dict.insert clientId (EditingState uuid) model.distClients
      }
    , Cmd.batch
        [ case maybePlayerClientId of
            Nothing ->
                Cmd.none

            Just playerClientId ->
                closeClient { clientId = playerClientId, reason = "admin editing state" }
        , writeRegistry newRegistry
        , stateEditReady { adminClientId = clientId, uuid = uuid, json = Encode.encode 0 currentState }
        ]
    )


init : () -> ( Model, Cmd Msg )
init () =
    ( { connectedPlayers = Dict.empty
      , distClients = Dict.empty
      , registry = []
      , pendingStateEdits = Set.empty
      , iqTimers = Dict.empty
      , seed = Random.initialSeed 0
      }
    , Cmd.batch
        [ readFile registryFilePath
        , Task.perform GotTime Time.now
        ]
    )


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        ClientConnected _ ->
            ( model, Cmd.none )

        ClientDisconnected clientId ->
            let
                cleanedDist =
                    Dict.remove clientId model.distClients

                maybeUuid =
                    findUuidByClient clientId model.connectedPlayers

                -- Pause (don't drop) any live IQ timer for this player: bump its
                -- epoch so any in-flight Process.sleep becomes a stale no-op when it
                -- fires, but keep every field (dingCount/totalDings/phase/...) so a
                -- reconnect (ClientIqResume) picks up exactly where they left off.
                pausedTimers =
                    case maybeUuid of
                        Just uuid ->
                            Dict.update uuid (Maybe.map (\s -> { s | epoch = s.epoch + 1 })) model.iqTimers

                        Nothing ->
                            model.iqTimers
            in
            case maybeUuid of
                Nothing ->
                    ( { model | distClients = cleanedDist, iqTimers = pausedTimers }, Cmd.none )

                Just uuid ->
                    -- Leave the player's persisted state exactly as it was. The
                    -- jeopardy snapshot (mid-game screen → savedState, reset to
                    -- BeginScreen) now happens lazily on their next stateRequest
                    -- (see ClientStateRequest below), so a server stop/restart that
                    -- never fires a disconnect still resumes the player correctly.
                    ( { model
                        | connectedPlayers = Dict.remove uuid model.connectedPlayers
                        , distClients = cleanedDist
                        , iqTimers = pausedTimers
                      }
                    , Cmd.none
                    )

        MessageReceived { clientId, payload } ->
            case Decode.decodeValue decodeClientEnvelope payload of
                Ok (ClientStateRequest uuid) ->
                    if Set.member uuid model.pendingStateEdits then
                        ( model
                        , rejectAndClose { clientId = clientId, reason = "state is being edited by admin", payload = rejectEnvelope "state is being edited by admin" }
                        )

                    else if Dict.member uuid model.connectedPlayers then
                        ( model
                        , rejectAndClose { clientId = clientId, reason = "duplicate uuid", payload = rejectEnvelope "player already connected" }
                        )

                    else
                        case List.filter (\e -> e.uuid == uuid) model.registry of
                            [] ->
                                ( model
                                , rejectAndClose { clientId = clientId, reason = "unknown uuid", payload = rejectEnvelope "unknown uuid" }
                                )

                            entry :: _ ->
                                let
                                    storedState =
                                        Maybe.withDefault (Encode.object []) entry.state

                                    -- If the player left mid-game (persisted screen is
                                    -- anything other than BeginScreen), snapshot that
                                    -- screen into savedState and reset to BeginScreen so
                                    -- they resume via the jeopardy Start flow. A player
                                    -- already on BeginScreen — or one who never started
                                    -- (empty state, no screen tag) — is delivered as-is,
                                    -- leaving their savedState and jeopardyPlaying flag
                                    -- untouched.
                                    screenTag =
                                        Decode.decodeValue (Decode.at [ "screen", "tag" ] Decode.string) storedState
                                            |> Result.withDefault ""

                                    connectedModel =
                                        { model | connectedPlayers = Dict.insert uuid clientId model.connectedPlayers }
                                in
                                if screenTag == "" || screenTag == "BeginScreen" then
                                    ( connectedModel
                                    , sendToClient { clientId = clientId, payload = stateEnvelope storedState }
                                    )

                                else
                                    let
                                        snapshotted =
                                            snapshotForJeopardy storedState

                                        newRegistry =
                                            updateEntryState uuid snapshotted model.registry
                                    in
                                    ( { connectedModel | registry = newRegistry }
                                    , Cmd.batch
                                        [ writeRegistry newRegistry
                                        , sendToClient { clientId = clientId, payload = stateEnvelope snapshotted }
                                        ]
                                    )

                Ok (ClientStateUpdate inner) ->
                    case findUuidByClient clientId model.connectedPlayers of
                        Nothing ->
                            ( model, Cmd.none )

                        Just uuid ->
                            let
                                newRegistry =
                                    updateEntryState uuid inner model.registry

                                -- Deliver the win text only at win time, as its own message
                                -- (never bundled into the client), when the incoming state
                                -- shows the player is transitioning into the win screen.
                                winTextCmd =
                                    if stateIsWin inner then
                                        model.registry
                                            |> List.filter (\e -> e.uuid == uuid)
                                            |> List.head
                                            |> Maybe.map (\e -> sendToClient { clientId = clientId, payload = winTextEnvelope e.winText })
                                            |> Maybe.withDefault Cmd.none

                                    else
                                        Cmd.none
                            in
                            ( { model | registry = newRegistry }
                            , Cmd.batch
                                [ writeRegistry newRegistry
                                , sendToClient { clientId = clientId, payload = ackEnvelope }
                                , winTextCmd
                                ]
                            )

                Ok (ClientDistRegister info) ->
                    ( { model | distClients = Dict.insert clientId (AwaitingAuth info) model.distClients }
                    , requestAuth { clientId = clientId, level = 2 }
                    )

                Ok (ClientDistUpload upload) ->
                    case Dict.get clientId model.distClients of
                        Just (AwaitingUpload info) ->
                            if info.uuid == upload.uuid then
                                let
                                    binPath =
                                        "app-builds/" ++ upload.filename

                                    writeChunk =
                                        writeFile
                                            { path = binPath
                                            , contents = upload.contentsBase64
                                            , encoding = "base64"
                                            , append = upload.chunkIndex > 0
                                            }
                                in
                                if upload.isLast then
                                    let
                                        newEntry =
                                            { uuid = upload.uuid
                                            , filename = upload.filename
                                            , platform = info.platform
                                            , state = Nothing
                                            , pendingStateEdit = False
                                            , winText = ""
                                            }

                                        newRegistry =
                                            List.filter (\e -> e.filename /= upload.filename) model.registry
                                                ++ [ newEntry ]
                                    in
                                    ( { model
                                        | distClients = Dict.remove clientId model.distClients
                                        , registry = newRegistry
                                      }
                                    , Cmd.batch
                                        [ writeChunk
                                        , writeRegistry newRegistry
                                        , sendToClient { clientId = clientId, payload = ackEnvelope }
                                        ]
                                    )

                                else
                                    ( model, writeChunk )

                            else
                                ( model, Cmd.none )

                        _ ->
                            ( model, Cmd.none )

                Ok (ClientDistComplete { uuid, filename, winText }) ->
                    case Dict.get clientId model.distClients of
                        Just (AwaitingUpload info) ->
                            if info.uuid == uuid then
                                let
                                    newEntry =
                                        { uuid = uuid
                                        , filename = filename
                                        , platform = info.platform
                                        , state = Nothing
                                        , pendingStateEdit = False
                                        , winText = winText
                                        }

                                    newRegistry =
                                        List.filter (\e -> e.filename /= filename) model.registry
                                            ++ [ newEntry ]
                                in
                                ( { model
                                    | distClients = Dict.remove clientId model.distClients
                                    , registry = newRegistry
                                  }
                                , Cmd.batch
                                    [ writeRegistry newRegistry
                                    , sendToClient { clientId = clientId, payload = ackEnvelope }
                                    ]
                                )

                            else
                                ( model, Cmd.none )

                        _ ->
                            ( model, Cmd.none )

                Ok (ClientDistStateEdit uuid) ->
                    -- Gate behind admin auth: stash the target uuid and request a
                    -- level-2 challenge. The actual edit prep runs in AuthCompleted
                    -- (performStateEdit) only after auth succeeds.
                    ( { model | distClients = Dict.insert clientId (AwaitingStateEditAuth uuid) model.distClients }
                    , requestAuth { clientId = clientId, level = 2 }
                    )

                Ok (ClientDistStateEditSave { json }) ->
                    -- Authorization is owned here (replaces the JS activeStateEdits set):
                    -- only a client in the EditingState stage may save, and the stage is
                    -- consumed on every save attempt (valid or invalid), mirroring the old
                    -- JS behavior. Invalid JSON therefore leaves the uuid stuck in
                    -- pendingStateEdits -- a pre-existing quirk (see tests/edit-state.test.js).
                    case Dict.get clientId model.distClients of
                        Just (EditingState editUuid) ->
                            let
                                clearedDist =
                                    Dict.remove clientId model.distClients
                            in
                            case Decode.decodeString Decode.value json of
                                Ok parsedState ->
                                    let
                                        newRegistry =
                                            updateEntryState editUuid parsedState model.registry

                                        reconciledModel =
                                            reconcileIqTimerAfterEdit editUuid parsedState model
                                    in
                                    ( { reconciledModel
                                        | registry = newRegistry
                                        , pendingStateEdits = Set.remove editUuid model.pendingStateEdits
                                        , distClients = clearedDist
                                      }
                                    , Cmd.batch
                                        [ writeRegistry newRegistry
                                        , sendToClient { clientId = clientId, payload = ackEnvelope }
                                        ]
                                    )

                                Err _ ->
                                    ( { model | distClients = clearedDist }
                                    , sendToClient { clientId = clientId, payload = rejectEnvelope "invalid json" }
                                    )

                        _ ->
                            ( model, closeClient { clientId = clientId, reason = "unauthorized" } )

                Ok ClientDistList ->
                    ( { model | distClients = Dict.insert clientId AwaitingListAuth model.distClients }
                    , requestAuth { clientId = clientId, level = 2 }
                    )

                Ok (ClientDistReplaceComplete { newUuid, oldUuid, filename }) ->
                    case Dict.get clientId model.distClients of
                        Just (AwaitingUpload info) ->
                            if info.uuid == newUuid then
                                let
                                    oldEntry =
                                        model.registry
                                            |> List.filter (\e -> e.uuid == oldUuid)
                                            |> List.head

                                    oldState =
                                        oldEntry |> Maybe.andThen .state

                                    newEntry =
                                        { uuid = newUuid
                                        , filename = filename
                                        , platform = info.platform
                                        , state = oldState
                                        , pendingStateEdit = True
                                        , winText = oldEntry |> Maybe.map .winText |> Maybe.withDefault ""
                                        }

                                    newRegistry =
                                        List.filter (\e -> e.uuid /= oldUuid && e.filename /= filename) model.registry
                                            ++ [ newEntry ]

                                    closeOldPlayerCmd =
                                        case Dict.get oldUuid model.connectedPlayers of
                                            Just playerClientId ->
                                                closeClient { clientId = playerClientId, reason = "build replaced" }

                                            Nothing ->
                                                Cmd.none
                                in
                                -- newUuid starts locked (pendingStateEdit = True): the admin must
                                -- resolve it via distStateEdit/distStateEditSave before players can
                                -- connect or download. Note: if that save is ever invalid JSON, this
                                -- uuid is stuck the same way the pre-existing edit-state quirk gets
                                -- stuck (see tests/edit-state.test.js) -- except every replacement now
                                -- requires a save to unlock, not just an optional admin edit.
                                ( { model
                                    | distClients = Dict.remove clientId model.distClients
                                    , connectedPlayers = Dict.remove oldUuid model.connectedPlayers
                                    , registry = newRegistry
                                    , pendingStateEdits = Set.insert newUuid model.pendingStateEdits
                                  }
                                , Cmd.batch
                                    [ closeOldPlayerCmd
                                    , writeRegistry newRegistry
                                    , sendToClient { clientId = clientId, payload = ackEnvelope }
                                    ]
                                )

                            else
                                ( model, Cmd.none )

                        _ ->
                            ( model, Cmd.none )

                Ok (ClientDistUndeploy uuid) ->
                    -- Gate behind admin auth; the removal runs in AuthCompleted
                    -- (performUndeploy) only after a level-2 challenge succeeds.
                    ( { model | distClients = Dict.insert clientId (AwaitingUndeployAuth uuid) model.distClients }
                    , requestAuth { clientId = clientId, level = 2 }
                    )

                Ok ClientIqStartCountdown ->
                    -- "Player pressed Begin." The count is the server's own, never
                    -- the client's -- see startCountdown.
                    case findUuidByClient clientId model.connectedPlayers of
                        Just uuid ->
                            startCountdown uuid model

                        Nothing ->
                            ( model, Cmd.none )

                Ok ClientIqReadyForDing ->
                    case findUuidByClient clientId model.connectedPlayers of
                        Nothing ->
                            ( model, Cmd.none )

                        Just uuid ->
                            case Dict.get uuid model.iqTimers of
                                Just state ->
                                    case state.phase of
                                        IqAwaitingReady ->
                                            -- First ding after the countdown: nothing to
                                            -- advance yet, just arm the first ding.
                                            scheduleNextDing uuid state model

                                        IqDingShown ->
                                            -- The outstanding ding was resolved; advance.
                                            case advanceOnClear state of
                                                Completed ->
                                                    ( { model | iqTimers = Dict.remove uuid model.iqTimers }
                                                    , sendToPlayer uuid model iqTestCompleteEnvelope
                                                    )

                                                Advanced adv ->
                                                    let
                                                        ( m, dingCmd ) =
                                                            scheduleNextDing uuid adv.state model
                                                    in
                                                    ( m
                                                    , if adv.startLoud then
                                                        Cmd.batch [ sendToPlayer uuid model iqStartLoudEnvelope, dingCmd ]

                                                      else
                                                        dingCmd
                                                    )

                                        _ ->
                                            -- Stale/duplicate request in another phase: ignore.
                                            ( model, Cmd.none )

                                Nothing ->
                                    ( model, Cmd.none )

                Ok ClientIqCaught ->
                    -- Honor a catch only when a fake ding is actually outstanding.
                    -- The server doubles its own count and goes idle; the client is
                    -- meanwhile playing the cutscene and will send iqStartCountdown
                    -- (which resets the run) when the player presses Begin again.
                    case findUuidByClient clientId model.connectedPlayers of
                        Nothing ->
                            ( model, Cmd.none )

                        Just uuid ->
                            case Dict.get uuid model.iqTimers of
                                Just state ->
                                    if state.phase == IqDingShown && state.lastDing == TrapFake then
                                        let
                                            caught =
                                                applyCatch state
                                        in
                                        ( { model | iqTimers = Dict.insert uuid { caught | phase = IqIdle } model.iqTimers }
                                        , Cmd.none
                                        )

                                    else
                                        ( model, Cmd.none )

                                Nothing ->
                                    ( model, Cmd.none )

                Ok ClientIqResume ->
                    -- The client just restored a saved IQ screen (countdown/active)
                    -- after reconnecting. Re-arm whatever was paused for it -- a
                    -- no-op if there's nothing to resume (e.g. IqIdle, or no entry).
                    case findUuidByClient clientId model.connectedPlayers of
                        Just uuid ->
                            resumeIqTimer uuid model

                        Nothing ->
                            ( model, Cmd.none )

                _ ->
                    ( model, Cmd.none )

        AuthCompleted { clientId, success, level } ->
            let
                isAdmin =
                    success && level >= 2

                failAuth m =
                    ( { m | distClients = Dict.remove clientId m.distClients }
                    , closeClient { clientId = clientId, reason = "Auth failed" }
                    )
            in
            case Dict.get clientId model.distClients of
                Just (AwaitingAuth info) ->
                    if isAdmin then
                        ( { model | distClients = Dict.insert clientId (AwaitingUpload info) model.distClients }
                        , sendToClient { clientId = clientId, payload = ackWithUploadTokenEnvelope }
                        )

                    else
                        failAuth model

                Just (AwaitingUndeployAuth uuid) ->
                    if isAdmin then
                        performUndeploy uuid clientId model

                    else
                        failAuth model

                Just AwaitingListAuth ->
                    if isAdmin then
                        ( { model | distClients = Dict.remove clientId model.distClients }
                        , -- send-then-close in one JS tick; Cmd.batch would not guarantee ordering.
                          rejectAndClose
                            { clientId = clientId
                            , reason = "list complete"
                            , payload = distListResultEnvelope model.registry
                            }
                        )

                    else
                        failAuth model

                Just (AwaitingStateEditAuth uuid) ->
                    if isAdmin then
                        performStateEdit uuid clientId model

                    else
                        failAuth model

                _ ->
                    ( model, Cmd.none )

        FileRead path result ->
            if path == registryFilePath then
                case result of
                    Ok contents ->
                        let
                            parsedRegistry =
                                parseRegistryJsonl contents

                            -- Rehydrate in-memory WS-connect gating from the persisted
                            -- flag so it agrees with on-disk download gating after a
                            -- restart mid-edit (otherwise connects would reopen while
                            -- downloads stayed locked until the next save).
                            rehydratedPendingStateEdits =
                                parsedRegistry
                                    |> List.filter .pendingStateEdit
                                    |> List.map .uuid
                                    |> Set.fromList
                        in
                        ( { model
                            | registry = parsedRegistry
                            , pendingStateEdits = rehydratedPendingStateEdits
                          }
                        , Cmd.none
                        )

                    Err _ ->
                        ( model, Cmd.none )

            else
                ( model, Cmd.none )

        WriteFileCompleted _ ->
            ( model, Cmd.none )

        GotTime posix ->
            -- Seed the RNG from wall-clock time so ding delays / trap points vary
            -- across server runs. Arrives once at startup, before any WS message.
            ( { model | seed = Random.initialSeed (Time.posixToMillis posix) }, Cmd.none )

        CountdownStep { uuid, epoch } ->
            case Dict.get uuid model.iqTimers of
                Just state ->
                    if state.epoch == epoch && state.phase == IqCounting then
                        let
                            newRemaining =
                                state.countdownRemaining - 1
                        in
                        if newRemaining > 0 then
                            ( { model | iqTimers = Dict.insert uuid { state | countdownRemaining = newRemaining } model.iqTimers }
                            , Cmd.batch
                                [ sendToPlayer uuid model (iqCountdownTickEnvelope newRemaining)
                                , scheduleCountdownStep uuid epoch
                                ]
                            )

                        else
                            ( { model | iqTimers = Dict.insert uuid { state | countdownRemaining = 0, phase = IqAwaitingReady } model.iqTimers }
                            , sendToPlayer uuid model iqCountdownCompleteEnvelope
                            )

                    else
                        -- Stale fire (paused by a disconnect, or a newer countdown started).
                        ( model, Cmd.none )

                Nothing ->
                    ( model, Cmd.none )

        DingReady { uuid, epoch } ->
            case Dict.get uuid model.iqTimers of
                Just state ->
                    if state.epoch == epoch && state.phase == IqDingScheduled then
                        let
                            ( coin, newSeed ) =
                                Random.step IQTest.coinFlipGen model.seed

                            kind =
                                classifyDing coin state
                        in
                        ( { model
                            | iqTimers = Dict.insert uuid { state | phase = IqDingShown, lastDing = kind } model.iqTimers
                            , seed = newSeed
                          }
                        , sendToPlayer uuid
                            model
                            (iqDingEnvelope
                                { fake = dingIsFake kind
                                , trap = kind == TrapFake
                                , dingCount = state.dingCount
                                , totalDings = state.totalDings
                                }
                            )
                        )

                    else
                        ( model, Cmd.none )

                Nothing ->
                    ( model, Cmd.none )


subscriptions : Model -> Sub Msg
subscriptions _ =
    Sub.batch
        [ onConnection ClientConnected
        , onDisconnection ClientDisconnected
        , onMessage MessageReceived
        , authResult AuthCompleted
        , writeFileResult WriteFileCompleted
        , readFileResult
            (\{ path, contents, error } ->
                case ( contents, error ) of
                    ( Just c, _ ) ->
                        FileRead path (Ok c)

                    ( _, Just e ) ->
                        FileRead path (Err e)

                    _ ->
                        FileRead path (Err "unknown error")
            )
        ]


main : Program () Model Msg
main =
    Platform.worker
        { init = init
        , update = update
        , subscriptions = subscriptions
        }


port onConnection : (String -> msg) -> Sub msg

port onDisconnection : (String -> msg) -> Sub msg

port onMessage : ({ clientId : String, payload : Encode.Value } -> msg) -> Sub msg

port sendToClient : { clientId : String, payload : Encode.Value } -> Cmd msg

port closeClient : { clientId : String, reason : String } -> Cmd msg

port rejectAndClose : { clientId : String, reason : String, payload : Encode.Value } -> Cmd msg

port readFile : String -> Cmd msg

port readFileResult : ({ path : String, contents : Maybe String, error : Maybe String } -> msg) -> Sub msg

port requestAuth : { clientId : String, level : Int } -> Cmd msg

port authResult : ({ clientId : String, success : Bool, level : Int, uuid : String } -> msg) -> Sub msg

port writeFile : { path : String, contents : String, encoding : String, append : Bool } -> Cmd msg

port writeFileResult : ({ path : String, ok : Bool, error : Maybe String } -> msg) -> Sub msg

port stateEditReady : { adminClientId : String, uuid : String, json : String } -> Cmd msg

port deleteBuildFile : String -> Cmd msg
