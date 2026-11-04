#pragma once
#include <flutter_plugin_registrar.h>
#ifdef FLUTTER_PLUGIN_IMPL
#define UNISON_PLUGIN_EXPORT __declspec(dllexport)
#else
#define UNISON_PLUGIN_EXPORT __declspec(dllimport)
#endif
extern "C" UNISON_PLUGIN_EXPORT void UnisonNativePluginCApiRegisterWithRegistrar(FlutterDesktopPluginRegistrarRef registrar);
