using System;

namespace WinMemoryCleaner
{
    /// <summary>
    /// Provides a deterministic seam for measuring optimization completion.
    /// </summary>
    internal sealed class OptimizationTiming
    {
        private readonly Func<TimeSpan> _clock;

        internal OptimizationTiming(Func<TimeSpan> clock)
        {
            if (clock == null)
                throw new ArgumentNullException("clock");

            _clock = clock;
        }

        internal TimeSpan Measure(Action stage)
        {
            if (stage == null)
                throw new ArgumentNullException("stage");

            var startedAt = _clock();

            stage();

            return _clock().Subtract(startedAt);
        }

        internal TimeSpan Complete(TimeSpan successfulNativeRuntime, Action finalAppRelease)
        {
            Measure(finalAppRelease);

            return successfulNativeRuntime;
        }
    }

    internal enum ReleaseMemoryMode
    {
        None,
        GCOnly,
        TrimOnly,
        Combined
    }
}
