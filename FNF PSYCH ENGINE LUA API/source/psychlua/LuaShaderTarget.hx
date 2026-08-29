package psychlua;

#if FEATURE_PSYCH_LUA
import flixel.system.FlxAssets.FlxShader;

typedef LuaShaderTarget =
{
  var target:Dynamic;
  var shader:FlxShader;
  var tag:String;
  var previousShader:Dynamic;
}
#end
