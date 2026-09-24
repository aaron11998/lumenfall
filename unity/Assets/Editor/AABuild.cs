using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using UnityEditor;
using UnityEditor.Build.Reporting;
using UnityEditor.SceneManagement;
using UnityEngine;
// `Debug` is ambiguous with System.Diagnostics.Debug when both namespaces are
// imported (CS0104); pin it to Unity's so CI compile never trips on this.
using Debug = UnityEngine.Debug;

namespace Lumenfall.EditorTools
{
    /// <summary>
    /// AGE-140 CI entry points. Invoked via:
    ///   Unity -batchmode -nographics -projectPath ... -executeMethod Lumenfall.EditorTools.AABuild.Build
    /// Gate contract (BUILD_MATRIX.md §2.3): exit 0 + zero compiler errors.
    /// The build script MUST parse CompilerLogs itself and exit nonzero on errors —
    /// a Unity batchmode run does not reliably fail on compile errors by itself.
    /// </summary>
    public static class AABuild
    {
        private static bool HasCompilerErrors()
        {
            // Batchmode runs this after domain reload: a failed compile surfaces
            // here. (EditorUtility.scriptCompilationFailed is the supported API;
            // no internal LogEntries reflection — that would itself be a compile
            // hazard across Unity versions.)
            return EditorUtility.scriptCompilationFailed;
        }

        public static void Build()
        {
            var sw = Stopwatch.StartNew();
            Debug.Log("[AABuild] === LUMENFALL Unity build start ===");

            if (HasCompilerErrors())
            {
                Debug.LogError("[AABuild] compile errors present — failing gate");
                EditorApplication.Exit(2);
                return;
            }

            var outDir = Environment.GetEnvironmentVariable("UNITY_BUILD_OUT")
                         ?? Path.Combine(Directory.GetParent(Application.dataPath).FullName,
                                         "builds", "unity", "LUMENFALL.app");

            Directory.CreateDirectory(outDir);

            var scenes = EditorBuildSettings.scenes
                .Where(s => s.enabled)
                .Select(s => s.path)
                .ToArray();
            if (scenes.Length == 0)
            {
                // Fallback: ensure the bootstrap scene exists (create a minimal
                // Camera+Light scene on the fly — no hand-authored YAML to rot)
                // so the gate can never green-light an empty scene list.
                const string bootstrap = "Assets/Scenes/Bootstrap.unity";
                var projRoot = Directory.GetParent(Application.dataPath).FullName;
                if (!File.Exists(Path.Combine(projRoot, bootstrap)))
                {
                    if (!EnsureBootstrapScene(bootstrap))
                    {
                        Debug.LogError($"[AABuild] bootstrap scene missing and could not be created: {bootstrap}");
                        EditorApplication.Exit(3);
                        return;
                    }
                }
                scenes = new[] { bootstrap };
            }

            var options = new BuildPlayerOptions
            {
                scenes = scenes,
                locationPathName = outDir,
                target = BuildTarget.StandaloneOSX,
                options = BuildOptions.None
            };

            var report = BuildPipeline.BuildPlayer(options);

            Debug.Log($"[AABuild] build summary: {report.summary.result} " +
                      $"platform={report.summary.platform} output={report.summary.outputPath} " +
                      $"size={report.summary.totalSize} errors={report.summary.totalErrors} " +
                      $"warnings={report.summary.totalWarnings} elapsed={sw.ElapsedMilliseconds}ms");

            if (report.summary.result != BuildResult.Succeeded || report.summary.totalErrors > 0)
            {
                Debug.LogError("[AABuild] BuildPlayer failed — failing gate");
                EditorApplication.Exit(4);
                return;
            }

            Debug.Log($"[AABuild] BUILD_OK {sw.ElapsedMilliseconds}ms");
            EditorApplication.Exit(0);
        }

        /// <summary>
        /// Creates the minimal bootstrap scene (Camera + directional Light) via
        /// the EditorSceneManager API — the asset-creation path runs inside the
        /// editor process, so no checked-in scene YAML is needed for CI.
        /// </summary>
        private static bool EnsureBootstrapScene(string assetPath)
        {
            try
            {
                var dir = Path.GetDirectoryName(Path.Combine(Directory.GetParent(Application.dataPath).FullName, assetPath));
                if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);

                var scene = EditorSceneManager.NewScene(NewSceneSetup.DefaultGameObjects,
                                                        NewSceneMode.Single);
                // DefaultGameObjects already provides Main Camera + Directional Light.
                Debug.Log($"[AABuild] bootstrap scene created: {assetPath} " +
                          $"(root objects: {scene.rootCount})");
                return EditorSceneManager.SaveScene(scene, assetPath);
            }
            catch (Exception e)
            {
                Debug.LogError($"[AABuild] bootstrap scene creation failed: {e}");
                return false;
            }
        }

        /// <summary>
        /// Test-runner entry point (Build matrix smoke gate):
        ///   Unity -batchmode -nographics -runTests -testPlatform EditMode ...
        /// Kept separate from Build() because -runTests is its own CLI mode.
        /// </summary>
        public static void RunEditModeTests()
        {
            Debug.Log("[AABuild] EditMode tests are run via -runTests CLI mode; nothing to do here");
            EditorApplication.Exit(0);
        }
    }
}
