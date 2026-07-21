using System.Diagnostics;
using System.Reflection;

namespace HealthRestorer;

internal static class Program
{
    private const string ProductFolder = "HealthRestorer";
    private const string PackageFolder = "Package";

    private static readonly IReadOnlyDictionary<string, string> EmbeddedFiles =
        new Dictionary<string, string>(StringComparer.Ordinal)
        {
            ["HealthRestorer.Embedded.HealthRestorer.ps1"] = "HealthRestorer.ps1",
            ["HealthRestorer.Embedded.SecureDeletedData.ps1"] = "SecureDeletedData.ps1",
            ["HealthRestorer.Embedded.ProgramResidueCleanup.ps1"] = "ProgramResidueCleanup.ps1",
            ["HealthRestorer.Embedded.Start-HealthRestorer.ps1"] = "Start-HealthRestorer.ps1",
            ["HealthRestorer.Embedded.LICENSE.md"] = "LICENSE.md"
        };

    [STAThread]
    private static int Main()
    {
        Console.OutputEncoding = System.Text.Encoding.UTF8;
        Console.InputEncoding = System.Text.Encoding.UTF8;
        Console.Title = "Health Restorer 1.2.0";

        try
        {
            if (!OperatingSystem.IsWindows())
            {
                throw new PlatformNotSupportedException("Health Restorer supports Windows only.");
            }

            string packagePath = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),
                ProductFolder,
                PackageFolder
            );

            Directory.CreateDirectory(packagePath);
            ExtractEmbeddedFiles(packagePath);

            string launcherPath = Path.Combine(packagePath, "Start-HealthRestorer.ps1");
            return RunPowerShell(launcherPath, packagePath);
        }
        catch (Exception exception)
        {
            WriteFailureLog(exception);
            Console.Error.WriteLine("Health Restorer could not start.");
            Console.Error.WriteLine(exception.Message);
            Console.Error.WriteLine();
            Console.Error.WriteLine("Details were written to:");
            Console.Error.WriteLine(GetFailureLogPath());
            Console.Error.WriteLine();
            Console.Error.WriteLine("Press Enter to close.");
            Console.ReadLine();
            return 1;
        }
    }

    private static void ExtractEmbeddedFiles(string destination)
    {
        Assembly assembly = Assembly.GetExecutingAssembly();

        foreach ((string resourceName, string fileName) in EmbeddedFiles)
        {
            using Stream source = assembly.GetManifestResourceStream(resourceName)
                ?? throw new InvalidOperationException($"Embedded resource was not found: {resourceName}");

            string targetPath = Path.Combine(destination, fileName);
            string temporaryPath = targetPath + ".new";

            using (FileStream target = new(
                temporaryPath,
                FileMode.Create,
                FileAccess.Write,
                FileShare.None
            ))
            {
                source.CopyTo(target);
                target.Flush(true);
            }

            File.Move(temporaryPath, targetPath, true);
        }
    }

    private static int RunPowerShell(string scriptPath, string workingDirectory)
    {
        string windowsPath = Environment.GetFolderPath(Environment.SpecialFolder.Windows);
        string powerShellPath = Path.Combine(
            windowsPath,
            "System32",
            "WindowsPowerShell",
            "v1.0",
            "powershell.exe"
        );

        if (!File.Exists(powerShellPath))
        {
            throw new FileNotFoundException("Windows PowerShell was not found.", powerShellPath);
        }

        ProcessStartInfo startInfo = new()
        {
            FileName = powerShellPath,
            WorkingDirectory = workingDirectory,
            UseShellExecute = false
        };

        startInfo.ArgumentList.Add("-NoProfile");
        startInfo.ArgumentList.Add("-ExecutionPolicy");
        startInfo.ArgumentList.Add("Bypass");
        startInfo.ArgumentList.Add("-File");
        startInfo.ArgumentList.Add(scriptPath);

        using Process process = Process.Start(startInfo)
            ?? throw new InvalidOperationException("Windows PowerShell could not be started.");

        process.WaitForExit();
        return process.ExitCode;
    }

    private static string GetFailureLogPath()
    {
        return Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),
            ProductFolder,
            "launcher-error.log"
        );
    }

    private static void WriteFailureLog(Exception exception)
    {
        try
        {
            string logPath = GetFailureLogPath();
            Directory.CreateDirectory(Path.GetDirectoryName(logPath)!);
            File.AppendAllText(
                logPath,
                $"[{DateTime.Now:yyyy-MM-dd HH:mm:ss}] {exception}{Environment.NewLine}"
            );
        }
        catch
        {
        }
    }
}
