using System;using System.IO;using System.Text;using System.Net;using System.Net.Sockets;using System.Collections.Generic;using System.Diagnostics;using System.Threading;
public static class Tests {
 static int pass,fail;static void A(bool b){if(!b)throw new Exception("assertion");}
 static void T(string n,Action a){try{a();pass++;Probe.Emit(new{name=n,status="pass"});}catch(Exception e){fail++;Probe.Emit(new{name=n,status="fail",error=e is Probe.Bad?e.Message:e.GetType().Name});}}
 static void Reject(Action a,string s){try{a();}catch(Probe.Bad e){A(e.Message==s);return;}throw new Exception("expected_rejection");}
 static Probe.Reply Local(string headers,byte[] body,int deadline,bool slow){var l=new TcpListener(IPAddress.Loopback,0);l.Start();int port=((IPEndPoint)l.LocalEndpoint).Port;var t=new Thread(delegate(){try{using(var c=l.AcceptTcpClient())using(var s=c.GetStream()){int state=0,b;while((b=s.ReadByte())>=0){state=(state==0&&b==13)?1:(state==1&&b==10)?2:(state==2&&b==13)?3:(state==3&&b==10)?4:0;if(state==4)break;}var h=Encoding.ASCII.GetBytes(headers);s.Write(h,0,h.Length);if(slow){for(int j=0;j<body.Length;j++){s.Write(body,j,1);Thread.Sleep(40);}}else s.Write(body,0,body.Length);}}catch{}finally{l.Stop();}});t.IsBackground=true;t.Start();var r=Probe.Fetch("http://127.0.0.1:"+port+"/",null,deadline,true);t.Join(1200);l.Stop();return r;}
 static Probe.Reply Http(string status,string extras,byte[] body,int ms,bool slow){return Local("HTTP/1.1 "+status+"\r\n"+extras+"Connection: close\r\n\r\n",body,ms,slow);}
 public static void Main(){
 T("int64_exact_over_javascript_limit",delegate{A((long)Probe.Codex("{\"stats\":{\"lifetime_tokens\":9007199254740993}}")["lifetime_tokens"]==9007199254740993L);});
 T("missing_not_zero",delegate{var r=Probe.Codex("{\"stats\":{}}");A(r["lifetime_tokens"]==null&&r["daily_buckets"]==null);});
 T("malformed_json",delegate{Reject(delegate{Probe.Parse("{bad");},"invalid_json");});
 T("missing_stats",delegate{Reject(delegate{Probe.Codex("{}");},"schema_object");});
 T("reject_negative",delegate{Reject(delegate{Probe.Integer(-1);},"invalid_integer");});
 T("reject_string",delegate{Reject(delegate{Probe.Integer("123");},"invalid_integer");});
 T("reject_boolean",delegate{Reject(delegate{Probe.Integer(true);},"invalid_integer");});
 T("reject_fraction",delegate{Reject(delegate{Probe.Integer(1.5m);},"invalid_integer");});
 T("reject_int64_overflow",delegate{Reject(delegate{Probe.Integer(9223372036854775808m);},"invalid_integer");});
 T("daily_sum_exact",delegate{var r=Probe.Codex("{\"stats\":{\"daily_usage_buckets\":[{\"start_date\":\"2026-10-29\",\"tokens\":123},{\"start_date\":\"2026-10-28\",\"tokens\":456}]}}");A((long)r["daily_buckets_sum"]==579&&(string)r["first_date"]=="2026-10-28");});
 T("duplicate_day_rejected",delegate{Reject(delegate{Probe.Codex("{\"stats\":{\"daily_usage_buckets\":[{\"start_date\":\"2026-10-29\",\"tokens\":1},{\"start_date\":\"2026-10-29\",\"tokens\":2}]}}");},"duplicate_date");});
 T("invalid_day_rejected",delegate{Reject(delegate{Probe.Codex("{\"stats\":{\"daily_usage_buckets\":[{\"start_date\":\"2026-02-30\",\"tokens\":1}]}}");},"invalid_date");});
 T("sum_overflow_rejected",delegate{Reject(delegate{Probe.Codex("{\"stats\":{\"daily_usage_buckets\":[{\"start_date\":\"2026-10-28\",\"tokens\":9223372036854775807},{\"start_date\":\"2026-10-29\",\"tokens\":1}]}}");},"integer_overflow");});
 T("claude_no_token_inference",delegate{A((bool)Probe.Claude("{\"seven_day\":{\"utilization\":42}}")["whole_account_token_history"]==false);});
 T("claude_missing_not_zero",delegate{Reject(delegate{Probe.Claude("{\"seven_day\":{}}");},"usage_missing");});
 T("grok_missing_history_not_empty",delegate{A(Probe.Grok("{\"config\":{}}")["history_records"]==null);});
 T("grok_proto_zero_cent",delegate{A((long)Probe.Grok("{\"config\":{\"prepaidBalance\":{}}}")["prepaid_usd_cents"]==0);});
 T("grok_amount_units",delegate{var r=Probe.Grok("{\"config\":{\"history\":[{\"totalUsed\":{\"val\":123}}]}}");A((int)r["history_amount_fields"]==1&&(string)r["unit"]=="credit_or_usd_cents_not_tokens");});
 T("percent_string_rejected",delegate{Reject(delegate{Probe.Claude("{\"seven_day\":{\"utilization\":\"42\"}}");},"invalid_percent");});
 T("destination_allowlist",delegate{A(Probe.Fetch("https://example.com/",null,200,false).Error=="destination_blocked");});
 T("downgrade_rejected",delegate{A(Probe.Fetch("http://chatgpt.com/backend-api/wham/profiles/me",null,200,false).Error=="destination_blocked");});
 T("production_loopback_rejected",delegate{A(Probe.Fetch("http://127.0.0.1:1/",null,200,false).Error=="destination_blocked");});
 T("http_success",delegate{var r=Http("200 OK","Content-Type: application/json\r\nContent-Length: 2\r\n",Encoding.UTF8.GetBytes("{}"),1000,false);A(r.Body=="{}"&&r.Bytes==2);});
 T("redirect_rejected",delegate{A(Http("302 Found","Location: https://example.com/\r\nContent-Length: 0\r\n",new byte[0],1000,false).Error=="redirect_rejected");});
 T("auth_failure_no_retry",delegate{A(Http("401 Unauthorized","Content-Length: 0\r\n",new byte[0],1000,false).Error=="login_rejected");});
 T("rate_limit_no_retry",delegate{A(Http("429 Too Many Requests","Content-Length: 0\r\n",new byte[0],1000,false).Error=="rate_limited");});
 T("html_rejected",delegate{A(Http("200 OK","Content-Type: text/html\r\nContent-Length: 2\r\n",Encoding.UTF8.GetBytes("{}"),1000,false).Error=="unexpected_content_type");});
 T("oversize_header_rejected",delegate{A(Http("200 OK","Content-Type: application/json\r\nContent-Length: 999999\r\n",new byte[0],1000,false).Error=="response_too_large");});
 T("oversize_stream_rejected",delegate{A(Http("200 OK","Content-Type: application/json\r\n",new byte[Probe.Cap+1],2000,false).Error=="response_too_large");});
 T("slow_stream_total_deadline",delegate{var w=Stopwatch.StartNew();var r=Http("200 OK","Content-Type: application/json\r\nContent-Length: 20\r\n",new byte[20],200,true);A(r.Error=="deadline_exceeded"&&w.ElapsedMilliseconds<1400);});
 var sw=Stopwatch.StartNew();var p=Process.GetCurrentProcess();var cpu=p.TotalProcessorTime;for(int i=0;i<10000;i++)Probe.Codex("{\"stats\":{\"lifetime_tokens\":9007199254740993,\"daily_usage_buckets\":[{\"start_date\":\"2026-10-29\",\"tokens\":123}]}}");p.Refresh();Probe.Emit(new{benchmark_iterations=10000,elapsed_ms=sw.ElapsedMilliseconds,cpu_ms=(p.TotalProcessorTime-cpu).TotalMilliseconds,peak_working_set_bytes=p.PeakWorkingSet64});Probe.Emit(new{passed=pass,failed=fail});Environment.ExitCode=fail==0?0:1;
 }}
