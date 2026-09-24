// LUMENFALL game module (AGE-141 scaffold).
// clangd errors here are expected: no UE engine headers exist on this host.
// UnrealBuildTool is the compiler of record (see decision doc §6).
#pragma once

#include "CoreMinimal.h"

DECLARE_LOG_CATEGORY_EXTERN(LogLumenfall, Log, All);

class FLumenfallModule : public FDefaultGameModuleImpl
{
public:
	virtual void StartupModule() override;
	virtual void ShutdownModule() override;
};
