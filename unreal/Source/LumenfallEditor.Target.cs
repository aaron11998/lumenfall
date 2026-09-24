// Lumenfall editor target (AGE-141 scaffold).
using UnrealBuildTool;
using System.Collections.Generic;

public class LumenfallEditorTarget : TargetRules
{
	public LumenfallEditorTarget(TargetInfo Target) : base(Target)
	{
		Type = TargetType.Editor;
		DefaultBuildSettings = BuildSettingsVersion.V5;
		IncludeOrderVersion = EngineIncludeOrderVersion.Unreal5_4;
		ExtraModuleNames.Add("Lumenfall");
	}
}
