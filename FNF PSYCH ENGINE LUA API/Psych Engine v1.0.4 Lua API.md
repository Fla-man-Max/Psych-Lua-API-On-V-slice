# Psych Engine v1.0.4 Lua API

Lua scripts use the Psych Engine 1.0.4 callback names and function names. Scripts are loaded from the active mod's `scripts` folder, plus stage, character, song, `custom_events`, and `custom_notetypes` folders.

## Script folders

```text
mods/
  scripts/
    global.lua
    options.lua
  stages/
    stage-id.lua
  characters/
    boyfriend.lua
  data/song-id/
    song.lua
  custom_events/
    My Event.lua
  custom_notetypes/
    Poison Note.lua
```

Files in `scripts` are loaded for gameplay. A script can be isolated to its file, while global scripts share the normal Psych callback behavior. Missing or failing scripts are reported and skipped so a broken optional script does not stop the song.

## Script examples

### Basic callbacks

```lua
function onCreate()
    debugPrint('song script loaded')
end

function onCreatePost()
    makeLuaText('welcome', 'Ready!', 0, 40, 40)
    setTextSize('welcome', 24)
    addLuaText('welcome')
end

function onUpdate(elapsed)
    setProperty('welcome.alpha', 0.75)
end

function onDestroy()
    removeLuaText('welcome')
end
```

### Notes and scoring

```lua
function goodNoteHit(noteId, direction, noteType, isSustainNote)
    if not isSustainNote then
        addScore(10)
    end
end

function opponentNoteHit(noteId, direction, noteType, isSustainNote)
    if noteType == 'Poison Note' then
        addHealth(-0.05)
    end
end

function noteMiss(noteId, direction, noteType, isSustainNote)
    debugPrint('missed lane ' .. direction)
end

function onSpawnNote(noteId, noteData, noteType, isSustainNote)
    if noteType == 'Ghost Note' then
        setPropertyFromGroup('notes', noteId, 'alpha', 0.6)
    end
end
```

### Events

```lua
function onEvent(name, value1, value2)
    if name == 'Flash Camera' then
        cameraFlash('game', value1 == '' and 'FFFFFF' or value1, 0.25)
    end
end

function eventEarlyTrigger(name, value1, value2)
    if name == 'Flash Camera' then
        return 0.1
    end
end

function onEventPushed(name, value1, value2, strumTime)
    debugPrint('event ' .. name .. ' at ' .. strumTime)
end
```

### Characters and camera

```lua
function onMoveCamera(focus)
    if focus == 'boyfriend' then
        setProperty('camFollow.x', getProperty('boyfriend.x') + 300)
    end
end

function onBeatHit()
    if curBeat % 4 == 0 then
        cameraShake('game', 0.01, 0.1)
    end
end

function onStepHit()
    if curStep == 128 then
        characterPlayAnim('dad', 'singUP', true)
    end
end
```

### Sprites and animation

```lua
function onCreatePost()
    makeAnimatedLuaSprite('logo', 'images/logo', 500, 80)
    addAnimationByPrefix('logo', 'idle', 'logo idle', 24, true)
    playAnim('logo', 'idle', true)
    addLuaSprite('logo', true)
    setObjectCamera('logo', 'hud')
    setObjectOrder('logo', 100)
end

function onUpdate(elapsed)
    setProperty('logo.angle', math.sin(getSongPosition() / 300) * 4)
end
```

### Text and menus

```lua
function onCreatePost()
    makeLuaText('status', 'Lua ready', 420, 20, 680)
    setTextAlignment('status', 'left')
    setTextBorder('status', 2, '000000')
    addLuaText('status', true)
end

function onUpdateScore()
    setTextString('status', 'Score: ' .. score .. '  Misses: ' .. misses)
end
```

### Tweens and timers

```lua
function onCreatePost()
    doTweenAlpha('fadeIn', 'status', 1, 1, 'quadOut')
    runTimer('hideStatus', 4)
end

function onTimerCompleted(tag, loops, loopsLeft)
    if tag == 'hideStatus' then
        doTweenAlpha('fadeOut', 'status', 0, 0.5, 'linear')
    end
end

function onTweenCompleted(tag)
    debugPrint('finished tween ' .. tag)
end
```

### Sound and music

```lua
function onSongStart()
    playSound('confirmMenu', 0.7, 'confirm')
end

function onUpdate(elapsed)
    setSoundVolume('confirm', 0.5)
end

function onDestroy()
    stopSound('confirm')
end
```

### Preferences and save data

```lua
function onCreate()
    if getPreference('downscroll') then
        debugPrint('downscroll is enabled')
    end
    initSaveData('my-mod')
    setDataFromSave('my-mod', 'timesPlayed', (getDataFromSave('my-mod', 'timesPlayed') or 0) + 1)
    flushSaveData('my-mod')
end
```

### Custom note type

`mods/custom_notetypes/Poison Note.lua`:

```lua
function onSpawnNote(noteId, noteData, noteType, isSustainNote)
    if noteType == 'Poison Note' then
        setPropertyFromGroup('notes', noteId, 'alpha', 0.7)
    end
end

function goodNoteHit(noteId, direction, noteType, isSustainNote)
    if noteType == 'Poison Note' and not isSustainNote then
        addHealth(-0.1)
    end
end
```

### Custom event

`mods/custom_events/Screen Tint.lua`:

```lua
function onEvent(name, value1, value2)
    if name == 'Screen Tint' then
        cameraFade('hud', value1, tonumber(value2) or 0.4, true)
    end
end
```

## Advanced script examples

### Shared script state

```lua
local pulse = 0

function onUpdate(elapsed)
    pulse = pulse + elapsed
    setProperty('iconP1.angle', math.sin(pulse * 3) * 5)
end
```

### Cancelable hooks

```lua
function onStartCountdown()
    if getProperty('inCutscene') then
        return Function_Stop
    end
    return Function_Continue
end

function onEndSong()
    if practiceMode then
        return Function_Stop
    end
    return Function_Continue
end
```

### Custom substates

```lua
function onCreatePost()
    openCustomSubstate('modOverlay', true)
end

function onCustomSubstateCreate(name)
    if name == 'modOverlay' then
        makeLuaText('overlayText', 'Press BACK to close', 0, 40, 40)
        addLuaText('overlayText', true)
    end
end

function onCustomSubstateUpdate(name, elapsed)
    if name == 'modOverlay' and keyJustPressed('BACKSPACE') then
        closeCustomSubstate()
    end
end
```

### Reflection and dynamic objects

```lua
function onCreatePost()
    setPropertyFromClass('flixel.FlxG', 'autoPause', false)
    local width = getPropertyFromClass('flixel.FlxG', 'width')
    debugPrint('screen width: ' .. width)
end
```

## Callback reference

The runtime supports `onCreate`, `onCreatePost`, `onUpdate`, `onUpdatePost`, `onDestroy`, `onStartCountdown`, `onCountdownStarted`, `onCountdownTick`, `onSongStart`, `onEndSong`, `onPause`, `onResume`, `onGameOver`, `onSpawnNote`, `goodNoteHitPre`, `goodNoteHit`, `opponentNoteHitPre`, `opponentNoteHit`, `noteMiss`, `noteMissPress`, `onGhostTap`, `onKeyPressPre`, `onKeyPress`, `onKeyReleasePre`, `onKeyRelease`, `onEvent`, `eventEarlyTrigger`, `onEventPushed`, `onMoveCamera`, `onStepHit`, `onBeatHit`, `onSectionHit`, `preUpdateScore`, `onUpdateScore`, `onRecalculateRating`, `onNextDialogue`, `onSkipDialogue`, `onTweenCompleted`, `onTimerCompleted`, `onSoundFinished`, `onCustomSubstateCreate`, `onCustomSubstateCreatePost`, `onCustomSubstateUpdate`, `onCustomSubstateUpdatePost`, and `onCustomSubstateDestroy`.

## Compatibility notes

`Function_Stop`, `Function_Continue`, `Function_StopLua`, `Function_StopHScript`, and `Function_StopAll` are available as normal Lua globals. HScript-only calls return `false` because this port exposes Lua without embedding a separate HScript runtime. Asset paths use the V-Slice `Paths` resolver, so a Psych-style asset name can be used without hard-coding platform-specific directories.
