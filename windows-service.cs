using System;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.ServiceProcess;
using System.Text.RegularExpressions;
using System.Threading;

// Built with the .NET Framework compiler included in Windows; no SDK required.
public sealed class TailcatService : ServiceBase
{
    private readonly string root = AppDomain.CurrentDomain.BaseDirectory;
    private readonly ManualResetEvent stopping = new ManualResetEvent(false);
    private readonly object logLock = new object();
    private Thread worker;
    private string State { get { return Path.Combine(root, "state"); } }

    public TailcatService()
    {
        ServiceName = "TailcatOneShot";
        CanShutdown = true;
    }

    public static void Main(string[] args)
    {
        using (var service = new TailcatService())
        {
            if (args.Length == 1 && args[0] == "--console")
            {
                Console.CancelKeyPress += delegate(object sender, ConsoleCancelEventArgs e) {
                    e.Cancel = true;
                    service.stopping.Set();
                };
                service.OnStart(new string[0]);
                service.stopping.WaitOne();
                service.OnStop();
            }
            else ServiceBase.Run(service);
        }
    }

    protected override void OnStart(string[] args)
    {
        Directory.CreateDirectory(State);
        File.Delete(Path.Combine(State, "address"));
        stopping.Reset();
        worker = new Thread(Run);
        worker.IsBackground = true;
        worker.Start();
    }

    protected override void OnStop()
    {
        stopping.Set();
        if (worker != null && !worker.Join(15000))
            throw new System.TimeoutException("Tailcat did not stop within 15 seconds.");
    }

    protected override void OnShutdown() { OnStop(); }

    private void Log(string line)
    {
        if (line == null) return;
        lock (logLock)
        {
            string path = Path.Combine(State, "server.log");
            if (File.Exists(path) && new FileInfo(path).Length > 5 * 1024 * 1024)
            {
                File.Delete(path + ".1");
                File.Move(path, path + ".1");
            }
            File.AppendAllText(path, line + Environment.NewLine);
            // Only a live server announcement counts as readiness (not genkey output).
            if (line.IndexOf("listening", StringComparison.OrdinalIgnoreCase) >= 0)
            {
                Match match = Regex.Match(line, @"tc[A-Za-z0-9_-]{80,}");
                if (match.Success) File.WriteAllText(Path.Combine(State, "address"), match.Value);
            }
        }
    }

    private void Run()
    {
        while (!stopping.WaitOne(0))
        {
            try
            {
                string key = Path.Combine(State, @"config\tailcat\keys\default.private.json");
                if (!File.Exists(key) && RunChild("genkey --key=default") != 0)
                    throw new Exception("Tailcat key generation failed; see server.log.");
                if (!stopping.WaitOne(0))
                {
                    File.Delete(Path.Combine(State, "address"));
                    int code = RunChild(File.ReadAllText(Path.Combine(root, "arguments.txt")).Trim());
                    Log("Tailcat exited with code " + code + "; retrying in 5 seconds.");
                }
            }
            catch (Exception e) { Log(e.ToString()); }
            finally { File.Delete(Path.Combine(State, "address")); }
            stopping.WaitOne(5000);
        }
    }

    private int RunChild(string arguments)
    {
        using (var job = new ChildJob())
        using (var process = new Process())
        {
            var info = new ProcessStartInfo(Path.Combine(root, "tailcat.exe"), arguments);
            info.UseShellExecute = false;
            info.CreateNoWindow = true;
            info.WorkingDirectory = State;
            info.RedirectStandardOutput = true;
            info.RedirectStandardError = true;
            info.EnvironmentVariables["APPDATA"] = Path.Combine(State, "config");
            info.EnvironmentVariables["LOCALAPPDATA"] = Path.Combine(State, "local");
            info.EnvironmentVariables["USERPROFILE"] = State;
            info.EnvironmentVariables["HOME"] = State;
            process.StartInfo = info;
            process.OutputDataReceived += delegate(object sender, DataReceivedEventArgs e) { Log(e.Data); };
            process.ErrorDataReceived += delegate(object sender, DataReceivedEventArgs e) { Log(e.Data); };
            process.Start();
            try { job.Assign(process); }
            catch { process.Kill(); throw; }
            process.BeginOutputReadLine();
            process.BeginErrorReadLine();
            while (!process.WaitForExit(250))
                if (stopping.WaitOne(0)) { job.Dispose(); break; }
            process.WaitForExit(); // Drain asynchronous output before reading the exit code.
            return process.ExitCode;
        }
    }

    // Closing the job kills Tailcat and every SSH child, including on host crashes.
    private sealed class ChildJob : IDisposable
    {
        private IntPtr handle;
        [StructLayout(LayoutKind.Sequential)]
        private struct BasicLimits
        {
            public long PerProcessUserTimeLimit, PerJobUserTimeLimit;
            public uint LimitFlags;
            public UIntPtr MinimumWorkingSetSize, MaximumWorkingSetSize;
            public uint ActiveProcessLimit;
            public UIntPtr Affinity;
            public uint PriorityClass, SchedulingClass;
        }
        [StructLayout(LayoutKind.Sequential)]
        private struct ExtendedLimits
        {
            public BasicLimits Basic;
            public ulong ReadOperationCount, WriteOperationCount, OtherOperationCount;
            public ulong ReadTransferCount, WriteTransferCount, OtherTransferCount;
            public UIntPtr ProcessMemoryLimit, JobMemoryLimit, PeakProcessMemoryUsed, PeakJobMemoryUsed;
        }
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr CreateJobObject(IntPtr attributes, string name);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool SetInformationJobObject(IntPtr job, int type, ref ExtendedLimits limits, uint size);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
        [DllImport("kernel32.dll")]
        private static extern bool CloseHandle(IntPtr handle);
        public ChildJob()
        {
            handle = CreateJobObject(IntPtr.Zero, null);
            var limits = new ExtendedLimits();
            limits.Basic.LimitFlags = 0x2000; // JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
            if (handle == IntPtr.Zero || !SetInformationJobObject(handle, 9, ref limits, (uint)Marshal.SizeOf(limits)))
            {
                int error = Marshal.GetLastWin32Error();
                Dispose();
                throw new System.ComponentModel.Win32Exception(error);
            }
        }
        public void Assign(Process process)
        {
            if (!AssignProcessToJobObject(handle, process.Handle))
                throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        }
        public void Dispose()
        {
            if (handle != IntPtr.Zero) { CloseHandle(handle); handle = IntPtr.Zero; }
        }
    }
}
