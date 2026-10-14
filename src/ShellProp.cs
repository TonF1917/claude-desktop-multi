using System;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;

public static class ShellProp {
  [StructLayout(LayoutKind.Sequential, Pack = 4)]
  public struct PROPERTYKEY { public Guid fmtid; public uint pid; }
  [StructLayout(LayoutKind.Explicit)]
  public struct PROPVARIANT { [FieldOffset(0)] public ushort vt; [FieldOffset(8)] public IntPtr p; [FieldOffset(16)] public IntPtr p2; }
  [ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  public interface IPropertyStore {
    [PreserveSig] int GetCount(out uint c);
    [PreserveSig] int GetAt(uint i, out PROPERTYKEY k);
    [PreserveSig] int GetValue(ref PROPERTYKEY k, out PROPVARIANT v);
    [PreserveSig] int SetValue(ref PROPERTYKEY k, ref PROPVARIANT v);
    [PreserveSig] int Commit();
  }
  [DllImport("shell32.dll")] static extern int SHGetPropertyStoreForWindow(IntPtr hwnd, ref Guid riid, out IPropertyStore ps);
  [DllImport("propsys.dll", CharSet = CharSet.Unicode)] static extern int PropVariantToStringAlloc(ref PROPVARIANT pv, out IntPtr s);
  [DllImport("ole32.dll")] static extern int PropVariantClear(ref PROPVARIANT pv);
  [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr h, int msg, IntPtr w, IntPtr l);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr LoadImage(IntPtr hi, string f, uint t, int cx, int cy, uint fl);

  static readonly Guid FMT = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3");
  static PROPERTYKEY K(uint pid) { var k = new PROPERTYKEY(); k.fmtid = FMT; k.pid = pid; return k; }

  static void Put(IPropertyStore ps, uint pid, string val) {
    var k = K(pid); PROPVARIANT v;
    v = new PROPVARIANT(); v.vt = 31; v.p = Marshal.StringToCoTaskMemUni(val);
    Marshal.ThrowExceptionForHR(ps.SetValue(ref k, ref v));
    PropVariantClear(ref v);
  }
  static string Get(IPropertyStore ps, uint pid) {
    var k = K(pid); PROPVARIANT v;
    if (ps.GetValue(ref k, out v) != 0 || v.vt == 0) return null;
    IntPtr s; PropVariantToStringAlloc(ref v, out s);
    string r = Marshal.PtrToStringUni(s); Marshal.FreeCoTaskMem(s); PropVariantClear(ref v);
    return r;
  }

  // Window-level taskbar identity (overrides the process-level AUMID Electron sets).
  public static string SetWindowIdentity(IntPtr hwnd, string aumid, string relaunchCmd, string iconRes, string name) {
    Guid iid = new Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99");
    IPropertyStore ps;
    Marshal.ThrowExceptionForHR(SHGetPropertyStoreForWindow(hwnd, ref iid, out ps));
    Put(ps, 5, aumid);
    Put(ps, 2, relaunchCmd);
    Put(ps, 3, iconRes);
    Put(ps, 4, name);
    return Get(ps, 5);
  }
  public static string GetWindowAumid(IntPtr hwnd) {
    Guid iid = new Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99");
    IPropertyStore ps;
    if (SHGetPropertyStoreForWindow(hwnd, ref iid, out ps) != 0) return null;
    return Get(ps, 5);
  }
  public static void SetWindowIcon(IntPtr hwnd, string ico) {
    IntPtr big = LoadImage(IntPtr.Zero, ico, 1, 32, 32, 0x10);
    IntPtr small = LoadImage(IntPtr.Zero, ico, 1, 16, 16, 0x10);
    SendMessage(hwnd, 0x80, (IntPtr)1, big);
    SendMessage(hwnd, 0x80, (IntPtr)0, small);
  }

  // Stamp an AUMID onto a .lnk (IPropertyStore on the ShellLink object).
  public static void SetLinkAumid(string lnk, string aumid) {
    var t = Type.GetTypeFromCLSID(new Guid("00021401-0000-0000-C000-000000000046"));
    object o = Activator.CreateInstance(t);
    var pf = (IPersistFile)o;
    pf.Load(lnk, 2);
    var ps = (IPropertyStore)o;
    Put(ps, 5, aumid);
    Marshal.ThrowExceptionForHR(ps.Commit());
    pf.Save(lnk, true);
  }
  public static string GetLinkAumid(string lnk) {
    var t = Type.GetTypeFromCLSID(new Guid("00021401-0000-0000-C000-000000000046"));
    object o = Activator.CreateInstance(t);
    ((IPersistFile)o).Load(lnk, 0);
    return Get((IPropertyStore)o, 5);
  }
}
