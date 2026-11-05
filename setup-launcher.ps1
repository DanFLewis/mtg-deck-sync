# Build the Cockatrice launcher shortcuts for the Moxfield deck sync.
#
# Creates two .lnk files, both stamped with the same AppUserModelID:
#
#   cockatrice_aumid.lnk  -> cockatrice.exe        (helper, launched by the VBS)
#   Cockatrice.lnk        -> wscript.exe <the VBS> (the one you pin)
#
# Matching AUMIDs are what make the running Cockatrice window group under the
# single pinned taskbar button instead of showing a second icon.
#
# Setting an AUMID on a shortcut is not exposed by WScript.Shell -- it needs
# the shell's IPropertyStore, so the interop below is declared by hand.
#
# This script only writes files. It does NOT pin anything: taskbar pinning is
# done by hand through right-click -> Pin to taskbar. Never edit the Taskband
# registry keys or hand-edit an already-pinned .lnk.
#
# Safe to re-run; it overwrites the two shortcuts in place.

$ErrorActionPreference = 'Stop'

$Base  = Split-Path -Parent $MyInvocation.MyCommand.Path
$AumId = 'Architrice.Cockatrice'

# Locate Cockatrice rather than assuming Program Files. Override with
# COCKATRICE_EXE if it lives somewhere else.
$CockatriceExe = $env:COCKATRICE_EXE
if (-not ($CockatriceExe -and (Test-Path -LiteralPath $CockatriceExe))) {
    $CockatriceExe = @(
        (Join-Path $env:ProgramFiles 'Cockatrice\cockatrice.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Cockatrice\cockatrice.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Cockatrice\cockatrice.exe')
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
}
if (-not $CockatriceExe) {
    throw 'Could not find cockatrice.exe. Set COCKATRICE_EXE to its full path.'
}
$CockatriceDir = Split-Path -Parent $CockatriceExe
$Wscript       = Join-Path $env:SystemRoot 'System32\wscript.exe'
$Vbs           = Join-Path $Base 'launch-cockatrice.vbs'
$HelperLnk     = Join-Path $Base 'cockatrice_aumid.lnk'
$PinnableLnk   = Join-Path $Base 'Cockatrice.lnk'

foreach ($required in @($CockatriceExe, $Wscript, $Vbs)) {
    if (-not (Test-Path -LiteralPath $required)) {
        throw "Required file not found: $required"
    }
}

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;

namespace ShellLnk
{
    [StructLayout(LayoutKind.Sequential)]
    public struct PropertyKey
    {
        public Guid fmtid;
        public uint pid;
        public PropertyKey(Guid f, uint p) { fmtid = f; pid = p; }
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct PropVariant
    {
        public ushort vt;
        public ushort r1;
        public ushort r2;
        public ushort r3;
        public IntPtr p;
        public IntPtr p2;
    }

    [ComImport, Guid("000214F9-0000-0000-C000-000000000046"),
     InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IShellLinkW
    {
        int GetPath([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder f,
                    int cch, IntPtr pfd, uint flags);
        int GetIDList(out IntPtr ppidl);
        int SetIDList(IntPtr pidl);
        int GetDescription([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder n, int cch);
        int SetDescription([MarshalAs(UnmanagedType.LPWStr)] string n);
        int GetWorkingDirectory([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder d, int cch);
        int SetWorkingDirectory([MarshalAs(UnmanagedType.LPWStr)] string d);
        int GetArguments([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder a, int cch);
        int SetArguments([MarshalAs(UnmanagedType.LPWStr)] string a);
        int GetHotkey(out ushort w);
        int SetHotkey(ushort w);
        int GetShowCmd(out int c);
        int SetShowCmd(int c);
        int GetIconLocation([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder i,
                            int cch, out int index);
        int SetIconLocation([MarshalAs(UnmanagedType.LPWStr)] string i, int index);
        int SetRelativePath([MarshalAs(UnmanagedType.LPWStr)] string r, uint reserved);
        int Resolve(IntPtr hwnd, uint flags);
        int SetPath([MarshalAs(UnmanagedType.LPWStr)] string f);
    }

    [ComImport, Guid("0000010b-0000-0000-C000-000000000046"),
     InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IPersistFile
    {
        int GetClassID(out Guid clsid);
        int IsDirty();
        int Load([MarshalAs(UnmanagedType.LPWStr)] string f, uint mode);
        int Save([MarshalAs(UnmanagedType.LPWStr)] string f,
                 [MarshalAs(UnmanagedType.Bool)] bool remember);
        int SaveCompleted([MarshalAs(UnmanagedType.LPWStr)] string f);
        int GetCurFile([MarshalAs(UnmanagedType.LPWStr)] out string f);
    }

    [ComImport, Guid("886d8eeb-8cf2-4446-8d02-cdba1dbdcf99"),
     InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IPropertyStore
    {
        int GetCount(out uint c);
        int GetAt(uint i, out PropertyKey key);
        int GetValue(ref PropertyKey key, out PropVariant v);
        int SetValue(ref PropertyKey key, ref PropVariant v);
        int Commit();
    }

    [ComImport, Guid("00021401-0000-0000-C000-000000000046")]
    public class ShellLink { }

    public static class Lnk
    {
        // PKEY_AppUserModel_ID
        static readonly Guid Fmtid =
            new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3");
        const uint Pid = 5;
        const ushort VT_LPWSTR = 31;

        [DllImport("ole32.dll")]
        static extern int PropVariantClear(ref PropVariant pv);

        static void Check(int hr, string what)
        {
            if (hr != 0) Marshal.ThrowExceptionForHR(hr);
        }

        public static void Create(string lnkPath, string target, string args,
                                  string workDir, string iconPath, int iconIndex,
                                  string description, string appUserModelId)
        {
            var link = (IShellLinkW)new ShellLink();

            Check(link.SetPath(target), "SetPath");
            if (!string.IsNullOrEmpty(args))
                Check(link.SetArguments(args), "SetArguments");
            if (!string.IsNullOrEmpty(workDir))
                Check(link.SetWorkingDirectory(workDir), "SetWorkingDirectory");
            if (!string.IsNullOrEmpty(iconPath))
                Check(link.SetIconLocation(iconPath, iconIndex), "SetIconLocation");
            if (!string.IsNullOrEmpty(description))
                Check(link.SetDescription(description), "SetDescription");

            var store = (IPropertyStore)link;
            var key = new PropertyKey(Fmtid, Pid);
            var pv = new PropVariant();
            pv.vt = VT_LPWSTR;
            pv.p = Marshal.StringToCoTaskMemUni(appUserModelId);
            try
            {
                Check(store.SetValue(ref key, ref pv), "SetValue");
                Check(store.Commit(), "Commit");
            }
            finally
            {
                PropVariantClear(ref pv);
            }

            var file = (IPersistFile)link;
            Check(file.Save(lnkPath, true), "Save");

            Marshal.FinalReleaseComObject(link);
        }

        public static string ReadAppUserModelId(string lnkPath)
        {
            var link = (IShellLinkW)new ShellLink();
            var file = (IPersistFile)link;
            Check(file.Load(lnkPath, 0), "Load");

            var store = (IPropertyStore)link;
            var key = new PropertyKey(Fmtid, Pid);
            PropVariant pv;
            Check(store.GetValue(ref key, out pv), "GetValue");

            string value = (pv.vt == VT_LPWSTR && pv.p != IntPtr.Zero)
                ? Marshal.PtrToStringUni(pv.p)
                : null;

            PropVariantClear(ref pv);
            Marshal.FinalReleaseComObject(link);
            return value;
        }
    }
}
'@

# Helper shortcut: plain Cockatrice, carrying the AUMID. The VBS launches
# this so the Cockatrice window inherits the ID.
[ShellLnk.Lnk]::Create(
    $HelperLnk, $CockatriceExe, '', $CockatriceDir,
    $CockatriceExe, 0, 'Cockatrice (AUMID helper - launched by the deck sync)',
    $AumId)

# The pinnable shortcut: runs the VBS through wscript so no console window
# flashes, wears the Cockatrice icon, same AUMID.
[ShellLnk.Lnk]::Create(
    $PinnableLnk, $Wscript, ('"{0}"' -f $Vbs), $CockatriceDir,
    $CockatriceExe, 0, 'Cockatrice (syncs Moxfield decks first)',
    $AumId)

foreach ($lnk in @($HelperLnk, $PinnableLnk)) {
    $id = [ShellLnk.Lnk]::ReadAppUserModelId($lnk)
    '{0,-22} AUMID = {1}' -f (Split-Path -Leaf $lnk), $id
}
