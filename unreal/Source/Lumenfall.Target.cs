// Lumenfall game target (AGE-141 scaffold).
using UnrealBuildTool;
using System.Collections.Generic;

public class LumenfallTarget : TargetRules
{
	public LumenfallTarget(TargetInfo Target) : base(Target)
	{
		Type = TargetType.Game;
		DefaultBuildSettings = BuildSettingsVersion.V5;
		IncludeOrderVersion = EngineIncludeOrderVersion.Unreal5_4;
		ExtraModuleNames.Add("Lumenfall");
	}
}
