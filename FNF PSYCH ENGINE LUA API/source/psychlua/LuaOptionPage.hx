package psychlua;

#if FEATURE_PSYCH_LUA
typedef LuaOptionPage =
{
  var id:String;
  var title:String;
  var position:Int;
  var items:Array<LuaOptionItem>;
}
#end
