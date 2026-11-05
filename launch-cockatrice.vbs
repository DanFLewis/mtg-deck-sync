' Launch Cockatrice, syncing Moxfield decks first.
'
' The sync runs hidden and non-blocking, so Cockatrice opens immediately
' rather than waiting on the network. Cockatrice itself is started through
' cockatrice_aumid.lnk -- a helper shortcut stamped with the same
' AppUserModelID as the pinned Cockatrice.lnk. Going through that shortcut
' makes the Cockatrice window adopt the AUMID, so it groups under the single
' pinned taskbar button instead of appearing as a second, separate icon.

Option Explicit

Dim fso, shell, app, base, helper

Set fso = CreateObject("Scripting.FileSystemObject")
Set shell = CreateObject("WScript.Shell")
Set app = CreateObject("Shell.Application")

base = fso.GetParentFolderName(WScript.ScriptFullName)
helper = base & "\cockatrice_aumid.lnk"

' (a) Deck sync: hidden window (0), do not wait (False).
shell.Run """" & base & "\run-sync-background.cmd""", 0, False

' (b) Cockatrice, via the AUMID-stamped helper shortcut. ShellExecute is used
'     rather than Run so the launch goes through the shell and the shortcut's
'     AppUserModelID propagates to the new process.
If fso.FileExists(helper) Then
    app.ShellExecute helper, "", "", "open", 1
Else
    ' Helper missing: still start Cockatrice, just without taskbar grouping.
    Dim candidates, candidate, exePath
    candidates = Array( _
        shell.ExpandEnvironmentStrings("%ProgramFiles%") & "\Cockatrice\cockatrice.exe", _
        shell.ExpandEnvironmentStrings("%ProgramFiles(x86)%") & "\Cockatrice\cockatrice.exe", _
        shell.ExpandEnvironmentStrings("%LOCALAPPDATA%") & "\Programs\Cockatrice\cockatrice.exe")

    exePath = ""
    For Each candidate In candidates
        If exePath = "" And fso.FileExists(candidate) Then exePath = candidate
    Next

    If exePath <> "" Then
        app.ShellExecute exePath, "", fso.GetParentFolderName(exePath), "open", 1
    End If
End If
