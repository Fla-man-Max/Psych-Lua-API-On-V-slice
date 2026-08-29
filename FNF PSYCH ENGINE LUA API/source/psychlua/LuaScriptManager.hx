package psychlua;

#if FEATURE_PSYCH_LUA
import flixel.FlxG;
import flixel.FlxBasic;
import flixel.FlxSprite;
import flixel.FlxSubState;
import flixel.input.FlxInput.FlxInputState;
import flixel.input.keyboard.FlxKey;
import flixel.sound.FlxSound;
import flixel.text.FlxText;
import flixel.text.FlxText.FlxTextAlign;
import flixel.text.FlxText.FlxTextBorderStyle;
import flixel.tweens.FlxEase;
import flixel.tweens.FlxTween;
import flixel.util.FlxAxes;
import flixel.util.FlxColor;
import flixel.util.FlxTimer;
import flixel.util.FlxSave;
import funkin.Conductor;
import funkin.util.Constants;
import funkin.Highscore;
import funkin.Paths;
import funkin.Preferences as FunkinPreferences;
import funkin.data.event.SongEventRegistry;
import funkin.data.song.SongData.SongEventData;
import funkin.data.song.SongRegistry;
import funkin.save.Save;
import funkin.data.stage.StageRegistry;
import funkin.graphics.FunkinSprite;
import funkin.modding.events.ScriptEvent;
import funkin.modding.PolymodHandler;
import funkin.play.cutscene.VideoCutscene;
import funkin.play.PauseSubState;
import funkin.play.PlayState;
import funkin.ui.transition.LoadingState;
import funkin.ui.mainmenu.MainMenuState;
import funkin.ui.options.OptionsState;
import funkin.util.MemoryUtil;
import funkin.util.WindowUtil;
import haxe.Json;
import hxlua.Lua;
import hxlua.LuaL;
import hxlua.Types.Lua_State;
import sys.FileSystem;
import sys.io.File;
import openfl.utils.Assets as OpenFLAssets;
import openfl.display.BlendMode;
#end

class LuaScriptManager
{
  #if FEATURE_PSYCH_LUA
  public static final FUNCTION_STOP:String = '##PSYCHLUA_FUNCTIONSTOP';
  public static final FUNCTION_CONTINUE:String = '##PSYCHLUA_FUNCTIONCONTINUE';
  public static final FUNCTION_STOP_LUA:String = '##PSYCHLUA_FUNCTIONSTOPLUA';
  public static final FUNCTION_STOP_HSCRIPT:String = '##PSYCHLUA_FUNCTIONSTOPHSCRIPT';
  public static final FUNCTION_STOP_ALL:String = '##PSYCHLUA_FUNCTIONSTOPALL';
  static var activeManager:Null<LuaScriptManager>;
  var state:cpp.RawPointer<Lua_State>;
  var loadedScripts:Array<String> = [];
  var scriptGlobalModes:Map<String, Bool> = [];
  var scriptEnvRefs:Map<String, Int> = [];
  var globalScriptHookRefs:Map<String, Map<String, Int>> = [];
  var isolatedScriptHookRefs:Map<String, Map<String, Int>> = [];
  var hookPresence:Map<String, Bool> = [];
  var pathPartsCache:Map<String, Array<String>> = [];
  var sprites:Map<String, FunkinSprite> = [];
  var texts:Map<String, FlxText> = [];
  var objects:Map<String, Dynamic> = [];
  var sounds:Map<String, FlxSound> = [];
  var tweens:Map<String, FlxTween> = [];
  var timers:Map<String, FlxTimer> = [];
  var saveData:Map<String, FlxSave> = [];
  var customSubstate:Null<FlxSubState>;
  var customSubstateName:String = '';
  var optionManager:Dynamic;
  var menuManager:Dynamic;
  var shaderManager:LuaShaderManager;
  var disabledHooks:Map<String, Bool> = [];
  var scriptPriorities:Map<String, Int> = [];
  var scriptPriorityDirty:Bool = false;
  var currentEvent:Null<ScriptEvent> = null;
  var currentLuaFiles:Array<String> = [];
  var mainMenuState:Null<MainMenuState> = null;
  var pauseMenuState:Null<PauseSubState> = null;
  var pauseMenuConfig:Dynamic = null;
  var pauseMenuConfiguredThisPass:Bool = false;

  public function new()
  {
    state = LuaL.newstate();
    LuaL.openlibs(state);
    activeManager = this;
    optionManager = null;
    menuManager = null;
    shaderManager = new LuaShaderManager();
    configurePackagePath();
    registerAPI();
  }

  public function loadScript(path:String):Bool
  {
    if (!FileSystem.exists(path))
    {
      reportLuaWarning('missing-script', path, null, 'Script does not exist: ${path}');
      return false;
    }

    updateGlobals();

    final isGlobalScript = isGlobalScript(path);
    final previousGlobalHooks = isGlobalScript ? snapshotGlobalHooks() : null;
    final envRef = isGlobalScript ? LuaL.NOREF : createScriptEnvironment();

    try
    {
      if (LuaL.loadfile(state, path) != Lua.OK)
      {
        final error = readError();
        trace('[LuaScriptManager] Failed to load ${path}: ${error}');
        LuaErrorManager.report('load-error', path, null, error);
        if (previousGlobalHooks != null)
        {
          restoreGlobalHooks(previousGlobalHooks);
          releaseHookRefs(previousGlobalHooks);
        }
        if (envRef != LuaL.NOREF) LuaL.unref(state, Lua.REGISTRYINDEX, envRef);
        return false;
      }

      if (!isGlobalScript)
      {
        Lua.rawgeti(state, Lua.REGISTRYINDEX, envRef);
        Lua.setupvalue(state, -2, 1);
      }

      if (Lua.pcall(state, 0, 0, 0) != Lua.OK)
      {
        final error = readError();
        trace('[LuaScriptManager] Failed to run ${path}: ${error}');
        LuaErrorManager.report('run-error', path, null, error);
        if (previousGlobalHooks != null)
        {
          restoreGlobalHooks(previousGlobalHooks);
          releaseHookRefs(previousGlobalHooks);
        }
        if (envRef != LuaL.NOREF) LuaL.unref(state, Lua.REGISTRYINDEX, envRef);
        return false;
      }
    }
    catch (e)
    {
      final error = Std.string(e);
      trace('[LuaScriptManager] Failed to load/run ${path}: ${error}');
      LuaErrorManager.report('haxe-load-error', path, null, error);
      if (previousGlobalHooks != null)
      {
        restoreGlobalHooks(previousGlobalHooks);
        releaseHookRefs(previousGlobalHooks);
      }
      if (envRef != LuaL.NOREF) LuaL.unref(state, Lua.REGISTRYINDEX, envRef);
      return false;
    }

    if (isGlobalScript && previousGlobalHooks != null)
    {
      releaseGlobalScriptHooks(path);
      captureChangedGlobalHooks(path, previousGlobalHooks);
      releaseHookRefs(previousGlobalHooks);
    }
    else if (!isGlobalScript && envRef != LuaL.NOREF)
    {
      releaseIsolatedScriptHooks(path);
      captureEnvironmentHooks(path, envRef);
    }

    if (!loadedScripts.contains(path)) loadedScripts.push(path);
    scriptGlobalModes.set(path, isGlobalScript);
    if (envRef != LuaL.NOREF) scriptEnvRefs.set(path, envRef);
    hookPresence.clear();
    trace('[LuaScriptManager] Loaded ${path} (${isGlobalScript ? 'global' : 'isolated'})');
    LuaLogger.scripts(loadedScripts);
    return true;
  }

  public function reloadScripts():Bool
  {
    if (state == null || loadedScripts.length == 0) return false;

    var scriptsToReload = loadedScripts.copy();
    callHook('onDestroy', []);
    clearRuntimeObjects();
    disabledHooks.clear();

    Lua.close(state);
    state = LuaL.newstate();
    LuaL.openlibs(state);
    activeManager = this;
    configurePackagePath();
    registerAPI();

    loadedScripts = [];
    scriptGlobalModes.clear();
    scriptEnvRefs.clear();
    globalScriptHookRefs.clear();
    isolatedScriptHookRefs.clear();
    hookPresence.clear();
    pathPartsCache.clear();
    scriptPriorities.clear();
    scriptPriorityDirty = false;
    var loadedAny = false;
    var seen:Map<String, Bool> = [];
    for (scriptPath in scriptsToReload)
    {
      if (seen.exists(scriptPath)) continue;
      seen.set(scriptPath, true);
      if (loadScript(scriptPath)) loadedAny = true;
    }

    if (loadedAny)
    {
      callHook('onCreate', []);
      callHook('onReload', []);
      trace('[LuaScriptManager] Hot-reloaded ${loadedScripts.length} Lua script(s).');
      LuaLogger.scripts(loadedScripts);
    }

    return loadedAny;
  }

  public function getLoadedScriptCount():Int
  {
    return loadedScripts.length;
  }

  public function callHook(name:String, args:Array<Dynamic>):Void
  {
    if (state == null || loadedScripts.length == 0) return;

    if (scriptPriorityDirty)
    {
      loadedScripts.sort(function(a, b) return (scriptPriorities.get(b) ?? 0) - (scriptPriorities.get(a) ?? 0));
      scriptPriorityDirty = false;
    }

    activeManager = this;
    if (!hasHook(name)) return;

    updateGlobals();
    try
    {
      callGlobalHook(name, args);
    }
    catch (e)
    {
      final hookKey = 'global:${name}';
      final error = Std.string(e);
      trace('[LuaScriptManager] Haxe error in global ${name}, disabling this Lua hook: ${error}');
      disabledHooks.set(hookKey, true);
      LuaErrorManager.report('hook-haxe-error', 'global', name, error);
    }

    for (scriptPath in loadedScripts)
    {
      if (scriptGlobalModes.get(scriptPath) == true) continue;
      try
      {
        callScriptHook(scriptPath, name, args);
      }
      catch (e)
      {
        final hookKey = '${scriptPath}:${name}';
        final error = Std.string(e);
        trace('[LuaScriptManager] Haxe error in ${scriptPath} ${name}, disabling this Lua hook: ${error}');
        disabledHooks.set(hookKey, true);
        LuaErrorManager.report('hook-haxe-error', scriptPath, name, error);
      }
    }

    invalidateMissingHooks();
  }

  public function callChartEventsPushed(events:Array<SongEventData>):Void
  {
    if (events == null) return;
    for (eventData in events)
    {
      final values = psychEventValues(eventData.value);
      callHook('onEventPushed', [eventData.eventKind, values[0], values[1], eventData.time]);
    }
  }

  public function callHookResult(name:String, args:Array<Dynamic>):Dynamic
  {
    if (state == null || loadedScripts.length == 0 || !hasHook(name)) return FUNCTION_CONTINUE;

    updateGlobals();
    var result:Dynamic = FUNCTION_CONTINUE;
    var capturedGlobalHook:Bool = false;
    for (scriptPath in loadedScripts)
    {
      if (scriptGlobalModes.get(scriptPath) != true) continue;
      final scriptHooks = globalScriptHookRefs.get(scriptPath);
      if (scriptHooks == null || !scriptHooks.exists(name)) continue;
      capturedGlobalHook = true;
      final scriptResult = callGlobalScriptHookResult(scriptPath, name, args);
      if (scriptResult == FUNCTION_STOP || scriptResult == FUNCTION_STOP_LUA || scriptResult == FUNCTION_STOP_ALL) return scriptResult;
      if (scriptResult != null && scriptResult != FUNCTION_CONTINUE) result = scriptResult;
    }
    if (!capturedGlobalHook)
    {
      final globalResult = callGlobalHookResult(name, args);
      if (globalResult == FUNCTION_STOP || globalResult == FUNCTION_STOP_LUA || globalResult == FUNCTION_STOP_ALL) return globalResult;
      if (globalResult != null && globalResult != FUNCTION_CONTINUE) result = globalResult;
    }
    for (scriptPath in loadedScripts)
    {
      if (scriptGlobalModes.get(scriptPath) == true) continue;
      final scriptResult = callScriptHookResult(scriptPath, name, args);
      if (scriptResult == FUNCTION_STOP || scriptResult == FUNCTION_STOP_LUA || scriptResult == FUNCTION_STOP_ALL) return scriptResult;
      if (scriptResult != null && scriptResult != FUNCTION_CONTINUE) result = scriptResult;
    }
    invalidateMissingHooks();
    return result;
  }

  function callGlobalHookResult(name:String, args:Array<Dynamic>):Dynamic
  {
    final hookKey = 'global:${name}';
    if (disabledHooks.exists(hookKey)) return FUNCTION_CONTINUE;

    Lua.getglobal(state, name);
    if (Lua.type(state, -1) != Lua.TFUNCTION)
    {
      Lua.pop(state, 1);
      return FUNCTION_CONTINUE;
    }

    for (arg in args) pushValue(arg);

    final previousLuaFiles = currentLuaFiles;
    currentLuaFiles = ['global'];
    final callResult = Lua.pcall(state, args.length, 1, 0);
    currentLuaFiles = previousLuaFiles;
    if (callResult != Lua.OK)
    {
      final error = readError();
      disabledHooks.set(hookKey, true);
      LuaErrorManager.report('hook-error', 'global', name, error, ['global']);
      return FUNCTION_CONTINUE;
    }

    final value = readValue(state, -1);
    Lua.pop(state, 1);
    return value;
  }

  function callScriptHookResult(scriptPath:String, name:String, args:Array<Dynamic>):Dynamic
  {
    final hookKey = '${scriptPath}:${name}';
    if (disabledHooks.exists(hookKey)) return FUNCTION_CONTINUE;

    final scriptHooks = isolatedScriptHookRefs.get(scriptPath);
    final hookRef = scriptHooks?.get(name);
    if (hookRef == null) return FUNCTION_CONTINUE;

    Lua.rawgeti(state, Lua.REGISTRYINDEX, hookRef);
    if (Lua.type(state, -1) != Lua.TFUNCTION)
    {
      Lua.pop(state, 1);
      return FUNCTION_CONTINUE;
    }

    for (arg in args) pushValue(arg);

    final previousLuaFiles = currentLuaFiles;
    currentLuaFiles = [scriptPath];
    final callResult = Lua.pcall(state, args.length, 1, 0);
    currentLuaFiles = previousLuaFiles;
    if (callResult != Lua.OK)
    {
      final error = readError();
      disabledHooks.set(hookKey, true);
      LuaErrorManager.report('hook-error', scriptPath, name, error, [scriptPath]);
      return FUNCTION_CONTINUE;
    }

    final value = readValue(state, -1);
    Lua.pop(state, 1);
    return value;
  }

  function hasHook(name:String):Bool
  {
    final cached = hookPresence.get(name);
    if (cached != null) return cached;

    for (scriptPath in loadedScripts)
    {
      if (scriptGlobalModes.get(scriptPath) != true) continue;
      final hooks = globalScriptHookRefs.get(scriptPath);
      if (hooks != null && hooks.exists(name))
      {
        hookPresence.set(name, true);
        return true;
      }
    }

    Lua.getglobal(state, name);
    final globalFound = Lua.type(state, -1) == Lua.TFUNCTION;
    Lua.pop(state, 1);
    if (globalFound)
    {
      hookPresence.set(name, true);
      return true;
    }

    for (scriptPath in loadedScripts)
    {
      if (scriptGlobalModes.get(scriptPath) == true) continue;
      final hooks = isolatedScriptHookRefs.get(scriptPath);
      if (hooks != null && hooks.exists(name))
      {
        hookPresence.set(name, true);
        return true;
      }
    }

    hookPresence.set(name, false);
    return false;
  }

  function invalidateMissingHooks():Void
  {
    final missing = [for (name => present in hookPresence) if (!present) name];
    for (name in missing) hookPresence.remove(name);
  }

  function callGlobalHook(name:String, args:Array<Dynamic>):Void
  {
    var capturedHookCount = 0;
    for (scriptPath in loadedScripts)
    {
      if (scriptGlobalModes.get(scriptPath) != true) continue;
      final scriptHooks = globalScriptHookRefs.get(scriptPath);
      if (scriptHooks == null || !scriptHooks.exists(name)) continue;
      capturedHookCount++;
      callGlobalScriptHook(scriptPath, name, args);
    }

    if (capturedHookCount > 0) return;

    final hookKey = 'global:${name}';
    if (disabledHooks.exists(hookKey)) return;

    Lua.getglobal(state, name);

    if (Lua.type(state, -1) != Lua.TFUNCTION)
    {
      Lua.settop(state, -2);
      return;
    }

    for (arg in args)
    {
      pushValue(arg);
    }

    var previousLuaFiles = currentLuaFiles;
    currentLuaFiles = ['global'];
    var callResult = Lua.pcall(state, args.length, 0, 0);
    currentLuaFiles = previousLuaFiles;

    if (callResult != Lua.OK)
    {
      final error = readError();
      trace('[LuaScriptManager] Error in global ${name}, disabling this Lua hook: ${error}');
      disabledHooks.set(hookKey, true);
      LuaErrorManager.report('hook-error', 'global', name, error, ['global']);
    }
  }

  function callGlobalScriptHook(scriptPath:String, name:String, args:Array<Dynamic>):Void
  {
    final hookKey = '${scriptPath}:${name}';
    if (disabledHooks.exists(hookKey)) return;

    final scriptHooks = globalScriptHookRefs.get(scriptPath);
    if (scriptHooks == null) return;

    final hookRef = scriptHooks.get(name);
    if (hookRef == null) return;

    Lua.rawgeti(state, Lua.REGISTRYINDEX, hookRef);

    if (Lua.type(state, -1) != Lua.TFUNCTION)
    {
      Lua.pop(state, 1);
      return;
    }

    for (arg in args)
    {
      pushValue(arg);
    }

    var previousLuaFiles = currentLuaFiles;
    currentLuaFiles = [scriptPath];
    var callResult = Lua.pcall(state, args.length, 0, 0);
    currentLuaFiles = previousLuaFiles;

    if (callResult != Lua.OK)
    {
      final error = readError();
      trace('[LuaScriptManager] Error in ${scriptPath} ${name}, disabling this Lua hook: ${error}');
      disabledHooks.set(hookKey, true);
      LuaErrorManager.report('hook-error', scriptPath, name, error, [scriptPath]);
    }
  }

  function callGlobalScriptHookResult(scriptPath:String, name:String, args:Array<Dynamic>):Dynamic
  {
    final hookKey = '${scriptPath}:${name}';
    if (disabledHooks.exists(hookKey)) return FUNCTION_CONTINUE;

    final scriptHooks = globalScriptHookRefs.get(scriptPath);
    if (scriptHooks == null) return FUNCTION_CONTINUE;

    final hookRef = scriptHooks.get(name);
    if (hookRef == null) return FUNCTION_CONTINUE;

    Lua.rawgeti(state, Lua.REGISTRYINDEX, hookRef);
    if (Lua.type(state, -1) != Lua.TFUNCTION)
    {
      Lua.pop(state, 1);
      return FUNCTION_CONTINUE;
    }

    for (arg in args) pushValue(arg);

    final previousLuaFiles = currentLuaFiles;
    currentLuaFiles = [scriptPath];
    final callResult = Lua.pcall(state, args.length, 1, 0);
    currentLuaFiles = previousLuaFiles;
    if (callResult != Lua.OK)
    {
      final error = readError();
      disabledHooks.set(hookKey, true);
      LuaErrorManager.report('hook-error', scriptPath, name, error, [scriptPath]);
      return FUNCTION_CONTINUE;
    }

    final value = readValue(state, -1);
    Lua.pop(state, 1);
    return value;
  }

  function callScriptHook(scriptPath:String, name:String, args:Array<Dynamic>):Void
  {
    final hookKey = '${scriptPath}:${name}';
    if (disabledHooks.exists(hookKey)) return;

    final scriptHooks = isolatedScriptHookRefs.get(scriptPath);
    if (scriptHooks == null) return;

    final hookRef = scriptHooks.get(name);
    if (hookRef == null) return;

    Lua.rawgeti(state, Lua.REGISTRYINDEX, hookRef);

    if (Lua.type(state, -1) != Lua.TFUNCTION)
    {
      Lua.pop(state, 1);
      return;
    }

    for (arg in args)
    {
      pushValue(arg);
    }

    var previousLuaFiles = currentLuaFiles;
    currentLuaFiles = [scriptPath];
    var callResult = Lua.pcall(state, args.length, 0, 0);
    currentLuaFiles = previousLuaFiles;

    if (callResult != Lua.OK)
    {
      final error = readError();
      trace('[LuaScriptManager] Error in ${scriptPath} ${name}, disabling this Lua hook: ${error}');
      disabledHooks.set(hookKey, true);
      LuaErrorManager.report('hook-error', scriptPath, name, error, [scriptPath]);
    }
  }

  public function callEvent(event:ScriptEvent):Void
  {
    var previousEvent = currentEvent;
    currentEvent = event;

    var type = Std.string(event.type);
    var payload = eventToPayload(event);

    switch (type)
    {
      case 'UPDATE':
        final elapsed:Float = numericField(event, 'elapsed', 0);
        callHook('onUpdate', [elapsed]);
        callHook('onUpdatePost', [elapsed]);
      case 'COUNTDOWN_START':
        cancelForStop(event, callHookResult('onStartCountdown', []));
      case 'COUNTDOWN_STEP':
        callHook('onCountdownTick', [countdownStepIndex(safeField(event, 'step'))]);
      case 'COUNTDOWN_END':
        callHook('onCountdownStarted', []);
      case 'SONG_START':
        callHook('onSongStart', []);
      case 'SONG_END':
        cancelForStop(event, callHookResult('onEndSong', []));
      case 'PAUSE':
        cancelForStop(event, callHookResult('onPause', []));
      case 'RESUME':
        cancelForStop(event, callHookResult('onResume', []));
      case 'GAME_OVER':
        cancelForStop(event, callHookResult('onGameOver', []));
      case 'SONG_BEAT_HIT':
        callHook('onBeatHit', []);
      case 'SONG_STEP_HIT':
        callHook('onStepHit', []);
        final step = Std.int(numericField(event, 'step', Conductor.instance.currentStep));
        if (step % 16 == 0) callHook('onSectionHit', []);
      case 'NOTE_INCOMING':
        final note = safeField(event, 'note');
        callHook('onSpawnNote', psychNoteArguments(note, false));
      case 'NOTE_HIT':
        final note = safeField(event, 'note');
        final arguments = psychNoteArguments(note, false);
        final isPlayer = isPlayerNote(note);
        final preHook = isPlayer ? 'goodNoteHitPre' : 'opponentNoteHitPre';
        cancelForStop(event, callHookResult(preHook, arguments));
        if (!event.eventCanceled) callHook(isPlayer ? 'goodNoteHit' : 'opponentNoteHit', arguments);
      case 'NOTE_MISS':
        callHook('noteMiss', psychNoteArguments(safeField(event, 'note'), false));
      case 'NOTE_HOLD_DROP':
        callHook('noteMiss', psychHoldArguments(safeField(event, 'holdNote')));
      case 'NOTE_GHOST_MISS':
        final direction = Std.int(numericField(event, 'dir', 0));
        callHook('noteMissPress', [direction]);
        callHook('onGhostTap', [direction]);
      case 'SONG_EVENT':
        final data = safeField(event, 'eventData');
        final eventName = Std.string(safeField(data, 'eventKind'));
        final values = psychEventValues(safeField(data, 'value'));
        cancelForStop(event, callHookResult('onEvent', [eventName, values[0], values[1]]));
      case 'KEY_DOWN':
        final input = safeField(event, 'event');
        final keyCode = Std.int(numericField(input, 'keyCode', 0));
        callHook('onKeyPressPre', [keyCode]);
        callHook('onKeyPress', [keyCode]);
      case 'KEY_UP':
        final input = safeField(event, 'event');
        final keyCode = Std.int(numericField(input, 'keyCode', 0));
        callHook('onKeyReleasePre', [keyCode]);
        callHook('onKeyRelease', [keyCode]);
      case 'SUBSTATE_OPEN_BEGIN':
        callHook('onCustomSubstateCreate', [Std.string(safeField(payload, 'name'))]);
      case 'SUBSTATE_OPEN_END':
        callHook('onCustomSubstateCreatePost', [Std.string(safeField(payload, 'name'))]);
      case 'SUBSTATE_CLOSE_BEGIN':
        callHook('onCustomSubstateDestroy', [Std.string(safeField(payload, 'name'))]);
      case 'DIALOGUE_START':
        callHook('onNextDialogue', [0]);
      case 'DIALOGUE_LINE':
        callHook('onNextDialogue', [0]);
      case 'DIALOGUE_SKIP':
        callHook('onSkipDialogue', [0]);
      case 'DIALOGUE_END':
        callHook('onDialogueEnd', [payload]);
      default:
    }

    currentEvent = previousEvent;
  }

  function cancelForStop(event:ScriptEvent, result:Dynamic):Void
  {
    if (result == FUNCTION_STOP || result == FUNCTION_STOP_ALL || result == FUNCTION_STOP_LUA) event.cancelEvent();
  }

  function numericField(target:Dynamic, field:String, fallback:Float):Float
  {
    final value = safeField(target, field);
    if (value == null) return fallback;
    final parsed = Std.parseFloat(Std.string(value));
    return Math.isNaN(parsed) ? fallback : parsed;
  }

  function countdownStepIndex(step:Dynamic):Int
  {
    if (step == null) return 0;
    final value = Std.string(step).toUpperCase();
    return switch (value)
    {
      case 'THREE': 0;
      case 'TWO': 1;
      case 'ONE': 2;
      case 'GO': 3;
      case 'START': 4;
      default: Std.parseInt(value) ?? 0;
    }
  }

  function isPlayerNote(note:Dynamic):Bool
  {
    final noteData = safeField(note, 'noteData');
    if (noteData == null) return true;
    final getStrumlineIndex = safeField(noteData, 'getStrumlineIndex');
    if (getStrumlineIndex == null) return true;
    return Reflect.callMethod(noteData, getStrumlineIndex, []) == 0;
  }

  function psychNoteArguments(note:Dynamic, sustain:Bool):Array<Dynamic>
  {
    if (note == null) return [-1, 0, '', sustain];
    final noteData = safeField(note, 'noteData');
    final index = findNoteIndex(note);
    final direction = Std.int(numericField(note, 'direction', numericField(noteData, 'data', 0))) % 4;
    final kindValue = safeField(note, 'kind') ?? safeField(noteData, 'kind');
    return [index, direction, kindValue == null ? '' : Std.string(kindValue), sustain];
  }

  function psychHoldArguments(holdNote:Dynamic):Array<Dynamic>
  {
    if (holdNote == null) return [-1, 0, '', true];
    final noteData = safeField(holdNote, 'noteData');
    final direction = Std.int(numericField(holdNote, 'noteDirection', numericField(noteData, 'data', 0))) % 4;
    final kindValue = safeField(noteData, 'kind');
    return [-1, direction, kindValue == null ? '' : Std.string(kindValue), true];
  }

  function findNoteIndex(note:Dynamic):Int
  {
    final playState = PlayState.instance;
    if (playState == null) return -1;
    var index = playState.playerStrumline.notes.members.indexOf(note);
    if (index >= 0) return index;
    index = playState.opponentStrumline.notes.members.indexOf(note);
    return index < 0 ? -1 : playState.playerStrumline.notes.members.length + index;
  }

  function psychEventValues(value:Dynamic):Array<String>
  {
    if (value == null) return ['', ''];
    if (Std.isOfType(value, Array))
    {
      final values:Array<Dynamic> = cast value;
      return [values.length > 0 ? Std.string(values[0]) : '', values.length > 1 ? Std.string(values[1]) : ''];
    }
    final value1 = safeField(value, 'value1') ?? safeField(value, 'v1');
    final value2 = safeField(value, 'value2') ?? safeField(value, 'v2');
    if (value1 != null || value2 != null) return [value1 == null ? '' : Std.string(value1), value2 == null ? '' : Std.string(value2)];
    return [Std.isOfType(value, String) ? cast value : Json.stringify(value), ''];
  }

  public function destroy():Void
  {
    if (state == null) return;

    clearRuntimeObjects();
    Lua.close(state);
    state = null;
    loadedScripts = [];
    scriptGlobalModes.clear();
    scriptEnvRefs.clear();
    globalScriptHookRefs.clear();
    isolatedScriptHookRefs.clear();
    hookPresence.clear();
    pathPartsCache.clear();
    if (activeManager == this) activeManager = null;
  }

  public static function loadGameplayScriptsForState(playState:PlayState):Null<LuaScriptManager>
  {
    if (playState == null) return null;

    var roots:Array<String> = ['mods'];
    for (modDir in PolymodHandler.loadedModDirs)
    {
      final root = 'mods/${modDir}';
      if (!roots.contains(root)) roots.push(root);
    }

    var scriptPaths:Array<String> = [];
    for (root in roots) collectScriptFolder('${root}/scripts', scriptPaths, '.lua');

    final stageId = playState.currentStageId;
    if (stageId != '') addFirstExistingScript(roots, 'stages/${stageId}.lua', scriptPaths);

    if (playState.currentStage != null)
    {
      final characterIds:Array<String> = [];
      final boyfriend = playState.currentStage.getBoyfriend();
      final dad = playState.currentStage.getDad();
      final girlfriend = playState.currentStage.getGirlfriend();
      if (boyfriend != null) characterIds.push(boyfriend.characterId);
      if (dad != null && !characterIds.contains(dad.characterId)) characterIds.push(dad.characterId);
      if (girlfriend != null && !characterIds.contains(girlfriend.characterId)) characterIds.push(girlfriend.characterId);
      for (characterId in characterIds) addFirstExistingScript(roots, 'characters/${characterId}.lua', scriptPaths);
    }

    final chart = playState.currentChart;
    if (chart != null)
    {
      final noteKinds:Array<String> = [];
      for (note in chart.notes)
      {
        final kind = note.kind;
        if (kind != null && kind != '' && !noteKinds.contains(kind)) noteKinds.push(kind);
      }
      for (kind in noteKinds) addFirstExistingScript(roots, 'custom_notetypes/${kind}.lua', scriptPaths);

      final eventKinds:Array<String> = [];
      for (eventData in chart.getEvents())
      {
        final kind = eventData.eventKind;
        if (kind != '' && !eventKinds.contains(kind)) eventKinds.push(kind);
      }
      for (kind in eventKinds) addFirstExistingScript(roots, 'custom_events/${kind}.lua', scriptPaths);
    }

    for (root in roots) collectScriptFolder('${root}/data/${playState.currentSong.id}', scriptPaths, '.lua');

    var manager:Null<LuaScriptManager> = null;
    final loaded:Map<String, Bool> = [];
    for (scriptPath in scriptPaths)
    {
      final normalized = StringTools.replace(scriptPath, '\\', '/');
      if (loaded.exists(normalized) || !FileSystem.exists(scriptPath) || FileSystem.isDirectory(scriptPath)) continue;
      if (manager == null) manager = new LuaScriptManager();
      if (manager.loadScript(scriptPath)) loaded.set(normalized, true);
    }
    if (manager != null && chart != null) manager.callChartEventsPushed(chart.getEvents());
    return manager;
  }

  static function addFirstExistingScript(roots:Array<String>, relativePath:String, scriptPaths:Array<String>):Void
  {
    var index = roots.length - 1;
    while (index >= 0)
    {
      final path = '${roots[index]}/${relativePath}';
      if (FileSystem.exists(path) && !FileSystem.isDirectory(path))
      {
        scriptPaths.push(path);
        return;
      }
      index--;
    }
  }

  public static function loadOptionsScriptsForState(optionsState:OptionsState):Null<LuaScriptManager>
  {
    var scriptPaths:Array<String> = [];
    collectOptionLuaScripts('mods/scripts/options', scriptPaths, '.luag');
    collectOptionLuaScripts('mods/scripts/options', scriptPaths, '.lua');

    if (FileSystem.exists('mods') && FileSystem.isDirectory('mods'))
    {
      for (modName in FileSystem.readDirectory('mods'))
      {
        var modPath = 'mods/${modName}';
        if (!FileSystem.isDirectory(modPath) || modName == 'scripts') continue;
        collectOptionLuaScripts('${modPath}/scripts/options', scriptPaths, '.luag');
        collectOptionLuaScripts('${modPath}/scripts/options', scriptPaths, '.lua');
      }
    }

    var manager:Null<LuaScriptManager> = null;
    var loaded:Map<String, Bool> = [];
    for (scriptPath in scriptPaths)
    {
      if (!FileSystem.exists(scriptPath) || loaded.exists(scriptPath)) continue;
      if (manager == null) manager = new LuaScriptManager();
      manager.loadScript(scriptPath);
      loaded.set(scriptPath, true);
    }

    if (manager != null)
    {
      manager.callHook('onCreate', []);
      manager.optionManager.attachToOptionsState(optionsState);
    }

    return manager;
  }

  public static function loadMainMenuScriptsForState(mainMenuState:MainMenuState):Null<LuaScriptManager>
  {
    var scriptPaths:Array<String> = [];
    collectScriptFolder('mods/scripts/menu', scriptPaths, '.luag');
    collectScriptFolder('mods/scripts/menu', scriptPaths, '.lua');

    if (FileSystem.exists('mods') && FileSystem.isDirectory('mods'))
    {
      for (modName in FileSystem.readDirectory('mods'))
      {
        var modPath = 'mods/${modName}';
        if (!FileSystem.isDirectory(modPath) || modName == 'scripts') continue;
        collectScriptFolder('${modPath}/scripts/menu', scriptPaths, '.luag');
        collectScriptFolder('${modPath}/scripts/menu', scriptPaths, '.lua');
      }
    }

    var manager:Null<LuaScriptManager> = null;
    var loaded:Map<String, Bool> = [];
    for (scriptPath in scriptPaths)
    {
      if (!FileSystem.exists(scriptPath) || loaded.exists(scriptPath)) continue;
      if (manager == null)
      {
        manager = new LuaScriptManager();
        manager.mainMenuState = mainMenuState;
      }
      manager.loadScript(scriptPath);
      loaded.set(scriptPath, true);
    }

    if (manager != null) manager.callHook('onCreate', []);
    return manager;
  }

  public static function loadFreeplayScriptsForState(freeplayState:Dynamic):Null<LuaScriptManager>
  {
    return loadStateFolderScripts('freeplay', 'onFreeplayCreate');
  }

  public static function loadStoryScriptsForState(storyState:Dynamic):Null<LuaScriptManager>
  {
    return loadStateFolderScripts('story', 'onStoryCreate');
  }

  public static function loadResultsScriptsForState(resultsState:Dynamic):Null<LuaScriptManager>
  {
    return loadStateFolderScripts('results', 'onResultsCreate');
  }

  public static function loadClassScriptsForState(stateInstance:Dynamic):Null<LuaScriptManager>
  {
    if (stateInstance == null) return null;
    final stateClass = Type.getClass(stateInstance);
    if (stateClass == null) return null;
    final fullClassName = Type.getClassName(stateClass) ?? '';
    final classParts = fullClassName.split('.');
    final className = classParts.length == 0 ? fullClassName : classParts[classParts.length - 1];
    if (className == '') return null;

    var scriptPaths:Array<String> = [];
    collectScriptFolder('assets/scripts/engine', scriptPaths, '.luag');
    addClassScriptPaths('mods', className, scriptPaths);

    if (FileSystem.exists('mods') && FileSystem.isDirectory('mods'))
    {
      for (modName in FileSystem.readDirectory('mods'))
      {
        final modPath = 'mods/${modName}';
        if (!FileSystem.isDirectory(modPath) || modName == 'scripts') continue;
        addClassScriptPaths(modPath, className, scriptPaths);
      }
    }

    var manager:Null<LuaScriptManager> = null;
    var loaded:Map<String, Bool> = [];
    for (scriptPath in scriptPaths)
    {
      if (!FileSystem.exists(scriptPath) || loaded.exists(scriptPath)) continue;
      if (manager == null) manager = new LuaScriptManager();
      manager.loadScript(scriptPath);
      loaded.set(scriptPath, true);
    }
    return manager;
  }

  static function addClassScriptPaths(root:String, className:String, scriptPaths:Array<String>):Void
  {
    scriptPaths.push('${root}/${className}.luag');
    scriptPaths.push('${root}/scripts/${className}.luag');
    scriptPaths.push('${root}/scripts/states/${className}.luag');
  }

  static function loadStateFolderScripts(folderName:String, createHook:String):Null<LuaScriptManager>
  {
    var scriptPaths:Array<String> = [];
    collectScriptFolder('mods/scripts/${folderName}', scriptPaths, '.luag');
    collectScriptFolder('mods/scripts/${folderName}', scriptPaths, '.lua');

    if (FileSystem.exists('mods') && FileSystem.isDirectory('mods'))
    {
      for (modName in FileSystem.readDirectory('mods'))
      {
        var modPath = 'mods/${modName}';
        if (!FileSystem.isDirectory(modPath) || modName == 'scripts') continue;
        collectScriptFolder('${modPath}/scripts/${folderName}', scriptPaths, '.luag');
        collectScriptFolder('${modPath}/scripts/${folderName}', scriptPaths, '.lua');
      }
    }

    var manager:Null<LuaScriptManager> = null;
    var loaded:Map<String, Bool> = [];
    for (scriptPath in scriptPaths)
    {
      if (!FileSystem.exists(scriptPath) || loaded.exists(scriptPath)) continue;
      if (manager == null) manager = new LuaScriptManager();
      manager.loadScript(scriptPath);
      loaded.set(scriptPath, true);
    }

    if (manager != null) manager.callHook(createHook, []);
    return manager;
  }

  public function beginPauseMenu(pauseMenuState:PauseSubState):Void
  {
    this.pauseMenuState = pauseMenuState;
    pauseMenuConfiguredThisPass = false;
  }

  public function endPauseMenu():Void
  {
    this.pauseMenuState = null;
    pauseMenuConfiguredThisPass = false;
  }

  public function configureLuaPauseMenu(config:Dynamic):Bool
  {
    if (config == null) return false;
    ensureLuaPauseMenuConfig();

    if (Reflect.hasField(config, 'mode')) Reflect.setField(pauseMenuConfig, 'mode', Reflect.field(config, 'mode'));
    if (Reflect.hasField(config, 'options')) Reflect.setField(pauseMenuConfig, 'options', Reflect.field(config, 'options'));

    var incomingItems:Dynamic = Reflect.field(config, 'items');
    if (Std.isOfType(incomingItems, Array))
    {
      for (item in cast(incomingItems, Array<Dynamic>)) upsertLuaPauseMenuItem(item);
    }

    applyLuaPauseMenuConfig();
    return true;
  }

  public function setLuaPauseMenuItem(matchOrId:String, label:String, position:Int, target:String, hidden:Bool):Bool
  {
    if (matchOrId == '') return false;
    ensureLuaPauseMenuConfig();
    var items:Dynamic = Reflect.field(pauseMenuConfig, 'items');
    if (!Std.isOfType(items, Array))
    {
      items = [];
      Reflect.setField(pauseMenuConfig, 'items', items);
    }

    var item:Dynamic = {};
    Reflect.setField(item, 'match', matchOrId);
    Reflect.setField(item, 'id', matchOrId);
    if (label != '') Reflect.setField(item, 'label', label);
    Reflect.setField(item, 'position', position);
    if (target != '') Reflect.setField(item, 'target', target);
    Reflect.setField(item, 'hidden', hidden);
    cast(items, Array<Dynamic>).push(item);
    applyLuaPauseMenuConfig();
    return true;
  }

  function upsertLuaPauseMenuItem(item:Dynamic):Void
  {
    if (item == null) return;
    ensureLuaPauseMenuConfig();

    var items:Dynamic = Reflect.field(pauseMenuConfig, 'items');
    if (!Std.isOfType(items, Array))
    {
      items = [];
      Reflect.setField(pauseMenuConfig, 'items', items);
    }

    var key = pauseMenuItemKey(item);
    var itemArray:Array<Dynamic> = cast items;
    if (key != '')
    {
      for (i in 0...itemArray.length)
      {
        if (pauseMenuItemKey(itemArray[i]) == key)
        {
          itemArray[i] = item;
          return;
        }
      }
    }

    itemArray.push(item);
  }

  function pauseMenuItemKey(item:Dynamic):String
  {
    if (item == null) return '';
    if (Reflect.hasField(item, 'match')) return Std.string(Reflect.field(item, 'match')).toLowerCase();
    if (Reflect.hasField(item, 'id')) return Std.string(Reflect.field(item, 'id')).toLowerCase();
    return '';
  }
  function ensureLuaPauseMenuConfig():Void
  {
    if (pauseMenuConfig == null) pauseMenuConfig = {mode: 'standard', items: []};
    if (!Reflect.hasField(pauseMenuConfig, 'items')) Reflect.setField(pauseMenuConfig, 'items', []);
  }
  public function applyLuaPauseMenuConfig():Bool
  {
    if (pauseMenuState == null || pauseMenuConfig == null || pauseMenuConfiguredThisPass) return false;
    final configureMethod = Reflect.field(pauseMenuState, 'configureLuaPauseMenu');
    if (configureMethod == null) return false;
    pauseMenuConfiguredThisPass = Reflect.callMethod(pauseMenuState, configureMethod, [pauseMenuConfig, function(id:String)
    {
      callHook(id, []);
      callHook('onLuaPauseMenuAccept', [id]);
    }]) == true;
    return pauseMenuConfiguredThisPass;
  }

  static function collectOptionLuaScripts(folder:String, scriptPaths:Array<String>, extension:String):Void
  {
    collectScriptFolder(folder, scriptPaths, extension);
  }

  static function collectScriptFolder(folder:String, scriptPaths:Array<String>, extension:String):Void
  {
    if (!FileSystem.exists(folder) || !FileSystem.isDirectory(folder)) return;

    for (entry in FileSystem.readDirectory(folder))
    {
      var path = '${folder}/${entry}';
      if (FileSystem.isDirectory(path))
      {
        collectScriptFolder(path, scriptPaths, extension);
        continue;
      }
      if (StringTools.endsWith(path.toLowerCase(), extension)) scriptPaths.push(path);
    }
  }

  function resolveLuaScriptPath(requested:String):Null<String>
  {
    if (requested == '') return null;
    final name = StringTools.endsWith(requested.toLowerCase(), '.lua') ? requested : requested + '.lua';
    final candidates:Array<String> = [requested, name, 'mods/${requested}', 'mods/${name}'];
    var index = PolymodHandler.loadedModDirs.length - 1;
    while (index >= 0)
    {
      final root = 'mods/${PolymodHandler.loadedModDirs[index]}';
      candidates.push('${root}/${requested}');
      candidates.push('${root}/${name}');
      index--;
    }
    for (candidate in candidates)
    {
      if (FileSystem.exists(candidate) && !FileSystem.isDirectory(candidate)) return candidate;
    }
    return null;
  }

  function findLoadedScript(requested:String):Null<String>
  {
    final normalized = StringTools.replace(requested, '\\', '/').toLowerCase();
    final withExtension = StringTools.endsWith(normalized, '.lua') ? normalized : normalized + '.lua';
    for (scriptPath in loadedScripts)
    {
      final candidate = StringTools.replace(scriptPath, '\\', '/').toLowerCase();
      if (candidate == normalized || candidate == withExtension || StringTools.endsWith(candidate, '/' + normalized)
        || StringTools.endsWith(candidate, '/' + withExtension)) return scriptPath;
    }
    return null;
  }

  function removeLoadedScript(requested:String):Bool
  {
    final scriptPath = findLoadedScript(requested);
    if (scriptPath == null) return false;
    releaseGlobalScriptHooks(scriptPath);
    releaseIsolatedScriptHooks(scriptPath);
    final envRef = scriptEnvRefs.get(scriptPath);
    if (envRef != null) LuaL.unref(state, Lua.REGISTRYINDEX, envRef);
    scriptEnvRefs.remove(scriptPath);
    scriptGlobalModes.remove(scriptPath);
    loadedScripts.remove(scriptPath);
    hookPresence.clear();
    return true;
  }

  function isGlobalScript(path:String):Bool
  {
    return StringTools.endsWith(path.toLowerCase(), '.luag');
  }

  function createScriptEnvironment():Int
  {
    Lua.newtable(state);
    Lua.newtable(state);
    Lua.pushglobaltable(state);
    Lua.setfield(state, -2, '__index');
    Lua.setmetatable(state, -2);
    return LuaL.ref(state, Lua.REGISTRYINDEX);
  }

  function snapshotGlobalHooks():Map<String, Int>
  {
    var hooks:Map<String, Int> = [];

    for (hookName in LuaHookCatalog.ALL)
    {
      Lua.getglobal(state, hookName);
      if (Lua.type(state, -1) == Lua.TFUNCTION)
      {
        hooks.set(hookName, LuaL.ref(state, Lua.REGISTRYINDEX));
      }
      else
      {
        Lua.pop(state, 1);
      }
    }

    return hooks;
  }

  function restoreGlobalHooks(previousHooks:Map<String, Int>):Void
  {
    for (hookName in LuaHookCatalog.ALL)
    {
      final hookRef:Null<Int> = previousHooks.get(hookName);
      if (hookRef == null)
      {
        Lua.pushnil(state);
      }
      else
      {
        Lua.rawgeti(state, Lua.REGISTRYINDEX, hookRef);
      }
      Lua.setglobal(state, hookName);
    }
  }

  function captureChangedGlobalHooks(scriptPath:String, previousHooks:Map<String, Int>):Void
  {
    var scriptHooks:Map<String, Int> = [];

    for (hookName in LuaHookCatalog.ALL)
    {
      Lua.getglobal(state, hookName);
      if (Lua.type(state, -1) != Lua.TFUNCTION)
      {
        Lua.pop(state, 1);
        continue;
      }

      var changed = true;
      final previousRef = previousHooks.get(hookName);
      if (previousRef != null)
      {
        Lua.rawgeti(state, Lua.REGISTRYINDEX, previousRef);
        changed = Lua.rawequal(state, -1, -2) == 0;
        Lua.pop(state, 1);
      }

      if (changed)
      {
        scriptHooks.set(hookName, LuaL.ref(state, Lua.REGISTRYINDEX));
      }
      else
      {
        Lua.pop(state, 1);
      }
    }

    if (scriptHooks.keys().hasNext()) globalScriptHookRefs.set(scriptPath, scriptHooks);
  }

  function releaseGlobalScriptHooks(scriptPath:String):Void
  {
    final scriptHooks = globalScriptHookRefs.get(scriptPath);
    if (scriptHooks == null) return;

    releaseHookRefs(scriptHooks);
    globalScriptHookRefs.remove(scriptPath);
  }

  function captureEnvironmentHooks(scriptPath:String, envRef:Int):Void
  {
    var scriptHooks:Map<String, Int> = [];

    Lua.rawgeti(state, Lua.REGISTRYINDEX, envRef);
    for (hookName in LuaHookCatalog.ALL)
    {
      Lua.getfield(state, -1, hookName);
      if (Lua.type(state, -1) == Lua.TFUNCTION)
      {
        scriptHooks.set(hookName, LuaL.ref(state, Lua.REGISTRYINDEX));
      }
      else
      {
        Lua.pop(state, 1);
      }
    }
    Lua.pop(state, 1);

    if (scriptHooks.keys().hasNext()) isolatedScriptHookRefs.set(scriptPath, scriptHooks);
  }

  function releaseIsolatedScriptHooks(scriptPath:String):Void
  {
    final scriptHooks = isolatedScriptHookRefs.get(scriptPath);
    if (scriptHooks == null) return;

    releaseHookRefs(scriptHooks);
    isolatedScriptHookRefs.remove(scriptPath);
  }

  function releaseHookRefs(hooks:Map<String, Int>):Void
  {
    for (hookRef in hooks)
    {
      LuaL.unref(state, Lua.REGISTRYINDEX, hookRef);
    }
  }

  function setCurrentHookDisabled(hook:String, disabled:Bool):Void
  {
    if (currentLuaFiles.length == 0)
    {
      final key = 'global:${hook}';
      if (disabled) disabledHooks.set(key, true);
      else disabledHooks.remove(key);
      return;
    }

    for (scriptPath in currentLuaFiles)
    {
      final key = '${scriptPath}:${hook}';
      if (disabled) disabledHooks.set(key, true);
      else disabledHooks.remove(key);
    }
  }

  function reportLuaWarning(kind:String, scriptPath:String, hookName:Null<String>, message:String):Void
  {
    trace('[LuaScriptManager] ${message}');
    LuaErrorManager.warn(kind, scriptPath, hookName, message, currentLuaFiles.length == 0 ? [scriptPath] : currentLuaFiles.copy());
  }

  function clearRuntimeObjects():Void
  {
    for (tween in tweens) tween.cancel();
    tweens.clear();

    for (timer in timers) timer.cancel();
    timers.clear();

    for (sound in sounds) sound.destroy();
    sounds.clear();

    var playState = PlayState.instance;
    var hostState = playState != null ? playState : FlxG.state;

    for (sprite in sprites)
    {
      hostState?.remove(sprite, true);
      sprite.destroy();
    }
    sprites.clear();

    for (text in texts)
    {
      hostState?.remove(text, true);
      text.destroy();
    }
    texts.clear();

    for (object in objects)
    {
      if (Std.isOfType(object, FlxBasic)) hostState?.remove(cast object, true);
      var destroy = safeField(object, 'destroy');
      if (destroy != null) safeCallMethod(object, destroy, []);
    }
    objects.clear();

    if (menuManager != null) menuManager.clear();
    shaderManager.clear();
  }

  function configurePackagePath():Void
  {
    var paths:Array<String> = [
      'mods/?.lua',
      'mods/?.luag',
      'mods/?/init.lua',
      'mods/?/init.luag',
      'mods/scripts/?.lua',
      'mods/scripts/?.luag',
      'mods/scripts/?/init.lua',
      'mods/scripts/?/init.luag'
    ];
    addPackagePaths(paths, 'mods/scripts');

    if (FileSystem.exists('mods') && FileSystem.isDirectory('mods'))
    {
      for (modName in FileSystem.readDirectory('mods'))
      {
        var modPath = 'mods/${modName}';
        if (!FileSystem.isDirectory(modPath)) continue;
        paths.push('${modPath}/?.lua');
        paths.push('${modPath}/?.luag');
        paths.push('${modPath}/?/init.lua');
        paths.push('${modPath}/?/init.luag');
        paths.push('${modPath}/script/?.lua');
        paths.push('${modPath}/script/?.luag');
        paths.push('${modPath}/script/?/init.lua');
        paths.push('${modPath}/script/?/init.luag');
        paths.push('${modPath}/scripts/?.lua');
        paths.push('${modPath}/scripts/?.luag');
        paths.push('${modPath}/scripts/?/init.lua');
        paths.push('${modPath}/scripts/?/init.luag');
        addPackagePaths(paths, '${modPath}/script');
        addPackagePaths(paths, '${modPath}/scripts');
      }
    }

    Lua.getglobal(state, 'package');
    if (Lua.type(state, -1) != Lua.TTABLE)
    {
      Lua.pop(state, 1);
      return;
    }

    Lua.getfield(state, -1, 'path');
    var existingPath = Lua.type(state, -1) == Lua.TSTRING ? Std.string(Lua.tostring(state, -1)) : '';
    Lua.pop(state, 1);
    Lua.pushstring(state, existingPath + ';' + paths.join(';'));
    Lua.setfield(state, -2, 'path');
    Lua.pop(state, 1);
  }

  function addPackagePaths(paths:Array<String>, folder:String):Void
  {
    for (category in LuaScriptFolders.ALL)
    {
      if (category != 'luag')
      {
        paths.push('${folder}/${category}/?.lua');
        paths.push('${folder}/${category}/?/init.lua');
      }

      if (category != 'lua')
      {
        paths.push('${folder}/${category}/?.luag');
        paths.push('${folder}/${category}/?/init.luag');
      }
    }
  }

  function updateGlobals():Void
  {
    var playState = PlayState.instance;
    final conductor = Conductor.instance;
    final chart = playState?.currentChart;
    final totalNotes = Highscore.tallies.totalNotes;
    final rating = totalNotes <= 0 ? 0.0 : Highscore.tallies.totalNotesHit / totalNotes;
    final boyfriend = playState?.currentStage?.getBoyfriend();
    final dad = playState?.currentStage?.getDad();
    final girlfriend = playState?.currentStage?.getGirlfriend();

    setGlobal('Function_Stop', FUNCTION_STOP);
    setGlobal('Function_Continue', FUNCTION_CONTINUE);
    setGlobal('Function_StopLua', FUNCTION_STOP_LUA);
    setGlobal('Function_StopHScript', FUNCTION_STOP_HSCRIPT);
    setGlobal('Function_StopAll', FUNCTION_STOP_ALL);
    setGlobal('version', '1.0.4');
    setGlobal('psychEngineVersion', '1.0.4');
    setGlobal('curBpm', conductor.bpm);
    setGlobal('bpm', conductor.bpm);
    setGlobal('scrollSpeed', chart?.scrollSpeed ?? 1.0);
    setGlobal('crochet', conductor.beatLengthMs);
    setGlobal('stepCrochet', conductor.stepLengthMs);
    setGlobal('songLength', FlxG.sound.music?.length ?? 0.0);
    setGlobal('songName', playState?.currentSong?.songName ?? '');
    setGlobal('songPath', playState?.currentSong?.id ?? '');
    setGlobal('curStage', playState?.currentStageId ?? '');
    setGlobal('difficulty', playState?.currentDifficulty ?? '');
    setGlobal('difficultyName', playState?.currentDifficulty ?? '');
    setGlobal('weekRaw', '');
    setGlobal('week', '');
    setGlobal('weekName', '');
    setGlobal('isStoryMode', false);
    setGlobal('seenCutscene', false);
    setGlobal('hasVocals', playState?.vocals != null);
    setGlobal('screenWidth', FlxG.width);
    setGlobal('screenHeight', FlxG.height);
    setGlobal('curSection', Std.int(conductor.currentStep / 16));
    setGlobal('curBeat', conductor.currentBeat);
    setGlobal('curStep', conductor.currentStep);
    setGlobal('curDecBeat', conductor.currentBeatTime);
    setGlobal('curDecStep', conductor.currentStepTime);
    setGlobal('score', playState?.songScore ?? 0);
    setGlobal('misses', Highscore.tallies.missed);
    setGlobal('hits', Highscore.tallies.totalNotesHit);
    setGlobal('combo', Highscore.tallies.combo);
    setGlobal('deaths', 0);
    setGlobal('rating', rating);
    setGlobal('ratingPercent', rating);
    setGlobal('ratingName', '');
    setGlobal('ratingFC', '');
    setGlobal('health', playState?.health ?? 0);
    setGlobal('playbackRate', playState?.playbackRate ?? 1.0);
    setGlobal('botPlay', playState?.isBotPlayMode ?? false);
    setGlobal('practice', playState?.isPracticeMode ?? false);
    setGlobal('downscroll', FunkinPreferences.downscroll);
    setGlobal('middlescroll', false);
    setGlobal('framerate', FunkinPreferences.framerate);
    setGlobal('ghostTapping', true);
    setGlobal('hideHud', false);
    setGlobal('timeBarType', 'Time Left');
    setGlobal('scoreZoom', true);
    setGlobal('cameraZoomOnBeat', FunkinPreferences.zoomCamera);
    setGlobal('flashingLights', FunkinPreferences.flashingLights);
    setGlobal('noteOffset', 0);
    setGlobal('healthBarAlpha', playState?.healthBar?.alpha ?? 1.0);
    setGlobal('noResetButton', false);
    setGlobal('lowQuality', false);
    setGlobal('shadersEnabled', true);
    setGlobal('boyfriendName', boyfriend?.characterId ?? '');
    setGlobal('dadName', dad?.characterId ?? '');
    setGlobal('gfName', girlfriend?.characterId ?? '');
    setGlobal('startedCountdown', safeField(playState, 'startedCountdown') ?? false);
    setGlobal('startingSong', safeField(playState, 'startingSong') ?? false);
    setGlobal('mustHitSection', false);
    setGlobal('altAnim', false);
    setGlobal('gfSection', false);
    setGlobal('buildTarget', #if windows 'windows' #elseif mac 'mac' #elseif linux 'linux' #else 'unknown' #end);
  }

  function setGlobal(name:String, value:Dynamic):Void
  {
    pushValue(value);
    Lua.setglobal(state, name);
  }

  function countLoadedScripts(global:Bool):Int
  {
    var count = 0;
    for (scriptPath in loadedScripts)
    {
      if ((scriptGlobalModes.get(scriptPath) == true) == global) count++;
    }
    return count;
  }

  function registerAPI():Void
  {
    registerPsychAPIOnly();
    return;
    Lua.register(state, 'debugPrint', cpp.Callable.fromStaticFunction(lua_debugPrint));
    Lua.register(state, 'luaTrace', cpp.Callable.fromStaticFunction(lua_debugPrint));
    Lua.register(state, 'reloadLuaScripts', cpp.Callable.fromStaticFunction(lua_reloadLuaScripts));
    Lua.register(state, 'setLuaWindowTitle', cpp.Callable.fromStaticFunction(lua_setLuaWindowTitle));
    Lua.register(state, 'getCurrentLuaScriptPath', cpp.Callable.fromStaticFunction(lua_getCurrentLuaScriptPath));
    Lua.register(state, 'stopCurrentLuaScript', cpp.Callable.fromStaticFunction(lua_stopCurrentLuaScript));
    Lua.register(state, 'setCurrentLuaScriptPriority', cpp.Callable.fromStaticFunction(lua_setCurrentLuaScriptPriority));
    Lua.register(state, 'getCurrentEvent', cpp.Callable.fromStaticFunction(lua_getCurrentEvent));
    Lua.register(state, 'getEventField', cpp.Callable.fromStaticFunction(lua_getEventField));
    Lua.register(state, 'setEventField', cpp.Callable.fromStaticFunction(lua_setEventField));
    Lua.register(state, 'cancelEvent', cpp.Callable.fromStaticFunction(lua_cancelEvent));
    Lua.register(state, 'stopEventPropagation', cpp.Callable.fromStaticFunction(lua_stopEventPropagation));
    Lua.register(state, 'getProperty', cpp.Callable.fromStaticFunction(lua_getProperty));
    Lua.register(state, 'setProperty', cpp.Callable.fromStaticFunction(lua_setProperty));
    Lua.register(state, 'setProperties', cpp.Callable.fromStaticFunction(lua_setProperties));
    Lua.register(state, 'getPropertyRef', cpp.Callable.fromStaticFunction(lua_getPropertyRef));
    Lua.register(state, 'setPropertyRef', cpp.Callable.fromStaticFunction(lua_setPropertyRef));
    Lua.register(state, 'objectExists', cpp.Callable.fromStaticFunction(lua_objectExists));
    Lua.register(state, 'getObjectProperty', cpp.Callable.fromStaticFunction(lua_getProperty));
    Lua.register(state, 'setObjectProperty', cpp.Callable.fromStaticFunction(lua_setProperty));
    Lua.register(state, 'callMethod', cpp.Callable.fromStaticFunction(lua_callMethod));
    Lua.register(state, 'classExists', cpp.Callable.fromStaticFunction(lua_classExists));
    Lua.register(state, 'getStaticProperty', cpp.Callable.fromStaticFunction(lua_getStaticProperty));
    Lua.register(state, 'setStaticProperty', cpp.Callable.fromStaticFunction(lua_setStaticProperty));
    Lua.register(state, 'callStatic', cpp.Callable.fromStaticFunction(lua_callStatic));
    Lua.register(state, 'createInstance', cpp.Callable.fromStaticFunction(lua_createInstance));
    Lua.register(state, 'storeObject', cpp.Callable.fromStaticFunction(lua_storeObject));
    Lua.register(state, 'forgetObject', cpp.Callable.fromStaticFunction(lua_forgetObject));
    Lua.register(state, 'addObjectToState', cpp.Callable.fromStaticFunction(lua_addObjectToState));
    Lua.register(state, 'removeObjectFromState', cpp.Callable.fromStaticFunction(lua_removeObjectFromState));
    Lua.register(state, 'destroyObject', cpp.Callable.fromStaticFunction(lua_destroyObject));
    Lua.register(state, 'getArrayLength', cpp.Callable.fromStaticFunction(lua_getArrayLength));
    Lua.register(state, 'getArrayItem', cpp.Callable.fromStaticFunction(lua_getArrayItem));
    Lua.register(state, 'setArrayItem', cpp.Callable.fromStaticFunction(lua_setArrayItem));
    Lua.register(state, 'jsonParse', cpp.Callable.fromStaticFunction(lua_jsonParse));
    Lua.register(state, 'jsonStringify', cpp.Callable.fromStaticFunction(lua_jsonStringify));
    Lua.register(state, 'fileExists', cpp.Callable.fromStaticFunction(lua_fileExists));
    Lua.register(state, 'directoryExists', cpp.Callable.fromStaticFunction(lua_directoryExists));
    Lua.register(state, 'readTextFile', cpp.Callable.fromStaticFunction(lua_readTextFile));
    Lua.register(state, 'writeTextFile', cpp.Callable.fromStaticFunction(lua_writeTextFile));
    Lua.register(state, 'randomFloat', cpp.Callable.fromStaticFunction(lua_randomFloat));
    Lua.register(state, 'randomInt', cpp.Callable.fromStaticFunction(lua_randomInt));
    Lua.register(state, 'keyPressed', cpp.Callable.fromStaticFunction(lua_keyPressed));
    Lua.register(state, 'keyJustPressed', cpp.Callable.fromStaticFunction(lua_keyJustPressed));
    Lua.register(state, 'keyJustReleased', cpp.Callable.fromStaticFunction(lua_keyJustReleased));
    Lua.register(state, 'mouseX', cpp.Callable.fromStaticFunction(lua_mouseX));
    Lua.register(state, 'mouseY', cpp.Callable.fromStaticFunction(lua_mouseY));
    Lua.register(state, 'mousePressed', cpp.Callable.fromStaticFunction(lua_mousePressed));
    Lua.register(state, 'mouseJustPressed', cpp.Callable.fromStaticFunction(lua_mouseJustPressed));
    Lua.register(state, 'mouseJustReleased', cpp.Callable.fromStaticFunction(lua_mouseJustReleased));

    Lua.register(state, 'getSongPosition', cpp.Callable.fromStaticFunction(lua_getSongPosition));
    Lua.register(state, 'getBeat', cpp.Callable.fromStaticFunction(lua_getBeat));
    Lua.register(state, 'getStep', cpp.Callable.fromStaticFunction(lua_getStep));
    Lua.register(state, 'getSongName', cpp.Callable.fromStaticFunction(lua_getSongName));
    Lua.register(state, 'getDifficulty', cpp.Callable.fromStaticFunction(lua_getDifficulty));
    Lua.register(state, 'getVariation', cpp.Callable.fromStaticFunction(lua_getVariation));
    Lua.register(state, 'getStageId', cpp.Callable.fromStaticFunction(lua_getStageId));
    Lua.register(state, 'changeStage', cpp.Callable.fromStaticFunction(lua_changeStage));
    Lua.register(state, 'changeCharacter', cpp.Callable.fromStaticFunction(lua_changeCharacter));
    Lua.register(state, 'getPlaybackRate', cpp.Callable.fromStaticFunction(lua_getPlaybackRate));
    Lua.register(state, 'setPlaybackRate', cpp.Callable.fromStaticFunction(lua_setPlaybackRate));
    Lua.register(state, 'getScrollSpeed', cpp.Callable.fromStaticFunction(lua_getScrollSpeed));
    Lua.register(state, 'setScrollSpeed', cpp.Callable.fromStaticFunction(lua_setScrollSpeed));
    Lua.register(state, 'getChartNotes', cpp.Callable.fromStaticFunction(lua_getChartNotes));
    Lua.register(state, 'getChartEvents', cpp.Callable.fromStaticFunction(lua_getChartEvents));
    Lua.register(state, 'setStrumlinePosition', cpp.Callable.fromStaticFunction(lua_setStrumlinePosition));
    Lua.register(state, 'setStrumlineAlpha', cpp.Callable.fromStaticFunction(lua_setStrumlineAlpha));
    Lua.register(state, 'setStrumlineVisible', cpp.Callable.fromStaticFunction(lua_setStrumlineVisible));
    Lua.register(state, 'setStrumlineNotePosition', cpp.Callable.fromStaticFunction(lua_setStrumlineNotePosition));
    Lua.register(state, 'playStrumlineAnimation', cpp.Callable.fromStaticFunction(lua_playStrumlineAnimation));
    Lua.register(state, 'setBotplay', cpp.Callable.fromStaticFunction(lua_setBotplay));
    Lua.register(state, 'setPracticeMode', cpp.Callable.fromStaticFunction(lua_setPracticeMode));
    Lua.register(state, 'getPreference', cpp.Callable.fromStaticFunction(lua_getPreference));
    Lua.register(state, 'setPreference', cpp.Callable.fromStaticFunction(lua_setPreference));
    Lua.register(state, 'setCamZoom', cpp.Callable.fromStaticFunction(lua_setCamZoom));
    Lua.register(state, 'debugInfo', cpp.Callable.fromStaticFunction(lua_debugInfo));
    Lua.register(state, 'debugWarn', cpp.Callable.fromStaticFunction(lua_debugWarn));
    Lua.register(state, 'debugError', cpp.Callable.fromStaticFunction(lua_debugError));
    Lua.register(state, 'disableLuaHook', cpp.Callable.fromStaticFunction(lua_disableLuaHook));
    Lua.register(state, 'enableLuaHook', cpp.Callable.fromStaticFunction(lua_enableLuaHook));
    Lua.register(state, 'defineLuaOption', cpp.Callable.fromStaticFunction(lua_defineLuaOption));
    Lua.register(state, 'getLuaOption', cpp.Callable.fromStaticFunction(lua_getLuaOption));
    Lua.register(state, 'setLuaOption', cpp.Callable.fromStaticFunction(lua_setLuaOption));
    Lua.register(state, 'hasLuaOption', cpp.Callable.fromStaticFunction(lua_hasLuaOption));
    Lua.register(state, 'luaStageExists', cpp.Callable.fromStaticFunction(lua_stageExists));
    Lua.register(state, 'removeLuaOption', cpp.Callable.fromStaticFunction(lua_removeLuaOption));
    Lua.register(state, 'getLuaOptions', cpp.Callable.fromStaticFunction(lua_getLuaOptions));
    Lua.register(state, 'createLuaOptionPage', cpp.Callable.fromStaticFunction(lua_createLuaOptionPage));
    Lua.register(state, 'addLuaCheckbox', cpp.Callable.fromStaticFunction(lua_addLuaCheckbox));
    Lua.register(state, 'addLuaNumber', cpp.Callable.fromStaticFunction(lua_addLuaNumber));
    Lua.register(state, 'addLuaEnum', cpp.Callable.fromStaticFunction(lua_addLuaEnum));
    Lua.register(state, 'getLuaSave', cpp.Callable.fromStaticFunction(lua_getLuaSave));
    Lua.register(state, 'setLuaSave', cpp.Callable.fromStaticFunction(lua_setLuaSave));
    Lua.register(state, 'flushSave', cpp.Callable.fromStaticFunction(lua_flushSave));
    Lua.register(state, 'getScreenWidth', cpp.Callable.fromStaticFunction(lua_getScreenWidth));
    Lua.register(state, 'getScreenHeight', cpp.Callable.fromStaticFunction(lua_getScreenHeight));
    Lua.register(state, 'setFullscreen', cpp.Callable.fromStaticFunction(lua_setFullscreen));
    Lua.register(state, 'getMemoryUsageMB', cpp.Callable.fromStaticFunction(lua_getMemoryUsageMB));
    Lua.register(state, 'getDebugDisplayVisible', cpp.Callable.fromStaticFunction(lua_getDebugDisplayVisible));
    Lua.register(state, 'setDebugDisplayVisible', cpp.Callable.fromStaticFunction(lua_setDebugDisplayVisible));
    Lua.register(state, 'getHealth', cpp.Callable.fromStaticFunction(lua_getHealth));
    Lua.register(state, 'setHealth', cpp.Callable.fromStaticFunction(lua_setHealth));
    Lua.register(state, 'addHealth', cpp.Callable.fromStaticFunction(lua_addHealth));
    Lua.register(state, 'getScore', cpp.Callable.fromStaticFunction(lua_getScore));
    Lua.register(state, 'setScore', cpp.Callable.fromStaticFunction(lua_setScore));
    Lua.register(state, 'addScore', cpp.Callable.fromStaticFunction(lua_addScore));
    Lua.register(state, 'getCombo', cpp.Callable.fromStaticFunction(lua_getCombo));
    Lua.register(state, 'setCombo', cpp.Callable.fromStaticFunction(lua_setCombo));
    Lua.register(state, 'getAccuracy', cpp.Callable.fromStaticFunction(lua_getAccuracy));
    Lua.register(state, 'getTallies', cpp.Callable.fromStaticFunction(lua_getTallies));
    Lua.register(state, 'setVocalsVolume', cpp.Callable.fromStaticFunction(lua_setVocalsVolume));
    Lua.register(state, 'startCountdown', cpp.Callable.fromStaticFunction(lua_startCountdown));
    Lua.register(state, 'startConversation', cpp.Callable.fromStaticFunction(lua_startConversation));
    Lua.register(state, 'playVideo', cpp.Callable.fromStaticFunction(lua_playVideo));
    Lua.register(state, 'pauseVideo', cpp.Callable.fromStaticFunction(lua_pauseVideo));
    Lua.register(state, 'resumeVideo', cpp.Callable.fromStaticFunction(lua_resumeVideo));
    Lua.register(state, 'finishVideo', cpp.Callable.fromStaticFunction(lua_finishVideo));
    Lua.register(state, 'isVideoPlaying', cpp.Callable.fromStaticFunction(lua_isVideoPlaying));
    Lua.register(state, 'endSong', cpp.Callable.fromStaticFunction(lua_endSong));
    Lua.register(state, 'restartSong', cpp.Callable.fromStaticFunction(lua_restartSong));
    Lua.register(state, 'openLuaState', cpp.Callable.fromStaticFunction(lua_openLuaState));
    Lua.register(state, 'openLuaSubState', cpp.Callable.fromStaticFunction(lua_openLuaSubState));

    Lua.register(state, 'addSprite', cpp.Callable.fromStaticFunction(lua_addSprite));
    Lua.register(state, 'loadGraphic', cpp.Callable.fromStaticFunction(lua_loadGraphic));
    Lua.register(state, 'loadSparrow', cpp.Callable.fromStaticFunction(lua_loadSparrow));
    Lua.register(state, 'makeSolidSprite', cpp.Callable.fromStaticFunction(lua_makeSolidSprite));
    Lua.register(state, 'removeSprite', cpp.Callable.fromStaticFunction(lua_removeSprite));
    Lua.register(state, 'setSpriteCamera', cpp.Callable.fromStaticFunction(lua_setSpriteCamera));
    Lua.register(state, 'addText', cpp.Callable.fromStaticFunction(lua_addText));
    Lua.register(state, 'setText', cpp.Callable.fromStaticFunction(lua_setText));
    Lua.register(state, 'setTextFormat', cpp.Callable.fromStaticFunction(lua_setTextFormat));
    Lua.register(state, 'removeText', cpp.Callable.fromStaticFunction(lua_removeText));
    Lua.register(state, 'setObjectCamera', cpp.Callable.fromStaticFunction(lua_setObjectCamera));
    Lua.register(state, 'setObjectPosition', cpp.Callable.fromStaticFunction(lua_setObjectPosition));
    Lua.register(state, 'getObjectX', cpp.Callable.fromStaticFunction(lua_getObjectX));
    Lua.register(state, 'getObjectY', cpp.Callable.fromStaticFunction(lua_getObjectY));
    Lua.register(state, 'getObjectWidth', cpp.Callable.fromStaticFunction(lua_getObjectWidth));
    Lua.register(state, 'getObjectHeight', cpp.Callable.fromStaticFunction(lua_getObjectHeight));
    Lua.register(state, 'getObjectAlpha', cpp.Callable.fromStaticFunction(lua_getObjectAlpha));
    Lua.register(state, 'getObjectVisible', cpp.Callable.fromStaticFunction(lua_getObjectVisible));
    Lua.register(state, 'getObjectAngle', cpp.Callable.fromStaticFunction(lua_getObjectAngle));
    Lua.register(state, 'setObjectScale', cpp.Callable.fromStaticFunction(lua_setObjectScale));
    Lua.register(state, 'setObjectSize', cpp.Callable.fromStaticFunction(lua_setObjectSize));
    Lua.register(state, 'setObjectAlpha', cpp.Callable.fromStaticFunction(lua_setObjectAlpha));
    Lua.register(state, 'setObjectVisible', cpp.Callable.fromStaticFunction(lua_setObjectVisible));
    Lua.register(state, 'setObjectAngle', cpp.Callable.fromStaticFunction(lua_setObjectAngle));
    Lua.register(state, 'setObjectColor', cpp.Callable.fromStaticFunction(lua_setObjectColor));
    Lua.register(state, 'setObjectVelocity', cpp.Callable.fromStaticFunction(lua_setObjectVelocity));
    Lua.register(state, 'setObjectAcceleration', cpp.Callable.fromStaticFunction(lua_setObjectAcceleration));
    Lua.register(state, 'setObjectScrollFactor', cpp.Callable.fromStaticFunction(lua_setObjectScrollFactor));
    Lua.register(state, 'setObjectZIndex', cpp.Callable.fromStaticFunction(lua_setObjectZIndex));
    Lua.register(state, 'screenCenter', cpp.Callable.fromStaticFunction(lua_screenCenter));
    Lua.register(state, 'objectExists', cpp.Callable.fromStaticFunction(lua_objectExists));
    Lua.register(state, 'killObject', cpp.Callable.fromStaticFunction(lua_killObject));
    Lua.register(state, 'reviveObject', cpp.Callable.fromStaticFunction(lua_reviveObject));
    Lua.register(state, 'addAnimByPrefix', cpp.Callable.fromStaticFunction(lua_addAnimByPrefix));
    Lua.register(state, 'playAnim', cpp.Callable.fromStaticFunction(lua_playAnim));
    Lua.register(state, 'hasAnim', cpp.Callable.fromStaticFunction(lua_hasAnim));
    Lua.register(state, 'createLuaMenu', cpp.Callable.fromStaticFunction(lua_createLuaMenu));
    Lua.register(state, 'createLuaImageMenu', cpp.Callable.fromStaticFunction(lua_createLuaImageMenu));
    Lua.register(state, 'addLuaMainMenuItem', cpp.Callable.fromStaticFunction(lua_addLuaMainMenuItem));
    Lua.register(state, 'configureLuaPauseMenu', cpp.Callable.fromStaticFunction(lua_configureLuaPauseMenu));
    Lua.register(state, 'setLuaPauseOptions', cpp.Callable.fromStaticFunction(lua_setLuaPauseOptions));
    Lua.register(state, 'setLuaPauseOptionsBehavior', cpp.Callable.fromStaticFunction(lua_setLuaPauseOptionsBehavior));
    Lua.register(state, 'setLuaPauseMenuItem', cpp.Callable.fromStaticFunction(lua_setLuaPauseMenuItem));
    Lua.register(state, 'setLuaMenuItems', cpp.Callable.fromStaticFunction(lua_setLuaMenuItems));
    Lua.register(state, 'setLuaMenuPosition', cpp.Callable.fromStaticFunction(lua_setLuaMenuPosition));
    Lua.register(state, 'showLuaMenu', cpp.Callable.fromStaticFunction(lua_showLuaMenu));
    Lua.register(state, 'hideLuaMenu', cpp.Callable.fromStaticFunction(lua_hideLuaMenu));
    Lua.register(state, 'removeLuaMenu', cpp.Callable.fromStaticFunction(lua_removeLuaMenu));
    Lua.register(state, 'getLuaMenuSelected', cpp.Callable.fromStaticFunction(lua_getLuaMenuSelected));
    Lua.register(state, 'initLuaShaderRaw', cpp.Callable.fromStaticFunction(lua_initLuaShader));
    Lua.register(state, 'initLuaShader', cpp.Callable.fromStaticFunction(lua_initLuaShader));
    Lua.register(state, 'makeLuaShader', cpp.Callable.fromStaticFunction(lua_makeLuaShader));
    Lua.register(state, 'setLuaShader', cpp.Callable.fromStaticFunction(lua_setLuaShader));
    Lua.register(state, 'setShaderOnSprite', cpp.Callable.fromStaticFunction(lua_setShaderOnSprite));
    Lua.register(state, 'createShader', cpp.Callable.fromStaticFunction(lua_createShader));
    Lua.register(state, 'destroyShader', cpp.Callable.fromStaticFunction(lua_destroyShader));
    Lua.register(state, 'luaShaderExists', cpp.Callable.fromStaticFunction(lua_shaderExists));
    Lua.register(state, 'setShaderFloat', cpp.Callable.fromStaticFunction(lua_setShaderFloat));
    Lua.register(state, 'setShaderFloatArray', cpp.Callable.fromStaticFunction(lua_setShaderFloatArray));
    Lua.register(state, 'setShaderInt', cpp.Callable.fromStaticFunction(lua_setShaderInt));
    Lua.register(state, 'setShaderBool', cpp.Callable.fromStaticFunction(lua_setShaderBool));
    Lua.register(state, 'setShaderColor', cpp.Callable.fromStaticFunction(lua_setShaderColor));
    Lua.register(state, 'tweenShaderFloat', cpp.Callable.fromStaticFunction(lua_tweenShaderFloat));
    Lua.register(state, 'applyShader', cpp.Callable.fromStaticFunction(lua_applyShader));
    Lua.register(state, 'clearShader', cpp.Callable.fromStaticFunction(lua_clearShader));
    Lua.register(state, 'applyCameraShader', cpp.Callable.fromStaticFunction(lua_applyCameraShader));
    Lua.register(state, 'clearCameraShader', cpp.Callable.fromStaticFunction(lua_clearCameraShader));

    Lua.register(state, 'tween', cpp.Callable.fromStaticFunction(lua_tween));
    Lua.register(state, 'cancelTween', cpp.Callable.fromStaticFunction(lua_cancelTween));
    Lua.register(state, 'pauseTween', cpp.Callable.fromStaticFunction(lua_pauseTween));
    Lua.register(state, 'resumeTween', cpp.Callable.fromStaticFunction(lua_resumeTween));
    Lua.register(state, 'runTimer', cpp.Callable.fromStaticFunction(lua_runTimer));
    Lua.register(state, 'cancelTimer', cpp.Callable.fromStaticFunction(lua_cancelTimer));

    Lua.register(state, 'playSound', cpp.Callable.fromStaticFunction(lua_playSound));
    Lua.register(state, 'stopSound', cpp.Callable.fromStaticFunction(lua_stopSound));
    Lua.register(state, 'pauseSound', cpp.Callable.fromStaticFunction(lua_pauseSound));
    Lua.register(state, 'resumeSound', cpp.Callable.fromStaticFunction(lua_resumeSound));
    Lua.register(state, 'setSoundVolume', cpp.Callable.fromStaticFunction(lua_setSoundVolume));
    Lua.register(state, 'soundExists', cpp.Callable.fromStaticFunction(lua_soundExists));
    Lua.register(state, 'playMusic', cpp.Callable.fromStaticFunction(lua_playMusic));
    Lua.register(state, 'stopMusic', cpp.Callable.fromStaticFunction(lua_stopMusic));
    Lua.register(state, 'pauseMusic', cpp.Callable.fromStaticFunction(lua_pauseMusic));
    Lua.register(state, 'resumeMusic', cpp.Callable.fromStaticFunction(lua_resumeMusic));
    Lua.register(state, 'setMusicVolume', cpp.Callable.fromStaticFunction(lua_setMusicVolume));
    Lua.register(state, 'cameraFlash', cpp.Callable.fromStaticFunction(lua_cameraFlash));
    Lua.register(state, 'cameraFade', cpp.Callable.fromStaticFunction(lua_cameraFade));
    Lua.register(state, 'cameraShake', cpp.Callable.fromStaticFunction(lua_cameraShake));
    Lua.register(state, 'setCameraZoom', cpp.Callable.fromStaticFunction(lua_setCameraZoom));
    Lua.register(state, 'setCameraAlpha', cpp.Callable.fromStaticFunction(lua_setCameraAlpha));
    Lua.register(state, 'setCameraBgColor', cpp.Callable.fromStaticFunction(lua_setCameraBgColor));
    Lua.register(state, 'setCameraVisible', cpp.Callable.fromStaticFunction(lua_setCameraVisible));
    Lua.register(state, 'setCameraPosition', cpp.Callable.fromStaticFunction(lua_setCameraPosition));
    Lua.register(state, 'setCameraFollow', cpp.Callable.fromStaticFunction(lua_setCameraFollow));
    Lua.register(state, 'setCameraBop', cpp.Callable.fromStaticFunction(lua_setCameraBop));
    Lua.register(state, 'setHealthBarColors', cpp.Callable.fromStaticFunction(lua_setHealthBarColors));
    Lua.register(state, 'resetCamera', cpp.Callable.fromStaticFunction(lua_resetCamera));
    Lua.register(state, 'tweenCameraZoom', cpp.Callable.fromStaticFunction(lua_tweenCameraZoom));
    Lua.register(state, 'tweenCameraToPosition', cpp.Callable.fromStaticFunction(lua_tweenCameraToPosition));
    Lua.register(state, 'cancelCameraTweens', cpp.Callable.fromStaticFunction(lua_cancelCameraTweens));
    Lua.register(state, 'tweenScrollSpeed', cpp.Callable.fromStaticFunction(lua_tweenScrollSpeed));
    Lua.register(state, 'cancelScrollSpeedTweens', cpp.Callable.fromStaticFunction(lua_cancelScrollSpeedTweens));

    Lua.register(state, 'pathImage', cpp.Callable.fromStaticFunction(lua_pathImage));
    Lua.register(state, 'pathSound', cpp.Callable.fromStaticFunction(lua_pathSound));
    Lua.register(state, 'pathMusic', cpp.Callable.fromStaticFunction(lua_pathMusic));
    Lua.register(state, 'pathFont', cpp.Callable.fromStaticFunction(lua_pathFont));
    Lua.register(state, 'pathFile', cpp.Callable.fromStaticFunction(lua_pathFile));
    Lua.register(state, 'pathJson', cpp.Callable.fromStaticFunction(lua_pathJson));

    registerPsychStyleAliases();
    installSimpleAPI();
  }

  function registerPsychAPIOnly():Void
  {
    Lua.register(state, 'debugPrint', cpp.Callable.fromStaticFunction(lua_debugPrint));
    Lua.register(state, 'getProperty', cpp.Callable.fromStaticFunction(lua_getProperty));
    Lua.register(state, 'setProperty', cpp.Callable.fromStaticFunction(lua_setProperty));
    Lua.register(state, 'getPropertyFromClass', cpp.Callable.fromStaticFunction(lua_getStaticProperty));
    Lua.register(state, 'setPropertyFromClass', cpp.Callable.fromStaticFunction(lua_setStaticProperty));
    Lua.register(state, 'getPropertyFromGroup', cpp.Callable.fromStaticFunction(lua_getPropertyFromGroup));
    Lua.register(state, 'setPropertyFromGroup', cpp.Callable.fromStaticFunction(lua_setPropertyFromGroup));
    Lua.register(state, 'getPropertyLuaSprite', cpp.Callable.fromStaticFunction(lua_getPropertyLuaSprite));
    Lua.register(state, 'setPropertyLuaSprite', cpp.Callable.fromStaticFunction(lua_setPropertyLuaSprite));
    Lua.register(state, 'addToGroup', cpp.Callable.fromStaticFunction(lua_addToGroup));
    Lua.register(state, 'removeFromGroup', cpp.Callable.fromStaticFunction(lua_removeFromGroup));
    Lua.register(state, 'updateHitboxFromGroup', cpp.Callable.fromStaticFunction(lua_updateHitboxFromGroup));
    Lua.register(state, 'callMethod', cpp.Callable.fromStaticFunction(lua_callMethod));
    Lua.register(state, 'callMethodFromClass', cpp.Callable.fromStaticFunction(lua_callStatic));
    Lua.register(state, 'createInstance', cpp.Callable.fromStaticFunction(lua_createInstance));
    Lua.register(state, 'addInstance', cpp.Callable.fromStaticFunction(lua_addObjectToState));
    Lua.register(state, 'instanceArg', cpp.Callable.fromStaticFunction(lua_instanceArg));
    Lua.register(state, 'getVar', cpp.Callable.fromStaticFunction(lua_getVar));
    Lua.register(state, 'setVar', cpp.Callable.fromStaticFunction(lua_setVar));
    Lua.register(state, 'addLuaScript', cpp.Callable.fromStaticFunction(lua_addLuaScript));
    Lua.register(state, 'removeLuaScript', cpp.Callable.fromStaticFunction(lua_removeLuaScript));
    Lua.register(state, 'callScript', cpp.Callable.fromStaticFunction(lua_callScript));
    Lua.register(state, 'getRunningScripts', cpp.Callable.fromStaticFunction(lua_getRunningScripts));
    Lua.register(state, 'isRunning', cpp.Callable.fromStaticFunction(lua_isRunning));
    Lua.register(state, 'close', cpp.Callable.fromStaticFunction(lua_closeScript));
    Lua.register(state, 'setOnScripts', cpp.Callable.fromStaticFunction(lua_setOnScripts));
    Lua.register(state, 'setOnLuas', cpp.Callable.fromStaticFunction(lua_setOnScripts));
    Lua.register(state, 'callOnScripts', cpp.Callable.fromStaticFunction(lua_callOnScripts));
    Lua.register(state, 'callOnLuas', cpp.Callable.fromStaticFunction(lua_callOnScripts));
    Lua.register(state, 'setOnHScript', cpp.Callable.fromStaticFunction(lua_unsupported));
    Lua.register(state, 'callOnHScript', cpp.Callable.fromStaticFunction(lua_unsupported));
    Lua.register(state, 'getModSetting', cpp.Callable.fromStaticFunction(lua_getModSetting));

    Lua.register(state, 'makeLuaSprite', cpp.Callable.fromStaticFunction(lua_psychMakeLuaSprite));
    Lua.register(state, 'makeAnimatedLuaSprite', cpp.Callable.fromStaticFunction(lua_psychMakeAnimatedLuaSprite));
    Lua.register(state, 'makeGraphic', cpp.Callable.fromStaticFunction(lua_makeGraphicAlias));
    Lua.register(state, 'loadGraphic', cpp.Callable.fromStaticFunction(lua_psychLoadGraphic));
    Lua.register(state, 'loadFrames', cpp.Callable.fromStaticFunction(lua_psychLoadFrames));
    Lua.register(state, 'loadMultipleFrames', cpp.Callable.fromStaticFunction(lua_psychLoadMultipleFrames));
    Lua.register(state, 'loadAnimateAtlas', cpp.Callable.fromStaticFunction(lua_psychLoadAnimateAtlas));
    Lua.register(state, 'makeFlxAnimateSprite', cpp.Callable.fromStaticFunction(lua_psychMakeFlxAnimateSprite));
    Lua.register(state, 'addLuaSprite', cpp.Callable.fromStaticFunction(lua_psychAddLuaSprite));
    Lua.register(state, 'removeLuaSprite', cpp.Callable.fromStaticFunction(lua_removeSprite));
    Lua.register(state, 'luaSpriteExists', cpp.Callable.fromStaticFunction(lua_luaSpriteExists));
    Lua.register(state, 'luaSpriteMakeGraphic', cpp.Callable.fromStaticFunction(lua_makeGraphicAlias));
    Lua.register(state, 'addAnimationByPrefix', cpp.Callable.fromStaticFunction(lua_addAnimByPrefix));
    Lua.register(state, 'addAnimation', cpp.Callable.fromStaticFunction(lua_addAnimation));
    Lua.register(state, 'addAnimationByIndices', cpp.Callable.fromStaticFunction(lua_addAnimationByIndices));
    Lua.register(state, 'addAnimationByIndicesLoop', cpp.Callable.fromStaticFunction(lua_addAnimationByIndicesLoop));
    Lua.register(state, 'addAnimationBySymbol', cpp.Callable.fromStaticFunction(lua_addAnimationBySymbol));
    Lua.register(state, 'addAnimationBySymbolIndices', cpp.Callable.fromStaticFunction(lua_addAnimationBySymbolIndices));
    Lua.register(state, 'luaSpriteAddAnimationByPrefix', cpp.Callable.fromStaticFunction(lua_addAnimByPrefix));
    Lua.register(state, 'luaSpriteAddAnimationByIndices', cpp.Callable.fromStaticFunction(lua_addAnimationByIndices));
    Lua.register(state, 'playAnim', cpp.Callable.fromStaticFunction(lua_playAnim));
    Lua.register(state, 'objectPlayAnimation', cpp.Callable.fromStaticFunction(lua_playAnim));
    Lua.register(state, 'luaSpritePlayAnimation', cpp.Callable.fromStaticFunction(lua_playAnim));
    Lua.register(state, 'characterPlayAnim', cpp.Callable.fromStaticFunction(lua_characterPlayAnim));
    Lua.register(state, 'characterDance', cpp.Callable.fromStaticFunction(lua_characterDance));
    Lua.register(state, 'addOffset', cpp.Callable.fromStaticFunction(lua_addOffset));
    Lua.register(state, 'scaleObject', cpp.Callable.fromStaticFunction(lua_psychScaleObject));
    Lua.register(state, 'scaleLuaSprite', cpp.Callable.fromStaticFunction(lua_psychScaleObject));
    Lua.register(state, 'setGraphicSize', cpp.Callable.fromStaticFunction(lua_psychSetGraphicSize));
    Lua.register(state, 'updateHitbox', cpp.Callable.fromStaticFunction(lua_updateHitbox));
    Lua.register(state, 'setScrollFactor', cpp.Callable.fromStaticFunction(lua_setObjectScrollFactor));
    Lua.register(state, 'setLuaSpriteScrollFactor', cpp.Callable.fromStaticFunction(lua_setObjectScrollFactor));
    Lua.register(state, 'setObjectCamera', cpp.Callable.fromStaticFunction(lua_setObjectCamera));
    Lua.register(state, 'setLuaSpriteCamera', cpp.Callable.fromStaticFunction(lua_setObjectCamera));
    Lua.register(state, 'screenCenter', cpp.Callable.fromStaticFunction(lua_screenCenter));
    Lua.register(state, 'setObjectOrder', cpp.Callable.fromStaticFunction(lua_setObjectZIndex));
    Lua.register(state, 'getObjectOrder', cpp.Callable.fromStaticFunction(lua_getObjectOrder));
    Lua.register(state, 'setBlendMode', cpp.Callable.fromStaticFunction(lua_setBlendMode));
    Lua.register(state, 'getPixelColor', cpp.Callable.fromStaticFunction(lua_getPixelColor));
    Lua.register(state, 'objectsOverlap', cpp.Callable.fromStaticFunction(lua_objectsOverlap));
    Lua.register(state, 'getMidpointX', cpp.Callable.fromStaticFunction(lua_getMidpointX));
    Lua.register(state, 'getMidpointY', cpp.Callable.fromStaticFunction(lua_getMidpointY));
    Lua.register(state, 'getGraphicMidpointX', cpp.Callable.fromStaticFunction(lua_getGraphicMidpointX));
    Lua.register(state, 'getGraphicMidpointY', cpp.Callable.fromStaticFunction(lua_getGraphicMidpointY));
    Lua.register(state, 'getScreenPositionX', cpp.Callable.fromStaticFunction(lua_getScreenPositionX));
    Lua.register(state, 'getScreenPositionY', cpp.Callable.fromStaticFunction(lua_getScreenPositionY));

    Lua.register(state, 'makeLuaText', cpp.Callable.fromStaticFunction(lua_makeLuaTextAlias));
    Lua.register(state, 'addLuaText', cpp.Callable.fromStaticFunction(lua_psychAddLuaText));
    Lua.register(state, 'removeLuaText', cpp.Callable.fromStaticFunction(lua_removeText));
    Lua.register(state, 'luaTextExists', cpp.Callable.fromStaticFunction(lua_luaTextExists));
    Lua.register(state, 'setTextString', cpp.Callable.fromStaticFunction(lua_setText));
    Lua.register(state, 'getTextString', cpp.Callable.fromStaticFunction(lua_getTextString));
    Lua.register(state, 'setTextSize', cpp.Callable.fromStaticFunction(lua_setTextSize));
    Lua.register(state, 'getTextSize', cpp.Callable.fromStaticFunction(lua_getTextSize));
    Lua.register(state, 'setTextWidth', cpp.Callable.fromStaticFunction(lua_setTextWidth));
    Lua.register(state, 'getTextWidth', cpp.Callable.fromStaticFunction(lua_getTextWidth));
    Lua.register(state, 'setTextHeight', cpp.Callable.fromStaticFunction(lua_setTextHeight));
    Lua.register(state, 'setTextFont', cpp.Callable.fromStaticFunction(lua_setTextFont));
    Lua.register(state, 'getTextFont', cpp.Callable.fromStaticFunction(lua_getTextFont));
    Lua.register(state, 'setTextColor', cpp.Callable.fromStaticFunction(lua_setTextColor));
    Lua.register(state, 'setTextAlignment', cpp.Callable.fromStaticFunction(lua_setTextAlignment));
    Lua.register(state, 'setTextBorder', cpp.Callable.fromStaticFunction(lua_setTextBorder));
    Lua.register(state, 'setTextItalic', cpp.Callable.fromStaticFunction(lua_setTextItalic));
    Lua.register(state, 'setTextAutoSize', cpp.Callable.fromStaticFunction(lua_setTextAutoSize));

    Lua.register(state, 'doTweenX', cpp.Callable.fromStaticFunction(lua_tweenObjectX));
    Lua.register(state, 'doTweenY', cpp.Callable.fromStaticFunction(lua_tweenObjectY));
    Lua.register(state, 'doTweenAlpha', cpp.Callable.fromStaticFunction(lua_tweenObjectAlpha));
    Lua.register(state, 'doTweenAngle', cpp.Callable.fromStaticFunction(lua_tweenObjectAngle));
    Lua.register(state, 'doTweenColor', cpp.Callable.fromStaticFunction(lua_doTweenColor));
    Lua.register(state, 'doTweenZoom', cpp.Callable.fromStaticFunction(lua_tweenCameraZoom));
    Lua.register(state, 'noteTweenX', cpp.Callable.fromStaticFunction(lua_noteTweenX));
    Lua.register(state, 'noteTweenY', cpp.Callable.fromStaticFunction(lua_noteTweenY));
    Lua.register(state, 'noteTweenAngle', cpp.Callable.fromStaticFunction(lua_noteTweenAngle));
    Lua.register(state, 'noteTweenAlpha', cpp.Callable.fromStaticFunction(lua_noteTweenAlpha));
    Lua.register(state, 'noteTweenDirection', cpp.Callable.fromStaticFunction(lua_noteTweenDirection));
    Lua.register(state, 'startTween', cpp.Callable.fromStaticFunction(lua_startTween));
    Lua.register(state, 'cancelTween', cpp.Callable.fromStaticFunction(lua_cancelTween));
    Lua.register(state, 'runTimer', cpp.Callable.fromStaticFunction(lua_runTimer));
    Lua.register(state, 'cancelTimer', cpp.Callable.fromStaticFunction(lua_cancelTimer));

    Lua.register(state, 'playSound', cpp.Callable.fromStaticFunction(lua_playSound));
    Lua.register(state, 'stopSound', cpp.Callable.fromStaticFunction(lua_stopSound));
    Lua.register(state, 'pauseSound', cpp.Callable.fromStaticFunction(lua_pauseSound));
    Lua.register(state, 'resumeSound', cpp.Callable.fromStaticFunction(lua_resumeSound));
    Lua.register(state, 'luaSoundExists', cpp.Callable.fromStaticFunction(lua_soundExists));
    Lua.register(state, 'setSoundVolume', cpp.Callable.fromStaticFunction(lua_setSoundVolume));
    Lua.register(state, 'getSoundVolume', cpp.Callable.fromStaticFunction(lua_getSoundVolume));
    Lua.register(state, 'setSoundTime', cpp.Callable.fromStaticFunction(lua_setSoundTime));
    Lua.register(state, 'getSoundTime', cpp.Callable.fromStaticFunction(lua_getSoundTime));
    Lua.register(state, 'setSoundPitch', cpp.Callable.fromStaticFunction(lua_setSoundPitch));
    Lua.register(state, 'getSoundPitch', cpp.Callable.fromStaticFunction(lua_getSoundPitch));
    Lua.register(state, 'soundFadeIn', cpp.Callable.fromStaticFunction(lua_soundFadeIn));
    Lua.register(state, 'soundFadeOut', cpp.Callable.fromStaticFunction(lua_soundFadeOut));
    Lua.register(state, 'soundFadeCancel', cpp.Callable.fromStaticFunction(lua_soundFadeCancel));
    Lua.register(state, 'playMusic', cpp.Callable.fromStaticFunction(lua_playMusic));
    Lua.register(state, 'musicFadeIn', cpp.Callable.fromStaticFunction(lua_musicFadeIn));
    Lua.register(state, 'musicFadeOut', cpp.Callable.fromStaticFunction(lua_musicFadeOut));

    Lua.register(state, 'cameraFlash', cpp.Callable.fromStaticFunction(lua_cameraFlash));
    Lua.register(state, 'cameraFade', cpp.Callable.fromStaticFunction(lua_cameraFade));
    Lua.register(state, 'cameraShake', cpp.Callable.fromStaticFunction(lua_cameraShake));
    Lua.register(state, 'cameraSetTarget', cpp.Callable.fromStaticFunction(lua_cameraSetTarget));
    Lua.register(state, 'getCameraFollowX', cpp.Callable.fromStaticFunction(lua_getCameraFollowX));
    Lua.register(state, 'getCameraFollowY', cpp.Callable.fromStaticFunction(lua_getCameraFollowY));
    Lua.register(state, 'setCameraFollowPoint', cpp.Callable.fromStaticFunction(lua_setCameraFollowPoint));
    Lua.register(state, 'addCameraFollowPoint', cpp.Callable.fromStaticFunction(lua_addCameraFollowPoint));
    Lua.register(state, 'getCameraScrollX', cpp.Callable.fromStaticFunction(lua_getCameraScrollX));
    Lua.register(state, 'getCameraScrollY', cpp.Callable.fromStaticFunction(lua_getCameraScrollY));
    Lua.register(state, 'setCameraScroll', cpp.Callable.fromStaticFunction(lua_setCameraScroll));
    Lua.register(state, 'addCameraScroll', cpp.Callable.fromStaticFunction(lua_addCameraScroll));

    Lua.register(state, 'getSongPosition', cpp.Callable.fromStaticFunction(lua_getSongPosition));
    Lua.register(state, 'setHealth', cpp.Callable.fromStaticFunction(lua_setHealth));
    Lua.register(state, 'getHealth', cpp.Callable.fromStaticFunction(lua_getHealth));
    Lua.register(state, 'addHealth', cpp.Callable.fromStaticFunction(lua_addHealth));
    Lua.register(state, 'setScore', cpp.Callable.fromStaticFunction(lua_setScore));
    Lua.register(state, 'addScore', cpp.Callable.fromStaticFunction(lua_addScore));
    Lua.register(state, 'setHits', cpp.Callable.fromStaticFunction(lua_setHits));
    Lua.register(state, 'addHits', cpp.Callable.fromStaticFunction(lua_addHits));
    Lua.register(state, 'setMisses', cpp.Callable.fromStaticFunction(lua_setMisses));
    Lua.register(state, 'addMisses', cpp.Callable.fromStaticFunction(lua_addMisses));
    Lua.register(state, 'setRatingPercent', cpp.Callable.fromStaticFunction(lua_setGlobalValue));
    Lua.register(state, 'setRatingName', cpp.Callable.fromStaticFunction(lua_setGlobalValue));
    Lua.register(state, 'setRatingFC', cpp.Callable.fromStaticFunction(lua_setGlobalValue));
    Lua.register(state, 'setHealthBarColors', cpp.Callable.fromStaticFunction(lua_setHealthBarColors));
    Lua.register(state, 'setTimeBarColors', cpp.Callable.fromStaticFunction(lua_setTimeBarColors));
    Lua.register(state, 'updateScoreText', cpp.Callable.fromStaticFunction(lua_updateScoreText));
    Lua.register(state, 'startCountdown', cpp.Callable.fromStaticFunction(lua_startCountdown));
    Lua.register(state, 'endSong', cpp.Callable.fromStaticFunction(lua_endSong));
    Lua.register(state, 'exitSong', cpp.Callable.fromStaticFunction(lua_exitSong));
    Lua.register(state, 'restartSong', cpp.Callable.fromStaticFunction(lua_restartSong));
    Lua.register(state, 'loadSong', cpp.Callable.fromStaticFunction(lua_loadSong));
    Lua.register(state, 'triggerEvent', cpp.Callable.fromStaticFunction(lua_triggerEvent));
    Lua.register(state, 'startDialogue', cpp.Callable.fromStaticFunction(lua_startDialogue));
    Lua.register(state, 'startVideo', cpp.Callable.fromStaticFunction(lua_playVideo));
    Lua.register(state, 'addCharacterToList', cpp.Callable.fromStaticFunction(lua_addCharacterToList));
    Lua.register(state, 'getCharacterX', cpp.Callable.fromStaticFunction(lua_getCharacterX));
    Lua.register(state, 'getCharacterY', cpp.Callable.fromStaticFunction(lua_getCharacterY));
    Lua.register(state, 'setCharacterX', cpp.Callable.fromStaticFunction(lua_setCharacterX));
    Lua.register(state, 'setCharacterY', cpp.Callable.fromStaticFunction(lua_setCharacterY));

    Lua.register(state, 'checkFileExists', cpp.Callable.fromStaticFunction(lua_fileExists));
    Lua.register(state, 'getTextFromFile', cpp.Callable.fromStaticFunction(lua_readTextFile));
    Lua.register(state, 'saveFile', cpp.Callable.fromStaticFunction(lua_writeTextFile));
    Lua.register(state, 'deleteFile', cpp.Callable.fromStaticFunction(lua_deleteFile));
    Lua.register(state, 'directoryFileList', cpp.Callable.fromStaticFunction(lua_directoryFileList));
    Lua.register(state, 'initSaveData', cpp.Callable.fromStaticFunction(lua_initSaveData));
    Lua.register(state, 'flushSaveData', cpp.Callable.fromStaticFunction(lua_flushSaveData));
    Lua.register(state, 'getDataFromSave', cpp.Callable.fromStaticFunction(lua_getDataFromSave));
    Lua.register(state, 'setDataFromSave', cpp.Callable.fromStaticFunction(lua_setDataFromSave));
    Lua.register(state, 'eraseSaveData', cpp.Callable.fromStaticFunction(lua_eraseSaveData));
    Lua.register(state, 'getRandomInt', cpp.Callable.fromStaticFunction(lua_randomInt));
    Lua.register(state, 'getRandomFloat', cpp.Callable.fromStaticFunction(lua_randomFloat));
    Lua.register(state, 'getRandomBool', cpp.Callable.fromStaticFunction(lua_getRandomBool));
    Lua.register(state, 'stringStartsWith', cpp.Callable.fromStaticFunction(lua_stringStartsWith));
    Lua.register(state, 'stringEndsWith', cpp.Callable.fromStaticFunction(lua_stringEndsWith));
    Lua.register(state, 'stringSplit', cpp.Callable.fromStaticFunction(lua_stringSplit));
    Lua.register(state, 'stringTrim', cpp.Callable.fromStaticFunction(lua_stringTrim));
    Lua.register(state, 'getColorFromHex', cpp.Callable.fromStaticFunction(lua_getColorFromHex));
    Lua.register(state, 'getColorFromName', cpp.Callable.fromStaticFunction(lua_getColorFromName));
    Lua.register(state, 'getColorFromString', cpp.Callable.fromStaticFunction(lua_getColorFromString));
    Lua.register(state, 'FlxColor', cpp.Callable.fromStaticFunction(lua_getColorFromString));

    Lua.register(state, 'keyPressed', cpp.Callable.fromStaticFunction(lua_keyPressed));
    Lua.register(state, 'keyJustPressed', cpp.Callable.fromStaticFunction(lua_keyJustPressed));
    Lua.register(state, 'keyReleased', cpp.Callable.fromStaticFunction(lua_keyJustReleased));
    Lua.register(state, 'keyboardPressed', cpp.Callable.fromStaticFunction(lua_keyPressed));
    Lua.register(state, 'keyboardJustPressed', cpp.Callable.fromStaticFunction(lua_keyJustPressed));
    Lua.register(state, 'keyboardReleased', cpp.Callable.fromStaticFunction(lua_keyJustReleased));
    Lua.register(state, 'getMouseX', cpp.Callable.fromStaticFunction(lua_mouseX));
    Lua.register(state, 'getMouseY', cpp.Callable.fromStaticFunction(lua_mouseY));
    Lua.register(state, 'mousePressed', cpp.Callable.fromStaticFunction(lua_mousePressed));
    Lua.register(state, 'mouseClicked', cpp.Callable.fromStaticFunction(lua_mouseJustPressed));
    Lua.register(state, 'mouseReleased', cpp.Callable.fromStaticFunction(lua_mouseJustReleased));
    Lua.register(state, 'gamepadPressed', cpp.Callable.fromStaticFunction(lua_gamepadPressed));
    Lua.register(state, 'gamepadJustPressed', cpp.Callable.fromStaticFunction(lua_gamepadJustPressed));
    Lua.register(state, 'gamepadReleased', cpp.Callable.fromStaticFunction(lua_gamepadReleased));
    Lua.register(state, 'anyGamepadPressed', cpp.Callable.fromStaticFunction(lua_anyGamepadPressed));
    Lua.register(state, 'anyGamepadJustPressed', cpp.Callable.fromStaticFunction(lua_anyGamepadJustPressed));
    Lua.register(state, 'anyGamepadReleased', cpp.Callable.fromStaticFunction(lua_anyGamepadReleased));
    Lua.register(state, 'gamepadAnalogX', cpp.Callable.fromStaticFunction(lua_gamepadAnalogX));
    Lua.register(state, 'gamepadAnalogY', cpp.Callable.fromStaticFunction(lua_gamepadAnalogY));

    Lua.register(state, 'initLuaShader', cpp.Callable.fromStaticFunction(lua_initLuaShader));
    Lua.register(state, 'setSpriteShader', cpp.Callable.fromStaticFunction(lua_setShaderOnSprite));
    Lua.register(state, 'removeSpriteShader', cpp.Callable.fromStaticFunction(lua_clearShader));
    Lua.register(state, 'setShaderFloat', cpp.Callable.fromStaticFunction(lua_setShaderFloat));
    Lua.register(state, 'setShaderFloatArray', cpp.Callable.fromStaticFunction(lua_setShaderFloatArray));
    Lua.register(state, 'setShaderInt', cpp.Callable.fromStaticFunction(lua_setShaderInt));
    Lua.register(state, 'setShaderIntArray', cpp.Callable.fromStaticFunction(lua_setShaderFloatArray));
    Lua.register(state, 'setShaderBool', cpp.Callable.fromStaticFunction(lua_setShaderBool));
    Lua.register(state, 'setShaderBoolArray', cpp.Callable.fromStaticFunction(lua_setShaderFloatArray));
    Lua.register(state, 'getShaderFloat', cpp.Callable.fromStaticFunction(lua_getShaderFloat));
    Lua.register(state, 'getShaderFloatArray', cpp.Callable.fromStaticFunction(lua_getShaderFloatArray));
    Lua.register(state, 'getShaderInt', cpp.Callable.fromStaticFunction(lua_getShaderInt));
    Lua.register(state, 'getShaderIntArray', cpp.Callable.fromStaticFunction(lua_getShaderIntArray));
    Lua.register(state, 'getShaderBool', cpp.Callable.fromStaticFunction(lua_getShaderBool));
    Lua.register(state, 'getShaderBoolArray', cpp.Callable.fromStaticFunction(lua_getShaderBoolArray));
    Lua.register(state, 'setShaderSampler2D', cpp.Callable.fromStaticFunction(lua_setShaderSampler2D));

    Lua.register(state, 'precacheImage', cpp.Callable.fromStaticFunction(lua_precacheImage));
    Lua.register(state, 'precacheSound', cpp.Callable.fromStaticFunction(lua_precacheSound));
    Lua.register(state, 'precacheMusic', cpp.Callable.fromStaticFunction(lua_precacheMusic));
    Lua.register(state, 'openCustomSubstate', cpp.Callable.fromStaticFunction(lua_openCustomSubstate));
    Lua.register(state, 'closeCustomSubstate', cpp.Callable.fromStaticFunction(lua_closeCustomSubstate));
    Lua.register(state, 'insertToCustomSubstate', cpp.Callable.fromStaticFunction(lua_insertToCustomSubstate));
    Lua.register(state, 'addHScript', cpp.Callable.fromStaticFunction(lua_unsupported));
    Lua.register(state, 'removeHScript', cpp.Callable.fromStaticFunction(lua_unsupported));
    Lua.register(state, 'runHaxeCode', cpp.Callable.fromStaticFunction(lua_unsupported));
    Lua.register(state, 'runHaxeFunction', cpp.Callable.fromStaticFunction(lua_unsupported));
    Lua.register(state, 'addHaxeLibrary', cpp.Callable.fromStaticFunction(lua_unsupported));
  }

  function installSimpleAPI():Void
  {
  }
  function registerPsychStyleAliases():Void
  {
    Lua.register(state, 'makeLuaSprite', cpp.Callable.fromStaticFunction(lua_addSprite));
    Lua.register(state, 'makeAnimatedLuaSprite', cpp.Callable.fromStaticFunction(lua_addAnimatedSpriteAlias));
    Lua.register(state, 'makeGraphic', cpp.Callable.fromStaticFunction(lua_makeGraphicAlias));
    Lua.register(state, 'addLuaSprite', cpp.Callable.fromStaticFunction(lua_noopTrue));
    Lua.register(state, 'removeLuaSprite', cpp.Callable.fromStaticFunction(lua_removeSprite));
    Lua.register(state, 'makeLuaText', cpp.Callable.fromStaticFunction(lua_makeLuaTextAlias));
    Lua.register(state, 'setTextString', cpp.Callable.fromStaticFunction(lua_setText));
    Lua.register(state, 'removeLuaText', cpp.Callable.fromStaticFunction(lua_removeText));
    Lua.register(state, 'doTween', cpp.Callable.fromStaticFunction(lua_tween));
    Lua.register(state, 'doTweenX', cpp.Callable.fromStaticFunction(lua_tweenObjectX));
    Lua.register(state, 'doTweenY', cpp.Callable.fromStaticFunction(lua_tweenObjectY));
    Lua.register(state, 'doTweenAlpha', cpp.Callable.fromStaticFunction(lua_tweenObjectAlpha));
    Lua.register(state, 'doTweenAngle', cpp.Callable.fromStaticFunction(lua_tweenObjectAngle));
    Lua.register(state, 'runTimer', cpp.Callable.fromStaticFunction(lua_runTimer));
    Lua.register(state, 'cancelTimer', cpp.Callable.fromStaticFunction(lua_cancelTimer));
  }

  function pushValue(value:Dynamic):Void
  {
    if (value == null)
    {
      Lua.pushnil(state);
    }
    else if (Std.isOfType(value, Bool))
    {
      Lua.pushboolean(state, value ? 1 : 0);
    }
    else if (Std.isOfType(value, Int))
    {
      Lua.pushinteger(state, cast(value, Int));
    }
    else if (Std.isOfType(value, Float))
    {
      Lua.pushnumber(state, cast(value, Float));
    }
    else if (Std.isOfType(value, Array))
    {
      pushArray(cast value);
    }
    else if (Reflect.isObject(value) && !Std.isOfType(value, String))
    {
      pushTable(value);
    }
    else
    {
      Lua.pushstring(state, Std.string(value));
    }
  }

  function pushArray(values:Array<Dynamic>):Void
  {
    Lua.createtable(state, values.length, 0);

    for (i in 0...values.length)
    {
      pushValue(values[i]);
      Lua.rawseti(state, -2, i + 1);
    }
  }

  function pushTable(value:Dynamic):Void
  {
    Lua.createtable(state, 0, 0);

    var fields:Array<String> = [];
    try
    {
      fields = Reflect.fields(value);
    }
    catch (e)
    {
      return;
    }

    for (field in fields)
    {
      pushValue(safeField(value, field));
      Lua.setfield(state, -2, field);
    }
  }

  function pushReturn(value:Dynamic):Int
  {
    pushValue(value);
    return 1;
  }

  function readError():String
  {
    var message:String = Std.string(Lua.tostring(state, -1));
    Lua.settop(state, -2);
    return message;
  }

  function eventToPayload(event:ScriptEvent):Dynamic
  {
    var payload:Dynamic = {
      type: Std.string(event.type),
      cancelable: event.cancelable,
      eventCanceled: event.eventCanceled
    };

    var fields:Array<String> = [];
    try
    {
      fields = Reflect.fields(event);
    }
    catch (e)
    {
      return payload;
    }

    for (field in fields)
    {
      var value = safeField(event, field);
      if (field == 'note' && value != null)
      {
        Reflect.setField(payload, 'note', {
          strumTime: safeGetProperty(value, 'strumTime'),
          direction: stringifyNullable(safeGetProperty(value, 'direction')),
          noteData: stringifyNullable(safeGetProperty(value, 'noteData')),
          kind: stringifyNullable(safeGetProperty(value, 'kind'))
        });
      }
      else if (field == 'eventData' && value != null)
      {
        Reflect.setField(payload, 'eventData', {
          eventKind: Std.string(safeGetProperty(value, 'eventKind')),
          value: Std.string(safeGetProperty(value, 'value')),
          time: safeGetProperty(value, 'time')
        });
      }
      else if (!Std.isOfType(value, FlxSprite))
      {
        Reflect.setField(payload, field, value);
      }
    }

    return payload;
  }

  static function stringifyNullable(value:Dynamic):Null<String>
  {
    return value == null ? null : Std.string(value);
  }
  static function current():Null<LuaScriptManager>
  {
    return activeManager;
  }

  static function lua_unsupported(L:cpp.RawPointer<Lua_State>):Int
  {
    return current()?.pushReturn(false) ?? 0;
  }

  static function lua_getVar(L:cpp.RawPointer<Lua_State>):Int
  {
    final manager = current();
    if (manager == null) return 0;
    return manager.pushReturn(manager.objects.get(readString(L, 1, '')));
  }

  static function lua_setVar(L:cpp.RawPointer<Lua_State>):Int
  {
    final manager = current();
    if (manager == null) return 0;
    final name = readString(L, 1, '');
    if (name == '') return manager.pushReturn(false);
    manager.objects.set(name, manager.readValue(L, 2));
    return manager.pushReturn(true);
  }

  static function lua_instanceArg(L:cpp.RawPointer<Lua_State>):Int
  {
    return current()?.pushReturn('##PSYCH_INSTANCE##' + readString(L, 1, '')) ?? 0;
  }

  static function lua_addLuaScript(L:cpp.RawPointer<Lua_State>):Int
  {
    final manager = current();
    if (manager == null) return 0;
    final path = manager.resolveLuaScriptPath(readString(L, 1, ''));
    if (path == null) return manager.pushReturn(false);
    if (readBool(L, 2, false) && manager.findLoadedScript(path) != null) return manager.pushReturn(true);
    return manager.pushReturn(manager.loadScript(path));
  }

  static function lua_removeLuaScript(L:cpp.RawPointer<Lua_State>):Int
  {
    final manager = current();
    if (manager == null) return 0;
    return manager.pushReturn(manager.removeLoadedScript(readString(L, 1, '')));
  }

  static function lua_callScript(L:cpp.RawPointer<Lua_State>):Int
  {
    final manager = current();
    if (manager == null) return 0;
    final scriptPath = manager.findLoadedScript(readString(L, 1, ''));
    if (scriptPath == null) return manager.pushReturn(FUNCTION_CONTINUE);
    final argsValue = manager.readValue(L, 3);
    final args:Array<Dynamic> = Std.isOfType(argsValue, Array) ? cast argsValue : [];
    return manager.pushReturn(manager.callScriptHookResult(scriptPath, readString(L, 2, ''), args));
  }

  static function lua_getRunningScripts(L:cpp.RawPointer<Lua_State>):Int
  {
    final manager = current();
    return manager?.pushReturn(manager.loadedScripts.copy()) ?? 0;
  }

  static function lua_isRunning(L:cpp.RawPointer<Lua_State>):Int
  {
    final manager = current();
    return manager?.pushReturn(manager.findLoadedScript(readString(L, 1, '')) != null) ?? 0;
  }

  static function lua_closeScript(L:cpp.RawPointer<Lua_State>):Int
  {
    final manager = current();
    if (manager == null || manager.currentLuaFiles.length == 0) return manager?.pushReturn(false) ?? 0;
    return manager.pushReturn(manager.removeLoadedScript(manager.currentLuaFiles[0]));
  }

  static function lua_setOnScripts(L:cpp.RawPointer<Lua_State>):Int
  {
    final manager = current();
    if (manager == null) return 0;
    manager.setGlobal(readString(L, 1, ''), manager.readValue(L, 2));
    return manager.pushReturn(true);
  }

  static function lua_callOnScripts(L:cpp.RawPointer<Lua_State>):Int
  {
    final manager = current();
    if (manager == null) return 0;
    final argsValue = manager.readValue(L, 2);
    final args:Array<Dynamic> = Std.isOfType(argsValue, Array) ? cast argsValue : [];
    return manager.pushReturn(manager.callHookResult(readString(L, 1, ''), args));
  }

  static function lua_getPropertyFromGroup(L:cpp.RawPointer<Lua_State>):Int
  {
    final manager = current();
    if (manager == null) return 0;
    final item = manager.resolveGroupItem(readString(L, 1, ''), readInt(L, 2, 0));
    if (item == null) return manager.pushReturn(null);
    final property = readString(L, 3, '');
    return manager.pushReturn(property == '' ? item : manager.resolveRelativePath(item, property));
  }

  static function lua_setPropertyFromGroup(L:cpp.RawPointer<Lua_State>):Int
  {
    final manager = current();
    if (manager == null) return 0;
    final item = manager.resolveGroupItem(readString(L, 1, ''), readInt(L, 2, 0));
    if (item == null) return manager.pushReturn(false);
    return manager.pushReturn(manager.setRelativePath(item, readString(L, 3, ''), manager.readValue(L, 4)));
  }

  static function lua_getPropertyLuaSprite(L:cpp.RawPointer<Lua_State>):Int
  {
    final manager = current();
    if (manager == null) return 0;
    final object = manager.resolvePath(readString(L, 1, '')).value;
    return manager.pushReturn(manager.resolveRelativePath(object, readString(L, 2, '')));
  }

  static function lua_setPropertyLuaSprite(L:cpp.RawPointer<Lua_State>):Int
  {
    final manager = current();
    if (manager == null) return 0;
    final object = manager.resolvePath(readString(L, 1, '')).value;
    return manager.pushReturn(manager.setRelativePath(object, readString(L, 2, ''), manager.readValue(L, 3)));
  }

  static function lua_addToGroup(L:cpp.RawPointer<Lua_State>):Int
  {
    final manager = current();
    if (manager == null) return 0;
    final group = manager.resolvePath(readString(L, 1, '')).value;
    final object = manager.resolvePath(readString(L, 2, '')).value;
    if (group == null || object == null) return manager.pushReturn(false);
    final index = readInt(L, 3, -1);
    final method = manager.safeField(group, index < 0 ? 'add' : 'insert');
    return manager.pushReturn(method != null && manager.safeCallMethod(group, method, index < 0 ? [object] : [index, object]).ok);
  }

  static function lua_removeFromGroup(L:cpp.RawPointer<Lua_State>):Int
  {
    final manager = current();
    if (manager == null) return 0;
    final group = manager.resolvePath(readString(L, 1, '')).value;
    var object = readString(L, 3, '') == '' ? manager.resolveGroupItem(readString(L, 1, ''), readInt(L, 2, -1)) : manager.resolvePath(readString(L, 3, '')).value;
    if (group == null || object == null) return manager.pushReturn(false);
    final remove = manager.safeField(group, 'remove');
    if (remove == null) return manager.pushReturn(false);
    final result = manager.safeCallMethod(group, remove, [object, true]).ok;
    if (result && readBool(L, 4, true))
    {
      final destroy = manager.safeField(object, 'destroy');
      if (destroy != null) manager.safeCallMethod(object, destroy, []);
    }
    return manager.pushReturn(result);
  }

  static function lua_updateHitboxFromGroup(L:cpp.RawPointer<Lua_State>):Int
  {
    final manager = current();
    if (manager == null) return 0;
    final item = manager.resolveGroupItem(readString(L, 1, ''), readInt(L, 2, 0));
    final method = item == null ? null : manager.safeField(item, 'updateHitbox');
    return manager.pushReturn(method != null && manager.safeCallMethod(item, method, []).ok);
  }

  static function lua_getModSetting(L:cpp.RawPointer<Lua_State>):Int
  {
    final manager = current();
    if (manager == null) return 0;
    final key = readString(L, 1, '');
    final modName = readString(L, 2, '');
    for (root in [modName == '' ? 'mods' : 'mods/${modName}'])
    {
      final path = '${root}/data/settings.json';
      if (!FileSystem.exists(path)) continue;
      try
      {
        final data = Json.parse(File.getContent(path));
        return manager.pushReturn(Reflect.field(data, key));
      }
      catch (error) {}
    }
    return manager.pushReturn(null);
  }

  static function lua_psychMakeLuaSprite(L:cpp.RawPointer<Lua_State>):Int
  {
    return psychMakeSprite(L, false, false);
  }

  static function lua_psychMakeAnimatedLuaSprite(L:cpp.RawPointer<Lua_State>):Int
  {
    return psychMakeSprite(L, true, false);
  }

  static function lua_psychMakeFlxAnimateSprite(L:cpp.RawPointer<Lua_State>):Int
  {
    return psychMakeSprite(L, true, true);
  }

  static function psychMakeSprite(L:cpp.RawPointer<Lua_State>, animated:Bool, textureAtlas:Bool):Int
  {
    final manager = current();
    if (manager == null) return 0;
    final tag = readString(L, 1, '');
    final asset = readString(L, 2, '');
    if (tag == '') return manager.pushReturn(false);
    manager.removeSprite(tag);
    try
    {
      final x = readFloat(L, 3, 0);
      final y = readFloat(L, 4, 0);
      final sprite = asset == '' ? new FunkinSprite(x, y) : textureAtlas ? FunkinSprite.createTextureAtlas(x, y, asset) : animated ? FunkinSprite.createSparrow(x,
        y, asset) : FunkinSprite.create(x, y, asset);
      manager.sprites.set(tag, sprite);
      return manager.pushReturn(true);
    }
    catch (error)
    {
      manager.reportLuaWarning('api-error', 'lua-api', 'makeLuaSprite', Std.string(error));
      return manager.pushReturn(false);
    }
  }

  static function lua_psychAddLuaSprite(L:cpp.RawPointer<Lua_State>):Int
  {
    final manager = current();
    final playState = PlayState.instance;
    if (manager == null || playState == null) return 0;
    final sprite = manager.sprites.get(readString(L, 1, ''));
    if (sprite == null) return manager.pushReturn(false);
    if (readBool(L, 2, false)) sprite.zIndex = 1000000;
    if (!playState.members.contains(sprite)) playState.add(sprite);
    playState.refresh();
    return manager.pushReturn(true);
  }

  static function lua_psychLoadGraphic(L:cpp.RawPointer<Lua_State>):Int
  {
    final manager = current();
    if (manager == null) return 0;
    final sprite = manager.sprites.get(readString(L, 1, ''));
    if (sprite == null) return manager.pushReturn(false);
    try
    {
      sprite.loadGraphic(Paths.image(readString(L, 2, '')), readBool(L, 3, false), readInt(L, 4, 0), readInt(L, 5, 0));
      return manager.pushReturn(true);
    }
    catch (error)
    {
      return manager.pushReturn(false);
    }
  }

  static function lua_psychLoadFrames(L:cpp.RawPointer<Lua_State>):Int
  {
    final manager = current();
    if (manager == null) return 0;
    final sprite = manager.sprites.get(readString(L, 1, ''));
    if (sprite == null) return manager.pushReturn(false);
    final image = readString(L, 2, '');
    final type = readString(L, 3, 'sparrow').toLowerCase();
    try
    {
      sprite.frames = type == 'packer' ? Paths.getPackerAtlas(image) : Paths.getSparrowAtlas(image);
      return manager.pushReturn(true);
    }
    catch (error)
    {
      return manager.pushReturn(false);
    }
  }

  static function lua_psychLoadMultipleFrames(L:cpp.RawPointer<Lua_State>):Int
  {
    return lua_psychLoadFrames(L);
  }

  static function lua_psychLoadAnimateAtlas(L:cpp.RawPointer<Lua_State>):Int
  {
    final manager = current();
    if (manager == null) return 0;
    final tag = readString(L, 1, '');
    final oldSprite = manager.sprites.get(tag);
    if (oldSprite == null) return manager.pushReturn(false);
    try
    {
      final sprite = FunkinSprite.createTextureAtlas(oldSprite.x, oldSprite.y, readString(L, 2, ''));
      sprite.zIndex = oldSprite.zIndex;
      sprite.cameras = oldSprite.cameras;
      manager.replaceSprite(tag, oldSprite, sprite);
      return manager.pushReturn(true);
    }
    catch (error)
    {
      return manager.pushReturn(false);
    }
  }

  static function lua_luaSpriteExists(L:cpp.RawPointer<Lua_State>):Int
  {
    return current()?.pushReturn(current()?.sprites.exists(readString(L, 1, '')) ?? false) ?? 0;
  }

  static function lua_addAnimation(L:cpp.RawPointer<Lua_State>):Int
  {
    final manager = current();
    if (manager == null) return 0;
    final sprite = manager.sprites.get(readString(L, 1, ''));
    if (sprite == null) return manager.pushReturn(false);
    final framesValue = manager.readValue(L, 3);
    final frames:Array<Int> = [];
    if (Std.isOfType(framesValue, Array)) for (frame in cast(framesValue, Array<Dynamic>)) frames.push(Std.int(frame));
    sprite.animation.add(readString(L, 2, ''), frames, readInt(L, 4, 24), readBool(L, 5, false));
    return manager.pushReturn(true);
  }

  static function lua_addAnimationByIndices(L:cpp.RawPointer<Lua_State>):Int
  {
    return psychAddAnimationByIndices(L, false);
  }

  static function lua_addAnimationByIndicesLoop(L:cpp.RawPointer<Lua_State>):Int
  {
    return psychAddAnimationByIndices(L, true);
  }

  static function psychAddAnimationByIndices(L:cpp.RawPointer<Lua_State>, forceLoop:Bool):Int
  {
    final manager = current();
    if (manager == null) return 0;
    final sprite = manager.sprites.get(readString(L, 1, ''));
    if (sprite == null) return manager.pushReturn(false);
    final indicesValue = manager.readValue(L, 4);
    final indices:Array<Int> = [];
    if (Std.isOfType(indicesValue, Array)) for (index in cast(indicesValue, Array<Dynamic>)) indices.push(Std.int(index));
    sprite.animation.addByIndices(readString(L, 2, ''), readString(L, 3, ''), indices, '', readInt(L, 5, 24), forceLoop || readBool(L, 6, false));
    return manager.pushReturn(true);
  }

  static function lua_addAnimationBySymbol(L:cpp.RawPointer<Lua_State>):Int
  {
    return psychCallAnimationMethod(L, 'addBySymbol', [readString(L, 2, ''), readString(L, 3, ''), readInt(L, 4, 24), readBool(L, 5, false),
      readFloat(L, 6, 0), readFloat(L, 7, 0)]);
  }

  static function lua_addAnimationBySymbolIndices(L:cpp.RawPointer<Lua_State>):Int
  {
    final manager = current();
    final indices = manager?.readValue(L, 4);
    return psychCallAnimationMethod(L, 'addBySymbolIndices',
      [readString(L, 2, ''), readString(L, 3, ''), indices, readInt(L, 5, 24), readBool(L, 6, false), readFloat(L, 7, 0), readFloat(L, 8, 0)]);
  }

  static function psychCallAnimationMethod(L:cpp.RawPointer<Lua_State>, methodName:String, args:Array<Dynamic>):Int
  {
    final manager = current();
    if (manager == null) return 0;
    final sprite = manager.sprites.get(readString(L, 1, ''));
    final method = sprite == null ? null : manager.safeField(sprite, methodName);
    return manager.pushReturn(method != null && manager.safeCallMethod(sprite, method, args).ok);
  }

  static function lua_psychScaleObject(L:cpp.RawPointer<Lua_State>):Int
  {
    return lua_setObjectScale(L);
  }

  static function lua_psychSetGraphicSize(L:cpp.RawPointer<Lua_State>):Int
  {
    return lua_setObjectSize(L);
  }

  static function lua_updateHitbox(L:cpp.RawPointer<Lua_State>):Int
  {
    final manager = current();
    if (manager == null) return 0;
    final target = manager.resolvePath(readString(L, 1, '')).value;
    final method = target == null ? null : manager.safeField(target, 'updateHitbox');
    return manager.pushReturn(method != null && manager.safeCallMethod(target, method, []).ok);
  }

  static function lua_getObjectOrder(L:cpp.RawPointer<Lua_State>):Int
  {
    final manager = current();
    if (manager == null) return 0;
    return manager.pushReturn(manager.safeGetProperty(manager.resolvePath(readString(L, 1, '')).value, 'zIndex') ?? 0);
  }

  static function lua_setBlendMode(L:cpp.RawPointer<Lua_State>):Int
  {
    final manager = current();
    if (manager == null) return 0;
    final target = manager.resolvePath(readString(L, 1, '')).value;
    final mode = readString(L, 2, 'normal').toLowerCase();
    final blend:BlendMode = switch (mode)
    {
      case 'add': BlendMode.ADD;
      case 'multiply': BlendMode.MULTIPLY;
      case 'screen': BlendMode.SCREEN;
      case 'subtract': BlendMode.SUBTRACT;
      case 'darken': BlendMode.DARKEN;
      case 'lighten': BlendMode.LIGHTEN;
      default: BlendMode.NORMAL;
    };
    return manager.pushReturn(target != null && manager.safeSetProperty(target, 'blend', blend));
  }

  static function lua_getPixelColor(L:cpp.RawPointer<Lua_State>):Int
  {
    final manager = current();
    if (manager == null) return 0;
    final target = manager.resolvePath(readString(L, 1, '')).value;
    if (!Std.isOfType(target, FlxSprite)) return manager.pushReturn(0);
    return manager.pushReturn(cast(target, FlxSprite).pixels.getPixel32(readInt(L, 2, 0), readInt(L, 3, 0)));
  }

  static function lua_objectsOverlap(L:cpp.RawPointer<Lua_State>):Int
  {
    final manager = current();
    if (manager == null) return 0;
    final first = manager.resolvePath(readString(L, 1, '')).value;
    final second = manager.resolvePath(readString(L, 2, '')).value;
    return manager.pushReturn(first != null && second != null && FlxG.overlap(first, second));
  }

  static function lua_getMidpointX(L:cpp.RawPointer<Lua_State>):Int return psychGetPoint(L, 'getMidpoint', 'x');
  static function lua_getMidpointY(L:cpp.RawPointer<Lua_State>):Int return psychGetPoint(L, 'getMidpoint', 'y');
  static function lua_getGraphicMidpointX(L:cpp.RawPointer<Lua_State>):Int return psychGetPoint(L, 'getGraphicMidpoint', 'x');
  static function lua_getGraphicMidpointY(L:cpp.RawPointer<Lua_State>):Int return psychGetPoint(L, 'getGraphicMidpoint', 'y');
  static function lua_getScreenPositionX(L:cpp.RawPointer<Lua_State>):Int return psychGetPoint(L, 'getScreenPosition', 'x');
  static function lua_getScreenPositionY(L:cpp.RawPointer<Lua_State>):Int return psychGetPoint(L, 'getScreenPosition', 'y');

  static function psychGetPoint(L:cpp.RawPointer<Lua_State>, methodName:String, field:String):Int
  {
    final manager = current();
    if (manager == null) return 0;
    final target = manager.resolvePath(readString(L, 1, '')).value;
    final method = target == null ? null : manager.safeField(target, methodName);
    if (method == null) return manager.pushReturn(0);
    final point = manager.safeCallMethod(target, method, []).value;
    return manager.pushReturn(manager.safeGetProperty(point, field) ?? 0);
  }

  static function lua_psychAddLuaText(L:cpp.RawPointer<Lua_State>):Int
  {
    final manager = current();
    final playState = PlayState.instance;
    if (manager == null || playState == null) return 0;
    final text = manager.texts.get(readString(L, 1, ''));
    if (text == null) return manager.pushReturn(false);
    if (!playState.members.contains(text)) playState.add(text);
    playState.refresh();
    return manager.pushReturn(true);
  }

  static function lua_luaTextExists(L:cpp.RawPointer<Lua_State>):Int
  {
    final manager = current();
    return manager?.pushReturn(manager.texts.exists(readString(L, 1, ''))) ?? 0;
  }

  static function lua_getTextString(L:cpp.RawPointer<Lua_State>):Int return psychGetTextField(L, 'text', '');
  static function lua_getTextSize(L:cpp.RawPointer<Lua_State>):Int return psychGetTextField(L, 'size', 0);
  static function lua_getTextWidth(L:cpp.RawPointer<Lua_State>):Int return psychGetTextField(L, 'width', 0);
  static function lua_getTextFont(L:cpp.RawPointer<Lua_State>):Int return psychGetTextField(L, 'font', '');

  static function psychGetTextField(L:cpp.RawPointer<Lua_State>, field:String, fallback:Dynamic):Int
  {
    final manager = current();
    if (manager == null) return 0;
    final text = manager.texts.get(readString(L, 1, ''));
    return manager.pushReturn(text == null ? fallback : manager.safeGetProperty(text, field) ?? fallback);
  }

  static function lua_setTextSize(L:cpp.RawPointer<Lua_State>):Int return psychSetTextField(L, 'size', readInt(L, 2, 16));
  static function lua_setTextWidth(L:cpp.RawPointer<Lua_State>):Int return psychSetTextField(L, 'fieldWidth', readFloat(L, 2, 0));
  static function lua_setTextHeight(L:cpp.RawPointer<Lua_State>):Int return psychSetTextField(L, 'fieldHeight', readFloat(L, 2, 0));
  static function lua_setTextColor(L:cpp.RawPointer<Lua_State>):Int return psychSetTextField(L, 'color', readColor(L, 2, FlxColor.WHITE));
  static function lua_setTextItalic(L:cpp.RawPointer<Lua_State>):Int return psychSetTextField(L, 'italic', readBool(L, 2, true));
  static function lua_setTextAutoSize(L:cpp.RawPointer<Lua_State>):Int return psychSetTextField(L, 'autoSize', readBool(L, 2, true));

  static function psychSetTextField(L:cpp.RawPointer<Lua_State>, field:String, value:Dynamic):Int
  {
    final manager = current();
    if (manager == null) return 0;
    final text = manager.texts.get(readString(L, 1, ''));
    return manager.pushReturn(text != null && manager.safeSetProperty(text, field, value));
  }

  static function lua_setTextFont(L:cpp.RawPointer<Lua_State>):Int
  {
    final manager = current();
    if (manager == null) return 0;
    final text = manager.texts.get(readString(L, 1, ''));
    if (text == null) return manager.pushReturn(false);
    try
    {
      text.font = Paths.font(readString(L, 2, 'vcr.ttf'));
      return manager.pushReturn(true);
    }
    catch (error)
    {
      return manager.pushReturn(false);
    }
  }

  static function lua_setTextAlignment(L:cpp.RawPointer<Lua_State>):Int
  {
    final manager = current();
    if (manager == null) return 0;
    final text = manager.texts.get(readString(L, 1, ''));
    if (text == null) return manager.pushReturn(false);
    text.alignment = readTextAlign(L, 2, text.alignment);
    return manager.pushReturn(true);
  }

  static function lua_setTextBorder(L:cpp.RawPointer<Lua_State>):Int
  {
    final manager = current();
    if (manager == null) return 0;
    final text = manager.texts.get(readString(L, 1, ''));
    if (text == null) return manager.pushReturn(false);
    text.borderSize = readFloat(L, 2, 1);
    text.borderColor = readColor(L, 3, FlxColor.BLACK);
    text.borderStyle = switch (readString(L, 4, 'outline').toLowerCase())
    {
      case 'shadow': FlxTextBorderStyle.SHADOW;
      case 'outline_fast': FlxTextBorderStyle.OUTLINE_FAST;
      case 'none': FlxTextBorderStyle.NONE;
      default: FlxTextBorderStyle.OUTLINE;
    };
    return manager.pushReturn(true);
  }

  static function lua_doTweenColor(L:cpp.RawPointer<Lua_State>):Int
  {
    final manager = current();
    if (manager == null) return 0;
    final tag = readString(L, 1, '');
    final target = manager.resolvePath(readString(L, 2, '')).value;
    if (tag == '' || target == null) return manager.pushReturn(false);
    final from:FlxColor = manager.safeGetProperty(target, 'color') ?? FlxColor.WHITE;
    final to = readColor(L, 3, from);
    final duration = readFloat(L, 4, 1);
    manager.cancelTween(tag);
    final tween = FlxTween.color(cast target, duration, from, to, {
      ease: resolveEase(readString(L, 5, 'linear')),
      onComplete: function(_)
      {
        manager.tweens.remove(tag);
        manager.callHook('onTweenCompleted', [tag]);
      }
    });
    manager.tweens.set(tag, tween);
    return manager.pushReturn(true);
  }

  static function lua_startTween(L:cpp.RawPointer<Lua_State>):Int
  {
    final manager = current();
    if (manager == null) return 0;
    final tag = readString(L, 1, '');
    final target = manager.resolvePath(readString(L, 2, '')).value;
    final values = manager.readValue(L, 3);
    if (tag == '' || target == null || values == null) return manager.pushReturn(false);
    final options = manager.readValue(L, 5);
    final ease = options == null ? 'linear' : Std.string(manager.safeField(options, 'ease') ?? 'linear');
    manager.cancelTween(tag);
    final tween = FlxTween.tween(target, values, readFloat(L, 4, 1), {
      ease: resolveEase(ease),
      startDelay: options == null ? 0 : manager.numericField(options, 'startDelay', 0),
      loopDelay: options == null ? 0 : manager.numericField(options, 'loopDelay', 0),
      onComplete: function(_)
      {
        manager.tweens.remove(tag);
        manager.callHook('onTweenCompleted', [tag]);
      }
    });
    manager.tweens.set(tag, tween);
    return manager.pushReturn(true);
  }

  static function lua_noteTweenX(L:cpp.RawPointer<Lua_State>):Int return psychNoteTween(L, 'x');
  static function lua_noteTweenY(L:cpp.RawPointer<Lua_State>):Int return psychNoteTween(L, 'y');
  static function lua_noteTweenAngle(L:cpp.RawPointer<Lua_State>):Int return psychNoteTween(L, 'angle');
  static function lua_noteTweenAlpha(L:cpp.RawPointer<Lua_State>):Int return psychNoteTween(L, 'alpha');
  static function lua_noteTweenDirection(L:cpp.RawPointer<Lua_State>):Int return psychNoteTween(L, 'direction');

  static function psychNoteTween(L:cpp.RawPointer<Lua_State>, field:String):Int
  {
    final manager = current();
    if (manager == null) return 0;
    final target = manager.resolvePsychStrumNote(readInt(L, 2, 0));
    final tag = readString(L, 1, '');
    if (target == null || tag == '') return manager.pushReturn(false);
    final values:Dynamic = {};
    Reflect.setField(values, field, readFloat(L, 3, manager.numericField(target, field, 0)));
    manager.cancelTween(tag);
    final tween = FlxTween.tween(target, values, readFloat(L, 4, 1), {
      ease: resolveEase(readString(L, 5, 'linear')),
      onComplete: function(_)
      {
        manager.tweens.remove(tag);
        manager.callHook('onTweenCompleted', [tag]);
      }
    });
    manager.tweens.set(tag, tween);
    return manager.pushReturn(true);
  }

  static function lua_debugPrint(L:cpp.RawPointer<Lua_State>):Int
  {
    return lua_debugLog(L, 'print');
  }

  static function lua_debugInfo(L:cpp.RawPointer<Lua_State>):Int
  {
    return lua_debugLog(L, 'info');
  }

  static function lua_debugWarn(L:cpp.RawPointer<Lua_State>):Int
  {
    return lua_debugLog(L, 'warn');
  }

  static function lua_debugError(L:cpp.RawPointer<Lua_State>):Int
  {
    return lua_debugLog(L, 'error');
  }

  static function lua_debugLog(L:cpp.RawPointer<Lua_State>, level:String):Int
  {
    var message = readString(L, 1, '');
    trace('[Lua:${level}] ${message}');
    return 0;
  }

  static function lua_reloadLuaScripts(L:cpp.RawPointer<Lua_State>):Int
  {
    var manager = current();
    if (manager == null) return 0;

    var playState = PlayState.instance;
    if (playState == null) return manager.pushReturn(false);

    return manager.pushReturn(manager.reloadScripts());
  }

  static function lua_noopTrue(L:cpp.RawPointer<Lua_State>):Int
  {
    return current()?.pushReturn(true) ?? 0;
  }

  static function lua_getCurrentEvent(L:cpp.RawPointer<Lua_State>):Int
  {
    var manager = current();
    if (manager == null) return 0;
    if (manager.currentEvent == null) return manager.pushReturn(null);
    return manager.pushReturn(manager.eventToPayload(manager.currentEvent));
  }

  static function lua_getEventField(L:cpp.RawPointer<Lua_State>):Int
  {
    var manager = current();
    if (manager == null) return 0;
    if (manager.currentEvent == null) return manager.pushReturn(null);
    return manager.pushReturn(manager.resolveEventPath(readString(L, 1, '')).value);
  }

  static function lua_setEventField(L:cpp.RawPointer<Lua_State>):Int
  {
    var manager = current();
    if (manager == null || manager.currentEvent == null) return 0;

    var resolved = manager.resolveEventParent(readString(L, 1, ''));
    if (resolved.target == null || resolved.field == '') return manager.pushReturn(false);

    return manager.pushReturn(manager.safeSetProperty(resolved.target, resolved.field, manager.readValue(L, 2), false));
  }

  static function lua_cancelEvent(L:cpp.RawPointer<Lua_State>):Int
  {
    var manager = current();
    if (manager == null || manager.currentEvent == null) return 0;

    manager.currentEvent.cancelEvent();
    return manager.pushReturn(manager.currentEvent.eventCanceled);
  }

  static function lua_stopEventPropagation(L:cpp.RawPointer<Lua_State>):Int
  {
    var manager = current();
    if (manager == null || manager.currentEvent == null) return 0;

    manager.currentEvent.stopPropagation();
    return manager.pushReturn(true);
  }

  static function lua_getProperty(L:cpp.RawPointer<Lua_State>):Int
  {
    var manager = current();
    if (manager == null) return 0;
    return manager.pushReturn(manager.resolvePath(readString(L, 1, '')).value);
  }

  static function lua_setProperty(L:cpp.RawPointer<Lua_State>):Int
  {
    var manager = current();
    if (manager == null) return 0;

    var path = readString(L, 1, '');
    var value = manager.readValue(L, 2);
    var resolved = manager.resolveParent(path);

    if (resolved.target == null || resolved.field == '')
    {
      manager.reportLuaWarning('api-error', 'lua-api', 'setProperty', 'setProperty failed. Invalid path: ${path}');
      return manager.pushReturn(false);
    }

    return manager.pushReturn(manager.safeSetProperty(resolved.target, resolved.field, value));
  }

  static function lua_setProperties(L:cpp.RawPointer<Lua_State>):Int
  {
    var manager = current();
    if (manager == null) return 0;

    var targetPath = readString(L, 1, '');
    var values = manager.readValue(L, 2);
    var target = manager.resolvePath(targetPath).value;
    if (target == null || values == null) return manager.pushReturn(false);

    var ok = true;
    for (field in Reflect.fields(values))
    {
      ok = manager.safeSetProperty(target, field, Reflect.field(values, field)) && ok;
    }
    return manager.pushReturn(ok);
  }

  static function lua_getPropertyRef(L:cpp.RawPointer<Lua_State>):Int
  {
    var manager = current();
    if (manager == null) return 0;
    return manager.pushReturn(manager.resolvePath(readString(L, 1, '')).value);
  }

  static function lua_setPropertyRef(L:cpp.RawPointer<Lua_State>):Int
  {
    var manager = current();
    if (manager == null) return 0;

    var resolved = manager.resolveParent(readString(L, 1, ''));
    if (resolved.target == null || resolved.field == '') return manager.pushReturn(false);
    return manager.pushReturn(manager.safeSetProperty(resolved.target, resolved.field, manager.readValue(L, 2)));
  }

  static function lua_disableLuaHook(L:cpp.RawPointer<Lua_State>):Int
  {
    var manager = current();
    if (manager == null) return 0;
    var hook = readString(L, 1, '');
    if (hook == '') return manager.pushReturn(false);
    manager.setCurrentHookDisabled(hook, true);
    return manager.pushReturn(true);
  }

  static function lua_enableLuaHook(L:cpp.RawPointer<Lua_State>):Int
  {
    var manager = current();
    if (manager == null) return 0;
    var hook = readString(L, 1, '');
    if (hook == '') return manager.pushReturn(false);
    manager.setCurrentHookDisabled(hook, false);
    return manager.pushReturn(true);
  }

  static function lua_setLuaWindowTitle(L:cpp.RawPointer<Lua_State>):Int
  {
    WindowUtil.setWindowTitle(readString(L, 1, "Friday Night Funkin'"));
    return 0;
  }

  static function lua_getCurrentLuaScriptPath(L:cpp.RawPointer<Lua_State>):Int
  {
    var manager = current();
    if (manager == null) return 0;
    return manager.pushReturn(manager.currentLuaFiles.length == 0 ? '' : manager.currentLuaFiles[0]);
  }

  static function lua_stopCurrentLuaScript(L:cpp.RawPointer<Lua_State>):Int
  {
    var manager = current();
    if (manager == null || manager.currentLuaFiles.length == 0) return manager == null ? 0 : manager.pushReturn(false);
    for (hook in LuaHookCatalog.ALL) manager.setCurrentHookDisabled(hook, true);
    return manager.pushReturn(true);
  }

  static function lua_setCurrentLuaScriptPriority(L:cpp.RawPointer<Lua_State>):Int
  {
    var manager = current();
    if (manager == null || manager.currentLuaFiles.length == 0) return manager == null ? 0 : manager.pushReturn(false);
    var priority = readInt(L, 1, 0);
    for (path in manager.currentLuaFiles) manager.scriptPriorities.set(path, priority);
    manager.scriptPriorityDirty = true;
    return manager.pushReturn(true);
  }

  static function lua_callMethod(L:cpp.RawPointer<Lua_State>):Int
  {
    var manager = current();
    if (manager == null) return 0;

    var path = readString(L, 1, '');
    var args:Array<Dynamic> = [];
    var top = Lua.gettop(L);
    for (i in 2...(top + 1)) args.push(manager.readValue(L, i));

    var resolved = manager.resolveParent(path);
    if (resolved.target == null || resolved.field == '')
    {
      manager.reportLuaWarning('api-error', 'lua-api', 'callMethod', 'callMethod failed. Invalid path: ${path}');
      return 0;
    }

    var method = manager.safeField(resolved.target, resolved.field);
    if (method == null)
    {
      manager.reportLuaWarning('api-error', 'lua-api', 'callMethod', 'callMethod failed. Missing function: ${path}');
      return 0;
    }

    var called = manager.safeCallMethod(resolved.target, method, args);
    return manager.pushReturn(called.value);
  }

  static function lua_classExists(L:cpp.RawPointer<Lua_State>):Int
  {
    return current()?.pushReturn(Type.resolveClass(readString(L, 1, '')) != null) ?? 0;
  }

  static function lua_getStaticProperty(L:cpp.RawPointer<Lua_State>):Int
  {
    var manager = current();
    if (manager == null) return 0;

    var targetClass = Type.resolveClass(readString(L, 1, ''));
    if (targetClass == null) return manager.pushReturn(null);

    return manager.pushReturn(manager.safeGetProperty(targetClass, readString(L, 2, '')));
  }

  static function lua_setStaticProperty(L:cpp.RawPointer<Lua_State>):Int
  {
    var manager = current();
    if (manager == null) return 0;

    var targetClass = Type.resolveClass(readString(L, 1, ''));
    if (targetClass == null) return manager.pushReturn(false);

    return manager.pushReturn(manager.safeSetProperty(targetClass, readString(L, 2, ''), manager.readValue(L, 3)));
  }

  static function lua_callStatic(L:cpp.RawPointer<Lua_State>):Int
  {
    var manager = current();
    if (manager == null) return 0;

    var targetClass = Type.resolveClass(readString(L, 1, ''));
    if (targetClass == null) return manager.pushReturn(null);

    var method = manager.safeField(targetClass, readString(L, 2, ''));
    if (method == null) return manager.pushReturn(null);

    return manager.pushReturn(manager.safeCallMethod(targetClass, method, manager.readArgs(L, 3)).value);
  }

  static function lua_createInstance(L:cpp.RawPointer<Lua_State>):Int
  {
    var manager = current();
    if (manager == null) return 0;

    var tag = readString(L, 1, '');
    var targetClass = Type.resolveClass(readString(L, 2, ''));
    if (tag == '' || targetClass == null) return manager.pushReturn(false);

    try
    {
      final args = manager.readArgs(L, 3);
      for (index in 0...args.length)
      {
        if (!Std.isOfType(args[index], String)) continue;
        final value:String = cast args[index];
        if (StringTools.startsWith(value, '##PSYCH_INSTANCE##')) args[index] = manager.resolvePath(value.substr(18)).value;
      }
      manager.objects.set(tag, Type.createInstance(targetClass, args));
      return manager.pushReturn(true);
    }
    catch (e)
    {
      trace('[LuaScriptManager] createInstance failed: ${e}');
      return manager.pushReturn(false);
    }
  }

  static function lua_storeObject(L:cpp.RawPointer<Lua_State>):Int
  {
    var manager = current();
    if (manager == null) return 0;

    var tag = readString(L, 1, '');
    var value = manager.resolvePath(readString(L, 2, '')).value;
    if (tag == '' || value == null) return manager.pushReturn(false);

    manager.objects.set(tag, value);
    return manager.pushReturn(true);
  }

  static function lua_forgetObject(L:cpp.RawPointer<Lua_State>):Int
  {
    var manager = current();
    if (manager == null) return 0;
    return manager.pushReturn(manager.objects.remove(readString(L, 1, '')));
  }

  static function lua_addObjectToState(L:cpp.RawPointer<Lua_State>):Int
  {
    var manager = current();
    var playState = PlayState.instance;
    if (manager == null || playState == null) return 0;

    var object = manager.objects.get(readString(L, 1, ''));
    if (object == null || !Std.isOfType(object, FlxBasic)) return manager.pushReturn(false);

    playState.add(cast object);
    playState.refresh();
    return manager.pushReturn(true);
  }

  static function lua_removeObjectFromState(L:cpp.RawPointer<Lua_State>):Int
  {
    var manager = current();
    var playState = PlayState.instance;
    if (manager == null || playState == null) return 0;

    var object = manager.objects.get(readString(L, 1, ''));
    if (object == null || !Std.isOfType(object, FlxBasic)) return manager.pushReturn(false);

    playState.remove(cast object, true);
    return manager.pushReturn(true);
  }

  static function lua_destroyObject(L:cpp.RawPointer<Lua_State>):Int
  {
    var manager = current();
    if (manager == null) return 0;

    var tag = readString(L, 1, '');
    var object = manager.objects.get(tag);
    if (object == null) return manager.pushReturn(false);

    var playState = PlayState.instance;
    if (playState != null && Std.isOfType(object, FlxBasic)) playState.remove(cast object, true);
    var destroy = manager.safeField(object, 'destroy');
    if (destroy != null) manager.safeCallMethod(object, destroy, []);
    manager.objects.remove(tag);
    return manager.pushReturn(true);
  }

  static function lua_getArrayLength(L:cpp.RawPointer<Lua_State>):Int
  {
    var manager = current();
    if (manager == null) return 0;
    var value = manager.resolvePath(readString(L, 1, '')).value;
    if (value == null) return manager.pushReturn(0);
    if (Std.isOfType(value, Array)) return manager.pushReturn(cast(value, Array<Dynamic>).length);
    var length = manager.safeGetProperty(value, 'length');
    return manager.pushReturn(length ?? 0);
  }

  static function lua_getArrayItem(L:cpp.RawPointer<Lua_State>):Int
  {
    var manager = current();
    if (manager == null) return 0;
    var value = manager.resolvePath(readString(L, 1, '')).value;
    var index = readInt(L, 2, 0);
    if (value == null) return manager.pushReturn(null);
    if (Std.isOfType(value, Array)) return manager.pushReturn(cast(value, Array<Dynamic>)[index]);
    return manager.pushReturn(manager.safeGetProperty(value, Std.string(index)));
  }

  static function lua_setArrayItem(L:cpp.RawPointer<Lua_State>):Int
  {
    var manager = current();
    if (manager == null) return 0;
    var value = manager.resolvePath(readString(L, 1, '')).value;
    var index = readInt(L, 2, 0);
    var item = manager.readValue(L, 3);
    if (value == null) return manager.pushReturn(false);
    if (Std.isOfType(value, Array))
    {
      cast(value, Array<Dynamic>)[index] = item;
      return manager.pushReturn(true);
    }
    return manager.pushReturn(manager.safeSetProperty(value, Std.string(index), item));
  }

  static function lua_jsonParse(L:cpp.RawPointer<Lua_State>):Int
  {
    var manager = current();
    if (manager == null) return 0;

    try
    {
      return manager.pushReturn(Json.parse(readString(L, 1, '{}')));
    }
    catch (e)
    {
      trace('[LuaScriptManager] jsonParse failed: ${e}');
      Lua.pushnil(L);
      return 1;
    }
  }

  static function lua_jsonStringify(L:cpp.RawPointer<Lua_State>):Int
  {
    var manager = current();
    if (manager == null) return 0;

    try
    {
      return manager.pushReturn(Json.stringify(manager.readValue(L, 1), null, readString(L, 2, '')));
    }
    catch (e)
    {
      trace('[LuaScriptManager] jsonStringify failed: ${e}');
      return manager.pushReturn(null);
    }
  }

  static function lua_fileExists(L:cpp.RawPointer<Lua_State>):Int
  {
    var manager = current();
    if (manager == null) return 0;
    try
    {
      return manager.pushReturn(FileSystem.exists(readString(L, 1, '')));
    }
    catch (e)
    {
      return manager.pushReturn(false);
    }
  }

  static function lua_directoryExists(L:cpp.RawPointer<Lua_State>):Int
  {
    var manager = current();
    if (manager == null) return 0;
    var path = readString(L, 1, '');
    try
    {
      return manager.pushReturn(FileSystem.exists(path) && FileSystem.isDirectory(path));
    }
    catch (e)
    {
      return manager.pushReturn(false);
    }
  }

  static function lua_readTextFile(L:cpp.RawPointer<Lua_State>):Int
  {
    var manager = current();
    if (manager == null) return 0;

    var path = readString(L, 1, '');
    if (!FileSystem.exists(path)) return manager.pushReturn(null);

    try
    {
      return manager.pushReturn(File.getContent(path));
    }
    catch (e)
    {
      trace('[LuaScriptManager] readTextFile failed: ${e}');
      return manager.pushReturn(null);
    }
  }

  static function lua_writeTextFile(L:cpp.RawPointer<Lua_State>):Int
  {
    var manager = current();
    if (manager == null) return 0;

    try
    {
      File.saveContent(readString(L, 1, ''), readString(L, 2, ''));
      return manager.pushReturn(true);
    }
    catch (e)
    {
      trace('[LuaScriptManager] writeTextFile failed: ${e}');
      return manager.pushReturn(false);
    }
  }

  static function lua_randomFloat(L:cpp.RawPointer<Lua_State>):Int
  {
    return current()?.pushReturn(FlxG.random.float(readFloat(L, 1, 0), readFloat(L, 2, 1))) ?? 0;
  }

  static function lua_randomInt(L:cpp.RawPointer<Lua_State>):Int
  {
    return current()?.pushReturn(FlxG.random.int(readInt(L, 1, 0), readInt(L, 2, 100))) ?? 0;
  }

  static function lua_keyPressed(L:cpp.RawPointer<Lua_State>):Int
  {
    return current()?.pushReturn(FlxG.keys.checkStatus(readKey(L, 1), FlxInputState.PRESSED)) ?? 0;
  }

  static function lua_keyJustPressed(L:cpp.RawPointer<Lua_State>):Int
  {
    return current()?.pushReturn(FlxG.keys.checkStatus(readKey(L, 1), FlxInputState.JUST_PRESSED)) ?? 0;
  }

  static function lua_keyJustReleased(L:cpp.RawPointer<Lua_State>):Int
  {
    return current()?.pushReturn(FlxG.keys.checkStatus(readKey(L, 1), FlxInputState.JUST_RELEASED)) ?? 0;
  }

  static function lua_mouseX(L:cpp.RawPointer<Lua_State>):Int
  {
    return current()?.pushReturn(FlxG.mouse.x) ?? 0;
  }

  static function lua_mouseY(L:cpp.RawPointer<Lua_State>):Int
  {
    return current()?.pushReturn(FlxG.mouse.y) ?? 0;
  }

  static function lua_mousePressed(L:cpp.RawPointer<Lua_State>):Int
  {
    return current()?.pushReturn(FlxG.mouse.pressed) ?? 0;
  }

  static function lua_mouseJustPressed(L:cpp.RawPointer<Lua_State>):Int
  {
    return current()?.pushReturn(FlxG.mouse.justPressed) ?? 0;
  }

  static function lua_mouseJustReleased(L:cpp.RawPointer<Lua_State>):Int
  {
    return current()?.pushReturn(FlxG.mouse.justReleased) ?? 0;
  }

  static function lua_getSongPosition(L:cpp.RawPointer<Lua_State>):Int
  {
    return current()?.pushReturn(Conductor.instance.songPosition) ?? 0;
  }

  static function lua_getBeat(L:cpp.RawPointer<Lua_State>):Int
  {
    return current()?.pushReturn(Conductor.instance.currentBeat) ?? 0;
  }

  static function lua_getStep(L:cpp.RawPointer<Lua_State>):Int
  {
    return current()?.pushReturn(Conductor.instance.currentStep) ?? 0;
  }

  static function lua_getSongName(L:cpp.RawPointer<Lua_State>):Int
  {
    return current()?.pushReturn(PlayState.instance?.currentSong?.songName ?? '') ?? 0;
  }

  static function lua_getDifficulty(L:cpp.RawPointer<Lua_State>):Int
  {
    return current()?.pushReturn(PlayState.instance?.currentDifficulty ?? '') ?? 0;
  }

  static function lua_getVariation(L:cpp.RawPointer<Lua_State>):Int
  {
    return current()?.pushReturn(PlayState.instance?.currentVariation ?? '') ?? 0;
  }

  static function lua_getStageId(L:cpp.RawPointer<Lua_State>):Int
  {
    return current()?.pushReturn(PlayState.instance?.currentStageId ?? '') ?? 0;
  }

  static function lua_changeStage(L:cpp.RawPointer<Lua_State>):Int
  {
    final manager = current();
    final playState = PlayState.instance;
    if (manager == null || playState == null) return 0;

    final stageId:String = readString(L, 1, '');
    final accepted:Bool = false;
    if (!accepted) manager.reportLuaWarning('api-warning', 'lua-api', 'changeStage', 'changeStage failed: Unknown stage "$stageId".');
    return manager.pushReturn(accepted);
  }

  static function lua_changeCharacter(L:cpp.RawPointer<Lua_State>):Int
  {
    final manager = current();
    final playState = PlayState.instance;
    if (manager == null || playState == null) return 0;

    final targetName:String = StringTools.trim(readString(L, 1, '').toLowerCase());
    final target:Int = switch (targetName)
    {
      case 'player': 0;
      case 'opponent': 1;
      case 'girlfriend' | 'gf': 2;
      default: -1;
    };
    final characterId:String = readString(L, 2, '');
    final accepted:Bool = false;
    if (!accepted)
    {
      manager.reportLuaWarning('api-warning', 'lua-api', 'changeCharacter',
        'changeCharacter failed: Use "player", "opponent", or "girlfriend" and a valid character ID. Received "$targetName", "$characterId".');
    }
    return manager.pushReturn(accepted);
  }

  static function lua_getPlaybackRate(L:cpp.RawPointer<Lua_State>):Int
  {
    return current()?.pushReturn(PlayState.instance?.playbackRate ?? 1.0) ?? 0;
  }

  static function lua_setPlaybackRate(L:cpp.RawPointer<Lua_State>):Int
  {
    var playState = PlayState.instance;
    if (playState != null) playState.playbackRate = readFloat(L, 1, playState.playbackRate);
    return 0;
  }

  static function lua_getScrollSpeed(L:cpp.RawPointer<Lua_State>):Int
  {
    var playState = PlayState.instance;
    if (playState == null) return current()?.pushReturn(0.0) ?? 0;

    return switch (readString(L, 1, 'player'))
    {
      case 'opponent' | 'dad': current()?.pushReturn(playState.opponentStrumline?.scrollSpeed ?? 0.0) ?? 0;
      default: current()?.pushReturn(playState.playerStrumline?.scrollSpeed ?? 0.0) ?? 0;
    }
  }

  static function lua_setScrollSpeed(L:cpp.RawPointer<Lua_State>):Int
  {
    var playState = PlayState.instance;
    if (playState == null) return 0;

    var speed = readFloat(L, 1, 1);
    var target = readString(L, 2, 'both');
    if ((target == 'player' || target == 'both') && playState.playerStrumline != null) playState.playerStrumline.scrollSpeed = speed;
    if ((target == 'opponent' || target == 'dad' || target == 'both') && playState.opponentStrumline != null) playState.opponentStrumline.scrollSpeed = speed;
    return 0;
  }

  static function lua_getChartNotes(L:cpp.RawPointer<Lua_State>):Int
  {
    return current()?.pushReturn(PlayState.instance?.currentChart?.notes ?? []) ?? 0;
  }

  static function lua_getChartEvents(L:cpp.RawPointer<Lua_State>):Int
  {
    return current()?.pushReturn(PlayState.instance?.currentChart?.getEvents() ?? []) ?? 0;
  }

  static function lua_setStrumlinePosition(L:cpp.RawPointer<Lua_State>):Int
  {
    var manager = current();
    if (manager == null) return 0;
    var strumline = manager.resolveStrumline(readString(L, 1, 'player'));
    if (strumline == null) return manager.pushReturn(false);

    strumline.setPosition(readFloat(L, 2, strumline.x), readFloat(L, 3, strumline.y));
    strumline.refresh();
    return manager.pushReturn(true);
  }

  static function lua_setStrumlineAlpha(L:cpp.RawPointer<Lua_State>):Int
  {
    var manager = current();
    if (manager == null) return 0;
    var strumline = manager.resolveStrumline(readString(L, 1, 'player'));
    if (strumline == null) return manager.pushReturn(false);

    strumline.alpha = readFloat(L, 2, strumline.alpha);
    return manager.pushReturn(true);
  }

  static function lua_setStrumlineVisible(L:cpp.RawPointer<Lua_State>):Int
  {
    var manager = current();
    if (manager == null) return 0;
    var strumline = manager.resolveStrumline(readString(L, 1, 'player'));
    if (strumline == null) return manager.pushReturn(false);

    strumline.visible = readBool(L, 2, strumline.visible);
    return manager.pushReturn(true);
  }

  static function lua_setStrumlineNotePosition(L:cpp.RawPointer<Lua_State>):Int
  {
    var manager = current();
    if (manager == null) return 0;
    var strumline = manager.resolveStrumline(readString(L, 1, 'player'));
    if (strumline == null) return manager.pushReturn(false);

    var note = strumline.getByIndex(readInt(L, 2, 0));
    if (note == null) return manager.pushReturn(false);

    note.setPosition(readFloat(L, 3, note.x), readFloat(L, 4, note.y));
    return manager.pushReturn(true);
  }

  static function lua_playStrumlineAnimation(L:cpp.RawPointer<Lua_State>):Int
  {
    var manager = current();
    if (manager == null) return 0;
    var strumline = manager.resolveStrumline(readString(L, 1, 'player'));
    if (strumline == null) return manager.pushReturn(false);

    var direction:funkin.play.notes.NoteDirection = readInt(L, 2, 0);
    switch (readString(L, 3, 'static'))
    {
      case 'press': strumline.playPress(direction);
      case 'confirm': strumline.playConfirm(direction);
      case 'holdConfirm': strumline.holdConfirm(direction);
      case 'splash': strumline.playNoteSplash(direction);
      default: strumline.playStatic(direction);
    }
    return manager.pushReturn(true);
  }

  static function lua_setBotplay(L:cpp.RawPointer<Lua_State>):Int
  {
    var playState = PlayState.instance;
    if (playState != null) playState.isBotPlayMode = readBool(L, 1, playState.isBotPlayMode);
    return 0;
  }

  static function lua_setPracticeMode(L:cpp.RawPointer<Lua_State>):Int
  {
    var playState = PlayState.instance;
    if (playState != null) playState.isPracticeMode = readBool(L, 1, playState.isPracticeMode);
    return 0;
  }

  static function lua_getPreference(L:cpp.RawPointer<Lua_State>):Int
  {
    var manager = current();
    if (manager == null) return 0;

    try
    {
      return manager.pushReturn(Reflect.getProperty(FunkinPreferences, readString(L, 1, '')));
    }
    catch (e)
    {
      trace('[LuaScriptManager] getPreference failed: ${e}');
      return manager.pushReturn(null);
    }
  }

  static function lua_setPreference(L:cpp.RawPointer<Lua_State>):Int
  {
    var manager = current();
    if (manager == null) return 0;

    try
    {
      Reflect.setProperty(FunkinPreferences, readString(L, 1, ''), manager.readValue(L, 2));
      return manager.pushReturn(true);
    }
    catch (e)
    {
      trace('[LuaScriptManager] setPreference failed: ${e}');
      return manager.pushReturn(false);
    }
  }

  static function lua_setCamZoom(L:cpp.RawPointer<Lua_State>):Int
  {
    var manager = current();
    if (manager == null) return 0;

    var camera = manager.resolveCamera(readString(L, 2, 'game'));
    if (camera == null) return manager.pushReturn(false);

    camera.zoom = readFloat(L, 1, camera.zoom);
    return manager.pushReturn(true);
  }

  static function lua_defineLuaOption(L:cpp.RawPointer<Lua_State>):Int
  {
    var manager = current();
    if (manager == null) return 0;
    return manager.pushReturn(manager.optionManager.defineOption(readString(L, 1, ''), manager.readValue(L, 2)));
  }

  static function lua_getLuaOption(L:cpp.RawPointer<Lua_State>):Int
  {
    var manager = current();
    if (manager == null) return 0;
    return manager.pushReturn(manager.optionManager.getOption(readString(L, 1, ''), manager.readValue(L, 2)));
  }

  static function lua_setLuaOption(L:cpp.RawPointer<Lua_State>):Int
  {
    var manager = current();
    if (manager == null) return 0;
    return manager.pushReturn(manager.optionManager.setOption(readString(L, 1, ''), manager.readValue(L, 2), readBool(L, 3, true)));
  }

  static function lua_hasLuaOption(L:cpp.RawPointer<Lua_State>):Int
  {
    var manager = current();
    if (manager == null) return 0;
    return manager.pushReturn(manager.optionManager.hasOption(readString(L, 1, '')));
  }

  static function lua_stageExists(L:cpp.RawPointer<Lua_State>):Int
  {
    var manager = current();
    if (manager == null) return 0;
    return manager.pushReturn(StageRegistry.instance.hasEntry(readString(L, 1, '')));
  }

  static function lua_removeLuaOption(L:cpp.RawPointer<Lua_State>):Int
  {
    var manager = current();
    if (manager == null) return 0;
    return manager.pushReturn(manager.optionManager.removeOption(readString(L, 1, ''), readBool(L, 2, true)));
  }

  static function lua_getLuaOptions(L:cpp.RawPointer<Lua_State>):Int
  {
    var manager = current();
    if (manager == null) return 0;
    return manager.pushReturn(manager.optionManager.getOptions());
  }

  static function lua_createLuaOptionPage(L:cpp.RawPointer<Lua_State>):Int
  {
    var manager = current();
    if (manager == null) return 0;
    return manager.pushReturn(manager.optionManager.createPage(readString(L, 1, ''), readString(L, 2, ''), readInt(L, 3, -1)));
  }

  static function lua_addLuaCheckbox(L:cpp.RawPointer<Lua_State>):Int
  {
    var manager = current();
    if (manager == null) return 0;
    return manager.pushReturn(manager.optionManager.addCheckbox(readString(L, 1, ''), readString(L, 2, ''), readString(L, 3, ''),
      readString(L, 4, ''), readBool(L, 5, false)));
  }

  static function lua_addLuaNumber(L:cpp.RawPointer<Lua_State>):Int
  {
    var manager = current();
    if (manager == null) return 0;
    return manager.pushReturn(manager.optionManager.addNumber(readString(L, 1, ''), readString(L, 2, ''), readString(L, 3, ''),
      readString(L, 4, ''), readFloat(L, 5, 0), readFloat(L, 6, 0), readFloat(L, 7, 1), readFloat(L, 8, 0.1), readInt(L, 9, 1)));
  }

  static function lua_addLuaEnum(L:cpp.RawPointer<Lua_State>):Int
  {
    var manager = current();
    if (manager == null) return 0;
    return manager.pushReturn(manager.optionManager.addEnum(readString(L, 1, ''), readString(L, 2, ''), readString(L, 3, ''),
      readString(L, 4, ''), manager.readValue(L, 5), readString(L, 6, '')));
  }

  static function lua_flushSave(L:cpp.RawPointer<Lua_State>):Int
  {
    Save.system.flush();
    return 0;
  }

  static function lua_getLuaSave(L:cpp.RawPointer<Lua_State>):Int
  {
    var manager = current();
    if (manager == null) return 0;

    var key = readString(L, 1, '');
    var fallback = manager.readValue(L, 2);
    if (key == '') return manager.pushReturn(fallback);

    var data = ensureLuaSaveData();
    if (!Reflect.hasField(data, key)) return manager.pushReturn(fallback);
    return manager.pushReturn(Reflect.field(data, key));
  }

  static function lua_setLuaSave(L:cpp.RawPointer<Lua_State>):Int
  {
    var manager = current();
    if (manager == null) return 0;

    var key = readString(L, 1, '');
    if (key == '') return manager.pushReturn(false);

    var data = ensureLuaSaveData();
    Reflect.setField(data, key, manager.readValue(L, 2));
    Save.system.flush();
    return manager.pushReturn(true);
  }

  static function ensureLuaSaveData():Dynamic
  {
    var saveData:Dynamic = FlxG.save.data;
    if (!Reflect.hasField(saveData, 'psychLua')) Reflect.setField(saveData, 'psychLua', {});

    var data:Dynamic = Reflect.field(saveData, 'psychLua');
    if (data == null || Std.isOfType(data, String) || Std.isOfType(data, Int) || Std.isOfType(data, Float) || Std.isOfType(data, Bool))
    {
      data = {};
      Reflect.setField(saveData, 'psychLua', data);
    }

    return data;
  }

  static function lua_getScreenWidth(L:cpp.RawPointer<Lua_State>):Int
  {
    return current()?.pushReturn(FlxG.width) ?? 0;
  }

  static function lua_getScreenHeight(L:cpp.RawPointer<Lua_State>):Int
  {
    return current()?.pushReturn(FlxG.height) ?? 0;
  }

  static function lua_setFullscreen(L:cpp.RawPointer<Lua_State>):Int
  {
    FlxG.fullscreen = readBool(L, 1, FlxG.fullscreen);
    return 0;
  }

  static function lua_getMemoryUsageMB(L:cpp.RawPointer<Lua_State>):Int
  {
    return current()?.pushReturn(MemoryUtil.getGCMemory() / 1024 / 1024) ?? 0;
  }

  static function lua_getDebugDisplayVisible(L:cpp.RawPointer<Lua_State>):Int
  {
    final display = Main.debugDisplay;
    final parent = FlxG.game?.parent;
    return current()?.pushReturn(display != null && parent != null && parent.contains(display) && display.visible) ?? 0;
  }

  static function lua_setDebugDisplayVisible(L:cpp.RawPointer<Lua_State>):Int
  {
    if (Main.debugDisplay == null) return current()?.pushReturn(false) ?? 0;
    Main.debugDisplay.visible = readBool(L, 1, true);
    return current()?.pushReturn(true) ?? 0;
  }

  static function lua_getHealth(L:cpp.RawPointer<Lua_State>):Int
  {
    return current()?.pushReturn(PlayState.instance?.health ?? 0.0) ?? 0;
  }

  static function lua_setHealth(L:cpp.RawPointer<Lua_State>):Int
  {
    var playState = PlayState.instance;
    if (playState != null) playState.health = readFloat(L, 1, playState.health);
    return 0;
  }

  static function lua_addHealth(L:cpp.RawPointer<Lua_State>):Int
  {
    var playState = PlayState.instance;
    if (playState != null) playState.health += readFloat(L, 1, 0);
    return 0;
  }

  static function lua_getScore(L:cpp.RawPointer<Lua_State>):Int
  {
    return current()?.pushReturn(PlayState.instance?.songScore ?? 0) ?? 0;
  }

  static function lua_setScore(L:cpp.RawPointer<Lua_State>):Int
  {
    var playState = PlayState.instance;
    if (playState != null) playState.songScore = readFloat(L, 1, playState.songScore);
    return 0;
  }

  static function lua_addScore(L:cpp.RawPointer<Lua_State>):Int
  {
    var playState = PlayState.instance;
    if (playState != null) playState.songScore += readFloat(L, 1, 0);
    return 0;
  }

  static function lua_getCombo(L:cpp.RawPointer<Lua_State>):Int
  {
    return current()?.pushReturn(Highscore.tallies.combo) ?? 0;
  }

  static function lua_setCombo(L:cpp.RawPointer<Lua_State>):Int
  {
    Highscore.tallies.combo = readInt(L, 1, Highscore.tallies.combo);
    if (Highscore.tallies.combo > Highscore.tallies.maxCombo) Highscore.tallies.maxCombo = Highscore.tallies.combo;
    return 0;
  }

  static function lua_getAccuracy(L:cpp.RawPointer<Lua_State>):Int
  {
    if (Highscore.tallies.totalNotes <= 0) return current()?.pushReturn(0) ?? 0;
    return current()?.pushReturn((Highscore.tallies.totalNotesHit / Highscore.tallies.totalNotes) * 100) ?? 0;
  }

  static function lua_getTallies(L:cpp.RawPointer<Lua_State>):Int
  {
    return current()?.pushReturn({
      sick: Highscore.tallies.sick,
      good: Highscore.tallies.good,
      bad: Highscore.tallies.bad,
      shit: Highscore.tallies.shit,
      missed: Highscore.tallies.missed,
      combo: Highscore.tallies.combo,
      maxCombo: Highscore.tallies.maxCombo,
      totalNotesHit: Highscore.tallies.totalNotesHit,
      totalNotes: Highscore.tallies.totalNotes,
      score: PlayState.instance?.songScore ?? 0
    }) ?? 0;
  }

  static function lua_setVocalsVolume(L:cpp.RawPointer<Lua_State>):Int
  {
    var playState = PlayState.instance;
    if (playState == null) return 0;
    var playerVolume = readFloat(L, 1, playState.playerVocalsVolume);
    var opponentVolume = readFloat(L, 2, playState.opponentVocalsVolume);
    playState.playerVocalsVolume = playerVolume;
    playState.opponentVocalsVolume = opponentVolume;
    if (playState.vocals != null)
    {
      playState.vocals.playerVolume = playerVolume;
      playState.vocals.opponentVolume = opponentVolume;
    }
    return 0;
  }

  static function lua_startCountdown(L:cpp.RawPointer<Lua_State>):Int
  {
    PlayState.instance?.startCountdown();
    return 0;
  }

  static function lua_startConversation(L:cpp.RawPointer<Lua_State>):Int
  {
    var playState = PlayState.instance;
    if (playState == null) return current()?.pushReturn(false) ?? 0;

    playState.startConversation(readString(L, 1, ''));
    return current()?.pushReturn(playState.currentConversation != null) ?? 0;
  }

  static function lua_playVideo(L:cpp.RawPointer<Lua_State>):Int
  {
    var manager = current();
    if (manager == null) return 0;
    try
    {
      VideoCutscene.play(Paths.file(readString(L, 1, '')));
      return manager.pushReturn(true);
    }
    catch (e)
    {
      trace('[LuaScriptManager] playVideo failed: ${e}');
      return manager.pushReturn(false);
    }
  }

  static function lua_pauseVideo(L:cpp.RawPointer<Lua_State>):Int
  {
    VideoCutscene.pauseVideo();
    return 0;
  }

  static function lua_resumeVideo(L:cpp.RawPointer<Lua_State>):Int
  {
    VideoCutscene.resumeVideo();
    return 0;
  }

  static function lua_finishVideo(L:cpp.RawPointer<Lua_State>):Int
  {
    VideoCutscene.finishVideo(readFloat(L, 1, 0.5));
    return 0;
  }

  static function lua_isVideoPlaying(L:cpp.RawPointer<Lua_State>):Int
  {
    return current()?.pushReturn(VideoCutscene.isPlaying()) ?? 0;
  }

  static function lua_endSong(L:cpp.RawPointer<Lua_State>):Int
  {
    PlayState.instance?.endSong(readBool(L, 1, false));
    return 0;
  }

  static function lua_restartSong(L:cpp.RawPointer<Lua_State>):Int
  {
    var playState = PlayState.instance;
    if (playState != null) playState.needsReset = true;
    return 0;
  }

  static function lua_openLuaState(L:cpp.RawPointer<Lua_State>):Int
  {
    final manager = current();
    if (manager == null) return 0;
    final target = readString(L, 1, '');
    try
    {
      final success = target != '' && LuaStateManager.openState(target, manager.readArgs(L, 2));
      if (!success) manager.reportLuaWarning('api-error', 'lua-api', 'openLuaState', 'State not found or invalid: ${target}');
      return manager.pushReturn(success);
    }
    catch (error)
    {
      manager.reportLuaWarning('api-error', 'lua-api', 'openLuaState', 'Could not open state ${target}: ${error}');
      return manager.pushReturn(false);
    }
  }

  static function lua_openLuaSubState(L:cpp.RawPointer<Lua_State>):Int
  {
    final manager = current();
    if (manager == null) return 0;
    final target = readString(L, 1, '');
    try
    {
      final success = target != '' && LuaStateManager.openSubState(target, manager.readArgs(L, 2));
      if (!success) manager.reportLuaWarning('api-error', 'lua-api', 'openLuaSubState', 'Substate not found or invalid: ${target}');
      return manager.pushReturn(success);
    }
    catch (error)
    {
      manager.reportLuaWarning('api-error', 'lua-api', 'openLuaSubState', 'Could not open substate ${target}: ${error}');
      return manager.pushReturn(false);
    }
  }

  static function lua_addSprite(L:cpp.RawPointer<Lua_State>):Int
  {
    var manager = current();
    var playState = PlayState.instance;
    if (manager == null || playState == null) return 0;

    var tag = readString(L, 1, '');
    var asset = readString(L, 2, '');
    var x = readFloat(L, 3, 0);
    var y = readFloat(L, 4, 0);
    var camera = readString(L, 5, 'game');
    var zIndex = readInt(L, 6, 0);
    var animated = readBool(L, 7, false);

    if (tag == '' || asset == '') return manager.pushReturn(false);

    manager.removeSprite(tag);

    var sprite:Null<FunkinSprite> = null;
    try
    {
      sprite = animated ? FunkinSprite.createSparrow(x, y, asset) : FunkinSprite.create(x, y, asset);
    }
    catch (e)
    {
      trace('[LuaScriptManager] addSprite failed: ${e}');
      return manager.pushReturn(false);
    }
    if (sprite == null) return manager.pushReturn(false);
    sprite.zIndex = zIndex;
    manager.applyCamera(sprite, camera);
    manager.sprites.set(tag, sprite);
    playState.add(sprite);
    playState.refresh();

    return manager.pushReturn(true);
  }

  static function lua_addAnimatedSpriteAlias(L:cpp.RawPointer<Lua_State>):Int
  {
    var manager = current();
    var playState = PlayState.instance;
    if (manager == null || playState == null) return 0;

    var tag = readString(L, 1, '');
    var asset = readString(L, 2, '');
    if (tag == '' || asset == '') return manager.pushReturn(false);

    manager.removeSprite(tag);

    var sprite:Null<FunkinSprite> = null;
    try
    {
      sprite = FunkinSprite.createSparrow(readFloat(L, 3, 0), readFloat(L, 4, 0), asset);
    }
    catch (e)
    {
      trace('[LuaScriptManager] addAnimatedSprite failed: ${e}');
      return manager.pushReturn(false);
    }
    if (sprite == null) return manager.pushReturn(false);
    sprite.zIndex = readInt(L, 6, 0);
    manager.applyCamera(sprite, readString(L, 5, 'game'));
    manager.sprites.set(tag, sprite);
    playState.add(sprite);
    playState.refresh();
    return manager.pushReturn(true);
  }

  static function lua_loadGraphic(L:cpp.RawPointer<Lua_State>):Int
  {
    return createSpriteFromLua(L, false);
  }

  static function lua_loadSparrow(L:cpp.RawPointer<Lua_State>):Int
  {
    return createSpriteFromLua(L, true);
  }

  static function createSpriteFromLua(L:cpp.RawPointer<Lua_State>, animated:Bool):Int
  {
    var manager = current();
    var playState = PlayState.instance;
    if (manager == null || playState == null) return 0;

    var tag = readString(L, 1, '');
    var asset = readString(L, 2, '');
    if (tag == '' || asset == '') return manager.pushReturn(false);

    manager.removeSprite(tag);
    var sprite:Null<FunkinSprite> = null;
    try
    {
      sprite = animated ? FunkinSprite.createSparrow(readFloat(L, 3, 0), readFloat(L, 4, 0), asset) : FunkinSprite.create(readFloat(L, 3, 0),
        readFloat(L, 4, 0), asset);
    }
    catch (e)
    {
      trace('[LuaScriptManager] createSprite failed: ${e}');
      return manager.pushReturn(false);
    }
    if (sprite == null) return manager.pushReturn(false);
    sprite.zIndex = readInt(L, 6, 0);
    manager.applyCamera(sprite, readString(L, 5, 'game'));
    manager.sprites.set(tag, sprite);
    playState.add(sprite);
    playState.refresh();
    return manager.pushReturn(true);
  }

  static function lua_makeSolidSprite(L:cpp.RawPointer<Lua_State>):Int
  {
    var manager = current();
    var playState = PlayState.instance;
    if (manager == null || playState == null) return 0;

    var tag = readString(L, 1, '');
    var x = readFloat(L, 2, 0);
    var y = readFloat(L, 3, 0);
    var width = readInt(L, 4, 100);
    var height = readInt(L, 5, 100);
    var color = readColor(L, 6, FlxColor.WHITE);
    var camera = readString(L, 7, 'game');
    var zIndex = readInt(L, 8, 0);

    if (tag == '') return manager.pushReturn(false);

    manager.removeSprite(tag);

    var sprite = new FunkinSprite(x, y);
    try
    {
      sprite.makeSolidColor(width, height, color);
    }
    catch (e)
    {
      trace('[LuaScriptManager] makeSolidSprite failed: ${e}');
      return manager.pushReturn(false);
    }
    sprite.zIndex = zIndex;
    manager.applyCamera(sprite, camera);
    manager.sprites.set(tag, sprite);
    playState.add(sprite);
    playState.refresh();

    return manager.pushReturn(true);
  }

  static function lua_makeGraphicAlias(L:cpp.RawPointer<Lua_State>):Int
  {
    var manager = current();
    var playState = PlayState.instance;
    if (manager == null || playState == null) return 0;

    var tag = readString(L, 1, '');
    if (tag == '') return manager.pushReturn(false);

    var sprite = manager.sprites.get(tag);
    if (sprite == null)
    {
      sprite = new FunkinSprite(0, 0);
      manager.sprites.set(tag, sprite);
      playState.add(sprite);
    }

    try
    {
      sprite.makeSolidColor(readInt(L, 2, 100), readInt(L, 3, 100), readColor(L, 4, FlxColor.WHITE));
    }
    catch (e)
    {
      trace('[LuaScriptManager] makeGraphic failed: ${e}');
      return manager.pushReturn(false);
    }
    playState.refresh();
    return manager.pushReturn(true);
  }

  static function lua_removeSprite(L:cpp.RawPointer<Lua_State>):Int
  {
    var manager = current();
    if (manager == null) return 0;
    return manager.pushReturn(manager.removeSprite(readString(L, 1, '')));
  }

  static function lua_setSpriteCamera(L:cpp.RawPointer<Lua_State>):Int
  {
    var manager = current();
    if (manager == null) return 0;

    var sprite = manager.sprites.get(readString(L, 1, ''));
    if (sprite == null) return manager.pushReturn(false);

    manager.applyCamera(sprite, readString(L, 2, 'game'));
    return manager.pushReturn(true);
  }

  static function lua_addText(L:cpp.RawPointer<Lua_State>):Int
  {
    var manager = current();
    var playState = PlayState.instance;
    if (manager == null || playState == null) return 0;

    var tag = readString(L, 1, '');
    if (tag == '') return manager.pushReturn(false);

    manager.removeText(tag);
    var text = new FlxText(readFloat(L, 2, 0), readFloat(L, 3, 0), readFloat(L, 4, 0), readString(L, 5, ''), readInt(L, 6, 16));
    text.color = readColor(L, 7, FlxColor.WHITE);
    text.zIndex = readInt(L, 8, 0);
    var camera = readString(L, 9, 'hud');
    var resolved = manager.resolveCamera(camera);
    if (resolved != null) text.cameras = [resolved];
    manager.texts.set(tag, text);
    playState.add(text);
    playState.refresh();
    return manager.pushReturn(true);
  }

  static function lua_makeLuaTextAlias(L:cpp.RawPointer<Lua_State>):Int
  {
    var manager = current();
    var playState = PlayState.instance;
    if (manager == null || playState == null) return 0;

    var tag = readString(L, 1, '');
    if (tag == '') return manager.pushReturn(false);

    manager.removeText(tag);
    var text = new FlxText(readFloat(L, 4, 0), readFloat(L, 5, 0), readFloat(L, 3, 0), readString(L, 2, ''), readInt(L, 6, 16));
    text.color = readColor(L, 7, FlxColor.WHITE);
    text.zIndex = readInt(L, 8, 0);
    var resolved = manager.resolveCamera(readString(L, 9, 'hud'));
    if (resolved != null) text.cameras = [resolved];
    manager.texts.set(tag, text);
    playState.add(text);
    playState.refresh();
    return manager.pushReturn(true);
  }

  static function lua_setText(L:cpp.RawPointer<Lua_State>):Int
  {
    var manager = current();
    if (manager == null) return 0;
    var text = manager.texts.get(readString(L, 1, ''));
    if (text == null) return manager.pushReturn(false);
    text.text = readString(L, 2, text.text);
    return manager.pushReturn(true);
  }

  static function lua_setTextFormat(L:cpp.RawPointer<Lua_State>):Int
  {
    var manager = current();
    if (manager == null) return 0;
    var text = manager.texts.get(readString(L, 1, ''));
    if (text == null) return manager.pushReturn(false);
    text.size = readInt(L, 2, text.size);
    text.color = readColor(L, 3, text.color);
    text.alignment = readTextAlign(L, 4, text.alignment);
    text.borderStyle = readBool(L, 5, false) ? FlxTextBorderStyle.OUTLINE : FlxTextBorderStyle.NONE;
    text.borderColor = readColor(L, 6, FlxColor.BLACK);
    return manager.pushReturn(true);
  }

  static function lua_removeText(L:cpp.RawPointer<Lua_State>):Int
  {
    var manager = current();
    if (manager == null) return 0;
    return manager.pushReturn(manager.removeText(readString(L, 1, '')));
  }

  static function lua_setObjectCamera(L:cpp.RawPointer<Lua_State>):Int
  {
    var manager = current();
    if (manager == null) return 0;

    var target = manager.resolvePath(readString(L, 1, '')).value;
    var camera = manager.resolveCamera(readString(L, 2, 'game'));
    if (target == null || camera == null) return manager.pushReturn(false);

    return manager.pushReturn(manager.safeSetProperty(target, 'cameras', [camera]));
  }

  static function lua_setObjectPosition(L:cpp.RawPointer<Lua_State>):Int
  {
    var manager = current();
    if (manager == null) return 0;
    var target = manager.resolvePath(readString(L, 1, '')).value;
    if (target == null) return manager.pushReturn(false);
    var xOk = manager.safeSetProperty(target, 'x', readFloat(L, 2, manager.safeGetProperty(target, 'x') ?? 0));
    var yOk = manager.safeSetProperty(target, 'y', readFloat(L, 3, manager.safeGetProperty(target, 'y') ?? 0));
    return manager.pushReturn(xOk && yOk);
  }

  static function lua_getObjectX(L:cpp.RawPointer<Lua_State>):Int
  {
    return getSimpleObjectField(L, 'x', 0);
  }

  static function lua_getObjectY(L:cpp.RawPointer<Lua_State>):Int
  {
    return getSimpleObjectField(L, 'y', 0);
  }

  static function lua_getObjectWidth(L:cpp.RawPointer<Lua_State>):Int
  {
    return getSimpleObjectField(L, 'width', 0);
  }

  static function lua_getObjectHeight(L:cpp.RawPointer<Lua_State>):Int
  {
    return getSimpleObjectField(L, 'height', 0);
  }

  static function lua_getObjectAlpha(L:cpp.RawPointer<Lua_State>):Int
  {
    return getSimpleObjectField(L, 'alpha', 1);
  }

  static function lua_getObjectVisible(L:cpp.RawPointer<Lua_State>):Int
  {
    var manager = current();
    if (manager == null) return 0;
    var target = manager.resolvePath(readString(L, 1, '')).value;
    if (target == null) return manager.pushReturn(false);
    return manager.pushReturn(manager.safeGetProperty(target, 'visible') ?? false);
  }

  static function lua_getObjectAngle(L:cpp.RawPointer<Lua_State>):Int
  {
    return getSimpleObjectField(L, 'angle', 0);
  }

  static function lua_setObjectScale(L:cpp.RawPointer<Lua_State>):Int
  {
    var manager = current();
    if (manager == null) return 0;
    var target = manager.resolvePath(readString(L, 1, '')).value;
    var scale = target == null ? null : manager.safeField(target, 'scale');
    if (scale == null) return manager.pushReturn(false);
    var set = manager.safeField(scale, 'set');
    if (set == null) return manager.pushReturn(false);
    manager.safeCallMethod(scale, set, [readFloat(L, 2, manager.safeGetProperty(scale, 'x') ?? 0), readFloat(L, 3, manager.safeGetProperty(scale, 'y') ?? 0)]);
    var updateHitbox = manager.safeField(target, 'updateHitbox');
    if (updateHitbox != null) manager.safeCallMethod(target, updateHitbox, []);
    return manager.pushReturn(true);
  }

  static function lua_setObjectSize(L:cpp.RawPointer<Lua_State>):Int
  {
    var manager = current();
    if (manager == null) return 0;

    var target = manager.resolvePath(readString(L, 1, '')).value;
    if (target == null || !Std.isOfType(target, FlxSprite)) return manager.pushReturn(false);

    try
    {
      cast(target, FlxSprite).setGraphicSize(readInt(L, 2, Std.int(target.width)), readInt(L, 3, Std.int(target.height)));
      target.updateHitbox();
      return manager.pushReturn(true);
    }
    catch (e)
    {
      trace('[LuaScriptManager] setObjectSize failed: ${e}');
      return manager.pushReturn(false);
    }
  }

  static function lua_setObjectAlpha(L:cpp.RawPointer<Lua_State>):Int
  {
    return setSimpleObjectField(L, 'alpha', 2, 1);
  }

  static function lua_setObjectVisible(L:cpp.RawPointer<Lua_State>):Int
  {
    var manager = current();
    if (manager == null) return 0;
    var target = manager.resolvePath(readString(L, 1, '')).value;
    if (target == null) return manager.pushReturn(false);
    return manager.pushReturn(manager.safeSetProperty(target, 'visible', readBool(L, 2, true)));
  }

  static function lua_setObjectAngle(L:cpp.RawPointer<Lua_State>):Int
  {
    return setSimpleObjectField(L, 'angle', 2, 0);
  }

  static function lua_setObjectColor(L:cpp.RawPointer<Lua_State>):Int
  {
    var manager = current();
    if (manager == null) return 0;
    var target = manager.resolvePath(readString(L, 1, '')).value;
    if (target == null) return manager.pushReturn(false);
    return manager.pushReturn(manager.safeSetProperty(target, 'color', readColor(L, 2, FlxColor.WHITE)));
  }

  static function lua_setObjectVelocity(L:cpp.RawPointer<Lua_State>):Int
  {
    return setPointObjectField(L, 'velocity', 2, 3);
  }

  static function lua_setObjectAcceleration(L:cpp.RawPointer<Lua_State>):Int
  {
    return setPointObjectField(L, 'acceleration', 2, 3);
  }

  static function lua_setObjectScrollFactor(L:cpp.RawPointer<Lua_State>):Int
  {
    return setPointObjectField(L, 'scrollFactor', 2, 3);
  }

  static function lua_setObjectZIndex(L:cpp.RawPointer<Lua_State>):Int
  {
    var manager = current();
    if (manager == null) return 0;
    var target = manager.resolvePath(readString(L, 1, '')).value;
    if (target == null) return manager.pushReturn(false);
    if (!manager.safeSetProperty(target, 'zIndex', readInt(L, 2, manager.safeGetProperty(target, 'zIndex') ?? 0))) return manager.pushReturn(false);
    PlayState.instance?.refresh();
    return manager.pushReturn(true);
  }

  static function lua_screenCenter(L:cpp.RawPointer<Lua_State>):Int
  {
    var manager = current();
    if (manager == null) return 0;
    var target = manager.resolvePath(readString(L, 1, '')).value;
    if (target == null || !Std.isOfType(target, FlxSprite)) return manager.pushReturn(false);
    cast(target, FlxSprite).screenCenter(readAxes(L, 2, FlxAxes.XY));
    return manager.pushReturn(true);
  }

  static function lua_objectExists(L:cpp.RawPointer<Lua_State>):Int
  {
    var manager = current();
    if (manager == null) return 0;
    return manager.pushReturn(manager.resolvePath(readString(L, 1, '')).value != null);
  }

  static function lua_killObject(L:cpp.RawPointer<Lua_State>):Int
  {
    var manager = current();
    if (manager == null) return 0;
    var target = manager.resolvePath(readString(L, 1, '')).value;
    var method = target == null ? null : manager.safeField(target, 'kill');
    if (method == null) return manager.pushReturn(false);
    return manager.pushReturn(manager.safeCallMethod(target, method, []).ok);
  }

  static function lua_reviveObject(L:cpp.RawPointer<Lua_State>):Int
  {
    var manager = current();
    if (manager == null) return 0;
    var target = manager.resolvePath(readString(L, 1, '')).value;
    var method = target == null ? null : manager.safeField(target, 'revive');
    if (method == null) return manager.pushReturn(false);
    return manager.pushReturn(manager.safeCallMethod(target, method, []).ok);
  }

  static function lua_addAnimByPrefix(L:cpp.RawPointer<Lua_State>):Int
  {
    var manager = current();
    if (manager == null) return 0;
    var target = manager.resolvePath(readString(L, 1, '')).value;
    var animation = target == null ? null : manager.safeField(target, 'animation');
    var addByPrefix = animation == null ? null : manager.safeField(animation, 'addByPrefix');
    if (addByPrefix == null) return manager.pushReturn(false);
    return manager.pushReturn(manager.safeCallMethod(animation, addByPrefix,
      [readString(L, 2, ''), readString(L, 3, ''), readInt(L, 4, 24), readBool(L, 5, false)]).ok);
  }

  static function lua_playAnim(L:cpp.RawPointer<Lua_State>):Int
  {
    var manager = current();
    if (manager == null) return 0;

    var target = manager.resolvePath(readString(L, 1, '')).value;
    var anim = readString(L, 2, '');
    var force = readBool(L, 3, false);

    if (target == null || anim == '') return manager.pushReturn(false);

    if (Std.isOfType(target, FunkinSprite))
    {
      cast(target, FunkinSprite).animation.play(anim, force);
      return manager.pushReturn(true);
    }

    var method = manager.safeField(target, 'playAnimation') ?? manager.safeField(target, 'playAnim');
    if (method != null)
    {
      return manager.pushReturn(manager.safeCallMethod(target, method, [anim, force]).ok);
    }

    return manager.pushReturn(false);
  }

  static function lua_hasAnim(L:cpp.RawPointer<Lua_State>):Int
  {
    var manager = current();
    if (manager == null) return 0;

    var target = manager.resolvePath(readString(L, 1, '')).value;
    var anim = readString(L, 2, '');
    if (target == null || anim == '') return manager.pushReturn(false);

    if (Std.isOfType(target, FunkinSprite)) return manager.pushReturn(cast(target, FunkinSprite).hasAnimation(anim));

    var method = manager.safeField(target, 'hasAnimation');
    return manager.pushReturn(method != null && manager.safeCallMethod(target, method, [anim]).value == true);
  }

  static function lua_createLuaMenu(L:cpp.RawPointer<Lua_State>):Int
  {
    var manager = current();
    if (manager == null) return 0;
    return manager.pushReturn(manager.menuManager.createMenu(readString(L, 1, ''), readStringArray(L, 2), readFloat(L, 3, 80), readFloat(L, 4, 120),
      readFloat(L, 5, 600), readString(L, 6, 'hud'), readColor(L, 7, FlxColor.WHITE), readColor(L, 8, FlxColor.YELLOW)));
  }

  static function lua_createLuaImageMenu(L:cpp.RawPointer<Lua_State>):Int
  {
    var manager = current();
    if (manager == null) return 0;
    return manager.pushReturn(manager.menuManager.createImageMenu(readString(L, 1, ''), readStringArray(L, 2), readFloat(L, 3, 80),
      readFloat(L, 4, 120), readFloat(L, 5, 95), readString(L, 6, 'hud'), manager.readValue(L, 7)));
  }

  static function lua_addLuaMainMenuItem(L:cpp.RawPointer<Lua_State>):Int
  {
    var manager = current();
    if (manager == null || manager.mainMenuState == null) return manager?.pushReturn(false) ?? 0;

    var id = readString(L, 1, '');
    var assetPath = readString(L, 2, 'images:mainmenu/storymode');
    var position = readInt(L, 3, 999);
    var animName = readString(L, 4, id);
    var target = readString(L, 5, '');
    final addMethod = Reflect.field(manager.mainMenuState, 'addLuaMenuItem');
    if (addMethod == null) return manager.pushReturn(false);
    return manager.pushReturn(Reflect.callMethod(manager.mainMenuState, addMethod, [id, assetPath, position, animName, target, function()
    {
      manager.callHook('onLuaMainMenuAccept', [id]);
    }]));
  }

  static function lua_configureLuaPauseMenu(L:cpp.RawPointer<Lua_State>):Int
  {
    var manager = current();
    if (manager == null) return 0;
    return manager.pushReturn(manager.configureLuaPauseMenu(manager.readValue(L, 1)));
  }

  static function lua_setLuaPauseOptionsBehavior(L:cpp.RawPointer<Lua_State>):Int
  {
    return lua_setLuaPauseOptions(L);
  }

  static function lua_setLuaPauseOptions(L:cpp.RawPointer<Lua_State>):Int
  {
    var manager = current();
    if (manager == null) return 0;
    final optionsClass = funkin.ui.options.OptionsState;
    final prepareMethod = Reflect.field(optionsClass, 'prepareLuaPauseReturn');
    if (prepareMethod == null) return manager.pushReturn(false);
    Reflect.callMethod(optionsClass, prepareMethod, [{howExit: readString(L, 1, 'resume'), hideExit: true}]);
    return manager.pushReturn(true);
  }
  static function lua_setLuaPauseMenuItem(L:cpp.RawPointer<Lua_State>):Int
  {
    var manager = current();
    if (manager == null) return 0;
    return manager.pushReturn(manager.setLuaPauseMenuItem(readString(L, 1, ''), readString(L, 2, ''), readInt(L, 3, 999), readString(L, 4, ''), readBool(L, 5, false)));
  }

  static function lua_setLuaMenuItems(L:cpp.RawPointer<Lua_State>):Int
  {
    var manager = current();
    if (manager == null) return 0;
    return manager.pushReturn(manager.menuManager.setItems(readString(L, 1, ''), readStringArray(L, 2)));
  }

  static function lua_setLuaMenuPosition(L:cpp.RawPointer<Lua_State>):Int
  {
    var manager = current();
    if (manager == null) return 0;
    return manager.pushReturn(manager.menuManager.setPosition(readString(L, 1, ''), readFloat(L, 2, 80), readFloat(L, 3, 120), readFloat(L, 4, 34)));
  }

  static function lua_showLuaMenu(L:cpp.RawPointer<Lua_State>):Int
  {
    var manager = current();
    if (manager == null) return 0;
    return manager.pushReturn(manager.menuManager.showMenu(readString(L, 1, '')));
  }

  static function lua_hideLuaMenu(L:cpp.RawPointer<Lua_State>):Int
  {
    var manager = current();
    if (manager == null) return 0;
    return manager.pushReturn(manager.menuManager.hideMenu(readString(L, 1, '')));
  }

  static function lua_removeLuaMenu(L:cpp.RawPointer<Lua_State>):Int
  {
    var manager = current();
    if (manager == null) return 0;
    return manager.pushReturn(manager.menuManager.removeMenu(readString(L, 1, '')));
  }

  static function lua_getLuaMenuSelected(L:cpp.RawPointer<Lua_State>):Int
  {
    var manager = current();
    if (manager == null) return 0;
    return manager.pushReturn(manager.menuManager.getSelected(readString(L, 1, '')));
  }

  static function lua_createShader(L:cpp.RawPointer<Lua_State>):Int
  {
    var manager = current();
    if (manager == null) return 0;
    return manager.pushReturn(manager.shaderManager.createShader(readString(L, 1, ''), readString(L, 2, ''), readString(L, 3, '')));
  }

  static function lua_initLuaShader(L:cpp.RawPointer<Lua_State>):Int
  {
    var manager = current();
    if (manager == null) return 0;
    return manager.pushReturn(manager.shaderManager.initShader(readString(L, 1, ''), readString(L, 2, '')));
  }

  static function lua_makeLuaShader(L:cpp.RawPointer<Lua_State>):Int
  {
    var manager = current();
    if (manager == null) return 0;

    var tag = readString(L, 1, '');
    var path = readString(L, 2, '');
    if (path == '') return manager.pushReturn(manager.shaderManager.initShader(tag));
    return manager.pushReturn(manager.shaderManager.createShader(tag, path, readString(L, 3, '')));
  }

  static function lua_setLuaShader(L:cpp.RawPointer<Lua_State>):Int
  {
    var manager = current();
    if (manager == null) return 0;
    return manager.pushReturn(manager.shaderManager.applyToTarget(readString(L, 1, ''), manager.resolveShaderTarget(readString(L, 2, ''))));
  }

  static function lua_setShaderOnSprite(L:cpp.RawPointer<Lua_State>):Int
  {
    var manager = current();
    if (manager == null) return 0;
    return manager.pushReturn(manager.shaderManager.applyToTarget(readString(L, 2, ''), manager.resolveShaderTarget(readString(L, 1, ''))));
  }

  static function lua_destroyShader(L:cpp.RawPointer<Lua_State>):Int
  {
    var manager = current();
    if (manager == null) return 0;
    return manager.pushReturn(manager.shaderManager.destroyShader(readString(L, 1, '')));
  }

  static function lua_shaderExists(L:cpp.RawPointer<Lua_State>):Int
  {
    var manager = current();
    if (manager == null) return 0;
    return manager.pushReturn(manager.shaderManager.hasShader(readString(L, 1, '')));
  }

  static function lua_setShaderFloat(L:cpp.RawPointer<Lua_State>):Int
  {
    var manager = current();
    if (manager == null) return 0;
    return manager.pushReturn(manager.shaderManager.setFloat(readString(L, 1, ''), readString(L, 2, ''), readFloat(L, 3, 0)));
  }

  static function lua_setShaderFloatArray(L:cpp.RawPointer<Lua_State>):Int
  {
    var manager = current();
    if (manager == null) return 0;
    return manager.pushReturn(manager.shaderManager.setFloatArray(readString(L, 1, ''), readString(L, 2, ''), readFloatArray(L, 3)));
  }

  static function lua_setShaderInt(L:cpp.RawPointer<Lua_State>):Int
  {
    var manager = current();
    if (manager == null) return 0;
    return manager.pushReturn(manager.shaderManager.setInt(readString(L, 1, ''), readString(L, 2, ''), readInt(L, 3, 0)));
  }

  static function lua_setShaderBool(L:cpp.RawPointer<Lua_State>):Int
  {
    var manager = current();
    if (manager == null) return 0;
    return manager.pushReturn(manager.shaderManager.setBool(readString(L, 1, ''), readString(L, 2, ''), readBool(L, 3, false)));
  }

  static function lua_setShaderColor(L:cpp.RawPointer<Lua_State>):Int
  {
    var manager = current();
    if (manager == null) return 0;
    return manager.pushReturn(manager.shaderManager.setColor(readString(L, 1, ''), readString(L, 2, ''), readColor(L, 3, FlxColor.WHITE)));
  }

  static function lua_tweenShaderFloat(L:cpp.RawPointer<Lua_State>):Int
  {
    var manager = current();
    if (manager == null) return 0;
    final shaderTag = readString(L, 1, '');
    final property = readString(L, 2, 'amount');
    final from = readFloat(L, 3, 0);
    final to = readFloat(L, 4, 1);
    final duration = Math.max(0, readFloat(L, 5, 1));
    final easeName = readString(L, 6, 'linear');
    final tweenTag = readString(L, 7, 'shader:${shaderTag}:${property}');
    if (shaderTag == '' || property == '' || !manager.shaderManager.hasShader(shaderTag)) return manager.pushReturn(false);

    manager.cancelTween(tweenTag);
    final holder:Dynamic = {value: from};
    manager.shaderManager.setFloat(shaderTag, property, from);
    final shaderTween = FlxTween.tween(holder, {value: to}, duration, {
      ease: resolveEase(easeName),
      onUpdate: function(_) manager.shaderManager.setFloat(shaderTag, property, holder.value),
      onComplete: function(_)
      {
        manager.shaderManager.setFloat(shaderTag, property, to);
        manager.tweens.remove(tweenTag);
        manager.callHook('onTweenCompleted', [tweenTag]);
      }
    });
    manager.tweens.set(tweenTag, shaderTween);
    return manager.pushReturn(true);
  }

  static function lua_applyShader(L:cpp.RawPointer<Lua_State>):Int
  {
    var manager = current();
    if (manager == null) return 0;
    return manager.pushReturn(manager.shaderManager.applyToTarget(readString(L, 1, ''), manager.resolveShaderTarget(readString(L, 2, ''))));
  }

  static function lua_clearShader(L:cpp.RawPointer<Lua_State>):Int
  {
    var manager = current();
    if (manager == null) return 0;
    return manager.pushReturn(manager.shaderManager.clearTarget(manager.resolveShaderTarget(readString(L, 1, ''))));
  }

  static function lua_applyCameraShader(L:cpp.RawPointer<Lua_State>):Int
  {
    var manager = current();
    if (manager == null) return 0;
    return manager.pushReturn(manager.shaderManager.applyToCamera(readString(L, 1, ''), manager.resolveCamera(readString(L, 2, 'game'))));
  }

  static function lua_clearCameraShader(L:cpp.RawPointer<Lua_State>):Int
  {
    var manager = current();
    if (manager == null) return 0;
    return manager.pushReturn(manager.shaderManager.clearCamera(manager.resolveCamera(readString(L, 1, 'game'))));
  }

  static function lua_tween(L:cpp.RawPointer<Lua_State>):Int
  {
    var manager = current();
    if (manager == null) return 0;

    var tag = readString(L, 1, '');
    var target = manager.resolvePath(readString(L, 2, '')).value;
    var values = manager.readValue(L, 3);
    var duration = readFloat(L, 4, 1);
    var easeName = readString(L, 5, 'linear');

    if (tag == '' || target == null || values == null) return manager.pushReturn(false);

    manager.cancelTween(tag);
    try
    {
      var tween = FlxTween.tween(target, values, duration,
        {
          ease: resolveEase(easeName),
          onComplete: function(_)
          {
            manager.tweens.remove(tag);
            manager.callHook('onTweenCompleted', [tag]);
          }
        });
      manager.tweens.set(tag, tween);
    }
    catch (e)
    {
      trace('[LuaScriptManager] tween failed: ${e}');
      return manager.pushReturn(false);
    }

    return manager.pushReturn(true);
  }

  static function lua_tweenObjectX(L:cpp.RawPointer<Lua_State>):Int
  {
    return tweenObjectField(L, 'x');
  }

  static function lua_tweenObjectY(L:cpp.RawPointer<Lua_State>):Int
  {
    return tweenObjectField(L, 'y');
  }

  static function lua_tweenObjectAlpha(L:cpp.RawPointer<Lua_State>):Int
  {
    return tweenObjectField(L, 'alpha');
  }

  static function lua_tweenObjectAngle(L:cpp.RawPointer<Lua_State>):Int
  {
    return tweenObjectField(L, 'angle');
  }

  static function tweenObjectField(L:cpp.RawPointer<Lua_State>, field:String):Int
  {
    var manager = current();
    if (manager == null) return 0;

    var tag = readString(L, 1, '');
    var target = manager.resolvePath(readString(L, 2, '')).value;
    var values:Dynamic = {};
    Reflect.setField(values, field, readFloat(L, 3, 0));
    var duration = readFloat(L, 4, 1);
    var easeName = readString(L, 5, 'linear');

    if (tag == '' || target == null) return manager.pushReturn(false);

    manager.cancelTween(tag);
    try
    {
      var tween = FlxTween.tween(target, values, duration,
        {
          ease: resolveEase(easeName),
          onComplete: function(_)
          {
            manager.tweens.remove(tag);
            manager.callHook('onTweenCompleted', [tag]);
          }
        });
      manager.tweens.set(tag, tween);
    }
    catch (e)
    {
      trace('[LuaScriptManager] tweenObject failed: ${e}');
      return manager.pushReturn(false);
    }

    return manager.pushReturn(true);
  }

  static function lua_cancelTween(L:cpp.RawPointer<Lua_State>):Int
  {
    var manager = current();
    if (manager == null) return 0;
    return manager.pushReturn(manager.cancelTween(readString(L, 1, '')));
  }

  static function lua_pauseTween(L:cpp.RawPointer<Lua_State>):Int
  {
    var manager = current();
    if (manager == null) return 0;
    var tween = manager.tweens.get(readString(L, 1, ''));
    if (tween == null) return manager.pushReturn(false);
    tween.active = false;
    return manager.pushReturn(true);
  }

  static function lua_resumeTween(L:cpp.RawPointer<Lua_State>):Int
  {
    var manager = current();
    if (manager == null) return 0;
    var tween = manager.tweens.get(readString(L, 1, ''));
    if (tween == null) return manager.pushReturn(false);
    tween.active = true;
    return manager.pushReturn(true);
  }

  static function lua_runTimer(L:cpp.RawPointer<Lua_State>):Int
  {
    var manager = current();
    if (manager == null) return 0;

    var tag = readString(L, 1, '');
    var delay = readFloat(L, 2, 1);
    var loops = readInt(L, 3, 1);
    if (tag == '') return manager.pushReturn(false);

    manager.cancelTimer(tag);
    var timer = new FlxTimer().start(delay, function(tmr)
    {
      manager.callHook('onTimerCompleted', [tag, tmr.loopsLeft]);
      if (tmr.loopsLeft <= 0) manager.timers.remove(tag);
    }, loops);
    manager.timers.set(tag, timer);
    return manager.pushReturn(true);
  }

  static function lua_cancelTimer(L:cpp.RawPointer<Lua_State>):Int
  {
    var manager = current();
    if (manager == null) return 0;
    return manager.pushReturn(manager.cancelTimer(readString(L, 1, '')));
  }

  static function lua_playSound(L:cpp.RawPointer<Lua_State>):Int
  {
    var manager = current();
    if (manager == null) return 0;

    var key = readString(L, 1, '');
    var volume = readFloat(L, 2, 1);
    var tag = readString(L, 3, '');
    if (key == '') return manager.pushReturn(false);
    if (tag == '') tag = 'sound:${key}:${Std.random(0x3FFFFFFF)}';

    manager.stopSound(tag);
    try
    {
      var sound = FlxG.sound.play(Paths.sound(key), volume, false, null, true, function()
      {
        manager.sounds.remove(tag);
        manager.callHook('onSoundFinished', [tag]);
      });
      sound.pitch = readFloat(L, 4, 1);
      sound.time = readFloat(L, 5, 0);
      manager.sounds.set(tag, sound);
    }
    catch (e)
    {
      trace('[LuaScriptManager] playSound failed: ${e}');
      return manager.pushReturn(false);
    }
    return manager.pushReturn(true);
  }

  static function lua_getSoundVolume(L:cpp.RawPointer<Lua_State>):Int
  {
    final manager = current();
    final sound = manager?.sounds.get(readString(L, 1, ''));
    return manager?.pushReturn(sound?.volume ?? 0) ?? 0;
  }

  static function lua_setSoundTime(L:cpp.RawPointer<Lua_State>):Int
  {
    final manager = current();
    final sound = manager?.sounds.get(readString(L, 1, ''));
    if (manager == null || sound == null) return manager?.pushReturn(false) ?? 0;
    sound.time = readFloat(L, 2, sound.time);
    return manager.pushReturn(true);
  }

  static function lua_getSoundTime(L:cpp.RawPointer<Lua_State>):Int
  {
    final manager = current();
    final sound = manager?.sounds.get(readString(L, 1, ''));
    return manager?.pushReturn(sound?.time ?? 0) ?? 0;
  }

  static function lua_setSoundPitch(L:cpp.RawPointer<Lua_State>):Int
  {
    final manager = current();
    final sound = manager?.sounds.get(readString(L, 1, ''));
    if (manager == null || sound == null) return manager?.pushReturn(false) ?? 0;
    sound.pitch = readFloat(L, 2, sound.pitch);
    return manager.pushReturn(true);
  }

  static function lua_getSoundPitch(L:cpp.RawPointer<Lua_State>):Int
  {
    final manager = current();
    final sound = manager?.sounds.get(readString(L, 1, ''));
    return manager?.pushReturn(sound?.pitch ?? 0) ?? 0;
  }

  static function lua_soundFadeIn(L:cpp.RawPointer<Lua_State>):Int
  {
    final manager = current();
    final sound = manager?.sounds.get(readString(L, 1, ''));
    if (manager == null || sound == null) return manager?.pushReturn(false) ?? 0;
    sound.fadeIn(readFloat(L, 2, 1), readFloat(L, 3, 0), readFloat(L, 4, 1));
    return manager.pushReturn(true);
  }

  static function lua_soundFadeOut(L:cpp.RawPointer<Lua_State>):Int
  {
    final manager = current();
    final sound = manager?.sounds.get(readString(L, 1, ''));
    if (manager == null || sound == null) return manager?.pushReturn(false) ?? 0;
    sound.fadeOut(readFloat(L, 2, 1), readFloat(L, 3, 0));
    return manager.pushReturn(true);
  }

  static function lua_soundFadeCancel(L:cpp.RawPointer<Lua_State>):Int
  {
    final manager = current();
    final sound = manager?.sounds.get(readString(L, 1, ''));
    if (manager == null || sound == null) return manager?.pushReturn(false) ?? 0;
    sound.fadeTween?.cancel();
    return manager.pushReturn(true);
  }

  static function lua_musicFadeIn(L:cpp.RawPointer<Lua_State>):Int
  {
    FlxG.sound.music?.fadeIn(readFloat(L, 1, 1), readFloat(L, 2, 0), readFloat(L, 3, 1));
    return 0;
  }

  static function lua_musicFadeOut(L:cpp.RawPointer<Lua_State>):Int
  {
    FlxG.sound.music?.fadeOut(readFloat(L, 1, 1), readFloat(L, 2, 0));
    return 0;
  }

  static function lua_getCameraFollowX(L:cpp.RawPointer<Lua_State>):Int return current()?.pushReturn(PlayState.instance?.cameraFollowPoint?.x ?? 0) ?? 0;
  static function lua_getCameraFollowY(L:cpp.RawPointer<Lua_State>):Int return current()?.pushReturn(PlayState.instance?.cameraFollowPoint?.y ?? 0) ?? 0;

  static function lua_setCameraFollowPoint(L:cpp.RawPointer<Lua_State>):Int
  {
    final point = PlayState.instance?.cameraFollowPoint;
    if (point == null) return current()?.pushReturn(false) ?? 0;
    point.setPosition(readFloat(L, 1, point.x), readFloat(L, 2, point.y));
    return current()?.pushReturn(true) ?? 0;
  }

  static function lua_addCameraFollowPoint(L:cpp.RawPointer<Lua_State>):Int
  {
    final point = PlayState.instance?.cameraFollowPoint;
    if (point == null) return current()?.pushReturn(false) ?? 0;
    point.setPosition(point.x + readFloat(L, 1, 0), point.y + readFloat(L, 2, 0));
    return current()?.pushReturn(true) ?? 0;
  }

  static function lua_getCameraScrollX(L:cpp.RawPointer<Lua_State>):Int return current()?.pushReturn(FlxG.camera.scroll.x) ?? 0;
  static function lua_getCameraScrollY(L:cpp.RawPointer<Lua_State>):Int return current()?.pushReturn(FlxG.camera.scroll.y) ?? 0;

  static function lua_setCameraScroll(L:cpp.RawPointer<Lua_State>):Int
  {
    FlxG.camera.scroll.set(readFloat(L, 1, FlxG.camera.scroll.x), readFloat(L, 2, FlxG.camera.scroll.y));
    return current()?.pushReturn(true) ?? 0;
  }

  static function lua_addCameraScroll(L:cpp.RawPointer<Lua_State>):Int
  {
    FlxG.camera.scroll.add(readFloat(L, 1, 0), readFloat(L, 2, 0));
    return current()?.pushReturn(true) ?? 0;
  }

  static function lua_cameraSetTarget(L:cpp.RawPointer<Lua_State>):Int
  {
    final manager = current();
    final playState = PlayState.instance;
    if (manager == null || playState == null) return 0;
    final character = manager.resolveCharacter(readString(L, 1, 'dad'));
    if (character == null) return manager.pushReturn(false);
    final point = character.getGraphicMidpoint();
    playState.cameraFollowPoint.setPosition(point.x, point.y);
    return manager.pushReturn(true);
  }

  static function lua_characterPlayAnim(L:cpp.RawPointer<Lua_State>):Int
  {
    final manager = current();
    if (manager == null) return 0;
    final character = manager.resolveCharacter(readString(L, 1, 'dad'));
    if (character == null) return manager.pushReturn(false);
    character.playAnimation(readString(L, 2, ''), readBool(L, 3, false), false, readBool(L, 4, false));
    return manager.pushReturn(true);
  }

  static function lua_characterDance(L:cpp.RawPointer<Lua_State>):Int
  {
    final manager = current();
    if (manager == null) return 0;
    final character = manager.resolveCharacter(readString(L, 1, 'dad'));
    final dance = character == null ? null : manager.safeField(character, 'dance');
    return manager.pushReturn(dance != null && manager.safeCallMethod(character, dance, []).ok);
  }

  static function lua_addOffset(L:cpp.RawPointer<Lua_State>):Int
  {
    return current()?.pushReturn(false) ?? 0;
  }

  static function lua_addCharacterToList(L:cpp.RawPointer<Lua_State>):Int
  {
    final manager = current();
    if (manager == null) return 0;
    return manager.pushReturn(funkin.data.character.CharacterData.CharacterDataParser.fetchCharacterData(readString(L, 1, '')) != null);
  }

  static function lua_getCharacterX(L:cpp.RawPointer<Lua_State>):Int return psychCharacterPosition(L, 'x', false);
  static function lua_getCharacterY(L:cpp.RawPointer<Lua_State>):Int return psychCharacterPosition(L, 'y', false);
  static function lua_setCharacterX(L:cpp.RawPointer<Lua_State>):Int return psychCharacterPosition(L, 'x', true);
  static function lua_setCharacterY(L:cpp.RawPointer<Lua_State>):Int return psychCharacterPosition(L, 'y', true);

  static function psychCharacterPosition(L:cpp.RawPointer<Lua_State>, field:String, set:Bool):Int
  {
    final manager = current();
    if (manager == null) return 0;
    final character = manager.resolveCharacter(readString(L, 1, 'dad'));
    if (character == null) return manager.pushReturn(set ? false : 0);
    if (!set) return manager.pushReturn(manager.safeGetProperty(character, field) ?? 0);
    return manager.pushReturn(manager.safeSetProperty(character, field, readFloat(L, 2, manager.numericField(character, field, 0))));
  }

  static function lua_setHits(L:cpp.RawPointer<Lua_State>):Int
  {
    Highscore.tallies.totalNotesHit = readInt(L, 1, Highscore.tallies.totalNotesHit);
    return current()?.pushReturn(true) ?? 0;
  }

  static function lua_addHits(L:cpp.RawPointer<Lua_State>):Int
  {
    Highscore.tallies.totalNotesHit += readInt(L, 1, 0);
    return current()?.pushReturn(true) ?? 0;
  }

  static function lua_setMisses(L:cpp.RawPointer<Lua_State>):Int
  {
    Highscore.tallies.missed = readInt(L, 1, Highscore.tallies.missed);
    return current()?.pushReturn(true) ?? 0;
  }

  static function lua_addMisses(L:cpp.RawPointer<Lua_State>):Int
  {
    Highscore.tallies.missed += readInt(L, 1, 0);
    return current()?.pushReturn(true) ?? 0;
  }

  static function lua_setGlobalValue(L:cpp.RawPointer<Lua_State>):Int
  {
    return current()?.pushReturn(true) ?? 0;
  }

  static function lua_setTimeBarColors(L:cpp.RawPointer<Lua_State>):Int
  {
    return current()?.pushReturn(false) ?? 0;
  }

  static function lua_updateScoreText(L:cpp.RawPointer<Lua_State>):Int
  {
    final playState = PlayState.instance;
    final manager = current();
    if (playState == null || manager == null) return 0;
    final method = manager.safeField(playState, 'updateScoreText');
    return manager.pushReturn(method != null && manager.safeCallMethod(playState, method, []).ok);
  }

  static function lua_exitSong(L:cpp.RawPointer<Lua_State>):Int
  {
    PlayState.instance?.endSong(true);
    return current()?.pushReturn(true) ?? 0;
  }

  static function lua_loadSong(L:cpp.RawPointer<Lua_State>):Int
  {
    final manager = current();
    if (manager == null) return 0;
    final songId = readString(L, 1, '');
    final song = SongRegistry.instance.fetchEntry(songId);
    if (song == null) return manager.pushReturn(false);
    final difficulty = readString(L, 2, Constants.DEFAULT_DIFFICULTY);
    LoadingState.loadPlayState({
      targetSong: song,
      targetDifficulty: difficulty,
      playbackRate: readFloat(L, 3, 1)
    }, true);
    return manager.pushReturn(true);
  }

  static function lua_triggerEvent(L:cpp.RawPointer<Lua_State>):Int
  {
    final manager = current();
    if (manager == null) return 0;
    final name = readString(L, 1, '');
    if (name == '') return manager.pushReturn(false);
    final eventData = new SongEventData(Conductor.instance.songPosition, name, {
      value1: manager.readValue(L, 2),
      value2: manager.readValue(L, 3)
    });
    final scriptEvent = new funkin.modding.events.ScriptEvent.SongEventScriptEvent(eventData);
    PlayState.instance?.dispatchEvent(scriptEvent);
    if (!scriptEvent.eventCanceled) SongEventRegistry.handleEvent(eventData);
    return manager.pushReturn(!scriptEvent.eventCanceled);
  }

  static function lua_startDialogue(L:cpp.RawPointer<Lua_State>):Int
  {
    final playState = PlayState.instance;
    if (playState == null) return current()?.pushReturn(false) ?? 0;
    playState.startConversation(readString(L, 1, ''));
    return current()?.pushReturn(true) ?? 0;
  }

  static function lua_deleteFile(L:cpp.RawPointer<Lua_State>):Int
  {
    final manager = current();
    if (manager == null) return 0;
    final path = readString(L, 1, '');
    try
    {
      if (path == '' || !FileSystem.exists(path) || FileSystem.isDirectory(path)) return manager.pushReturn(false);
      FileSystem.deleteFile(path);
      return manager.pushReturn(true);
    }
    catch (error)
    {
      return manager.pushReturn(false);
    }
  }

  static function lua_directoryFileList(L:cpp.RawPointer<Lua_State>):Int
  {
    final manager = current();
    if (manager == null) return 0;
    final path = readString(L, 1, '');
    try
    {
      return manager.pushReturn(FileSystem.exists(path) && FileSystem.isDirectory(path) ? FileSystem.readDirectory(path) : []);
    }
    catch (error)
    {
      return manager.pushReturn([]);
    }
  }

  static function lua_initSaveData(L:cpp.RawPointer<Lua_State>):Int
  {
    final manager = current();
    if (manager == null) return 0;
    final tag = readString(L, 1, '');
    if (tag == '') return manager.pushReturn(false);
    if (!manager.saveData.exists(tag))
    {
      final save = new FlxSave();
      save.bind(tag, readString(L, 2, 'PsychEngine'));
      manager.saveData.set(tag, save);
    }
    return manager.pushReturn(true);
  }

  static function lua_flushSaveData(L:cpp.RawPointer<Lua_State>):Int
  {
    final manager = current();
    final save = manager?.saveData.get(readString(L, 1, ''));
    return manager?.pushReturn(save?.flush() ?? false) ?? 0;
  }

  static function lua_getDataFromSave(L:cpp.RawPointer<Lua_State>):Int
  {
    final manager = current();
    final save = manager?.saveData.get(readString(L, 1, ''));
    if (manager == null || save == null) return manager?.pushReturn(null) ?? 0;
    return manager.pushReturn(Reflect.field(save.data, readString(L, 2, '')) ?? manager.readValue(L, 3));
  }

  static function lua_setDataFromSave(L:cpp.RawPointer<Lua_State>):Int
  {
    final manager = current();
    final save = manager?.saveData.get(readString(L, 1, ''));
    if (manager == null || save == null) return manager?.pushReturn(false) ?? 0;
    Reflect.setField(save.data, readString(L, 2, ''), manager.readValue(L, 3));
    return manager.pushReturn(true);
  }

  static function lua_eraseSaveData(L:cpp.RawPointer<Lua_State>):Int
  {
    final manager = current();
    final save = manager?.saveData.get(readString(L, 1, ''));
    if (manager == null || save == null) return manager?.pushReturn(false) ?? 0;
    save.erase();
    manager.saveData.remove(readString(L, 1, ''));
    return manager.pushReturn(true);
  }

  static function lua_getRandomBool(L:cpp.RawPointer<Lua_State>):Int
  {
    return current()?.pushReturn(FlxG.random.bool(readFloat(L, 1, 50))) ?? 0;
  }

  static function lua_stringStartsWith(L:cpp.RawPointer<Lua_State>):Int
  {
    return current()?.pushReturn(StringTools.startsWith(readString(L, 1, ''), readString(L, 2, ''))) ?? 0;
  }

  static function lua_stringEndsWith(L:cpp.RawPointer<Lua_State>):Int
  {
    return current()?.pushReturn(StringTools.endsWith(readString(L, 1, ''), readString(L, 2, ''))) ?? 0;
  }

  static function lua_stringSplit(L:cpp.RawPointer<Lua_State>):Int
  {
    return current()?.pushReturn(readString(L, 1, '').split(readString(L, 2, ''))) ?? 0;
  }

  static function lua_stringTrim(L:cpp.RawPointer<Lua_State>):Int
  {
    return current()?.pushReturn(StringTools.trim(readString(L, 1, ''))) ?? 0;
  }

  static function lua_getColorFromHex(L:cpp.RawPointer<Lua_State>):Int
  {
    final raw = readString(L, 1, 'FFFFFF');
    final color:FlxColor = FlxColor.fromString(StringTools.startsWith(raw, '#') ? raw : '#' + raw) ?? FlxColor.WHITE;
    return current()?.pushReturn(cast color) ?? 0;
  }

  static function lua_getColorFromName(L:cpp.RawPointer<Lua_State>):Int
  {
    final color:FlxColor = FlxColor.fromString(readString(L, 1, 'WHITE')) ?? FlxColor.WHITE;
    return current()?.pushReturn(cast color) ?? 0;
  }

  static function lua_getColorFromString(L:cpp.RawPointer<Lua_State>):Int
  {
    final color:FlxColor = FlxColor.fromString(readString(L, 1, 'WHITE')) ?? FlxColor.WHITE;
    return current()?.pushReturn(cast color) ?? 0;
  }

  static function lua_gamepadPressed(L:cpp.RawPointer<Lua_State>):Int return psychGamepadButton(L, 'pressed', false);
  static function lua_gamepadJustPressed(L:cpp.RawPointer<Lua_State>):Int return psychGamepadButton(L, 'justPressed', false);
  static function lua_gamepadReleased(L:cpp.RawPointer<Lua_State>):Int return psychGamepadButton(L, 'justReleased', false);
  static function lua_anyGamepadPressed(L:cpp.RawPointer<Lua_State>):Int return psychGamepadButton(L, 'pressed', true);
  static function lua_anyGamepadJustPressed(L:cpp.RawPointer<Lua_State>):Int return psychGamepadButton(L, 'justPressed', true);
  static function lua_anyGamepadReleased(L:cpp.RawPointer<Lua_State>):Int return psychGamepadButton(L, 'justReleased', true);

  static function psychGamepadButton(L:cpp.RawPointer<Lua_State>, stateName:String, any:Bool):Int
  {
    final manager = current();
    if (manager == null) return 0;
    final buttonName = readString(L, any ? 1 : 2, '').toUpperCase();
    if (buttonName == '') return manager.pushReturn(false);
    if (any)
    {
      for (gamepad in FlxG.gamepads.getActiveGamepads())
      {
        if (manager.readGamepadButton(gamepad, stateName, buttonName)) return manager.pushReturn(true);
      }
      return manager.pushReturn(false);
    }
    return manager.pushReturn(manager.readGamepadButton(FlxG.gamepads.getByID(readInt(L, 1, 0)), stateName, buttonName));
  }

  static function lua_gamepadAnalogX(L:cpp.RawPointer<Lua_State>):Int return psychGamepadAnalog(L, true);
  static function lua_gamepadAnalogY(L:cpp.RawPointer<Lua_State>):Int return psychGamepadAnalog(L, false);

  static function psychGamepadAnalog(L:cpp.RawPointer<Lua_State>, xAxis:Bool):Int
  {
    final manager = current();
    if (manager == null) return 0;
    final gamepad = FlxG.gamepads.getByID(readInt(L, 1, 0));
    if (gamepad == null) return manager.pushReturn(0);
    final stick = readString(L, 2, 'left').toLowerCase();
    final axisName = (stick == 'right' ? 'RIGHT_STICK_' : 'LEFT_STICK_') + (xAxis ? 'X' : 'Y');
    final analog = manager.safeField(gamepad, 'analog');
    final value = analog == null ? null : manager.safeField(analog, 'value');
    return manager.pushReturn(value == null ? 0 : manager.safeGetProperty(value, axisName) ?? 0);
  }

  static function lua_getShaderFloat(L:cpp.RawPointer<Lua_State>):Int return psychGetShaderValue(L, 'getFloat', 0.0);
  static function lua_getShaderFloatArray(L:cpp.RawPointer<Lua_State>):Int return psychGetShaderValue(L, 'getFloatArray', []);
  static function lua_getShaderInt(L:cpp.RawPointer<Lua_State>):Int return psychGetShaderValue(L, 'getInt', 0);
  static function lua_getShaderIntArray(L:cpp.RawPointer<Lua_State>):Int return psychGetShaderValue(L, 'getIntArray', []);
  static function lua_getShaderBool(L:cpp.RawPointer<Lua_State>):Int return psychGetShaderValue(L, 'getBool', false);
  static function lua_getShaderBoolArray(L:cpp.RawPointer<Lua_State>):Int return psychGetShaderValue(L, 'getBoolArray', []);

  static function psychGetShaderValue(L:cpp.RawPointer<Lua_State>, methodName:String, fallback:Dynamic):Int
  {
    final manager = current();
    if (manager == null) return 0;
    @:privateAccess final shader = manager.shaderManager.shaders.get(readString(L, 1, ''));
    final method = shader == null ? null : manager.safeField(shader, methodName);
    return manager.pushReturn(method == null ? fallback : manager.safeCallMethod(shader, method, [readString(L, 2, '')]).value ?? fallback);
  }

  static function lua_setShaderSampler2D(L:cpp.RawPointer<Lua_State>):Int
  {
    final manager = current();
    if (manager == null) return 0;
    @:privateAccess final shader = manager.shaderManager.shaders.get(readString(L, 1, ''));
    final method = shader == null ? null : manager.safeField(shader, 'setSampler2D');
    if (method == null) return manager.pushReturn(false);
    try
    {
      final bitmap = OpenFLAssets.getBitmapData(Paths.image(readString(L, 3, '')));
      return manager.pushReturn(manager.safeCallMethod(shader, method, [readString(L, 2, ''), bitmap]).ok);
    }
    catch (error)
    {
      return manager.pushReturn(false);
    }
  }

  static function lua_precacheImage(L:cpp.RawPointer<Lua_State>):Int
  {
    final manager = current();
    try
    {
      Paths.image(readString(L, 1, ''));
      return manager?.pushReturn(true) ?? 0;
    }
    catch (error)
    {
      return manager?.pushReturn(false) ?? 0;
    }
  }

  static function lua_precacheSound(L:cpp.RawPointer<Lua_State>):Int
  {
    final manager = current();
    try
    {
      Paths.sound(readString(L, 1, ''));
      return manager?.pushReturn(true) ?? 0;
    }
    catch (error)
    {
      return manager?.pushReturn(false) ?? 0;
    }
  }

  static function lua_precacheMusic(L:cpp.RawPointer<Lua_State>):Int
  {
    final manager = current();
    try
    {
      Paths.music(readString(L, 1, ''));
      return manager?.pushReturn(true) ?? 0;
    }
    catch (error)
    {
      return manager?.pushReturn(false) ?? 0;
    }
  }

  static function lua_openCustomSubstate(L:cpp.RawPointer<Lua_State>):Int
  {
    final manager = current();
    final playState = PlayState.instance;
    if (manager == null || playState == null) return 0;
    if (manager.customSubstate != null) manager.customSubstate.close();
    manager.customSubstateName = readString(L, 1, '');
    manager.customSubstate = new FlxSubState(readBool(L, 2, false) ? FlxColor.BLACK : FlxColor.TRANSPARENT);
    manager.callHook('onCustomSubstateCreate', [manager.customSubstateName]);
    playState.openSubState(manager.customSubstate);
    manager.callHook('onCustomSubstateCreatePost', [manager.customSubstateName]);
    return manager.pushReturn(true);
  }

  static function lua_closeCustomSubstate(L:cpp.RawPointer<Lua_State>):Int
  {
    final manager = current();
    if (manager == null || manager.customSubstate == null) return manager?.pushReturn(false) ?? 0;
    manager.callHook('onCustomSubstateDestroy', [manager.customSubstateName]);
    manager.customSubstate.close();
    manager.customSubstate = null;
    manager.customSubstateName = '';
    return manager.pushReturn(true);
  }

  static function lua_insertToCustomSubstate(L:cpp.RawPointer<Lua_State>):Int
  {
    final manager = current();
    if (manager == null || manager.customSubstate == null) return manager?.pushReturn(false) ?? 0;
    final object = manager.resolvePath(readString(L, 1, '')).value;
    if (!Std.isOfType(object, FlxBasic)) return manager.pushReturn(false);
    manager.customSubstate.add(cast object);
    return manager.pushReturn(true);
  }

  static function lua_stopSound(L:cpp.RawPointer<Lua_State>):Int
  {
    var manager = current();
    if (manager == null) return 0;
    return manager.pushReturn(manager.stopSound(readString(L, 1, '')));
  }

  static function lua_pauseSound(L:cpp.RawPointer<Lua_State>):Int
  {
    var manager = current();
    if (manager == null) return 0;
    var sound = manager.sounds.get(readString(L, 1, ''));
    if (sound == null) return manager.pushReturn(false);
    sound.pause();
    return manager.pushReturn(true);
  }

  static function lua_resumeSound(L:cpp.RawPointer<Lua_State>):Int
  {
    var manager = current();
    if (manager == null) return 0;
    var sound = manager.sounds.get(readString(L, 1, ''));
    if (sound == null) return manager.pushReturn(false);
    sound.resume();
    return manager.pushReturn(true);
  }

  static function lua_setSoundVolume(L:cpp.RawPointer<Lua_State>):Int
  {
    var manager = current();
    if (manager == null) return 0;
    var sound = manager.sounds.get(readString(L, 1, ''));
    if (sound == null) return manager.pushReturn(false);
    sound.volume = readFloat(L, 2, sound.volume);
    return manager.pushReturn(true);
  }

  static function lua_soundExists(L:cpp.RawPointer<Lua_State>):Int
  {
    var manager = current();
    if (manager == null) return 0;
    return manager.pushReturn(manager.sounds.exists(readString(L, 1, '')));
  }

  static function lua_playMusic(L:cpp.RawPointer<Lua_State>):Int
  {
    var manager = current();
    if (manager == null) return 0;
    try
    {
      FlxG.sound.playMusic(Paths.music(readString(L, 1, '')), readFloat(L, 2, 1), readBool(L, 3, true));
      return manager.pushReturn(true);
    }
    catch (e)
    {
      trace('[LuaScriptManager] playMusic failed: ${e}');
      return manager.pushReturn(false);
    }
  }

  static function lua_stopMusic(L:cpp.RawPointer<Lua_State>):Int
  {
    FlxG.sound.music?.stop();
    return 0;
  }

  static function lua_pauseMusic(L:cpp.RawPointer<Lua_State>):Int
  {
    FlxG.sound.music?.pause();
    return 0;
  }

  static function lua_resumeMusic(L:cpp.RawPointer<Lua_State>):Int
  {
    FlxG.sound.music?.resume();
    return 0;
  }

  static function lua_setMusicVolume(L:cpp.RawPointer<Lua_State>):Int
  {
    if (FlxG.sound.music != null) FlxG.sound.music.volume = readFloat(L, 1, FlxG.sound.music.volume);
    return 0;
  }

  static function lua_cameraFlash(L:cpp.RawPointer<Lua_State>):Int
  {
    var manager = current();
    if (manager == null) return 0;
    manager.resolveCamera(readString(L, 1, 'game'))?.flash(readColor(L, 2, FlxColor.WHITE), readFloat(L, 3, 1));
    return 0;
  }

  static function lua_cameraFade(L:cpp.RawPointer<Lua_State>):Int
  {
    var manager = current();
    if (manager == null) return 0;
    manager.resolveCamera(readString(L, 1, 'game'))?.fade(readColor(L, 2, FlxColor.BLACK), readFloat(L, 3, 1), readBool(L, 4, false));
    return 0;
  }

  static function lua_cameraShake(L:cpp.RawPointer<Lua_State>):Int
  {
    var manager = current();
    if (manager == null) return 0;
    manager.resolveCamera(readString(L, 1, 'game'))?.shake(readFloat(L, 2, 0.01), readFloat(L, 3, 0.5));
    return 0;
  }

  static function lua_setCameraZoom(L:cpp.RawPointer<Lua_State>):Int
  {
    var manager = current();
    if (manager == null) return 0;
    var camera = manager.resolveCamera(readString(L, 1, 'game'));
    if (camera != null) camera.zoom = readFloat(L, 2, camera.zoom);
    return 0;
  }

  static function lua_setCameraAlpha(L:cpp.RawPointer<Lua_State>):Int
  {
    var manager = current();
    if (manager == null) return 0;
    var camera = manager.resolveCamera(readString(L, 1, 'game'));
    if (camera != null) camera.alpha = readFloat(L, 2, camera.alpha);
    return 0;
  }

  static function lua_setCameraBgColor(L:cpp.RawPointer<Lua_State>):Int
  {
    var manager = current();
    if (manager == null) return 0;
    var camera = manager.resolveCamera(readString(L, 1, 'game'));
    if (camera != null) camera.bgColor = readColor(L, 2, camera.bgColor);
    return 0;
  }

  static function lua_setCameraVisible(L:cpp.RawPointer<Lua_State>):Int
  {
    var manager = current();
    if (manager == null) return 0;
    var camera = manager.resolveCamera(readString(L, 1, 'game'));
    if (camera != null) camera.visible = readBool(L, 2, camera.visible);
    return 0;
  }

  static function lua_setCameraPosition(L:cpp.RawPointer<Lua_State>):Int
  {
    var manager = current();
    if (manager == null) return 0;
    var camera = manager.resolveCamera(readString(L, 1, 'game'));
    if (camera != null) camera.setPosition(readFloat(L, 2, camera.x), readFloat(L, 3, camera.y));
    return 0;
  }

  static function lua_setCameraFollow(L:cpp.RawPointer<Lua_State>):Int
  {
    var playState = PlayState.instance;
    if (playState != null && playState.cameraFollowPoint != null)
    {
      playState.cameraFollowPoint.setPosition(readFloat(L, 1, playState.cameraFollowPoint.x), readFloat(L, 2, playState.cameraFollowPoint.y));
    }
    return 0;
  }

  static function lua_setCameraBop(L:cpp.RawPointer<Lua_State>):Int
  {
    var playState = PlayState.instance;
    if (playState != null)
    {
      playState.cameraBopIntensity = readFloat(L, 1, playState.cameraBopIntensity);
      playState.cameraBopMultiplier = readFloat(L, 2, playState.cameraBopMultiplier);
      playState.hudCameraZoomIntensity = readFloat(L, 3, playState.hudCameraZoomIntensity);
    }
    return 0;
  }

  static function lua_setHealthBarColors(L:cpp.RawPointer<Lua_State>):Int
  {
    var playState = PlayState.instance;
    if (playState != null && playState.healthBar != null)
    {
      playState.healthBar.createFilledBar(readColor(L, 1, FlxColor.RED), readColor(L, 2, FlxColor.LIME));
      playState.healthBar.updateBar();
    }
    return 0;
  }

  static function lua_resetCamera(L:cpp.RawPointer<Lua_State>):Int
  {
    PlayState.instance?.resetCamera(readBool(L, 1, true), readBool(L, 2, true), readBool(L, 3, true));
    return 0;
  }

  static function lua_tweenCameraZoom(L:cpp.RawPointer<Lua_State>):Int
  {
    PlayState.instance?.tweenCameraZoom(readFloat(L, 1, 1), readFloat(L, 2, 0), readBool(L, 3, false), resolveEase(readString(L, 4, 'linear')));
    return 0;
  }

  static function lua_tweenCameraToPosition(L:cpp.RawPointer<Lua_State>):Int
  {
    PlayState.instance?.tweenCameraToPosition(readFloat(L, 1, 0), readFloat(L, 2, 0), readFloat(L, 3, 0), resolveEase(readString(L, 4, 'linear')));
    return 0;
  }

  static function lua_cancelCameraTweens(L:cpp.RawPointer<Lua_State>):Int
  {
    PlayState.instance?.cancelAllCameraTweens();
    return 0;
  }

  static function lua_tweenScrollSpeed(L:cpp.RawPointer<Lua_State>):Int
  {
    PlayState.instance?.tweenScrollSpeed(readFloat(L, 1, 1), readFloat(L, 2, 0), resolveEase(readString(L, 3, 'linear')), [readString(L, 4, 'player'), readString(L, 5, 'opponent')]);
    return 0;
  }

  static function lua_cancelScrollSpeedTweens(L:cpp.RawPointer<Lua_State>):Int
  {
    PlayState.instance?.cancelScrollSpeedTweens();
    return 0;
  }

  static function lua_pathImage(L:cpp.RawPointer<Lua_State>):Int
  {
    var manager = current();
    if (manager == null) return 0;
    try
    {
      return manager.pushReturn(Paths.image(readString(L, 1, ''), readString(L, 2, null)));
    }
    catch (e)
    {
      return manager.pushReturn(null);
    }
  }

  static function lua_pathSound(L:cpp.RawPointer<Lua_State>):Int
  {
    var manager = current();
    if (manager == null) return 0;
    try
    {
      return manager.pushReturn(Paths.sound(readString(L, 1, ''), readString(L, 2, null)));
    }
    catch (e)
    {
      return manager.pushReturn(null);
    }
  }

  static function lua_pathMusic(L:cpp.RawPointer<Lua_State>):Int
  {
    var manager = current();
    if (manager == null) return 0;
    try
    {
      return manager.pushReturn(Paths.music(readString(L, 1, ''), readString(L, 2, null)));
    }
    catch (e)
    {
      return manager.pushReturn(null);
    }
  }

  static function lua_pathFont(L:cpp.RawPointer<Lua_State>):Int
  {
    var manager = current();
    if (manager == null) return 0;
    try
    {
      return manager.pushReturn(Paths.font(readString(L, 1, '')));
    }
    catch (e)
    {
      return manager.pushReturn(null);
    }
  }

  static function lua_pathFile(L:cpp.RawPointer<Lua_State>):Int
  {
    var manager = current();
    if (manager == null) return 0;
    try
    {
      return manager.pushReturn(Paths.file(readString(L, 1, '')));
    }
    catch (e)
    {
      return manager.pushReturn(null);
    }
  }

  static function lua_pathJson(L:cpp.RawPointer<Lua_State>):Int
  {
    var manager = current();
    if (manager == null) return 0;
    try
    {
      return manager.pushReturn(Paths.json(readString(L, 1, ''), readString(L, 2, null)));
    }
    catch (e)
    {
      return manager.pushReturn(null);
    }
  }

  static function setSimpleObjectField(L:cpp.RawPointer<Lua_State>, field:String, valueIndex:Int, fallback:Float):Int
  {
    var manager = current();
    if (manager == null) return 0;
    var target = manager.resolvePath(readString(L, 1, '')).value;
    if (target == null) return manager.pushReturn(false);
    return manager.pushReturn(manager.safeSetProperty(target, field, readFloat(L, valueIndex, fallback)));
  }

  static function getSimpleObjectField(L:cpp.RawPointer<Lua_State>, field:String, fallback:Float):Int
  {
    var manager = current();
    if (manager == null) return 0;
    var target = manager.resolvePath(readString(L, 1, '')).value;
    if (target == null) return manager.pushReturn(fallback);
    return manager.pushReturn(manager.safeGetProperty(target, field) ?? fallback);
  }

  static function setPointObjectField(L:cpp.RawPointer<Lua_State>, field:String, xIndex:Int, yIndex:Int):Int
  {
    var manager = current();
    if (manager == null) return 0;

    var target = manager.resolvePath(readString(L, 1, '')).value;
    var point = target == null ? null : manager.safeGetProperty(target, field);
    var set = point == null ? null : manager.safeField(point, 'set');
    if (set == null) return manager.pushReturn(false);

    return manager.pushReturn(manager.safeCallMethod(point, set,
      [readFloat(L, xIndex, manager.safeGetProperty(point, 'x') ?? 0), readFloat(L, yIndex, manager.safeGetProperty(point, 'y') ?? 0)]).ok);
  }

  function removeSprite(tag:String):Bool
  {
    var sprite = sprites.get(tag);
    if (sprite == null) return false;

    PlayState.instance?.remove(sprite, true);
    sprite.destroy();
    sprites.remove(tag);
    return true;
  }

  function removeText(tag:String):Bool
  {
    var text = texts.get(tag);
    if (text == null) return false;

    PlayState.instance?.remove(text, true);
    text.destroy();
    texts.remove(tag);
    return true;
  }

  function cancelTween(tag:String):Bool
  {
    var tween = tweens.get(tag);
    if (tween == null) return false;
    tween.cancel();
    tweens.remove(tag);
    return true;
  }

  function cancelTimer(tag:String):Bool
  {
    var timer = timers.get(tag);
    if (timer == null) return false;
    timer.cancel();
    timers.remove(tag);
    return true;
  }

  function stopSound(tag:String):Bool
  {
    var sound = sounds.get(tag);
    if (sound == null) return false;
    sound.stop();
    sound.destroy();
    sounds.remove(tag);
    return true;
  }

  function applyCamera(sprite:FlxSprite, camera:String):Void
  {
    var resolved = resolveCamera(camera);
    if (resolved != null) sprite.cameras = [resolved];
  }

  function resolveCamera(camera:String):Null<flixel.FlxCamera>
  {
    var playState = PlayState.instance;
    if (playState == null) return FlxG.camera;

    return switch (camera)
    {
      case 'hud' | 'camHUD': playState.camHUD;
      case 'cutscene' | 'camCutscene': playState.camCutscene;
      case 'game' | 'camGame': playState.camGame;
      default: FlxG.camera;
    }
  }

  function resolveStrumline(target:String):Null<funkin.play.notes.Strumline>
  {
    var playState = PlayState.instance;
    if (playState == null) return null;

    return switch (target)
    {
      case 'opponent' | 'dad' | 'p2' | 'enemy': playState.opponentStrumline;
      default: playState.playerStrumline;
    }
  }

  function safeField(target:Dynamic, field:String):Dynamic
  {
    try
    {
      return Reflect.field(target, field);
    }
    catch (e)
    {
      return null;
    }
  }

  function safeGetProperty(target:Dynamic, field:String):Dynamic
  {
    try
    {
      return Reflect.getProperty(target, field);
    }
    catch (e)
    {
      return null;
    }
  }

  function safeSetProperty(target:Dynamic, field:String, value:Dynamic, report:Bool = true):Bool
  {
    try
    {
      Reflect.setProperty(target, field, value);
      return true;
    }
    catch (e)
    {
      if (report) reportLuaWarning('api-error', 'lua-api', 'setProperty', 'setProperty failed for ${field}: ${e}');
      return false;
    }
  }

  function safeCallMethod(target:Dynamic, method:Dynamic, args:Array<Dynamic>):{ok:Bool, value:Dynamic}
  {
    try
    {
      return {ok: true, value: Reflect.callMethod(target, method, args)};
    }
    catch (e)
    {
      reportLuaWarning('api-error', 'lua-api', 'callMethod', 'callMethod failed: ${e}');
      return {ok: false, value: null};
    }
  }

  function resolveRelativePath(root:Dynamic, path:String):Dynamic
  {
    var value = root;
    for (part in cachedPathParts(path))
    {
      if (value == null) return null;
      value = resolvePart(value, part);
    }
    return value;
  }

  function setRelativePath(root:Dynamic, path:String, value:Dynamic):Bool
  {
    final parts = cachedPathParts(path);
    if (root == null || parts.length == 0) return false;
    final field = parts.pop();
    var target = root;
    for (part in parts)
    {
      target = resolvePart(target, part);
      if (target == null) return false;
    }
    return safeSetProperty(target, field, value);
  }

  function resolveGroupItem(path:String, index:Int):Dynamic
  {
    var group = resolvePath(path).value;
    if (group == null) return null;
    final members = safeGetProperty(group, 'members');
    if (Std.isOfType(members, Array)) group = members;
    if (Std.isOfType(group, Array))
    {
      final array:Array<Dynamic> = cast group;
      return index >= 0 && index < array.length ? array[index] : null;
    }
    return safeGetProperty(group, Std.string(index));
  }

  function replaceSprite(tag:String, oldSprite:FunkinSprite, sprite:FunkinSprite):Void
  {
    final playState = PlayState.instance;
    if (playState != null && playState.members.contains(oldSprite))
    {
      final index = playState.members.indexOf(oldSprite);
      playState.remove(oldSprite, false);
      playState.insert(index, sprite);
    }
    oldSprite.destroy();
    sprites.set(tag, sprite);
  }

  function resolvePsychStrumNote(index:Int):Dynamic
  {
    final playState = PlayState.instance;
    if (playState == null) return null;
    final strumline = index < 4 ? playState.opponentStrumline : playState.playerStrumline;
    final direction = ((index % 4) + 4) % 4;
    return strumline?.getByIndex(direction);
  }

  function resolveCharacter(target:String):Dynamic
  {
    final stage = PlayState.instance?.currentStage;
    if (stage == null) return null;
    return switch (target.toLowerCase())
    {
      case '0' | 'boyfriend' | 'bf' | 'player': stage.getBoyfriend();
      case '2' | 'gf' | 'girlfriend': stage.getGirlfriend();
      default: stage.getDad();
    }
  }

  function readGamepadButton(gamepad:Dynamic, stateName:String, buttonName:String):Bool
  {
    if (gamepad == null) return false;
    final inputState = safeField(gamepad, stateName);
    final getByName = inputState == null ? null : safeField(inputState, 'getByName');
    return getByName != null && safeCallMethod(inputState, getByName, [buttonName]).value == true;
  }

  function resolvePath(path:String):{target:Dynamic, field:String, value:Dynamic}
  {
    if (path == '') return {target: null, field: '', value: null};

    var parts = cachedPathParts(path);
    var value:Dynamic = resolveRoot(parts.shift());

    for (part in parts)
    {
      if (value == null) return {target: null, field: part, value: null};
      value = resolvePart(value, part);
    }

    return {target: null, field: '', value: value};
  }

  function resolveShaderTarget(path:String):Dynamic
  {
    if (path == null || path == '') return null;
    var objectName = path;
    for (prefix in ['object:', 'stageobject:', 'stage object:'])
    {
      if (!StringTools.startsWith(objectName.toLowerCase(), prefix)) continue;
      objectName = objectName.substr(prefix.length);
      return PlayState.instance?.currentStage?.getNamedProp(objectName);
    }

    final resolved = resolvePath(path).value;
    return resolved ?? PlayState.instance?.currentStage?.getNamedProp(path);
  }

  function resolveEventPath(path:String):{target:Dynamic, field:String, value:Dynamic}
  {
    if (currentEvent == null) return {target: null, field: '', value: null};
    if (path == '') return {target: null, field: '', value: currentEvent};

    var parts = cachedPathParts(path);
    var value:Dynamic = currentEvent;

    for (part in parts)
    {
      if (value == null) return {target: null, field: part, value: null};
      value = resolvePart(value, part);
    }

    return {target: null, field: '', value: value};
  }

  function resolveParent(path:String):{target:Dynamic, field:String}
  {
    var parts = cachedPathParts(path);
    if (parts.length == 0) return {target: null, field: ''};

    var field = parts.pop();
    var target:Dynamic = resolveRoot(parts.shift());

    for (part in parts)
    {
      if (target == null) return {target: null, field: field};
      target = resolvePart(target, part);
    }

    return {target: target, field: field};
  }

  function resolveEventParent(path:String):{target:Dynamic, field:String}
  {
    if (currentEvent == null) return {target: null, field: ''};

    var parts = cachedPathParts(path);
    if (parts.length == 0) return {target: null, field: ''};

    var field = parts.pop();
    var target:Dynamic = currentEvent;

    for (part in parts)
    {
      if (target == null) return {target: null, field: field};
      target = resolvePart(target, part);
    }

    return {target: target, field: field};
  }

  function cachedPathParts(path:String):Array<String>
  {
    var cached = pathPartsCache.get(path);
    if (cached == null)
    {
      cached = path == '' ? [] : path.split('.');
      pathPartsCache.set(path, cached);
    }
    return cached.copy();
  }

  function resolveRoot(root:Null<String>):Dynamic
  {
    var playState = PlayState.instance;

    return switch (root)
    {
      case null | '' | 'playState' | 'state': playState;
      case 'FlxG': FlxG;
      case 'sound' | 'FlxG.sound': FlxG.sound;
      case 'music' | 'FlxG.sound.music': FlxG.sound.music;
      case 'Conductor': Conductor.instance;
      case 'Highscore' | 'tallies': Highscore.tallies;
      case 'camGame': playState?.camGame;
      case 'camHUD': playState?.camHUD;
      case 'camCutscene': playState?.camCutscene;
      case 'currentStage' | 'stage': playState?.currentStage;
      case 'currentSong' | 'song': playState?.currentSong;
      case 'currentChart' | 'chart': playState?.currentChart;
      case 'currentConversation' | 'conversation': playState?.currentConversation;
      case 'vocals': playState?.vocals;
      case 'scoreText': playState == null ? null : safeField(playState, 'scoreText');
      case 'healthBar': playState?.healthBar;
      case 'healthBarBG': playState?.healthBarBG;
      case 'iconP1' | 'playerIcon': playState?.iconP1;
      case 'iconP2' | 'opponentIcon': playState?.iconP2;
      case 'comboPopUps' | 'comboPopups': playState?.comboPopUps;
      case 'cameraFollowPoint' | 'cameraTarget': playState?.cameraFollowPoint;
      case 'boyfriend' | 'bf': playState?.currentStage?.getBoyfriend();
      case 'dad' | 'opponent': playState?.currentStage?.getDad();
      case 'girlfriend' | 'gf': playState?.currentStage?.getGirlfriend();
      case 'playerStrumline': playState?.playerStrumline;
      case 'opponentStrumline': playState?.opponentStrumline;
      default:
        var sprite = sprites.get(root);
        if (sprite != null) sprite;
        else
        {
          var text = texts.get(root);
          if (text != null) text else objects.get(root);
        }
    }
  }

  function resolvePart(target:Dynamic, part:String):Dynamic
  {
    if (target == null) return null;

    var bracketIndex = part.indexOf('[');
    if (bracketIndex > -1 && StringTools.endsWith(part, ']'))
    {
      var field = part.substr(0, bracketIndex);
      var index = Std.parseInt(part.substring(bracketIndex + 1, part.length - 1));
      var value:Dynamic = field == '' ? target : safeGetProperty(target, field);
      if (index == null || value == null) return null;

      if (Std.isOfType(value, Array))
      {
        var array:Array<Dynamic> = cast value;
        return array[index];
      }

      return safeGetProperty(value, Std.string(index));
    }

    return safeGetProperty(target, part);
  }

  function readValue(L:cpp.RawPointer<Lua_State>, index:Int):Dynamic
  {
    var luaType = Lua.type(L, index);

    if (luaType == Lua.TNIL || luaType == Lua.TNONE) return null;
    if (luaType == Lua.TBOOLEAN) return Lua.toboolean(L, index) != 0;
    if (luaType == Lua.TNUMBER) return Lua.tonumber(L, index);
    if (luaType == Lua.TSTRING) return Std.string(Lua.tostring(L, index));
    if (luaType == Lua.TTABLE) return readTable(L, index);

    return Std.string(Lua.tostring(L, index));
  }

  function readArgs(L:cpp.RawPointer<Lua_State>, startIndex:Int):Array<Dynamic>
  {
    var args:Array<Dynamic> = [];
    var top = Lua.gettop(L);
    for (i in startIndex...(top + 1)) args.push(readValue(L, i));
    return args;
  }

  function readTable(L:cpp.RawPointer<Lua_State>, index:Int):Dynamic
  {
    var absoluteIndex = Lua.absindex(L, index);
    var result:Dynamic = {};
    var arrayValues:Map<Int, Dynamic> = new Map<Int, Dynamic>();
    var hasArrayValues = false;
    var hasObjectValues = false;
    var maxArrayIndex = 0;

    Lua.pushnil(L);
    while (Lua.next(L, absoluteIndex) != 0)
    {
      var key = readTableKey(L, -2);
      var value = readValue(L, -1);
      if (Std.isOfType(key, Float))
      {
        var numericKey:Float = cast key;
        var arrayIndex = Std.int(numericKey);
        if (numericKey != arrayIndex)
        {
          Reflect.setField(result, Std.string(key), value);
          hasObjectValues = true;
        }
        else
        if (arrayIndex > 0)
        {
          arrayValues.set(arrayIndex, value);
          if (arrayIndex > maxArrayIndex) maxArrayIndex = arrayIndex;
          hasArrayValues = true;
        }
        else
        {
          Reflect.setField(result, Std.string(key), value);
          hasObjectValues = true;
        }
      }
      else
      {
        Reflect.setField(result, Std.string(key), value);
        hasObjectValues = true;
      }
      Lua.pop(L, 1);
    }

    if (hasArrayValues && hasObjectValues)
    {
      for (i in arrayValues.keys()) Reflect.setField(result, Std.string(i), arrayValues.get(i));
      return result;
    }

    if (hasArrayValues)
    {
      var array:Array<Dynamic> = [];
      for (i in 1...(maxArrayIndex + 1)) array.push(arrayValues.exists(i) ? arrayValues.get(i) : null);
      return array;
    }

    return result;
  }

  function readTableKey(L:cpp.RawPointer<Lua_State>, index:Int):Dynamic
  {
    var luaType = Lua.type(L, index);
    if (luaType == Lua.TSTRING) return Std.string(Lua.tostring(L, index));
    if (luaType == Lua.TNUMBER) return Lua.tonumber(L, index);
    if (luaType == Lua.TBOOLEAN) return Lua.toboolean(L, index) != 0;
    return Std.string(luaType);
  }

  static function readString(L:cpp.RawPointer<Lua_State>, index:Int, fallback:String):String
  {
    if (Lua.gettop(L) < index || Lua.type(L, index) == Lua.TNIL) return fallback;
    return Std.string(Lua.tostring(L, index));
  }

  static function readStringArray(L:cpp.RawPointer<Lua_State>, index:Int):Array<String>
  {
    var values:Array<String> = [];
    if (Lua.gettop(L) < index || Lua.type(L, index) == Lua.TNIL) return values;
    if (Lua.type(L, index) != Lua.TTABLE)
    {
      var raw = readString(L, index, '');
      return raw == '' ? values : raw.split('|');
    }

    var absoluteIndex = Lua.absindex(L, index);
    var i = 1;
    while (true)
    {
      Lua.rawgeti(L, absoluteIndex, i);
      if (Lua.type(L, -1) == Lua.TNIL)
      {
        Lua.pop(L, 1);
        break;
      }
      values.push(readString(L, -1, ''));
      Lua.pop(L, 1);
      i++;
    }
    return values;
  }

  static function readFloatArray(L:cpp.RawPointer<Lua_State>, index:Int):Array<Float>
  {
    var values:Array<Float> = [];
    if (Lua.gettop(L) < index || Lua.type(L, index) == Lua.TNIL) return values;
    if (Lua.type(L, index) != Lua.TTABLE)
    {
      values.push(readFloat(L, index, 0));
      return values;
    }

    var absoluteIndex = Lua.absindex(L, index);
    var i = 1;
    while (true)
    {
      Lua.rawgeti(L, absoluteIndex, i);
      if (Lua.type(L, -1) == Lua.TNIL)
      {
        Lua.pop(L, 1);
        break;
      }
      values.push(readFloat(L, -1, 0));
      Lua.pop(L, 1);
      i++;
    }
    return values;
  }

  static function readFloat(L:cpp.RawPointer<Lua_State>, index:Int, fallback:Float):Float
  {
    if (Lua.gettop(L) < index || Lua.type(L, index) != Lua.TNUMBER) return fallback;
    return Lua.tonumber(L, index);
  }

  static function readInt(L:cpp.RawPointer<Lua_State>, index:Int, fallback:Int):Int
  {
    if (Lua.gettop(L) < index || Lua.type(L, index) != Lua.TNUMBER) return fallback;
    return Std.int(Lua.tonumber(L, index));
  }

  static function readBool(L:cpp.RawPointer<Lua_State>, index:Int, fallback:Bool):Bool
  {
    if (Lua.gettop(L) < index || Lua.type(L, index) == Lua.TNIL) return fallback;
    return Lua.toboolean(L, index) != 0;
  }

  static function readKey(L:cpp.RawPointer<Lua_State>, index:Int):FlxKey
  {
    return FlxKey.fromString(readString(L, index, '').toUpperCase());
  }

  static function readColor(L:cpp.RawPointer<Lua_State>, index:Int, fallback:FlxColor):FlxColor
  {
    if (Lua.gettop(L) < index || Lua.type(L, index) == Lua.TNIL) return fallback;

    var luaType = Lua.type(L, index);
    if (luaType == Lua.TNUMBER) return FlxColor.fromInt(readInt(L, index, fallback));
    if (luaType == Lua.TSTRING) return FlxColor.fromString(readString(L, index, Std.string(fallback))) ?? fallback;

    return fallback;
  }

  static function readTextAlign(L:cpp.RawPointer<Lua_State>, index:Int, fallback:FlxTextAlign):FlxTextAlign
  {
    return switch (readString(L, index, '').toLowerCase())
    {
      case 'left': FlxTextAlign.LEFT;
      case 'center': FlxTextAlign.CENTER;
      case 'right': FlxTextAlign.RIGHT;
      case 'justify': FlxTextAlign.JUSTIFY;
      default: fallback;
    }
  }

  static function readAxes(L:cpp.RawPointer<Lua_State>, index:Int, fallback:FlxAxes):FlxAxes
  {
    return switch (readString(L, index, '').toLowerCase())
    {
      case 'x': FlxAxes.X;
      case 'y': FlxAxes.Y;
      case 'xy' | 'both': FlxAxes.XY;
      default: fallback;
    }
  }

  static function resolveEase(name:String):EaseFunction
  {
    return switch (name)
    {
      case 'quadIn': FlxEase.quadIn;
      case 'quadOut': FlxEase.quadOut;
      case 'quadInOut': FlxEase.quadInOut;
      case 'cubeIn': FlxEase.cubeIn;
      case 'cubeOut': FlxEase.cubeOut;
      case 'cubeInOut': FlxEase.cubeInOut;
      case 'sineIn': FlxEase.sineIn;
      case 'sineOut': FlxEase.sineOut;
      case 'sineInOut': FlxEase.sineInOut;
      case 'elasticIn': FlxEase.elasticIn;
      case 'elasticOut': FlxEase.elasticOut;
      case 'elasticInOut': FlxEase.elasticInOut;
      case 'bounceIn': FlxEase.bounceIn;
      case 'bounceOut': FlxEase.bounceOut;
      case 'bounceInOut': FlxEase.bounceInOut;
      case 'backIn': FlxEase.backIn;
      case 'backOut': FlxEase.backOut;
      case 'backInOut': FlxEase.backInOut;
      default: FlxEase.linear;
    }
  }
  #end
}
