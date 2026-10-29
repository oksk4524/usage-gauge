using System;
using System.IO;
using System.Text;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
namespace LocalUsageValidation {
 public static class FileSafety {
  [StructLayout(LayoutKind.Sequential)]struct BasicInfo{public long created,accessed,written,changed;public uint attributes;}
  [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)]static extern uint GetFinalPathNameByHandle(SafeFileHandle file,StringBuilder path,uint size,uint flags);
  [DllImport("kernel32.dll",SetLastError=true)]static extern bool GetFileInformationByHandleEx(SafeFileHandle file,int infoClass,out BasicInfo info,uint size);
  public static long Validate(FileStream stream,string root){var name=new StringBuilder(32768);uint len=GetFinalPathNameByHandle(stream.SafeFileHandle,name,(uint)name.Capacity,0);if(len==0||len>=name.Capacity)throw new IOException("cannot_verify_file_location");string allowed=Collector.NormalizeRoot(root).TrimEnd(Path.DirectorySeparatorChar)+Path.DirectorySeparatorChar;if(!name.ToString().StartsWith(allowed,StringComparison.OrdinalIgnoreCase))throw new IOException("file_outside_selected_root");BasicInfo info;if(!GetFileInformationByHandleEx(stream.SafeFileHandle,0,out info,(uint)Marshal.SizeOf(typeof(BasicInfo))))return 0;return info.changed;}
  public static long Stamp(string path,string root){using(var stream=new FileStream(path,FileMode.Open,FileAccess.Read,FileShare.ReadWrite|FileShare.Delete))return Validate(stream,root);}
 }
}
