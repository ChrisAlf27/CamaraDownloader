// Lanzador de Cámara Downloader: abre el script de PowerShell sin mostrar la ventana de consola.
using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Windows.Forms;

[assembly: AssemblyTitle("Cámara Downloader")]
[assembly: AssemblyProduct("Cámara Downloader")]

static class Launcher
{
    [STAThread]
    static void Main()
    {
        string dir = AppDomain.CurrentDomain.BaseDirectory;
        string script = Path.Combine(dir, "CamaraDownloader.ps1");
        if (!File.Exists(script))
        {
            MessageBox.Show("No se encontró " + script + "\nReinstalá la aplicación.", "Cámara Downloader",
                MessageBoxButtons.OK, MessageBoxIcon.Error);
            return;
        }
        string ps = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System),
            @"WindowsPowerShell\v1.0\powershell.exe");
        var psi = new ProcessStartInfo(ps,
            "-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + script + "\"");
        psi.UseShellExecute = false;
        psi.CreateNoWindow = true;
        psi.WorkingDirectory = dir;
        Process.Start(psi);
    }
}
