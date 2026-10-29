using System;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;
using System.Reflection;
using System.Security.Cryptography;
public static class AuthReadOnlyTests {
 static int passed;
 static void Check(bool value,string name){if(!value)throw new Exception(name);passed++;Console.WriteLine("PASS "+name);}
 static string Json(string token){return "{\"claudeAiOauth\":{\"accessToken\":\""+token+"\",\"refreshToken\":\"synthetic-not-used\",\"expiresAt\":1}}";}
 static string InvokeGet(Func<string> token,int requests,int finalStatus,out int status){
  var server=new TcpListener(IPAddress.Loopback,0);server.Start();int port=((IPEndPoint)server.LocalEndpoint).Port;Exception failure=null;int handled=0;
  var thread=new Thread(delegate(){try{for(int i=0;i<requests;i++){using(var client=server.AcceptTcpClient()){client.ReceiveTimeout=4000;client.SendTimeout=4000;using(var stream=client.GetStream()){var reader=new StreamReader(stream,Encoding.ASCII,false,1024,true);string line;while((line=reader.ReadLine())!=null&&line.Length>0){}int code=i==requests-1?finalStatus:401;byte[] body=Encoding.UTF8.GetBytes("{}");byte[] head=Encoding.ASCII.GetBytes("HTTP/1.1 "+code+(code==200?" OK":" Unauthorized")+"\r\nContent-Type: application/json\r\nContent-Length: 2\r\nConnection: close\r\n\r\n");stream.Write(head,0,head.Length);stream.Write(body,0,body.Length);handled++;}}}}catch(Exception e){failure=e;}});thread.IsBackground=true;thread.Start();
  try{object[] args={"http://127.0.0.1:"+port+"/quota","X-Synthetic","fixture",token,0};string body=(string)typeof(Usage).GetMethod("AuthedGet",BindingFlags.NonPublic|BindingFlags.Static).Invoke(null,args);status=(int)args[4];if(!thread.Join(5000))throw new Exception("synthetic_server_timeout");if(failure!=null)throw failure;Check(handled==requests,"expected_GET_request_count_"+requests);return body;}finally{server.Stop();}
 }
 public static int Main(string[] args){string dir=args[0];Directory.CreateDirectory(dir);string file=Path.Combine(dir,"synthetic-login.fixture");try{
  // keep synthetic merge messages out of the real widget log
  typeof(Log).GetField("Dir").SetValue(null,dir);typeof(Log).GetField("FilePath").SetValue(null,Path.Combine(dir,"test.log"));
  Check(Log.FilePath.StartsWith(dir),"test_log_redirected");
  foreach(string name in new[]{"PatchFile","RenewClaude","RenewGrok","PostToken","CanWrite","CleanupTemps"})Check(typeof(Usage).GetMethod(name,BindingFlags.NonPublic|BindingFlags.Public|BindingFlags.Static)==null,"removed_credential_mutator_"+name);
  File.WriteAllText(file,Json("synthetic-one"));byte[] before=File.ReadAllBytes(file);File.SetAttributes(file,FileAttributes.ReadOnly);
  var read=typeof(Usage).GetMethod("ReadClaude",BindingFlags.NonPublic|BindingFlags.Static);var one=read.Invoke(null,new object[]{file});Check((string)one.GetType().GetField("Access").GetValue(one)=="synthetic-one","read_only_login_file_works");
  Check(Convert.ToBase64String(before)==Convert.ToBase64String(File.ReadAllBytes(file)),"login_bytes_unchanged_after_read");File.SetAttributes(file,FileAttributes.Normal);
  File.WriteAllText(file,Json("synthetic-owner-new"));var two=read.Invoke(null,new object[]{file});Check((string)two.GetType().GetField("Access").GetValue(two)=="synthetic-owner-new","official_tool_update_is_read_not_overwritten");
  int calls=0,status;string result=InvokeGet(delegate{calls++;return "synthetic-same";},1,401,out status);Check(calls==2&&status==401&&result==null,"401_same_token_no_repeat_no_refresh");
  calls=0;result=InvokeGet(delegate{return ++calls==1?"synthetic-old":"synthetic-new";},2,200,out status);Check(calls==2&&status==200&&result=="{}","401_retry_only_after_owner_changes_token");
  Check(Usage.RemainingNumber(0)=="0"&&Usage.RemainingNumber(100)=="100","exact_endpoints_remain_exact");
  Check(Usage.RemainingNumber(0.4)=="<1"&&Usage.RemainingNumber(0.001)=="<1","nonzero_remaining_never_rounds_to_zero");
  Check(Usage.RemainingNumber(99.6)==">99","not_full_never_rounds_to_full");
  Check(Usage.RemainingNumber(1)=="1"&&Usage.PercentText(99)=="99","99_used_means_1_remaining");
  Check(Usage.PercentText(0.004)=="<0.01"&&Usage.PercentText(99.996)==">99.99","tooltip_preserves_small_nonzero_amounts");
  Check(Usage.AuthError("Claude",403).Contains("403")&&!Usage.AuthError("Claude",403).Contains("login expired"),"403_is_permission_denied_not_expired_login");
  Check(Usage.AuthError("Claude",401).Contains("login expired (401)"),"401_remains_explicit_login_rejection");
  // account identity: a value never survives an account switch
  var mergeM=typeof(GaugeForm).GetMethod("Merge",BindingFlags.NonPublic|BindingFlags.Static);
  Func<Quota,Quota,bool,Quota> merge=delegate(Quota p,Quota f,bool h){return (Quota)mergeM.Invoke(null,new object[]{p,f,12,h});};
  Func<string,string,string,Quota> okQ=delegate(string acct,string key,string cred){var q=new Quota{Name="Claude",Ok=true,Remaining=1,LastOkUtc=DateTime.UtcNow};return Usage.Tag(q,acct,key,cred);};
  Func<string,string,string,Quota> failQ=delegate(string key,string cred,string err){return Usage.Tag(new Quota{Name="Claude",Error=err},null,key,cred);};
  var r1=merge(okQ("old@example.com","claude:A","t1"),failQ("claude:B","t2","Timed out"),true);Check(!r1.Ok&&r1.Remaining==0,"account_switch_with_failure_drops_old_value");
  var r2=merge(okQ("a@example.com","claude:A","t1"),failQ(null,"t2","Timed out"),true);Check(!r2.Ok,"new_token_unknown_account_does_not_reuse_old_value");
  var r3=merge(okQ("a@example.com","claude:A","t1"),failQ(null,"t1","Timed out"),true);Check(r3.Ok&&r3.Failing&&r3.Remaining==1&&r3.Account=="a@example.com","same_token_transient_failure_keeps_value_and_account");
  var r4=merge(okQ("a@example.com","claude:A","t1"),failQ(null,null,"Claude login not found"),true);Check(!r4.Ok,"missing_login_drops_old_value");
  var ag=new Quota{Name="Gemini",Ok=true,Remaining=18,LastOkUtc=DateTime.UtcNow};var r5=merge(ag,new Quota{Name="Gemini",Error="Timed out"},false);Check(r5.Ok&&r5.Failing,"no_identity_service_keeps_previous_behavior");
  var fresh=okQ("new@example.com","claude:B","t3");fresh.Remaining=100;var r6=merge(okQ("old@example.com","claude:A","t1"),fresh,true);Check(r6.Account=="new@example.com"&&r6.Remaining==100&&r6.AccountChangedUtc!=DateTime.MinValue,"account_switch_success_shows_new_account_and_marks_change");
  var same=okQ(null,null,"t1");var r7=merge(okQ("a@example.com","claude:A","t1"),same,true);Check(r7.Account=="a@example.com"&&r7.AccountKey=="claude:A","same_token_inherits_account_when_profile_unavailable");
  var other=okQ(null,null,"t9");var r8=merge(okQ("a@example.com","claude:A","t1"),other,true);Check(r8.Account==null,"new_token_without_profile_is_not_labelled_with_old_account");
  Check(GaugeForm.Who(r8).Contains("계정 확인 안 됨")||GaugeForm.Who(r8).Contains("account unknown"),"unknown_account_is_shown_explicitly");
  // token aged out vs revoked
  var now=DateTime.UtcNow;
  Check(!Usage.Rejected("Claude",401,now.AddMinutes(-5),now).Contains("login expired"),"aged_out_token_does_not_offer_relogin");
  Check(Usage.Rejected("Claude",401,now.AddHours(2),now).Contains("login expired"),"rejected_unexpired_token_is_login_problem");
  Check(Usage.Rejected("Claude",403,now.AddMinutes(-5),now).Contains("403"),"403_stays_permission_error");
  // id_token decode for display
  string payload=Convert.ToBase64String(Encoding.UTF8.GetBytes("{\"email\":\"user@example.com\"}")).TrimEnd('=').Replace('+','-').Replace('/','_');
  var claims=Usage.JwtClaims("x."+payload+".y");Check(claims!=null&&(string)claims["email"]=="user@example.com","codex_id_token_email_decoded");
  Check(Usage.JwtClaims("garbage")==null&&Usage.JwtClaims(null)==null,"bad_id_token_is_ignored");
  Check(Usage.Hash("secret-a")!=Usage.Hash("secret-b")&&!Usage.Hash("secret-a").Contains("secret"),"token_hash_is_one_way_and_distinct");
  // Claude credential file: expiry is read, token file still untouched
  File.WriteAllText(file,"{\"claudeAiOauth\":{\"accessToken\":\"synthetic\",\"expiresAt\":1000}}");var lg=Usage.ReadClaude(file);Check(lg.ExpiresUtc.HasValue&&lg.ExpiresUtc.Value.Year==1970,"claude_expiry_read");
  Console.WriteLine("RESULT "+passed+" passed; real credentials and public APIs untouched");return 0;
 }catch(Exception e){Console.Error.WriteLine(e.GetType().Name+": "+e.Message);return 1;}finally{if(File.Exists(file)){File.SetAttributes(file,FileAttributes.Normal);File.Delete(file);}}}
}
