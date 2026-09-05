using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Runtime;
using System.Text;
using NUnit.Framework;

namespace WinMemoryCleaner.MemoryBenchmarks
{
#pragma warning disable CS1591
    [TestFixture]
    [Explicit("Runs only in the disposable Windows CI benchmark job.")]
    public class ReleaseMemoryBenchmarkTests
    {
        private const string BenchmarkEnabledVariable = "WIN_MEMORY_CLEANER_RELEASE_MEMORY_BENCHMARK";
        private const string CsvPathVariable = "WIN_MEMORY_CLEANER_RELEASE_MEMORY_BENCHMARK_CSV";
        private const string SamplesVariable = "WIN_MEMORY_CLEANER_RELEASE_MEMORY_BENCHMARK_SAMPLES";
        private const int RetainedBytes = 32 * 1024 * 1024;
        private const int TransientBlockCount = 4;
        private const int TransientBlockBytes = 2 * 1024 * 1024;
        private const int PageSize = 4096;
        private const string Header = "variant,iteration,pid,bitness,clrVersion,serverGC,operationMs,processCpuDeltaMs,workingSetBeforeBytes,workingSetAfterBytes,workingSetRecoveryBytes,privateBytesAfterBytes,gc0Delta,gc1Delta,gc2Delta,recoveryMs";

        private string _csvPath;
        private int _samples;

        [SetUp]
        public void RequireExplicitBenchmarkEnvironment()
        {
            if (!string.Equals(Environment.GetEnvironmentVariable(BenchmarkEnabledVariable), "1", StringComparison.Ordinal))
                Assert.Ignore("Release-memory benchmarks are opt-in and may run only in the disposable Windows CI job.");

            _csvPath = Environment.GetEnvironmentVariable(CsvPathVariable);
            Assert.IsFalse(string.IsNullOrEmpty(_csvPath), "The benchmark CSV output path is required.");

            _samples = ParseSamples(Environment.GetEnvironmentVariable(SamplesVariable));
        }

        [Test]
        public void None()
        {
            RunVariant("None", WinMemoryCleaner.ReleaseMemoryMode.None);
        }

        [Test]
        public void GCOnly()
        {
            RunVariant("GCOnly", WinMemoryCleaner.ReleaseMemoryMode.GCOnly);
        }

        [Test]
        public void TrimOnly()
        {
            RunVariant("TrimOnly", WinMemoryCleaner.ReleaseMemoryMode.TrimOnly);
        }

        [Test]
        public void Combined()
        {
            RunVariant("Combined", WinMemoryCleaner.ReleaseMemoryMode.Combined);
        }

        private void RunVariant(string variant, WinMemoryCleaner.ReleaseMemoryMode mode)
        {
            var retained = new byte[RetainedBytes];
            WarmUp();
            Touch(retained);

            for (var iteration = 1; iteration <= _samples; iteration++)
                RunSample(variant, mode, iteration, retained);

            GC.KeepAlive(retained);
        }

        private static void WarmUp()
        {
            var warmup = new byte[PageSize];
            var operationErrors = new List<Exception>();
            Touch(warmup);
            WinMemoryCleaner.App.ReleaseMemory(
                WinMemoryCleaner.ReleaseMemoryMode.Combined,
                () => CaptureStage(WinMemoryCleaner.App.CollectGarbageSequence, operationErrors),
                () => CaptureStage(WinMemoryCleaner.App.TrimOwnProcessWorkingSet, operationErrors));
            Assert.AreEqual(0, operationErrors.Count, "The benchmark warmup failed: " + JoinErrors(operationErrors));
            GC.KeepAlive(warmup);
        }

        private void RunSample(string variant, WinMemoryCleaner.ReleaseMemoryMode mode, int iteration, byte[] retained)
        {
            CreateTransientGarbage();

            using (var process = Process.GetCurrentProcess())
            {
                process.Refresh();
                var workingSetBefore = process.WorkingSet64;
                var cpuBefore = process.TotalProcessorTime;
                var gc0Before = GC.CollectionCount(0);
                var gc1Before = GC.CollectionCount(1);
                var gc2Before = GC.CollectionCount(2);
                var operationErrors = new List<Exception>();
                var operationTimer = Stopwatch.StartNew();

                WinMemoryCleaner.App.ReleaseMemory(
                    mode,
                    () => CaptureStage(WinMemoryCleaner.App.CollectGarbageSequence, operationErrors),
                    () => CaptureStage(WinMemoryCleaner.App.TrimOwnProcessWorkingSet, operationErrors));

                operationTimer.Stop();
                process.Refresh();
                var workingSetAfter = process.WorkingSet64;
                var privateBytesAfter = process.PrivateMemorySize64;
                var cpuDelta = process.TotalProcessorTime - cpuBefore;
                var recoveryTimer = Stopwatch.StartNew();
                Touch(retained);
                recoveryTimer.Stop();
                process.Refresh();

                Assert.AreEqual(0, operationErrors.Count, "The benchmark operation failed: " + JoinErrors(operationErrors));
                AppendRow(
                    variant,
                    iteration,
                    process.Id,
                    Environment.Is64BitProcess ? "64" : "32",
                    Environment.Version.ToString(),
                    GCSettings.IsServerGC,
                    operationTimer.Elapsed.TotalMilliseconds,
                    cpuDelta.TotalMilliseconds,
                    workingSetBefore,
                    workingSetAfter,
                    process.WorkingSet64,
                    privateBytesAfter,
                    GC.CollectionCount(0) - gc0Before,
                    GC.CollectionCount(1) - gc1Before,
                    GC.CollectionCount(2) - gc2Before,
                    recoveryTimer.Elapsed.TotalMilliseconds);
            }
        }

        private static void CaptureStage(Action stage, ICollection<Exception> operationErrors)
        {
            try
            {
                stage();
            }
            catch (Exception exception)
            {
                operationErrors.Add(exception);
                throw;
            }
        }

        private static void CreateTransientGarbage()
        {
            var garbage = new List<byte[]>();
            for (var index = 0; index < TransientBlockCount; index++)
            {
                var block = new byte[TransientBlockBytes];
                Touch(block);
                garbage.Add(block);
            }

            garbage.Clear();
        }

        private static int Touch(byte[] bytes)
        {
            var checksum = 0;
            for (var offset = 0; offset < bytes.Length; offset += PageSize)
            {
                bytes[offset]++;
                checksum += bytes[offset];
            }

            return checksum;
        }

        private void AppendRow(
            string variant,
            int iteration,
            int processId,
            string bitness,
            string clrVersion,
            bool serverGc,
            double operationMilliseconds,
            double processCpuDeltaMilliseconds,
            long workingSetBefore,
            long workingSetAfter,
            long workingSetRecovery,
            long privateBytesAfter,
            int gc0Delta,
            int gc1Delta,
            int gc2Delta,
            double recoveryMilliseconds)
        {
            if (!File.Exists(_csvPath))
                File.AppendAllText(_csvPath, Header + Environment.NewLine, Encoding.UTF8);

            var row = string.Join(",", new[]
            {
                variant,
                iteration.ToString(CultureInfo.InvariantCulture),
                processId.ToString(CultureInfo.InvariantCulture),
                bitness,
                clrVersion,
                serverGc.ToString(),
                operationMilliseconds.ToString("R", CultureInfo.InvariantCulture),
                processCpuDeltaMilliseconds.ToString("R", CultureInfo.InvariantCulture),
                workingSetBefore.ToString(CultureInfo.InvariantCulture),
                workingSetAfter.ToString(CultureInfo.InvariantCulture),
                workingSetRecovery.ToString(CultureInfo.InvariantCulture),
                privateBytesAfter.ToString(CultureInfo.InvariantCulture),
                gc0Delta.ToString(CultureInfo.InvariantCulture),
                gc1Delta.ToString(CultureInfo.InvariantCulture),
                gc2Delta.ToString(CultureInfo.InvariantCulture),
                recoveryMilliseconds.ToString("R", CultureInfo.InvariantCulture)
            });

            File.AppendAllText(_csvPath, row + Environment.NewLine, Encoding.UTF8);
        }

        private static int ParseSamples(string value)
        {
            int samples;
            if (!int.TryParse(value, NumberStyles.None, CultureInfo.InvariantCulture, out samples) || samples < 1 || samples > 100)
                Assert.Fail("The benchmark sample count must be an integer from 1 through 100.");

            return samples;
        }

        private static string JoinErrors(IEnumerable<Exception> errors)
        {
            var messages = new List<string>();
            foreach (var error in errors)
                messages.Add(error.GetType().Name + ": " + error.Message);

            return string.Join("; ", messages.ToArray());
        }
    }
#pragma warning restore CS1591
}
