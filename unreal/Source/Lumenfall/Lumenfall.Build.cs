// LUMENFALL UE5 primary game module (AGE-141 scaffold).
// Deliberately minimal: compiles clean against stock Engine modules only.
// GAS modules (GameplayAbilities/GameplayTags/GameplayTasks) are added by the
// first feature branch that needs abilities — not pre-wired here, so this
// scaffold builds against a stock engine install with zero extra setup.
using UnrealBuildTool;
using System.Collections.Generic;

public class Lumenfall : ModuleRules
{
	public Lumenfall(ReadOnlyTargetRules Target) : base(Target)
	{
		PCHUsage = PCHUsageMode.UseExplicitOrSharedPCHs;

		PublicDependencyModuleNames.AddRange(new string[]
		{
			"Core",
			"CoreUObject",
			"Engine",
			"InputCore"
		});

		PrivateDependencyModuleNames.AddRange(new string[]
		{
			"Slate",
			"SlateCore"
		});
	}
}
