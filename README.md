# DisplayScaler

A small PowerShell utility for changing the display-scaling mode on a Philips 439P9H monitor from Windows. It talks to the monitor through Windows' built-in DDC/CI APIs, so you can run it directly from PowerShell or bind a command to a Stream Deck button or another launcher.

This is an optional convenience for switching between **16:9** (useful for a PS5 output) and **Wide**. You do not need a Stream Deck, Philips SmartControl software, or a separate script dependency.

> **Compatibility:** The script currently targets the Philips 439P9H, identified by the PnP ID `PHL0939`, and its VCP feature `0x86`. It is not a general-purpose scaler for arbitrary monitor models.

## Requirements

- Windows with Windows PowerShell available.
- A Philips 439P9H connected in a way that exposes its DDC/CI controls to Windows.
- DDC/CI enabled in the monitor's on-screen menu.

No third-party PowerShell modules are required. The script uses Windows APIs and compiles a small interop helper at runtime.

## Quick start

Open PowerShell in the folder containing `Philips-DisplayScaling.ps1` and inspect the detected monitors and current scaling mode:

```powershell
.\Philips-DisplayScaling.ps1
```

Inspection is the default action and is read-only. To switch modes, run one of:

```powershell
.\Philips-DisplayScaling.ps1 -Action Toggle
.\Philips-DisplayScaling.ps1 -Action Set16x9
.\Philips-DisplayScaling.ps1 -Action SetWide
```

`Toggle` switches between 16:9 and Wide based on the mode the monitor currently reports. If it reports another value, the script stops without changing it. The set actions select a specific mode and do nothing if the monitor is already in that mode.

### Run from any folder

Pass the full script path to Windows PowerShell:

```powershell
& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -File "C:\path\to\DisplayScaler\Philips-DisplayScaling.ps1" -Action Toggle
```

Replace `C:\path\to\DisplayScaler` with the folder where you saved the script. You can use the same command in a shortcut, launcher, or scheduled workflow.

### Optional: Stream Deck

Create a System: Open action (or the equivalent command-launching action) with Windows PowerShell as the application:

```text
C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe
```

Use these arguments, changing the script path as needed:

```text
-NoProfile -File "C:\path\to\DisplayScaler\Philips-DisplayScaling.ps1" -Action Toggle
```

The Stream Deck is just one way to launch the command; it is not required.

## Actions

| Action | Behavior |
| --- | --- |
| `Inspect` | Lists Windows/DDC-CI monitor information and reports the current mode without writing to the monitor. This is the default. |
| `Toggle` | Switches between 16:9 and Wide. |
| `Set16x9` | Selects 16:9. |
| `SetWide` | Selects Wide. |

For this monitor, the script maps VCP `0x86` value `4` to **16:9** and value `8` to **Wide**.

## Safety and troubleshooting

- Before changing anything, run the default `Inspect` action and confirm that the Philips monitor is detected.
- The script only writes when Windows can associate exactly one physical DDC/CI monitor handle with exactly one PnP monitor device whose ID contains `PHL0939`. If the association is missing or ambiguous, it stops without writing.
- If no physical DDC/CI handles are found or reading VCP `0x86` fails, check the monitor connection, enable DDC/CI in the monitor menu, and try again.
- If the monitor is not identified as `PHL0939`, this script will not target it. Other models may use different IDs or scaling controls and are not currently supported.
- After a mode change, the script reacquires the monitor and attempts to verify the reported value. It may warn if the monitor temporarily does not provide a read-back.

## How it works

The script enumerates Windows display monitors, verifies the Philips monitor's PnP identity and one-to-one association, then reads or writes the monitor's DDC/CI VCP `0x86` feature using `dxva2.dll`. It does not use Philips SmartControl.
