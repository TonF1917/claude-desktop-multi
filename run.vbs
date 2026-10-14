' Windowless shim.  run.vbs <instance-id> | --url <claude://...> | --gui
Set fso = CreateObject("Scripting.FileSystemObject")
d = fso.GetParentFolderName(WScript.ScriptFullName)
If WScript.Arguments.Count < 1 Then WScript.Quit 1
a = WScript.Arguments(0)
base = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden "
If a = "--url" And WScript.Arguments.Count > 1 Then
  cmd = base & "-File """ & d & "\claude-multi.ps1"" route -Url """ & Replace(WScript.Arguments(1), """", "") & """"
ElseIf a = "--restart" And WScript.Arguments.Count > 1 Then
  cmd = base & "-File """ & d & "\claude-multi.ps1"" restart -Url """ & Replace(WScript.Arguments(1), """", "") & """"
ElseIf a = "--gui" Then
  cmd = base & "-STA -File """ & d & "\claude-multi.ps1"" gui"
Else
  cmd = base & "-File """ & d & "\claude-multi.ps1"" launch -Id """ & Replace(a, """", "") & """"
End If
CreateObject("WScript.Shell").Run cmd, 0, False
