using NUnit.Framework;
using UnityEngine;

namespace Lumenfall.Tests
{
    /// <summary>
    /// AGE-140 minimal EditMode smoke suite (runs via Unity Test Runner CLI:
    /// -runTests -testPlatform EditMode). Expands as real Unity gameplay lands.
    /// </summary>
    public class SmokeTests
    {
        [Test]
        public void Mathf_Clamp_Behaves()
        {
            Assert.AreEqual(5, Mathf.Clamp(5, 0, 10));
            Assert.AreEqual(0, Mathf.Clamp(-1, 0, 10));
            Assert.AreEqual(10, Mathf.Clamp(11, 0, 10));
        }

        [Test]
        public void JsonUtility_RoundTrip()
        {
            var payload = new BuildProbe { buildId = 42, channel = "ci" };
            var json = JsonUtility.ToJson(payload);
            var back = JsonUtility.FromJson<BuildProbe>(json);
            Assert.AreEqual(42, back.buildId);
            Assert.AreEqual("ci", back.channel);
        }

        [Test]
        public void Time_FixedDeltaTime_Sane()
        {
            Assert.Greater(ProjectSettings_FixedStep(), 0f);
        }

        private static float ProjectSettings_FixedStep()
        {
            return UnityEngine.Time.fixedDeltaTime;
        }

        [System.Serializable]
        private class BuildProbe
        {
            public int buildId;
            public string channel;
        }
    }
}
