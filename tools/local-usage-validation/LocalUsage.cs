using System;
using System.IO;
using System.Text;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.Web.Script.Serialization;

namespace LocalUsageValidation {
 public sealed class Options {
  public TimeZoneInfo Timezone = TimeZoneInfo.Local;
  public long MaxBytes = 1073741824L, MaxFileBytes = 134217728L;
  public int MaxLineBytes = 2097152, MaxFiles = 10000, MaxMilliseconds = 45000;
 }
 public sealed class Counts {
  public long input, output, cacheRead, cacheCreate, reasoning, total, requests;
  internal Counts Copy() { return (Counts)MemberwiseClone(); }
  internal bool Add(Counts b) { try { checked { long i=input+b.input,o=output+b.output,c=cacheRead+b.cacheRead,k=cacheCreate+b.cacheCreate,r=reasoning+b.reasoning,t=total+b.total,q=requests+b.requests; input=i;output=o;cacheRead=c;cacheCreate=k;reasoning=r;total=t;requests=q; } return true; } catch(OverflowException){return false;} }
  internal bool Same(Counts b) {return input==b.input && output==b.output && cacheRead==b.cacheRead && cacheCreate==b.cacheCreate && reasoning==b.reasoning && total==b.total;}
 }
 public sealed class Day { public string date; public long input,output,cacheRead,cacheCreate,reasoning,total,requests; internal Day(string d,Counts c){date=d;input=c.input;output=c.output;cacheRead=c.cacheRead;cacheCreate=c.cacheCreate;reasoning=c.reasoning;total=c.total;requests=c.requests;} }
 public sealed class Coverage {
  public int filesFound,filesRead,cacheHits,duplicateRecords,conflictingRecords,invalidRecords,skippedFiles,incompleteRecords,unsupportedFiles,unmeteredRecords,totalMismatches,errors;
  public long bytesRead; public bool partial,limitReached; public string selectionBoundary="record_timestamp_last_30_local_calendar_days;all_candidate_mtimes_scanned";
  internal void Merge(Coverage c){unmeteredRecords+=c.unmeteredRecords;invalidRecords+=c.invalidRecords;incompleteRecords+=c.incompleteRecords;unsupportedFiles+=c.unsupportedFiles;totalMismatches+=c.totalMismatches;errors+=c.errors;partial|=c.partial;}
 }
 public sealed class Result {
  public string service,scope="this_device",timezone,from,to,status,semanticNote;
  public bool missingDaysAreNoRecords=true;
  public List<Day> days=new List<Day>(); public Counts totals; public Coverage coverage=new Coverage(); public long elapsedMs;
 }
 internal sealed class Record { public string key; public DateTimeOffset at; public Counts count; }
 internal sealed class Entry {public long length,ticks,changeStamp;public List<Record> records=new List<Record>();public Coverage diagnostics=new Coverage();}
 internal sealed class Budget { public Stopwatch clock=Stopwatch.StartNew();public long bytes; public int files,entries; }
 public sealed class Collector {
  // One Collector instance is single-threaded; cache checks length+mtime+OS change time, not byte-incremental.
  // The open file handle's resolved path is checked before any content is read.
  // Defaults stay 1 GiB/128 MiB/45 s. Explicit one-time indexing may allow up to 8 GiB/512 MiB/180 s.
  // Stable parse diagnostics are cached too; a changed file invalidates both data and diagnostics.
  // Time budget is cooperative: blocking filesystem calls and one bounded JSON parse cannot be preempted.
  public static void InitializePathHandling(){}
  public static string NormalizeRoot(string root){string p=Path.GetFullPath(root);if(Path.DirectorySeparatorChar=='\\'&&!p.StartsWith(@"\\?\",StringComparison.Ordinal)){p=p.StartsWith(@"\\",StringComparison.Ordinal)?@"\\?\UNC\"+p.Substring(2):@"\\?\"+p;}return p;}
  static Collector(){AppContext.SetSwitch("Switch.System.IO.UseLegacyPathHandling",false);AppContext.SetSwitch("Switch.System.IO.BlockLongPaths",false);}
  readonly Options opt; readonly Dictionary<string,Entry> cache=new Dictionary<string,Entry>(StringComparer.OrdinalIgnoreCase);
  public Collector():this(new Options()){} public Collector(Options options){if(options==null || options.Timezone==null || options.MaxBytes<=0 || options.MaxBytes>8589934592L || options.MaxFileBytes<=0 || options.MaxFileBytes>536870912L || options.MaxLineBytes<=0 || options.MaxLineBytes>2097152 || options.MaxFiles<=0 || options.MaxFiles>10000 || options.MaxMilliseconds<=0 || options.MaxMilliseconds>180000)throw new ArgumentException("invalid_limits");opt=new Options{Timezone=options.Timezone,MaxBytes=options.MaxBytes,MaxFileBytes=options.MaxFileBytes,MaxLineBytes=options.MaxLineBytes,MaxFiles=options.MaxFiles,MaxMilliseconds=options.MaxMilliseconds};}
  public void ClearCache(){cache.Clear();}
  public static string DefaultRoot(string service){string home=Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);if(service=="claude"){string c=Environment.GetEnvironmentVariable("CLAUDE_CONFIG_DIR");return Path.Combine(String.IsNullOrEmpty(c)?Path.Combine(home,".claude"):c,"projects");}if(service=="grok"){string g=Environment.GetEnvironmentVariable("GROK_HOME");return Path.Combine(String.IsNullOrEmpty(g)?Path.Combine(home,".grok"):g,"sessions");}if(service=="antigravity")return Path.Combine(home,".gemini","antigravity-cli","brain");throw new ArgumentException("unknown_service");}
  public Result Collect(string service,string root,DateTimeOffset now){return CollectCore(service,root,now,new Budget());}
  public Result[] CollectAll(DateTimeOffset now){Budget b=new Budget();Result g=CollectCore("grok",DefaultRoot("grok"),now,b),a=CollectCore("antigravity",DefaultRoot("antigravity"),now,b),c=CollectCore("claude",DefaultRoot("claude"),now,b);return new Result[]{c,g,a};}
  bool Stop(Budget b,Coverage c){if(b.clock.ElapsedMilliseconds>=opt.MaxMilliseconds || b.bytes>=opt.MaxBytes){c.partial=true;c.limitReached=true;return true;}return false;}
  static bool SafePath(string p){DirectoryInfo d=new DirectoryInfo(p);while(d!=null){if(d.Exists && (d.Attributes & FileAttributes.ReparsePoint)!=0)return false;d=d.Parent;}return true;}
  Result CollectCore(string service,string root,DateTimeOffset now,Budget budget){
   if(service!="claude" && service!="grok" && service!="antigravity")throw new ArgumentException("unknown_service");
   long start=budget.clock.ElapsedMilliseconds;DateTime end=TimeZoneInfo.ConvertTime(now,opt.Timezone).Date,begin=end.AddDays(-29);Result result=new Result{service=service,timezone=opt.Timezone.Id,from=begin.ToString("yyyy-MM-dd",CultureInfo.InvariantCulture),to=end.ToString("yyyy-MM-dd",CultureInfo.InvariantCulture),status="ok",semanticNote=service=="antigravity"?"total=input+output;cacheRead_separate;headless_documented_semantics_assumed_for_transcript_not_directly_verified":service=="grok"?"total=input+output;cacheRead_and_reasoning_are_subsets":"total=input+output+cacheRead+cacheCreate;nested_breakdowns_excluded"};Coverage cov=result.coverage;
   if(String.IsNullOrEmpty(root))root=DefaultRoot(service);root=NormalizeRoot(root);
   try{if(!Directory.Exists(root)){result.status="no_data";result.elapsedMs=budget.clock.ElapsedMilliseconds-start;return result;}if(!SafePath(root)){cov.partial=true;cov.skippedFiles++;result.status="partial";result.elapsedMs=budget.clock.ElapsedMilliseconds-start;return result;}}catch{cov.errors++;cov.partial=true;result.status="partial";return result;}
   Dictionary<string,Record> unique=new Dictionary<string,Record>(StringComparer.Ordinal);
   bool halt=false;List<FileInfo> candidates=Candidates(root,service,budget,cov);
   foreach(FileInfo candidate in candidates){if(halt||Stop(budget,cov))break;string path=candidate.FullName;
    try {FileInfo fi=new FileInfo(path);long length=fi.Length,ticks=fi.LastWriteTimeUtc.Ticks;if(length>opt.MaxFileBytes){cov.skippedFiles++;cov.partial=true;continue;}
     long changeStamp=FileSafety.Stamp(path,root);Entry e;if(cache.TryGetValue(service+"|"+path,out e)&&e.length==length&&e.ticks==ticks&&changeStamp!=0&&e.changeStamp==changeStamp){cov.cacheHits++;}else{
      e=new Entry{length=length,ticks=ticks,changeStamp=changeStamp};Read(root,path,service,e,budget,cov);cov.filesRead++;fi.Refresh();
      if(fi.Length!=length||fi.LastWriteTimeUtc.Ticks!=ticks||FileSafety.Stamp(path,root)!=changeStamp){e.diagnostics.partial=true;e.diagnostics.incompleteRecords++;cache.Remove(service+"|"+path);}else if(!cov.limitReached && e.diagnostics.errors==0){if(cache.Count>=opt.MaxFiles)cache.Clear();cache[service+"|"+path]=e;}else cache.Remove(service+"|"+path);
     }
     cov.Merge(e.diagnostics);foreach(Record r in e.records){if(budget.clock.ElapsedMilliseconds>=opt.MaxMilliseconds){cov.partial=cov.limitReached=true;halt=true;break;}Record prior;if(unique.TryGetValue(r.key,out prior)){cov.duplicateRecords++;if(service=="claude"&&prior.count.input==r.count.input&&prior.count.cacheRead==r.count.cacheRead&&prior.count.cacheCreate==r.count.cacheCreate){unique[r.key]=new Record{key=r.key,at=prior.at<r.at?prior.at:r.at,count=prior.count.output>=r.count.output?prior.count:r.count};}else if(prior.at!=r.at||!prior.count.Same(r.count)){cov.conflictingRecords++;cov.partial=true;}}else unique.Add(r.key,r);}
    }catch{cov.errors++;cov.skippedFiles++;cov.partial=true;}
   }
   SortedDictionary<string,Counts> days=new SortedDictionary<string,Counts>(StringComparer.Ordinal);for(DateTime d=begin;d<=end;d=d.AddDays(1))days.Add(d.ToString("yyyy-MM-dd",CultureInfo.InvariantCulture),new Counts());result.totals=new Counts();
   foreach(Record r in unique.Values){DateTime day=TimeZoneInfo.ConvertTime(r.at,opt.Timezone).Date;if(day<begin||day>end)continue;Counts daily=days[day.ToString("yyyy-MM-dd",CultureInfo.InvariantCulture)],next=result.totals.Copy(),nextDay=daily.Copy();if(!next.Add(r.count)||!nextDay.Add(r.count)){cov.invalidRecords++;cov.partial=true;continue;}result.totals=next;days[day.ToString("yyyy-MM-dd",CultureInfo.InvariantCulture)]=nextDay;}
   if(cov.filesFound==0){result.status=cov.partial?"partial":"no_data";result.totals=null;}else {foreach(KeyValuePair<string,Counts> d in days)result.days.Add(new Day(d.Key,d.Value));result.status=cov.partial?"partial":"ok";if(unique.Count==0&&cov.unsupportedFiles>0){result.status="unsupported_no_history";result.totals=null;result.days.Clear();}}
   result.elapsedMs=budget.clock.ElapsedMilliseconds-start;return result;
  }
  List<FileInfo> Candidates(string root,string service,Budget budget,Coverage cov){
   List<FileInfo> list=new List<FileInfo>();Stack<string> dirs=new Stack<string>();dirs.Push(Path.GetFullPath(root));bool halt=false;
   while(dirs.Count>0&&!halt&&!Stop(budget,cov)){string dir=dirs.Pop();try{foreach(string p in Directory.EnumerateFileSystemEntries(dir)){
    if(Stop(budget,cov)){halt=true;break;}if(++budget.entries>100000){cov.partial=cov.limitReached=true;halt=true;break;}
    FileAttributes attr;try{attr=File.GetAttributes(p);}catch{cov.errors++;cov.partial=true;continue;}
    if((attr&FileAttributes.ReparsePoint)!=0){cov.skippedFiles++;cov.partial=true;continue;}
    if((attr&FileAttributes.Directory)!=0){if(service=="antigravity"){string rel=p.Substring(Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar).Length).TrimStart(Path.DirectorySeparatorChar);string[] parts=rel.Split(Path.DirectorySeparatorChar);if(parts.Length==1||(parts.Length==2&&parts[1]==".system_generated")||(parts.Length==3&&parts[1]==".system_generated"&&parts[2]=="logs"))dirs.Push(p);}else if(service=="grok"){string rel=p.Substring(Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar).Length).TrimStart(Path.DirectorySeparatorChar);if(rel.Split(Path.DirectorySeparatorChar).Length<=2)dirs.Push(p);}else dirs.Push(p);continue;}
    bool selected=service=="claude"?p.EndsWith(".jsonl",StringComparison.OrdinalIgnoreCase):service=="grok"?Path.GetFileName(p)=="usage.json":CanonicalAg(p,root);if(!selected)continue;
    cov.filesFound++;if(++budget.files>opt.MaxFiles){cov.skippedFiles++;cov.limitReached=cov.partial=true;halt=true;break;}
    try{list.Add(new FileInfo(p));}catch{cov.errors++;cov.partial=true;}
   }}catch{cov.errors++;cov.partial=true;}}
   try{list.Sort(delegate(FileInfo a,FileInfo b){return b.LastWriteTimeUtc.CompareTo(a.LastWriteTimeUtc);});}catch{cov.errors++;cov.partial=true;}
   cov.selectionBoundary="record_timestamp_last_30_local_calendar_days;newest_mtime_first;all_candidate_mtimes_eligible";return list;
  }
  static bool CanonicalAg(string path,string root){string rel=path.Substring(Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar).Length).TrimStart(Path.DirectorySeparatorChar);string[] p=rel.Split(Path.DirectorySeparatorChar);return p.Length==4&&p[1]==".system_generated"&&p[2]=="logs"&&p[3]=="transcript_full.jsonl";}
  void Read(string root,string path,string service,Entry entry,Budget budget,Coverage cov){
   using(FileStream stream=new FileStream(path,FileMode.Open,FileAccess.Read,FileShare.ReadWrite|FileShare.Delete)){
    FileSafety.Validate(stream,root);
    if(service=="grok"){using(MemoryStream mem=new MemoryStream()){byte[] buf=new byte[8192];long read=0;while(true){if(Stop(budget,cov)){entry.diagnostics.partial=true;return;}long remaining=Math.Min(opt.MaxFileBytes-read,opt.MaxBytes-budget.bytes);if(remaining<=0){entry.diagnostics.partial=true;cov.limitReached=true;return;}int n=stream.Read(buf,0,(int)Math.Min(buf.Length,remaining));if(n==0)break;read+=n;budget.bytes+=n;cov.bytesRead+=n;if(mem.Length+n>opt.MaxLineBytes){entry.diagnostics.invalidRecords++;entry.diagnostics.partial=true;return;}mem.Write(buf,0,n);}ParseGrok(Encoding.UTF8.GetString(mem.ToArray()),entry,budget,cov); }return;}
    byte[] buffer=new byte[8192];using(MemoryStream line=new MemoryStream()){bool over=false;long read=0;while(true){if(Stop(budget,cov)){entry.diagnostics.partial=true;return;}long remaining=Math.Min(opt.MaxFileBytes-read,opt.MaxBytes-budget.bytes);if(remaining<=0){entry.diagnostics.partial=true;cov.limitReached=true;return;}int n=stream.Read(buffer,0,(int)Math.Min(buffer.Length,remaining));if(n==0)break;read+=n;budget.bytes+=n;cov.bytesRead+=n;
     for(int pos=0;pos<n;){if(budget.clock.ElapsedMilliseconds>=opt.MaxMilliseconds){cov.partial=cov.limitReached=true;entry.diagnostics.partial=true;return;}int newline=Array.IndexOf<byte>(buffer,10,pos,n-pos);int finish=newline<0?n:newline;int count=finish-pos;if(!over){if(line.Length+count>opt.MaxLineBytes){over=true;entry.diagnostics.invalidRecords++;entry.diagnostics.partial=true;line.SetLength(0);}else line.Write(buffer,pos,count);}if(newline>=0){if(!over)ParseLine(Encoding.UTF8.GetString(line.ToArray()),service,path,entry,false);line.SetLength(0);over=false;}pos=newline<0?n:newline+1;}
    }if(line.Length>0&&!over)ParseLine(Encoding.UTF8.GetString(line.ToArray()),service,path,entry,true);}
   }
  }
  static Dictionary<string,object> Obj(object v){return v as Dictionary<string,object>;}
  static object Get(Dictionary<string,object>d,string k){object v;return d!=null&&d.TryGetValue(k,out v)?v:null;}
  static string Str(Dictionary<string,object>d,string k){return Get(d,k) as string;}
  static long Num(Dictionary<string,object>d,string k,bool required){object v=Get(d,k);if(v==null){if(required)throw new FormatException();return 0;}if(!(v is int)&&!(v is long)&&!(v is decimal))throw new FormatException();decimal n=Convert.ToDecimal(v,CultureInfo.InvariantCulture);if(n<0||n>long.MaxValue||Decimal.Truncate(n)!=n)throw new FormatException();return (long)n;}
  static DateTimeOffset Stamp(Dictionary<string,object>d,string key){string s=Str(d,key);DateTimeOffset t;if(s==null || !(s.EndsWith("Z",StringComparison.OrdinalIgnoreCase)||(s.Length>=6&&(s[s.Length-6]=='+'||s[s.Length-6]=='-')&&s[s.Length-3]==':')) || !DateTimeOffset.TryParse(s,CultureInfo.InvariantCulture,DateTimeStyles.None,out t))throw new FormatException();return t;}
  static string Id(Dictionary<string,object>d,string k){string s=Str(d,k);if(String.IsNullOrWhiteSpace(s))throw new FormatException();return s;}
  static string Key(string a,string b){return a.Length.ToString(CultureInfo.InvariantCulture)+":"+a+b;}
  static Dictionary<string,object> Json(string s){JavaScriptSerializer j=new JavaScriptSerializer{MaxJsonLength=134217728,RecursionLimit=64};Dictionary<string,object>d=Obj(j.DeserializeObject(s.TrimStart('\uFEFF')));if(d==null)throw new FormatException();return d;}
  static void Bad(Entry e){e.diagnostics.invalidRecords++;e.diagnostics.partial=true;}
  void ParseLine(string s,string service,string path,Entry e,bool last){if(String.IsNullOrWhiteSpace(s))return;
   // Cheap token-bearing filter avoids deserializing ordinary conversation rows.
   if(service=="claude" && (s.IndexOf("usage",StringComparison.Ordinal)<0||s.IndexOf("assistant",StringComparison.Ordinal)<0)){if(last&&!s.TrimEnd().EndsWith("}")){e.diagnostics.incompleteRecords++;e.diagnostics.partial=true;}return;}
   if(service=="antigravity" && s.IndexOf("PLANNER_RESPONSE",StringComparison.Ordinal)<0){if(last&&!s.TrimEnd().EndsWith("}")){e.diagnostics.incompleteRecords++;e.diagnostics.partial=true;}return;}
   try{Dictionary<string,object>d=Json(JsonProjection.Project(s,service));Record r=new Record();Counts c=new Counts{requests=1};if(service=="claude"){
    if(Str(d,"type")!="assistant")return;Dictionary<string,object> m=Obj(Get(d,"message")),u=Obj(Get(m,"usage"));if(u==null)return;r.key=Key(Id(m,"id"),Id(d,"requestId"));r.at=Stamp(d,"timestamp");c.input=Num(u,"input_tokens",true);c.output=Num(u,"output_tokens",true);c.cacheRead=Num(u,"cache_read_input_tokens",false);c.cacheCreate=Num(u,"cache_creation_input_tokens",false);checked{c.total=c.input+c.output+c.cacheRead+c.cacheCreate;}
   }else{if(Str(d,"type")!="PLANNER_RESPONSE"||Str(d,"status")!="DONE")return;if(Get(d,"input_tokens")==null&&Get(d,"output_tokens")==null&&Get(d,"cache_read_tokens")==null){e.diagnostics.unmeteredRecords++;e.diagnostics.partial=true;return;}long step=Num(d,"step_index",true);r.key=Key(Path.GetDirectoryName(Path.GetDirectoryName(Path.GetDirectoryName(path))),step.ToString(CultureInfo.InvariantCulture));r.at=Stamp(d,"created_at");c.input=Num(d,"input_tokens",true);c.output=Num(d,"output_tokens",true);c.cacheRead=Num(d,"cache_read_tokens",false);checked{c.total=c.input+c.output;}}
   r.count=c;e.records.Add(r);
   }catch{if(last&&!s.TrimEnd().EndsWith("}")){e.diagnostics.incompleteRecords++;e.diagnostics.partial=true;}else Bad(e);}
  }
  void ParseGrok(string s,Entry e,Budget budget,Coverage cov){try{Dictionary<string,object>d=Json(s);string id=Id(d,"sessionId");object[] turns=Get(d,"turns") as object[];if(turns==null||turns.Length==0){e.diagnostics.unsupportedFiles++;e.diagnostics.partial=true;return;}long sum=0;bool complete=true;HashSet<long> seen=new HashSet<long>();foreach(object item in turns){if(budget.clock.ElapsedMilliseconds>=opt.MaxMilliseconds){cov.partial=cov.limitReached=true;e.diagnostics.partial=true;return;}try{Dictionary<string,object> t=Obj(item);long number=Num(t,"turnNumber",true);Counts c=new Counts{input=Num(t,"inputTokens",true),output=Num(t,"outputTokens",true),cacheRead=Num(t,"cachedReadTokens",false),cacheCreate=Num(t,"cacheCreationTokens",false),reasoning=Num(t,"reasoningTokens",false),requests=1};checked{c.total=c.input+c.output;}if(Num(t,"totalTokens",true)!=c.total){e.diagnostics.totalMismatches++;e.diagnostics.partial=true;}Record r=new Record{key=Key(id,number.ToString(CultureInfo.InvariantCulture)),at=Stamp(t,"endedAt"),count=c};e.records.Add(r);if(!seen.Add(number))complete=false;else checked{sum+=c.total;}}catch{Bad(e);complete=false;}}
   Dictionary<string,object> session=Obj(Get(d,"session"));if(complete&&session!=null&&Get(session,"totalTokens")!=null&&Num(session,"totalTokens",true)!=sum){e.diagnostics.totalMismatches++;e.diagnostics.partial=true;}
  }catch{Bad(e);}}
 }
 public static class Program {
  public static int Main(string[] args){Collector.InitializePathHandling();if(args.Length!=1||args[0]!="--live"){Console.WriteLine("{\"status\":\"requires_live_flag\"}");return 2;}try{Console.WriteLine(new JavaScriptSerializer{MaxJsonLength=134217728}.Serialize(new Collector().CollectAll(DateTimeOffset.Now)));return 0;}catch{Console.WriteLine("{\"status\":\"collector_error\"}");return 1;}}
 }
}
