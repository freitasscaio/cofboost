// CofBoost.exe: abre o CofBoost.ps1 sem a janela preta do PowerShell.
// É um app de janela (winexe), então não cria console; o PowerShell é iniciado com
// CreateNoWindow. Pede administrador (UAC) se precisar, antes de abrir o PowerShell,
// para que o script não tenha que se reabrir.
//
// Uso:  CofBoost.exe              abre o app (pede administrador)
//       CofBoost.exe --simulate   modo simulação (não pede administrador)
//       CofBoost.exe --undo-all   reverte tudo e sai; código de saída 0 = ok
//
// Compilado pelo build.ps1 com o csc.exe do .NET Framework que vem no Windows.

using System;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Security.Principal;

[assembly: AssemblyTitle("CofBoost")]
[assembly: AssemblyProduct("CofBoost")]
[assembly: AssemblyDescription("Otimizador de Windows para jogos")]
[assembly: AssemblyCompany("CofBoost contributors")]
[assembly: AssemblyCopyright("MIT License")]

static class Launcher
{
    const int ErrorCancelled = 1223; // usuário recusou o UAC

    [STAThread]
    static int Main(string[] args)
    {
        bool simulate = Array.IndexOf(args, "--simulate") >= 0;
        bool undoAll = Array.IndexOf(args, "--undo-all") >= 0;
        string exe = Assembly.GetExecutingAssembly().Location;
        string dir = Path.GetDirectoryName(exe);

        if (!simulate && !IsAdmin())
        {
            var elevate = new ProcessStartInfo(exe, string.Join(" ", args))
            {
                UseShellExecute = true,
                Verb = "runas",
                WorkingDirectory = dir
            };
            try
            {
                Process p = Process.Start(elevate);
                if (undoAll) { p.WaitForExit(); return p.ExitCode; }
                return 0;
            }
            catch (Win32Exception) { return ErrorCancelled; }
        }

        string script = Path.Combine(dir, "CofBoost.ps1");
        string psArgs = "-NoProfile -ExecutionPolicy Bypass -STA -File \"" + script + "\"";
        if (simulate) psArgs += " -DryRun";
        if (undoAll) psArgs += " -UndoAll";

        var ps = new ProcessStartInfo(
            Path.Combine(Environment.SystemDirectory, @"WindowsPowerShell\v1.0\powershell.exe"), psArgs)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            WorkingDirectory = dir
        };
        Process proc = Process.Start(ps);
        if (undoAll) { proc.WaitForExit(); return proc.ExitCode; }
        return 0;
    }

    static bool IsAdmin()
    {
        return new WindowsPrincipal(WindowsIdentity.GetCurrent()).IsInRole(WindowsBuiltInRole.Administrator);
    }
}
