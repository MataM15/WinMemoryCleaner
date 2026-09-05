using System;
using System.Threading;

namespace WinMemoryCleaner
{
    internal sealed class OptimizationRequestCoordinator
    {
        private readonly Func<Action, bool> _scheduler;
        private object _activeRequest;

        public OptimizationRequestCoordinator()
            : this(action => ThreadPool.QueueUserWorkItem(_ => action()))
        {
        }

        internal OptimizationRequestCoordinator(Func<Action, bool> scheduler)
        {
            if (scheduler == null)
                throw new ArgumentNullException("scheduler");

            _scheduler = scheduler;
        }

        internal bool TryQueue(Action onAccepted, Action work)
        {
            if (onAccepted == null)
                throw new ArgumentNullException("onAccepted");
            if (work == null)
                throw new ArgumentNullException("work");

            object request = new object();
            if (Interlocked.CompareExchange(ref _activeRequest, request, null) != null)
                return false;

            try
            {
                onAccepted();

                if (!_scheduler(() =>
                {
                    try
                    {
                        work();
                    }
                    finally
                    {
                        Release(request);
                    }
                }))
                {
                    Release(request);
                    return false;
                }

                return true;
            }
            catch
            {
                Release(request);
                throw;
            }
        }

        private void Release(object request)
        {
            Interlocked.CompareExchange(ref _activeRequest, null, request);
        }
    }
}
