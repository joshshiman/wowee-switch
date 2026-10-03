#pragma once
// Pad-button alias table for the Switch port: same logical names the PS4
// code used, mapped onto libnx's HidNpadButton bits. Lets the (platform-
// neutral, unit-tested) pad binding table in input_switch.hpp keep its
// shape while the backend reads real Switch state.
//
// Console face buttons to Switch face buttons: PS4 Cross is A, Circle is
// B, Square is X, Triangle is Y (Xbox/Switch layout).
//
// <switch.h>, not the sub-header: only switch.h wraps libnx in extern "C",
// and a C++-linkage declaration of hidGet* would not link against libnx.
#include <switch.h>

#define ORBIS_PAD_BUTTON_CROSS   (HidNpadButton_A)
#define ORBIS_PAD_BUTTON_CIRCLE  (HidNpadButton_B)
#define ORBIS_PAD_BUTTON_SQUARE  (HidNpadButton_X)
#define ORBIS_PAD_BUTTON_TRIANGLE (HidNpadButton_Y)
#define ORBIS_PAD_BUTTON_L3      (HidNpadButton_StickL)
#define ORBIS_PAD_BUTTON_R3      (HidNpadButton_StickR)
#define ORBIS_PAD_BUTTON_L1      (HidNpadButton_L)
#define ORBIS_PAD_BUTTON_R1      (HidNpadButton_R)
#define ORBIS_PAD_BUTTON_L2      (HidNpadButton_ZL)
#define ORBIS_PAD_BUTTON_R2      (HidNpadButton_ZR)
#define ORBIS_PAD_BUTTON_OPTIONS (HidNpadButton_Plus)
#define ORBIS_PAD_BUTTON_TOUCH_PAD (HidNpadButton_Minus)
#define ORBIS_PAD_BUTTON_UP      (HidNpadButton_Up)
#define ORBIS_PAD_BUTTON_DOWN    (HidNpadButton_Down)
#define ORBIS_PAD_BUTTON_LEFT    (HidNpadButton_Left)
#define ORBIS_PAD_BUTTON_RIGHT   (HidNpadButton_Right)
