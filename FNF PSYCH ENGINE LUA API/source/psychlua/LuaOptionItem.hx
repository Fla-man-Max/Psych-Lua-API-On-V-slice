package psychlua;

#if FEATURE_PSYCH_LUA
typedef LuaOptionItem =
{
  var kind:String;
  var key:String;
  var label:String;
  var description:String;
  var defaultValue:Dynamic;
  var min:Float;
  var max:Float;
  var step:Float;
  var precision:Int;
  var values:Dynamic;
}
#end
