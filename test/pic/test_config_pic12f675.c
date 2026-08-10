// PIC12F675 adapter for the shared CONFIG-word checker.
//
// The mechanism is in test_config_pic_core.h and the decode table in
// pic12f675_config.h, which the core includes through PIC_CONFIG_DEVICE_HEADER.
// A separate adapter rather than another PIC_DEVICE_NAME on the PIC10F32x one:
// the two parts share the CONFIG address and nothing else, so what varies is the
// whole table, not a label.

#define PIC_CONFIG_DEVICE_HEADER "pic/pic12f675_config.h"

#include "pic/test_config_pic_core.h"
