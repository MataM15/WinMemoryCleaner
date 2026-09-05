using NUnit.Framework;

#pragma warning disable CS1591 // Missing XML comment for publicly visible type or member

namespace WinMemoryCleaner.Test
{
    [TestFixture]
    public sealed class SecurityPolicyTests
    {
        [Test]
        public void AutoUpdate_IsBlocked_WhenStoredPreferenceIsEnabled()
        {
            AssertAutoUpdateIsBlocked(true);
        }

        [Test]
        public void AutoUpdate_IsBlocked_WhenStoredPreferenceIsDisabled()
        {
            AssertAutoUpdateIsBlocked(false);
        }

        private static void AssertAutoUpdateIsBlocked(bool storedPreference)
        {
            var originalAutoUpdate = Settings.AutoUpdate;

            try
            {
                Settings.AutoUpdate = storedPreference;

                Assert.IsFalse(Updater.IsAutoUpdateEnabled);
                Assert.DoesNotThrow(() => Updater.Update());
            }
            finally
            {
                Settings.AutoUpdate = originalAutoUpdate;
            }
        }
    }
}

#pragma warning restore CS1591 // Missing XML comment for publicly visible type or member
