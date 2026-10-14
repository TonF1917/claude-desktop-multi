' Windowless shim: run.vbs <instance-id>  ->  claude-multi.ps1 launch -Id <instance-id>
Set fso = CreateObject("Scripting.FileSystemObject")
d = fso.GetParentFolderName(WScript.ScriptFullName)
If WScript.Arguments.Count < 1 Then WScript.Quit 1
CreateObject("WScript.Shell").Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & d & "\claude-multi.ps1"" launch -Id """ & WScript.Arguments(0) & """", 0, False
