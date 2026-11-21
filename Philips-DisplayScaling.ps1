# Philips-DisplayScaling.ps1
# Native Windows DDC/CI via dxva2.dll
# Philips 439P9H: VCP 0x86, 4 = 16:9, 8 = Wide
#
# Default action is Inspect (read-only).
# To change the Philips monitor: .\Philips-DisplayScaling.ps1 -Action Set16x9
#
# The script only writes when Windows can associate exactly one physical
# monitor handle with exactly one PnP monitor device whose ID contains PHL0939.

[CmdletBinding()]
param(
    [ValidateSet('Inspect', 'Toggle', 'Set16x9', 'SetWide')]
    [string]$Action = 'Inspect'
)

$ErrorActionPreference = 'Stop'

$TargetPnP = 'PHL0939'
$VcpCode   = [byte]0x86

if (-not ('PhilipsDdcNativeV2' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public static class PhilipsDdcNativeV2
{
    private const uint EDD_GET_DEVICE_INTERFACE_NAME = 0x00000001;

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT
    {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct MONITORINFOEX
    {
        public int cbSize;
        public RECT rcMonitor;
        public RECT rcWork;
        public uint dwFlags;

        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
        public string szDevice;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct DISPLAY_DEVICE
    {
        public int cb;

        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
        public string DeviceName;

        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)]
        public string DeviceString;

        public uint StateFlags;

        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)]
        public string DeviceID;

        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)]
        public string DeviceKey;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct PHYSICAL_MONITOR
    {
        public IntPtr hPhysicalMonitor;

        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)]
        public string szPhysicalMonitorDescription;
    }

    public class Entry
    {
        public IntPtr Handle;
        public string GdiDisplay;
        public string PnpDeviceId;
        public string DeviceString;
        public string PhysicalDescription;
        public bool AssociationVerified;
        public string AssociationNote;
    }

    private enum MC_VCP_CODE_TYPE : uint
    {
        MC_MOMENTARY = 0,
        MC_SET_PARAMETER = 1
    }

    private delegate bool MonitorEnumProc(
        IntPtr hMonitor,
        IntPtr hdcMonitor,
        ref RECT rect,
        IntPtr data
    );

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool EnumDisplayMonitors(
        IntPtr hdc,
        IntPtr clip,
        MonitorEnumProc callback,
        IntPtr data
    );

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool GetMonitorInfoW(
        IntPtr hMonitor,
        ref MONITORINFOEX info
    );

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool EnumDisplayDevicesW(
        string device,
        uint index,
        ref DISPLAY_DEVICE displayDevice,
        uint flags
    );

    [DllImport("dxva2.dll", SetLastError = true)]
    private static extern bool GetNumberOfPhysicalMonitorsFromHMONITOR(
        IntPtr hMonitor,
        out uint count
    );

    [DllImport("dxva2.dll", SetLastError = true)]
    private static extern bool GetPhysicalMonitorsFromHMONITOR(
        IntPtr hMonitor,
        uint count,
        [Out] PHYSICAL_MONITOR[] physicalMonitors
    );

    [DllImport("dxva2.dll", SetLastError = true)]
    private static extern bool GetVCPFeatureAndVCPFeatureReply(
        IntPtr hMonitor,
        byte code,
        out MC_VCP_CODE_TYPE type,
        out uint currentValue,
        out uint maximumValue
    );

    [DllImport("dxva2.dll", SetLastError = true)]
    private static extern bool SetVCPFeature(
        IntPtr hMonitor,
        byte code,
        uint newValue
    );

    [DllImport("dxva2.dll", SetLastError = true)]
    private static extern bool DestroyPhysicalMonitor(IntPtr hMonitor);

    public static int LastError;

    private static List<string> GetMonitorPnpIds(string gdiDisplay)
    {
        List<string> ids = new List<string>();

        for (uint i = 0; ; i++)
        {
            DISPLAY_DEVICE dd = new DISPLAY_DEVICE();
            dd.cb = Marshal.SizeOf(typeof(DISPLAY_DEVICE));

            if (!EnumDisplayDevicesW(
                gdiDisplay, i, ref dd, EDD_GET_DEVICE_INTERFACE_NAME))
                break;

            string id = dd.DeviceID ?? "";
            if (!String.IsNullOrWhiteSpace(id))
                ids.Add(id);
        }

        // Fallback: some drivers return no interface name with the flag.
        if (ids.Count == 0)
        {
            for (uint i = 0; ; i++)
            {
                DISPLAY_DEVICE dd = new DISPLAY_DEVICE();
                dd.cb = Marshal.SizeOf(typeof(DISPLAY_DEVICE));

                if (!EnumDisplayDevicesW(gdiDisplay, i, ref dd, 0))
                    break;

                string id = dd.DeviceID ?? "";
                if (!String.IsNullOrWhiteSpace(id))
                    ids.Add(id);
            }
        }

        return ids;
    }

    public static Entry[] Enumerate()
    {
        List<Entry> result = new List<Entry>();
        List<IntPtr> acquiredHandles = new List<IntPtr>();

        MonitorEnumProc callback = delegate(
            IntPtr hMonitor,
            IntPtr hdc,
            ref RECT rect,
            IntPtr data)
        {
            MONITORINFOEX info = new MONITORINFOEX();
            info.cbSize = Marshal.SizeOf(typeof(MONITORINFOEX));

            if (!GetMonitorInfoW(hMonitor, ref info))
                return true;

            List<string> pnpIds = GetMonitorPnpIds(info.szDevice);

            uint count;
            if (!GetNumberOfPhysicalMonitorsFromHMONITOR(hMonitor, out count))
                return true;

            if (count == 0)
                return true;

            PHYSICAL_MONITOR[] physical = new PHYSICAL_MONITOR[count];

            if (!GetPhysicalMonitorsFromHMONITOR(hMonitor, count, physical))
                return true;

            bool oneToOne = (count == 1 && pnpIds.Count == 1);

            for (int i = 0; i < physical.Length; i++)
            {
                IntPtr handle = physical[i].hPhysicalMonitor;
                acquiredHandles.Add(handle);

                Entry e = new Entry();
                e.Handle = handle;
                e.GdiDisplay = info.szDevice;
                e.PhysicalDescription =
                    physical[i].szPhysicalMonitorDescription ?? "";
                e.AssociationVerified = oneToOne;

                if (oneToOne)
                {
                    e.PnpDeviceId = pnpIds[0];
                    e.AssociationNote = "1 GDI monitor device ↔ 1 physical DDC/CI handle";
                }
                else
                {
                    e.PnpDeviceId = String.Join(" || ", pnpIds.ToArray());
                    e.AssociationNote =
                        "Ambiguous: child PnP device count=" + pnpIds.Count +
                        ", physical handle count=" + count;
                }

                e.DeviceString = "";
                result.Add(e);
            }

            return true;
        };

        if (!EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, callback, IntPtr.Zero))
        {
            LastError = Marshal.GetLastWin32Error();
            foreach (IntPtr h in acquiredHandles)
                if (h != IntPtr.Zero) DestroyPhysicalMonitor(h);
            throw new Exception("EnumDisplayMonitors failed. Win32=" + LastError);
        }

        return result.ToArray();
    }

    public static bool ReadVcp(
        IntPtr handle, byte code,
        out uint current, out uint maximum, out uint codeType)
    {
        MC_VCP_CODE_TYPE type;
        bool ok = GetVCPFeatureAndVCPFeatureReply(
            handle, code, out type, out current, out maximum);

        codeType = (uint)type;
        LastError = ok ? 0 : Marshal.GetLastWin32Error();
        return ok;
    }

    public static bool WriteVcp(IntPtr handle, byte code, uint value)
    {
        bool ok = SetVCPFeature(handle, code, value);
        LastError = ok ? 0 : Marshal.GetLastWin32Error();
        return ok;
    }

    public static void Release(IntPtr handle)
    {
        if (handle != IntPtr.Zero)
            DestroyPhysicalMonitor(handle);
    }
}
'@
}


$entries = @()
$verifyEntries = @()

function Get-PhilipsEntry {
    param([object[]]$Items)

    $found = @(
        $Items | Where-Object {
            $_.AssociationVerified -and
            $_.PnpDeviceId -match [regex]::Escape($TargetPnP)
        }
    )

    if ($found.Count -ne 1) {
        throw "Expected exactly one verified PHL0939 mapping; found $($found.Count). No write performed."
    }

    return $found[0]
}

function Release-PhysicalEntries {
    param([object[]]$Items)

    foreach ($item in $Items) {
        if ($null -ne $item -and $item.Handle -ne [IntPtr]::Zero) {
            [PhilipsDdcNativeV2]::Release($item.Handle)
        }
    }
}

try {
    $entries = @([PhilipsDdcNativeV2]::Enumerate())

    if ($entries.Count -eq 0) {
        throw 'Windows returned no physical DDC/CI monitor handles.'
    }

    Write-Host "`n=== WINDOWS / DDC-CI MONITOR INVENTORY ===" -ForegroundColor Cyan

    foreach ($e in $entries) {
        Write-Host "`nGDI display       : $($e.GdiDisplay)"
        Write-Host "Physical name     : $($e.PhysicalDescription)"
        Write-Host "PnP device ID     : $($e.PnpDeviceId)"
        Write-Host "Association       : $($e.AssociationNote)"
        Write-Host "Association valid : $($e.AssociationVerified)"
    }

    $target = Get-PhilipsEntry -Items $entries

    [uint32]$current = 0
    [uint32]$maximum = 0
    [uint32]$codeType = 0

    $ok = [PhilipsDdcNativeV2]::ReadVcp(
        $target.Handle, $VcpCode,
        [ref]$current, [ref]$maximum, [ref]$codeType
    )

    if (-not $ok) {
        throw "Reading VCP 0x86 failed. Win32 error: $([PhilipsDdcNativeV2]::LastError)"
    }

    Write-Host "`n=== PHILIPS 439P9H VCP 0x86 ===" -ForegroundColor Cyan
    Write-Host "Current value : $current"
    Write-Host "Code type     : $codeType"
    Write-Host "Maximum       : $maximum"

    if ($Action -eq 'Inspect') {
        $mode = switch ($current) {
            4 { '16:9' }
            8 { 'Wide' }
            default { "Unknown/other ($current)" }
        }
        Write-Host "Current mode  : $mode"
        Write-Host "`nRead-only inspection. Nothing changed." -ForegroundColor Green
        return
    }

    switch ($Action) {
        'Toggle' {
            if ($current -eq 4) {
                [uint32]$desired = 8
                $description = 'Wide'
            }
            elseif ($current -eq 8) {
                [uint32]$desired = 4
                $description = '16:9'
            }
            else {
                throw "Current VCP value $current is neither 4 (16:9) nor 8 (Wide). Toggle stopped without writing."
            }
        }
        'Set16x9' {
            [uint32]$desired = 4
            $description = '16:9'
        }
        'SetWide' {
            [uint32]$desired = 8
            $description = 'Wide'
        }
    }

    if ($current -eq $desired) {
        Write-Host "`nAlready in $description mode (value $desired). No write needed." -ForegroundColor Green
        return
    }

    Write-Host "`nSwitching Philips Display Scaling: $current -> $desired ($description)..." -ForegroundColor Yellow

    $ok = [PhilipsDdcNativeV2]::WriteVcp(
        $target.Handle, $VcpCode, $desired
    )

    if (-not $ok) {
        throw "SetVCPFeature failed. Win32 error: $([PhilipsDdcNativeV2]::LastError)"
    }

    # Some monitors invalidate the current DDC/CI handle after changing
    # display scaling. Release it and reacquire a fresh physical handle.
    Write-Host "Windows accepted SetVCPFeature. Reacquiring monitor for verification..."
    Release-PhysicalEntries -Items $entries
    $entries = @()

    Start-Sleep -Milliseconds 900

    try {
        $verifyEntries = @([PhilipsDdcNativeV2]::Enumerate())
        $verifyTarget = Get-PhilipsEntry -Items $verifyEntries

        [uint32]$readBack = 0
        [uint32]$readBackMax = 0
        [uint32]$readBackType = 0

        $readOk = [PhilipsDdcNativeV2]::ReadVcp(
            $verifyTarget.Handle, $VcpCode,
            [ref]$readBack, [ref]$readBackMax, [ref]$readBackType
        )

        if ($readOk) {
            Write-Host "`n=== VERIFICATION ===" -ForegroundColor Cyan
            Write-Host "Requested : $desired ($description)"
            Write-Host "Read back : $readBack"

            if ($readBack -eq $desired) {
                Write-Host "CONFIRMED: Philips reports the requested mode." -ForegroundColor Green
            }
            else {
                Write-Warning "Write was accepted, but monitor reports $readBack instead of $desired."
            }
        }
        else {
            Write-Warning ("Write was accepted by Windows, but DDC/CI readback is temporarily unavailable. " +
                "Win32 error: $([PhilipsDdcNativeV2]::LastError). Check the monitor's picture; " +
                "the next Toggle will read the actual current value before switching.")
        }
    }
    catch {
        Write-Warning ("Write was accepted by Windows. Post-write verification could not complete: " +
            $_.Exception.Message)
    }
}
finally {
    Release-PhysicalEntries -Items $entries
    Release-PhysicalEntries -Items $verifyEntries
}
