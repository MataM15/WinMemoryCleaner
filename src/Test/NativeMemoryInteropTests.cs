using NUnit.Framework;

#pragma warning disable CS1591 // Missing XML comment for publicly visible type or member

namespace WinMemoryCleaner.NativeMemoryTests
{
    [TestFixture]
    public sealed class NativeMemoryInteropTests
    {
        [Test]
        public void CreateNtStatusException_WhenStatusIsAccessDenied_MapsToWin32AccessDenied()
        {
            var staleWin32Error = Constants.Windows.SystemErrorCode.ErrorInvalidParameter;
            var exception = ComputerService.CreateNtStatusException(
                Constants.Windows.NtStatus.StatusAccessDenied,
                staleWin32Error);

            Assert.AreEqual(Constants.Windows.SystemErrorCode.ErrorAccessDenied, exception.NativeErrorCode);
        }

        [Test]
        public void IsAdjustTokenPrivilegesSuccessful_WhenNotAllPrivilegesAreAssigned_ReturnsFalse()
        {
            Assert.IsFalse(ComputerService.IsAdjustTokenPrivilegesSuccessful(
                true,
                Constants.Windows.SystemErrorCode.ErrorNotAllAssigned));
        }
    }
}

#pragma warning restore CS1591 // Missing XML comment for publicly visible type or member
