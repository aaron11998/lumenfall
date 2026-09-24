// LUMENFALL game module implementation (AGE-141 scaffold).
// NOTE: clangd diagnostics on this file are expected noise — there is no UE
// engine on this host, so no compile_commands.json exists. Compilation is
// proven by UnrealBuildTool on a machine with a UE 5.4 install (CI or dev rig).
#include "Lumenfall.h"
#include "Modules/ModuleManager.h"

DEFINE_LOG_CATEGORY(LogLumenfall);

void FLumenfallModule::StartupModule()
{
	UE_LOG(LogLumenfall, Log, TEXT("LUMENFALL game module up (scaffold, AGE-141)"));
}

void FLumenfallModule::ShutdownModule()
{
}

IMPLEMENT_PRIMARY_GAME_MODULE(FLumenfallModule, Lumenfall, "Lumenfall");
