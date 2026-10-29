using System;
using System.Text;
using System.Globalization;
using System.Web.Script.Serialization;
namespace LocalUsageValidation {
 // Strict JSON syntax walker: validates but does not allocate conversation/tool payload objects.
 // Only whitelisted usage fields are copied into the small JSON passed to JavaScriptSerializer.
 public static class JsonProjection {
  public static string Project(string source,string service){var p=new Walker(source);string r=p.Object(service,0);p.White();if(p.At!=source.Length)throw new FormatException("trailing_json");return r;}
  sealed class Walker {
   readonly string s;public int At;public Walker(string text){s=text;}
   public void White(){while(At<s.Length&&(s[At]==' '||s[At]=='\r'||s[At]=='\n'||s[At]=='\t'||(At==0&&s[At]=='\uFEFF')))At++;}
   void Need(char c){White();if(At>=s.Length||s[At++]!=c)throw new FormatException("json_syntax");}
   int StringEnd(){int begin=At;if(At>=s.Length||s[At++]!='"')throw new FormatException("json_string");while(At<s.Length){char c=s[At++];if(c=='"')return begin;if(c<32)throw new FormatException("json_control");if(c=='\\'){if(At>=s.Length)throw new FormatException("json_escape");char esc=s[At++];if(esc=='u'){for(int n=0;n<4;n++){if(At>=s.Length||!Uri.IsHexDigit(s[At++]))throw new FormatException("json_unicode");}}else if("\"\\/bfnrt".IndexOf(esc)<0)throw new FormatException("json_escape");}}throw new FormatException("json_string_end");}
   string Key(){White();int start=At;StringEnd();int length=At-start;if(length>512)throw new FormatException("key_too_long");string raw=s.Substring(start,length);if(raw.IndexOf('\\')<0)return raw.Substring(1,raw.Length-2);return new JavaScriptSerializer().Deserialize<string>(raw);}
   static bool Keep(string mode,string key){if(mode=="claude")return key=="type"||key=="timestamp"||key=="requestId"||key=="message";if(mode=="message")return key=="id"||key=="usage";if(mode=="usage")return key=="input_tokens"||key=="output_tokens"||key=="cache_read_input_tokens"||key=="cache_creation_input_tokens";if(mode=="antigravity")return key=="type"||key=="status"||key=="step_index"||key=="created_at"||key=="input_tokens"||key=="output_tokens"||key=="cache_read_tokens";return false;}
   public string Object(string mode,int depth){if(depth>64)throw new FormatException("json_depth");Need('{');var b=new StringBuilder("{");bool first=true;White();if(At<s.Length&&s[At]=='}'){At++;return "{}";}while(true){string key=Key();Need(':');White();int start=At;bool keep=Keep(mode,key);string value=null;if(keep&&At<s.Length&&s[At]=='{'&&((mode=="claude"&&key=="message")||(mode=="message"&&key=="usage")))value=Object(key,depth+1);else{Skip(depth+1);if(keep){if(At-start>65536)throw new FormatException("selected_value_too_large");value=s.Substring(start,At-start);}}if(keep){if(!first)b.Append(',');first=false;b.Append('"').Append(key).Append("\":").Append(value);if(b.Length>65536)throw new FormatException("projection_too_large");}White();if(At>=s.Length)throw new FormatException("json_object_end");char end=s[At++];if(end=='}')break;if(end!=',')throw new FormatException("json_object_separator");}return b.Append('}').ToString();}
   void Skip(int depth){if(depth>64)throw new FormatException("json_depth");White();if(At>=s.Length)throw new FormatException("json_value");char c=s[At];if(c=='"'){StringEnd();return;}if(c=='{'){At++;White();if(At<s.Length&&s[At]=='}'){At++;return;}while(true){Key();Need(':');Skip(depth+1);White();if(At>=s.Length)throw new FormatException("json_object_end");char end=s[At++];if(end=='}')return;if(end!=',')throw new FormatException("json_object_separator");}}if(c=='['){At++;White();if(At<s.Length&&s[At]==']'){At++;return;}while(true){Skip(depth+1);White();if(At>=s.Length)throw new FormatException("json_array_end");char end=s[At++];if(end==']')return;if(end!=',')throw new FormatException("json_array_separator");}}if(c=='t'){Literal("true");return;}if(c=='f'){Literal("false");return;}if(c=='n'){Literal("null");return;}if(c=='-'||(c>='0'&&c<='9')){Number();return;}throw new FormatException("json_value");}
   void Literal(string text){if(At+text.Length>s.Length||String.CompareOrdinal(s,At,text,0,text.Length)!=0)throw new FormatException("json_literal");At+=text.Length;}
   bool Digit(){return At<s.Length&&s[At]>='0'&&s[At]<='9';}
   void Number(){if(s[At]=='-')At++;if(!Digit())throw new FormatException("json_number");if(s[At]=='0')At++;else while(Digit())At++;if(At<s.Length&&s[At]=='.'){At++;if(!Digit())throw new FormatException("json_fraction");while(Digit())At++;}if(At<s.Length&&(s[At]=='e'||s[At]=='E')){At++;if(At<s.Length&&(s[At]=='+'||s[At]=='-'))At++;if(!Digit())throw new FormatException("json_exponent");while(Digit())At++;}}
  }
 }
}
