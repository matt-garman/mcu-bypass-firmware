#ifndef TEST_PIC_FIND_PIN_EXACT_H
#define TEST_PIC_FIND_PIN_EXACT_H

#include <string>

#include "modules.h"
#include "ioports.h"

static IOPIN *find_pin_exact(Module *module, const char *name) {
    for (int i = 1; i <= module->get_pin_count(); ++i) {
        std::string &pin_name = module->get_pin_name((unsigned)i);
        if (pin_name == name) return module->get_pin((unsigned)i);
    }
    return nullptr;
}

#endif
