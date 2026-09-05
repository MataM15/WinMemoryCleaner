namespace WinMemoryCleaner
{
    /// <summary>
    /// Provides the update policy for this experimental fork.
    /// </summary>
    public static class Updater
    {
        /// <summary>
        /// Gets a value indicating whether automatic updates are enabled.
        /// </summary>
        /// <value>Always <c>false</c>; this experimental fork never updates itself.</value>
        internal static bool IsAutoUpdateEnabled
        {
            get { return false; }
        }

        /// <summary>
        /// Retained for compatibility with existing update call sites.
        /// </summary>
        /// <param name="args">Ignored command-line arguments.</param>
        public static void Update(params string[] args)
        {
            if (args == null)
                return;

            // Automatic updating is permanently disabled for this experimental fork.
        }
    }
}
