using System;
using System.Globalization;
using System.IO;
using System.Diagnostics;
using System.Threading;

internal static class FakeTranscoder
{
    private static int Main()
    {
        string output = Environment.GetEnvironmentVariable("PLEX_SHIM_TEST_OUTPUT");
        if (!string.IsNullOrEmpty(output))
        {
            File.WriteAllText(output, Environment.CommandLine);
            File.WriteAllText(output + ".pid",
                Process.GetCurrentProcess().Id.ToString(CultureInfo.InvariantCulture));
        }

        int sleepMs;
        if (int.TryParse(Environment.GetEnvironmentVariable("PLEX_SHIM_TEST_SLEEP_MS"), out sleepMs) && sleepMs > 0)
            Thread.Sleep(sleepMs);

        int exitCode;
        if (int.TryParse(Environment.GetEnvironmentVariable("PLEX_SHIM_TEST_EXIT_CODE"), out exitCode))
            return exitCode;
        return 0;
    }
}
