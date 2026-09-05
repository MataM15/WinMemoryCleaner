using System;
using System.Threading;

namespace WinMemoryCleaner
{
    internal sealed class OptimizationRequestCoordinator
    {
        private readonly Func<Action, bool> _scheduler;

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

            onAccepted();
            return _scheduler(work);
        }
    }
}
