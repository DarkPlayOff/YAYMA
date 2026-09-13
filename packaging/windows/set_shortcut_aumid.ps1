# Sets the System.AppUserModel.ID property on a .lnk shortcut.
# Windows resolves the app name shown in the media flyout (SMTC) through this
# property, so it must match the AUMID set by the app (SetCurrentProcessExplicitAppUserModelID).
# Run by yayma.iss right after the shortcuts are created.
param(
    [Parameter(Mandatory = $true)][string]$ShortcutPath,
    [Parameter(Mandatory = $true)][string]$Aumid
)

$code = @"
using System;
using System.Runtime.InteropServices;

public static class ShortcutAumid
{
    [StructLayout(LayoutKind.Sequential)]
    public struct PROPERTYKEY { public Guid fmtid; public uint pid; }

    [StructLayout(LayoutKind.Explicit)]
    public struct PropVariant
    {
        [FieldOffset(0)] public ushort vt;
        [FieldOffset(8)] public IntPtr pwszVal;
    }

    [DllImport("ole32.dll")]
    private static extern int PropVariantClear(ref PropVariant pvar);

    [ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IPropertyStore
    {
        void GetCount(out uint cProps);
        void GetAt(uint prop, out PROPERTYKEY key);
        void GetValue(ref PROPERTYKEY key, out PropVariant value);
        void SetValue(ref PROPERTYKEY key, ref PropVariant value);
        void Commit();
    }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = false)]
    private static extern void SHGetPropertyStoreFromParsingName(
        string pszPath, IntPtr pbc, uint grfMode, ref Guid riid,
        [MarshalAs(UnmanagedType.Interface)] out IPropertyStore ppv);

    public static void Set(string lnkPath, string aumid)
    {
        var iid = new Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99");
        IPropertyStore store;
        SHGetPropertyStoreFromParsingName(lnkPath, IntPtr.Zero, 0x2 /* GPS_READWRITE */, ref iid, out store);
        var pv = new PropVariant { vt = 31 /* VT_LPWSTR */ };
        pv.pwszVal = Marshal.StringToCoTaskMemUni(aumid);
        try
        {
            var key = new PROPERTYKEY
            {
                fmtid = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3"),
                pid = 5
            };
            store.SetValue(ref key, ref pv);
            store.Commit();
        }
        finally
        {
            PropVariantClear(ref pv);
        }
    }
}
"@

Add-Type -TypeDefinition $code -Language CSharp

foreach ($path in $ShortcutPath.Split(';')) {
    if (Test-Path -LiteralPath $path) {
        [ShortcutAumid]::Set($path, $Aumid)
        Write-Output "Set AUMID '$Aumid' on $path"
    }
}
