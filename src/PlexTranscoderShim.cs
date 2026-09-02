// ===========================================================================
//  PlexTranscoderShim
//
//  Sits in place of "Plex Transcoder.exe", rewrites rate-control arguments
//  for encoders that mishandle them, and forwards everything to the real
//  Plex binary ("Plex Transcoder Real.exe") in the same folder.
//
//  Design notes:
//   * Operates on the RAW command line (Environment.CommandLine), never on a
//     parsed argv. Round-tripping Plex's filter graphs through parse+requote
//     is the most likely way to break this, so we simply don't.
//   * Fails OPEN. Any error at all -> the real binary runs with the original,
//     untouched command line. A bug here must never stop playback.
//   * Puts itself in a Job Object with KILL_ON_JOB_CLOSE before spawning.
//     Children inherit job membership, so when Plex kills this shim the real
//     transcoder dies with it instead of orphaning and filling the temp disk.
//   * Optionally sets the child's CPU priority (shim.ini: priority=...).
//   * Reads shim.ini on EVERY invocation, so config changes take effect on the
//     next transcode. No rebuild, no Plex restart.
// ===========================================================================

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;

[assembly: AssemblyTitle("PlexTranscoderShim")]
[assembly: AssemblyDescription("A fail-open Plex Transcoder rate-control wrapper for Windows")]
[assembly: AssemblyProduct("PlexTranscoderShim")]
[assembly: AssemblyVersion("1.0.0.0")]
[assembly: AssemblyFileVersion("1.0.0.0")]

internal static class Shim
{
    private const string RealExeName = "Plex Transcoder Real.exe";
    private const string ConfigName = "shim.ini";

    // ---- config (defaults are used if shim.ini is missing or unreadable) ----
    private static bool _enabled = true;
    private static bool _logEnabled = true;
    private static string _logFile = "";
    private static long _logMaxBytes = 5 * 1024 * 1024;
    private static List<string> _codecs = new List<string>(new[] { "hevc_qsv" });
    private static double _bitrateFactor = 0.90;
    private static double _bufsizeFactor = 0.0;   // 0 = leave Plex's value alone
    private static string _extraArgs = "";
    private static string _priority = "";         // "" = leave the child's default

    private static string _exeDir = "";

    private static int Main()
    {
        _exeDir = AppDomain.CurrentDomain.BaseDirectory;
        _logFile = Path.Combine(_exeDir, "shim.log");

        string original = StripOwnExe(Environment.CommandLine);
        string final = original;

        try
        {
            LoadConfig(Path.Combine(_exeDir, ConfigName));
            ValidateConfig();
            if (_enabled)
            {
                final = Rewrite(original);
            }
        }
        catch (Exception ex)
        {
            final = original;                       // fail open
            TryLog("ERROR (passing through unmodified): " + ex.Message);
        }

        if (_logEnabled && !string.Equals(original, final, StringComparison.Ordinal))
        {
            TryLog("IN : " + original);
            TryLog("OUT: " + final);
        }

        string realExe = Path.Combine(_exeDir, RealExeName);
        if (!File.Exists(realExe))
        {
            Console.Error.WriteLine("PlexTranscoderShim: cannot find " + realExe);
            return 127;
        }

        try
        {
            return RunChild(realExe, final);
        }
        catch (Exception ex)
        {
            TryLog("ERROR: could not launch the real transcoder: " + ex.Message);
            Console.Error.WriteLine("PlexTranscoderShim: could not launch the real transcoder: " + ex.Message);
            return 126;
        }
    }

    // ------------------------------------------------------------------ args

    /// <summary>
    /// Environment.CommandLine includes our own exe path. Remove exactly that
    /// leading token (quoted or not) and return the remainder verbatim.
    /// </summary>
    private static string StripOwnExe(string cmdLine)
    {
        if (string.IsNullOrEmpty(cmdLine)) return "";
        int i = 0;
        while (i < cmdLine.Length && char.IsWhiteSpace(cmdLine[i])) i++;

        if (i < cmdLine.Length && cmdLine[i] == '"')
        {
            i++;
            while (i < cmdLine.Length && cmdLine[i] != '"') i++;
            if (i < cmdLine.Length) i++;            // closing quote
        }
        else
        {
            while (i < cmdLine.Length && !char.IsWhiteSpace(cmdLine[i])) i++;
        }

        return cmdLine.Substring(Math.Min(i, cmdLine.Length)).TrimStart();
    }

    /// <summary>
    /// Find a managed encoder, then rewrite its rate control. Everything is
    /// scoped to the stream index the encoder was declared on, and the search
    /// starts AFTER the encoder token so input-side options are never touched
    /// (Plex uses "-codec:0 hevc" for the DECODER on the same index).
    /// </summary>
    private static string Rewrite(string args)
    {
        if (_codecs.Count == 0) return args;

        string alternation = string.Join("|", _codecs.ToArray());
        Match enc = Regex.Match(args,
            @"-(?:codec|c):(\d+)\s+(" + alternation + @")\b",
            RegexOptions.IgnoreCase);

        if (!enc.Success) return args;

        string idx = enc.Groups[1].Value;
        int scanFrom = enc.Index + enc.Length;
        string head = args.Substring(0, scanFrom);
        string tail = args.Substring(scanFrom);

        // maxrate is the anchor: everything is derived from it.
        Match mr = Regex.Match(tail, @"-maxrate:" + idx + @"\s+(\d+)([kKmM]?)");
        if (!mr.Success)
        {
            TryLog("no -maxrate:" + idx + " found; leaving rate control alone");
            return args;
        }

        long maxrateBps = ToBitsPerSecond(mr.Groups[1].Value, mr.Groups[2].Value);
        long targetKbps = (long)Math.Round(maxrateBps * _bitrateFactor / 1000.0);

        // The actual fix: a quality-only invocation lets QSV ignore maxrate.
        // Giving it an explicit target pulls it into constrained VBR.
        string qPattern = @"-q:" + idx + @"\s+[\d.]+";
        string bPattern = @"-b:" + idx + @"\s+\d+[kKmM]?";
        bool hasQuality = Regex.IsMatch(tail, qPattern);
        bool hasBitrate = Regex.IsMatch(tail, bPattern);
        string targetBitrate = "-b:" + idx + " " +
            targetKbps.ToString(CultureInfo.InvariantCulture) + "k";
        if (hasQuality && hasBitrate)
        {
            // Avoid leaving mutually conflicting rate-control options if a
            // future Plex version supplies both quality and bitrate modes.
            tail = Regex.Replace(tail, qPattern, "");
            tail = Regex.Replace(tail, bPattern, targetBitrate);
        }
        else if (hasQuality)
        {
            tail = Regex.Replace(tail, qPattern, targetBitrate, RegexOptions.None);
        }
        else if (!hasBitrate)
        {
            tail = Regex.Replace(tail, @"(-maxrate:" + idx + @"\s+)",
                targetBitrate + " $1");
        }

        if (_bufsizeFactor > 0)
        {
            long bufKbps = (long)Math.Round(maxrateBps * _bufsizeFactor / 1000.0);
            tail = Regex.Replace(tail, @"-bufsize:" + idx + @"\s+\d+[kKmM]?",
                "-bufsize:" + idx + " " + bufKbps.ToString(CultureInfo.InvariantCulture) + "k");
        }

        if (!string.IsNullOrEmpty(_extraArgs))
        {
            string extra = _extraArgs.Replace("{i}", idx);
            Regex anchor = new Regex(@"(-maxrate:" + idx + @"\s+\d+[kKmM]?)");
            tail = anchor.Replace(tail, delegate(Match match)
            {
                return match.Groups[1].Value + " " + extra;
            }, 1);
        }

        return head + tail;
    }

    private static long ToBitsPerSecond(string number, string suffix)
    {
        long v = long.Parse(number, CultureInfo.InvariantCulture);
        if (suffix.Equals("k", StringComparison.OrdinalIgnoreCase)) return v * 1000L;
        if (suffix.Equals("m", StringComparison.OrdinalIgnoreCase)) return v * 1000000L;
        return v;
    }

    // ---------------------------------------------------------------- config

    private static void LoadConfig(string path)
    {
        if (!File.Exists(path)) return;

        foreach (string raw in File.ReadAllLines(path))
        {
            string line = raw.Trim();
            if (line.Length == 0 || line[0] == '#' || line[0] == ';') continue;

            int eq = line.IndexOf('=');
            if (eq <= 0) continue;

            string key = line.Substring(0, eq).Trim().ToLowerInvariant();
            string val = line.Substring(eq + 1).Trim();

            switch (key)
            {
                case "enabled":        _enabled = IsTrue(val); break;
                case "log":            _logEnabled = IsTrue(val); break;
                case "logfile":        if (val.Length > 0) _logFile = val; break;
                case "log_max_mb":     _logMaxBytes = long.Parse(val, CultureInfo.InvariantCulture) * 1024 * 1024; break;
                case "bitrate_factor": _bitrateFactor = double.Parse(val, CultureInfo.InvariantCulture); break;
                case "bufsize_factor": _bufsizeFactor = double.Parse(val, CultureInfo.InvariantCulture); break;
                case "extra":          _extraArgs = val; break;
                case "priority":       _priority = val.ToLowerInvariant(); break;
                case "codecs":
                    _codecs = new List<string>();
                    foreach (string c in val.Split(','))
                    {
                        string t = c.Trim();
                        if (t.Length > 0) _codecs.Add(Regex.Escape(t));
                    }
                    break;
            }
        }
    }

    private static bool IsTrue(string v)
    {
        v = v.Trim().ToLowerInvariant();
        return v == "1" || v == "true" || v == "yes" || v == "on";
    }

    private static void ValidateConfig()
    {
        if (double.IsNaN(_bitrateFactor) || double.IsInfinity(_bitrateFactor) ||
            _bitrateFactor <= 0.0 || _bitrateFactor > 1.0)
            throw new InvalidDataException("bitrate_factor must be greater than 0 and no greater than 1.0");

        if (double.IsNaN(_bufsizeFactor) || double.IsInfinity(_bufsizeFactor) ||
            _bufsizeFactor < 0.0 || _bufsizeFactor > 10.0)
            throw new InvalidDataException("bufsize_factor must be 0 or between 0.1 and 10.0");

        if (_logMaxBytes < 1024 * 1024 || _logMaxBytes > 1024L * 1024L * 1024L)
            throw new InvalidDataException("log_max_mb must be between 1 and 1024");
    }

    // --------------------------------------------------------------- logging

    private static void TryLog(string message)
    {
        if (!_logEnabled) return;
        try
        {
            if (File.Exists(_logFile) && new FileInfo(_logFile).Length > _logMaxBytes)
                File.Delete(_logFile);

            File.AppendAllText(_logFile,
                DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss", CultureInfo.InvariantCulture)
                + " [" + Process.GetCurrentProcess().Id + "] " + RedactSensitiveLogText(message) + Environment.NewLine,
                Encoding.UTF8);
        }
        catch { /* logging must never break a transcode */ }
    }

    private static string RedactSensitiveLogText(string value)
    {
        if (string.IsNullOrEmpty(value)) return value;
        return Regex.Replace(value,
            @"(?i)(X-Plex-Token|PlexToken|api[_-]?key)(=|%3D)([^&\s""']+)",
            delegate(Match match)
            {
                return match.Groups[1].Value + match.Groups[2].Value + "<redacted>";
            });
    }

    // ------------------------------------------------------- child + job obj

    private static int RunChild(string exe, string arguments)
    {
        CreateJobKillOnClose();                   // failure is non-fatal

        ProcessStartInfo psi = new ProcessStartInfo(exe, arguments);
        psi.UseShellExecute = false;              // inherit our stdin/out/err
        psi.CreateNoWindow = true;

        using (Process p = Process.Start(psi))
        {
            ApplyPriority(p);
            p.WaitForExit();
            // Do not explicitly close the job handle while this shim is still
            // a member: KILL_ON_JOB_CLOSE would terminate the shim before it
            // can return the child's exit code. Windows closes the handle as
            // part of normal process teardown immediately after Main returns.
            return p.ExitCode;
        }
    }

    /// <summary>
    /// Set the transcoder's CPU priority. PriorityClass only exists on a live
    /// Process - it cannot be passed through ProcessStartInfo - so this runs
    /// after Start(). A just-started process can briefly refuse the call and a
    /// very short job may already have exited, so retry a couple of times and
    /// treat total failure as a warning, never an error.
    ///
    /// Scope note: QSV encoding runs on the Arc's fixed-function hardware, so
    /// this affects the CPU-side demux / filter / mux / segmenting threads
    /// only. Windows has no equivalent priority control for GPU contention.
    /// </summary>
    private static void ApplyPriority(Process p)
    {
        if (string.IsNullOrEmpty(_priority)) return;

        ProcessPriorityClass cls;
        switch (_priority)
        {
            case "idle":        cls = ProcessPriorityClass.Idle;        break;
            case "belownormal": cls = ProcessPriorityClass.BelowNormal; break;
            case "normal":      cls = ProcessPriorityClass.Normal;      break;
            case "abovenormal": cls = ProcessPriorityClass.AboveNormal; break;
            case "high":        cls = ProcessPriorityClass.High;        break;
            case "realtime":
                TryLog("WARN: refusing priority=realtime because it can destabilize Windows; leaving the default");
                return;
            default:
                TryLog("WARN: unknown priority '" + _priority + "' - leaving the default");
                return;
        }

        for (int attempt = 0; attempt < 3; attempt++)
        {
            try
            {
                if (p.HasExited) return;
                p.PriorityClass = cls;
                TryLog("priority set to " + cls);
                return;
            }
            catch (Exception ex)
            {
                if (attempt == 2) TryLog("WARN: could not set priority: " + ex.Message);
                else System.Threading.Thread.Sleep(50);
            }
        }
    }

    /// <summary>
    /// Create a job object with KILL_ON_JOB_CLOSE and put OURSELVES in it.
    /// Child processes inherit job membership, so there is no window in which
    /// a spawned transcoder exists outside the job. If Plex terminates this
    /// process, our handle closes, the job closes, and the child dies too.
    /// </summary>
    private static IntPtr CreateJobKillOnClose()
    {
        try
        {
            IntPtr job = CreateJobObject(IntPtr.Zero, null);
            if (job == IntPtr.Zero) return IntPtr.Zero;

            JOBOBJECT_EXTENDED_LIMIT_INFORMATION info = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
            info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;

            int len = Marshal.SizeOf(typeof(JOBOBJECT_EXTENDED_LIMIT_INFORMATION));
            IntPtr ptr = Marshal.AllocHGlobal(len);
            try
            {
                Marshal.StructureToPtr(info, ptr, false);
                if (!SetInformationJobObject(job, JobObjectExtendedLimitInformation, ptr, (uint)len))
                {
                    CloseHandle(job);
                    return IntPtr.Zero;
                }
            }
            finally { Marshal.FreeHGlobal(ptr); }

            if (!AssignProcessToJobObject(job, Process.GetCurrentProcess().Handle))
            {
                // Already in a job that forbids nesting: not fatal, just log it.
                TryLog("WARN: could not join job object; child may outlive a kill");
                CloseHandle(job);
                return IntPtr.Zero;
            }
            return job;
        }
        catch (Exception ex)
        {
            TryLog("WARN: job object setup failed: " + ex.Message);
            return IntPtr.Zero;
        }
    }

    private const int JobObjectExtendedLimitInformation = 9;
    private const uint JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x2000;

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr CreateJobObject(IntPtr attrs, string name);

    [DllImport("kernel32.dll")]
    private static extern bool SetInformationJobObject(IntPtr job, int infoClass, IntPtr info, uint length);

    [DllImport("kernel32.dll")]
    private static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);

    [DllImport("kernel32.dll")]
    private static extern bool CloseHandle(IntPtr handle);

    [StructLayout(LayoutKind.Sequential)]
    private struct JOBOBJECT_BASIC_LIMIT_INFORMATION
    {
        public long PerProcessUserTimeLimit;
        public long PerJobUserTimeLimit;
        public uint LimitFlags;
        public UIntPtr MinimumWorkingSetSize;
        public UIntPtr MaximumWorkingSetSize;
        public uint ActiveProcessLimit;
        public UIntPtr Affinity;
        public uint PriorityClass;
        public uint SchedulingClass;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct IO_COUNTERS
    {
        public ulong ReadOperationCount, WriteOperationCount, OtherOperationCount;
        public ulong ReadTransferCount, WriteTransferCount, OtherTransferCount;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION
    {
        public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
        public IO_COUNTERS IoInfo;
        public UIntPtr ProcessMemoryLimit;
        public UIntPtr JobMemoryLimit;
        public UIntPtr PeakProcessMemoryUsed;
        public UIntPtr PeakJobMemoryUsed;
    }
}
