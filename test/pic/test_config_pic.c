// PIC10F32x adapter for the shared CONFIG-word checker.
//
// Both PIC10F322 and PIC10F320 build this same source; the Makefile injects
// PIC_DEVICE_NAME so the report line names the chip actually under test. The
// mechanism is in test_config_pic_core.h and the decode table in
// pic10f32x_config.h, which the core includes through PIC_CONFIG_DEVICE_HEADER.

#define PIC_CONFIG_DEVICE_HEADER "pic/pic10f32x_config.h"

#include "pic/test_config_pic_core.h"
