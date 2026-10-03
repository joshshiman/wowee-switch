#pragma once
// switch shim for <SDL2/SDL.h>: there is no SDL on the console. When the switch
// include path precedes the system one, upstream '#include <SDL2/SDL.h>' lands
// here and gets the compat slice instead.
#include "../sdl_scancode_compat.h"
